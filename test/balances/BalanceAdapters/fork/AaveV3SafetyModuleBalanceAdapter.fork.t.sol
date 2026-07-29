// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    AaveV3SafetyModuleBalanceAdapter,
    IStakeToken
} from "src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

interface IStakeTokenExtended is IStakeToken {
    function claimRewards(address user, uint256 amount) external;
    function distributionEnd() external view returns (uint256);
}

/// @title AaveV3SafetyModuleBalanceAdapterForkTest
/// @notice Fork tests for the hardcoded multi-token AaveV3SafetyModuleBalanceAdapter against real Mainnet contracts.
/// @dev The adapter pins the SM stake token addresses as constants; these fork tests verify each is reachable on a
///      real fork and that the balance / position math matches the underlying contracts. Real holders for each
///      stake token were sourced from recent Transfer-event logs on Mainnet and verified to have non-zero current
///      balances at the pinned block.
contract AaveV3SafetyModuleBalanceAdapterForkTest is BalanceAdapterTestBase {
    // Hardcoded SM stake-token addresses (must match the constants in the adapter).
    IStakeTokenExtended public constant STK_AAVE = IStakeTokenExtended(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    IStakeTokenExtended public constant STK_ABPT = IStakeTokenExtended(0xa1116930326D21fB917d5A27F1E9943A9595fb47);
    IStakeTokenExtended public constant STK_ABPT_V2 = IStakeTokenExtended(0x9eDA81C21C273a82BE9Bbc19B6A6182212068101);
    IStakeTokenExtended public constant STK_GHO = IStakeTokenExtended(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);

    // Underlying tokens (also hardcoded in the adapter).
    address public constant AAVE = MAINNET_AAVE;
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant ABPT = 0x41A08648C3766F9F9d85598fF102a08f4ef84F84;
    address public constant ABPT_V2 = 0x3de27EFa2F1AA663Ae5D458857e731c129069F29;

    uint256 public constant FORK_BLOCK = 25_000_000; // recent Mainnet, all four stake tokens active

    AaveV3SafetyModuleBalanceAdapter public adapter;

    // Real Mainnet holders, one per stake token. STK_AAVE_HOLDER also holds stkABPTv2 — kept distinct for clarity.
    address public constant STK_AAVE_HOLDER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant STK_ABPT_HOLDER = 0xD9a776A672E4Df85bbbE97d390Ff9674B382d2ea;
    address public constant STK_ABPT_V2_HOLDER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant STK_GHO_HOLDER = 0xa94ec39c91DF334DCAb55aDaA8EdD9C1dAF67cA7;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupAdapter();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupAdapter() internal {
        address[] memory assets = new address[](4);
        assets[0] = AAVE;
        assets[1] = GHO;
        assets[2] = ABPT;
        assets[3] = ABPT_V2;
        balances = _deployBalancesForAdapter(assets);
        adapter = new AaveV3SafetyModuleBalanceAdapter(address(balances));
    }

    // ─── Sanity ───────────────────────────────────────────────────────────────

    function test_holdersHaveNonZeroBalances() public view {
        assertGt(STK_AAVE.balanceOf(STK_AAVE_HOLDER), 0, "stkAAVE holder dropped its position");
        assertGt(STK_ABPT.balanceOf(STK_ABPT_HOLDER), 0, "stkABPT holder dropped its position");
        assertGt(STK_ABPT_V2.balanceOf(STK_ABPT_V2_HOLDER), 0, "stkABPTv2 holder dropped its position");
        assertGt(STK_GHO.balanceOf(STK_GHO_HOLDER), 0, "stkGHO holder dropped its position");
    }

    function test_underlyingAssetsSupported_dedupesAAVEAcrossStakeTokens() public view {
        // All four stake tokens reward in AAVE; AAVE appears once in the deduplicated list.
        address[] memory list = adapter.underlyingAssetsSupported();
        assertEq(list.length, 4);
    }

    // ─── Per-stake-token: balance math matches the underlying contract ────────

    function test_stkGho_stakedTokenBalance_matchesPreviewRedeem() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(STK_GHO_HOLDER, GHO);
        uint256 expected = STK_GHO.previewRedeem(STK_GHO.balanceOf(STK_GHO_HOLDER));
        assertEq(amount, expected, "GHO leg should match previewRedeem(balanceOf)");
        assertGt(amount, 0);
        assertFalse(isDebt);
    }

    function test_stkAave_aaveLeg_matchesAdapterMath() public view {
        // The adapter's AAVE leg should be `stkAAVE.previewRedeem(balanceOf)` + sum of AAVE rewards across
        // all four stake tokens. Even when the holder has zero balance in some of them, a stake token can
        // still report nonzero `getTotalRewardsBalance` if the asset index is non-trivial — so we sum all
        // four rewards rather than just the ones with non-zero stake.
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(STK_AAVE_HOLDER, AAVE);

        uint256 stakedClaim = STK_AAVE.previewRedeem(STK_AAVE.balanceOf(STK_AAVE_HOLDER));
        uint256 totalRewards = STK_AAVE.getTotalRewardsBalance(STK_AAVE_HOLDER)
            + STK_ABPT.getTotalRewardsBalance(STK_AAVE_HOLDER) + STK_ABPT_V2.getTotalRewardsBalance(STK_AAVE_HOLDER)
            + STK_GHO.getTotalRewardsBalance(STK_AAVE_HOLDER);

        assertEq(amount, stakedClaim + totalRewards, "AAVE leg should be staked + summed rewards");
        assertGt(amount, 0);
    }

    function test_stkAbpt_stakedTokenBalance_matchesPreviewRedeem() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(STK_ABPT_HOLDER, ABPT);
        uint256 expected = STK_ABPT.previewRedeem(STK_ABPT.balanceOf(STK_ABPT_HOLDER));
        assertEq(amount, expected);
        assertGt(amount, 0);
    }

    function test_stkAbptV2_stakedTokenBalance_matchesPreviewRedeem() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(STK_ABPT_V2_HOLDER, ABPT_V2);
        uint256 expected = STK_ABPT_V2.previewRedeem(STK_ABPT_V2.balanceOf(STK_ABPT_V2_HOLDER));
        assertEq(amount, expected);
        assertGt(amount, 0);
    }

    // ─── Asset filtering and position attribution ─────────────────────────────

    function test_getAdapterPositions_attributesPerStakeToken() public view {
        // STK_GHO_HOLDER's stkGHO position must appear with a non-zero amount and the right metadata.
        // (The reward-leg position is conditional on `getTotalRewardsBalance > 0` — covered separately.)
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(STK_GHO_HOLDER, address(0));

        bool sawGhoStakedFromGho;
        for (uint256 i; i < positions.length; ++i) {
            address asset = positions[i].balanceAsset.asset;
            assertGt(positions[i].amount, 0);
            assertEq(positions[i].balanceAdapter, address(adapter));
            assertFalse(positions[i].isDebt);
            if (asset == GHO && positions[i].positionKind == PositionKind.Staking) {
                sawGhoStakedFromGho = true;
            }
        }
        assertTrue(sawGhoStakedFromGho, "missing GHO/stkGHO position");
    }

    function test_getAdapterPositions_assetFilter_onlyEmitsMatchingAsset() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(STK_GHO_HOLDER, GHO);
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, GHO);
    }

    // ─── Reward freeze behaviour (only when distributionEnd is in the future) ─

    /// @dev `getTotalRewardsBalance` stops growing once `distributionEnd` has passed, and this asserts that at
    ///      every pinned block rather than only at some of them.
    ///
    ///      It used to open with `if (distributionEnd <= block.timestamp) return;`, on the stated grounds that
    ///      the property "only makes sense when distributionEnd is still in the future". That guard has been
    ///      firing: at FORK_BLOCK stkGHO's `distributionEnd` is 1749123599 (2025-06-05) against a block
    ///      timestamp of 1777637363 (2026-04-29), so the single assertion below was never reached and the
    ///      reward-freeze behaviour of a mainnet-deployed adapter had no coverage at all. A pinned test that
    ///      degrades to a no-op as the chain ages is indistinguishable from a passing one, which is exactly how
    ///      that went unnoticed.
    ///
    ///      The premise was also wrong: the property holds on BOTH sides of `distributionEnd`, so no skip is
    ///      needed. Anchor the first read at `max(distributionEnd, block.timestamp)` — never warping backwards,
    ///      which on a fork can push `block.timestamp` behind a stored `lastUpdateTimestamp` and underflow
    ///      Aave's accrual arithmetic — and the second 100 days later. Both reads are then strictly at or after
    ///      the end of distribution, where the balance must be frozen.
    ///      **Scope, stated rather than implied.** At this pinned block the fixture's unclaimed AAVE reward
    ///      balance is 0 — measured on mainnet: the holder has 9,648e18 stkGHO but `getTotalRewardsBalance`
    ///      returns 0, because the distribution ended in June 2025 and the rewards were claimed. So this cannot
    ///      demonstrate accrual STOPPING; there is nothing left to stop. What it does check is the weaker but
    ///      still real property that the adapter does not INVENT reward accrual past distribution end, which is
    ///      what a regression in the accrual read would look like.
    ///
    ///      An earlier revision of this test asserted `atEnd > 0` to guard against exactly the vacuity of
    ///      `0 == 0`. That assertion was false against the chain and CI caught it. The honest guard is not a
    ///      claim about rewards the fixture does not have, but the two facts that make the zero MEANINGFUL: the
    ///      holder really does hold a stake (so the adapter is reading a live position, not an empty account),
    ///      and the distribution really has ended (so zero is the expected answer rather than a broken read).
    ///      If either stops holding, this test's premise has changed and it should be re-derived, not patched.
    function test_rewards_freezeAfterDistributionEnd() public {
        uint256 distributionEnd = STK_GHO.distributionEnd();

        // The two facts that make a zero reward balance meaningful rather than vacuous.
        assertGt(STK_GHO.balanceOf(STK_GHO_HOLDER), 0, "fixture must hold a live stkGHO stake");
        assertLe(distributionEnd, block.timestamp, "premise: distribution has already ended at this pin");

        // No ternary: the assertion above already pins `distributionEnd <= block.timestamp`, so the other
        // branch was provably dead. If that premise ever stops holding, the assertion fails loudly and this
        // test is re-derived rather than silently taking a different path. Dead branch removed in review.
        uint256 anchor = block.timestamp;

        vm.warp(anchor);
        (uint256 atEnd,) = adapter.getAdapterBalanceForAsset(STK_GHO_HOLDER, AAVE);
        vm.warp(anchor + 100 days);
        (uint256 afterEnd,) = adapter.getAdapterBalanceForAsset(STK_GHO_HOLDER, AAVE);

        assertEq(afterEnd, atEnd, "no further reward accrual past distribution end");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
