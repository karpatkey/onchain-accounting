// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    NexusMutualStakingPoolsBalanceAdapter,
    INexusStakingViewer
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
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

/// @notice Minimal mock of Nexus's StakingViewer — stores per-token (poolId, active, expired, rewards)
///         and returns them via both `getTokens` (per-token, used for positions) and
///         `getAggregatedTokens` (summed, used by the no-arg balance getters).
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

/// @title NexusMutualStakingPoolsBalanceAdapter unit tests (assisted, agent-fed)
contract NexusMutualStakingPoolsBalanceAdapterTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsBalanceAdapter public adapter;
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    Mock_ERC20 public nxm;

    address holder = makeAddr("holder");
    address other = makeAddr("other");

    bytes32 constant ASSISTANT_ROLE = keccak256("ASSISTANT_ROLE");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        // admin + assistant = this test, so it can submit/clear tokenIds.
        adapter = new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(0), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroViewer() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(0), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(0), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(0), address(this), address(this)
        );
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(bytes("StakingNFT must be a contract"));
        new NexusMutualStakingPoolsBalanceAdapter(
            makeAddr("eoa"), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_roles_grantedToConstructorArgs() public view {
        assertTrue(adapter.hasRole(ASSISTANT_ROLE, address(this)));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(adapter.hasRole(ASSISTANT_ROLE, other));
    }

    // ---- Discovery (agent-fed) + valuation ----

    /// @dev Seed an owned token for `holder` in pool `pool`, value it, and submit its id to the cache.
    function _seedOne(uint256 id, uint256 pool, uint256 a, uint256 e, uint256 r) internal {
        nft.setToken(id, pool, holder);
        viewer.setToken(id, pool, a, e, r);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        adapter.submitTokenIds(holder, ids);
    }

    function test_submittedTokensAggregate() public {
        // Submit is replace semantics, so both ids must go in ONE list (two separate submits would replace, not
        // accumulate). Seed the mock state for both, then submit them together.
        nft.setToken(2, 1, holder);
        viewer.setToken(2, 1, 100, 10, 3);
        nft.setToken(5, 1, holder);
        viewer.setToken(5, 1, 100, 10, 3); // each owned: 100 active + 10 expired + 3 rewards
        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 5;
        adapter.submitTokenIds(holder, ids);
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        // staking = (100+10)*2 = 220; rewards = 3*2 = 6; total = 226
        assertEq(amt, 226);
        assertEq(d, false);
    }

    function test_unsubmittedAccount_zero() public {
        _seedOne(3, 1, 100, 0, 5);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(other, address(nxm));
        assertEq(amt, 0); // `other` has no submitted ids
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
        // leg 0 = Staking (active+expired = 120), leg 1 = Rewards (7)
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 120);
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[1].amount, 7);
        bytes memory expectedId = abi.encode(viewer.poolAddr(7)); // positionId = staking-pool address
        for (uint256 i; i < 2; i++) {
            assertEq(p[i].balanceAsset.asset, address(nxm));
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolSubId, ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS);
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_MUTUAL);
            assertEq(p[i].positionId, expectedId);
            assertEq(p[i].isDebt, false);
            // Static breadcrumb = [category, pool address] (positionId-derived); the NFT id rides in positionInstanceId.
            string[] memory lbl = adapter.positionLabels(p[i].positionId);
            assertEq(lbl.length, 2);
            assertEq(lbl[0], "Staking Pools");
            assertEq(lbl[1], Strings.toHexString(viewer.poolAddr(7)));
            assertEq(p[i].positionInstanceId, bytes32(uint256(4)));
        }
    }

    /// @dev Two positions in two different pools → 4 legs, each keyed by its own (tokenId, poolId). Read order
    ///      follows the cache (submission) order: token 1 then token 2.
    function test_positions_twoPools_distinctPositionIds() public {
        nft.setToken(1, 7, holder);
        viewer.setToken(1, 7, 100, 0, 1);
        nft.setToken(2, 9, holder);
        viewer.setToken(2, 9, 200, 0, 2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        adapter.submitTokenIds(holder, ids);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 4); // (Staking+Rewards) x 2 tokens
        // token 1 → pool 7 (cache order); positionId = pool address, NFT id in positionInstanceId
        assertEq(p[0].positionId, abi.encode(viewer.poolAddr(7)));
        assertEq(p[1].positionId, abi.encode(viewer.poolAddr(7)));
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
        assertEq(p[0].amount, 100);
        assertEq(p[1].amount, 1);
        // token 2 → pool 9
        assertEq(p[2].positionId, abi.encode(viewer.poolAddr(9)));
        assertEq(p[3].positionId, abi.encode(viewer.poolAddr(9)));
        assertEq(p[2].positionInstanceId, bytes32(uint256(2)));
        assertEq(p[2].amount, 200);
        assertEq(p[3].amount, 2);
    }

    function test_positions_onlyStakingWhenNoRewards() public {
        _seedOne(1, 3, 50, 0, 0);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 50);
        assertEq(p[0].positionId, abi.encode(viewer.poolAddr(3)));
    }

    function test_positions_onlyRewardsWhenNoStake() public {
        _seedOne(1, 3, 0, 0, 9);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[0].amount, 9);
    }

    function test_positions_emptyWhenNothingSubmitted() public view {
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_positions_assetFilterMatch_andMismatch() public {
        _seedOne(1, 1, 100, 0, 0);
        assertEq(adapter.getAdapterPositions(holder, address(nxm)).length, 1); // match → leg
        assertEq(adapter.getAdapterPositions(holder, address(weth)).length, 0); // mismatch → empty
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceOwed() public {
        BalancesHarness freshNav = new BalancesHarness();
        NexusMutualStakingPoolsBalanceAdapter a2 = new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(freshNav), address(this), address(this)
        );
        nft.setToken(1, 1, holder);
        viewer.setToken(1, 1, 100, 0, 5);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        a2.submitTokenIds(holder, ids);
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0); // NXM not registered → dropped
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 105); // balance still computed
    }

    function test_getAdapterBalances_shape() public {
        _seedOne(2, 1, 100, 0, 5);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(nxm));
        assertEq(amounts[0], 105);
        assertEq(isDebt[0], false);
    }

    // ---- Assisted-cache behaviour ----

    function test_submit_onlyAssistantRole() public {
        nft.setToken(1, 1, holder);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, ASSISTANT_ROLE)
        );
        adapter.submitTokenIds(holder, ids);
    }

    /// @notice Writes are fail-loud: submitting an id not owned by the account reverts NotTokenOwner.
    function test_submit_revertsOnNonOwnedId() public {
        nft.setToken(1, 1, other); // owned by `other`, not holder
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, holder, uint256(1)));
        adapter.submitTokenIds(holder, ids);
    }

    /// @notice Reads are fail-open: an id transferred away after submission is silently discarded.
    function test_read_discardsTransferredId() public {
        _seedOne(1, 1, 100, 0, 0);
        _seedOne(2, 1, 200, 0, 0);
        nft.setToken(1, 1, other); // token 1 moves to `other`
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1, "transferred token discarded; remaining token reported");
        assertEq(p[0].positionId, abi.encode(viewer.poolAddr(1)));
        assertEq(p[0].positionInstanceId, bytes32(uint256(2)));
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 200);
    }

    /// @notice Reads are fail-open: an id whose tokenInfo reverts is silently discarded.
    function test_read_discardsRevertingId() public {
        _seedOne(2, 1, 100, 0, 0);
        _seedOne(4, 1, 100, 0, 0);
        nft.setRevertId(2); // tokenInfo(2) reverts → skipped
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 100); // only token 4 counted
    }

    function test_clearTokenId() public {
        _seedOne(1, 1, 100, 0, 0);
        _seedOne(2, 1, 200, 0, 0);
        adapter.clearTokenId(holder, 1);
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 200);
    }

    function test_clearAccount() public {
        _seedOne(1, 1, 100, 0, 0);
        adapter.clearAccount(holder);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    // ---- Caps + never-revert ----

    function test_perAccountCap_revertsWhenFull() public {
        uint256 cap = adapter.MAX_TOKEN_IDS();
        // A single list of exactly MAX_TOKEN_IDS owned ids is accepted.
        uint256[] memory ids = new uint256[](cap);
        for (uint256 i = 0; i < cap; i++) {
            uint256 id = i + 1;
            nft.setToken(id, 1, holder); // holder owns ALL
            viewer.setToken(id, 1, 1, 0, 0); // 1 active each
            ids[i] = id;
        }
        adapter.submitTokenIds(holder, ids);
        assertEq(adapter.tokenIdsOf(holder).length, cap);

        // A single list of MAX_TOKEN_IDS + 1 is fail-loud (the cap+1-th add reverts). Submit is replace semantics, so
        // the cap is hit within one list, not by accumulating across calls.
        uint256[] memory tooMany = new uint256[](cap + 1);
        for (uint256 i = 0; i < cap + 1; i++) {
            uint256 id = i + 1;
            nft.setToken(id, 1, holder);
            viewer.setToken(id, 1, 1, 0, 0);
            tooMany[i] = id;
        }
        vm.expectRevert(abi.encodeWithSelector(TokenIdCacheFull.selector, holder, cap));
        adapter.submitTokenIds(holder, tooMany);

        // The reverted submit left the prior set intact (replace is atomic — the clear rolled back with the revert).
        assertEq(adapter.tokenIdsOf(holder).length, cap);
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
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0); // getTokens revert → empty
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IAssistedBalanceAdapter).interfaceId));
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
