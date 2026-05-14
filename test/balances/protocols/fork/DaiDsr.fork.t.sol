// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {DaiDsrBalanceOracle, PotLike} from "src/balances/protocols/DaiDsr.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title DaiDsrBalanceOracleForkTest
/// @notice Fork tests for DaiDsrBalanceOracle using real mainnet contracts
/// @dev Tests adapter behavior with real Maker DSR contracts and positions
contract DaiDsrBalanceOracleForkTest is BalanceAdapterTestBase {
    // Maker contract addresses (mainnet)
    address public constant DAI = MAINNET_DAI;
    address public constant DSR = 0x373238337Bfe1146fb49989fc222523f83081dDb;

    // Fork block
    uint256 public constant FORK_BLOCK = 20_993_780;

    // Oracle instance
    DaiDsrBalanceOracle public oracle;
    PotLike public pot;

    // Real user address with DAI in DSR
    // Use an existing user that already has DAI in DSR
    // This avoids the complexity of setting up a new DSR position which requires Vat authorization
    address public constant TEST_USER = 0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B;

    function setUp() public override {
        super.setUp();
        _setupFork();
    }

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        balances = _deployBalancesForOracle(DAI);
        oracle = new DaiDsrBalanceOracle(
            DAI,
            DSR,
            "Maker",
            "{\"protocol\":\"Maker\",\"product\":\"DSR\"",
            "0x0000000000000000000000000000000000000001",
            address(balances)
        );
        pot = oracle.POT();
    }

    // ============================================
    // Balance Calculation Tests
    // ============================================

    /// @notice Tests balance calculation when rho was just updated (rho == block.timestamp)
    /// @notice In this case, no compounding calculation is needed since rho is current
    function test_getOracleBalanceForAsset_when_rho_is_current() public {
        // Manually call drip() to update rho to current block timestamp
        // This ensures rho == block.timestamp for our test
        pot.drip();

        uint256 rho = pot.rho();

        // Verify rho matches block timestamp (was just updated by drip)
        assertEq(rho, block.timestamp, "rho should equal block.timestamp after drip");

        // Calculate balance for test user - should use chi directly without compounding
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_USER, DAI);
        assertGt(amount, 0, "Balance should be positive");
        assertFalse(isDebt);
    }

    /// @notice Tests balance calculation when rho hasn't been updated (rho < block.timestamp)
    /// @notice In this case, the contract must manually calculate compounding interest
    function test_getOracleBalanceForAsset_when_rho_is_stale() public {
        // Get initial rho value
        uint256 initialRho = pot.rho();

        // Advance time to make rho stale (but don't call drip)
        // This simulates the case where rho hasn't been updated
        vm.warp(block.timestamp + 1 days);

        // Verify rho is now stale (less than current block timestamp)
        uint256 rho = pot.rho();

        assertEq(rho, initialRho, "rho should not change without drip");
        assertLt(rho, block.timestamp, "rho should be less than block.timestamp when stale");

        // Calculate balance for test user - should apply compounding calculation
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(TEST_USER, DAI);
        assertGt(amount, 0, "Balance should be positive");
        assertFalse(isDebt);

        // Balance with stale rho should be higher than with current rho due to compounding
        // (though the difference may be small depending on the time elapsed)
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalance_returnsCorrectBalance() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(TEST_USER);

        // Should have DAI position
        assertGe(assets.length, 1, "Should have at least one position");
        assertEq(assets.length, amounts.length, "Arrays should match length");

        // Verify DAI is present
        bool foundDai = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == DAI) {
                foundDai = true;
                assertGt(amounts[i], 0, "DAI balance should be positive");
                assertFalse(isDebt[i], "DAI should be credit");
            }
        }

        assertTrue(foundDai, "Should find DAI position");
    }

    function test_getOraclePositions_returnsCorrectPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(TEST_USER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
