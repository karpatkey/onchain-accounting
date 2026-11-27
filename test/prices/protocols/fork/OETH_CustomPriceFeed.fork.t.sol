// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {OETH_CustomPriceFeed} from "src/prices/protocols/OETH_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract OETH_CrossRatePriceForkTest is TestEnvConfigurator {
    OETH_CustomPriceFeed oracle;

    address constant ASSET = 0x856c4Efb76C1D1AE02e20CEB03A2A6a08b0b8dC3;
    address constant RATE_FEED = 0x703118C4CbccCBF2AB31913e0f8075fbbb15f563;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        oracle = new OETH_CustomPriceFeed(ASSET, RATE_FEED, RATE_HEARTBEAT, NAV, BASE);
    }

    /// @dev In-EVM ground truth: rateFeed answer * NAV(base/USD, 8 dec) / 10**rateFeedDecimals.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(BASE);
        uint256 base8 = uint256(pd.price);
        (, int256 rate,,,) = AggregatorV3Interface(RATE_FEED).latestRoundData();
        uint256 rateDecimals = AggregatorV3Interface(RATE_FEED).decimals();
        uint256 expected = (uint256(rate) * base8) / (10 ** rateDecimals);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (asset/base) * NAV(base/USD) / 10**rateDecimals");
        assertEq(stale, false);
    }

    /// @notice Past the RATE heartbeat, with the base genuinely fresh, the rate leg alone marks it stale.
    /// @dev **What was wrong.** The previous body warped by `RATE_HEARTBEAT + 1` and asserted `stale == true`.
    ///      That warp also pushes the NAV's base/USD feed past ITS own heartbeat, and `_compute` tests
    ///      `baseStale` BEFORE the rate heartbeat (`if (baseStale || rate <= 0) return (0, true, ...)`), so the
    ///      assertion was satisfied by the base leg. It passed with the rate-leg gate deleted entirely —
    ///      coverage in appearance only, the same defect class as the hardcoded RATE_FEED this PR removes.
    ///
    ///      **Why the freshness is restored at the ORACLE, not at the NAV.** Mocking `getPriceData` or whatever
    ///      `NavBaseUsdLib` calls would make the test assert that a mock returned what it was told to return —
    ///      the tautology again, one layer in. The base Chainlink aggregator is the SYSTEM BOUNDARY, so it is
    ///      the only thing stubbed here: `NAVCalculator`, `NavBaseUsdLib` and the ADR-0019 `sequencerDown`
    ///      un-folding all still execute for real, and the verdict arrives the way it will in production. It
    ///      also survives refactors — a mock pinned to today's internal call shape would silently start passing
    ///      when the plumbing moves.
    ///
    ///      Mutation-verified: deleting the rate-heartbeat gate in `TwoFeedChainlinkPriceFeed._compute` makes
    ///      this FAIL. Passing unmutated is not evidence.
    function test_getLatestPriceStale() public {
        (uint256 freshPrice,) = oracle.getLatestPrice();
        assertGt(freshPrice, 0, "control: priced while fresh");
        address baseFeed = INAVCalculator(NAV).getPriceData(BASE).priceFeed;
        (uint80 rid, int256 ans,,, uint80 air) = AggregatorV3Interface(baseFeed).latestRoundData();

        vm.warp(block.timestamp + RATE_HEARTBEAT + 1);

        // Keep the REAL base aggregator answering fresh at the warped timestamp. Only the rate leg is stale now.
        vm.mockCall(
            baseFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(rid, ans, block.timestamp, block.timestamp, air)
        );

        // Sanity through the CONTRACT's own path, not the mock: the NAV must agree the base is fresh, or a
        // `stale == true` below would prove nothing about the rate leg.
        assertEq(INAVCalculator(NAV).getPriceData(BASE).stale, false, "base must be fresh via the real NAV path");

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, freshPrice, "a stale leg keeps the last price, flagged stale (ADR 0029)");
        assertEq(stale, true, "RATE leg past its heartbeat must mark it stale while the base is fresh");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset should match the priced token");
    }
}
