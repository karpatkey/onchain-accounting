// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {RobinhoodEquity_CustomPriceFeed} from "src/prices/protocols/RobinhoodEquity_CustomPriceFeed.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {InvalidArguments, InvalidArgumentsWithContext, NotChainlinkOracle} from "src/errors.sol";

/// @notice A Chainlink mock whose answer may be zero or NEGATIVE, whose `updatedAt` may be zero or in the future, and
///         which can be made to revert or to migrate its `decimals()` mid-life.
/// @dev `Mock_PriceOracleChainlink` stores its price as `uint256` and always stamps `block.timestamp`, so it cannot
///      express any of the branches this feed exists to handle. A negative answer reaching `uint256(answer)` would be
///      catastrophic rather than merely wrong, so it is driven explicitly here.
contract Mock_EquityAggregator is AggregatorV3Interface {
    int256 internal _answer;
    uint8 internal _decimals;
    uint256 internal _updatedAt;
    uint80 internal _roundId = 18_446_744_073_709_551_778; // phase 1, round 34 — the shape 4663 actually publishes
    bool internal _reverting;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setRound(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    /// @notice Simulates a proxy migrating to an aggregator that publishes at a different scale.
    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setReverting(bool reverting_) external {
        _reverting = reverting_;
    }

    function decimals() external view override returns (uint8) {
        if (_reverting) revert("aggregator down");
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "RHSPY / USD";
    }

    function version() external pure override returns (uint256) {
        return 4;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return latestRoundData();
    }

    function latestRoundData() public view override returns (uint80, int256, uint256, uint256, uint80) {
        if (_reverting) revert("aggregator down");
        // `startedAt` trails `updatedAt` by the aggregation delay, as the real 4663 rounds do (MEASURED: 12 s).
        // Guarded so the `updatedAt == 0` branch stays reachable without an arithmetic revert masking it.
        return (_roundId, _answer, _updatedAt == 0 ? 0 : _updatedAt - 12, _updatedAt, _roundId);
    }
}

/// @notice Mirrors the Robinhood tokenised-equity surface the wrapper probes: an ERC20-shaped token carrying
///         `uiMultiplier` / `newUIMultiplier` / `effectiveAt` / `oraclePaused`, each individually suppressible so the
///         half-implemented cases are reachable.
contract Mock_EquityToken {
    uint256 internal _uiMultiplier = 1e18;
    uint256 internal _newUIMultiplier;
    uint256 internal _effectiveAt;
    bool internal _paused;
    bool internal _hasUiMultiplier = true;
    bool internal _hasNewUiMultiplier = true;
    bool internal _hasEffectiveAt = true;

    function totalSupply() external pure returns (uint256) {
        return 23_980_562_525_050_000_000_000;
    }

    function setMultipliers(uint256 current, uint256 pending, uint256 effectiveAt_) external {
        _uiMultiplier = current;
        _newUIMultiplier = pending;
        _effectiveAt = effectiveAt_;
    }

    function setPaused(bool paused_) external {
        _paused = paused_;
    }

    function setImplemented(bool current, bool pending, bool effectiveAt_) external {
        _hasUiMultiplier = current;
        _hasNewUiMultiplier = pending;
        _hasEffectiveAt = effectiveAt_;
    }

    function uiMultiplier() external view returns (uint256) {
        if (!_hasUiMultiplier) revert("not implemented");
        return _uiMultiplier;
    }

    function newUIMultiplier() external view returns (uint256) {
        if (!_hasNewUiMultiplier) revert("not implemented");
        return _newUIMultiplier;
    }

    function effectiveAt() external view returns (uint256) {
        if (!_hasEffectiveAt) revert("not implemented");
        return _effectiveAt;
    }

    function oraclePaused() external view returns (bool) {
        return _paused;
    }
}

/// @notice A contract with code but no `totalSupply()`, to drive `assertERC20Address`'s reject arm.
contract Mock_NotAnErc20 {}

/// @title RobinhoodEquity_CustomPriceFeed unit tests (no fork)
/// @dev The numbers are the ones MEASURED on chain 4663 at block 85,956,175 (2026-10-11 12:00:00 ET, Sunday, US
///      tape closed): SPY's aggregator answered `78005783409` at 8 decimals, last updated 164,141 s earlier, and the
///      SPY token's `uiMultiplier()` read `1001717991187472003` — a +17.18 bp multiplier, which is the 17.2 bp the
///      first build of this wrapper overvalued SPY by when it applied that multiplier a second time (MEASURED,
///      2026-09-25). Those are pinned here as the canonical case rather than round numbers, so a regression that
///      reintroduced the double-multiply shows up as the real error it was.
contract RobinhoodEquity_CustomPriceFeedTest is Test {
    Mock_EquityAggregator internal agg;
    Mock_EquityToken internal token;
    RobinhoodEquity_CustomPriceFeed internal feed;

    /// @dev MEASURED on 4663, 2026-10-11: `RHSPY / USD` answer at 8 decimals ($780.05783409).
    int256 internal constant SPY_ANSWER = 78_005_783_409;
    /// @dev MEASURED on 4663, 2026-10-11: SPY's `uiMultiplier()`. Non-unit, and must not move the price.
    uint256 internal constant SPY_MULTIPLIER = 1_001_717_991_187_472_003;

    /// @dev The aggregator's declared publication cadence. DOCUMENTATION ONLY on 4663 — these contracts expose no
    ///      `heartbeat()` getter — corroborated by an 86,417 s longest observed intra-week gap (MEASURED).
    uint256 internal constant HEARTBEAT = 86_400;
    /// @dev The policy number of ADR 0028: Friday close + a Monday US holiday + margin over the MEASURED 290,892 s
    ///      worst-case legitimate weekend gap.
    uint256 internal constant MAX_HOLDOVER = 432_000;

    function setUp() public {
        // Start far enough into the epoch that `block.timestamp - MAX_HOLDOVER` never underflows.
        vm.warp(1_791_734_400); // the pinned fork block's timestamp, for continuity with the fork suite
        agg = new Mock_EquityAggregator(8, SPY_ANSWER, block.timestamp);
        token = new Mock_EquityToken();
        token.setMultipliers(SPY_MULTIPLIER, SPY_MULTIPLIER, block.timestamp - 1 days);
        feed = new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), HEARTBEAT, MAX_HOLDOVER);
    }

    /// @dev The aggregator's `updatedAt`, read back through an external call.
    /// @dev **Never cache `block.timestamp` in a local and then `vm.warp`.** solc treats `TIMESTAMP` as constant for
    ///      the whole transaction — true on a real chain, false under a cheatcode — so it rematerialises the opcode at
    ///      every use of such a local instead of keeping the captured value. `vm.warp(cached + X)` then compounds, and
    ///      `block.timestamp - cached` folds to 0. Every age in this suite is therefore anchored to a value that came
    ///      out of an external call, and "now" after a warp is read with `vm.getBlockTimestamp()`.
    function _legUpdatedAt() internal view returns (uint256 updatedAt) {
        (,,, updatedAt,) = agg.latestRoundData();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Happy path
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The aggregator's answer IS the token price (docstring 1). A non-unit multiplier must not touch it.
    function test_getLatestPrice_returnsTheAggregatorAnswerUnmultiplied() public view {
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "a fresh print inside the holdover window is not stale");
        assertEq(price, uint256(SPY_ANSWER), "price == answer, the multiplier is already in it");

        // The regression guard: what the first build returned, and what this build must not.
        uint256 doubleMultiplied = (uint256(SPY_ANSWER) * SPY_MULTIPLIER) / 1e18;
        assertGt(doubleMultiplied, price, "premise: the multiplier is non-unit at these numbers");
        assertEq(feed.effectiveMultiplier(), SPY_MULTIPLIER, "reported for monitoring, never applied");
    }

    function test_decimals_isTheAggregatorScalePinnedAtConstruction() public view {
        assertEq(feed.decimals(), 8, "4663 equity aggregators publish at 8 decimals");
    }

    function test_underlyingAssetSupported_isTheToken() public view {
        assertEq(feed.underlyingAssetSupported(), address(token));
    }

    function test_baseAsset_isZeroSoRegistrationAcceptsIt() public view {
        assertEq(feed.BASE_ASSET(), address(0), "no NAV-sourced base leg");
        assertEq(INavSourcedPriceFeed(address(feed)).BASE_ASSET(), address(0), "reachable through the interface");
    }

    /// @dev Mirrors the NAV's raw circularity probe: a MISSING or malformed `BASE_ASSET()` is a rejection upstream
    ///      (`IPrices.CustomFeedBaseUnreadable`), so "answers one clean word" is the property, not "returns zero".
    function test_baseAsset_isReadableAsExactlyOneWord() public view {
        (bool ok, bytes memory ret) = address(feed).staticcall(abi.encodeWithSignature("BASE_ASSET()"));
        assertTrue(ok, "BASE_ASSET() must be readable");
        assertEq(ret.length, 32, "exactly one word");
        assertEq(abi.decode(ret, (uint256)), 0);
    }

    function test_supportsInterface() public view {
        assertTrue(feed.supportsInterface(type(ICustomPriceFeed).interfaceId), "ICustomPriceFeed");
        assertTrue(feed.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(feed.supportsInterface(type(INavSourcedPriceFeed).interfaceId), "not folded into the gate");
        assertFalse(feed.supportsInterface(0xffffffff), "must reject the invalid id");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The holdover policy
    // -----------------------------------------------------------------------------------------------------------

    /// @dev THE POINT OF THE CONTRACT: past the aggregator's own 24 h heartbeat — where a raw `PriceType.Chainlink`
    ///      registration would already be dead — but inside the holdover, the last print still stands.
    function test_pastHeartbeatButInsideHoldover_isNotStale() public {
        uint256 updatedAt = _legUpdatedAt();

        vm.warp(updatedAt + HEARTBEAT);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "age == HEARTBEAT: the holdover accepts it");
        assertEq(price, uint256(SPY_ANSWER));

        // The age MEASURED at the pinned fork block, 45.6 h: deep past the heartbeat, well inside the holdover.
        vm.warp(updatedAt + 164_141);
        (price, stale) = feed.getLatestPrice();
        assertFalse(stale, "the real weekend age is accepted");
        assertEq(price, uint256(SPY_ANSWER), "the weekend mark is the last close");

        vm.warp(updatedAt + MAX_HOLDOVER - 1);
        (, stale) = feed.getLatestPrice();
        assertFalse(stale, "one second inside the policy limit is the last accepted second");
    }

    /// @dev The bound is INCLUSIVE, matching `PriceFeedLib._selectFeedCore` and every upstream Chainlink wrapper, so
    ///      that registering `MAX_HOLDOVER` as the NAV heartbeat makes both gates fire on the same second.
    function test_atAndPastMaxHoldover_isStaleButStillReportsTheRejectedMark() public {
        uint256 updatedAt = _legUpdatedAt();

        vm.warp(updatedAt + MAX_HOLDOVER);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale, "age == MAX_HOLDOVER is stale: the bound is inclusive");
        assertEq(price, uint256(SPY_ANSWER), "the rejected mark is still visible to an operator");

        vm.warp(updatedAt + 7 days);
        (price, stale) = feed.getLatestPrice();
        assertTrue(stale, "a week old must never silently recover");
        assertEq(price, uint256(SPY_ANSWER));
    }

    /// @dev `maxHoldover == heartbeat` is the "no holdover at all" configuration.
    function test_noHoldoverConfiguration_behavesLikeRawChainlink() public {
        RobinhoodEquity_CustomPriceFeed plain =
            new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), HEARTBEAT, HEARTBEAT);
        uint256 updatedAt = _legUpdatedAt();

        vm.warp(updatedAt + HEARTBEAT - 1);
        (, bool stale) = plain.getLatestPrice();
        assertFalse(stale);

        vm.warp(updatedAt + HEARTBEAT);
        (, stale) = plain.getLatestPrice();
        assertTrue(stale, "with no holdover the heartbeat is the whole policy");
    }

    /// @dev A clock ahead of ours is clamped to age 0, exactly as the NAV clamps it, rather than treated as an error.
    function test_futureUpdatedAt_clampsToAgeZero() public {
        agg.setRound(SPY_ANSWER, block.timestamp + 1 days);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, uint256(SPY_ANSWER));
        assertFalse(stale, "future updatedAt clamps to age 0");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The four hard-staleness conditions, never held over
    // -----------------------------------------------------------------------------------------------------------

    function test_zeroAnswer_isStaleWithNoPrice() public {
        agg.setRound(0, block.timestamp);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, 0, "there is no mark to report");
        assertTrue(stale);
    }

    function test_negativeAnswer_isStaleWithNoPrice() public {
        agg.setRound(-1, block.timestamp);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, 0, "a negative answer must never reach uint256(answer)");
        assertTrue(stale);
    }

    function test_zeroUpdatedAt_isStaleWithNoPrice() public {
        agg.setRound(SPY_ANSWER, 0);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, 0, "a print with no timestamp cannot be held over");
        assertTrue(stale);
    }

    /// @dev A corporate action is exactly the event that stops the last print from being a fair mark, and the flag is
    ///      advisory on-chain — this wrapper is the only thing that makes it bite.
    function test_oraclePaused_isStaleInsideTheHeartbeat() public {
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertFalse(stale);
        assertFalse(feed.oraclePaused());

        token.setPaused(true);
        (price, stale) = feed.getLatestPrice();
        assertTrue(stale, "a corporate-action pause is never held over");
        assertEq(price, uint256(SPY_ANSWER), "the rejected mark is still reported");
        assertTrue(feed.oraclePaused());
    }

    /// @dev A token asserting its own multiplier is zero contradicts the aggregator that is supposed to apply it.
    ///      Refusing to price the contradiction under-reports, which is the direction this system errs in.
    function test_zeroEffectiveMultiplier_isStale() public {
        token.setMultipliers(0, 0, 0);
        assertEq(feed.effectiveMultiplier(), 0);

        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale, "a zero effective multiplier is hard staleness");
        assertEq(price, uint256(SPY_ANSWER), "the rejected mark is still reported");
    }

    /// @dev The over-report direction the pinned `decimals()` would otherwise hide: a proxy migrating 8 -> 10 keeps
    ///      publishing the same real price as a 100x larger integer, and the NAV still scales by the 8 it stored.
    function test_decimalsMigration_isStaleRatherThanRescaled() public {
        agg.setDecimals(10);
        (uint256 price, bool stale) = feed.getLatestPrice();
        assertTrue(stale, "an unknown scale is not a price");
        assertEq(price, 0);
        assertEq(feed.decimals(), 8, "the pinned value is what the NAV stored and does not move");
    }

    /// @dev An unreadable aggregator is reported as stale, never propagated as a revert.
    function test_revertingAggregator_isStaleAndNeverReverts() public {
        agg.setReverting(true);

        (uint256 price, bool stale) = feed.getLatestPrice();
        assertEq(price, 0);
        assertTrue(stale, "unreadable aggregator");

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 0);
        assertEq(answer, 0);
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0, "the interface's documented no-trackable-oracle value");
        assertEq(answeredInRound, 0);

        (uint256 govUpdatedAt, uint256 govHeartbeat) = feed.governingFeedFreshness();
        assertEq(govUpdatedAt, 0, "no timestamp");
        assertEq(govHeartbeat, HEARTBEAT, "still reported against the declared cadence");
    }

    // -----------------------------------------------------------------------------------------------------------
    // latestRoundData and governingFeedFreshness
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Verbatim pass-through: the NAV uses this `updatedAt` for the registered-heartbeat gate and to rank
    ///      redundant feeds, so it must be the aggregator's real timestamp and not `block.timestamp`.
    function test_latestRoundData_passesTheAggregatorTupleThrough() public view {
        (uint80 aRound, int256 aAnswer, uint256 aStarted, uint256 aUpdated, uint80 aAnsweredIn) = agg.latestRoundData();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        assertEq(roundId, aRound, "roundId");
        assertEq(answer, aAnswer, "answer");
        assertEq(startedAt, aStarted, "startedAt");
        assertEq(updatedAt, aUpdated, "updatedAt");
        assertEq(answeredInRound, aAnsweredIn, "answeredInRound");
    }

    /// @dev The answer is NOT zeroed when the feed is stale — unlike a feed whose answer is derived, this tuple is
    ///      the oracle's own round, which {ICustomPriceFeed} says to return directly.
    function test_latestRoundData_keepsTheAnswerWhenStale() public {
        vm.warp(block.timestamp + MAX_HOLDOVER);
        (, bool stale) = feed.getLatestPrice();
        assertTrue(stale);

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, SPY_ANSWER, "the round is reported as published");
        assertGt(updatedAt, 0, "and so is its real timestamp");
    }

    /// @dev ADR 0020: one Chainlink leg, so that leg governs. It reports the DECLARED cadence, not the policy number.
    function test_governingFeedFreshness_isTheLegAgainstTheDeclaredCadence() public view {
        (,,, uint256 legUpdatedAt,) = agg.latestRoundData();
        (uint256 updatedAt, uint256 heartbeat) = feed.governingFeedFreshness();
        assertEq(updatedAt, legUpdatedAt, "the leg's own timestamp");
        assertEq(heartbeat, HEARTBEAT, "the aggregator cadence");
        assertTrue(heartbeat != MAX_HOLDOVER, "NOT the holdover, and NOT the registered heartbeat");
    }

    /// @dev The direction ADR 0020 does not enumerate: during the holdover the advisory pair reads STALE while the
    ///      authoritative `stale` flag is false. That is the operator signal, and it is why consumers must gate on
    ///      `stale` rather than recompute from the pair.
    function test_governingFeedFreshness_readsStaleWhileTheFeedIsNot() public {
        vm.warp(block.timestamp + 164_141); // the age MEASURED at the pinned fork block
        (uint256 updatedAt, uint256 heartbeat) = feed.governingFeedFreshness();
        assertGt(block.timestamp - updatedAt, heartbeat, "the advisory pair is past its deadline");

        (, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "the authoritative verdict is still fresh: that is the holdover");
    }

    // -----------------------------------------------------------------------------------------------------------
    // The ADR 0025 / ADR 0028 registration coupling
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The whole tension, made checkable: the provider's declared cadence is NOT a legal registration for this
    ///      wrapper, and the policy number is the only one that is.
    function test_requiredRegistrationHeartbeat_isTheHoldoverAndNotTheDeclaredCadence() public view {
        assertEq(feed.requiredRegistrationHeartbeat(), MAX_HOLDOVER, "register the policy number");
        assertTrue(feed.registrationHeartbeatSatisfiesPolicy(MAX_HOLDOVER));
        assertFalse(
            feed.registrationHeartbeatSatisfiesPolicy(HEARTBEAT), "the declared cadence kills the policy off-hours"
        );
        assertFalse(feed.registrationHeartbeatSatisfiesPolicy(MAX_HOLDOVER + 1), "anything wider is unexplained margin");
        assertFalse(feed.registrationHeartbeatSatisfiesPolicy(MAX_HOLDOVER - 1), "anything narrower is too tight");
    }

    /// @dev The invariant the registration must satisfy, asserted against the gate it exists to clear: at the last
    ///      age this wrapper accepts, a NAV registered at `requiredRegistrationHeartbeat()` has not yet refused the
    ///      feed; one second later both refuse it.
    function test_registrationHeartbeatLetsThePolicySpeakToItsLastSecond() public {
        uint256 updatedAt = _legUpdatedAt();
        uint256 registered = feed.requiredRegistrationHeartbeat();

        vm.warp(updatedAt + MAX_HOLDOVER - 1);
        (, bool stale) = feed.getLatestPrice();
        assertFalse(stale, "wrapper accepts");
        assertLt(vm.getBlockTimestamp() - updatedAt, registered, "and _selectFeedCore's `>= heartbeat` has not fired");

        vm.warp(updatedAt + MAX_HOLDOVER);
        (, stale) = feed.getLatestPrice();
        assertTrue(stale, "wrapper refuses");
        assertGe(vm.getBlockTimestamp() - updatedAt, registered, "on the same second the NAV gate fires");
    }

    // -----------------------------------------------------------------------------------------------------------
    // effectiveMultiplier
    // -----------------------------------------------------------------------------------------------------------

    /// @dev A plain ERC20 implementing none of the Robinhood getters degenerates to a pass-through.
    function test_effectiveMultiplier_plainErc20ReadsUnity() public {
        Mock_ERC20 weth = new Mock_ERC20("WETH", 18);
        RobinhoodEquity_CustomPriceFeed plainFeed =
            new RobinhoodEquity_CustomPriceFeed(address(agg), address(weth), HEARTBEAT, MAX_HOLDOVER);

        assertEq(plainFeed.effectiveMultiplier(), plainFeed.MULTIPLIER_SCALE(), "no getters => unit multiplier");
        assertFalse(plainFeed.oraclePaused(), "no getter => not paused");

        (uint256 price, bool stale) = plainFeed.getLatestPrice();
        assertEq(price, uint256(SPY_ANSWER));
        assertFalse(stale);
    }

    function test_effectiveMultiplier_switchesAtEffectiveAt() public {
        token.setMultipliers(1.5e18, 2e18, block.timestamp + 1000);
        assertEq(feed.effectiveMultiplier(), 1.5e18, "before effectiveAt the current multiplier stands");

        vm.warp(block.timestamp + 1000); // exactly at effectiveAt
        assertEq(feed.effectiveMultiplier(), 2e18, "at effectiveAt the pending multiplier is in force");
    }

    function test_effectiveMultiplier_effectiveAtZeroMeansNothingStaged() public {
        token.setMultipliers(1.5e18, 9e18, 0);
        assertEq(feed.effectiveMultiplier(), 1.5e18, "effectiveAt == 0 means nothing is staged");
    }

    /// @dev If the pending value is scheduled but unreadable, the value already in force stands — never `1e18`, so a
    ///      half-implemented token cannot silently erase a live corporate-action adjustment.
    function test_effectiveMultiplier_unreadablePendingFallsBackToCurrentNotUnity() public {
        token.setMultipliers(1.5e18, 2e18, block.timestamp - 1);
        token.setImplemented(true, false, true);
        assertEq(feed.effectiveMultiplier(), 1.5e18, "falls back to the live value, not to unity");
    }

    function test_effectiveMultiplier_unreadableEffectiveAtKeepsCurrent() public {
        token.setMultipliers(1.5e18, 2e18, block.timestamp - 1);
        token.setImplemented(true, true, false);
        assertEq(feed.effectiveMultiplier(), 1.5e18, "no schedule readable => current stands");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Constructor guards
    // -----------------------------------------------------------------------------------------------------------

    function test_constructor_rejectsZeroAggregator() public {
        vm.expectRevert(InvalidArguments.selector);
        new RobinhoodEquity_CustomPriceFeed(address(0), address(token), HEARTBEAT, MAX_HOLDOVER);
    }

    function test_constructor_rejectsAnAggregatorThatCannotAnswer() public {
        Mock_EquityAggregator dead = new Mock_EquityAggregator(8, SPY_ANSWER, block.timestamp);
        dead.setReverting(true);

        vm.expectRevert(NotChainlinkOracle.selector);
        new RobinhoodEquity_CustomPriceFeed(address(dead), address(token), HEARTBEAT, MAX_HOLDOVER);
    }

    /// @dev A code-less aggregator fails too, but through solc's `extcodesize` check on the high-level call, which
    ///      `try` does not catch — so the revert data is not `NotChainlinkOracle` and the assertion is deliberately
    ///      on the fact of the revert, not on its selector.
    function test_constructor_rejectsACodelessAggregator() public {
        vm.expectRevert();
        new RobinhoodEquity_CustomPriceFeed(address(0xdead), address(token), HEARTBEAT, MAX_HOLDOVER);
    }

    function test_constructor_rejectsZeroUnderlyingAsset() public {
        vm.expectRevert(InvalidArguments.selector);
        new RobinhoodEquity_CustomPriceFeed(address(agg), address(0), HEARTBEAT, MAX_HOLDOVER);
    }

    function test_constructor_rejectsANonErc20UnderlyingAsset() public {
        Mock_NotAnErc20 notToken = new Mock_NotAnErc20();
        vm.expectRevert(InvalidArguments.selector);
        new RobinhoodEquity_CustomPriceFeed(address(agg), address(notToken), HEARTBEAT, MAX_HOLDOVER);
    }

    function test_constructor_rejectsZeroHeartbeat() public {
        vm.expectRevert(InvalidArguments.selector);
        new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), 0, MAX_HOLDOVER);
    }

    function test_constructor_rejectsAHoldoverBelowTheHeartbeat() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "maxHoldover: below heartbeat"));
        new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), HEARTBEAT, HEARTBEAT - 1);
    }

    function test_constructor_rejectsAnUnusableAggregatorAnswer() public {
        bytes memory expected =
            abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "aggregator: answer unusable");

        agg.setRound(0, block.timestamp);
        vm.expectRevert(expected);
        new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), HEARTBEAT, MAX_HOLDOVER);

        agg.setRound(SPY_ANSWER, 0);
        vm.expectRevert(expected);
        new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), HEARTBEAT, MAX_HOLDOVER);

        agg.setRound(SPY_ANSWER, block.timestamp + 1);
        vm.expectRevert(expected);
        new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), HEARTBEAT, MAX_HOLDOVER);
    }

    /// @dev Stale-but-positive is explicitly ALLOWED at deploy time: requiring a fresh round would make every
    ///      off-hours deployment revert, which is the failure mode this contract exists to remove.
    function test_constructor_acceptsAnOverAgedPrintAndReportsStale() public {
        agg.setRound(SPY_ANSWER, block.timestamp - 6 days);
        RobinhoodEquity_CustomPriceFeed offHours =
            new RobinhoodEquity_CustomPriceFeed(address(agg), address(token), HEARTBEAT, MAX_HOLDOVER);

        (uint256 price, bool stale) = offHours.getLatestPrice();
        assertTrue(stale, "deployed against an over-aged print: deploys, reports stale");
        assertEq(price, uint256(SPY_ANSWER), "and still shows what it rejected");
    }

    function test_constructor_pinsEveryInput() public view {
        assertEq(address(feed.AGGREGATOR()), address(agg));
        assertEq(feed.UNDERLYING_ASSET(), address(token));
        assertEq(feed.HEARTBEAT(), HEARTBEAT);
        assertEq(feed.MAX_HOLDOVER(), MAX_HOLDOVER);
        assertEq(feed.MULTIPLIER_SCALE(), 1e18);
    }
}
