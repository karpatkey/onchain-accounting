// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {syrupUSDC_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_CustomPriceFeed.sol";

/// @title syrupUSDC_CustomPriceFeed unit tests (no fork)
contract syrupUSDC_CustomPriceFeedTest is Test {
    address syrupUsdcAddress;
    address usdcToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        syrupUsdcAddress = address(0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b);
        usdcToUsdChainlink = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        heartbeat = 82_800;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(address(0), usdcToUsdChainlink, heartbeat);

        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(syrupUsdcAddress, address(0), heartbeat);

        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(syrupUsdcAddress, usdcToUsdChainlink, 0);

        vm.expectRevert();
        new syrupUSDC_CustomPriceFeed(syrupUsdcAddress, syrupUsdcAddress, heartbeat);
    }
}
