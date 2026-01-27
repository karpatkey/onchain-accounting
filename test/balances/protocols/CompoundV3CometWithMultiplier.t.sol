// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {CometExtInterface, CompoundV3CometWithMultiplier} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {MockCometMinimal} from "test/balances/protocols/CompoundV3Comet.t.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Mock Compound rewards for WithMultiplier: rewardConfig returns 4 values (token, rescaleFactor, shouldUpscale, multiplier).
contract MockCompoundRewardsWithMultiplier {
    address public rewardToken;
    uint64 public rescaleFactor;
    bool public shouldUpscale;
    uint256 public multiplier;

    constructor(address rewardToken_, uint64 rescaleFactor_, bool shouldUpscale_, uint256 multiplier_) {
        rewardToken = rewardToken_;
        rescaleFactor = rescaleFactor_ == 0 ? 1 : rescaleFactor_; // avoid div by zero in adapter
        shouldUpscale = shouldUpscale_;
        multiplier = multiplier_;
    }

    function rewardConfig(address)
        external
        view
        returns (address token, uint64 rescaleFactor_, bool shouldUpscale_, uint256 multiplier_)
    {
        return (rewardToken, rescaleFactor, shouldUpscale, multiplier);
    }

    function rewardsClaimed(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @title CompoundV3CometWithMultiplierBalanceOracleTest
/// @notice Unit and implementation tests for CompoundV3CometWithMultiplierBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract CompoundV3CometWithMultiplierBalanceOracleTest is BalanceAdapterTestBase {
    CompoundV3CometWithMultiplier public oracle;
    MockCompoundRewardsWithMultiplier public mockCompoundRewards;
    MockCometMinimal public mockComet;
    MockContract public mockRewardToken;

    function setUp() public override {
        super.setUp();
        mockRewardToken = new MockContract();
        // rewardConfig returns (token, rescaleFactor=1, shouldUpscale=false, multiplier=1e18)
        mockCompoundRewards = new MockCompoundRewardsWithMultiplier(
            address(mockRewardToken),
            1,
            false,
            1e18
        );
        mockComet = new MockCometMinimal(address(usdc));
        oracle = new CompoundV3CometWithMultiplier(
            address(mockCompoundRewards),
            address(mockComet),
            address(mockRewardToken),
            "Compound v3",
            "USDC Comet",
            address(balances)
        );
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_returns_zero_for_unsupported_token() public {
        address unsupportedToken = address(1);
        
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(alice, unsupportedToken);
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        int256 balance = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_returns_zero_for_user_without_position() public view {
        address user = address(1);
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertEq(balance, 0);
    }
    
    // ============================================
    // Edge Case Tests (Using Mocks)
    // ============================================
    
    function test_getOracleBalanceForAsset_edgeCase_MaxPrincipal() public {
        address user = address(1);
        int104 maxPositivePrincipal = type(int104).max;
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, uint64(0), uint64(0), uint16(0), uint8(0))
        );
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertGt(balance, 0, "Balance should be positive (credit)");
    }

    function test_getOracleBalanceForAsset_edgeCase_MinimalPrincipal() public {
        address user = address(1);
        int104 maxNegativePrincipal = type(int104).min;
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxNegativePrincipal, uint64(0), uint64(0), uint16(0), uint8(0))
        );
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertLt(balance, 0, "Balance should be negative (debt)");
    }
    
    function test_getOracleBalanceForAsset_edgeCase_OneMultiplier() public {
        address user = address(1);
        // userBasic(principal=1, baseTrackingIndex=1, baseTrackingAccrued=1, assetsIn=0, reserved=0)
        // -> updateBasePrincipal yields accrued 1; reward = 1 * 1e18 / 1e18 = 1
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(int104(1), uint64(1), uint64(1), uint16(0), uint8(0))
        );
        int256 balance = oracle.getOracleBalanceForAsset(user, address(mockRewardToken));
        assertEq(balance, 1);
    }

    function test_getOracleBalanceForAsset_edgeCase_DoubleMultiplier() public {
        address user = address(1);
        // userBasic(principal=1, baseTrackingIndex=1, baseTrackingAccrued=2, ...) -> accrued 2; reward = 2
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(int104(1), uint64(1), uint64(2), uint16(0), uint8(0))
        );
        int256 balance = oracle.getOracleBalanceForAsset(user, address(mockRewardToken));
        assertEq(balance, 2);
    }
    
    // ============================================
    // Interface Compliance Tests
    // ============================================
    
    function test_getOracleBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, int256[] memory balances) = 
            oracle.getOracleBalance(address(0));
        
        assertEq(assets.length, 0);
        assertEq(balances.length, 0);
    }
    
    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = 
            oracle.getOraclePositions(address(0), address(0));
        
        assertEq(positions.length, 0);
    }
}
