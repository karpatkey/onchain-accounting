// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

import {sUSDS_PriceOracle} from "src/prices/protocols/sUSDS_Price.sol";

contract sUSDS_PriceOracleTest is TestEnvConfigurator {
    sUSDS_PriceOracle sUSDS_priceOracle;
    address sUSDSAddress;
    address UsdsToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        uint256 fork = vm.createFork(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(23_143_100);

        sUSDSAddress = address(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);

        UsdsToUsdChainlink = address(0xfF30586cD0F29eD462364C7e81375FC0C71219b1);
        heartbeat = 82_800;

        sUSDS_priceOracle = new sUSDS_PriceOracle(sUSDSAddress, UsdsToUsdChainlink, heartbeat);
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sUSDS_PriceOracle(address(0), UsdsToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUSDSAddress, address(0), heartbeat);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUSDSAddress, UsdsToUsdChainlink, 0);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUSDSAddress, sUSDSAddress, heartbeat);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = sUSDS_priceOracle.getLatestPrice();
        assertEq(price, 106_298_946);
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + heartbeat);
        (uint256 price, bool stale) = sUSDS_priceOracle.getLatestPrice();
        assertEq(price, 106_311_899);
        assertEq(stale, true);
    }

    function test_decimals() public view {
        assertEq(sUSDS_priceOracle.decimals(), 8, "Decimals should match USDS/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(
            sUSDS_priceOracle.underlyingAssetSupported(), sUSDSAddress, "Underlying asset should match sUSDS token"
        );
    }
}
