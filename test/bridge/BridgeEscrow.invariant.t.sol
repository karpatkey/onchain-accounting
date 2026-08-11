// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {BridgeEscrow} from "src/bridge/BridgeEscrow.sol";
import {MockBridgeAdapter} from "test/bridge/mocks/MockBridgeAdapter.sol";
import {InvoiceDataLib} from "src/bridge/InvoiceDataLib.sol";
import {BridgeEscrowTestBase} from "test/bridge/BridgeEscrowTestBase.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";

/// @title BridgeEscrow Invariant Tests
/// @notice Critical invariants for BridgeEscrow accounting and state
contract BridgeEscrowInvariantTest is BridgeEscrowTestBase {
    // ============ Destination custody stateful invariant (ADR 0024) ============

    BridgeEscrow public destEscrow;
    MockBridgeAdapter public destMock;
    DestinationCustodyHandler public handler;

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

    // ============ Stateful invariant: destination custody (record + claim) ============

    function setUp() public override {
        super.setUp();

        // A dedicated destination escrow (chainId == DEST_CHAIN_ID). recordDelivery validates against the
        // escrow's stored chainId (not block.chainid), so we do not need to switch vm.chainId and can leave
        // the source-side unit tests above untouched.
        destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        destMock = _deployMockAdapterForEscrow(destEscrow);
        vm.prank(admin);
        destEscrow.authorizeAdapter(address(destMock));

        handler = new DestinationCustodyHandler(destEscrow, destMock, usdc, account, manager);

        // Only the handler drives the fuzz sequences (record / claim / stray transfers).
        targetContract(address(handler));
    }

    /// @notice I1 (conservation): held custody never exceeds the escrow's real balance; the aggregate equals
    ///         both the ghost sum of unclaimed recorded amounts and the single account's held balance; and the
    ///         escrow's balance is exactly unclaimed custody + stray funds (nothing is lost or double-counted).
    function invariant_I1_custodyConservation() public view {
        uint256 heldAggregate = destEscrow.getHeldBalanceForAsset(address(usdc), address(0));
        uint256 heldForAccount = destEscrow.getHeldBalanceForAsset(address(usdc), account);
        uint256 escrowBalance = usdc.balanceOf(address(destEscrow));

        assertEq(heldAggregate, handler.ghostUnclaimed(), "held aggregate == ghost unclaimed");
        assertEq(heldAggregate, heldForAccount, "single account: aggregate == per-account held");
        assertGe(escrowBalance, heldAggregate, "escrow balance covers held custody");
        assertEq(escrowBalance, handler.ghostUnclaimed() + handler.ghostStray(), "balance == unclaimed + stray");
    }

    /// @notice I3: a custody record claimed once can never be claimed again — a second claim reverts.
    function invariant_I3_claimedCannotBeReclaimed() public {
        uint256 n = handler.claimedHashesLength();
        uint256 cap = n > 8 ? 8 : n; // bound the per-run cost
        for (uint256 i = 0; i < cap; i++) {
            bytes32 h = handler.claimedHashAt(i);
            vm.prank(manager);
            try destEscrow.claim(h) {
                fail();
            } catch {
                // expected: AlreadyClaimed
            }
        }
    }

    /// @notice I6: stray funds transferred directly to the escrow are never counted as held custody, and no
    ///         custody hash keys them (nothing to claim). The equality in I1 already excludes stray from held;
    ///         here we additionally assert stray funds actually reached the escrow yet stayed unattributed.
    function invariant_I6_strayFundsUnclaimable() public view {
        assertGe(usdc.balanceOf(address(destEscrow)), handler.ghostStray(), "stray funds are in the escrow");
        assertEq(
            destEscrow.getHeldBalanceForAsset(address(usdc), address(0)),
            handler.ghostUnclaimed(),
            "stray never increases held custody"
        );
    }
}

