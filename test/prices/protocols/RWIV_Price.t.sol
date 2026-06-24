// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {RWIV_PriceOracle} from "src/prices/protocols/RWIV_Price.sol";

/// @title RWIV_PriceOracle unit tests (no fork)
contract RWIV_PriceOracleTest is Test {
    address rwivAddress;
    address usdcToUsdChainlink;
    uint256 heartbeat;

    function setUp() public {
        rwivAddress = address(0xcAFeAA466736ac01e0AC9Ca72644beF348694731);
        usdcToUsdChainlink = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        heartbeat = 82_800;
    }

    function test_invalidConstructorArgs() public {
        vm.expectRevert();
        new RWIV_PriceOracle(address(0), usdcToUsdChainlink, heartbeat);

        vm.expectRevert();
        new RWIV_PriceOracle(rwivAddress, address(0), heartbeat);

        vm.expectRevert();
        new RWIV_PriceOracle(rwivAddress, usdcToUsdChainlink, 0);

        vm.expectRevert();
        new RWIV_PriceOracle(rwivAddress, rwivAddress, heartbeat);
    }
}
