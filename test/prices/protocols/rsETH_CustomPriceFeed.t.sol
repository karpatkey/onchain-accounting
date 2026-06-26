// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {rsETH_CustomPriceFeed} from "src/prices/protocols/rsETH_CustomPriceFeed.sol";

/// @title rsETH_CustomPriceFeed unit tests (no fork)
contract rsETH_CustomPriceFeedTest is Test {
    address rsEthAddress;
    address rateProvider;
    address ethToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        rsEthAddress = address(0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7);
        rateProvider = address(0x0788906B19bA8f8d0e8a7015f0714DF3179D9aB6);
        ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        heartbeat = 3600;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new rsETH_CustomPriceFeed(address(0), rateProvider, ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new rsETH_CustomPriceFeed(rsEthAddress, address(0), ethToUsdChainlink, heartbeat);

        vm.expectRevert();
        new rsETH_CustomPriceFeed(rsEthAddress, rateProvider, address(0), heartbeat);

        vm.expectRevert();
        new rsETH_CustomPriceFeed(rsEthAddress, rateProvider, ethToUsdChainlink, 0);

        vm.expectRevert();
        new rsETH_CustomPriceFeed(rsEthAddress, rateProvider, rsEthAddress, heartbeat);
    }
}
