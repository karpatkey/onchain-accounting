// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {FablesRangeIndex} from "src/balances/MetaBalanceAdapters/fables/FablesRangeIndex.sol";
import {IFablesHook} from "src/balances/MetaBalanceAdapters/fables/IFablesHook.sol";
import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {InvalidArgumentsWithContext} from "src/errors.sol";
import {MockGriefHook} from "test/balances/MetaBalanceAdapters/fables/FablesMocks.sol";

/// @title FablesRangeIndexForkTest
/// @author KPK
/// @notice Fork tests for the discovery index against a REAL Fables hook on chain 4663, at a pinned block.
///
/// @dev The index's whole safety argument is "it takes nothing on the caller's word, it asks the chain" —
///      which can only be tested against a chain. Here the hook is the live kRHETH Fables hook
///      `0x06a8…6080`, the holder is the vault's real vfat Sickle `0x744b…cac6`, and the range is the one it
///      actually holds. MEASURED 16 Oct 2026 at {FORK_BLOCK} = 90,186,157: `balanceOf(sickle, rangeId)` is
///      6,467,343,454,345,013 and `rangeKey(rangeId).set` is true, ticks [-198070, -196620].
///
///      Everything here runs against a FRESHLY deployed index rather than the live one, so the assertions
///      are about this source rather than about whatever is already filed on chain.
contract FablesRangeIndexForkTest is BalanceAdapterTestBase {
    uint256 public constant FORK_BLOCK = 90_186_157;

    address public constant HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    address public constant SICKLE = 0x744b5597203E2a49169c2E49Bc671A065Ec6cac6;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 public constant RANGE_ID = 0x28f2d251381722a5606bd2aeae9f0e2889a215a774d1deb95131dc24d352c4af;
    uint256 public constant SHARES = 6_467_343_454_345_013;
    uint24 public constant DYNAMIC_FEE = 8_388_608;

    FablesRangeIndex public index;
    address public stranger;

    function setUp() public override {
        super.setUp();
        index = new FablesRangeIndex();
        stranger = makeAddr("stranger");
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("robinhood-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: address(0), currency1: USDG, fee: DYNAMIC_FEE, tickSpacing: 10, hooks: HOOK});
    }

    function _entry(address hook, uint256 id) internal pure returns (FablesRangeIndex.Entry[] memory e) {
        e = new FablesRangeIndex.Entry[](1);
        e[0] = FablesRangeIndex.Entry({hook: hook, rangeId: id});
    }

    /// @notice The fixture is what this suite claims it is, read straight off the hook.
    function test_fixtureIsLiveAtTheForkBlock() public view {
        (,,, bool set) = IFablesHook(HOOK).rangeKey(RANGE_ID);
        assertTrue(set, "the hook has a preimage for this range");
        assertEq(IFablesHook(HOOK).balanceOf(SICKLE, RANGE_ID), SHARES, "the Sickle holds the shares");
    }

    /// @notice Anyone may file, and the entry is accepted only because the chain confirms it.
    /// @dev There is no argument that attributes a position to a holder who does not have the balance, so
    ///      there is nothing for an owner or an allowlist to protect — which is why neither exists and the
    ///      operator never becomes a bottleneck.
    function test_permissionlessFilingOfARealRange() public {
        vm.prank(stranger);
        index.index(SICKLE, _entry(HOOK, RANGE_ID));

        assertTrue(index.isIndexed(SICKLE, HOOK, RANGE_ID));
        assertEq(index.indexedCount(SICKLE), 1);
        assertEq(index.liveCount(SICKLE), 1);

        uint256[] memory bucket = index.indexedRangeIds(SICKLE, HOOK);
        assertEq(bucket.length, 1);
        assertEq(bucket[0], RANGE_ID, "filed into the hook's own bucket");
    }

    /// @notice A real hook, a real holder, but a range that holder does not hold: refused.
    function test_realHookRefusesAHolderWithNoBalance() public {
        address outsider = makeAddr("outsider");
        vm.expectRevert(abi.encodeWithSelector(FablesRangeIndex.NoBalance.selector, outsider, HOOK, RANGE_ID));
        index.index(outsider, _entry(HOOK, RANGE_ID));
    }

    /// @notice A rangeId the live hook has never seen is refused rather than skipped.
    function test_realHookRefusesAnUnknownRange() public {
        uint256 ghost = uint256(keccak256("never deposited into"));
        vm.expectRevert(abi.encodeWithSelector(FablesRangeIndex.UnknownRange.selector, HOOK, ghost));
        index.index(SICKLE, _entry(HOOK, ghost));
    }

    function test_rejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "holder: zero address"));
        index.index(address(0), _entry(HOOK, RANGE_ID));
        vm.expectRevert(abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "hook: zero address"));
        index.index(SICKLE, _entry(address(0), RANGE_ID));
    }

    /// @notice An open prune cannot be used to blind the adapter: a live entry is refused.
    function test_pruneRefusesTheLiveVaultEntry() public {
        index.index(SICKLE, _entry(HOOK, RANGE_ID));
        vm.expectRevert(abi.encodeWithSelector(FablesRangeIndex.EntryStillValid.selector, SICKLE, HOOK, RANGE_ID));
        index.prune(SICKLE, _entry(HOOK, RANGE_ID));
    }

    /// @notice A hostile hook's entries sit in their own bucket, which nothing that values a position loads.
    /// @dev The 24 Sep 2026 fix, against the real hook. The grief contract answers the index (so {prune}
    ///      refuses it) and reverts for everyone else; before the bucketing, the adapter's read of this
    ///      holder failed for every pool because of it.
    function test_hostileEntryIsBucketedAwayFromTheRealHook() public {
        index.index(SICKLE, _entry(HOOK, RANGE_ID));

        MockGriefHook grief = new MockGriefHook(address(index), _key());
        vm.prank(stranger);
        index.index(SICKLE, _entry(address(grief), 1));

        assertEq(index.indexedCount(SICKLE), 2, "both are filed");
        assertEq(index.indexedRangeIds(SICKLE, HOOK).length, 1, "the real bucket holds exactly the real range");
        assertEq(index.indexedRangeIds(SICKLE, HOOK)[0], RANGE_ID);
        assertEq(index.indexedRangeIds(SICKLE, address(grief)).length, 1, "the hostile entry is elsewhere");

        vm.expectRevert(
            abi.encodeWithSelector(FablesRangeIndex.EntryStillValid.selector, SICKLE, address(grief), uint256(1))
        );
        index.prune(SICKLE, _entry(address(grief), 1));
    }

    /// @notice An entry naming an address that is not a hook at all reads as empty rather than reverting.
    /// @dev Fail-open on {liveCount}/{liveRanges}, which is what keeps one broken entry from taking down a
    ///      read that spans every entry a holder has. Such an entry cannot be FILED (the typed `rangeKey`
    ///      call on the write path reverts), so it is injected here by filing a conforming hook and then
    ///      pointing the same address at nothing.
    function test_liveViewsSurviveAnEntryThatStopsAnswering() public {
        index.index(SICKLE, _entry(HOOK, RANGE_ID));
        assertEq(index.liveCount(SICKLE), 1);

        // The hook stops answering `balanceOf` entirely.
        vm.mockCallRevert(HOOK, abi.encodeWithSelector(IFablesHook.balanceOf.selector), "gone");
        assertEq(index.liveCount(SICKLE), 0, "unreadable reads as empty, not as a revert");
        assertEq(index.liveRanges(SICKLE).length, 0);

        // And the entry is then prunable, which is the safe direction.
        index.prune(SICKLE, _entry(HOOK, RANGE_ID));
        assertFalse(index.isIndexed(SICKLE, HOOK, RANGE_ID));
        assertEq(index.indexedRangeIds(SICKLE, HOOK).length, 0, "bucket cleared in step with the flat list");
    }

    /// @notice Staleness is the normal state: a vfat re-centre empties a range and the index notices.
    function test_emptiedRangeDropsOutOfLiveAndIsPrunable() public {
        index.index(SICKLE, _entry(HOOK, RANGE_ID));

        // Simulate the re-centre's effect on this holder's balance without driving the hook's own withdraw,
        // which would also move pool state this suite does not assert on.
        vm.mockCall(
            HOOK, abi.encodeWithSelector(IFablesHook.balanceOf.selector, SICKLE, RANGE_ID), abi.encode(uint256(0))
        );
        assertEq(index.liveCount(SICKLE), 0, "live re-checks the balance at read time");
        assertEq(index.indexedCount(SICKLE), 1, "the entry is still filed; pruning is a separate step");

        index.prune(SICKLE, _entry(HOOK, RANGE_ID));
        assertEq(index.indexedCount(SICKLE), 0);
    }
}
