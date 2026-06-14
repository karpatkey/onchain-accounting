// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {DaiDsrBalanceAdapter, PotLike} from "src/balances/protocols/DaiDsr.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Minimal mock for Pot contract (used by DaiDsrBalanceAdapter)
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

/// @notice Minimal mock for DsrManager (used by DaiDsrBalanceAdapter)
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

/// @title DaiDsrBalanceAdapterTest
/// @notice Unit and implementation tests for DaiDsrBalanceAdapter
/// @dev Tests adapter logic and error handling without requiring fork
contract DaiDsrBalanceAdapterTest is BalanceAdapterTestBase {
    DaiDsrBalanceAdapter public adapter;
    MockDsrManager public mockDsrManager;

    function setUp() public override {
        super.setUp();
        mockDsrManager = new MockDsrManager();
        adapter = new DaiDsrBalanceAdapter(
            address(dai), // use test base DAI token so it's a real contract if ever queried
            address(mockDsrManager),
            address(balances)
        );
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getAdapterBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        // getAdapterBalanceForAsset returns 0 for unsupported tokens
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, invalidToken);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_returns_zero_for_zero_address() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_getAdapterBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, uint256[] memory amounts,) = adapter.getAdapterBalances(address(0));

        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getAdapterPositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(address(0), address(0));

        assertEq(positions.length, 0);
    }
}
