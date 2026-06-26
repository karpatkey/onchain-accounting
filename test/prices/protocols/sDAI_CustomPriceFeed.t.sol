// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sDAI_CustomPriceFeed} from "src/prices/protocols/sDAI_CustomPriceFeed.sol";

/// @title sDAI_CustomPriceFeed unit tests (no fork)
contract sDAI_CustomPriceFeedTest is Test {
    address sDaiAddress;
    address dsrManager;
    address daiToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        sDaiAddress = address(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
        daiToUsdChainlink = address(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);
        dsrManager = address(0x373238337Bfe1146fb49989fc222523f83081dDb);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sDAI_CustomPriceFeed(address(0), dsrManager, daiToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sDAI_CustomPriceFeed(sDaiAddress, address(0), daiToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sDAI_CustomPriceFeed(sDaiAddress, dsrManager, address(0), heartbeat);

        vm.expectRevert();
        new sDAI_CustomPriceFeed(sDaiAddress, dsrManager, daiToUsdChainlink, 0);

        vm.expectRevert();
        new sDAI_CustomPriceFeed(sDaiAddress, dsrManager, dsrManager, heartbeat);
    }
}
