// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {syrupUSDC_L2_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_L2_CustomPriceFeed.sol";

contract syrupUSDC_L2_CustomPriceFeedForkTest_Arbitrum is TestEnvConfigurator {
    syrupUSDC_L2_CustomPriceFeed oracle;

    address constant SYRUP_USDC = 0x41CA7586cC1311807B4605fBB748a3B8862b42b5;
    address constant SYRUP_USDC_TO_USDC_CHAINLINK = 0xF8722c901675C4F2F7824E256B8A6477b2c105FB;
    address constant USDC_TO_USD_CHAINLINK = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    uint256 constant SYRUP_USDC_TO_USDC_HEARTBEAT = 86_400;
    uint256 constant USDC_TO_USD_HEARTBEAT = 86_400;
    uint256 constant FORK_BLOCK = 433_494_408;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("arb-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new syrupUSDC_L2_CustomPriceFeed(
            SYRUP_USDC,
            SYRUP_USDC_TO_USDC_CHAINLINK,
            USDC_TO_USD_CHAINLINK,
            SYRUP_USDC_TO_USDC_HEARTBEAT,
            USDC_TO_USD_HEARTBEAT
        );
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // 1152141147199413740 * 99997000 / 1e18 = 115210658
        assertEq(price, 115_210_658, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + USDC_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match USDC/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), SYRUP_USDC, "Underlying asset should match syrupUSDC token");
    }
}
