// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {DaiDsrBalanceOracle, PotLike} from "src/balances/protocols/DaiDsr.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Minimal mock for Pot contract (used by DaiDsrBalanceOracle)
contract MockPot {
    uint256 public constant RAY = 10 ** 27;

    function dsr() external pure returns (uint256) {
        return RAY;
    }

    function chi() external pure returns (uint256) {
        return RAY;
    }

    function rho() external pure returns (uint256) {
        return type(uint32).max; // so block.timestamp > rho is false in unit tests
    }

    function drip() external pure returns (uint256) {
        return RAY;
    }

    function join(uint256) external pure {}

    function exit(uint256) external pure {}
}

/// @notice Minimal mock for DsrManager (used by DaiDsrBalanceOracle)
contract MockDsrManager {
    MockPot public immutable POT;

    constructor() {
        POT = new MockPot();
    }

    function pot() external view returns (PotLike) {
        return PotLike(address(POT));
    }

    function pieOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @title DaiDsrBalanceOracleTest
/// @notice Unit and implementation tests for DaiDsrBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract DaiDsrBalanceOracleTest is BalanceAdapterTestBase {
    DaiDsrBalanceOracle public oracle;
    MockDsrManager public mockDsrManager;

    function setUp() public override {
        super.setUp();
        mockDsrManager = new MockDsrManager();
        oracle = new DaiDsrBalanceOracle(
            address(dai), // use test base DAI token so it's a real contract if ever queried
            address(mockDsrManager),
            "Maker",
            "{\"protocol\":\"Maker\",\"product\":\"Savings\",\"name\":\"DSR\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
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
