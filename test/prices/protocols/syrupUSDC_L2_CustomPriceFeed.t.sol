// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {syrupUSDC_L2_CustomPriceFeed} from "src/prices/protocols/syrupUSDC_L2_CustomPriceFeed.sol";

/// @title syrupUSDC_L2_CustomPriceFeed unit tests (no fork)
contract syrupUSDC_L2_CustomPriceFeedTest is Test {
    address syrupUsdcAddress;
    address syrupUsdcToUsdcChainlink;
    address usdcToUsdChainlink;
    uint256 syrupUsdcToUsdcHeartbeat;
    uint256 usdcToUsdHeartbeat;

    function setUp() public {
        syrupUsdcAddress = address(0x41CA7586cC1311807B4605fBB748a3B8862b42b5);
        syrupUsdcToUsdcChainlink = address(0xF8722c901675C4F2F7824E256B8A6477b2c105FB);
        usdcToUsdChainlink = address(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3);
        syrupUsdcToUsdcHeartbeat = 86_400;
        usdcToUsdHeartbeat = 86_400;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(
            address(0), syrupUsdcToUsdcChainlink, usdcToUsdChainlink, syrupUsdcToUsdcHeartbeat, usdcToUsdHeartbeat
        );

        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(
            syrupUsdcAddress, address(0), usdcToUsdChainlink, syrupUsdcToUsdcHeartbeat, usdcToUsdHeartbeat
        );

        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(
            syrupUsdcAddress, syrupUsdcToUsdcChainlink, address(0), syrupUsdcToUsdcHeartbeat, usdcToUsdHeartbeat
        );

        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(
            syrupUsdcAddress, syrupUsdcToUsdcChainlink, usdcToUsdChainlink, 0, usdcToUsdHeartbeat
        );

        vm.expectRevert();
        new syrupUSDC_L2_CustomPriceFeed(
            syrupUsdcAddress, syrupUsdcToUsdcChainlink, usdcToUsdChainlink, syrupUsdcToUsdcHeartbeat, 0
        );
    }
}
