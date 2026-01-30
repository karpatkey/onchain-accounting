// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Vm} from "forge-std/Vm.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {InvalidArguments} from "src/errors.sol";

/// @title BridgeEscrowTest
/// @notice Unit tests for BridgeEscrow success paths and view helpers
contract BridgeEscrowTest is BridgeEscrowTestBase {
    // ============ Initialize ============

    function test_initialize_setsAdminAndChainId() public view {
        assertTrue(
            bridgeEscrow.hasRole(bridgeEscrow.DEFAULT_ADMIN_ROLE(), admin), "Admin should have DEFAULT_ADMIN_ROLE"
        );
        assertEq(bridgeEscrow.chainId(), SOURCE_CHAIN_ID, "ChainId should be set");
        assertTrue(bridgeEscrow.isAuthorizedAccount(account), "Account should be authorized");
    }

    function test_initialize_authorizesInitialSafesAndAdapters() public view {
        assertTrue(bridgeEscrow.isAuthorizedAccount(account), "Initial account should be authorized");
        assertTrue(bridgeEscrow.isAuthorizedAdapter(address(mockAdapter)), "Mock adapter should be authorized");
    }

    // ============ depositAndBridge (ERC20) ============

    function test_depositAndBridge_erc20Success() public {
        uint256 amount = BRIDGE_AMOUNT;
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(mockAdapter));

        assertTrue(invoiceHash != bytes32(0), "Invoice hash should be non-zero");
        IBridgeEscrow.Invoice memory inv = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(inv.invoiceId != bytes32(0), true, "Invoice should exist");
        assertEq(uint256(inv.status), uint256(IBridgeEscrow.InvoiceStatus.BRIDGING), "Status should be BRIDGING");
        assertEq(inv.amount, amount, "Amount should match");
        assertEq(inv.account, account, "Account should match");
        assertEq(
            bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account), amount, "In-transit balance should match"
        );
    }

    function test_depositAndBridge_emitsInvoiceCreatedAndAssetsDeposited() public {
        uint256 amount = BRIDGE_AMOUNT;
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        vm.prank(account);
        vm.recordLogs();
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(mockAdapter));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertGe(entries.length, 2, "At least InvoiceCreated and AssetsDeposited");
        assertTrue(invoiceHash != bytes32(0), "Invoice hash emitted");
    }

    function test_depositAndBridge_updatesInTransitBalances() public {
        uint256 amount = BRIDGE_AMOUNT;
        _approveToken(address(usdc), address(bridgeEscrow), amount);

        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(mockAdapter));

        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account), amount, "Per-safe in-transit");
        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(usdc), address(0)), amount, "All-safes in-transit");
        (address[] memory assets, uint256[] memory amounts) = bridgeEscrow.getInTransitBalancesForAccount(account);
        assertEq(assets.length, 1, "One asset in transit");
        assertEq(assets[0], address(usdc), "Asset should be USDC");
        assertEq(amounts[0], amount, "Amount should match");
    }

    function test_depositAndBridge_nativeSuccess() public {
        uint256 amount = 1 ether;
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.stopPrank();
        vm.deal(account, amount);

        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge{value: amount}(DEST_CHAIN_ID, WETH_SYMBOL, amount, address(mockAdapter));

        assertTrue(invoiceHash != bytes32(0), "Invoice hash should be non-zero");
        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(0), account), amount, "In-transit native balance");
    }

    // ============ releaseByInvoiceId ============

    function test_releaseByInvoiceId_success() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destEscrow), 1000e6);

        uint256 balanceBefore = usdc.balanceOf(account);
        vm.prank(address(destMock));
        destEscrow.releaseByInvoiceId(messagePayload);
        assertEq(usdc.balanceOf(account), balanceBefore + 1000e6, "Account should receive tokens");
        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        assertTrue(destEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be completed");
    }

    // ============ cancelInvoice ============

    function test_cancelInvoice_success() public {
        uint256 amount = BRIDGE_AMOUNT;
        _approveToken(address(usdc), address(bridgeEscrow), amount);
        vm.prank(account);
        bytes32 invoiceHash = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, amount, address(mockAdapter));
        assertEq(usdc.balanceOf(address(bridgeEscrow)), amount, "Escrow should still hold tokens (mock does not pull)");

        vm.prank(manager);
        bridgeEscrow.cancelInvoice(invoiceHash);

        assertEq(usdc.balanceOf(account), INITIAL_BALANCE, "Account should get tokens back");
        IBridgeEscrow.Invoice memory inv = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(uint256(inv.status), uint256(IBridgeEscrow.InvoiceStatus.CANCELLED), "Status should be CANCELLED");
        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account), 0, "In-transit should be zero");
    }

    // ============ markInvoiceCompleted ============

    function test_markInvoiceCompleted_success() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        vm.prank(manager);
        bridgeEscrow.markInvoiceCompleted(_array(invoiceHash));

        IBridgeEscrow.Invoice memory inv = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(uint256(inv.status), uint256(IBridgeEscrow.InvoiceStatus.COMPLETED), "Status should be COMPLETED");
        assertTrue(bridgeEscrow.isInvoiceCompleted(invoiceHash), "Invoice should be completed");
        assertEq(bridgeEscrow.getInTransitBalanceForAsset(address(usdc), account), 0, "In-transit should be zero");
    }

    function test_markInvoiceCompleted_skipsNonExistentAndNonBridging() public {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("nonexistent");
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        hashes[1] = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
        hashes[2] = keccak256("also-nonexistent");

        vm.prank(manager);
        bridgeEscrow.markInvoiceCompleted(hashes);

        assertTrue(bridgeEscrow.isInvoiceCompleted(hashes[1]), "Valid invoice should be completed");
    }

    // ============ registerAsset / unregisterAsset ============

    function test_registerAsset_success() public {
        bytes6 symbol = "NEW   ";
        address token = address(new Mock_ERC20("NEW", 18));
        vm.prank(admin);
        bridgeEscrow.registerAsset(symbol, token);
        assertEq(bridgeEscrow.assetRegistry(symbol), token, "Asset should be registered");
        assertTrue(bridgeEscrow.registeredSymbols(symbol), "Symbol should be registered");
    }

    function test_unregisterAsset_success() public {
        vm.prank(admin);
        bridgeEscrow.unregisterAsset(DAI_SYMBOL);
        assertEq(bridgeEscrow.assetRegistry(DAI_SYMBOL), address(0), "Asset should be cleared");
        assertFalse(bridgeEscrow.registeredSymbols(DAI_SYMBOL), "Symbol should be unregistered");
    }

    // ============ Admin: authorize / revoke ============

    function test_authorizeAccount_success() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(admin);
        bridgeEscrow.authorizeAccount(newSafe);
        assertTrue(bridgeEscrow.isAuthorizedAccount(newSafe), "Account should be authorized");
    }

    function test_revokeAccount_success() public {
        vm.prank(admin);
        bridgeEscrow.revokeAccount(account);
        assertFalse(bridgeEscrow.isAuthorizedAccount(account), "Account should be revoked");
    }

    function test_authorizeAdapter_revertsForNonInterface() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        bridgeEscrow.authorizeAdapter(address(usdc));
    }

    function test_revokeAdapter_success() public {
        vm.prank(admin);
        bridgeEscrow.revokeAdapter(address(mockAdapter));
        assertFalse(bridgeEscrow.isAuthorizedAdapter(address(mockAdapter)), "Adapter should be revoked");
    }

    // ============ Pause / emergencyWithdraw ============

    function test_pauseAndUnpause() public {
        vm.prank(admin);
        bridgeEscrow.pause();
        assertTrue(bridgeEscrow.paused(), "Should be paused");
        vm.prank(admin);
        bridgeEscrow.unpause();
        assertFalse(bridgeEscrow.paused(), "Should be unpaused");
    }

    function test_emergencyWithdraw_success() public {
        usdc.mint(address(bridgeEscrow), 5000e6);
        vm.prank(admin);
        bridgeEscrow.pause();

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        bridgeEscrow.emergencyWithdraw(address(usdc), 5000e6, recipient);
        assertEq(usdc.balanceOf(recipient), 5000e6, "Recipient should receive tokens");
    }

    // ============ View functions ============

    function test_getInvoice_returnsStoredInvoice() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
        IBridgeEscrow.Invoice memory inv = bridgeEscrow.getInvoice(invoiceHash);
        assertEq(inv.amount, BRIDGE_AMOUNT, "Amount should match");
        assertEq(inv.account, account, "Safe should match");
        assertEq(inv.asset, address(usdc), "Asset should match");
    }

    function test_getActiveInvoices_returnsBridgingInvoices() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
        IBridgeEscrow.Invoice[] memory active = bridgeEscrow.getActiveInvoices(account);
        assertEq(active.length, 1, "One active invoice");
        assertEq(active[0].amount, BRIDGE_AMOUNT, "Amount should match");
    }

    function test_decodeInvoiceId_roundtrip() public view {
        bytes32 invoiceId = _generateInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL);
        (uint24 src, uint24 dest, address safe, bytes6 symbol) = bridgeEscrow.decodeInvoiceId(invoiceId);
        assertEq(src, SafeCast.toUint24(SOURCE_CHAIN_ID), "Source chain");
        assertEq(dest, SafeCast.toUint24(DEST_CHAIN_ID), "Dest chain");
        assertEq(safe, account, "Safe");
        assertEq(symbol, USDC_SYMBOL, "Symbol");
    }

    function test_validateInvoiceIdChecksum_valid() public view {
        bytes32 invoiceId = _generateInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL);
        uint256 amount = 1000e6;
        uint64 timestamp = uint64(block.timestamp);
        bytes24 checksum = _calculateChecksum(invoiceId, amount, timestamp);
        assertTrue(bridgeEscrow.validateInvoiceIdChecksum(invoiceId, amount, timestamp, checksum), "Valid checksum");
    }

    function test_validateInvoiceIdChecksum_invalid() public view {
        bytes32 invoiceId = _generateInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL);
        uint256 amount = 1000e6;
        uint64 timestamp = uint64(block.timestamp);
        bytes24 goodChecksum = _calculateChecksum(invoiceId, amount, timestamp);
        bytes24 badChecksum = bytes24(uint192(uint256(uint192(goodChecksum)) ^ 1));
        assertFalse(
            bridgeEscrow.validateInvoiceIdChecksum(invoiceId, amount, timestamp, badChecksum), "Invalid checksum"
        );
    }

    function test_getInvoicesCompletionStatus() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 h1 = bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
        vm.prank(manager);
        bridgeEscrow.markInvoiceCompleted(_array(h1));
        bytes32 h2 = keccak256("other");
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = h1;
        hashes[1] = h2;
        bool[] memory status = bridgeEscrow.getInvoicesCompletionStatus(hashes);
        assertEq(status.length, 2, "Two results");
        assertTrue(status[0], "First completed");
        assertFalse(status[1], "Second not completed");
    }
}
