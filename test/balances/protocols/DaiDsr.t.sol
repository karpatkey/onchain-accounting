// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import {DaiDsrBalanceOracle, PotLike, DsrManager} from "src/balances/protocols/DaiDsr.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";

contract DaiDsrBalanceOracleTest is TestEnvConfigurator {
    uint256 fork;

    address dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address dsr = address(0x373238337Bfe1146fb49989fc222523f83081dDb);

    PotLike public pot;
    DsrManager public dsrManager;

    DaiDsrBalanceOracle oracle;
    MockBalances mockBalances;

    function setUp() public {
        mockBalances = new MockBalances();
    }

    // Use an existing user that already has DAI in DSR
    // This avoids the complexity of setting up a new DSR position which requires Vat authorization
    // Using the same safe address from NAVCalculator fork tests which has DSR balance at this block
    address public constant TEST_USER = address(0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B);
    uint256 public constant FORK_BLOCK = 20_993_780;

    /// @notice Tests balance calculation when rho was just updated (rho == block.timestamp)
    /// @notice In this case, no compounding calculation is needed since rho is current
    function test_mainnet_balanceOf_when_rho_is_current() public {
        // Use a specific block where we know there are DSR balances
        fork = vm.createSelectFork(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);

        // Initialize contracts
        oracle = new DaiDsrBalanceOracle(dai, dsr, "Maker", "DSR", address(mockBalances));
        pot = oracle.POT();

        // Manually call drip() to update rho to current block timestamp
        // This ensures rho == block.timestamp for our test
        pot.drip();

        uint256 rho = pot.rho();

        // Verify rho matches block timestamp (was just updated by drip)
        assertEq(rho, block.timestamp, "rho should equal block.timestamp after drip");

        // Calculate balance for test user - should use chi directly without compounding
        int256 balance = oracle.balanceOf(dai, TEST_USER);
        assertGt(balance, 0, "balance should be positive");
    }

    /// @notice Tests balance calculation when rho hasn't been updated (rho < block.timestamp)
    /// @notice In this case, the contract must manually calculate compounding interest
    function test_mainnet_balanceOf_when_rho_is_stale() public {
        // Use a specific block where we know there are DSR balances
        fork = vm.createSelectFork(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);

        // Initialize contracts
        oracle = new DaiDsrBalanceOracle(dai, dsr, "Maker", "DSR", address(mockBalances));
        pot = oracle.POT();

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
        int256 balance = oracle.balanceOf(dai, TEST_USER);
        assertGt(balance, 0, "balance should be positive");

        // Balance with stale rho should be higher than with current rho due to compounding
        // (though the difference may be small depending on the time elapsed)
    }
}
