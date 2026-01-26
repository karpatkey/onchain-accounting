// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {CometExtInterface, CompoundV3CometWithMultiplier} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

interface CometRewardsAux {
    function getRewardOwed(address comet, address account) external returns (address token, uint256 owed);
}

/// @title CompoundV3CometWithMultiplierBalanceOracleTest
/// @notice Unit and implementation tests for CompoundV3CometWithMultiplierBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract CompoundV3CometWithMultiplierBalanceOracleTest is BalanceAdapterTestBase {
    CompoundV3CometWithMultiplier public oracle;
    MockBalances public mockBalances;
    
    // Mock Compound addresses (for unit tests)
    address public constant MOCK_COMPOUND_REWARDS = address(0x1111111111111111111111111111111111111111);
    address public constant MOCK_COMET = address(0x2222222222222222222222222222222222222222);
    address public constant MOCK_REWARD_TOKEN = address(0x3333333333333333333333333333333333333333);
    
    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        oracle = new CompoundV3CometWithMultiplier(
            MOCK_COMPOUND_REWARDS,
            MOCK_COMET,
            MOCK_REWARD_TOKEN,
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
            MOCK_COMET,
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, 0, 0, 0, 0, 1)
        );
        
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertGt(balance, 0, "Balance should be positive (credit)");
    }
    
    function test_getOracleBalanceForAsset_edgeCase_MinimalPrincipal() public {
        address user = address(1);
        
        int104 maxNegativePrincipal = type(int104).min;
        vm.mockCall(
            MOCK_COMET,
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxNegativePrincipal, 0, 0, 0, 0, 1)
        );
        
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertLt(balance, 0, "Balance should be negative (debt)");
    }
    
    function test_getOracleBalanceForAsset_edgeCase_OneMultiplier() public {
        address user = address(1);
        
        int104 maxPositivePrincipal = 1;
        vm.mockCall(
            MOCK_COMET,
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, 1, 1, 1, 1, 1)
        );
        
        int256 balance = oracle.getOracleBalanceForAsset(user, MOCK_REWARD_TOKEN);
        assertEq(balance, 1_000_000_000_000);
    }
    
    function test_getOracleBalanceForAsset_edgeCase_DoubleMultiplier() public {
        address user = address(1);
        
        int104 maxNegativePrincipal = 1;
        vm.mockCall(
            MOCK_COMET,
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxNegativePrincipal, 1, 2, 1, 1, 1)
        );
        
        int256 balance = oracle.getOracleBalanceForAsset(user, MOCK_REWARD_TOKEN);
        assertEq(balance, -2_000_000_000_000);
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
