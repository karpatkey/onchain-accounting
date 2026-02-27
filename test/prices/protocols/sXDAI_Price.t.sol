// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";

/// @title sXDAI_PriceOracle unit tests (no fork)
contract sXDAI_PriceOracleTest is Test {
    address savingsXDaiAddress;
    address xdaiToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        savingsXDaiAddress = address(0xaf204776c7245bF4147c2612BF6e5972Ee483701);
        xdaiToUsdChainlink = address(0x678df3415fc31947dA4324eC63212874be5a82f8);
        heartbeat = 86_400;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sXDAI_PriceOracle(address(0), xdaiToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sXDAI_PriceOracle(savingsXDaiAddress, address(0), heartbeat);

        vm.expectRevert();
        new sXDAI_PriceOracle(savingsXDaiAddress, xdaiToUsdChainlink, 0);

        vm.expectRevert();
        new sXDAI_PriceOracle(savingsXDaiAddress, savingsXDaiAddress, heartbeat);
    }
}
