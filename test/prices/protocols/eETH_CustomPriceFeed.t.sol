// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {eETH_CustomPriceFeed} from "src/prices/protocols/eETH_CustomPriceFeed.sol";

/// @title eETH_CustomPriceFeed unit tests (no fork)
contract eETH_CustomPriceFeedTest is Test {
    address eEthAddress;
    address weEthAddress;
    address weEthToEthChainlink;
    address ethToUsdChainlink;
    uint256 weEthToEthHeartbeat;
    uint256 ethToUsdHeartbeat;

    function setUp() public {
        eEthAddress = address(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
        weEthAddress = address(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
        weEthToEthChainlink = address(0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        weEthToEthHeartbeat = 86_400;
        ethToUsdHeartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new eETH_CustomPriceFeed(
            address(0), weEthAddress, weEthToEthChainlink, ethToUsdChainlink, weEthToEthHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new eETH_CustomPriceFeed(
            eEthAddress, address(0), weEthToEthChainlink, ethToUsdChainlink, weEthToEthHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new eETH_CustomPriceFeed(
            eEthAddress, weEthAddress, address(0), ethToUsdChainlink, weEthToEthHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new eETH_CustomPriceFeed(
            eEthAddress, weEthAddress, weEthToEthChainlink, address(0), weEthToEthHeartbeat, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new eETH_CustomPriceFeed(
            eEthAddress, weEthAddress, weEthToEthChainlink, ethToUsdChainlink, 0, ethToUsdHeartbeat
        );

        vm.expectRevert();
        new eETH_CustomPriceFeed(
            eEthAddress, weEthAddress, weEthToEthChainlink, ethToUsdChainlink, weEthToEthHeartbeat, 0
        );

        vm.expectRevert();
        new eETH_CustomPriceFeed(
            eEthAddress, weEthAddress, weEthAddress, ethToUsdChainlink, weEthToEthHeartbeat, ethToUsdHeartbeat
        );
    }
}
