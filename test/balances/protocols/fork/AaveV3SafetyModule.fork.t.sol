// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {AaveV3SafetyModuleBalanceOracle, IStakeToken} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface IStakeTokenExtended is IStakeToken {
    function claimRewards(address user, uint256 amount) external;
    function distributionEnd() external view returns (uint256);
}

/// @title AaveV3SafetyModuleBalanceOracleForkTest
/// @notice Fork tests for AaveV3SafetyModuleBalanceOracle using real mainnet contracts
/// @dev Tests adapter behavior with real Aave Safety Module contracts and positions
contract AaveV3SafetyModuleBalanceOracleForkTest is BalanceAdapterTestBase {
    // Aave Safety Module contract addresses (mainnet)
    IStakeTokenExtended public constant STK_GHO = IStakeTokenExtended(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    IStakeTokenExtended public constant STK_AAVE = IStakeTokenExtended(0x4da27a545c0c5B758a6BA100e3a049001de870f5);

    // Token addresses
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant AAVE = MAINNET_AAVE;

    // Fork block
    uint256 public constant FORK_BLOCK = 21_395_285;

    // Oracle instances
    AaveV3SafetyModuleBalanceOracle public ghoOracle;
    AaveV3SafetyModuleBalanceOracle public aaveOracle;

    // Real user addresses with positions in Aave Safety Module
    address public constant TEST_USER = 0xa94ec39c91DF334DCAb55aDaA8EdD9C1dAF67cA7;
    address public constant AAVE_USER = 0xa923B13270F8622B5d5960634200Dc4302b7611E;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracles();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracles() internal {
        address[] memory assets = new address[](2);
        assets[0] = GHO;
        assets[1] = AAVE;
        balances = _deployBalancesForOracle(assets);

        ghoOracle = new AaveV3SafetyModuleBalanceOracle(address(STK_GHO), "Aave v3", "Safety Module", address(balances));
        aaveOracle =
            new AaveV3SafetyModuleBalanceOracle(address(STK_AAVE), "Aave v3", "Safety Module", address(balances));
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_constructor_gho() public view {
        assertEq(address(ghoOracle.STAKED_TOKEN()), GHO);
        assertEq(ghoOracle.REWARD_TOKEN(), AAVE);
    }

    function test_constructor_aave() public view {
        assertEq(address(aaveOracle.STAKED_TOKEN()), AAVE);
        assertEq(aaveOracle.REWARD_TOKEN(), AAVE);
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getOracleBalanceForAsset_stk_gho_stakedTokenBalance() public {
        (uint256 amount, bool isDebt) = ghoOracle.getOracleBalanceForAsset(TEST_USER, GHO);

        vm.startPrank(TEST_USER);
        uint256 stkGhoBalance = STK_GHO.balanceOf(TEST_USER);
        uint256 previewRedeem = STK_GHO.previewRedeem(stkGhoBalance);
        vm.stopPrank();

        assertEq(amount, previewRedeem, "Oracle balance should match preview redeem");
        assertGt(amount, 0, "User should have positive staked GHO position");
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_stk_gho_rewardTokenBalance() public {
        (uint256 amount, bool isDebt) = ghoOracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        // Get actual claimable rewards
        vm.startPrank(TEST_USER);
        uint256 aaveBalanceBefore = IERC20(AAVE).balanceOf(TEST_USER);
        STK_GHO.claimRewards(TEST_USER, type(uint256).max);
        uint256 aaveBalanceAfter = IERC20(AAVE).balanceOf(TEST_USER);
        vm.stopPrank();

        uint256 claimedRewards = aaveBalanceAfter - aaveBalanceBefore;

        assertEq(amount, claimedRewards, "Oracle rewards should match actual claimed rewards");
        assertGt(amount, 0, "User should have positive AAVE rewards");
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_stk_aave_stakedAndRewardBalance() public {
        (uint256 amount, bool isDebt) = aaveOracle.getOracleBalanceForAsset(AAVE_USER, AAVE);

        uint256 stkAaveBalance = STK_AAVE.balanceOf(AAVE_USER);

        vm.startPrank(AAVE_USER);
        uint256 previewRedeem = STK_AAVE.previewRedeem(stkAaveBalance);

        uint256 aaveBalanceBefore = IERC20(AAVE).balanceOf(AAVE_USER);
        STK_AAVE.claimRewards(AAVE_USER, type(uint256).max);
        uint256 aaveBalanceAfter = IERC20(AAVE).balanceOf(AAVE_USER);
        vm.stopPrank();

        uint256 claimedRewards = aaveBalanceAfter - aaveBalanceBefore;

        assertEq(amount, previewRedeem + claimedRewards, "Oracle balance should match staked + rewards");
        assertGt(amount, 0, "User should have positive AAVE position");
        assertFalse(isDebt);
    }

    // ============================================
    // Supported Assets Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assetsGho = ghoOracle.underlyingAssetsSupported();
        assertEq(assetsGho.length, 2);
        assertEq(assetsGho[0], GHO);
        assertEq(assetsGho[1], AAVE);

        address[] memory assetsAave = aaveOracle.underlyingAssetsSupported();
        assertEq(assetsAave.length, 1);
        assertEq(assetsAave[0], AAVE);
    }

    // ============================================
    // Rewards Calculation Tests
    // ============================================

    function test_getOracleBalanceForAsset_rewardsWithZeroTotalSupply() public view {
        (uint256 amount,) = ghoOracle.getOracleBalanceForAsset(address(0xdead), AAVE);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_rewardsCalculation() public {
        (uint256 initialAmount,) = ghoOracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        vm.warp(block.timestamp + 365 days);

        (uint256 newAmount,) = ghoOracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        vm.startPrank(TEST_USER);
        uint256 aaveBalanceBefore = IERC20(AAVE).balanceOf(TEST_USER);
        STK_GHO.claimRewards(TEST_USER, type(uint256).max);
        uint256 aaveBalanceAfter = IERC20(AAVE).balanceOf(TEST_USER);
        vm.stopPrank();

        uint256 actualRewards = aaveBalanceAfter - aaveBalanceBefore;

        assertEq(newAmount, actualRewards, "Oracle rewards should match actual claimed rewards");
        assertGt(newAmount, initialAmount, "New rewards should be bigger than initial rewards");
    }

    function test_getOracleBalanceForAsset_rewardsAfterDistributionEnd() public {
        (uint256 initialAmount,) = ghoOracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        uint256 distributionEnd = STK_GHO.distributionEnd();

        // Move to before exact distribution end and get rewards
        vm.warp(distributionEnd - 1);
        (uint256 rewardsBeforeEnd,) = ghoOracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        // Move to exact distribution end and get rewards
        vm.warp(distributionEnd);
        (uint256 rewardsAtEnd,) = ghoOracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        // Move past distribution end
        vm.warp(distributionEnd + 100 days);
        (uint256 rewardsAfterEnd,) = ghoOracle.getOracleBalanceForAsset(TEST_USER, AAVE);

        assertGt(rewardsBeforeEnd, initialAmount, "Rewards should accrue until distribution end");
        assertGt(rewardsAtEnd, initialAmount, "Rewards should accrue until distribution end");
        assertLe(rewardsBeforeEnd, rewardsAtEnd, "Rewards should accrue until distribution end");
        assertEq(rewardsAfterEnd, rewardsAtEnd, "Rewards should not increase after distribution end");
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalance_aggregatesPositions() public view {
        (address[] memory assets, uint256[] memory amounts,) = ghoOracle.getOracleBalances(TEST_USER);

        // Should have at least GHO and AAVE positions
        assertGe(assets.length, 2, "Should have multiple positions");
        assertEq(assets.length, amounts.length, "Arrays should match length");
    }

    function test_getOraclePositions_returnsCorrectPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = ghoOracle.getOraclePositions(TEST_USER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
