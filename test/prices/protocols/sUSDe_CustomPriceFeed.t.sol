// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sUSDe_CustomPriceFeed} from "src/prices/protocols/sUSDe_CustomPriceFeed.sol";

/// @title sUSDe_CustomPriceFeed unit tests (no fork)
contract sUSDe_CustomPriceFeedTest is Test {
    address sUsdeAddress;
    address usdeToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        sUsdeAddress = address(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
        usdeToUsdChainlink = address(0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961);
        heartbeat = 82_800;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sUSDe_CustomPriceFeed(address(0), usdeToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sUSDe_CustomPriceFeed(sUsdeAddress, address(0), heartbeat);

        vm.expectRevert();
        new sUSDe_CustomPriceFeed(sUsdeAddress, usdeToUsdChainlink, 0);

        vm.expectRevert();
        new sUSDe_CustomPriceFeed(sUsdeAddress, sUsdeAddress, heartbeat);
    }
}
