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

    address internal account2 = makeAddr("custodyAccount2");

    function setUp() public override {
        super.setUp();

        // A dedicated destination escrow (chainId == DEST_CHAIN_ID). recordDelivery validates against the
        // escrow's stored chainId (not block.chainid), so we do not need to switch vm.chainId and can leave
        // the source-side unit tests above untouched.
        destEscrow = _setupDestinationChainEscrow(DEST_CHAIN_ID);
        destMock = _deployMockAdapterForEscrow(destEscrow);
        vm.startPrank(admin);
        destEscrow.authorizeAdapter(address(destMock));
        destEscrow.authorizeAccount(account2); // the escrow initializes with only `account` authorized
        vm.stopPrank();

        // Two accounts × two assets (USDC "USDC  ", DAI "DAI   ") so the cross-account summation and per-asset
        // separation of _heldClaimable / _heldByAccount are actually fuzzed (not trivially true).
        handler = new DestinationCustodyHandler(destEscrow, destMock, usdc, dai, account, account2, manager);
        targetContract(address(handler));
    }

    /// @notice I1 (conservation), per asset: the aggregate (address(0)) held equals both the SUM of the two
    ///         accounts' held balances (cross-account) and the ghost sum of unclaimed recorded amounts; and the
    ///         escrow's real balance is exactly unclaimed custody + stray (nothing lost or double-counted).
    function invariant_I1_custodyConservation() public view {
        for (uint256 t = 0; t < 2; t++) {
            Mock_ERC20 tk = handler.tokenAt(t);
            uint256 aggregate = destEscrow.getHeldBalanceForAsset(address(tk), address(0));
            uint256 sumPerAccount = destEscrow.getHeldBalanceForAsset(address(tk), account)
                + destEscrow.getHeldBalanceForAsset(address(tk), account2);
            uint256 escrowBalance = tk.balanceOf(address(destEscrow));

            assertEq(aggregate, sumPerAccount, "aggregate == Sum of per-account held (cross-account)");
            assertEq(aggregate, handler.ghostUnclaimedFor(t), "aggregate == ghost unclaimed (per asset)");
            assertGe(escrowBalance, aggregate, "escrow balance covers held custody");
            // The escrow's real balance is exactly: unclaimed held custody + stray + source deposits still in
            // the escrow (BRIDGING). cancelInvoice must never let a source refund eat into held custody — if it
            // did, this equality (and the aggregate == unclaimed check above) would break.
            assertEq(
                escrowBalance,
                handler.ghostUnclaimedFor(t) + handler.ghostStrayFor(t) + handler.ghostSourceDepositedFor(t),
                "balance == unclaimed + stray + source-deposited"
            );
        }
    }

    /// @notice ADR 0025: for each account, every hash in `getHeldInvoices` maps to a genuine unclaimed custody
    ///         record (right account, amount > 0, not claimed), with no duplicates — so the operator never receives
    ///         a stale or already-claimed hash. (Value-completeness of the held set is covered by I1 above.)
    function invariant_heldSet_matchesUnclaimedCustody() public view {
        address[2] memory accts = [account, account2];
        for (uint256 a = 0; a < 2; a++) {
            bytes32[] memory held = destEscrow.getHeldInvoices(accts[a]);
            for (uint256 i = 0; i < held.length; i++) {
                (address acct,, uint256 amount,,, bool claimed) = destEscrow.destinationCustody(held[i]);
                assertEq(acct, accts[a], "held hash belongs to the queried account");
                assertGt(amount, 0, "held hash has a live custody amount");
                assertFalse(claimed, "held set never contains a claimed hash");
                for (uint256 j = i + 1; j < held.length; j++) {
                    assertTrue(held[i] != held[j], "no duplicate hashes in the held set");
                }
            }
        }
    }

    /// @notice ADR 0025 completeness (the reverse direction): every recorded delivery that is still live
    ///         (custody amount > 0 && !claimed) appears in its account's `getHeldInvoices` set — so the keeper never
    ///         misses a claimable invoice. Guards against a future custody-writing path that forgets the add hook.
    function invariant_heldSet_isComplete() public view {
        uint256 n = handler.recordedHashesLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 h = handler.recordedHashAt(i);
            (address acct,, uint256 amount,,, bool claimed) = destEscrow.destinationCustody(h);
            if (amount == 0 || claimed) continue; // not live → not required to be in the set
            bytes32[] memory held = destEscrow.getHeldInvoices(acct);
            bool found;
            for (uint256 j = 0; j < held.length; j++) {
                if (held[j] == h) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "every live unclaimed custody record must appear in getHeldInvoices");
        }
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

    /// @notice I6: stray funds transferred directly to the escrow are never counted as held custody. Per asset,
    ///         stray reached the escrow yet held custody equals only the ghost unclaimed (stray excluded).
    function invariant_I6_strayFundsUnclaimable() public view {
        for (uint256 t = 0; t < 2; t++) {
            Mock_ERC20 tk = handler.tokenAt(t);
            assertGe(tk.balanceOf(address(destEscrow)), handler.ghostStrayFor(t), "stray funds are in the escrow");
            assertEq(
                destEscrow.getHeldBalanceForAsset(address(tk), address(0)),
                handler.ghostUnclaimedFor(t),
                "stray never increases held custody"
            );
        }
    }
}

