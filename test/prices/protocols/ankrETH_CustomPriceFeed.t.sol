// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ankrETH_CustomPriceFeed} from "src/prices/protocols/ankrETH_CustomPriceFeed.sol";

/// @title ankrETH_CustomPriceFeed unit tests (no fork)
contract ankrETH_CustomPriceFeedTest is Test {
    address ankrEthAddress;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        ankrEthAddress = address(0xE95A203B1a91a908F9B9CE46459d101078c2c3cb);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new ankrETH_CustomPriceFeed(address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new ankrETH_CustomPriceFeed(ankrEthAddress, address(0), heartbeat);

        vm.expectRevert();
        new ankrETH_CustomPriceFeed(ankrEthAddress, ethToUsdChainlink, 0);

        vm.expectRevert();
        new ankrETH_CustomPriceFeed(ankrEthAddress, ankrEthAddress, heartbeat);
    }
}
