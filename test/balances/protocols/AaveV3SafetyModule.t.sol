// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import "src/errors.sol";

/// @title AaveV3SafetyModuleBalanceOracleTest
/// @notice Unit and implementation tests for AaveV3SafetyModuleBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract AaveV3SafetyModuleBalanceOracleTest is BalanceAdapterTestBase {
    AaveV3SafetyModuleBalanceOracle public oracle;
    MockBalances public mockBalances;
    
    // Mock stake token address (for unit tests)
    address public constant MOCK_STAKE_TOKEN = address(0x1111111111111111111111111111111111111111);
    
    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        oracle = new AaveV3SafetyModuleBalanceOracle(
            MOCK_STAKE_TOKEN,
            "Aave v3",
            "Safety Module",
            address(balances)
        );
    }
    
    // ============================================
    // Constructor Tests
    // ============================================
    
    function test_constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveV3SafetyModuleBalanceOracle(address(0), "Aave v3", "Safety Module", address(mockBalances));
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
        int256 balance1 = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(balance1, 0);
        
        int256 balance2 = oracle.getOracleBalanceForAsset(address(0), address(dai));
        assertEq(balance2, 0);
    }
    
    // ============================================
    // Interface Compliance Tests
    // ============================================
    
    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }
    
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