/// @notice Stateful invariant handler over **two accounts × two assets**: an authorized mock adapter records
///         deliveries for a seed-chosen (account, token) and a MANAGER claims recorded hashes, over random
///         bounded sequences. Also transfers stray funds directly into the escrow (bypassing recordDelivery) to
///         exercise I6. Ghost sums are tracked PER ASSET so the cross-account/cross-asset half of I1 is fuzzed.
contract DestinationCustodyHandler is Test {
    BridgeEscrow public immutable escrow;
    MockBridgeAdapter public immutable adapter;
    address public immutable manager;

    Mock_ERC20[2] internal _tokens;
    bytes6[2] internal _symbols;
    address[2] internal _accounts;

    uint64 internal constant SRC_CHAIN_ID = 1;
    uint64 internal _destChainId;

    uint64 internal constant OTHER_CHAIN = 137; // a destination chain id != the escrow's, for source deposits

    // Ghost accounting, per token index (0 == token0, 1 == token1)
    uint256[2] internal _ghostRecorded; // Σ recorded (measured) amounts
    uint256[2] internal _ghostClaimed; // Σ claimed amounts
    uint256[2] internal _ghostStray; // Σ stray direct transfers
    uint256[2] internal _ghostSourceDeposited; // Σ source-deposit funds currently sitting in the escrow (BRIDGING)
    uint256 internal _nonce;

    bytes32[] internal _recordedHashes;
    mapping(bytes32 => bool) internal _isClaimed;
    bytes32[] internal _claimedHashes;

    bytes32[] internal _sourceHashes;
    mapping(bytes32 => bool) internal _sourceClosed;
    mapping(bytes32 => uint256) internal _sourceAmount;
    mapping(bytes32 => uint256) internal _sourceTok;

    constructor(
        BridgeEscrow escrow_,
        MockBridgeAdapter adapter_,
        Mock_ERC20 token0_,
        Mock_ERC20 token1_,
        address account0_,
        address account1_,
        address manager_
    ) {
        escrow = escrow_;
        adapter = adapter_;
        manager = manager_;
        _tokens[0] = token0_;
        _tokens[1] = token1_;
        _symbols[0] = "USDC  ";
        _symbols[1] = "DAI   ";
        _accounts[0] = account0_;
        _accounts[1] = account1_;
        _destChainId = escrow_.chainId();
    }

    function tokenAt(uint256 i) external view returns (Mock_ERC20) {
        return _tokens[i];
    }

    function ghostUnclaimedFor(uint256 t) external view returns (uint256) {
        return _ghostRecorded[t] - _ghostClaimed[t];
    }

    function ghostStrayFor(uint256 t) external view returns (uint256) {
        return _ghostStray[t];
    }

    function ghostSourceDepositedFor(uint256 t) external view returns (uint256) {
        return _ghostSourceDeposited[t];
    }

    function claimedHashesLength() external view returns (uint256) {
        return _claimedHashes.length;
    }

    function claimedHashAt(uint256 i) external view returns (bytes32) {
        return _claimedHashes[i];
    }

    function recordedHashesLength() external view returns (uint256) {
        return _recordedHashes.length;
    }

    function recordedHashAt(uint256 i) external view returns (bytes32) {
        return _recordedHashes[i];
    }

    /// @notice Record a delivery for a random (account, token, amount) via the authorized adapter.
    function recordDelivery(uint256 amountSeed, uint256 accSeed, uint256 tokSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e30);
        uint256 a = accSeed % 2;
        uint256 t = tokSeed % 2;
        uint256 nonce = _nonce++;
        bytes memory payload = _buildPayload(_accounts[a], _symbols[t], amount, nonce);

        _tokens[t].mint(address(adapter), amount);
        vm.prank(address(adapter));
        _tokens[t].approve(address(escrow), amount);

        vm.prank(address(adapter));
        escrow.recordDelivery(payload);

        _recordedHashes.push(bytes32(uint256(uint192(InvoiceDataLib.decode(payload).checksum24))));
        _ghostRecorded[t] += amount;
    }

    /// @notice Claim a random previously-recorded, not-yet-claimed hash as MANAGER.
    function claim(uint256 idxSeed) external {
        uint256 len = _recordedHashes.length;
        if (len == 0) return;
        uint256 start = bound(idxSeed, 0, len - 1);
        for (uint256 k = 0; k < len; k++) {
            bytes32 h = _recordedHashes[(start + k) % len];
            if (_isClaimed[h]) continue;
            (, address asset, uint256 amount,,,) = escrow.destinationCustody(h);
            vm.prank(manager);
            escrow.claim(h);
            _isClaimed[h] = true;
            _claimedHashes.push(h);
            _ghostClaimed[_tokenIndex(asset)] += amount;
            return;
        }
    }

    /// @notice Transfer stray funds of a random token directly to the escrow, bypassing recordDelivery (I6).
    function strayTransfer(uint256 amountSeed, uint256 tokSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e24);
        uint256 t = tokSeed % 2;
        _tokens[t].mint(address(this), amount);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        _tokens[t].transfer(address(escrow), amount);
        _ghostStray[t] += amount;
    }

    /// @notice Open a SOURCE bridging invoice via depositAndBridge (the mock adapter is a no-op, so the deposited
    ///         funds sit in the escrow — commingled with destination held custody, which is the whole point).
    function depositSource(uint256 amountSeed, uint256 accSeed, uint256 tokSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e30);
        uint256 a = accSeed % 2;
        uint256 t = tokSeed % 2;

        _tokens[t].mint(_accounts[a], amount);
        vm.prank(_accounts[a]);
        _tokens[t].approve(address(escrow), amount);
        vm.prank(_accounts[a]);
        bytes32 h = escrow.depositAndBridge(OTHER_CHAIN, _symbolStr(t), amount, address(adapter));

        _sourceHashes.push(h);
        _sourceAmount[h] = amount;
        _sourceTok[h] = t;
        _ghostSourceDeposited[t] += amount;
    }

    /// @notice Cancel a random open SOURCE invoice as MANAGER — must refund only from the surplus over held
    ///         custody, never dipping into it (the guard under test).
    function cancelSource(uint256 idxSeed) external {
        uint256 len = _sourceHashes.length;
        if (len == 0) return;
        uint256 start = bound(idxSeed, 0, len - 1);
        for (uint256 k = 0; k < len; k++) {
            bytes32 h = _sourceHashes[(start + k) % len];
            if (_sourceClosed[h]) continue;
            uint256 t = _sourceTok[h];
            vm.prank(manager);
            escrow.cancelInvoice(h);
            _sourceClosed[h] = true;
            _ghostSourceDeposited[t] -= _sourceAmount[h];
            return;
        }
    }

    function _symbolStr(uint256 t) internal pure returns (string memory) {
        return t == 0 ? "USDC" : "DAI";
    }

    function _tokenIndex(address asset) internal view returns (uint256) {
        return asset == address(_tokens[0]) ? 0 : 1;
    }

    function _buildPayload(address account_, bytes6 symbol, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 invoiceId = bytes32(
            (uint256(SafeCast.toUint24(SRC_CHAIN_ID)) << 232) | (uint256(SafeCast.toUint24(_destChainId)) << 208)
                | (uint256(uint160(account_)) << 48) | uint256(uint48(symbol))
        );
        uint64 timestamp = uint64(block.timestamp);
        bytes24 checksum24 = InvoiceDataLib.calculateChecksum(invoiceId, amount, timestamp, nonce);
        return InvoiceDataLib.encode(
            InvoiceDataLib.InvoiceData({
                invoiceId: invoiceId,
                sourceChainId: SafeCast.toUint24(SRC_CHAIN_ID),
                destinationChainId: SafeCast.toUint24(_destChainId),
                account: account_,
                assetSymbol: symbol,
                amount: amount,
                nonce: nonce,
                timestamp: timestamp,
                checksum24: checksum24
            })
        );
    }
}
