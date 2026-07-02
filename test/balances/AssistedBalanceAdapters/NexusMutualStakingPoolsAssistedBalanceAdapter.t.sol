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
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

/// @title NexusMutualStakingPoolsAssistedBalanceAdapter unit tests (wrapper-fed)
/// @notice The Nexus staking adapter is wrapper-fed: a `SUBMITTER_ROLE` contract feeds coordinates via incremental
///         `submit`/`remove` (single id). Covers the feed surface, per-NFT valuation legs, labels, read-time
///         ownership discard, fault isolation, and interface support.
contract NexusMutualStakingPoolsAssistedBalanceAdapterTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    Mock_ERC20 public nxm;

    address holder = makeAddr("holder");
    address other = makeAddr("other");

    bytes32 constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        // admin + wrapper = this test, so it can submit/remove tokenIds directly.
        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(0), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroViewer() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(0), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(0), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(0), address(this), address(this)
        );
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "StakingNFT"));
        new NexusMutualStakingPoolsAssistedBalanceAdapter(
            makeAddr("eoa"), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_roles_grantedToConstructorArgs() public view {
        assertTrue(adapter.hasRole(SUBMITTER_ROLE, address(this)));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(adapter.hasRole(SUBMITTER_ROLE, other));
    }

    function test_constructor_wrapperOptional() public {
        NexusMutualStakingPoolsAssistedBalanceAdapter a2 = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this), address(0)
        );
        assertFalse(a2.hasRole(SUBMITTER_ROLE, address(this)));
        assertTrue(a2.hasRole(a2.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ---- Feed (wrapper) + valuation ----

    /// @dev Seed an owned token for `holder` in pool `pool`, value it, and submit its id (single, incremental).
    function _seedOne(uint256 id, uint256 pool, uint256 a, uint256 e, uint256 r) internal {
        nft.setToken(id, pool, holder);
        viewer.setToken(id, pool, a, e, r);
        adapter.submit(holder, id);
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
        adapter.submit(holder, 2); // duplicate
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
        adapter.submit(holder, 1);
        adapter.submit(holder, 2);

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
            address(nft), address(viewer), address(nxm), address(freshNav), address(this), address(this)
        );
        nft.setToken(1, 1, holder);
        viewer.setToken(1, 1, 100, 0, 5);
        a2.submit(holder, 1);
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

    // ---- Wrapper-fed cache behaviour ----

    function test_submit_onlyWrapperRole() public {
        nft.setToken(1, 1, holder);
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, SUBMITTER_ROLE)
        );
        adapter.submit(holder, 1);
    }

    function test_submit_revertsOnZeroAccount() public {
        nft.setToken(1, 1, holder);
        vm.expectRevert(InvalidArguments.selector);
        adapter.submit(address(0), 1);
    }

    /// @notice Writes are fail-loud: submitting an id not owned by the account reverts NotTokenOwner (rolling back the
    ///         wrapper's deposit tx).
    function test_submit_revertsOnNonOwnedId() public {
        nft.setToken(1, 1, other); // owned by `other`, not holder
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, holder, uint256(1)));
        adapter.submit(holder, 1);
    }

    /// @notice Ownership is re-verified on EVERY submit — re-submitting an already-cached id the account has since
    ///         transferred away reverts NotTokenOwner (the check is not bypassed by the dedup).
    function test_submit_reverifiesOwnershipOnResubmit() public {
        _seedOne(2, 1, 100, 0, 0); // holder owns 2 and it is cached
        nft.setToken(2, 1, other); // 2 transferred to `other`
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, holder, uint256(2)));
        adapter.submit(holder, 2);
    }

    function test_remove_onlyWrapperRole() public {
        _seedOne(1, 1, 100, 0, 0);
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, SUBMITTER_ROLE)
        );
        adapter.remove(holder, 1);
    }

    function test_remove_stopsTracking() public {
        _seedOne(1, 1, 100, 0, 0);
        _seedOne(2, 1, 200, 0, 0);
        viewer.setToken(1, 1, 0, 0, 0); // fully claim token 1 (zero remaining value) so it can be untracked
        adapter.remove(holder, 1);
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 200);
    }

    /// @notice remove reverts TokenIdNotClaimed for a still-valued position (must be fully withdrawn first).
    function test_remove_revertsIfNotClaimed() public {
        _seedOne(1, 1, 100, 0, 0); // holder owns 1, value 100 (not claimed)
        vm.expectRevert(abi.encodeWithSelector(TokenIdNotClaimed.selector, holder, uint256(1)));
        adapter.remove(holder, 1);
    }

    /// @notice Owned-but-uncached id: remove passes the ownership check and is a no-op (no revert, no event).
    function test_remove_ownedButUncached_noop() public {
        _seedOne(1, 1, 100, 0, 0);
        nft.setToken(999, 1, holder); // holder owns 999 but it was never cached
        adapter.remove(holder, 999);
        assertEq(adapter.tokenIdsOf(holder).length, 1);
    }

    /// @notice remove verifies ownership too — removing an id not owned by `account` reverts NotTokenOwner.
    function test_remove_revertsOnNonOwnedId() public {
        _seedOne(1, 1, 100, 0, 0);
        nft.setToken(1, 1, other); // 1 transferred away from holder
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, holder, uint256(1)));
        adapter.remove(holder, 1);
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

    // ---- Admin rescue ----

    function test_clearAccount_admin() public {
        _seedOne(1, 1, 100, 0, 0);
        adapter.clearAccount(holder);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_clearAccount_onlyAdmin() public {
        _seedOne(1, 1, 100, 0, 0);
        bytes32 adminRole = adapter.DEFAULT_ADMIN_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole)
        );
        adapter.clearAccount(holder);
    }

    // ---- Uncapped accumulation + never-revert ----

    /// @notice No per-account cap: many owned ids accumulate without reverting.
    function test_noCap_accumulatesManyIds() public {
        uint256 count = 100; // well past the old 64 cap
        for (uint256 i = 0; i < count; i++) {
            uint256 id = i + 1;
            nft.setToken(id, 1, holder);
            viewer.setToken(id, 1, 1, 0, 0);
            adapter.submit(holder, id);
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
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], address(nxm));
    }
}
