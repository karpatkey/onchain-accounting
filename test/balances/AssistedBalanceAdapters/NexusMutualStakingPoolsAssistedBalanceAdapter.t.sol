// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter,
    INexusStakingViewer
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of Nexus's StakingNFT — `tokenInfo(id) -> (poolId, owner)`. Unset ids return
///         (0, address(0)); `setRevertId` makes one id revert to exercise the read-time try/catch.
contract MockStakingNFT {
    mapping(uint256 => address) private _owner;
    mapping(uint256 => uint256) private _pool;
    uint256 public revertId; // 0 = none

    function setToken(uint256 id, uint256 poolId, address owner) external {
        _pool[id] = poolId;
        _owner[id] = owner;
    }

    function setRevertId(uint256 id) external {
        revertId = id;
    }

    function tokenInfo(uint256 id) external view returns (uint256, address) {
        require(id != revertId || revertId == 0, "tokenInfo revert");
        return (_pool[id], _owner[id]);
    }
}

/// @notice Minimal mock of Nexus's StakingViewer — stores per-token (poolId, active, expired, rewards) and returns
///         them via `getTokens` / `getAggregatedTokens`.
contract MockStakingViewer {
    mapping(uint256 => uint256) public poolId;
    mapping(uint256 => uint256) public active;
    mapping(uint256 => uint256) public expired;
    mapping(uint256 => uint256) public rewards;
    bool public doRevert;

    function setToken(uint256 id, uint256 pool, uint256 a, uint256 e, uint256 r) external {
        poolId[id] = pool;
        active[id] = a;
        expired[id] = e;
        rewards[id] = r;
    }

    function setRevert(bool v) external {
        doRevert = v;
    }

    function getTokens(uint256[] calldata ids) external view returns (INexusStakingViewer.Token[] memory tokens) {
        require(!doRevert, "tokens revert");
        tokens = new INexusStakingViewer.Token[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            tokens[i] = INexusStakingViewer.Token({
                tokenId: ids[i],
                poolId: poolId[ids[i]],
                activeStake: active[ids[i]],
                expiredStake: expired[ids[i]],
                rewards: rewards[ids[i]],
                deposits: new INexusStakingViewer.Deposit[](0)
            });
        }
    }

    function getAggregatedTokens(uint256[] calldata ids)
        external
        view
        returns (INexusStakingViewer.AggregatedTokens memory agg)
    {
        require(!doRevert, "agg revert");
        for (uint256 i; i < ids.length; ++i) {
            agg.totalActiveStake += active[ids[i]];
            agg.totalExpiredStake += expired[ids[i]];
            agg.totalRewards += rewards[ids[i]];
        }
    }

    /// @notice Deterministic non-zero staking-pool address per poolId (the positionId). Mirror via `poolAddr`.
    function stakingPool(uint256 pid) external pure returns (address) {
        return poolAddr(pid);
    }

    function poolAddr(uint256 pid) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("nexus-staking-pool", pid)))));
    }
}

/// @notice Minimal Nexus StakingPool mock exposing `getPoolId()` for the positionLabels "Pool #<id>" leaf.
contract MockNexusStakingPool {
    uint256 private immutable _poolId;

    constructor(uint256 poolId_) {
        _poolId = poolId_;
    }

    function getPoolId() external view returns (uint256) {
        return _poolId;
    }
}

