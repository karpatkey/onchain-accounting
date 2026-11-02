// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter,
    INexusStakingViewer
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {CoordinateNotOwned, CoordinateNotCached, CoordinateStillLive} from "src/errors.sol";

/// @notice Minimal ERC-721 transfer surface for the real StakingNFT (to exercise read-time ownership discard).
interface IStakingNFTLike {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title NexusMutualStakingPoolsAssistedBalanceAdapterForkTest
/// @notice Fork test against Nexus Mutual's real StakingNFT + StakingViewer on mainnet.
/// @dev The adapter is permissionless wrapper-fed: `submit(id)` / `remove(id)` are `msg.sender`-keyed, valued live via
///      `StakingViewer.getTokens` with ownership re-verified per read via `tokenInfo`. The Nexus Mutual Safe
///      (`0x8e53…cFE3`) holds 5 positions across 5 pools (tokenIds 180,184,185,186,187); the test submits them one by
///      one (pranking the Safe) and asserts the per-kind sums equal an independent `getAggregatedTokens` read of those
///      exact ids (delta 0) AND that every emitted positionId decodes to a deployed staking-pool address (the NFT id
///      riding in the typed positionInstanceId).
contract NexusMutualStakingPoolsAssistedBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address public constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address public constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;

    address public constant HOLDER = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3; // Nexus Mutual Safe

    uint256 public constant FORK_BLOCK = 25_388_000;

