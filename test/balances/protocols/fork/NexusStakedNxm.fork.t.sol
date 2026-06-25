// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {NexusStakedNxmBalanceAdapter, INexusStakingViewer} from "src/balances/protocols/NexusStakedNxm.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title NexusStakedNxmBalanceAdapterForkTest
/// @notice Fork test against Nexus Mutual's real StakingNFT + StakingViewer on mainnet.
/// @dev The adapter self-discovers an account's StakingNFT positions by scanning
///      `tokenInfo(1..totalSupply)` for a matching owner — there is no per-owner enumeration on the
///      NFT. The Nexus Mutual Safe (`0x8e53…cFE3`, a KPK-managed account) holds 5 positions across 5
///      pools (tokenIds 180,184,185,186,187). The test asserts the adapter's scan-derived total equals
///      an independent `getAggregatedTokens` read of those exact ids (delta 0) AND the pinned values.
contract NexusStakedNxmBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address public constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address public constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;

    address public constant HOLDER = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3; // Nexus Mutual Safe

    uint256 public constant FORK_BLOCK = 25_388_000;

    // getAggregatedTokens([180,184,185,186,187]) at FORK_BLOCK (NXM, 18dp).
    uint256 public constant EXPECTED_STAKING = 74_229_519_750_529_478_080_348; // ~74,229.5 NXM active (+0 expired)
    uint256 public constant EXPECTED_REWARDS = 228_254_616_240_628_948_835; // ~228.25 NXM rewards

    NexusStakedNxmBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NXM, 18, "NXM");

        adapter = new NexusStakedNxmBalanceAdapter(STAKING_NFT, STAKING_VIEWER, NXM, address(balances));
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Independent live read of the Safe's known tokenIds — the ground truth the adapter's scan
    ///      must reproduce.
    function _liveTotals() internal view returns (uint256 staking, uint256 rewards) {
        uint256[] memory ids = new uint256[](5);
        ids[0] = 180;
        ids[1] = 184;
        ids[2] = 185;
        ids[3] = 186;
        ids[4] = 187;
        INexusStakingViewer.AggregatedTokens memory agg = INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(ids);
        return (agg.totalActiveStake + agg.totalExpiredStake, agg.totalRewards);
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

    function test_realHolder_positionLegs() public {
        (uint256 staking, uint256 rewards) = _liveTotals();
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        assertEq(p.length, 2);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, staking);
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[1].amount, rewards);
        for (uint256 i; i < 2; i++) {
            assertEq(p[i].balanceAsset.asset, NXM);
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_STAKING);
            assertEq(p[i].positionId.length, 0);
            assertFalse(p[i].isDebt);
        }
    }

    function test_nonStaker_reportsZero() public {
        address stranger = makeAddr("stranger");
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(stranger, NXM);
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(stranger, address(0)).length, 0);
    }
}
