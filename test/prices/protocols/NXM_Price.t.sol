// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NXM_PriceOracle} from "src/prices/protocols/NXM_Price.sol";

/// @title NXM_PriceOracle unit tests (no fork)
contract NXM_PriceOracleTest is Test {
    address nxm;
    address ramm;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        nxm = address(0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B);
        ramm = address(0xcafea54f03E1Cc036653444e581A10a43B2487CD);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new NXM_PriceOracle(address(0), ramm, ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new NXM_PriceOracle(nxm, address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new NXM_PriceOracle(nxm, ramm, address(0), heartbeat);

        vm.expectRevert();
        new NXM_PriceOracle(nxm, ramm, ethToUsdChainlink, 0);

        vm.expectRevert();
        new NXM_PriceOracle(nxm, ramm, nxm, heartbeat);
    }
}
