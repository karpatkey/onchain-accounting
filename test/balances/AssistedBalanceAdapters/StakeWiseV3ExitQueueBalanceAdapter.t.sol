// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {
    StakeWiseV3ExitQueueBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of a StakeWise V3 vault's exit-queue reads. Faithful to the two states that matter:
///         fully-pending (idx == -1, valued via the still-queued shares) and checkpointed (idx >= 0, exitedAssets
///         claimable). To prove the adapter passes an out-of-range index when fully pending — the way the real
///         ExitQueue library returns the full queued shares without reverting — calculateExitedAssets REVERTS if
///         idx < 0 and the caller does not pass type(uint256).max (mirroring `Errors.InvalidCheckpointIndex`).
contract MockStakeWiseVault {
    struct Req {
        uint256 leftShares;
        uint256 exitedAssets;
        bool set;
    }

    mapping(bytes32 => Req) private _req; // key(receiver, ticket, ts) → request
    mapping(uint256 => int256) private _idx; // ticket → checkpoint index
    mapping(uint256 => bool) private _idxSet;
    uint256 public rateWad = 1e18; // 1 share = 1 asset by default
    bool public revertIndex;
    bool public revertCalc;
    bool public revertConvert;

    function setIndex(uint256 ticket, int256 idx) external {
        _idx[ticket] = idx;
        _idxSet[ticket] = true;
    }

    function setRequest(address receiver, uint256 ticket, uint256 ts, uint256 leftShares, uint256 exitedAssets)
        external
    {
        _req[keccak256(abi.encode(receiver, ticket, ts))] = Req(leftShares, exitedAssets, true);
    }

    function clearRequest(address receiver, uint256 ticket, uint256 ts) external {
        delete _req[keccak256(abi.encode(receiver, ticket, ts))];
    }

    function setRate(uint256 r) external {
        rateWad = r;
    }

    function setRevertIndex(bool v) external {
        revertIndex = v;
    }

    function setRevertCalc(bool v) external {
        revertCalc = v;
    }

    function setRevertConvert(bool v) external {
        revertConvert = v;
    }

    function getExitQueueIndex(uint256 ticket) external view returns (int256) {
        require(!revertIndex, "idx revert");
        return _idxSet[ticket] ? _idx[ticket] : int256(0);
    }

    function calculateExitedAssets(address receiver, uint256 ticket, uint256 ts, uint256 queryIdx)
        external
        view
        returns (uint256 leftTickets, uint256 exitedTickets, uint256 exitedAssets)
    {
        require(!revertCalc, "calc revert");
        int256 idx = _idxSet[ticket] ? _idx[ticket] : int256(0);
        // Real ExitQueue: a valid small index for a not-yet-checkpointed position reverts; an out-of-range index
        // early-returns (0,0) for the exited portion, so leftTickets = full queued shares.
        if (idx < 0) require(queryIdx == type(uint256).max, "InvalidCheckpointIndex");
        Req memory r = _req[keccak256(abi.encode(receiver, ticket, ts))];
        if (!r.set) return (0, 0, 0);
        return (r.leftShares, 0, r.exitedAssets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!revertConvert, "convert revert");
        return (shares * rateWad) / 1e18;
    }
}

contract MockVaultsRegistry {
    mapping(address => bool) public vaults;

    function setVault(address v, bool ok) external {
        vaults[v] = ok;
    }
}

