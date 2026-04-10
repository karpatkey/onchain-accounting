// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {syrupUSDC_PriceOracle} from "src/prices/protocols/syrupUSDC_Price.sol";

/// @title syrupUSDC_PriceOracle unit tests (no fork)
contract syrupUSDC_PriceOracleTest is Test {
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
        new syrupUSDC_PriceOracle(address(0), usdcToUsdChainlink, heartbeat);

        vm.expectRevert();
        new syrupUSDC_PriceOracle(syrupUsdcAddress, address(0), heartbeat);

        vm.expectRevert();
        new syrupUSDC_PriceOracle(syrupUsdcAddress, usdcToUsdChainlink, 0);

        vm.expectRevert();
        new syrupUSDC_PriceOracle(syrupUsdcAddress, syrupUsdcAddress, heartbeat);
    }
}
