// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ezETH_PriceOracle} from "src/prices/protocols/ezETH_Price.sol";

/// @title ezETH_PriceOracle unit tests (no fork)
contract ezETH_PriceOracleTest is Test {
    address ezEthAddress;
    address restakeManager;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        ezEthAddress = address(0xbf5495Efe5DB9ce00f80364C8B423567e58d2110);
        restakeManager = address(0x74a09653A083691711cF8215a6ab074BB4e99ef5);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new ezETH_PriceOracle(address(0), restakeManager, ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new ezETH_PriceOracle(ezEthAddress, address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new ezETH_PriceOracle(ezEthAddress, restakeManager, address(0), heartbeat);

        vm.expectRevert();
        new ezETH_PriceOracle(ezEthAddress, restakeManager, ethToUsdChainlink, 0);
    }
}
