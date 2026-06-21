// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {
    NotAuthorized,
    InvalidArguments,
    InvoiceNotFound,
    AssetHasActiveInvoices,
    AssetNotRegistered
} from "src/errors.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";

/// @title BridgeEscrow Error Tests
/// @notice Revert and authorization tests for BridgeEscrow
contract BridgeEscrowErrorTest is BridgeEscrowTestBase {
    // ============ depositAndBridge reverts ============

    function test_RevertWhen_depositAndBridge_callerNotAuthorizedSafe() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
    }

    function test_RevertWhen_depositAndBridge_adapterNotAuthorized() public {
        address unregisteredAdapter = makeAddr("unregisteredAdapter");
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, unregisteredAdapter);
    }

    function test_RevertWhen_depositAndBridge_amountZero() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, 0, address(mockAdapter));
    }

    function test_RevertWhen_depositAndBridge_sameChain() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        bridgeEscrow.depositAndBridge(SOURCE_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
    }

    function test_RevertWhen_depositAndBridge_assetNotRegistered() public {
        string memory unknownSymbol = "UNK";
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, unknownSymbol, BRIDGE_AMOUNT, address(mockAdapter));
    }

    function test_RevertWhen_depositAndBridge_whenPaused() public {
        vm.prank(admin);
        bridgeEscrow.pause();
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        vm.expectRevert();
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
    }

    function test_RevertWhen_depositAndBridge_nativeAmountMismatch() public {
        vm.startPrank(admin);
        bridgeEscrow.registerAsset(WETH_SYMBOL, address(0));
        vm.stopPrank();
        vm.deal(account, 2 ether);

        // ADR 0012: native msg.value must equal amount, else InvalidValue (fee-on-transfer safety path).
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IBridgeEscrow.InvalidValue.selector));
        bridgeEscrow.depositAndBridge{value: 0.5 ether}(DEST_CHAIN_ID, WETH_SYMBOL, 1 ether, address(mockAdapter));
    }

    // ============ releaseByInvoiceId reverts ============

    function test_RevertWhen_releaseByInvoiceId_callerNotAuthorizedAdapter() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload,) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destEscrow), 1000e6);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        destEscrow.releaseByInvoiceId(messagePayload);
    }

    /// @notice ADR 0012 (H9): MANAGER can no longer call releaseByInvoiceId directly — only an authorized
    ///         adapter (after its provenance check) may. A MANAGER-direct call reverts NotAuthorized.
    function test_RevertWhen_releaseByInvoiceId_callerIsManager() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload,) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destEscrow), 1000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        destEscrow.releaseByInvoiceId(messagePayload);
    }

    function test_RevertWhen_releaseByInvoiceId_invalidChecksum() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1000e6);
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000e6);
        data.checksum24 = bytes24(uint192(uint256(uint192(data.checksum24)) ^ 1)); // corrupt
        bytes memory badPayload = InvoiceDataLib.encode(data);
        usdc.mint(address(destEscrow), 1000e6);

        vm.prank(address(destMock));
        vm.expectRevert(); // InvalidChecksum
        destEscrow.releaseByInvoiceId(badPayload);
    }

    function test_RevertWhen_releaseByInvoiceId_futureTimestamp() public {
        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockBridgeAdapter destMock = _deployMockAdapterForEscrow(destEscrow);
        vm.prank(admin);
        destEscrow.authorizeAdapter(address(destMock));

        uint64 futureTs = uint64(block.timestamp + 1);
        InvoiceDataLib.InvoiceData memory data = _createInvoiceDataWithTimestamp(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000e6, futureTs
        );
        bytes memory messagePayload = InvoiceDataLib.encode(data);
        usdc.mint(address(destEscrow), 1000e6);

        vm.prank(address(destMock));
        vm.expectRevert(); // InvalidTimestamp
        destEscrow.releaseByInvoiceId(messagePayload);
    }

    function test_RevertWhen_releaseByInvoiceId_insufficientBalance() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        vm.prank(address(destMock));
        vm.expectRevert(); // InsufficientBalance
        destEscrow.releaseByInvoiceId(messagePayload);
    }

    function test_RevertWhen_releaseByInvoiceId_whenPaused() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destEscrow), 1000e6);
        vm.prank(admin);
        destEscrow.pause();
        vm.prank(address(destMock));
        vm.expectRevert();
        destEscrow.releaseByInvoiceId(messagePayload);
    }

    // ============ cancelInvoice reverts ============

    function test_RevertWhen_cancelInvoice_notManager() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        vm.prank(unauthorized);
        vm.expectRevert();
        bridgeEscrow.cancelInvoice(invoiceHash);
    }

    function test_RevertWhen_cancelInvoice_invoiceNotFound() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNotFound.selector));
        bridgeEscrow.cancelInvoice(keccak256("nonexistent"));
    }

    // ============ markInvoiceCompleted reverts ============

    function test_RevertWhen_markInvoiceCompleted_notManager() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        vm.prank(unauthorized);
        vm.expectRevert();
        bridgeEscrow.markInvoiceCompleted(_array(invoiceHash));
    }

    // ============ registerAsset / unregisterAsset reverts ============

    function test_RevertWhen_registerAsset_notManager() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        bridgeEscrow.registerAsset("NEW   ", makeAddr("token"));
    }

    function test_RevertWhen_unregisterAsset_notManager() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        bridgeEscrow.unregisterAsset(DAI_SYMBOL);
    }

    function test_RevertWhen_unregisterAsset_notRegistered() public {
        string memory unknownSymbol = "FAKE";
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AssetNotRegistered.selector, unknownSymbol));
        bridgeEscrow.unregisterAsset(unknownSymbol);
    }

    function test_RevertWhen_unregisterAsset_hasActiveInvoices() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AssetHasActiveInvoices.selector, USDC_SYMBOL));
        bridgeEscrow.unregisterAsset(USDC_SYMBOL);
    }

    // ============ emergencyWithdraw reverts ============

    function test_RevertWhen_emergencyWithdraw_notPaused() public {
        vm.prank(admin);
        vm.expectRevert();
        bridgeEscrow.emergencyWithdraw(address(usdc), 1, makeAddr("r"));
    }

    function test_RevertWhen_emergencyWithdraw_notAdmin() public {
        vm.prank(admin);
        bridgeEscrow.pause();
        vm.prank(unauthorized);
        vm.expectRevert();
        bridgeEscrow.emergencyWithdraw(address(usdc), 1, makeAddr("r"));
    }
}
