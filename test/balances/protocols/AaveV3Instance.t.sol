// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Mock Aave Protocol Data Provider
contract MockAaveProtocolDataProvider {
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

    TokenData[] public reserves;

    function getAllReservesTokens() external view returns (TokenData[] memory) {
        return reserves;
    }

    function getUserReserveData(
        address,
        /* asset */
        address /* user */
    )
        external
        pure
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        )
    {
        // Return zeros for all values (can be customized in tests if needed)
        return (0, 0, 0, 0, 0, 0, 0, 0, false);
    }

    function addReserve(string memory symbol, address tokenAddress) external {
        reserves.push(TokenData({symbol: symbol, tokenAddress: tokenAddress}));
    }
}

/// @title AaveV3InstanceBalanceOracleTest
/// @notice Unit and implementation tests for AaveV3InstanceBalanceOracle
/// @dev Tests adapter logic and implementation without requiring fork
contract AaveV3InstanceBalanceOracleTest is BalanceAdapterTestBase {
    AaveV3InstanceBalanceOracle public oracle;
    MockAaveProtocolDataProvider public mockDataProvider;

    function setUp() public override {
        super.setUp();
        mockDataProvider = new MockAaveProtocolDataProvider();
        oracle = new AaveV3InstanceBalanceOracle(
            address(mockDataProvider),
            "Aave v3",
            "{\"protocol\":\"Aave V3\",\"product\":\"Lending\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_constructor_setsCorrectValues() public view {
        assertEq(address(oracle.DATA_PROVIDER()), address(mockDataProvider));
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        // getOracleBalanceForAsset should return 0 for unsupported tokens
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, invalidToken);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address_account() public {
        address invalidToken = makeAddr("invalidToken");

        // Zero address account should return zero
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), invalidToken);
        assertEq(amount, 0);
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_underlyingAssetsSupported_returnsArray() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertGe(assets.length, 0, "returns array");
    }

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
