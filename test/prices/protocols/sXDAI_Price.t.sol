// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";

contract sXDAI_PriceOracleTest is TestEnvConfigurator {
    sXDAI_PriceOracle sXdaiPriceOracle;
    address savingsXDaiAddress;
    address xdaiToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(36_738_104);

        savingsXDaiAddress = address(0xaf204776c7245bF4147c2612BF6e5972Ee483701);

        xdaiToUsdChainlink = address(0x678df3415fc31947dA4324eC63212874be5a82f8);
        heartbeat = 86_400;

        sXdaiPriceOracle = new sXDAI_PriceOracle(savingsXDaiAddress, xdaiToUsdChainlink, heartbeat);
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sXDAI_PriceOracle(address(0), xdaiToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sXDAI_PriceOracle(savingsXDaiAddress, address(0), heartbeat);

        vm.expectRevert();
        new sXDAI_PriceOracle(savingsXDaiAddress, xdaiToUsdChainlink, 0);

        vm.expectRevert();
        new sXDAI_PriceOracle(savingsXDaiAddress, savingsXDaiAddress, heartbeat);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = sXdaiPriceOracle.getLatestPrice();
        assertEq(price, 112_016_996);
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + heartbeat);
        (uint256 price, bool stale) = sXdaiPriceOracle.getLatestPrice();
        assertEq(price, 112_016_996);
        assertEq(stale, true);
    }

    function test_decimals() public view {
        assertEq(sXdaiPriceOracle.decimals(), 8, "Decimals should match xDAI/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(
            sXdaiPriceOracle.underlyingAssetSupported(), savingsXDaiAddress, "Underlying asset should match sXDAI token"
        );
    }
}
