// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {weETH_L2_CustomPriceFeed} from "src/prices/protocols/weETH_L2_CustomPriceFeed.sol";

/// @title weETH_L2_CustomPriceFeed unit tests (no fork)
contract weETH_L2_CustomPriceFeedTest is Test {
    address weEthAddress;
    address weEthToEethChainlink;
    address ethToUsdChainlink;
    uint256 weEthToEethHeartbeat;
    uint256 ethToUsdHeartbeat;

    function setUp() public {
        weEthAddress = address(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe);
        weEthToEethChainlink = address(0x20bAe7e1De9c596f5F7615aeaa1342Ba99294e12);
        ethToUsdChainlink = address(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
        weEthToEethHeartbeat = 86_400;
        ethToUsdHeartbeat = 86_400;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new weETH_L2_CustomPriceFeed(
            address(0), weEthToEethChainlink, ethToUsdChainlink, weEthToEethHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new weETH_L2_CustomPriceFeed(
            weEthAddress, address(0), ethToUsdChainlink, weEthToEethHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new weETH_L2_CustomPriceFeed(
            weEthAddress, weEthToEethChainlink, address(0), weEthToEethHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new weETH_L2_CustomPriceFeed(weEthAddress, weEthToEethChainlink, ethToUsdChainlink, 0, ethToUsdHeartbeat);

        vm.expectRevert();
        new weETH_L2_CustomPriceFeed(weEthAddress, weEthToEethChainlink, ethToUsdChainlink, weEthToEethHeartbeat, 0);
    }
}
