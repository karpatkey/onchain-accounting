// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {FablesRangeIndex} from "src/balances/MetaBalanceAdapters/fables/FablesRangeIndex.sol";
import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {InvalidArgumentsWithContext} from "src/errors.sol";
import {MockFablesHook, MockGriefHook} from "test/balances/MetaBalanceAdapters/fables/FablesMocks.sol";

/// @title FablesRangeIndex unit tests
/// @author KPK
/// @notice The index is the only thing that can answer "which ranges does this holder have": v4-core's
///         ERC6909 is a bare `mapping(owner => mapping(id => balance))` with no enumeration and no per-holder
///         count, so there is no number anywhere on chain to derive it from and none to check it against.
///         These tests pin the four properties that make a PERMISSIONLESS index safe to leave open: it
///         validates both ways, it refuses to prune live data, it buckets per (holder, hook), and a hook that
///         stops answering reads as empty rather than reverting a read that spans many entries.
contract FablesRangeIndexTest is Test {
    uint24 internal constant DYNAMIC_FEE = 8_388_608;
    uint256 internal constant RANGE_A = uint256(keccak256("range/A"));
    uint256 internal constant RANGE_B = uint256(keccak256("range/B"));
    uint256 internal constant RANGE_C = uint256(keccak256("range/C"));

    FablesRangeIndex internal index;
    MockFablesHook internal hookOne;
    MockFablesHook internal hookTwo;

    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        index = new FablesRangeIndex();
        hookOne = new MockFablesHook(makeAddr("recipient"));
        hookTwo = new MockFablesHook(makeAddr("recipient"));

        _open(hookOne, RANGE_A, holder, 100);
        _open(hookOne, RANGE_B, holder, 200);
        _open(hookTwo, RANGE_C, holder, 300);
    }

    function _key(address hook) internal pure returns (PoolKey memory) {
        return PoolKey({currency0: address(1), currency1: address(2), fee: DYNAMIC_FEE, tickSpacing: 10, hooks: hook});
    }

    function _open(MockFablesHook hook, uint256 id, address who, uint256 balance) internal {
        hook.setRange(id, _key(address(hook)), -100, 100, true);
        hook.setBalance(who, id, balance);
    }

    function _entry(address hook, uint256 id) internal pure returns (FablesRangeIndex.Entry[] memory e) {
        e = new FablesRangeIndex.Entry[](1);
        e[0] = FablesRangeIndex.Entry({hook: hook, rangeId: id});
    }

    //
    // filing
    //

    function test_indexFilesWhatTheChainConfirms() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));

        assertTrue(index.isIndexed(holder, address(hookOne), RANGE_A));
        assertEq(index.indexedCount(holder), 1);
        assertEq(index.liveCount(holder), 1);

        FablesRangeIndex.Entry[] memory filed = index.indexedRanges(holder);
        assertEq(filed.length, 1);
        assertEq(filed[0].hook, address(hookOne));
        assertEq(filed[0].rangeId, RANGE_A);
    }

    /// @notice Anyone may file; the holder is validated, not trusted, so there is nothing to protect.
    function test_indexIsPermissionless() public {
        vm.prank(stranger);
        index.index(holder, _entry(address(hookOne), RANGE_A));
        assertTrue(index.isIndexed(holder, address(hookOne), RANGE_A));
    }

    /// @notice Re-filing is a no-op, never a duplicate — including from a different caller.
    function test_indexIsIdempotent() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));
        vm.prank(stranger);
        index.index(holder, _entry(address(hookOne), RANGE_A));
        assertEq(index.indexedCount(holder), 1, "flat list");
        assertEq(index.indexedRangeIds(holder, address(hookOne)).length, 1, "bucket");
    }

    /// @notice An entry the chain does not confirm REVERTS rather than being skipped.
    /// @dev Deliberate: a caller who got the list wrong finds out, instead of quietly succeeding and leaving
    ///      a hole in the NAV that nothing anywhere would surface.
    function test_indexRevertsOnAnUnknownRange() public {
        uint256 ghost = uint256(keccak256("never deposited into"));
        vm.expectRevert(abi.encodeWithSelector(FablesRangeIndex.UnknownRange.selector, address(hookOne), ghost));
        index.index(holder, _entry(address(hookOne), ghost));
    }

    function test_indexRevertsWhenTheHolderHasNoBalance() public {
        address other = makeAddr("other");
        vm.expectRevert(abi.encodeWithSelector(FablesRangeIndex.NoBalance.selector, other, address(hookOne), RANGE_A));
        index.index(other, _entry(address(hookOne), RANGE_A));
    }

    function test_indexRejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "holder: zero address"));
        index.index(address(0), _entry(address(hookOne), RANGE_A));

        vm.expectRevert(abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "hook: zero address"));
        index.index(holder, _entry(address(0), RANGE_A));
    }

    /// @notice One bad entry reverts the WHOLE batch, so a partially-filed list is never left behind.
    function test_indexRevertsTheWholeBatch() public {
        FablesRangeIndex.Entry[] memory batch = new FablesRangeIndex.Entry[](2);
        batch[0] = FablesRangeIndex.Entry({hook: address(hookOne), rangeId: RANGE_A});
        batch[1] = FablesRangeIndex.Entry({hook: address(hookOne), rangeId: uint256(keccak256("ghost"))});
        vm.expectRevert();
        index.index(holder, batch);
        assertEq(index.indexedCount(holder), 0, "nothing filed");
    }

    //
    // per-(holder, hook) buckets — the 24 Sep 2026 fix
    //

    /// @notice Entries are bucketed by hook, so a reader can load one hook's ranges without touching anyone
    ///         else's.
    /// @dev This is what stops a hostile entry BLINDING the adapter. Before the fix the adapter walked every
    ///      filed entry and called its hook, so one entry naming a contract that reverts for the adapter
    ///      dropped the holder's rows for every pool, real ranges included.
    function test_bucketsAreKeptPerHook() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));
        index.index(holder, _entry(address(hookOne), RANGE_B));
        index.index(holder, _entry(address(hookTwo), RANGE_C));

        uint256[] memory one = index.indexedRangeIds(holder, address(hookOne));
        assertEq(one.length, 2);
        assertEq(one[0], RANGE_A);
        assertEq(one[1], RANGE_B);

        uint256[] memory two = index.indexedRangeIds(holder, address(hookTwo));
        assertEq(two.length, 1);
        assertEq(two[0], RANGE_C);

        assertEq(index.indexedRangeIds(holder, makeAddr("never filed")).length, 0);
        assertEq(index.indexedCount(holder), 3, "flat list holds all three");
    }

    /// @notice A grief hook's entry lands in ITS OWN bucket and cannot be pruned away by anyone.
    function test_griefEntryIsIsolatedAndUnprunable() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));

        MockGriefHook grief = new MockGriefHook(address(index), _key(address(hookOne)));
        vm.prank(stranger);
        index.index(holder, _entry(address(grief), 1));

        assertEq(index.indexedRangeIds(holder, address(grief)).length, 1, "its own bucket");
        assertEq(index.indexedRangeIds(holder, address(hookOne)).length, 1, "the real bucket is untouched");

        vm.expectRevert(
            abi.encodeWithSelector(FablesRangeIndex.EntryStillValid.selector, holder, address(grief), uint256(1))
        );
        index.prune(holder, _entry(address(grief), 1));
    }

    //
    // pruning
    //

    function test_pruneRefusesALiveEntry() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));
        vm.expectRevert(
            abi.encodeWithSelector(FablesRangeIndex.EntryStillValid.selector, holder, address(hookOne), RANGE_A)
        );
        index.prune(holder, _entry(address(hookOne), RANGE_A));
    }

    function test_pruneRefusesAnUnfiledEntry() public {
        vm.expectRevert(abi.encodeWithSelector(FablesRangeIndex.NotIndexed.selector, holder, address(hookOne), RANGE_A));
        index.prune(holder, _entry(address(hookOne), RANGE_A));
    }

    /// @notice Pruning the MIDDLE entry keeps both the flat list and the per-hook bucket consistent.
    /// @dev The two swap-and-pops have to agree; a bug in either leaves an id readable from one view and not
    ///      the other, which would either hide a live range or resurrect a dead one.
    function test_pruneSwapAndPopKeepsBothViewsConsistent() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));
        index.index(holder, _entry(address(hookOne), RANGE_B));
        index.index(holder, _entry(address(hookTwo), RANGE_C));

        // A re-centre empties range B.
        hookOne.setBalance(holder, RANGE_B, 0);
        assertEq(index.liveCount(holder), 2, "B is already excluded from live before anyone prunes");

        index.prune(holder, _entry(address(hookOne), RANGE_B));

        assertFalse(index.isIndexed(holder, address(hookOne), RANGE_B), "B gone");
        assertTrue(index.isIndexed(holder, address(hookOne), RANGE_A), "A kept");
        assertTrue(index.isIndexed(holder, address(hookTwo), RANGE_C), "C kept");
        assertEq(index.indexedCount(holder), 2, "flat list");

        uint256[] memory one = index.indexedRangeIds(holder, address(hookOne));
        assertEq(one.length, 1);
        assertEq(one[0], RANGE_A, "the surviving id, not the moved one");
        assertEq(index.indexedRangeIds(holder, address(hookTwo)).length, 1, "the other bucket is untouched");

        // The flat list still contains exactly A and C, in some order.
        FablesRangeIndex.Entry[] memory filed = index.indexedRanges(holder);
        assertEq(filed.length, 2);
        bool sawA;
        bool sawC;
        for (uint256 i; i < filed.length; ++i) {
            if (filed[i].rangeId == RANGE_A) sawA = true;
            if (filed[i].rangeId == RANGE_C) sawC = true;
        }
        assertTrue(sawA && sawC, "flat list contents");

        // And the range can be re-filed afterwards, which proves both slot maps were cleared.
        hookOne.setBalance(holder, RANGE_B, 42);
        index.index(holder, _entry(address(hookOne), RANGE_B));
        assertEq(index.indexedRangeIds(holder, address(hookOne)).length, 2, "re-filed into its bucket");
    }

    /// @notice Pruning the LAST entry takes the no-swap branch.
    function test_pruneLastEntry() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));
        hookOne.setBalance(holder, RANGE_A, 0);
        index.prune(holder, _entry(address(hookOne), RANGE_A));
        assertEq(index.indexedCount(holder), 0);
        assertEq(index.indexedRangeIds(holder, address(hookOne)).length, 0);
    }

    //
    // staleness is the normal state
    //

    /// @notice {liveRanges} and {liveCount} re-check the balance at read time.
    /// @dev A vfat re-centre withdraws a range to zero and deposits a new one, so a filed rangeId is
    ///      routinely dead. That is the normal state, not an error — nothing here reverts over it.
    function test_liveViewsReCheckTheBalance() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));
        index.index(holder, _entry(address(hookOne), RANGE_B));
        hookOne.setBalance(holder, RANGE_A, 0);

        assertEq(index.indexedCount(holder), 2, "both still filed");
        assertEq(index.liveCount(holder), 1, "one still carries a balance");

        FablesRangeIndex.Entry[] memory live = index.liveRanges(holder);
        assertEq(live.length, 1);
        assertEq(live[0].rangeId, RANGE_B);
    }

    /// @notice A hook that stops answering `balanceOf` reads as EMPTY rather than reverting the read.
    /// @dev Fail-open is correct at this depth: one SLOAD behind one bounded staticcall, so there is no
    ///      nested read whose out-of-gas could hide inside it. The consequence is the safe one — the entry
    ///      becomes prunable and drops out of {liveRanges} — and the alternative is one broken hook reverting
    ///      a read that spans every entry the holder has.
    function test_failedBalanceReadsAsZeroAndStaysPrunable() public {
        index.index(holder, _entry(address(hookOne), RANGE_A));
        index.index(holder, _entry(address(hookTwo), RANGE_C));

        hookOne.setBalanceOfReverts(true);

        assertEq(index.liveCount(holder), 1, "the broken hook's entry reads as empty, the other survives");
        assertEq(index.liveRanges(holder).length, 1);
        index.prune(holder, _entry(address(hookOne), RANGE_A));
        assertFalse(index.isIndexed(holder, address(hookOne), RANGE_A), "prunable");
    }

    //
    // view surface
    //

    function test_viewsOnAnUnknownHolder() public {
        address nobody = makeAddr("nobody");
        assertEq(index.indexedCount(nobody), 0);
        assertEq(index.liveCount(nobody), 0);
        assertEq(index.indexedRanges(nobody).length, 0);
        assertEq(index.liveRanges(nobody).length, 0);
        assertEq(index.indexedRangeIds(nobody, address(hookOne)).length, 0);
        assertFalse(index.isIndexed(nobody, address(hookOne), RANGE_A));
    }
}
