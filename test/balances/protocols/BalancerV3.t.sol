// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/BalancerV3.sol";
import {InvalidArguments} from "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title BalancerV3PoolBalanceOracleTest
/// @notice Unit and implementation tests for BalancerV3PoolBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract BalancerV3PoolBalanceOracleTest is BalanceAdapterTestBase {
    BalancerV3PoolBalanceOracle public oracle;
    MockBalances public mockBalances;
    
    // Mock addresses (for unit tests)
    address public constant MOCK_POOL = address(0x1111111111111111111111111111111111111111);
    address public constant MOCK_GAUGE = address(0x2222222222222222222222222222222222222222);
    address public constant MOCK_MINTER = address(0x3333333333333333333333333333333333333333);
    
    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        oracle = new BalancerV3PoolBalanceOracle(
            MOCK_POOL,
            MOCK_GAUGE,
            MOCK_MINTER,
            "Balancer v3",
            address(balances)
        );
    }
    
    // ============================================
    // Constructor Tests
    // ============================================
    
    function test_constructor() public view {
        assertEq(address(oracle.POOL()), MOCK_POOL);
        assertEq(address(oracle.GAUGE()), MOCK_GAUGE);
    }
    
    function test_constructor_reverts_zeroPool() public {
        vm.expectRevert(InvalidArguments.selector);
        new BalancerV3PoolBalanceOracle(address(0), MOCK_GAUGE, MOCK_MINTER, "Balancer v3", address(mockBalances));
    }
    
    function test_constructor_reverts_zeroGauge() public {
        vm.expectRevert(InvalidArguments.selector);
        new BalancerV3PoolBalanceOracle(MOCK_POOL, address(0), MOCK_MINTER, "Balancer v3", address(mockBalances));
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_returns_zero_for_nonPoolToken() public {
        address randomToken = address(0x1234);
        
        int256 balance = oracle.getOracleBalanceForAsset(alice, randomToken);
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_returns_zero_when_noBpt() public {
        address deadAddress = address(0xdead);
        
        int256 balance1 = oracle.getOracleBalanceForAsset(deadAddress, address(usdc));
        assertEq(balance1, 0);
        
        int256 balance2 = oracle.getOracleBalanceForAsset(deadAddress, address(dai));
        assertEq(balance2, 0);
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
    
    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public {
        INAVCalculator.PositionBalance[] memory positions = 
            oracle.getOraclePositions(address(0), address(0));
        
        assertEq(positions.length, 0);
    }
}
