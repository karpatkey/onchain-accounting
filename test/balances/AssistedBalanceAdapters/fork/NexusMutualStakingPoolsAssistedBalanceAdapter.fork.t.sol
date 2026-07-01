// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {NexusMutualStakingPoolsAssistedBalanceAdapter, INexusStakingViewer} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title NexusMutualStakingPoolsAssistedBalanceAdapterForkTest
/// @notice Fork test against Nexus Mutual's real StakingNFT + StakingViewer on mainnet.
/// @dev The adapter is wrapper-fed: a `SUBMITTER_ROLE` holder feeds coordinates via incremental `submit(account, id)`,
///      valued live via `StakingViewer.getTokens` with ownership re-verified per read via `tokenInfo`. The Nexus
///      Mutual Safe (`0x8e53…cFE3`) holds 5 positions across
///      5 pools (tokenIds 180,184,185,186,187); the test submits them one by one and asserts the per-kind sums equal an
///      independent `getAggregatedTokens` read of those exact ids (delta 0) AND that every emitted positionId decodes
///      to a deployed staking-pool address (the NFT id riding in the typed positionInstanceId).
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

        // admin + wrapper = this test, so it can submit the Safe's known tokenIds (all owned by HOLDER → no revert).
        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this), address(this)
        );
        uint256[] memory ids = _knownIds();
        for (uint256 i; i < ids.length; ++i) {
            adapter.submit(HOLDER, ids[i]);
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
}
