// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {cbETH_CustomPriceFeed} from "src/prices/protocols/cbETH_CustomPriceFeed.sol";

/// @title cbETH_CustomPriceFeed unit tests (no fork)
contract cbETH_CustomPriceFeedTest is Test {
    address cbEthAddress;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        cbEthAddress = address(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new cbETH_CustomPriceFeed(address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new cbETH_CustomPriceFeed(cbEthAddress, address(0), heartbeat);

        vm.expectRevert();
        new cbETH_CustomPriceFeed(cbEthAddress, ethToUsdChainlink, 0);

        vm.expectRevert();
        new cbETH_CustomPriceFeed(cbEthAddress, cbEthAddress, heartbeat);
    }
}
