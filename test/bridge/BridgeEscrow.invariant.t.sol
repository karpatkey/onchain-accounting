// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";

/// @title BridgeEscrow Invariant Tests
/// @notice Critical invariants for BridgeEscrow accounting and state
contract BridgeEscrowInvariantTest is BridgeEscrowTestBase {
    /// @notice After depositAndBridge, in-transit for safe equals in-transit for address(0) when only one safe has deposits
    function test_invariant_singleSafeInTransitConsistency() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        uint256 perSafe = bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account);
        uint256 allSafes = bridgeEscrow.getInTransitBalanceForAsset(address(usdc), address(0));
        assertEq(perSafe, allSafes, "Single safe: per-safe in-transit should equal all-safes in-transit");
    }

    /// @notice After cancelInvoice, in-transit for that asset/safe is decremented
    function test_invariant_cancelInvoiceClearsInTransit() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account), BRIDGE_AMOUNT, "In-transit set");

        vm.prank(manager);
        bridgeEscrow.cancelInvoice(invoiceHash);

        assertEq(
            bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account),
            0,
            "In-transit should be zero after cancel"
        );
    }

    /// @notice After markInvoiceCompleted, in-transit is decremented and isInvoiceCompleted is true
    function test_invariant_markCompletedClearsInTransit() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        vm.prank(manager);
        bridgeEscrow.markInvoiceCompleted(_array(invoiceHash));

        assertTrue(bridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be completed");
        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account), 0, "In-transit should be zero");
    }
}
