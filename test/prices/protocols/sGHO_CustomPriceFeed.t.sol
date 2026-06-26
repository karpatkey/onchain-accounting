// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sGHO_CustomPriceFeed} from "src/prices/protocols/sGHO_CustomPriceFeed.sol";

/// @title sGHO_CustomPriceFeed unit tests (no fork)
contract sGHO_CustomPriceFeedTest is Test {
    address sghoAddress;
    address ghoToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        sghoAddress = address(0xE1753F2e00940cC31213dd92013cF019DFE4ca1d);
        ghoToUsdChainlink = address(0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC);
        heartbeat = 86_400;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sGHO_CustomPriceFeed(address(0), ghoToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sGHO_CustomPriceFeed(sghoAddress, address(0), heartbeat);

        vm.expectRevert();
        new sGHO_CustomPriceFeed(sghoAddress, ghoToUsdChainlink, 0);

        vm.expectRevert();
        new sGHO_CustomPriceFeed(sghoAddress, sghoAddress, heartbeat);
    }
}
