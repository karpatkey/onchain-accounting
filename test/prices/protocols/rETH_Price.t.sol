// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {rETH_PriceOracle} from "src/prices/protocols/rETH_Price.sol";

/// @title rETH_PriceOracle unit tests (no fork)
contract rETH_PriceOracleTest is Test {
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
        new rETH_PriceOracle(address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new rETH_PriceOracle(rEthAddress, address(0), heartbeat);

        vm.expectRevert();
        new rETH_PriceOracle(rEthAddress, ethToUsdChainlink, 0);

        vm.expectRevert();
        new rETH_PriceOracle(rEthAddress, rEthAddress, heartbeat);
    }
}
