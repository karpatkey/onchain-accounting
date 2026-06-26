// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    NexusMutualStakingPoolsBalanceAdapter,
    INexusStakingViewer
} from "src/balances/protocols/NexusMutualStakingPoolsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title NexusMutualStakingPoolsBalanceAdapterForkTest
/// @notice Fork test against Nexus Mutual's real StakingNFT + StakingViewer on mainnet.
/// @dev The adapter self-discovers an account's StakingNFT positions by scanning
///      `tokenInfo(1..totalSupply)` for a matching owner — there is no per-owner enumeration on the
///      NFT. The Nexus Mutual Safe (`0x8e53…cFE3`, a KPK-managed account) holds 5 positions across 5
///      pools (tokenIds 180,184,185,186,187). The adapter now emits one Staking + one Rewards leg
///      PER tokenId (positionId = abi.encode(tokenId, poolId)); the test asserts the per-kind sums
///      equal an independent `getAggregatedTokens` read of those exact ids (delta 0) AND that every
///      emitted positionId decodes to one of the Safe's known tokenIds.
contract NexusMutualStakingPoolsBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address public constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address public constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;

    address public constant HOLDER = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3; // Nexus Mutual Safe

    uint256 public constant FORK_BLOCK = 25_388_000;

    // getAggregatedTokens([180,184,185,186,187]) at FORK_BLOCK (NXM, 18dp).
    uint256 public constant EXPECTED_STAKING = 74_229_519_750_529_478_080_348; // ~74,229.5 NXM active (+0 expired)
    uint256 public constant EXPECTED_REWARDS = 228_254_616_240_628_948_835; // ~228.25 NXM rewards

    NexusMutualStakingPoolsBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NXM, 18, "NXM");

        adapter = new NexusMutualStakingPoolsBalanceAdapter(STAKING_NFT, STAKING_VIEWER, NXM, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Independent live read of the Safe's known tokenIds — the ground truth the adapter's scan
    ///      must reproduce.
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

    function _isKnownId(uint256 tokenId) internal pure returns (bool) {
        uint256[] memory ids = _knownIds();
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == tokenId) return true;
        }
        return false;
    }

    function test_realHolder_scanMatchesAggregate() public {
        (uint256 staking, uint256 rewards) = _liveTotals();
        // Sanity: the pinned values are the live state at FORK_BLOCK.
        assertEq(staking, EXPECTED_STAKING, "pinned staking drift");
        assertEq(rewards, EXPECTED_REWARDS, "pinned rewards drift");

        // The adapter scans the NFT, discovers the Safe's 5 positions, and totals them — must equal
        // the independent aggregate of those exact ids (delta 0).
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(HOLDER, NXM);
        assertEq(amount, staking + rewards, "adapter total must equal live getAggregatedTokens (delta 0)");
        assertFalse(isDebt);
    }

    function test_realHolder_perNftLegs() public {
        (uint256 staking, uint256 rewards) = _liveTotals();
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));

        // 5 positions → up to 10 legs (Staking+Rewards each, zero legs dropped); at least the 5 Staking legs.
        assertGe(p.length, 5, "expected at least one Staking leg per position");
        assertLe(p.length, 10, "at most two legs per position");

        uint256 stakingSum;
        uint256 rewardsSum;
        for (uint256 i; i < p.length; i++) {
            assertEq(p[i].balanceAsset.asset, NXM);
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_MUTUAL_STAKING);
            assertFalse(p[i].isDebt);
            // positionId decodes to one of the Safe's known (tokenId, poolId) positions.
            (uint256 tokenId, uint256 poolId) = abi.decode(p[i].positionId, (uint256, uint256));
            assertTrue(_isKnownId(tokenId), "positionId tokenId not in known set");
            assertGt(poolId, 0, "poolId should be set");
            if (p[i].positionKind == PositionKind.Staking) {
                stakingSum += p[i].amount;
            } else {
                assertEq(uint8(p[i].positionKind), uint8(PositionKind.Rewards));
                rewardsSum += p[i].amount;
            }
        }
        // Per-NFT legs must sum back to the independent aggregate (delta 0).
        assertEq(stakingSum, staking, "per-NFT staking legs must sum to live total");
        assertEq(rewardsSum, rewards, "per-NFT rewards legs must sum to live total");
    }

    function test_nonStaker_reportsZero() public {
        address stranger = makeAddr("stranger");
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(stranger, NXM);
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(stranger, address(0)).length, 0);
    }
}
