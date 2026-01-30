// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sUSDS_PriceOracle} from "src/prices/protocols/sUSDS_Price.sol";

/// @title sUSDS_PriceOracle unit tests (no fork)
contract sUSDS_PriceOracleTest is Test {
    address sUsdsAddress;
    address usdsToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        sUsdsAddress = address(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
        usdsToUsdChainlink = address(0xfF30586cD0F29eD462364C7e81375FC0C71219b1);
        heartbeat = 82_800;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new sUSDS_PriceOracle(address(0), usdsToUsdChainlink, heartbeat);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUsdsAddress, address(0), heartbeat);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUsdsAddress, usdsToUsdChainlink, 0);

        vm.expectRevert();
        new sUSDS_PriceOracle(sUsdsAddress, sUsdsAddress, heartbeat);
    }
}
