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
    AssetNotRegistered,
    TransferFailed
} from "src/errors.sol";
import {IBridgeEscrow} from "src/bridge/IBridgeEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

    /// @notice cancelInvoice must not refund a source invoice out of funds backing destination held custody:
    ///         the two fund pools share one escrow balance, so the refund is capped to the surplus over
    ///         _heldClaimable (I1). Regression for the hold-then-claim commingling.
    function test_cancelInvoice_cannotDrainHeldCustody() public {
        (BridgeEscrow destEscrow, bytes memory heldPayload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 100e6);
        // Destination custody: 100 USDC held for `account`.
        usdc.mint(address(destMock), 100e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 100e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(heldPayload);

        // Source-side BRIDGING invoice A (50 USDC) on the same escrow.
        usdc.mint(account, 50e6);
        vm.prank(account);
        usdc.approve(address(destEscrow), 50e6);
        vm.prank(account);
        bytes32 invoiceA = destEscrow.depositAndBridge(SOURCE_CHAIN_ID, USDC_SYMBOL, 50e6, address(destMock));

        // Simulate A's funds having left the escrow to the bridge: force the balance back to exactly the held
        // amount. Now only custody funds remain.
        deal(address(usdc), address(destEscrow), 100e6);

        // cancelInvoice(A) must revert rather than pay A out of B's custody (available surplus = 100 - 100 = 0).
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IBridgeEscrow.InsufficientBalance.selector, address(usdc), 50e6, 0));
        destEscrow.cancelInvoice(invoiceA);

        // Held custody is intact and still claimable.
        bytes32 heldHash = bytes32(uint256(uint192(InvoiceDataLib.decode(heldPayload).checksum24)));
        vm.prank(manager);
        destEscrow.claim(heldHash);
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held cleared by claim");
    }

    /// @notice Batch claim settles multiple records: each recorded amount is paid to the recorded account and the
    ///         held aggregates are decremented per record.
    function test_claimBatch_settlesMultipleRecords() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1);

        bytes memory p1 = InvoiceDataLib.encode(
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 100e6)
        );
        bytes memory p2 = InvoiceDataLib.encode(
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, USDC_SYMBOL_BYTES6, 200e6)
        );
        usdc.mint(address(destMock), 300e6);
        vm.startPrank(address(destMock));
        usdc.approve(address(destEscrow), 300e6);
        destEscrow.recordDelivery(p1);
        destEscrow.recordDelivery(p2);
        vm.stopPrank();

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = bytes32(uint256(uint192(InvoiceDataLib.decode(p1).checksum24)));
        hashes[1] = bytes32(uint256(uint192(InvoiceDataLib.decode(p2).checksum24)));

        uint256 before = usdc.balanceOf(account);
        vm.prank(manager);
        destEscrow.claim(hashes);

        assertEq(usdc.balanceOf(account) - before, 300e6, "both records paid");
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), 0, "held fully cleared");
    }

    /// @notice Batch claim is strict/all-or-nothing: one bad hash reverts the whole batch and moves no funds.
    function test_RevertWhen_claimBatch_atomicOnBadHash() public {
        (BridgeEscrow destEscrow, bytes memory payload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 100e6);
        usdc.mint(address(destMock), 100e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 100e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(payload);
        bytes32 good = bytes32(uint256(uint192(InvoiceDataLib.decode(payload).checksum24)));

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = good;
        hashes[1] = keccak256("no-such-custody");

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvoiceNotFound.selector));
        destEscrow.claim(hashes);

        // The good record was NOT settled — the whole batch reverted.
        assertEq(destEscrow.getHeldBalanceForAsset(address(usdc), account), 100e6, "no partial settlement");
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

    /// @notice cancelInvoice is whenNotPaused: like the other fund-moving entrypoints, a pause freezes it
    ///         (emergencyWithdraw remains the paused break-glass).
    function test_RevertWhen_cancelInvoice_whenPaused() public {
        _approveToken(address(usdc), address(bridgeEscrow), BRIDGE_AMOUNT);
        vm.prank(account);
        bytes32 invoiceHash =
            bridgeEscrow.depositAndBridge(DEST_CHAIN_ID, USDC_SYMBOL, BRIDGE_AMOUNT, address(mockAdapter));
        vm.prank(admin);
        bridgeEscrow.pause();
        vm.prank(manager);
        vm.expectRevert(); // EnforcedPause
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

    /// @notice The emergencyWithdraw surplus cap must protect native custody keyed under the ERC-7528 sentinel,
    ///         not just the address(0) bucket (both are valid native registrations).
    function test_emergencyWithdraw_nativeHeldUnderSentinel_isProtected() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1);
        address sentinel = destEscrow.NATIVE_ADDRESS_ERC7528();
        vm.prank(manager);
        destEscrow.registerAsset("ETH   ", sentinel);

        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, bytes6("ETH   "), 1 ether);
        bytes memory payload = InvoiceDataLib.encode(data);
        vm.deal(address(destMock), 1 ether);
        vm.prank(address(destMock));
        destEscrow.recordDelivery{value: 1 ether}(payload); // held under _heldClaimable[sentinel]

        vm.prank(admin);
        destEscrow.pause();
        // Surplus over native custody is 0 even though the held bucket is the sentinel, not address(0).
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IBridgeEscrow.InsufficientBalance.selector, address(0), 1 ether, 0));
        destEscrow.emergencyWithdraw(address(0), 1 ether, account);
    }

    /// F2 (audit): the aggregate (account==0) getHeldBalanceForAsset must sum BOTH native keys, matching
    /// _heldClaimableFor and BridgeHeldBalanceAdapter's point getter. Native held under address(0) must be
    /// visible when the aggregate is queried via the ERC-7528 sentinel too. Before the fix the sentinel query
    /// returned _heldClaimable[sentinel] == 0, silently under-reporting aggregate native held custody.
    function test_getHeldBalanceForAsset_aggregateNative_sumsBothKeys() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1);
        address sentinel = destEscrow.NATIVE_ADDRESS_ERC7528();
        vm.prank(admin);
        destEscrow.registerAsset("ETH   ", address(0)); // native keyed under address(0)

        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, bytes6("ETH   "), 1 ether);
        bytes memory payload = InvoiceDataLib.encode(data);
        vm.deal(address(destMock), 1 ether);
        vm.prank(address(destMock));
        destEscrow.recordDelivery{value: 1 ether}(payload); // held under _heldClaimable[address(0)]

        // Aggregate (account == address(0)) via EITHER native key returns the full held native custody.
        assertEq(destEscrow.getHeldBalanceForAsset(address(0), address(0)), 1 ether, "aggregate via address(0)");
        assertEq(
            destEscrow.getHeldBalanceForAsset(sentinel, address(0)), 1 ether, "aggregate via sentinel sums both keys"
        );
    }

    /// @notice Two symbols aliasing one token must not double-count held custody in getHeldBalancesForAccount.
    function test_getHeldBalancesForAccount_dedupesAliasedSymbols() public {
        (BridgeEscrow destEscrow, bytes memory payload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        vm.prank(manager);
        destEscrow.registerAsset("USDC2 ", address(usdc)); // second symbol -> same token

        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(payload);

        (address[] memory assets, uint256[] memory amounts) = destEscrow.getHeldBalancesForAccount(account);
        uint256 usdcCount;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == address(usdc)) {
                usdcCount++;
                assertEq(amounts[i], 1000e6, "held amount");
            }
        }
        assertEq(usdcCount, 1, "aliased token deduped to a single entry");
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

    // ============ revokeAccount + held custody (ADR 0024) ============

    /// @notice revokeAccount must be blocked while the account still has outstanding destination held custody,
    ///         and succeed once the custody is claimed. Mirrors the register/unregister held-custody guards.
    function test_RevertWhen_revokeAccount_withHeldCustody() public {
        (BridgeEscrow destEscrow, bytes memory payload, MockBridgeAdapter destMock) =
            _setupDestinationAndValidPayload(address(usdc), 1000e6);
        usdc.mint(address(destMock), 1000e6);
        vm.prank(address(destMock));
        usdc.approve(address(destEscrow), 1000e6);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(payload);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IBridgeEscrow.AccountHasActiveInvoices.selector, account));
        destEscrow.revokeAccount(account);

        // Once claimed, the account can be revoked.
        bytes32 h = bytes32(uint256(uint192(InvoiceDataLib.decode(payload).checksum24)));
        vm.prank(manager);
        destEscrow.claim(h);
        vm.prank(admin);
        destEscrow.revokeAccount(account); // no revert
        assertFalse(destEscrow.isAuthorizedAccount(account), "revoked after settlement");
    }

    // ============ native + fee-on-transfer record/claim (ADR 0024) ============

    /// @notice Native record → claim happy path: msg.value is held under address(0) and paid to the account.
    function test_recordAndClaim_native_happyPath() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1);
        vm.prank(manager);
        destEscrow.registerAsset("ETH   ", address(0));

        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, bytes6("ETH   "), 3 ether);
        bytes memory payload = InvoiceDataLib.encode(data);
        vm.deal(address(destMock), 3 ether);
        vm.prank(address(destMock));
        destEscrow.recordDelivery{value: 3 ether}(payload);
        assertEq(destEscrow.getHeldBalanceForAsset(address(0), account), 3 ether, "native held");

        uint256 balBefore = account.balance;
        vm.prank(manager);
        destEscrow.claim(bytes32(uint256(uint192(data.checksum24))));
        assertEq(account.balance - balBefore, 3 ether, "native paid to account");
        assertEq(destEscrow.getHeldBalanceForAsset(address(0), account), 0, "native held cleared");
    }

    /// @notice A native claim to a recipient that rejects ETH reverts, and the effects roll back so the record
    ///         stays claimable (no funds lost, no half-updated state).
    function test_RevertWhen_claim_nativeToRejectingAccount() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1);
        RejectEther rejecter = new RejectEther();
        vm.prank(admin);
        destEscrow.authorizeAccount(address(rejecter));
        vm.prank(manager);
        destEscrow.registerAsset("ETH   ", address(0));

        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, address(rejecter), bytes6("ETH   "), 1 ether);
        bytes memory payload = InvoiceDataLib.encode(data);
        vm.deal(address(destMock), 1 ether);
        vm.prank(address(destMock));
        destEscrow.recordDelivery{value: 1 ether}(payload);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(TransferFailed.selector));
        destEscrow.claim(bytes32(uint256(uint192(data.checksum24))));

        // Effects rolled back: the record is still fully claimable.
        assertEq(
            destEscrow.getHeldBalanceForAsset(address(0), address(rejecter)), 1 ether, "held intact after failed claim"
        );
    }

    /// @notice recordDelivery measures the balance-delta actually received, so a fee-on-transfer token records the
    ///         POST-fee amount (< declared), and claim releases exactly that measured amount (I7).
    function test_recordDelivery_feeOnTransfer_measuredDelta() public {
        (BridgeEscrow destEscrow,, MockBridgeAdapter destMock) = _setupDestinationAndValidPayload(address(usdc), 1);
        Mock_FeeOnTransferERC20 fot = new Mock_FeeOnTransferERC20();
        vm.prank(manager);
        destEscrow.registerAsset("FOT   ", address(fot));

        uint256 declared = 1000e18;
        uint256 measured = declared - declared / 100; // 1% fee withheld on transfer
        InvoiceDataLib.InvoiceData memory data =
            _createInvoiceData(SOURCE_CHAIN_ID, DEST_CHAIN_ID, account, bytes6("FOT   "), declared);
        bytes memory payload = InvoiceDataLib.encode(data);
        fot.mint(address(destMock), declared);
        vm.prank(address(destMock));
        fot.approve(address(destEscrow), declared);
        vm.prank(address(destMock));
        destEscrow.recordDelivery(payload);

        assertEq(
            destEscrow.getHeldBalanceForAsset(address(fot), account), measured, "held == measured (post-fee) delta"
        );
        (,, uint256 amount,,,) = destEscrow.destinationCustody(bytes32(uint256(uint192(data.checksum24))));
        assertEq(amount, measured, "custody records measured, not declared");
        assertLt(measured, declared, "measured strictly below declared");

        // claim releases exactly the measured amount.
        vm.prank(manager);
        destEscrow.claim(bytes32(uint256(uint192(data.checksum24))));
        assertEq(destEscrow.getHeldBalanceForAsset(address(fot), account), 0, "held cleared");
    }
}

/// @dev A contract that rejects all ETH, to exercise the native-claim failure/rollback path.
contract RejectEther {
    // no receive / fallback — any value-bearing call fails.
}

/// @dev Minimal fee-on-transfer ERC20 (1% fee withheld to a sink on account-to-account transfers), to exercise
///      recordDelivery's measured-delta path on the destination.
contract Mock_FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("FeeToken", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, to, value - fee);
            if (fee > 0) super._update(from, address(0xdead), fee);
            return;
        }
        super._update(from, to, value);
    }
}
