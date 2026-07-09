// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {rsETH_L2_CustomPriceFeed} from "src/prices/protocols/rsETH_L2_CustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract rsETH_L2_CustomPriceFeedForkTest_Arbitrum is TestEnvConfigurator {
    rsETH_L2_CustomPriceFeed oracle;

    address constant ASSET = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;
    address constant RATE_FEED = 0x3A917e6B5732dFCc4A45257e3930979fAE6a3737;
    address constant NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91;
    address constant BASE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    uint256 constant RATE_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 481_880_000;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new rsETH_L2_CustomPriceFeed(ASSET, RATE_FEED, RATE_HEARTBEAT, NAV, BASE);
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

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + RATE_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale past the rate heartbeat");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match NAV base/USD (8)");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), ASSET, "Underlying asset should match the priced token");
    }
}