    // getAggregatedTokens([180,184,185,186,187]) at FORK_BLOCK (NXM, 18dp).
    uint256 public constant EXPECTED_STAKING = 74_229_519_750_529_478_080_348; // ~74,229.5 NXM active (+0 expired)
    uint256 public constant EXPECTED_REWARDS = 228_254_616_240_628_948_835; // ~228.25 NXM rewards

    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NXM, 18, "NXM");

        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this)
        );
        // Permissionless: the account itself submits its ids (all owned by HOLDER → no revert).
        uint256[] memory ids = _knownIds();
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(HOLDER);
            adapter.submit(ids[i]);
        }
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Independent live read of the Safe's known tokenIds — the ground truth the adapter's scan must reproduce.
    function _liveTotals() internal view returns (uint256 staking, uint256 rewards) {
        INexusStakingViewer.AggregatedTokens memory agg =
            INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(_knownIds());
        return (agg.totalActiveStake + agg.totalExpiredStake, agg.totalRewards);
    }

    function _knownIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](5);
        ids[0] = 180;
        ids[1] = 184;
        ids[2] = 185;
        ids[3] = 186;
        ids[4] = 187;
    }

    function test_realHolder_scanMatchesAggregate() public {
        (uint256 staking, uint256 rewards) = _liveTotals();
        assertEq(staking, EXPECTED_STAKING, "pinned staking drift");
        assertEq(rewards, EXPECTED_REWARDS, "pinned rewards drift");

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(HOLDER, NXM);
        assertEq(amount, staking + rewards, "adapter total must equal live getAggregatedTokens (delta 0)");
        assertFalse(isDebt);
    }

    function test_realHolder_perNftLegs() public {
        (uint256 staking, uint256 rewards) = _liveTotals();
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));

        assertGe(p.length, 5, "expected at least one Staking leg per position");
        assertLe(p.length, 10, "at most two legs per position");

        uint256 stakingSum;
        uint256 rewardsSum;
        for (uint256 i; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, NXM);
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolSubId, ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS);
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_MUTUAL);
            assertFalse(p[i].isDebt);
            address pool = abi.decode(p[i].positionId, (address));
            assertGt(pool.code.length, 0, "positionId resolves to a deployed staking pool");
            string[] memory lbl = adapter.positionLabels(p[i].positionId);
            assertEq(lbl.length, 2, "static breadcrumb = [Staking, pool]");
            assertEq(lbl[0], "Staking Pools");
            assertTrue(p[i].positionInstanceId != bytes32(0), "NFT id rides in positionInstanceId");
            if (p[i].positionKind == PositionKind.Staking) {
                stakingSum += p[i].amount;
            } else {
                assertEq(uint8(p[i].positionKind), uint8(PositionKind.Rewards));
                rewardsSum += p[i].amount;
            }
        }
        assertEq(stakingSum, staking, "per-NFT staking legs must sum to live total");
        assertEq(rewardsSum, rewards, "per-NFT rewards legs must sum to live total");
    }

    function test_nonStaker_reportsZero() public {
        address stranger = makeAddr("stranger");
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(stranger, NXM);
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(stranger, address(0)).length, 0);
    }

    /// @notice submit reverts CoordinateNotOwned for a real id not owned by the caller (id 180 belongs to the Safe,
    ///         not `stranger`).
    function test_submit_revertsForNonOwnedId() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, stranger, uint256(180)));
        adapter.submit(180);
    }

    /// @notice remove is fail-loud for an id the caller never cached (CoordinateNotCached), keyed on msg.sender.
    function test_remove_revertsForUncachedId() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, stranger, uint256(180)));
        adapter.remove(180);
    }

    /// @notice remove is fail-loud for a still-live owned id (CoordinateStillLive): a live position is never dropped
    ///         from the cache — it can only leave once fully emptied or no longer owned (see {_removable}).
    function test_remove_revertsForLiveOwnedId() public {
        assertGt(_valueOf(180), 0, "id 180 is live at the pinned block");
        uint256 lenBefore = adapter.tokenIdsOf(HOLDER).length;

        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, HOLDER, uint256(180)));
        adapter.remove(180);

        assertEq(adapter.tokenIdsOf(HOLDER).length, lenBefore, "still tracked");
    }

    /// @notice Reads fail open: after the Safe transfers a cached StakingNFT away, that id is discarded on reads even
    ///         though it stays in the cache (ownership re-verified live via `tokenInfo`).
    function test_read_discardsTransferredId() public {
        address stranger = makeAddr("stranger");
        (uint256 amtBefore,) = adapter.getAdapterBalanceForAsset(HOLDER, NXM);
        uint256 one = _valueOf(180);

        vm.prank(HOLDER);
        IStakingNFTLike(STAKING_NFT).transferFrom(HOLDER, stranger, 180);

        // Still cached (the wrapper hasn't GC'd it) but discarded on read since it's no longer owned.
        assertEq(adapter.tokenIdsOf(HOLDER).length, 5, "cache unchanged");
        (uint256 amtAfter,) = adapter.getAdapterBalanceForAsset(HOLDER, NXM);
        assertEq(amtAfter, amtBefore - one, "transferred id discarded from the read");
    }

    /// @dev Live NXM value (active + expired stake + rewards) of a single tokenId via the viewer.
    function _valueOf(uint256 tokenId) internal view returns (uint256) {
        uint256[] memory one = new uint256[](1);
        one[0] = tokenId;
        INexusStakingViewer.AggregatedTokens memory agg = INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(one);
        return agg.totalActiveStake + agg.totalExpiredStake + agg.totalRewards;
    }

    // ---- Happy paths for additional real StakingNFT holders on mainnet (block 25,388,000) ----

    function test_realHolder_0x546a() public {
        _assertHappyPath(0x546a0cB802377153B4fEAe052a5ed14C98B3CC9C, _ids8(25, 41, 75, 94, 137, 143, 144, 218));
    }

    function test_realHolder_0x8C87() public {
        _assertHappyPath(0x8C878B8f805472C0b70eD66a71c0B33da3d233c8, _ids5(65, 66, 140, 189, 190));
    }

    function test_realHolder_0x49Fe() public {
        _assertHappyPath(0x49Fe6d0096Ec9a51A59231c2D46F09a339d16296, _ids5(90, 91, 92, 182, 183));
    }

    /// @dev Submit `ids` AS `account` (permissionless, msg.sender-keyed), then assert the adapter's balance AND its
    ///      per-NFT position legs both equal the independent live `getAggregatedTokens(ids)` total (delta 0).
    function _assertHappyPath(address account, uint256[] memory ids) internal {
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(account);
            adapter.submit(ids[i]);
        }
        INexusStakingViewer.AggregatedTokens memory agg = INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(ids);
        uint256 expected = agg.totalActiveStake + agg.totalExpiredStake + agg.totalRewards;
        assertGt(expected, 0, "fixture holds non-zero NXM");

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(account, NXM);
        assertEq(amount, expected, "adapter total == live getAggregatedTokens (delta 0)");
        assertFalse(isDebt);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(account, address(0));
        uint256 sum;
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].balanceAsset.asset, NXM);
            assertEq(p[i].protocolSubId, ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS);
            assertFalse(p[i].isDebt);
            assertGt(abi.decode(p[i].positionId, (address)).code.length, 0, "positionId is a deployed pool");
            sum += p[i].amount;
        }
        assertEq(sum, expected, "position legs sum to the live aggregate");
    }

    function _ids5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](5);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
        ids[3] = d;
        ids[4] = e;
    }

    function _ids8(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 g, uint256 h)
        internal
        pure
        returns (uint256[] memory ids)
    {
        ids = new uint256[](8);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
        ids[3] = d;
        ids[4] = e;
        ids[5] = f;
        ids[6] = g;
        ids[7] = h;
    }
}
