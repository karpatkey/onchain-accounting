// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {syrupUSDC_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_CustomPriceFeed.sol";

contract syrupUSDC_CustomPriceFeedForkTest is TestEnvConfigurator {
    syrupUSDC_CustomPriceFeed syrupUsdcPriceOracle;

    address constant SYRUP_USDC = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address constant USDC_TO_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    uint256 constant HEARTBEAT = 82_800;
    uint256 constant FORK_BLOCK = 24_485_547;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        syrupUsdcPriceOracle = new syrupUSDC_CustomPriceFeed(SYRUP_USDC, USDC_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = syrupUsdcPriceOracle.getLatestPrice();
        // convertToAssets(1e6) * USDC/USD / 1e6
        // = 1152151 * 99994000 / 1e6 = 115208187
        assertEq(price, 115_208_187, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = syrupUsdcPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(syrupUsdcPriceOracle.decimals(), 8, "Decimals should match USDC/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(
            syrupUsdcPriceOracle.underlyingAssetSupported(), SYRUP_USDC, "Underlying asset should match syrupUSDC token"
        );
    }
}
