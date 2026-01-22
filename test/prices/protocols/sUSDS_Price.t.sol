// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

import {sUSDS_PriceOracle} from "src/prices/protocols/sUSDS_Price.sol";

contract sUSDS_PriceOracleTest is TestEnvConfigurator {
    sUSDS_PriceOracle sUsdsPriceOracle;
    address sUsdsAddress;
    address usdsToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(23_143_100);

        sUsdsAddress = address(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);

        usdsToUsdChainlink = address(0xfF30586cD0F29eD462364C7e81375FC0C71219b1);
        heartbeat = 82_800;

        sUsdsPriceOracle = new sUSDS_PriceOracle(sUsdsAddress, usdsToUsdChainlink, heartbeat);
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sUSDS_PriceOracle(address(0), usdsToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUsdsAddress, address(0), heartbeat);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUsdsAddress, usdsToUsdChainlink, 0);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUsdsAddress, sUsdsAddress, heartbeat);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = sUsdsPriceOracle.getLatestPrice();
        assertEq(price, 106_298_946);
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + heartbeat);
        (uint256 price, bool stale) = sUsdsPriceOracle.getLatestPrice();
        assertEq(price, 106_311_899);
        assertEq(stale, true);
    }

    function test_decimals() public view {
        assertEq(sUsdsPriceOracle.decimals(), 8, "Decimals should match USDS/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(sUsdsPriceOracle.underlyingAssetSupported(), sUsdsAddress, "Underlying asset should match sUSDS token");
    }
}
