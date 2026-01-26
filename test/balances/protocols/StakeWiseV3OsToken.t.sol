// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "src/balances/protocols/StakeWiseV3OsToken.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title StakeWiseV3OsTokenBalanceOracleTest
/// @notice Unit and implementation tests for StakeWiseV3OsTokenBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract StakeWiseV3OsTokenBalanceOracleTest is BalanceAdapterTestBase {
    StakeWiseV3OsTokenBalanceOracle public oracle;
    MockBalances public mockBalances;
    
    // Mock addresses (for unit tests)
    address public constant MOCK_OS_TOKEN = address(0x1111111111111111111111111111111111111111);
    address public constant MOCK_UNDERLYING = address(0x2222222222222222222222222222222222222222);
    address public constant MOCK_VAULT_CONTROLLER = address(0x3333333333333333333333333333333333333333);
    
    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        oracle = new StakeWiseV3OsTokenBalanceOracle(
            MOCK_OS_TOKEN,
            MOCK_UNDERLYING,
            MOCK_VAULT_CONTROLLER,
            "Stakewise v3",
            "osGNO",
            address(balances)
        );
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_returns_zero_for_unsupported_address() public view {
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_returns_zero_for_incorrect_token() public {
        address incorrectToken = makeAddr("incorrectToken");
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(alice, incorrectToken);
        assertEq(balance, 0);
    }
    
    // ============================================
    // Supported Assets Tests
    // ============================================
    
    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], MOCK_UNDERLYING);
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
