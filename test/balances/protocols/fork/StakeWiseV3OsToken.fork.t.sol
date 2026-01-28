// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterForkTestBase} from "test/balances/protocols/fork/BalanceAdapterForkTestBase.sol";
import {StakeWiseV3OsTokenBalanceOracle} from "src/balances/protocols/StakeWiseV3OsToken.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title StakeWiseV3OsTokenBalanceOracleForkTest
/// @notice Fork tests for StakeWiseV3OsTokenBalanceOracle using real Gnosis chain contracts
/// @dev Tests adapter behavior with real StakeWise V3 osToken contracts and positions
contract StakeWiseV3OsTokenBalanceOracleForkTest is BalanceAdapterForkTestBase {
    // Gnosis chain addresses
    address public constant OS_GNO = 0xF490c80aAE5f2616d3e3BDa2483E30C4CB21d1A0;
    address public constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public constant OS_TOKEN_VAULT_CONTROLLER = 0x60B2053d7f2a0bBa70fe6CDd88FB47b579B9179a;

    // Fork block
    uint256 public constant FORK_BLOCK = 40_418_428;

    // Oracle instance
    StakeWiseV3OsTokenBalanceOracle public oracle;

    // Real user address with osGNO position
    address public constant OS_GNO_HOLDER = 0x84d5922fF253e7287b642091F5803dF28a7E39Aa;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(GNO);
        oracle = new StakeWiseV3OsTokenBalanceOracle(
            OS_GNO, GNO, OS_TOKEN_VAULT_CONTROLLER, "Stakewise v3", "osGNO", address(balances)
        );
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getOracleBalanceForAsset_gnosisInstance() public view {
        int256 balance = oracle.getOracleBalanceForAsset(OS_GNO_HOLDER, GNO);

        assertEq(balance, 1_176_150_159_277_420_338_054);
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalance_aggregatesPositions() public view {
        (address[] memory assets, int256[] memory balances) = oracle.getOracleBalance(OS_GNO_HOLDER);

        // Should have at least GNO position
        assertGe(assets.length, 1, "Should have at least one position");
        assertEq(assets.length, balances.length, "Arrays should match length");
    }

    function test_getOraclePositions_returnsCorrectPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(OS_GNO_HOLDER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
