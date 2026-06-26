// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";

/// @title BridgeEscrow Fuzz Tests
/// @notice Property-based fuzz tests for BridgeEscrow
contract BridgeEscrowFuzzTest is BridgeEscrowTestBase {
    function testFuzz_depositAndBridge_erc20Amount(uint96 amount) public {
        amount = uint96(bound(amount, 1, INITIAL_BALANCE));
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(mockAdapter));
        assertTrue(invoiceHash != bytes32(0), "Invoice hash non-zero");
        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account), amount, "In-transit matches");
    }

    function testFuzz_getInTransitBalanceForAsset_consistency(uint96 amount) public {
        amount = uint96(bound(amount, 1, INITIAL_BALANCE));
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(mockAdapter));
        uint256 perSafe = bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account);
        uint256 allSafes = bridgeEscrow.getInTransitBalanceForAsset(address(usdc), address(0));
        assertEq(perSafe, allSafes, "Per-safe and all-safes in-transit should match when one safe");
        assertEq(perSafe, amount, "Amount should match");
    }
}
