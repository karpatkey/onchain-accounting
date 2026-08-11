// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {
    NotAuthorized,
    InvalidArguments,
    InvoiceNotFound,
    InvoiceAlreadyExists,
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

    // ============ recordDelivery reverts (ADR 0024) ============

    function test_RevertWhen_recordDelivery_callerNotAuthorizedAdapter() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload,) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destEscrow), 1000e6);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        destEscrow.recordDelivery(messagePayload);
    }

    /// @notice ADR 0024/0012 (H9): MANAGER can no longer record deliveries directly — only an authorized
    ///         adapter (after its provenance check) may. A MANAGER-direct call reverts NotAuthorized. Timing of
    ///         the payout to the account is what MANAGER controls, via {claim}, not the custody write.
    function test_RevertWhen_recordDelivery_callerIsManager() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload,) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destEscrow), 1000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        destEscrow.recordDelivery(messagePayload);
    }

    function test_RevertWhen_recordDelivery_invalidChecksum() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1000e6);
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000e6);
        data.checksum24 = bytes24(uint192(uint256(uint192(data.checksum24)) ^ 1)); // corrupt
        bytes memory badPayload = InvoiceDataLib.encode(data);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);

        vm.prank(address(destMock));
        vm.expectRevert(); // InvalidChecksum (before any funds are pulled)
        destEscrow.recordDelivery(badPayload);
    }

    function test_RevertWhen_recordDelivery_futureTimestamp() public {
        vm.chainId(uint256(DEST_CHAIN_ID));
        BridgeEscrow destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        MockBridgeAdapter destMock = _deployMockAdapterForEscrow(destEscrow);
        vm.prank(admin);
        destEscrow.authorizeAdapter(address(destMock));

        // Beyond the 1h skew tolerance so the timestamp check (not a funding failure) is the revert cause. The
        // adapter is fully funded + approved, so InvalidTimestamp is the ONLY reason recordDelivery can revert.
        uint64 futureTs = uint64(block.timestamp) + destEscrow.TIMESTAMP_SKEW_TOLERANCE() + 1;
        InvoiceDataLib.InvoiceData memory data = _createInvoiceDataWithTimestamp(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 1000e6, futureTs
        );
        bytes memory messagePayload = InvoiceDataLib.encode(data);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);

        vm.prank(address(destMock));
        // InvalidTimestamp(provided, current) — asserted with args so it cannot be masked by a funding revert.
        vm.expectRevert(
            abi.encodeWithSelector(IBridgeEscrow.InvalidTimestamp.selector, futureTs, uint64(block.timestamp))
        );
        destEscrow.recordDelivery(messagePayload);
    }

    /// @notice The adapter does not hold (nor approve) the delivered funds, so the escrow's pull reverts —
    ///         the escrow never records a delivery it was not actually funded for (I7).
    function test_RevertWhen_recordDelivery_insufficientBalance() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        vm.prank(address(destMock));
        vm.expectRevert(); // transferFrom pull reverts (adapter holds nothing)
        destEscrow.recordDelivery(messagePayload);
    }

    function test_RevertWhen_recordDelivery_whenPaused() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(admin);
        destEscrow.pause();
        vm.prank(address(destMock));
        vm.expectRevert();
        destEscrow.recordDelivery(messagePayload);
    }

    function test_RevertWhen_recordDelivery_replayAlreadyRecorded() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        // Fund enough for two attempts; the second must revert on the replay guard, not on a pull failure.
        usdc.mint(address(destMock), 2000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 2000e6);

        vm.prank(address(destMock));
        destEscrow.recordDelivery(messagePayload);

        vm.prank(address(destMock));
        vm.expectRevert(abi.encodeWithSelector(InvoiceAlreadyExists.selector));
        destEscrow.recordDelivery(messagePayload);
    }

    /// @notice A zero-amount native delivery must revert (symmetry with the ERC20 measured==0 revert), not write a
    ///         "completed" but permanently-unclaimable custody record. Regression for the native/ERC20 asymmetry.
    function test_RevertWhen_recordDelivery_zeroAmountNative() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1);
        // Register a native symbol on the destination escrow so the native branch is reachable.
        vm.prank(admin);
        destEscrow.registerAsset("ETH   ", address(0));

        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, bytes6("ETH   "), 0);
        bytes memory payload = InvoiceDataLib.encode(data);

        vm.prank(address(destMock));
        vm.expectRevert(abi.encodeWithSelector(InvalidArguments.selector));
        destEscrow.recordDelivery{value: 0}(payload);

        // No zombie record: the invoice is neither completed nor claimable.
        bytes32 invoiceHash = bytes32(uint256(uint192(data.checksum24)));
        assertFalse(destEscrow.isInvoiceCompleted(invoiceHash), "no completed flag written");
        (,, uint256 amount,,,) = destEscrow.destinationCustody(invoiceHash);
        assertEq(amount, 0, "no custody record written");
    }

    // ============ claim reverts (ADR 0024) ============

    function test_RevertWhen_claim_invoiceNotFound() public {
        (BridgeEscrow destEscrow,,) = _setupDestinationAndValidPayload(address(usdc), 1000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNotFound.selector));
        destEscrow.claim(keccak256("no-such-custody"));
    }

    function test_RevertWhen_claim_alreadyClaimed() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(messagePayload);

        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        vm.prank(manager);
        destEscrow.claim(invoiceHash);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IBridgeEscrow.AlreadyClaimed.selector));
        destEscrow.claim(invoiceHash);
    }

    function test_RevertWhen_claim_callerNotManager() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(messagePayload);

        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        // A non-MANAGER cannot claim (AccessControl gate).
        vm.prank(unauthorized);
        vm.expectRevert();
        destEscrow.claim(invoiceHash);

        // MANAGER can.
        vm.prank(manager);
        destEscrow.claim(invoiceHash);
        assertEq(usdc.balanceOf(account), INITIAL_BALANCE + 1000e6, "MANAGER claim pays the account");
    }

    function test_RevertWhen_claim_whenPaused() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(messagePayload);

        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(messagePayload).checksum24)));
        vm.prank(admin);
        destEscrow.pause();
        vm.prank(manager);
        vm.expectRevert();
        destEscrow.claim(invoiceHash);
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

    /// @notice Repointing a registered symbol to a different asset while the OLD asset still backs held custody
    ///         must revert — otherwise getHeldBalance* would enumerate the new asset and hide the old held funds.
    function test_RevertWhen_registerAsset_repointWithHeldCustody() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(messagePayload); // USDC held under "USDC"

        // Repoint "USDC" -> a different token while custody still holds the old USDC.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AssetHasActiveInvoices.selector, USDC_SYMBOL));
        destEscrow.registerAsset(USDC_SYMBOL, address(weth));
    }

    /// @notice Unregistering an asset that still backs destination held custody must revert — otherwise
    ///         getHeldBalance* (which enumerate registered symbols) would silently hide still-claimable funds.
    function test_RevertWhen_unregisterAsset_withHeldCustody() public {
        (BridgeEscrow destEscrow, bytes memory messagePayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(messagePayload);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AssetHasActiveInvoices.selector, USDC_SYMBOL));
        destEscrow.unregisterAsset(USDC_SYMBOL);
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

    /// @notice emergencyWithdraw is capped to the surplus over held custody: it cannot touch funds backing
    ///         destination custody records, and those records stay fully claimable after unpause (I1).
    function test_emergencyWithdraw_cannotTakeHeldCustody() public {
        (BridgeEscrow destEscrow, bytes memory payload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(payload); // 1000e6 now held

        vm.prank(admin);
        destEscrow.pause();

        // The held amount is not withdrawable (surplus over custody is 0).
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IBridgeEscrow.InsufficientBalance.selector, address(usdc), 1000e6, 0));
        destEscrow.emergencyWithdraw(address(usdc), 1000e6, account);

        // Stray/surplus funds ARE withdrawable.
        usdc.mint(address(destEscrow), 5e6);
        vm.prank(admin);
        destEscrow.emergencyWithdraw(address(usdc), 5e6, account);

        // Held custody survived intact and is claimable after unpause.
        vm.prank(admin);
        destEscrow.unpause();
        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(payload).checksum24)));
        vm.prank(manager);
        destEscrow.claim(invoiceHash);
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held cleared by claim");
    }
}
