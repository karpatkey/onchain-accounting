// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {ankrETH_CustomPriceFeed} from "src/prices/protocols/ankrETH_CustomPriceFeed.sol";

contract ankrETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    ankrETH_CustomPriceFeed ankrEthPriceOracle;

    address constant ANKR_ETH = 0xE95A203B1a91a908F9B9CE46459d101078c2c3cb;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 25_345_348;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        ankrEthPriceOracle = new ankrETH_CustomPriceFeed(ANKR_ETH, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = ankrEthPriceOracle.getLatestPrice();
        // ETH/USD * 1e18 / ankrETH.ratio()
        assertEq(price, 212_219_207_556, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = ankrEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(ankrEthPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(ankrEthPriceOracle.underlyingAssetSupported(), ANKR_ETH, "Underlying asset should match ankrETH token");
    }
}
