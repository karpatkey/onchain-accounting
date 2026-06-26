// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {cbETH_CustomPriceFeed} from "src/prices/protocols/cbETH_CustomPriceFeed.sol";

contract cbETH_CustomPriceFeedForkTest is TestEnvConfigurator {
    cbETH_CustomPriceFeed cbEthPriceOracle;

    address constant CBETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
    address constant ETH_TO_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant FORK_BLOCK = 24_333_658;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        cbEthPriceOracle = new cbETH_CustomPriceFeed(CBETH, ETH_TO_USD_CHAINLINK, HEARTBEAT);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = cbEthPriceOracle.getLatestPrice();
        // exchangeRate * ETH/USD / 1e18
        assertEq(price, 338_973_691_855, "Price should match calculated value");
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        (uint256 price, bool stale) = cbEthPriceOracle.getLatestPrice();
        assertEq(price, 0, "Stale price returns 0 (I-1)");
        assertEq(stale, true, "Price should be marked as stale");
    }

    function test_decimals() public view {
        assertEq(cbEthPriceOracle.decimals(), 8, "Decimals should match ETH/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(cbEthPriceOracle.underlyingAssetSupported(), CBETH, "Underlying asset should match cbETH token");
    }
}
