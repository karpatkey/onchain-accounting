// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ETHPlus_PriceOracle} from "src/prices/protocols/ETHPlus_Price.sol";

/// @title ETHPlus_PriceOracle unit tests (no fork)
contract ETHPlus_PriceOracleTest is Test {
    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new ETHPlus_PriceOracle(address(0));
    }
}
