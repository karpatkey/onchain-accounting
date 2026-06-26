// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

import {sDAI_CustomPriceFeed} from "src/prices/protocols/sDAI_CustomPriceFeed.sol";

contract sDAI_CustomPriceFeedTest is TestEnvConfigurator {
    sDAI_CustomPriceFeed sDaiPriceOracle;
    address sDaiAddress;
    address dsrManager;
    address daiToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        uint256 fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(20_579_373);

        sDaiAddress = address(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
        daiToUsdChainlink = address(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);
        dsrManager = address(0x373238337Bfe1146fb49989fc222523f83081dDb);
        heartbeat = 3600;

        sDaiPriceOracle = new sDAI_CustomPriceFeed(sDaiAddress, dsrManager, daiToUsdChainlink, heartbeat);
    }

    function test_getLatestPrice() public view {
        (uint256 price, bool stale) = sDaiPriceOracle.getLatestPrice();
        assertEq(price, 110_450_673);
        assertEq(stale, false);
    }

    function test_getLatestPriceStale() public {
        vm.warp(block.timestamp + heartbeat);
        (uint256 price, bool stale) = sDaiPriceOracle.getLatestPrice();
        assertEq(price, 0);
        assertEq(stale, true);
    }

    function test_decimals() public view {
        assertEq(sDaiPriceOracle.decimals(), 8, "Decimals should match xDAI/USD oracle");
    }

    function test_underlyingAssetSupported() public view {
        assertEq(sDaiPriceOracle.underlyingAssetSupported(), sDaiAddress, "Underlying asset should match sDAI token");
    }
}