/// @notice Stateful invariant handler: an authorized mock adapter records deliveries for a fixed (account,
///         asset) and a MANAGER claims recorded hashes, over random bounded sequences. Also transfers stray
///         funds directly into the escrow (bypassing recordDelivery) to exercise I6. Tracks ghost sums.
contract DestinationCustodyHandler is Test {
    BridgeEscrow public immutable escrow;
    MockBridgeAdapter public immutable adapter;
    Mock_ERC20 public immutable token;
    address public immutable account;
    address public immutable manager;

    uint64 internal constant SRC_CHAIN_ID = 1;
    uint64 internal _destChainId;
    bytes6 internal constant USDC_SYMBOL_BYTES6 = "USDC  ";

    // Ghost accounting
    uint256 public ghostRecorded; // Σ recorded (measured) amounts
    uint256 public ghostClaimed; // Σ claimed amounts
    uint256 public ghostStray; // Σ stray direct transfers
    uint256 internal _nonce;

    bytes32[] internal _recordedHashes;
    mapping(bytes32 => bool) internal _isClaimed;
    bytes32[] internal _claimedHashes;

    constructor(
        BridgeEscrow escrow_,
        MockBridgeAdapter adapter_,
        Mock_ERC20 token_,
        address account_,
        address manager_
    ) {
        escrow = escrow_;
        adapter = adapter_;
        token = token_;
        account = account_;
        manager = manager_;
        _destChainId = escrow_.chainId();
    }

    function ghostUnclaimed() external view returns (uint256) {
        return ghostRecorded - ghostClaimed;
    }

    function claimedHashesLength() external view returns (uint256) {
        return _claimedHashes.length;
    }

    function claimedHashAt(uint256 i) external view returns (bytes32) {
        return _claimedHashes[i];
    }

    /// @notice Record a delivery for a random amount via the authorized adapter (funds pulled from it).
    function recordDelivery(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e30);
        uint256 nonce = _nonce++;
        bytes memory payload = _buildPayload(amount, nonce);

        // Fund the adapter and let the escrow pull exactly `amount` (standard, non-fee-on-transfer token).
        token.mint(address(adapter), amount);
        vm.prank(address(adapter));
        token.approve(address(escrow), amount);

        vm.prank(address(adapter));
        escrow.recordDelivery(payload);

        bytes32 invoiceHash = bytes32(uint256(uint192(InvoiceDataLib.decode(payload).checksum24)));
        _recordedHashes.push(invoiceHash);
        ghostRecorded += amount;
    }

    /// @notice Claim a random previously-recorded, not-yet-claimed hash as MANAGER.
    function claim(uint256 idxSeed) external {
        uint256 len = _recordedHashes.length;
        if (len == 0) return;
        uint256 start = bound(idxSeed, 0, len - 1);
        for (uint256 k = 0; k < len; k++) {
            bytes32 h = _recordedHashes[(start + k) % len];
            if (_isClaimed[h]) continue;
            (,, uint256 amount,,,) = escrow.destinationCustody(h);
            vm.prank(manager);
            escrow.claim(h);
            _isClaimed[h] = true;
            _claimedHashes.push(h);
            ghostClaimed += amount;
            return;
        }
    }

    /// @notice Transfer stray funds directly to the escrow, bypassing recordDelivery (I6).
    function strayTransfer(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e24);
        token.mint(address(this), amount);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(escrow), amount);
        ghostStray += amount;
    }

    function _buildPayload(uint256 amount, uint256 nonce) internal view returns (bytes memory) {
        bytes32 invoiceId = bytes32(
            (uint256(SafeCast.toUint24(SRC_CHAIN_ID)) << 232) | (uint256(SafeCast.toUint24(_destChainId)) << 208)
                | (uint256(uint160(account)) << 48) | uint256(uint48(USDC_SYMBOL_BYTES6))
        );
        uint64 timestamp = uint64(block.timestamp);
        bytes24 checksum24 = InvoiceDataLib.calculateChecksum(invoiceId, amount, timestamp, nonce);
        return InvoiceDataLib.encode(
            InvoiceDataLib.InvoiceData({
                invoiceId: invoiceId,
                sourceChainId: SafeCast.toUint24(SRC_CHAIN_ID),
                destinationChainId: SafeCast.toUint24(_destChainId),
                account: account,
                assetSymbol: USDC_SYMBOL_BYTES6,
                amount: amount,
                nonce: nonce,
                timestamp: timestamp,
                checksum24: checksum24
            })
        );
    }
}
