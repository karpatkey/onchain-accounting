// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "src/balances/protocols/StakeWiseV3OsToken.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title StakeWiseV3OsTokenBalanceOracleTest
/// @notice Unit and implementation tests for StakeWiseV3OsTokenBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract StakeWiseV3OsTokenBalanceOracleTest is BalanceAdapterTestBase {
    StakeWiseV3OsTokenBalanceOracle public oracle;
    MockContract public mockOsToken;
    MockContract public mockUnderlying;
    MockContract public mockVaultController;

    function setUp() public override {
        super.setUp();
        mockOsToken = new MockContract();
        mockUnderlying = new MockContract();
        mockVaultController = new MockContract();
        oracle = new StakeWiseV3OsTokenBalanceOracle(
            address(mockOsToken),
            address(mockUnderlying),
            address(mockVaultController),
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
        assertEq(assets[0], address(mockUnderlying));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_getOracleBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, int256[] memory balances) = oracle.getOracleBalance(address(0));

        assertEq(assets.length, 0);
        assertEq(balances.length, 0);
    }

    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));

        assertEq(positions.length, 0);
    }
}
