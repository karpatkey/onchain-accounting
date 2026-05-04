// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV2InstanceBalanceOracle} from "src/balances/protocols/AaveV2Instance.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MockAaveProtocolDataProvider} from "test/balances/protocols/AaveV3Instance.t.sol";

/// @title AaveV2InstanceBalanceOracleTest
/// @notice Unit and implementation tests for AaveV2InstanceBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
/// @dev `AaveV2InstanceBalanceOracle` inherits from `AaveV3InstanceBalanceOracle` — the V2
/// ProtocolDataProvider exposes the same `getAllReservesTokens()` and
/// `getUserReserveData(asset, user)` ABI as V3, so most logic is covered by the
/// `AaveV3InstanceBalanceOracle` unit suite.
contract AaveV2InstanceBalanceOracleTest is BalanceAdapterTestBase {
    AaveV2InstanceBalanceOracle public oracle;
    MockAaveProtocolDataProvider public mockDataProvider;

    function setUp() public override {
        super.setUp();
        mockDataProvider = new MockAaveProtocolDataProvider();
        oracle = new AaveV2InstanceBalanceOracle(address(mockDataProvider), "Aave V2", address(balances));
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

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address_account() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
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
