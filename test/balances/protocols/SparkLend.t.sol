// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {SparkLendBalanceOracle} from "src/balances/protocols/SparkLend.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MockAaveProtocolDataProvider, MockAaveRewardsDistributor} from "test/balances/protocols/AaveV3Instance.t.sol";

/// @title SparkLendBalanceOracleTest
/// @notice Unit and implementation tests for SparkLendBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
/// @dev SparkLend inherits from AaveV3Instance, so most logic is tested there
contract SparkLendBalanceOracleTest is BalanceAdapterTestBase {
    SparkLendBalanceOracle public oracle;
    MockAaveProtocolDataProvider public mockDataProvider;
    MockAaveRewardsDistributor public mockRewardsDistributor;
    
    function setUp() public override {
        super.setUp();
        mockDataProvider = new MockAaveProtocolDataProvider();
        mockRewardsDistributor = new MockAaveRewardsDistributor();
        oracle = new SparkLendBalanceOracle(
            address(mockDataProvider),
            address(mockRewardsDistributor),
            "Spark",
            address(balances)
        );
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");
        
        // getOracleBalanceForAsset should return 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(alice, invalidToken);
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        int256 balance = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(balance, 0);
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
