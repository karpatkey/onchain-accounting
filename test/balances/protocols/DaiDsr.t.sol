// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {DaiDsrBalanceOracle} from "src/balances/protocols/DaiDsr.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title DaiDsrBalanceOracleTest
/// @notice Unit and implementation tests for DaiDsrBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract DaiDsrBalanceOracleTest is BalanceAdapterTestBase {
    DaiDsrBalanceOracle public oracle;
    MockBalances public mockBalances;
    
    // Mock Maker addresses (for unit tests)
    address public constant MOCK_DAI = address(0x1111111111111111111111111111111111111111);
    address public constant MOCK_DSR = address(0x2222222222222222222222222222222222222222);
    
    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        oracle = new DaiDsrBalanceOracle(
            MOCK_DAI,
            MOCK_DSR,
            "Maker",
            "DSR",
            address(balances)
        );
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
