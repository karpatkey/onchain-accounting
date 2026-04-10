// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {wstETH_PriceOracle} from "src/prices/protocols/wstETH_Price.sol";

/// @title wstETH_PriceOracle unit tests (no fork)
contract wstETH_PriceOracleTest is Test {
    address wstEthAddress;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        wstEthAddress = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new wstETH_PriceOracle(address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new wstETH_PriceOracle(wstEthAddress, address(0), heartbeat);

        vm.expectRevert();
        new wstETH_PriceOracle(wstEthAddress, ethToUsdChainlink, 0);

        vm.expectRevert();
        new wstETH_PriceOracle(wstEthAddress, wstEthAddress, heartbeat);
    }
}
