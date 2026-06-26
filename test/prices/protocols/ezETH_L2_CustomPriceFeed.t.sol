// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ezETH_L2_CustomPriceFeed} from "src/prices/protocols/ezETH_L2_CustomPriceFeed.sol";

/// @title ezETH_L2_CustomPriceFeed unit tests (no fork)
contract ezETH_L2_CustomPriceFeedTest is Test {
    address ezEthAddress;
    address xRenzoDeposit;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        ezEthAddress = address(0x2416092f143378750bb29b79eD961ab195CcEea5);
        xRenzoDeposit = address(0x2EfA125B4fcD5B082a4233BA55b53FeB2Fb4Ff33);
        ethToUsdChainlink = address(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(address(0), xRenzoDeposit, ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(ezEthAddress, address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(ezEthAddress, xRenzoDeposit, address(0), heartbeat);

        vm.expectRevert();
        new ezETH_L2_CustomPriceFeed(ezEthAddress, xRenzoDeposit, ethToUsdChainlink, 0);
    }
}
