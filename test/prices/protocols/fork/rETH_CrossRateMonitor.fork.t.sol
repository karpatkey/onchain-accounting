// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Fork test for the mainnet rETH CrossRate divergence-MONITOR feed:
///         rETH/USD = (rETH/ETH market rate) x (ETH/USD from NAV). The rETH/ETH leg is an INDEPENDENT market
///         feed, distinct from the fundamental primary — so a real market depeg makes this monitor diverge from
///         the primary and NAV flags the asset irregular.
contract rETH_CrossRateMonitorForkTest is TestEnvConfigurator {
    CrossRateCustomPriceFeed oracle;

    address constant ASSET = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant RATE_FEED = 0x536218f9E9Eb48863970252233c8F271f554C2d0;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 25_491_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        _useNewNavImpl(NAV);

        oracle = new CrossRateCustomPriceFeed(ASSET, RATE_FEED, RATE_HEARTBEAT, NAV, BASE);
    }

    /// @dev In-EVM ground truth: rateFeed answer * NAV(base/USD, 8 dec) / 10**rateFeedDecimals.
    function test_getLatestPrice() public view {
        INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(BASE);
        uint256 base8 = uint256(pd.price);
        (, int256 rate,,,) = AggregatorV3Interface(RATE_FEED).latestRoundData();
        uint256 rateDecimals = AggregatorV3Interface(RATE_FEED).decimals();
        uint256 expected = (uint256(rate) * base8) / (10 ** rateDecimals);

        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, expected, "price == (rETH/ETH market) * NAV(ETH/USD) / 10**rateDecimals");
        assertEq(stale, false);
        // Sanity: an ETH-LST priced in USD is within a sane band of ETH/USD (rate ~1.0-1.3x).
        assertGt(price, base8, "LST/USD >= ETH/USD (rate > 1)");
    }

    function test_getLatestPriceStale() public {
        (uint256 freshPrice,) = oracle.getLatestPrice();
        assertGt(freshPrice, 0, "control: priced while fresh");
        vm.warp(block.timestamp + RATE_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, freshPrice, "a stale leg keeps the last price, flagged stale (ADR 0029)");
        assertEq(stale, true, "Price marked stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset is the priced token");
    }
}
