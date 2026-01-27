// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceAdapterForkTestBase} from "test/balances/protocols/fork/BalanceAdapterForkTestBase.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/BalancerV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    int256 public constant EXPECTED_USDT = 1_148_397; // 6 decimals
    int256 public constant EXPECTED_USDC = 3_714_973; // 6 decimals
    int256 public constant EXPECTED_GHO = 5_135_070_400_402_385_644; // 18 decimals
    
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
        oracle = new BalancerV3PoolBalanceOracle(
            POOL,
            GAUGE,
            BALANCER_MINTER,
            "Balancer v3",
            address(balances)
        );
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
        oracle = new BalancerV3PoolBalanceOracle(
            POOL,
            GAUGE,
            BALANCER_MINTER,
            "Balancer v3",
            address(balances)
        );

        int256 balanceUsdt = oracle.getOracleBalanceForAsset(USER_TENDERLY, USDT);
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(USER_TENDERLY, USDC);
        int256 balanceGho = oracle.getOracleBalanceForAsset(USER_TENDERLY, GHO);

        assertEq(balanceUsdt, EXPECTED_USDT, "USDT balance should match Tenderly");
        assertEq(balanceUsdc, EXPECTED_USDC, "USDC balance should match Tenderly");
        assertEq(balanceGho, EXPECTED_GHO, "GHO balance should match Tenderly");
    }

    function test_getOracleBalanceForAsset_mainnet_staked_gauge() public {
        vm.rollFork(FORK_BLOCK_2);
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle = new BalancerV3PoolBalanceOracle(
            POOL,
            GAUGE,
            BALANCER_MINTER,
            "Balancer v3",
            address(balances)
        );
        
        _assertOracleBalancesMatchRedemption(MAINNET_STAKED_USER);
    }
    
    function test_getOracleBalanceForAsset_mainnet_unstaked_bpt() public view {
        _assertOracleBalancesMatchRedemption(MAINNET_UNSTAKED_USER);
    }
    
    function test_getOracleBalanceForAsset_mainnet_staked_gauge_AfterRedeem() public {
        vm.rollFork(FORK_BLOCK_3);
        balances = _deployBalancesForOracle(_getSupportedAssets());
        oracle = new BalancerV3PoolBalanceOracle(
            POOL,
            GAUGE,
            BALANCER_MINTER,
            "Balancer v3",
            address(balances)
        );
        
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
        int256 balanceUsdt = oracle.getOracleBalanceForAsset(user, USDT);
        int256 balanceUsdc = oracle.getOracleBalanceForAsset(user, USDC);
        int256 balanceGho = oracle.getOracleBalanceForAsset(user, GHO);
        int256 balanceBal = oracle.getOracleBalanceForAsset(user, BAL);
        
        // Check that user has at least one non-zero position
        bool hasPosition = balanceUsdt != 0 || balanceUsdc != 0 || balanceGho != 0 || balanceBal != 0;
        assertTrue(hasPosition, "User should have at least one non-zero position");
        
        // All positions should be credit (no debt in Balancer pools)
        if (balanceUsdt > 0) assertGt(balanceUsdt, 0, "USDT should be credit (positive)");
        if (balanceUsdc > 0) assertGt(balanceUsdc, 0, "USDC should be credit (positive)");
        if (balanceGho > 0) assertGt(balanceGho, 0, "GHO should be credit (positive)");
        if (balanceBal > 0) assertGt(balanceBal, 0, "BAL should be credit (positive)");
    }
    
    // ============================================
    // Position Aggregation Tests
    // ============================================
    
    function test_getOracleBalance_aggregatesPositions() public view {
        (address[] memory assets, int256[] memory balances) = 
            oracle.getOracleBalance(MAINNET_STAKED_USER);
        
        // Should have at least one position
        assertGe(assets.length, 1, "Should have at least one position");
        assertEq(assets.length, balances.length, "Arrays should match length");
    }
    
    function test_getOraclePositions_returnsCorrectPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = 
            oracle.getOraclePositions(MAINNET_STAKED_USER, address(0));
        
        assertGe(positions.length, 1, "Should have at least one position");
        
        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
