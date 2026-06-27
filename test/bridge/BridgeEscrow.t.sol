// SPDX-License-Identifier: BUSL-1.1
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
        // Funded pass-through (ADR 0012): the escrow pulls the amount from the calling adapter, which holds
        // the delivered funds and approves the escrow. It is never paid from the escrow's standing balance.
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);

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

    function test_registeredAssets_initialState() public view {
        (string[] memory symbols, address[] memory assets) = bridgeEscrow.registeredAssets();
        assertEq(symbols.length, 3, "Setup registers USDC, WETH, DAI");
        assertEq(assets.length, 3, "Same length as symbols");
        (bool hasUsdc,) = _findSymbolString(symbols, USDC_SYMBOL);
        (bool hasWeth,) = _findSymbolString(symbols, WETH_SYMBOL);
        (bool hasDai,) = _findSymbolString(symbols, DAI_SYMBOL);
        assertTrue(hasUsdc && hasWeth && hasDai, "All setup symbols present");
        assertEq(bridgeEscrow.assetRegistry(USDC_SYMBOL), address(usdc), "USDC mapping");
        assertEq(bridgeEscrow.assetRegistry(WETH_SYMBOL), address(weth), "WETH mapping");
        assertEq(bridgeEscrow.assetRegistry(DAI_SYMBOL), address(dai), "DAI mapping");
    }

    function test_registerAsset_success() public {
        string memory symbol = "NEW";
        address token = address(new Mock_ERC20("NEW", 18));
        bytes6 expectedSym = InvoiceDataLib.strToBytes6(symbol);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IBridgeEscrow.AssetRegistered(expectedSym, token);
        bridgeEscrow.registerAsset(symbol, token);
        assertEq(bridgeEscrow.assetRegistry(symbol), token, "Asset should be registered");
        (string[] memory symbols, address[] memory assets) = bridgeEscrow.registeredAssets();
        assertEq(symbols.length, 4, "One more than initial");
        (bool found, uint256 idx) = _findSymbolString(symbols, symbol);
        assertTrue(found, "Symbol should be in registeredAssets");
        assertEq(assets[idx], token, "Asset address should match");
    }

    function test_registerAsset_nativeWithAddressZero() public {
        string memory symbol = "NATIVE";
        bytes6 expectedSym = InvoiceDataLib.strToBytes6(symbol);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IBridgeEscrow.AssetRegistered(expectedSym, address(0));
        bridgeEscrow.registerAsset(symbol, address(0));
        assertEq(bridgeEscrow.assetRegistry(symbol), address(0), "Native registered as zero address");
        (string[] memory symbols, address[] memory assets) = bridgeEscrow.registeredAssets();
        (bool found, uint256 idx) = _findSymbolString(symbols, symbol);
        assertTrue(found, "Native symbol in registeredAssets");
        assertEq(assets[idx], address(0), "Native asset is address(0)");
    }

    function test_registerAsset_revertsWhenSymbolTooLong() public {
        address token = address(new Mock_ERC20("LONG", 18));
        vm.prank(admin);
        vm.expectRevert(InvoiceDataLib.SymbolTooLong.selector);
        bridgeEscrow.registerAsset("SEVENCH", token); // 7 characters
    }

    function test_registerAsset_returnsSameSymbolAsInput() public {
        string memory symbol = "XYZ";
        address token = address(new Mock_ERC20("XYZ", 18));
        vm.prank(admin);
        bridgeEscrow.registerAsset(symbol, token);

        (string[] memory symbols,) = bridgeEscrow.registeredAssets();
        (bool found, uint256 idx) = _findSymbolString(symbols, symbol);
        assertTrue(found, "Symbol should be in registeredAssets");
        assertEq(symbols[idx], symbol, "Registered asset should return the same symbol as input");
        assertEq(bridgeEscrow.assetRegistry(symbol), token, "assetRegistry(symbol) should return registered token");
    }

    function test_registerAsset_updateExistingSymbol() public {
        address newToken = address(new Mock_ERC20("USDC2", 6));
        vm.prank(admin);
        bridgeEscrow.registerAsset(USDC_SYMBOL, newToken);
        assertEq(bridgeEscrow.assetRegistry(USDC_SYMBOL), newToken, "Registry updated");
        (string[] memory symbols, address[] memory assets) = bridgeEscrow.registeredAssets();
        assertEq(symbols.length, 3, "No duplicate entry; same symbol count");
        assertEq(assets[_findSymbolStringIndex(symbols, USDC_SYMBOL)], newToken, "registeredAssets shows new address");
    }

    function test_unregisterAsset_success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IBridgeEscrow.AssetUnregistered(DAI_SYMBOL_BYTES6);
        bridgeEscrow.unregisterAsset(DAI_SYMBOL);
        assertEq(bridgeEscrow.assetRegistry(DAI_SYMBOL), address(0), "Asset should be cleared");
        (string[] memory symbols,) = bridgeEscrow.registeredAssets();
        assertEq(symbols.length, 2, "One fewer than initial");
        (bool found,) = _findSymbolString(symbols, DAI_SYMBOL);
        assertFalse(found, "Symbol should not be in registeredAssets");
    }

    function test_unregisterAsset_registeredAssetsLengthAndContent() public {
        (string[] memory beforeSym,) = bridgeEscrow.registeredAssets();
        assertEq(beforeSym.length, 3, "Initial count");
        vm.prank(admin);
        bridgeEscrow.unregisterAsset(WETH_SYMBOL);
        (string[] memory afterSym, address[] memory afterAssets) = bridgeEscrow.registeredAssets();
        assertEq(afterSym.length, 2, "Count after unregister");
        assertEq(afterAssets.length, 2, "Assets length matches symbols");
        (bool hasWeth,) = _findSymbolString(afterSym, WETH_SYMBOL);
        assertFalse(hasWeth, "WETH removed from list");
    }

    function _findSymbolString(string[] memory symbols, string memory symbolStr)
        internal
        pure
        returns (bool found, uint256 index)
    {
        for (uint256 i; i < symbols.length; i++) {
            if (keccak256(abi.encodePacked(symbols[i])) == keccak256(abi.encodePacked(symbolStr))) return (true, i);
        }
        return (false, 0);
    }

    function _findSymbolStringIndex(string[] memory symbols, string memory symbolStr) internal pure returns (uint256) {
        (, uint256 index) = _findSymbolString(symbols, symbolStr);
        return index;
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

    /// @notice Audit M-10b: revoking an adapter with in-flight (BRIDGING) invoices it dispatched must revert,
    ///         symmetric with `revokeAccount`'s active-invoice guard.
    function test_revokeAdapter_revertsWithActiveInvoices() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IBridgeEscrow.AdapterHasActiveInvoices.selector, address(mockAdapter)));
        bridgeEscrow.revokeAdapter(address(mockAdapter));
        assertTrue(bridgeEscrow.isAuthorizedAdapter(address(mockAdapter)), "Adapter should still be authorized");
    }

    /// @notice Audit M-10b: once the in-flight invoice settles, the adapter can be revoked.
    function test_revokeAdapter_succeedsAfterInvoiceCompleted() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = invoiceHash;
        vm.prank(admin);
        bridgeEscrow.markInvoiceCompleted(hashes);

        vm.prank(admin);
        bridgeEscrow.revokeAdapter(address(mockAdapter));
        assertFalse(bridgeEscrow.isAuthorizedAdapter(address(mockAdapter)), "Adapter should be revoked");
    }

    /// @notice Audit M-12: `depositAndBridge` resets the adapter's ERC20 allowance to 0 after dispatch, so no
    ///         standing approval survives the call (MockBridgeAdapter._bridge is a no-op and pulls nothing).
    function test_depositAndBridge_resetsAdapterAllowance() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
        assertEq(usdc.allowance(address(bridgeEscrow), address(mockAdapter)), 0, "Adapter allowance must be reset to 0");
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

        // ADR 0012 (H10): emergencyWithdraw recipient MUST be an authorized account.
        address recipient = makeAddr("recipient");
        vm.startPrank(admin);
        bridgeEscrow.authorizeAccount(recipient);
        bridgeEscrow.pause();
        bridgeEscrow.emergencyWithdraw(address(usdc), 5000e6, recipient);
        vm.stopPrank();
        assertEq(usdc.balanceOf(recipient), 5000e6, "Recipient should receive tokens");
    }

    /// @notice ADR 0012 (H10): emergencyWithdraw to a non-authorized recipient reverts NotAuthorized.
    function test_RevertWhen_emergencyWithdraw_recipientNotAuthorized() public {
        usdc.mint(address(bridgeEscrow), 5000e6);
        vm.startPrank(admin);
        bridgeEscrow.pause();
        vm.expectRevert();
        bridgeEscrow.emergencyWithdraw(address(usdc), 5000e6, makeAddr("notAuthorized"));
        vm.stopPrank();
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
        bytes32 invoiceId = _generateInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6);
        (uint24 src, uint24 dest, address safe, string memory symbol) = bridgeEscrow.decodeInvoiceId(invoiceId);
        assertEq(src, SafeCast.toUint24(SOURCE_CHAIN_ID), "Source chain");
        assertEq(dest, SafeCast.toUint24(DEST_CHAIN_ID), "Dest chain");
        assertEq(safe, account, "Safe");
        assertEq(symbol, USDC_SYMBOL, "Symbol");
    }

    function test_validateInvoiceIdChecksum_valid() public view {
        bytes32 invoiceId = _generateInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6);
        uint256 amount = 1000e6;
        uint64 timestamp = uint64(block.timestamp);
        uint256 nonce = 0;
        bytes24 checksum = _calculateChecksum(invoiceId, amount, timestamp, nonce);
        assertTrue(
            bridgeEscrow.validateInvoiceIdChecksum(invoiceId, amount, timestamp, nonce, checksum), "Valid checksum"
        );
    }

    function test_validateInvoiceIdChecksum_invalid() public view {
        bytes32 invoiceId = _generateInvoiceId(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6);
        uint256 amount = 1000e6;
        uint64 timestamp = uint64(block.timestamp);
        uint256 nonce = 0;
        bytes24 goodChecksum = _calculateChecksum(invoiceId, amount, timestamp, nonce);
        bytes24 badChecksum = bytes24(uint192(uint256(uint192(goodChecksum)) ^ 1));
        assertFalse(
            bridgeEscrow.validateInvoiceIdChecksum(invoiceId, amount, timestamp, nonce, badChecksum), "Invalid checksum"
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