/// @title StakeWiseV3ExitQueueBalanceAdapter unit tests
contract StakeWiseV3ExitQueueBalanceAdapterTest is BalanceAdapterTestBase {
    StakeWiseV3ExitQueueBalanceAdapter public adapter;
    MockStakeWiseVault public vault;
    MockVaultsRegistry public registry;

    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address holder = makeAddr("holder");
    address other = makeAddr("other");

    uint256 constant TICKET = 12_345;
    uint256 constant TS = 1_700_000_000;
    uint256 constant DELAY = 1 days; // StakeWise post-checkpoint claim delay (EXIT_CLAIM_DELAY)

    function setUp() public override {
        super.setUp();
        vault = new MockStakeWiseVault();
        registry = new MockVaultsRegistry();
        registry.setVault(address(vault), true);
        balances.addSupportedAssetForTest(NATIVE);
        // admin = assistant = this test contract, so it can submit positions.
        adapter = new StakeWiseV3ExitQueueBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), DELAY, address(this), address(this)
        );
        // Warp comfortably past TS + DELAY so checkpointed positions (timestamp = TS) are past the claim delay and
        // value as claimable by default; the delay-gate test re-warps to within the window.
        vm.warp(TS + DELAY + 1);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueBalanceAdapter(
            address(0), NATIVE, "osETH", address(balances), DELAY, address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueBalanceAdapter(
            address(registry), address(0), "osETH", address(balances), DELAY, address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueBalanceAdapter(
            address(registry), NATIVE, "osETH", address(0), DELAY, address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroClaimDelay() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), 0, address(this), address(this)
        );
    }

    function test_constructor_revertsWhenRegistryNotContract() public {
        vm.expectRevert(bytes("VaultsRegistry must be a contract"));
        new StakeWiseV3ExitQueueBalanceAdapter(
            makeAddr("eoa"), NATIVE, "osETH", address(balances), DELAY, address(this), address(this)
        );
    }

    // ---- Access control / submission ----

    function test_submit_onlyAssistant() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, other, keccak256("ASSISTANT_ROLE")
            )
        );
        adapter.submitPositions(holder, _claimable());
    }

    function test_submit_storesValidPosition_andDedups() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether); // claimable
        adapter.submitPositions(holder, _claimable());
        adapter.submitPositions(holder, _claimable()); // dedup
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory cached = adapter.positionsOf(holder);
        assertEq(cached.length, 1);
        assertEq(cached[0].vault, address(vault));
        assertEq(cached[0].positionTicket, TICKET);
        assertEq(cached[0].timestamp, TS);
    }

    /// @notice Writes are fail-loud: a vault not in the registry reverts InvalidExitPosition rather than being skipped.
    function test_submit_revertsOnVaultNotInRegistry() public {
        registry.setVault(address(vault), false);
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(InvalidExitPosition.selector, holder, address(vault), TICKET));
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    /// @notice Writes are fail-loud: a tuple that resolves to zero owed for `account` (not its position, or claimed)
    ///         reverts InvalidExitPosition — the on-chain ownership proxy — rather than being silently skipped.
    function test_submit_revertsOnTupleWithZeroOwed() public {
        // Registered vault, but no exit request set for (holder, TICKET, TS) → owed 0 → reverts.
        vault.setIndex(TICKET, 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidExitPosition.selector, holder, address(vault), TICKET));
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_submitPositionsBatch_storesAcrossAccounts() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(other, TICKET + 1, TS, 0, 2 ether);
        address[] memory accounts = new address[](2);
        accounts[0] = holder;
        accounts[1] = other;
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[][] memory positions =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[][](2);
        positions[0] = new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](1);
        positions[0][0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
        positions[1] = new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](1);
        positions[1][0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET + 1, TS);
        adapter.submitPositionsBatch(accounts, positions);
        assertEq(adapter.positionsOf(holder).length, 1);
        assertEq(adapter.positionsOf(other).length, 1);
        (uint256 a1,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        (uint256 a2,) = adapter.getAdapterBalanceForAsset(other, NATIVE);
        assertEq(a1, 1 ether);
        assertEq(a2, 2 ether);
    }

    function test_submitPositionsBatch_revertsOnLengthMismatch() public {
        address[] memory accounts = new address[](2);
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[][] memory positions =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[][](1);
        vm.expectRevert(ArrayLengthMismatch.selector);
        adapter.submitPositionsBatch(accounts, positions);
    }

    function test_clearPosition_absentKey_noop() public {
        // Clearing a never-submitted position is idempotent (no revert, no state change).
        adapter.clearPosition(holder, address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_clearPosition_andClearAccount() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(holder, TICKET + 1, TS, 0, 2 ether);
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory two =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](2);
        two[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
        two[1] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET + 1, TS);
        adapter.submitPositions(holder, two);
        adapter.clearPosition(holder, address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 1);
        assertEq(adapter.positionsOf(holder)[0].positionTicket, TICKET + 1);
        adapter.clearAccount(holder);
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    // ---- Valuation ----

    function test_claimable_usesExitedAssets() public {
        vault.setIndex(TICKET, 1465);
        vault.setRequest(holder, TICKET, TS, 0, 4_999_000_000_000_000_000); // left 0, exitedAssets ~5 ETH
        adapter.submitPositions(holder, _claimable());
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4_999_000_000_000_000_000);
        assertEq(d, false);
    }

    function test_fullyPending_valuesQueuedSharesViaConvertToAssets() public {
        // idx == -1 (not yet checkpointed). Adapter must pass type(uint256).max (else the mock reverts).
        vault.setIndex(TICKET, -1);
        vault.setRate(0.98e18); // 1 share = 0.98 assets
        vault.setRequest(holder, TICKET, TS, 10 ether, 0); // 10 shares queued, nothing exited
        adapter.submitPositions(holder, _claimable());
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 9.8 ether); // convertToAssets(10) at 0.98
    }

    function test_partiallyExited_sumsExitedPlusQueued() public {
        vault.setIndex(TICKET, 7);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET, TS, 3 ether, 2 ether); // 3 shares left + 2 ETH exited
        adapter.submitPositions(holder, _claimable());
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 5 ether); // 2 exited + convertToAssets(3) at 1.0
    }

    function test_claimDelay_checkpointedButWithinDelay_reportedLocked() public {
        // A checkpointed position (fully exited, 3 ETH) whose entry timestamp is so recent that StakeWise's
        // post-checkpoint claim delay has NOT elapsed → the exited assets are reported LOCKED (isLocked=true), not
        // claimable, even though they still count toward the owed total.
        uint256 recentTs = block.timestamp - (DELAY - 1); // delay window not yet elapsed
        vault.setIndex(TICKET, 5);
        vault.setRequest(holder, TICKET, recentTs, 0, 3 ether); // left 0, exitedAssets 3 ETH
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory one =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](1);
        one[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, recentTs);
        adapter.submitPositions(holder, one);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1, "one locked leg while within the claim delay");
        assertTrue(p[0].isLocked, "checkpointed-but-delayed exited assets are locked, not claimable");
        assertEq(p[0].amount, 3 ether);
        // The owed total is unaffected by the gate.
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 3 ether);

        // Once the delay elapses, the same position flips to claimable (isLocked=false); amount unchanged.
        vm.warp(recentTs + DELAY);
        p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertFalse(p[0].isLocked, "claimable once the delay has elapsed");
        assertEq(p[0].amount, 3 ether);
    }

    function test_submit_revertsOnWrongReceiver() public {
        // Position belongs to `other`; submitting it under `holder` → calculateExitedAssets(holder,…) == 0, which is
        // the on-chain ownership proxy → fail-loud revert (the assistant submitted someone else's position).
        vault.setIndex(TICKET, 1);
        vault.setRequest(other, TICKET, TS, 0, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(InvalidExitPosition.selector, holder, address(vault), TICKET));
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.positionsOf(holder).length, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_claimedAfterSubmit_dropped_doesNotRevert() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        vault.clearRequest(holder, TICKET, TS); // claimed → request deleted
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_aggregatesAcrossPositions() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(holder, TICKET + 1, TS, 0, 3 ether);
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory two =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](2);
        two[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
        two[1] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET + 1, TS);
        adapter.submitPositions(holder, two);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4 ether);
    }

    // ---- never-revert guarantee (try/catch branches) ----

    function test_getExitQueueIndexReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        vault.setRevertIndex(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_calculateExitedAssetsReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        adapter.submitPositions(holder, _claimable());
        vault.setRevertCalc(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_convertToAssetsReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, -1);
        vault.setRequest(holder, TICKET, TS, 5 ether, 0); // pending → needs convertToAssets
        adapter.submitPositions(holder, _claimable());
        vault.setRevertConvert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    /// @notice Writes are fail-loud at the cap: a submitted list longer than MAX_POSITIONS reverts PositionCacheFull
    ///         rather than silently dropping the overflow. Submit is replace semantics, so the cap is hit within a
    ///         single list, not by accumulating across calls.
    function test_submit_revertsWhenCacheFull() public {
        uint256 cap = adapter.MAX_POSITIONS();
        // A single list of exactly MAX_POSITIONS is accepted.
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory many =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](cap);
        for (uint256 i = 0; i < cap; i++) {
            vault.setIndex(i + 1, 1);
            vault.setRequest(holder, i + 1, TS, 0, 1 ether);
            many[i] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), i + 1, TS);
        }
        adapter.submitPositions(holder, many);
        assertEq(adapter.positionsOf(holder).length, cap, "cache filled to MAX_POSITIONS");

        // A single list of MAX_POSITIONS + 1 is fail-loud (the cap+1-th add reverts).
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory tooMany =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](cap + 1);
        for (uint256 i = 0; i < cap + 1; i++) {
            vault.setIndex(i + 1, 1);
            vault.setRequest(holder, i + 1, TS, 0, 1 ether);
            tooMany[i] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), i + 1, TS);
        }
        vm.expectRevert(abi.encodeWithSelector(PositionCacheFull.selector, holder, cap));
        adapter.submitPositions(holder, tooMany);
        // The reverted submit left the prior set intact (replace is atomic — the clear rolled back with the revert).
        assertEq(adapter.positionsOf(holder).length, cap, "cache unchanged after the reverted submit");
    }

    // ---- Positions / identity ----

    function test_getAdapterPositions_identity() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether); // fully exited → claimable
        adapter.submitPositions(holder, _claimable());
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].isDebt, false);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].balanceAsset.asset, NATIVE);
        assertEq(p[0].protocolId, ProtocolIds.STAKEWISE_EXIT);
        // positionId is now the per-vault coordinate, NOT the VaultsRegistry.
        assertEq(p[0].positionId, abi.encode(address(vault)));
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(p[0].isLocked, "fully exited -> claimable leg");
        _assertTicketLeg(p[0]);
        assertEq(p[0].positionInstanceId, bytes32(TICKET), "positionInstanceId = ticket");
    }

    function test_getAdapterPositions_lockedLeg() public {
        // Fully pending (idx == -1) → entirely locked: valued via convertToAssets(leftShares).
        vault.setIndex(TICKET, -1);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET, TS, 4 ether, 0); // 4 shares queued, nothing exited
        adapter.submitPositions(holder, _claimable());
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 4 ether, "locked leg = convertToAssets(leftShares)");
        assertTrue(p[0].isLocked, "still-queued shares -> locked leg");
        assertEq(p[0].positionId, abi.encode(address(vault)));
        _assertTicketLeg(p[0]);
        assertEq(p[0].positionInstanceId, bytes32(TICKET), "positionInstanceId = ticket");
    }

    function test_getAdapterPositions_mixedClaimableAndLocked() public {
        // Partially exited: 2 ETH exited (claimable) + 3 shares still queued (locked) → two legs from the SAME
        // ticket, sharing the static per-vault positionId AND the same ticket label, distinguished by isLocked.
        vault.setIndex(TICKET, 7);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET, TS, 3 ether, 2 ether); // leftShares 3, exitedAssets 2
        adapter.submitPositions(holder, _claimable());

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2, "claimable + locked legs for the ticket");

        bytes memory expectedId = abi.encode(address(vault));
        bytes32 expectedInstanceId = bytes32(TICKET);
        uint256 claimable;
        uint256 locked;
        bool sawClaimable;
        bool sawLocked;
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, NATIVE);
            assertEq(p[i].balanceAdapter, address(adapter));
            assertFalse(p[i].isDebt);
            assertEq(p[i].protocolId, ProtocolIds.STAKEWISE_EXIT);
            assertEq(p[i].positionId, expectedId, "both legs share the static per-vault positionId");
            _assertTicketLeg(p[i]);
            assertEq(p[i].positionInstanceId, expectedInstanceId, "both legs carry the SAME ticket");
            if (p[i].isLocked) {
                locked += p[i].amount;
                sawLocked = true;
            } else {
                claimable += p[i].amount;
                sawClaimable = true;
            }
        }
        assertTrue(sawClaimable && sawLocked, "exactly one claimable + one locked leg present");
        assertEq(claimable, 2 ether, "claimable = exitedAssets");
        assertEq(locked, 3 ether, "locked = convertToAssets(leftShares)");

        // NAV-total invariance.
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(claimable + locked, agg, "sum of legs == old aggregate");
    }

    function test_getAdapterPositions_twoPositionsSameVault_distinctTicketLabels() public {
        // Two cached positions in the SAME vault → their legs carry DISTINCT ticket labels (not aggregated), share
        // the per-vault positionId, and sum to the aggregate.
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether); // claimable 1 ETH
        vault.setIndex(TICKET + 1, -1);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET + 1, TS, 3 ether, 0); // fully pending → locked 3 ETH
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory two =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](2);
        two[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
        two[1] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET + 1, TS);
        adapter.submitPositions(holder, two);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        // One leg per position (one claimable, one locked) → 2 legs total, with distinct ticket labels.
        assertEq(p.length, 2, "one leg per cached position");

        bytes memory expectedId = abi.encode(address(vault));
        bytes32 instA = bytes32(TICKET);
        bytes32 instB = bytes32(TICKET + 1);
        uint256 total;
        bool sawA;
        bool sawB;
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, expectedId, "legs of the same vault share the per-vault positionId");
            _assertTicketLeg(p[i]);
            total += p[i].amount;
            if (p[i].positionInstanceId == instA) {
                sawA = true;
                assertFalse(p[i].isLocked, "TICKET leg is claimable");
                assertEq(p[i].amount, 1 ether);
            } else if (p[i].positionInstanceId == instB) {
                sawB = true;
                assertTrue(p[i].isLocked, "TICKET+1 leg is locked");
                assertEq(p[i].amount, 3 ether);
            }
        }
        assertTrue(sawA && sawB, "legs carry DISTINCT ticket instance ids");

        (uint256 agg,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(total, agg, "sum of per-ticket legs == aggregate");
        assertEq(total, 4 ether);
    }

    function test_getAdapterBalances_shape() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        adapter.submitPositions(holder, _claimable());
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], NATIVE);
        assertEq(amounts[0], 2 ether);
        assertEq(isDebt[0], false);
        // Zero owed → empty arrays.
        (address[] memory a2,,) = adapter.getAdapterBalances(other);
        assertEq(a2.length, 0);
    }

    function test_getAdapterPositions_assetFilterMatchesUnderlying() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        adapter.submitPositions(holder, _claimable());
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, NATIVE);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].balanceAsset.asset, NATIVE);
    }

    function test_getAdapterPositions_assetFilterMismatch_empty() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        adapter.submitPositions(holder, _claimable());
        assertEq(adapter.getAdapterPositions(holder, address(0xdead)).length, 0);
    }

    function test_getAdapterPositions_zeroOwed_empty() public view {
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], NATIVE);
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceStillOwed() public {
        // Fresh NAV harness that does NOT register the native sentinel.
        BalancesHarness freshNav = new BalancesHarness();
        StakeWiseV3ExitQueueBalanceAdapter a2 = new StakeWiseV3ExitQueueBalanceAdapter(
            address(registry), NATIVE, "osETH", address(freshNav), DELAY, address(this), address(this)
        );
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        a2.submitPositions(holder, _claimable());
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0); // dropped: underlying not registered
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 1 ether);
    }

    function _claimable() internal view returns (StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory p) {
        p = new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](1);
        p[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(address(vault), TICKET, TS);
    }

    /// @dev Asserts a leg's static breadcrumb is `["osETH Exit Queue"]` (positionId-derived receipt-token category, no
    ///      ephemeral id); the positionTicket now rides in the typed `positionInstanceId`.
    function _assertTicketLeg(INAVCalculator.PositionBalance memory leg) internal view {
        string[] memory labels = adapter.positionLabels(leg.positionId);
        assertEq(labels.length, 1, "static breadcrumb = [category]");
        assertEq(labels[0], "osETH Exit Queue");
        assertTrue(leg.positionInstanceId != bytes32(0), "positionInstanceId carries the ticket");
    }
}
