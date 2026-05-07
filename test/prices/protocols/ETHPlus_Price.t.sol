// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ETHPlus_PriceOracle} from "src/prices/protocols/ETHPlus_Price.sol";

/// @title ETHPlus_PriceOracle unit tests (no fork)
contract ETHPlus_PriceOracleTest is Test {
    function test_invalidConstructorArgs_zeroAddress() public {
        vm.expectRevert();
        new ETHPlus_PriceOracle(address(0), 86400);
    }

    function test_invalidConstructorArgs_zeroHeartbeat() public {
        vm.expectRevert();
        new ETHPlus_PriceOracle(address(0x1), 0);
    }
}
