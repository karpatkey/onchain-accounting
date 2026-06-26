// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {rETH_CustomPriceFeed} from "src/prices/protocols/rETH_CustomPriceFeed.sol";

contract rETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    rETH_CustomPriceFeed rEthPriceOracle;

    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 24_249_038;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        rEthPriceOracle = new rETH_CustomPriceFeed(RETH, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = rEthPriceOracle.getLatestPrice();
        // getExchangeRate * ETH/USD / 1e18
        assertEq(price, 378_517_581_367, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = rEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(rEthPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(rEthPriceOracle.underlyingAssetSupported(), RETH, "Underlying asset should match rETH token");
    }
}
