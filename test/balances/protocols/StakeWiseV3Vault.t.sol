// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {StakeWiseV3VaultBalanceOracle} from "src/balances/protocols/StakeWiseV3Vault.sol";
import {InvalidArguments} from "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title StakeWiseV3VaultBalanceOracleTest
/// @notice Unit and implementation tests for StakeWiseV3VaultBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract StakeWiseV3VaultBalanceOracleTest is BalanceAdapterTestBase {
    StakeWiseV3VaultBalanceOracle public oracle;
    MockBalances public mockBalances;
    MockContract public mockUnderlying;
    MockContract public mockVault;

    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        mockUnderlying = new MockContract();
        mockVault = new MockContract();
        oracle = new StakeWiseV3VaultBalanceOracle(
            address(mockUnderlying), address(mockVault), "Stakewise v3", "{\"protocol\":\"StakeWise V3\",\"product\":\"Staking\",\"name\":\"Vault\"", "0x0000000000000000000000000000000000000001", address(balances)
        );
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_reverts_on_zero_address() public {
        vm.expectRevert(InvalidArguments.selector);
        new StakeWiseV3VaultBalanceOracle(address(0), address(0), "Stakewise v3", "{\"protocol\":\"StakeWise V3\",\"product\":\"Staking\",\"name\":\"Vault\"", "0x0000000000000000000000000000000000000001", address(mockBalances));
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        // getOracleBalanceForAsset returns 0 for unsupported tokens
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, invalidToken);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
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
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(address(0));

        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));

        assertEq(positions.length, 0);
    }
}
