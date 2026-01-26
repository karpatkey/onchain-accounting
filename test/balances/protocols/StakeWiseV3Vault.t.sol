// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {StakeWiseV3VaultBalanceOracle} from "src/balances/protocols/StakeWiseV3Vault.sol";
import {InvalidArguments} from "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title StakeWiseV3VaultBalanceOracleTest
/// @notice Unit and implementation tests for StakeWiseV3VaultBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract StakeWiseV3VaultBalanceOracleTest is BalanceAdapterTestBase {
    StakeWiseV3VaultBalanceOracle public oracle;
    MockBalances public mockBalances;
    
    // Mock addresses (for unit tests)
    address public constant MOCK_UNDERLYING = address(0x1111111111111111111111111111111111111111);
    address public constant MOCK_VAULT = address(0x2222222222222222222222222222222222222222);
    
    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        oracle = new StakeWiseV3VaultBalanceOracle(
            MOCK_UNDERLYING,
            MOCK_VAULT,
            "Stakewise v3",
            "Some vault",
            address(balances)
        );
    }
    
    // ============================================
    // Constructor Tests
    // ============================================
    
    function test_constructor_reverts_on_zero_address() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3VaultBalanceOracle(address(0), address(0), "Stakewise v3", "Some vault", address(mockBalances));
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");
        
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(alice, invalidToken);
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        int256 balance = oracle.getOracleBalanceForAsset(address(0), address(usdc));
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
