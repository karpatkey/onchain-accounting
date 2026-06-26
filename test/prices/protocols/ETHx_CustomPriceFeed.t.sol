// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ETHx_CustomPriceFeed} from "src/prices/protocols/ETHx_CustomPriceFeed.sol";

/// @title ETHx_CustomPriceFeed unit tests (no fork)
/// @dev Constructor-only sanity checks; arithmetic is exercised in the fork test against real Stader/Chainlink state.
contract ETHx_CustomPriceFeedTest is Test {
    address ethx;
    address stakePoolsManager;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        ethx = address(0xA35b1B31Ce002FBF2058D22F30f95D405200A15b);
        stakePoolsManager = address(0xcf5EA1b38380f6aF39068375516Daf40Ed70D299);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        // ETHx zero
        vm.expectRevert();
        new ETHx_CustomPriceFeed(address(0), stakePoolsManager, ethToUsdChainlink, heartbeat);

        // StakePoolsManager zero
        vm.expectRevert();
        new ETHx_CustomPriceFeed(ethx, address(0), ethToUsdChainlink, heartbeat);

        // ETH/USD oracle zero
        vm.expectRevert();
        new ETHx_CustomPriceFeed(ethx, stakePoolsManager, address(0), heartbeat);

        // Heartbeat zero
        vm.expectRevert();
        new ETHx_CustomPriceFeed(ethx, stakePoolsManager, ethToUsdChainlink, 0);

        // ETH/USD oracle pointing at the ETHx token (not a Chainlink aggregator)
        vm.expectRevert();
        new ETHx_CustomPriceFeed(ethx, stakePoolsManager, ethx, heartbeat);
    }
}
