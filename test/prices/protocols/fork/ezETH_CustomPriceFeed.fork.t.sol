// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ezETH_CustomPriceFeed} from "src/prices/protocols/ezETH_CustomPriceFeed.sol";

contract ezETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    ezETH_CustomPriceFeed oracle;

    address constant EZETH = 0xbf5495Efe5DB9ce00f80364C8B423567e58d2110;
    address constant RESTAKE_MANAGER = 0x74a09653A083691711cF8215a6ab074BB4e99ef5;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant ETH_TO_USD_HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 24_328_427;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        oracle = new ezETH_CustomPriceFeed(EZETH, RESTAKE_MANAGER, ETH_TO_USD_CHAINLINK, ETH_TO_USD_HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = oracle.getLatestPrice();
        // (234893778129660851465913 * 1e18 / 219462801658816815985885) * 297978431000 / 1e18 = 318930037025
        assertEq(price, 318_930_037_025, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + ETH_TO_USD_HEARTBEAT + 1);
        (uint256 price, bool stale) = oracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(oracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(oracle.underlyingAssetSupported(), EZETH, "Underlying asset should match ezETH token");
    }
}