/// @title NexusMutualStakingPoolsAssistedBalanceAdapter unit tests (permissionless, wrapper-fed)
/// @notice The Nexus staking adapter is permissionless wrapper-fed: `submit`/`remove` are `msg.sender`-keyed (the
///         owner Safe delegatecalls the wrapper, so the adapter sees the Safe as `msg.sender`). Covers the feed
///         surface, per-NFT valuation legs, labels, read-time ownership discard, fault isolation, and interfaces.
contract NexusMutualStakingPoolsAssistedBalanceAdapterTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    Mock_ERC20 public nxm;

    address holder = makeAddr("holder");
    address other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(address(0), address(viewer), address(nxm), address(balances));
    }

    function test_constructor_revertsOnZeroViewer() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(address(nft), address(0), address(nxm), address(balances));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(address(nft), address(viewer), address(0), address(balances));
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(address(nft), address(viewer), address(nxm), address(0));
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "StakingNFT"));
        new NexusMutualStakingPoolsAssistedBalanceAdapter(
            makeAddr("eoa"), address(viewer), address(nxm), address(balances)
        );
    }

    // ---- Feed (permissionless, msg.sender-keyed) + valuation ----

    /// @dev Seed an owned token for `holder` in pool `pool`, value it, and submit its id AS the holder (single).
    function _seedOne(uint256 id, uint256 pool, uint256 a, uint256 e, uint256 r) internal {
        nft.setToken(id, pool, holder);
        viewer.setToken(id, pool, a, e, r);
        vm.prank(holder);
        adapter.submit(id);
    }

    /// @notice Incremental submits ACCUMULATE (unlike the assistant-fed full-set replace).
    function test_submit_accumulates() public {
        _seedOne(2, 1, 100, 10, 3);
        _seedOne(5, 1, 100, 10, 3);
        assertEq(adapter.tokenIdsOf(holder).length, 2);
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        // staking = (100+10)*2 = 220; rewards = 3*2 = 6; total = 226
        assertEq(amt, 226);
        assertEq(d, false);
    }

    /// @notice Re-submitting an already-cached id is a no-op (idempotent) — the count and value do not change.
    function test_submit_idempotent() public {
        _seedOne(2, 1, 100, 0, 5);
        vm.prank(holder);
        adapter.submit(2); // duplicate
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 105);
    }

    function test_unsubmittedAccount_zero() public {
        _seedOne(3, 1, 100, 0, 5);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(other, address(nxm));
        assertEq(amt, 0);
    }

    function test_balanceForWrongAsset_zero() public {
        _seedOne(1, 1, 100, 0, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amt, 0);
    }

    // ---- getAdapterPositions: per-NFT legs + identity ----

    function test_positions_stakingAndRewardsLegs() public {
        _seedOne(4, 7, 100, 20, 7); // pool 7
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 120);
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[1].amount, 7);
        bytes memory expectedId = abi.encode(viewer.poolAddr(7));
        for (uint256 i; i < 2; i++) {
            assertEq(p[i].balanceAsset.asset, address(nxm));
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolSubId, ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS);
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_MUTUAL);
            assertEq(p[i].positionId, expectedId);
            assertEq(p[i].isDebt, false);
            string[] memory lbl = adapter.positionLabels(p[i].positionId);
            assertEq(lbl.length, 2);
            assertEq(lbl[0], "Staking Pools");
            assertEq(lbl[1], Strings.toHexString(viewer.poolAddr(7)));
            assertEq(p[i].positionInstanceId, bytes32(uint256(4)));
        }
    }

    function test_positionLabels_poolIdLeaf() public {
        MockNexusStakingPool pool = new MockNexusStakingPool(42);
        string[] memory lbl = adapter.positionLabels(abi.encode(address(pool)));
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "Staking Pools");
        assertEq(lbl[1], "Pool #42");
    }

    function test_positions_twoPools_distinctPositionIds() public {
        nft.setToken(1, 7, holder);
        viewer.setToken(1, 7, 100, 0, 1);
        nft.setToken(2, 9, holder);
        viewer.setToken(2, 9, 200, 0, 2);
        vm.prank(holder);
        adapter.submit(1);
        vm.prank(holder);
        adapter.submit(2);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 4);
        assertEq(p[0].positionId, abi.encode(viewer.poolAddr(7)));
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
        assertEq(p[0].amount, 100);
        assertEq(p[2].positionId, abi.encode(viewer.poolAddr(9)));
        assertEq(p[2].positionInstanceId, bytes32(uint256(2)));
        assertEq(p[2].amount, 200);
    }

    function test_positions_emptyWhenNothingSubmitted() public view {
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_positions_assetFilterMatch_andMismatch() public {
        _seedOne(1, 1, 100, 0, 0);
        assertEq(adapter.getAdapterPositions(holder, address(nxm)).length, 1);
        assertEq(adapter.getAdapterPositions(holder, address(weth)).length, 0);
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceOwed() public {
        BalancesHarness freshNav = new BalancesHarness();
        NexusMutualStakingPoolsAssistedBalanceAdapter a2 = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(freshNav)
        );
        nft.setToken(1, 1, holder);
        viewer.setToken(1, 1, 100, 0, 5);
        vm.prank(holder);
        a2.submit(1);
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0);
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 105);
    }

    function test_getAdapterBalances_shape() public {
        _seedOne(2, 1, 100, 0, 5);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(nxm));
        assertEq(amounts[0], 105);
        assertEq(isDebt[0], false);
    }

    // ---- Feed cache behaviour ----

    /// @notice Writes are fail-loud: submitting an id not owned by the caller reverts CoordinateNotOwned.
    function test_submit_revertsOnNonOwnedId() public {
        nft.setToken(1, 1, other); // owned by `other`, not holder
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, uint256(1)));
        adapter.submit(1);
    }

    /// @notice Ownership is re-verified on EVERY submit — re-submitting an already-cached id the caller has since
    ///         transferred away reverts CoordinateNotOwned (the check is not bypassed by the dedup).
    function test_submit_reverifiesOwnershipOnResubmit() public {
        _seedOne(2, 1, 100, 0, 0); // holder owns 2 and it is cached
        nft.setToken(2, 1, other); // 2 transferred to `other`
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, uint256(2)));
        adapter.submit(2);
    }

    /// @notice Removing an emptied (fully-withdrawn) id stops tracking it; a still-live sibling is untouched.
    function test_remove_emptiedIdStopsTracking() public {
        _seedOne(1, 1, 100, 0, 0);
        _seedOne(2, 1, 200, 0, 0);
        viewer.setToken(1, 1, 0, 0, 0); // id 1 fully withdrawn (owned, but no stake/rewards) → removable
        vm.prank(holder);
        adapter.remove(1);
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 200);
    }

    /// @notice Removing an id the caller never cached is fail-loud (CoordinateNotCached), even if the caller owns it.
    function test_remove_uncachedReverts() public {
        _seedOne(1, 1, 100, 0, 0);
        nft.setToken(999, 1, holder); // holder owns 999 but it was never cached
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, holder, uint256(999)));
        adapter.remove(999);
    }

    /// @notice A still-live position (owned, with active/expired stake or rewards) is NOT removable — remove is
    ///         fail-loud (CoordinateStillLive), so a partial/rewards-only withdraw can never silently drop it.
    function test_remove_liveIdReverts() public {
        _seedOne(1, 1, 100, 0, 0);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, uint256(1)));
        adapter.remove(1);
    }

    /// @notice Nexus does not burn the StakingNFT, but an id transferred away is no longer owned → removable.
    function test_remove_transferredAwayIdRemovable() public {
        _seedOne(1, 1, 100, 0, 0);
        nft.setToken(1, 1, other); // 1 transferred away from holder → no longer owned
        vm.prank(holder);
        adapter.remove(1);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    /// @notice Reads are fail-open: an id transferred away after submission is silently discarded.
    function test_read_discardsTransferredId() public {
        _seedOne(1, 1, 100, 0, 0);
        _seedOne(2, 1, 200, 0, 0);
        nft.setToken(1, 1, other);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].positionInstanceId, bytes32(uint256(2)));
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 200);
    }

    function test_read_discardsRevertingId() public {
        _seedOne(2, 1, 100, 0, 0);
        _seedOne(4, 1, 100, 0, 0);
        nft.setRevertId(2);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 100);
    }

    // ---- Self-service clear ----

    function test_clearAccount_self() public {
        _seedOne(1, 1, 100, 0, 0);
        vm.prank(holder);
        adapter.clearAccount();
        assertEq(adapter.tokenIdsOf(holder).length, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    // ---- Accumulation + never-revert ----

    /// @notice Many owned ids accumulate (well past the old 64 cap; the shared cap is 256).
    function test_accumulatesManyIds() public {
        uint256 count = 100;
        for (uint256 i = 0; i < count; i++) {
            uint256 id = i + 1;
            nft.setToken(id, 1, holder);
            viewer.setToken(id, 1, 1, 0, 0);
            vm.prank(holder);
            adapter.submit(id);
        }
        assertEq(adapter.tokenIdsOf(holder).length, count);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, count); // 1 active NXM each
    }

    function test_viewerReverts_balanceZero() public {
        _seedOne(1, 1, 100, 0, 0);
        viewer.setRevert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_viewerReverts_positionsEmpty() public {
        _seedOne(1, 1, 100, 0, 5);
        viewer.setRevert(true);
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAssistedBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], address(nxm));
    }
}
