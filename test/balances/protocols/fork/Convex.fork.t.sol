// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {ConvexBalanceOracle} from "src/balances/protocols/Convex.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title ConvexBalanceOracle fork tests — crvUSD/USDT Pool
/// @notice Tests using real Convex contracts on Ethereum mainnet (crvUSD/USDT pool, pid 266)
contract ConvexBalanceOracleForkTest_crvUSD_USDT is BalanceAdapterTestBase {
    // Convex BaseRewardPool for crvUSD/USDT (pid 266)
    address public constant REWARDER = 0xD1DdB0a0815fD28932fBb194C84003683AF8a824;

    // Underlying Curve LP token (crvUSD/USDT pool)
    address public constant LP_TOKEN = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    // Pool tokens
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant crvUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Reward tokens
    address public constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    // Fork block matching source oracle tests
    uint256 public constant FORK_BLOCK = 23_585_062;

    // karpatkey Safe with known Convex position at fork block
    address public constant SAFE = 0xC01318baB7ee1f5ba734172bF7718b5DC6Ec90E1;

    // Expected values from source oracle test at the same block
    uint256 public constant EXPECTED_USDT = 3_389_288;
    uint256 public constant EXPECTED_crvUSD = 7_660_319_668_213_973_665;
    uint256 public constant EXPECTED_CRV = 63_768_314_561_276_595;
    uint256 public constant EXPECTED_CVX = 63_768_314_561_276;
    uint256 public constant REWARD_TOLERANCE = 1e13;

    ConvexBalanceOracle public oracle;
    address internal unknownAccount;

    function setUp() public override {
        super.setUp();
        _setupFork();
        unknownAccount = makeAddr("unknownAccount");
        _setupOracle();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupOracle() internal {
        // Register pool tokens + rewards for getOraclePositions tests
        address[] memory assets = new address[](4);
        assets[0] = USDT;
        assets[1] = crvUSD;
        assets[2] = CRV;
        assets[3] = CVX;
        balances = _deployBalancesForOracle(assets);
        // LP_TOKEN must be provided explicitly — rewarder.stakingToken() returns the cvxLP wrapper, not the Curve LP
        oracle = new ConvexBalanceOracle(REWARDER, LP_TOKEN, "Convex", "crvUSD/USDT Pool", address(balances));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_lpTokenAddress() public view {
        assertEq(oracle.LP_TOKEN(), LP_TOKEN, "LP_TOKEN should match the provided Curve LP address");
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        // USDT, crvUSD (pool) + CRV, CVX (rewards) = 4
        assertEq(assets.length, 4);
        assertEq(assets[0], USDT);
        assertEq(assets[1], crvUSD);
        assertEq(assets[2], CRV);
        assertEq(assets[3], CVX);
    }

    // ============================================
    // Real Position Tests — Pool Tokens
    // ============================================

    function test_getOracleBalanceForAsset_usdt() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE, USDT);
        assertEq(amount, EXPECTED_USDT, "USDT balance should match source oracle test");
    }

    function test_getOracleBalanceForAsset_crvUsd() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE, crvUSD);
        assertEq(amount, EXPECTED_crvUSD, "crvUSD balance should match source oracle test");
    }

    // ============================================
    // Real Position Tests — Rewards
    // ============================================

    function test_getOracleBalanceForAsset_crv() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE, CRV);
        assertApproxEqAbs(amount, EXPECTED_CRV, REWARD_TOLERANCE, "CRV earned should match source oracle test");
    }

    function test_getOracleBalanceForAsset_cvx() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE, CVX);
        assertApproxEqAbs(amount, EXPECTED_CVX, REWARD_TOLERANCE, "CVX derived should match source oracle test");
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE, address(0xdead));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(unknownAccount, USDT);
        assertEq(amount, 0);
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalances_safe() public view {
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(SAFE);
        // Should have 4 positions (USDT, crvUSD, CRV, CVX — all non-zero)
        assertEq(assets.length, 4, "Should have 4 non-zero positions");

        assertEq(assets[0], USDT);
        assertEq(amounts[0], EXPECTED_USDT);

        assertEq(assets[1], crvUSD);
        assertEq(amounts[1], EXPECTED_crvUSD);

        assertEq(assets[2], CRV);
        assertApproxEqAbs(amounts[2], EXPECTED_CRV, REWARD_TOLERANCE);

        assertEq(assets[3], CVX);
        assertApproxEqAbs(amounts[3], EXPECTED_CVX, REWARD_TOLERANCE);
    }

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(unknownAccount);
        assertEq(assets.length, 0);
    }

    function test_getOraclePositions_safe() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, address(0));
        // All 4 assets registered → 4 positions
        assertEq(positions.length, 4, "Should have 4 registered positions");

        for (uint256 i = 0; i < positions.length; i++) {
            assertGt(positions[i].amount, 0);
            assertFalse(positions[i].isDebt);
            assertEq(positions[i].protocol, "Convex");
            assertEq(positions[i].positionDetail, "crvUSD/USDT Pool");
        }
    }

    function test_getOraclePositions_withAssetFilter() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, USDT);
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, USDT);
        assertEq(positions[0].amount, EXPECTED_USDT);

        INAVCalculator.PositionBalance[] memory empty = oracle.getOraclePositions(SAFE, address(0xdead));
        assertEq(empty.length, 0);
    }
}
