// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {Prices} from "src/prices/Prices.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {PricesHarness} from "test/prices/Prices.t.sol";

/// @notice Configurable Chainlink-shaped aggregator for exercising the read-time guards in PriceFeedLib._selectFeedCore
///         (round-completeness, min/maxAnswer circuit-breaker, future-timestamp reject). Also models the
///         `aggregator()`/`minAnswer()`/`maxAnswer()` surface so the bounds check can be driven, and can hide it
///         (bounds disabled → `aggregator()` reverts) to assert the fail-open path for feeds without bounds.
contract GuardAggregator is AggregatorV3Interface {
    int256 internal _answer;
    uint8 internal _decimals;
    uint256 internal _updatedAt;
    uint80 internal _roundId = 1;
    uint80 internal _answeredInRound = 1;
    int192 internal _min;
    int192 internal _max;
    bool internal _boundsEnabled;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 a) external {
        _answer = a;
    }

    function setUpdatedAt(uint256 u) external {
        _updatedAt = u;
    }

    function setRound(uint80 roundId_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function enableBounds(int192 min_, int192 max_) external {
        _min = min_;
        _max = max_;
        _boundsEnabled = true;
    }

    // --- Chainlink circuit-breaker surface (only reachable when bounds enabled) ---
    function aggregator() external view returns (address) {
        require(_boundsEnabled, "no aggregator");
        return address(this);
    }

    function minAnswer() external view returns (int192) {
        return _min;
    }

    function maxAnswer() external view returns (int192) {
        return _max;
    }

    // --- AggregatorV3Interface ---
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "GuardAggregator";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }
}

contract PriceFeedGuardsTest is Test {
    PricesHarness internal prices;
    address internal token = makeAddr("token");

    function setUp() public {
        // PriceFeedLib is pre-linked at a deterministic CREATE2 address; etch its runtime code there for DELEGATECALL.
        vm.etch(LibraryPins.PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.warp(1_000_000); // non-trivial timestamp so future/past offsets are unambiguous
        prices = new PricesHarness(address(0)); // L1: no sequencer feed
    }

    function _register(GuardAggregator agg) internal {
        prices.setPriceFeed(token, address(agg), type(uint256).max, IPrices.PriceType.Chainlink);
    }

    function _stale() internal view returns (bool stale) {
        (,, stale) = prices.latestPrice(token);
    }

    // --- Round completeness -------------------------------------------------

    function test_completeRound_isHealthy() public {
        GuardAggregator agg = new GuardAggregator(2000e8, 8);
        _register(agg);
        (int256 price,, bool stale) = prices.latestPrice(token);
        assertEq(price, 2000e8);
        assertFalse(stale);
    }

    function test_zeroRoundId_marksStale() public {
        GuardAggregator agg = new GuardAggregator(2000e8, 8);
        _register(agg);
        agg.setRound(0, 0); // roundId == 0 → incomplete
        assertTrue(_stale());
    }

    function test_carriedOverRound_marksStale() public {
        GuardAggregator agg = new GuardAggregator(2000e8, 8);
        _register(agg);
        agg.setRound(10, 9); // answeredInRound < roundId → stale carry-over
        assertTrue(_stale());
    }

    // --- min/maxAnswer circuit-breaker -------------------------------------

    function test_answerPinnedAtMax_marksStale() public {
        GuardAggregator agg = new GuardAggregator(2000e8, 8);
        agg.enableBounds(1e8, 1_000_000e8);
        _register(agg);
        assertFalse(_stale()); // within bounds
        agg.setAnswer(1_000_000e8); // == maxAnswer → clamped
        assertTrue(_stale());
    }

    function test_answerPinnedAtMin_marksStale() public {
        GuardAggregator agg = new GuardAggregator(2000e8, 8);
        agg.enableBounds(1e8, 1_000_000e8);
        _register(agg);
        agg.setAnswer(1e8); // == minAnswer → clamped
        assertTrue(_stale());
    }

    function test_bounds_failOpen_whenAggregatorAbsent() public {
        // Bounds NOT enabled → aggregator() reverts → _aggregatorBoundsOk fails open (no gating). A feed without
        // published bounds (API3/Redstone-style) is never gated by this check.
        GuardAggregator agg = new GuardAggregator(2000e8, 8);
        _register(agg);
        agg.setAnswer(999_999_999e8); // absurdly high, but no bounds to compare against
        assertFalse(_stale());
    }

    // --- Future timestamp ---------------------------------------------------

    function test_futureUpdatedAt_marksStale() public {
        GuardAggregator agg = new GuardAggregator(2000e8, 8);
        _register(agg);
        agg.setUpdatedAt(block.timestamp + 1); // future push timestamp → rejected
        assertTrue(_stale());
        agg.setUpdatedAt(block.timestamp); // back to now → healthy
        assertFalse(_stale());
    }
}
