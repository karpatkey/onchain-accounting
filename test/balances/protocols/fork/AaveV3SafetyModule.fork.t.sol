// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AaveV3SafetyModuleBalanceOracle, IStakeToken} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IStakeTokenExtended is IStakeToken {
    function claimRewards(address user, uint256 amount) external;
    function distributionEnd() external view returns (uint256);
}

/// @title AaveV3SafetyModuleBalanceOracleForkTest
/// @notice Fork tests for the multi-token AaveV3SafetyModuleBalanceOracle against real Mainnet contracts.
contract AaveV3SafetyModuleBalanceOracleForkTest is BalanceAdapterTestBase {
    IStakeTokenExtended public constant STK_GHO = IStakeTokenExtended(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    IStakeTokenExtended public constant STK_AAVE = IStakeTokenExtended(0x4da27a545c0c5B758a6BA100e3a049001de870f5);

    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant AAVE = MAINNET_AAVE;

    uint256 public constant FORK_BLOCK = 21_395_285;

    AaveV3SafetyModuleBalanceOracle public oracle;
    address public adminAddr = makeAddr("smAdmin");

    address public constant TEST_USER = 0xa94ec39c91DF334DCAb55aDaA8EdD9C1dAF67cA7; // stkGHO holder
    address public constant AAVE_USER = 0xa923B13270F8622B5d5960634200Dc4302b7611E; // stkAAVE holder

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        address[] memory assets = new address[](2);
        assets[0] = GHO;
        assets[1] = AAVE;
        balances = _deployBalancesForOracle(assets);

        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory init =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](2);
        init[0] =
            AaveV3SafetyModuleBalanceOracle.StakeTokenInit({stakeToken: address(STK_GHO), positionDetail: "stkGHO"});
        init[1] =
            AaveV3SafetyModuleBalanceOracle.StakeTokenInit({stakeToken: address(STK_AAVE), positionDetail: "stkAAVE"});

        oracle = new AaveV3SafetyModuleBalanceOracle(init, adminAddr, address(balances), "Aave V3 Safety Module");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    function test_constructor_seedsBothStakeTokens() public view {
        assertEq(oracle.stakeTokenCount(), 2);
        assertTrue(oracle.isStakeTokenRegistered(address(STK_GHO)));
        assertTrue(oracle.isStakeTokenRegistered(address(STK_AAVE)));

        (address ghoStaked, address ghoReward,) = oracle.stakeTokenInfo(address(STK_GHO));
        (address aaveStaked, address aaveReward,) = oracle.stakeTokenInfo(address(STK_AAVE));

        assertEq(ghoStaked, GHO);
        assertEq(ghoReward, AAVE);
        assertEq(aaveStaked, AAVE);
        assertEq(aaveReward, AAVE);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // underlyingAssetsSupported (deduplicates AAVE across stkGHO + stkAAVE)
    // ─────────────────────────────────────────────────────────────────────────

    function test_underlyingAssetsSupported_dedupesAAVE() public view {
        address[] memory list = oracle.underlyingAssetsSupported();
        assertEq(list.length, 2);

        bool sawGho;
        bool sawAave;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == GHO) sawGho = true;
            if (list[i] == AAVE) sawAave = true;
        }
        assertTrue(sawGho);
        assertTrue(sawAave);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Single-stake-token parity: balances should equal `previewRedeem(balanceOf)` for staked,
    // and `getTotalRewardsBalance` for rewards (the same math the legacy single-token adapter used).
    // ─────────────────────────────────────────────────────────────────────────

    function test_stkGho_stakedTokenBalance_matchesPreviewRedeem() public {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_USER, GHO);

        uint256 stkBalance = STK_GHO.balanceOf(TEST_USER);
        uint256 expected = STK_GHO.previewRedeem(stkBalance);

        assertEq(amount, expected, "GHO leg should match previewRedeem(balanceOf)");
        assertGt(amount, 0, "test user should have a positive stkGHO position");
        assertFalse(isDebt);
    }

    function test_stkGho_rewardTokenBalance_matchesClaim() public {
        // Read the oracle BEFORE any state changes, then verify against actual claim.
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        uint256 stkAaveStaked = STK_AAVE.previewRedeem(STK_AAVE.balanceOf(TEST_USER));
        // For TEST_USER (stkGHO holder, not stkAAVE), the AAVE leg should be just the stkGHO rewards.
        // Confirm by claiming.
        vm.startPrank(TEST_USER);
        uint256 before_ = IERC20(AAVE).balanceOf(TEST_USER);
        STK_GHO.claimRewards(TEST_USER, type(uint256).max);
        uint256 after_ = IERC20(AAVE).balanceOf(TEST_USER);
        vm.stopPrank();

        uint256 stkGhoRewards = after_ - before_;
        // Oracle reports the SUM across stake tokens:
        //   stkGHO rewards + (stkAAVE staked + stkAAVE rewards)
        // stkAAVE staked for TEST_USER is 0 (they're not a stkAAVE holder), so it should equal stkGHO rewards.
        // But still assert >= stkGhoRewards in case the oracle adds anything from stkAAVE.
        assertGe(amount, stkGhoRewards, "AAVE leg should include at least stkGHO rewards");
        assertEq(
            amount, stkAaveStaked + stkGhoRewards, "AAVE leg = stkGHO rewards + stkAAVE staked+rewards (latter 0 here)"
        );
        assertFalse(isDebt);
    }

    function test_stkAave_stakedAndRewardBalance_summed() public {
        // AAVE_USER holds stkAAVE; oracle's AAVE leg should be stkAAVE staked + stkAAVE rewards
        // (and any stkGHO rewards if AAVE_USER has stkGHO too, which they don't here).
        (uint256 amount,) = oracle.getOracleBalanceForAsset(AAVE_USER, AAVE);

        uint256 stkAaveBalance = STK_AAVE.balanceOf(AAVE_USER);
        uint256 expectedStaked = STK_AAVE.previewRedeem(stkAaveBalance);

        vm.startPrank(AAVE_USER);
        uint256 before_ = IERC20(AAVE).balanceOf(AAVE_USER);
        STK_AAVE.claimRewards(AAVE_USER, type(uint256).max);
        uint256 after_ = IERC20(AAVE).balanceOf(AAVE_USER);
        vm.stopPrank();
        uint256 expectedRewards = after_ - before_;

        assertEq(amount, expectedStaked + expectedRewards, "AAVE leg should sum stkAAVE staked + rewards");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reward accrual still works
    // ─────────────────────────────────────────────────────────────────────────

    function test_rewards_accrueOverTime() public {
        (uint256 initial,) = oracle.getOracleBalanceForAsset(TEST_USER, AAVE);
        vm.warp(block.timestamp + 365 days);
        (uint256 later_,) = oracle.getOracleBalanceForAsset(TEST_USER, AAVE);
        assertGt(later_, initial, "AAVE balance should grow as stkGHO rewards accrue");
    }

    function test_rewards_freezeAfterDistributionEnd() public {
        uint256 distributionEnd = STK_GHO.distributionEnd();
        vm.warp(distributionEnd);
        (uint256 atEnd,) = oracle.getOracleBalanceForAsset(TEST_USER, AAVE);
        vm.warp(distributionEnd + 100 days);
        (uint256 afterEnd,) = oracle.getOracleBalanceForAsset(TEST_USER, AAVE);
        // Rewards should stop accruing past distribution end (but stkAAVE rewards may also be subject to its own distribution end —
        // for TEST_USER with no stkAAVE position, both should freeze).
        assertEq(afterEnd, atEnd, "no further reward accrual past distribution end");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Position attribution: getOraclePositions emits per-stake-token entries
    // ─────────────────────────────────────────────────────────────────────────

    function test_getOraclePositions_attributesPerStakeToken() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));
        // TEST_USER has stkGHO only → expect:
        //   GHO position with positionDetail = "stkGHO" (staked leg)
        //   AAVE position with positionDetail = "stkGHO" (reward leg)
        // No stkAAVE entries because TEST_USER's stkAAVE balance is zero.
        assertEq(positions.length, 2);

        bool sawGhoStakedFromGho;
        bool sawAaveRewardFromGho;
        for (uint256 i; i < positions.length; ++i) {
            string memory detail = positions[i].positionDetail;
            address asset = positions[i].underlyingAsset.asset;
            if (asset == GHO && _eq(detail, "stkGHO")) sawGhoStakedFromGho = true;
            if (asset == AAVE && _eq(detail, "stkGHO")) sawAaveRewardFromGho = true;
            assertTrue(positions[i].amount > 0);
            assertEq(positions[i].balanceOracle, address(oracle));
            assertEq(positions[i].protocol, "Aave V3 Safety Module");
            assertFalse(positions[i].isDebt);
        }
        assertTrue(sawGhoStakedFromGho, "missing GHO/stkGHO position");
        assertTrue(sawAaveRewardFromGho, "missing AAVE/stkGHO position");
    }

    function test_getOraclePositions_assetFilter() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, GHO);
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, GHO);
        assertEq(positions[0].positionDetail, "stkGHO");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin: removeStakeToken removes contributions from balance reads
    // ─────────────────────────────────────────────────────────────────────────

    function test_removeStakeToken_dropsContributions() public {
        (uint256 ghoBefore,) = oracle.getOracleBalanceForAsset(TEST_USER, GHO);
        assertGt(ghoBefore, 0);

        vm.prank(adminAddr);
        oracle.removeStakeToken(address(STK_GHO));

        (uint256 ghoAfter,) = oracle.getOracleBalanceForAsset(TEST_USER, GHO);
        assertEq(ghoAfter, 0, "GHO balance should be 0 after stkGHO is removed");
    }

    function test_addStakeToken_thenContributionsAppear() public {
        // Start fresh with empty list, then add stkGHO mid-test.
        AaveV3SafetyModuleBalanceOracle.StakeTokenInit[] memory empty =
            new AaveV3SafetyModuleBalanceOracle.StakeTokenInit[](0);
        AaveV3SafetyModuleBalanceOracle freshOracle =
            new AaveV3SafetyModuleBalanceOracle(empty, adminAddr, address(balances), "Aave V3 Safety Module");

        (uint256 before_,) = freshOracle.getOracleBalanceForAsset(TEST_USER, GHO);
        assertEq(before_, 0);

        vm.prank(adminAddr);
        freshOracle.addStakeToken(address(STK_GHO), "stkGHO");

        (uint256 after_,) = freshOracle.getOracleBalanceForAsset(TEST_USER, GHO);
        assertGt(after_, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
