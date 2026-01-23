// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {TestSetupHelpers, BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {AaveV3SafetyModuleBalanceOracle, IStakeToken} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import "src/errors.sol";

interface IStakeTokenExtended is IStakeToken {
    function claimRewards(address user, uint256 amount) external;
    function distributionEnd() external view returns (uint256);
}

contract AaveV3SafetyModule is TestEnvConfigurator, TestSetupHelpers {
    IStakeTokenExtended public constant STK_GHO = IStakeTokenExtended(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    IStakeTokenExtended public constant STK_AAVE = IStakeTokenExtended(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    uint256 public constant FORK_BLOCK = 21_395_285;

    uint256 public fork;
    AaveV3SafetyModuleBalanceOracle public ghoOracle;
    AaveV3SafetyModuleBalanceOracle public aaveOracle;
    MockBalances mockBalances;
    BalancesHarnessForFork public balances;

    // Global user addresses with positions in Aave Safety Module
    address public testUser;
    address public aaveUser;

    function setUp() public {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        mockBalances = new MockBalances();

        address[] memory assets = new address[](2);
        assets[0] = GHO;
        assets[1] = AAVE;
        balances = deployBalancesInFork(assets);

        ghoOracle = new AaveV3SafetyModuleBalanceOracle(address(STK_GHO), "Aave v3", "Safety Module", address(balances));
        aaveOracle =
            new AaveV3SafetyModuleBalanceOracle(address(STK_AAVE), "Aave v3", "Safety Module", address(balances));

        // Set global user addresses - use addresses that have positions
        testUser = 0xa94ec39c91DF334DCAb55aDaA8EdD9C1dAF67cA7;
        aaveUser = 0xa923B13270F8622B5d5960634200Dc4302b7611E;
    }

    function test_constructor_gho() public view {
        assertEq(address(ghoOracle.STAKED_TOKEN()), GHO);
        assertEq(ghoOracle.REWARD_TOKEN(), AAVE);
    }

    function test_constructor_aave() public view {
        assertEq(address(aaveOracle.STAKED_TOKEN()), AAVE);
        assertEq(aaveOracle.REWARD_TOKEN(), AAVE);
    }

    function test_constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveV3SafetyModuleBalanceOracle(address(0), "Aave v3", "Safety Module", address(mockBalances));
    }

    function test_stk_gho_stakedTokenBalance() public {
        int256 balance = ghoOracle.getOracleBalanceForAsset(testUser, GHO);

        vm.startPrank(testUser);
        uint256 stkGhoBalance = STK_GHO.balanceOf(testUser);
        uint256 previewRedeem = STK_GHO.previewRedeem(stkGhoBalance);
        vm.stopPrank();

        assertEq(balance, int256(previewRedeem), "Oracle balance should match preview redeem");
        assertGt(balance, 0, "User should have positive staked GHO position");
    }

    function test_stk_gho_rewardTokenBalance() public {
        int256 balance = ghoOracle.getOracleBalanceForAsset(testUser, AAVE);

        // Get actual claimable rewards
        vm.startPrank(testUser);
        uint256 aaveBalanceBefore = IERC20(AAVE).balanceOf(testUser);
        STK_GHO.claimRewards(testUser, type(uint256).max);
        uint256 aaveBalanceAfter = IERC20(AAVE).balanceOf(testUser);
        vm.stopPrank();

        uint256 claimedRewards = aaveBalanceAfter - aaveBalanceBefore;

        assertEq(balance, int256(claimedRewards), "Oracle rewards should match actual claimed rewards");
        assertGt(balance, 0, "User should have positive AAVE rewards");
    }

    function test_stk_aave_stakedAndRewardBalance() public {
        int256 balance = aaveOracle.getOracleBalanceForAsset(aaveUser, AAVE);

        uint256 stkAaveBalance = STK_AAVE.balanceOf(aaveUser);

        vm.startPrank(aaveUser);
        uint256 previewRedeem = STK_AAVE.previewRedeem(stkAaveBalance);

        uint256 aaveBalanceBefore = IERC20(AAVE).balanceOf(aaveUser);
        STK_AAVE.claimRewards(aaveUser, type(uint256).max);
        uint256 aaveBalanceAfter = IERC20(AAVE).balanceOf(aaveUser);

        vm.stopPrank();

        uint256 claimedRewards = aaveBalanceAfter - aaveBalanceBefore;

        assertEq(balance, int256(previewRedeem + claimedRewards), "Oracle balance should match staked + rewards");
        assertGt(balance, 0, "User should have positive AAVE position");
    }

    function test_balanceOfZeroAddress() public view {
        assertEq(ghoOracle.getOracleBalanceForAsset(address(0), GHO), 0);
        assertEq(ghoOracle.getOracleBalanceForAsset(address(0), AAVE), 0);
    }

    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = ghoOracle.getOracleBalanceForAsset(0x458cD345B4C05e8DF39d0A07220feb4Ec19F5e6f, invalidToken);
        assertEq(balance, 0);
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assetsGho = ghoOracle.underlyingAssetsSupported();
        assertEq(assetsGho.length, 2);
        assertEq(assetsGho[0], GHO);
        assertEq(assetsGho[1], AAVE);

        address[] memory assetsAave = aaveOracle.underlyingAssetsSupported();
        assertEq(assetsAave.length, 1);
        assertEq(assetsAave[0], AAVE);
    }

    function test_rewardsWithZeroTotalSupply() public view {
        uint256 rewards = uint256(ghoOracle.getOracleBalanceForAsset(address(0xdead), AAVE));
        assertEq(rewards, 0);
    }

    function test_rewardsCalculation() public {
        uint256 initialRewards = uint256(ghoOracle.getOracleBalanceForAsset(testUser, AAVE));

        vm.warp(block.timestamp + 365 days);

        uint256 newRewards = uint256(ghoOracle.getOracleBalanceForAsset(testUser, AAVE));

        vm.startPrank(testUser);
        uint256 aaveBalanceBefore = IERC20(AAVE).balanceOf(testUser);
        STK_GHO.claimRewards(testUser, type(uint256).max);
        uint256 aaveBalanceAfter = IERC20(AAVE).balanceOf(testUser);
        vm.stopPrank();

        uint256 actualRewards = aaveBalanceAfter - aaveBalanceBefore;

        assertEq(newRewards, actualRewards, "Oracle rewards should match actual claimed rewards");
        assertGt(newRewards, initialRewards, "New rewards should be bigger then initial rewards");
    }

    function test_rewardsAfterDistributionEnd() public {
        uint256 initialRewards = uint256(ghoOracle.getOracleBalanceForAsset(testUser, AAVE));

        uint256 distributionEnd = STK_GHO.distributionEnd();

        // Move to beforee exact distribution end and get rewards
        vm.warp(distributionEnd - 1);
        uint256 rewardsBeforeEnd = uint256(ghoOracle.getOracleBalanceForAsset(testUser, AAVE));

        // Move to exact distribution end and get rewards
        vm.warp(distributionEnd);
        uint256 rewardsAtEnd = uint256(ghoOracle.getOracleBalanceForAsset(testUser, AAVE));

        // Move past distribution end
        vm.warp(distributionEnd + 100 days);
        uint256 rewardsAfterEnd = uint256(ghoOracle.getOracleBalanceForAsset(testUser, AAVE));

        assertGt(rewardsBeforeEnd, initialRewards, "Rewards should accrue until distribution end");
        assertGt(rewardsAtEnd, initialRewards, "Rewards should accrue until distribution end");

        assertLe(rewardsBeforeEnd, rewardsAtEnd, "Rewards should accrue until distribution end");
        assertEq(rewardsAfterEnd, rewardsAtEnd, "Rewards should not increase after distribution end");
    }

    function test_supportsInterface() public view {
        assertTrue(ghoOracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(ghoOracle.supportsInterface(type(IERC165).interfaceId));
    }
}
