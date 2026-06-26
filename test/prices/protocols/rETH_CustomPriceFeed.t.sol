// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {rETH_CustomPriceFeed} from "src/prices/protocols/rETH_CustomPriceFeed.sol";

/// @title rETH_CustomPriceFeed unit tests (no fork)
contract rETH_CustomPriceFeedTest is Test {
    address rEthAddress;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        rEthAddress = address(0xae78736Cd615f374D3085123A210448E74Fc6393);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new rETH_CustomPriceFeed(address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new rETH_CustomPriceFeed(rEthAddress, address(0), heartbeat);

        vm.expectRevert();
        new rETH_CustomPriceFeed(rEthAddress, ethToUsdChainlink, 0);

        vm.expectRevert();
        new rETH_CustomPriceFeed(rEthAddress, rEthAddress, heartbeat);
    }
}
