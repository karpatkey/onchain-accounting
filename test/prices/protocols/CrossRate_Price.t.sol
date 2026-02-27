// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {CrossRatePriceAdapter} from "src/prices/protocols/CrossRate_Price.sol";

/// @title CrossRatePriceAdapter unit tests (no fork)
contract CrossRate_PriceOracleTest is Test {
    address underlyingAsset;
    address xToUsdFeed;
    address yToXFeed;
    uint256 constant HEARTBEAT = 86400;

    function setUp() public {
        underlyingAsset = address(0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6); // wstETH example
        xToUsdFeed = address(0xa767f745331D267c7751297D982b050c93985627); // ETH/USD
        yToXFeed = address(0x0064AC007fF665CF8D0D3Af5E0AD1c26a3f853eA); // wstETH/ETH
    }

    function test_invalidConstructorArgs_zeroUnderlying() public {
        vm.expectRevert();
        new CrossRatePriceAdapter(address(0), xToUsdFeed, yToXFeed, HEARTBEAT, HEARTBEAT);
    }

    function test_invalidConstructorArgs_zeroXToUsdFeed() public {
        vm.expectRevert();
        new CrossRatePriceAdapter(underlyingAsset, address(0), yToXFeed, HEARTBEAT, HEARTBEAT);
    }

    function test_invalidConstructorArgs_zeroYToXFeed() public {
        vm.expectRevert();
        new CrossRatePriceAdapter(underlyingAsset, xToUsdFeed, address(0), HEARTBEAT, HEARTBEAT);
    }

    function test_invalidConstructorArgs_zeroXToUsdHeartbeat() public {
        vm.expectRevert();
        new CrossRatePriceAdapter(underlyingAsset, xToUsdFeed, yToXFeed, 0, HEARTBEAT);
    }

    function test_invalidConstructorArgs_zeroYToXHeartbeat() public {
        vm.expectRevert();
        new CrossRatePriceAdapter(underlyingAsset, xToUsdFeed, yToXFeed, HEARTBEAT, 0);
    }
}
