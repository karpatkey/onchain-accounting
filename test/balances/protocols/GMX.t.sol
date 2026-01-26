// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {GmxBalanceOracle} from "src/balances/protocols/GMX.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title GmxBalanceOracleTest
/// @notice Unit and implementation tests for GmxBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract GmxBalanceOracleTest is BalanceAdapterTestBase {
    GmxBalanceOracle public oracle;
    MockBalances public mockBalances;
    
    // Mock GMX addresses (for unit tests)
    address public constant MOCK_MARKET = address(0x1111111111111111111111111111111111111111);
    address public constant MOCK_READER = address(0x2222222222222222222222222222222222222222);
    address public constant MOCK_REFERRAL_STORAGE = address(0x3333333333333333333333333333333333333333);
    address public constant MOCK_COLLATERAL_TOKEN = address(0x4444444444444444444444444444444444444444);
    address public constant MOCK_INDEX_TOKEN = address(0x5555555555555555555555555555555555555555);
    address public constant MOCK_PRICE_FEED = address(0x6666666666666666666666666666666666666666);
    
    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        
        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(usdc), MOCK_PRICE_FEED);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(weth), MOCK_PRICE_FEED);
        
        oracle = new GmxBalanceOracle(
            MOCK_MARKET,
            MOCK_READER,
            MOCK_REFERRAL_STORAGE,
            address(usdc),
            address(weth),
            false,
            feeds,
            "GMX",
            "Test Market",
            address(balances)
        );
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
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
