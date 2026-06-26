// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ETHPlus_CustomPriceFeed} from "src/prices/protocols/ETHPlus_CustomPriceFeed.sol";

/// @title ETHPlus_CustomPriceFeed unit tests (no fork)
contract ETHPlus_CustomPriceFeedTest is Test {
    function test_invalidConstructorArgs_zeroAddress() public {
        vm.expectRevert();
        new ETHPlus_CustomPriceFeed(address(0), 86400);
    }

    function test_invalidConstructorArgs_zeroHeartbeat() public {
        vm.expectRevert();
        new ETHPlus_CustomPriceFeed(address(0x1), 0);
    }
}
