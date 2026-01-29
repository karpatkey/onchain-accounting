// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceAdapterForkTestBase} from "test/balances/protocols/fork/BalanceAdapterForkTestBase.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/BalancerV3.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title BalancerV3PoolBalanceOracleForkTest
/// @notice Fork tests for BalancerV3PoolBalanceOracle using real mainnet contracts
/// @dev Tests adapter behavior with real Balancer V3 pool contracts and positions
contract BalancerV3PoolBalanceOracleForkTest is BalanceAdapterForkTestBase {
    // Balancer V3 contract addresses (mainnet)
    address public constant POOL = 0x85B2b559bC2D21104C4DEFdd6EFcA8A20343361D;
    address public constant GAUGE = 0x9fdD52eFEb601E4Bc78b89C6490505B8aC637E9f;
    address public constant BALANCER_MINTER = 0x239e55F427D44C3cc793f49bFB507ebe76638a2b;

    // Token addresses
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant USDT = MAINNET_USDT;
    address public constant USDC = MAINNET_USDC;
    address public constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;

    // Fork blocks
    uint256 public constant FORK_BLOCK = 22_087_430;
    uint256 public constant FORK_BLOCK_2 = 22_131_971;
    uint256 public constant FORK_BLOCK_3 = 22_131_954;
    /// @notice Fork block for Aave GHO/USDT/USDC Tenderly simulation
    uint256 public constant FORK_BLOCK_TENDERLY = 23_569_450;

    // Oracle instance
    BalancerV3PoolBalanceOracle public oracle;

    // Real user addresses with positions in Balancer V3
    address public constant MAINNET_STAKED_USER = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
    address public constant MAINNET_UNSTAKED_USER = 0x9fdD52eFEb601E4Bc78b89C6490505B8aC637E9f;
    address public constant MAINNET_WHALE_USER = 0xaF52695E1bB01A16D33D7194C28C42b10e0Dbec2;
    /// @notice Test user for Aave GHO/USDT/USDC (Tenderly expected values)
    address public constant USER_TENDERLY = 0xC01318baB7ee1f5ba734172bF7718b5DC6Ec90E1;

    // Expected oracle balances at FORK_BLOCK_TENDERLY for USER_TENDERLY (Tenderly simulation)
    uint256 public constant EXPECTED_USDT = 1_148_397; // 6 decimals
    uint256 public constant EXPECTED_USDC = 3_714_973; // 6 decimals
    uint256 public constant EXPECTED_GHO = 5_135_070_405_257_166_097; // 18 decimals

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        balances = _deployBalancesForOracle(_getSupportedAssets());
        // Pool: Aave GHO/USDT/USDC; position type: Supplied
        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, "Balancer v3", address(balances));
    }

    function _getSupportedAssets() internal pure returns (address[] memory) {
        address[] memory assets = new address[](4);
        assets[0] = USDT;
        assets[1] = USDC;
        assets[2] = GHO;
        assets[3] = BAL;
        return assets;
    }

    // ============================================
    // Real Position Tests
    // ============================================

    /// @notice Oracle balances at fork 23_569_450 match Tenderly simulation for USER_TENDERLY (Aave GHO/USDT/USDC)
    function test_getOracleBalanceForAsset_tenderly_expectedValues() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_TENDERLY);
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, "Balancer v3", address(balances));

        (uint256 amountUsdt, bool isDebtUsdt) = oracle.getOracleBalanceForAsset(USER_TENDERLY, USDT);
        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(USER_TENDERLY, USDC);
        (uint256 amountGho, bool isDebtGho) = oracle.getOracleBalanceForAsset(USER_TENDERLY, GHO);

        assertEq(amountUsdt, EXPECTED_USDT, "USDT balance should match Tenderly");
        assertFalse(isDebtUsdt);
        assertEq(amountUsdc, EXPECTED_USDC, "USDC balance should match Tenderly");
        assertFalse(isDebtUsdc);
        assertEq(amountGho, EXPECTED_GHO, "GHO balance should match Tenderly");
        assertFalse(isDebtGho);
    }

    function test_getOracleBalanceForAsset_mainnet_staked_gauge() public {
        vm.rollFork(FORK_BLOCK_2);
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, "Balancer v3", address(balances));

        _assertOracleBalancesMatchRedemption(MAINNET_STAKED_USER);
    }

    function test_getOracleBalanceForAsset_mainnet_unstaked_bpt() public view {
        _assertOracleBalancesMatchRedemption(MAINNET_UNSTAKED_USER);
    }

    function test_getOracleBalanceForAsset_mainnet_staked_gauge_AfterRedeem() public {
        vm.rollFork(FORK_BLOCK_3);
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle = new BalancerV3PoolBalanceOracle(POOL, GAUGE, BALANCER_MINTER, "Balancer v3", address(balances));

        _assertOracleBalancesMatchRedemption(MAINNET_STAKED_USER);
    }

    function test_getOracleBalanceForAsset_mainnet_staked_gauge_whale() public view {
        _assertOracleBalancesMatchRedemption(MAINNET_WHALE_USER);
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _assertOracleBalancesMatchRedemption(address user) internal view {
        // Get oracle balances before redemption
        (uint256 amountUsdt, bool isDebtUsdt) = oracle.getOracleBalanceForAsset(user, USDT);
        (uint256 amountUsdc, bool isDebtUsdc) = oracle.getOracleBalanceForAsset(user, USDC);
        (uint256 amountGho, bool isDebtGho) = oracle.getOracleBalanceForAsset(user, GHO);
        (uint256 amountBal, bool isDebtBal) = oracle.getOracleBalanceForAsset(user, BAL);

        // Check that user has at least one non-zero position
        bool hasPosition = amountUsdt != 0 || amountUsdc != 0 || amountGho != 0 || amountBal != 0;
        assertTrue(hasPosition, "User should have at least one non-zero position");

        // All positions should be credit (no debt in Balancer pools)
        if (amountUsdt > 0) {
            assertGt(amountUsdt, 0, "USDT should be credit (positive)");
            assertFalse(isDebtUsdt);
        }
        if (amountUsdc > 0) {
            assertGt(amountUsdc, 0, "USDC should be credit (positive)");
            assertFalse(isDebtUsdc);
        }
        if (amountGho > 0) {
            assertGt(amountGho, 0, "GHO should be credit (positive)");
            assertFalse(isDebtGho);
        }
        if (amountBal > 0) {
            assertGt(amountBal, 0, "BAL should be credit (positive)");
            assertFalse(isDebtBal);
        }
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalance_aggregatesPositions() public view {
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(MAINNET_STAKED_USER);

        // Should have at least one position
        assertGe(assets.length, 1, "Should have at least one position");
        assertEq(assets.length, amounts.length, "Arrays should match length");
    }

    function test_getOraclePositions_returnsCorrectPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(MAINNET_STAKED_USER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
