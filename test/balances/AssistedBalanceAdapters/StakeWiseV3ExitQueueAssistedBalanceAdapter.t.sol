// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of a StakeWise V3 vault's exit-queue reads (identical to the assisted-adapter unit-test mock).
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
    mapping(address => bool) private _vaults;
    bool public revertVaults;

    function setVault(address v, bool ok) external {
        _vaults[v] = ok;
    }

    function setRevertVaults(bool v) external {
        revertVaults = v;
    }

    function vaults(address v) external view returns (bool) {
        require(!revertVaults, "registry revert");
        return _vaults[v];
    }
}

/// @title StakeWiseV3ExitQueueAssistedBalanceAdapter unit tests
/// @notice Wrapper-fed exit-queue adapter: `submit`/`remove` are permissionless and self-scoped to `msg.sender`
///         (no roles/admin), fed one ticket at a time. Tests call them as the tracked account directly.
contract StakeWiseV3ExitQueueAssistedBalanceAdapterTest is BalanceAdapterTestBase {
    StakeWiseV3ExitQueueAssistedBalanceAdapter public adapter;
    MockStakeWiseVault public vault;
    MockVaultsRegistry public registry;

    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address holder = makeAddr("holder");
    address other = makeAddr("other");

    uint256 constant TICKET = 12_345;
    uint256 constant TS = 1_700_000_000;
    uint256 constant DELAY = 1 days;

    function setUp() public override {
        super.setUp();
        vault = new MockStakeWiseVault();
        registry = new MockVaultsRegistry();
        registry.setVault(address(vault), true);
        balances.addSupportedAssetForTest(NATIVE);
        adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), DELAY
        );
        vm.warp(TS + DELAY + 1);
    }

    // ---- Helpers ----

    /// @dev submit is permissionless + self-scoped, so track `account`'s ticket by calling as `account`.
    function _submit(address account, uint256 ticket, uint256 ts) internal {
        vm.prank(account);
        adapter.submit(address(vault), ticket, ts);
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueAssistedBalanceAdapter(address(0), NATIVE, "osETH", address(balances), DELAY);
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueAssistedBalanceAdapter(address(registry), address(0), "osETH", address(balances), DELAY);
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueAssistedBalanceAdapter(address(registry), NATIVE, "osETH", address(0), DELAY);
    }

    function test_constructor_revertsOnZeroClaimDelay() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3ExitQueueAssistedBalanceAdapter(address(registry), NATIVE, "osETH", address(balances), 0);
    }

    function test_constructor_revertsWhenRegistryNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "VaultsRegistry"));
        new StakeWiseV3ExitQueueAssistedBalanceAdapter(makeAddr("eoa"), NATIVE, "osETH", address(balances), DELAY);
    }

    function test_constructor_revertsWhenNavNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new StakeWiseV3ExitQueueAssistedBalanceAdapter(address(registry), NATIVE, "osETH", makeAddr("eoa"), DELAY);
    }

    // ---- Write surface (permissionless, self-scoped) ----
    // submit/remove are permissionless and self-scoped to msg.sender; there is no role to test here.

    function test_submit_storesValidPosition_andDedups() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        _submit(holder, TICKET, TS); // dedup no-op
        StakeWiseV3ExitQueueAssistedBalanceAdapter.ExitPosition[] memory cached = adapter.positionsOf(holder);
        assertEq(cached.length, 1);
        assertEq(cached[0].vault, address(vault));
        assertEq(cached[0].positionTicket, TICKET);
        assertEq(cached[0].timestamp, TS);
    }

    function test_submit_revertsOnVaultNotInRegistry() public {
        registry.setVault(address(vault), false);
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(InvalidCoordinate.selector, holder, TICKET));
        adapter.submit(address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_submit_revertsOnTupleWithZeroOwed() public {
        vault.setIndex(TICKET, 1); // registered vault, but no request → owed 0 → not the caller's position
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, TICKET));
        adapter.submit(address(vault), TICKET, TS);
    }

    function test_submit_revertsWhenRegistryCallReverts() public {
        // The VaultsRegistry membership read is try/catch'd → a reverting registry is treated as "not registered".
        registry.setRevertVaults(true);
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(InvalidCoordinate.selector, holder, TICKET));
        adapter.submit(address(vault), TICKET, TS);
    }

    function test_submit_revertsWhenTicketOwnedByOtherAccount() public {
        // The exit position belongs to `other` (it is the receiver). `holder` cannot submit it: the on-chain
        // ownership proxy calculateExitedAssets(holder,…) is 0, so submit reverts NotExitPositionOwner.
        vault.setIndex(TICKET, 1);
        vault.setRequest(other, TICKET, TS, 0, 1 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, TICKET));
        adapter.submit(address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_remove_dropsTrackedPosition() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(holder, TICKET + 1, TS, 0, 2 ether);
        _submit(holder, TICKET, TS);
        _submit(holder, TICKET + 1, TS);

        // remove requires the position be claimed/consumed (owed 0) — simulate the claim for TICKET.
        vault.setRequest(holder, TICKET, TS, 0, 0);
        vm.prank(holder);
        adapter.remove(address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 1);
        assertEq(adapter.positionsOf(holder)[0].positionTicket, TICKET + 1);
    }

    function test_remove_revertsWhenStillOwed() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        // Still live (owed > 0) → cannot be dropped (would under-report the caller's own NAV).
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, TICKET));
        adapter.remove(address(vault), TICKET, TS);
    }

    function test_remove_revertsWhenNotTracked() public {
        // Never-tracked tuple → PositionNotTracked (the ticket must belong to the caller).
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, holder, TICKET));
        adapter.remove(address(vault), TICKET, TS);

        // And removing the same tuple twice reverts on the second call.
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        vault.setRequest(holder, TICKET, TS, 0, 0); // claimed → removable
        vm.prank(holder);
        adapter.remove(address(vault), TICKET, TS);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, holder, TICKET));
        adapter.remove(address(vault), TICKET, TS);
    }

    function test_remove_revertsWhenTrackedByOtherAccount() public {
        // `holder` tracks the ticket; `other` cannot remove it (self-scoped to msg.sender).
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, other, TICKET));
        adapter.remove(address(vault), TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 1, "holder's position untouched");
    }

    function test_clearAccount_self() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        assertEq(adapter.positionsOf(holder).length, 1);

        vm.prank(holder);
        adapter.clearAccount();
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_clearAccount_emptyIsNoop() public {
        // No tracked positions → clearAccount() is a no-op (no revert, still empty).
        vm.prank(holder);
        adapter.clearAccount();
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_submit_revertsWhenCacheFull() public {
        uint256 cap = adapter.MAX_POSITIONS();
        for (uint256 i = 0; i < cap; i++) {
            vault.setIndex(i + 1, 1);
            vault.setRequest(holder, i + 1, TS, 0, 1 ether);
            _submit(holder, i + 1, TS);
        }
        assertEq(adapter.positionsOf(holder).length, cap);

        vault.setIndex(cap + 1, 1);
        vault.setRequest(holder, cap + 1, TS, 0, 1 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, holder, cap));
        adapter.submit(address(vault), cap + 1, TS);
    }

    // ---- Valuation (shared with the assisted adapter) ----

    function test_claimable_usesExitedAssets() public {
        vault.setIndex(TICKET, 1465);
        vault.setRequest(holder, TICKET, TS, 0, 4_999_000_000_000_000_000);
        _submit(holder, TICKET, TS);
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4_999_000_000_000_000_000);
        assertEq(d, false);
    }

    function test_fullyPending_valuesQueuedSharesViaConvertToAssets() public {
        vault.setIndex(TICKET, -1);
        vault.setRate(0.98e18);
        vault.setRequest(holder, TICKET, TS, 10 ether, 0);
        _submit(holder, TICKET, TS);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 9.8 ether);
    }

    function test_partiallyExited_sumsExitedPlusQueued() public {
        vault.setIndex(TICKET, 7);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET, TS, 3 ether, 2 ether);
        _submit(holder, TICKET, TS);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 5 ether);
    }

    function test_claimDelay_checkpointedButWithinDelay_reportedLocked() public {
        uint256 recentTs = block.timestamp - (DELAY - 1);
        vault.setIndex(TICKET, 5);
        vault.setRequest(holder, TICKET, recentTs, 0, 3 ether);
        _submit(holder, TICKET, recentTs);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertTrue(p[0].isLocked);
        assertEq(p[0].amount, 3 ether);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 3 ether);

        vm.warp(recentTs + DELAY);
        p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertFalse(p[0].isLocked);
        assertEq(p[0].amount, 3 ether);
    }

    function test_claimedAfterSubmit_dropped_doesNotRevert() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        vault.clearRequest(holder, TICKET, TS);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_aggregatesAcrossPositions() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(holder, TICKET + 1, TS, 0, 3 ether);
        _submit(holder, TICKET, TS);
        _submit(holder, TICKET + 1, TS);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 4 ether);
    }

    // ---- never-revert guarantee ----

    function test_getExitQueueIndexReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        vault.setRevertIndex(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_calculateExitedAssetsReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        _submit(holder, TICKET, TS);
        vault.setRevertCalc(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    function test_convertToAssetsReverts_droppedNotReverted() public {
        vault.setIndex(TICKET, -1);
        vault.setRequest(holder, TICKET, TS, 5 ether, 0);
        _submit(holder, TICKET, TS);
        vault.setRevertConvert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 0);
    }

    // ---- Positions / identity ----

    function test_getAdapterPositions_identity() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        _submit(holder, TICKET, TS);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].isDebt, false);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].balanceAsset.asset, NATIVE);
        assertEq(p[0].protocolSubId, ProtocolIds.STAKEWISE_V3_EXIT);
        assertEq(p[0].protocolId, ProtocolIds.STAKEWISE_V3);
        assertEq(p[0].positionId, abi.encode(address(vault)));
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(p[0].isLocked);
        _assertTicketLeg(p[0]);
        assertEq(p[0].positionInstanceId, bytes32(TICKET));
    }

    function test_getAdapterPositions_mixedClaimableAndLocked() public {
        vault.setIndex(TICKET, 7);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET, TS, 3 ether, 2 ether);
        _submit(holder, TICKET, TS);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2);
        bytes memory expectedId = abi.encode(address(vault));
        uint256 claimable;
        uint256 locked;
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, expectedId);
            assertEq(p[i].positionInstanceId, bytes32(TICKET));
            if (p[i].isLocked) locked += p[i].amount;
            else claimable += p[i].amount;
        }
        assertEq(claimable, 2 ether);
        assertEq(locked, 3 ether);
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(claimable + locked, agg);
    }

    function test_getAdapterBalances_shape() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        _submit(holder, TICKET, TS);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], NATIVE);
        assertEq(amounts[0], 2 ether);
        assertEq(isDebt[0], false);
        (address[] memory a2,,) = adapter.getAdapterBalances(other);
        assertEq(a2.length, 0);
    }

    function test_getAdapterPositions_assetFilterMismatch_empty() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        _submit(holder, TICKET, TS);
        assertEq(adapter.getAdapterPositions(holder, address(0xdead)).length, 0);
    }

    function test_getAdapterPositions_assetFilterMatchesUnderlying() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        _submit(holder, TICKET, TS);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, NATIVE);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 2 ether);
        assertEq(p[0].balanceAsset.asset, NATIVE);
    }

    function test_getAdapterPositions_zeroOwed_empty() public view {
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_getAdapterPositions_zeroAccount_empty() public view {
        assertEq(adapter.getAdapterPositions(address(0), address(0)).length, 0);
    }

    function test_getAdapterPositions_skipsZeroValuedTrackedPosition() public {
        // Two tracked tickets; one is later claimed (its live read is 0) and must contribute NO legs, while the other
        // still produces its leg — exercising the per-position skip and the temp-array resize (sized 2*N, filled 1).
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        vault.setIndex(TICKET + 1, 1);
        vault.setRequest(holder, TICKET + 1, TS, 0, 5 ether);
        _submit(holder, TICKET, TS);
        _submit(holder, TICKET + 1, TS);

        // TICKET gets claimed → its request now values to 0 (but stays cached).
        vault.clearRequest(holder, TICKET, TS);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1, "zero-valued tracked position contributes no legs");
        assertEq(p[0].positionInstanceId, bytes32(TICKET + 1));
        assertEq(p[0].amount, 5 ether);
        // The read-time skip does not mutate the cache — both tuples remain tracked.
        assertEq(adapter.positionsOf(holder).length, 2);
    }

    function test_getAdapterPositions_fullyPendingLockedLeg() public {
        // idx == -1 → fully pending → one locked leg valued via convertToAssets(leftShares).
        vault.setIndex(TICKET, -1);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET, TS, 4 ether, 0);
        _submit(holder, TICKET, TS);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertTrue(p[0].isLocked, "still-queued shares -> locked leg");
        assertEq(p[0].amount, 4 ether);
        assertEq(p[0].positionId, abi.encode(address(vault)));
        assertEq(p[0].positionInstanceId, bytes32(TICKET));
    }

    function test_getAdapterPositions_twoPositionsSameVault_distinctInstanceIds() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether); // claimable 1 ETH
        vault.setIndex(TICKET + 1, -1);
        vault.setRate(1e18);
        vault.setRequest(holder, TICKET + 1, TS, 3 ether, 0); // fully-pending → locked 3 ETH
        _submit(holder, TICKET, TS);
        _submit(holder, TICKET + 1, TS);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2, "one leg per position");
        bytes memory expectedId = abi.encode(address(vault));
        uint256 total;
        bool sawA;
        bool sawB;
        for (uint256 i; i < p.length; i++) {
            assertEq(p[i].positionId, expectedId, "same vault -> shared positionId");
            total += p[i].amount;
            if (p[i].positionInstanceId == bytes32(TICKET)) {
                sawA = true;
                assertFalse(p[i].isLocked);
                assertEq(p[i].amount, 1 ether);
            } else if (p[i].positionInstanceId == bytes32(TICKET + 1)) {
                sawB = true;
                assertTrue(p[i].isLocked);
                assertEq(p[i].amount, 3 ether);
            }
        }
        assertTrue(sawA && sawB, "distinct per-ticket instance ids");
        assertEq(total, 4 ether);
    }

    function test_getAdapterBalanceForAsset_wrongAssetOrZeroAccount_returnsZero() public {
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 2 ether);
        _submit(holder, TICKET, TS);
        (uint256 wrong, bool wd) = adapter.getAdapterBalanceForAsset(holder, address(0xdead));
        assertEq(wrong, 0);
        assertFalse(wd);
        (uint256 zeroAcct,) = adapter.getAdapterBalanceForAsset(address(0), NATIVE);
        assertEq(zeroAcct, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xffffffff));
    }

    function test_protocolName() public view {
        assertEq(adapter.protocolName(), "StakeWise V3");
    }

    function test_positionLabels_fallbackWhenNoReceiptSymbol() public {
        // Empty receiptSymbol → bare ["Exit Queue"] breadcrumb.
        StakeWiseV3ExitQueueAssistedBalanceAdapter a2 =
            new StakeWiseV3ExitQueueAssistedBalanceAdapter(address(registry), NATIVE, "", address(balances), DELAY);
        string[] memory labels = a2.positionLabels(abi.encode(address(vault)));
        assertEq(labels.length, 1);
        assertEq(labels[0], "Exit Queue");
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], NATIVE);
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceStillOwed() public {
        BalancesHarness freshNav = new BalancesHarness();
        StakeWiseV3ExitQueueAssistedBalanceAdapter a2 = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            address(registry), NATIVE, "osETH", address(freshNav), DELAY
        );
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
        vm.prank(holder);
        a2.submit(address(vault), TICKET, TS);
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0);
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, NATIVE);
        assertEq(amt, 1 ether);
    }

    /// @dev Configuration-view probe: a consumer describing configuration has no positionId, so it can only call
    ///      `positionLabels("")`. This adapter's breadcrumb is positionId-INDEPENDENT (the leaf is the pinned
    ///      `receiptSymbol`), so the probe answers with the full constant breadcrumb.
    ///
    ///      What this pins is that the probe never silently collapses to `[]`. It does NOT forbid a vault-derived
    ///      leaf: the adapter accepts any VaultsRegistry-listed vault and emits `positionId = abi.encode(vault)`,
    ///      so several distinct positionIds share this one breadcrumb — the label is lossy today, and PR #163 made
    ///      exactly that improvement on the sibling `StakeWiseV3VaultsMetaBalanceAdapter`. If this adapter follows,
    ///      the probe must still return at least the `"Exit Queue"` category (the `_labels` empty-leaf convention),
    ///      and this assertion should be relaxed to that deliberately rather than deleted.
    function test_positionLabels_emptyProbe_returnsTheConstantShape() public view {
        string[] memory labels = adapter.positionLabels("");
        assertEq(labels.length, 2);
        assertEq(labels[0], "Exit Queue");
        assertEq(labels[1], "osETH");
    }

    /// @dev Static breadcrumb is `["Exit Queue", "osETH"]`; the ticket rides in the typed `positionInstanceId`.
    function _assertTicketLeg(INAVCalculator.PositionBalance memory leg) internal view {
        string[] memory labels = adapter.positionLabels(leg.positionId);
        assertEq(labels.length, 2);
        assertEq(labels[0], "Exit Queue");
        assertEq(labels[1], "osETH");
        assertTrue(leg.positionInstanceId != bytes32(0));
    }
}
