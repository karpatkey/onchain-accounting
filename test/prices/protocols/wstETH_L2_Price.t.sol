// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {wstETH_L2_PriceOracle} from "src/prices/protocols/wstETH_L2_Price.sol";

/// @title wstETH_L2_PriceOracle unit tests (no fork)
contract wstETH_L2_PriceOracleTest is Test {
    address wstEthAddress;
    address wstEthToEthChainlink;
    address ethToUsdChainlink;
    uint256 wstEthToEthHeartbeat;
    uint256 ethToUsdHeartbeat;

    function setUp() public {
        // Arbitrum addresses — no code locally, probes fail → constructor reverts (expected)
        wstEthAddress = address(0x5979D7b546E38E414F7E9822514be443A4800529);
        wstEthToEthChainlink = address(0xb523AE262D20A936BC152e6023996e46FDC2A95D);
        ethToUsdChainlink = address(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
        wstEthToEthHeartbeat = 86_400;
        ethToUsdHeartbeat = 86_400;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new wstETH_L2_PriceOracle(address(0), wstEthToEthChainlink, ethToUsdChainlink, wstEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new wstETH_L2_PriceOracle(wstEthAddress, address(0), ethToUsdChainlink, wstEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new wstETH_L2_PriceOracle(wstEthAddress, wstEthToEthChainlink, address(0), wstEthToEthHeartbeat, ethToUsdHeartbeat);

        vm.expectRevert();
        new wstETH_L2_PriceOracle(wstEthAddress, wstEthToEthChainlink, ethToUsdChainlink, 0, ethToUsdHeartbeat);

        vm.expectRevert();
        new wstETH_L2_PriceOracle(wstEthAddress, wstEthToEthChainlink, ethToUsdChainlink, wstEthToEthHeartbeat, 0);
    }
}
