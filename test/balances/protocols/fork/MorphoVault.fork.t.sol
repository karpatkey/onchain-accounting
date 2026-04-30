// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {MorphoVaultBalanceOracle} from "src/balances/protocols/morpho/MorphoVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title MorphoVaultBalanceOracle fork tests — kpkUSDC V1 vault
/// @notice Tests using the real kpkUSDC V1 Morpho vault on Ethereum mainnet
contract MorphoVaultBalanceOracleForkTest_V1 is BalanceAdapterTestBase {
    // kpkUSDC V1 vault and underlying asset
    IERC4626 public constant VAULT = IERC4626(0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Fork block where SAFE holds a known V1 position
    uint256 public constant FORK_BLOCK = 23_641_970;

    // karpatkey Safe with a V1 vault position at the fork block
    address public constant SAFE = 0x17bC2E773d4b4e32002eDAaa54Ce756F523b44b7;

    MorphoVaultBalanceOracle public oracle;

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
        balances = _deployBalancesForOracle(address(USDC));
        oracle = new MorphoVaultBalanceOracle(address(VAULT), "Morpho", "kpkUSDC V1 Vault", address(balances));
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    // ============================================
    // underlyingAssetsSupported Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDC));
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getOracleBalanceForAsset_safe_v1() public {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(SAFE, address(USDC));

        // Verify against actual redemption: prank SAFE and redeem all shares
        uint256 shares = VAULT.balanceOf(SAFE);
        assertGt(shares, 0, "SAFE should hold V1 shares at fork block");

        uint256 usdcBefore = USDC.balanceOf(SAFE);
        vm.prank(SAFE);
        VAULT.redeem(shares, SAFE, SAFE);
        uint256 redeemed = USDC.balanceOf(SAFE) - usdcBefore;

        assertEq(amount, redeemed, "Oracle balance should match actual redeemable amount");
        assertFalse(isDebt, "Vault position is always credit");
    }

    function test_getOracleBalanceForAsset_unknownAccount() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0xdead), address(USDC));
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(SAFE, address(0xdead));
        assertEq(amount, 0);
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getOracleBalances() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(SAFE);

        assertEq(assets.length, 1, "Should have one position");
        assertEq(assets[0], address(USDC));
        assertGt(amounts[0], 0, "Balance should be positive");
        assertFalse(isDebt[0]);
        assertEq(assets.length, amounts.length);
        assertEq(assets.length, isDebt.length);
    }

    function test_getOraclePositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, address(0));

        assertEq(positions.length, 1, "Should have one position");
        assertEq(positions[0].underlyingAsset.asset, address(USDC));
        assertGt(positions[0].amount, 0, "Position amount should be positive");
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Morpho");
        assertEq(positions[0].positionDetail, "kpkUSDC V1 Vault");
    }

    function test_getOraclePositions_withAssetFilter() public view {
        // Filter by USDC — should return the position
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, address(USDC));
        assertEq(positions.length, 1);
        assertGt(positions[0].amount, 0);

        // Filter by unrelated asset — should return empty
        INAVCalculator.PositionBalance[] memory empty = oracle.getOraclePositions(SAFE, address(0xdead));
        assertEq(empty.length, 0);
    }

    function test_getOracleBalances_unknownAccount() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(address(0xdead));
        assertEq(assets.length, 0);
    }
}

/// @title MorphoVaultBalanceOracle fork tests — kpkUSDC V2 vault
/// @notice Tests using the real kpkUSDC V2 Morpho vault on Ethereum mainnet
contract MorphoVaultBalanceOracleForkTest_V2 is BalanceAdapterTestBase {
    // kpkUSDC V2 vault and underlying asset
    IERC4626 public constant VAULT = IERC4626(0x4Ef53d2cAa51C447fdFEEedee8F07FD1962C9ee6);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Fork block where SAFE holds a known V2 position
    uint256 public constant FORK_BLOCK = 23_741_965;

    // karpatkey Safe with a V2 vault position at the fork block
    address public constant SAFE = 0x17bC2E773d4b4e32002eDAaa54Ce756F523b44b7;

    MorphoVaultBalanceOracle public oracle;

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
        balances = _deployBalancesForOracle(address(USDC));
        oracle = new MorphoVaultBalanceOracle(address(VAULT), "Morpho", "kpkUSDC V2 Vault", address(balances));
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getOracleBalanceForAsset_safe_v2() public {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(SAFE, address(USDC));

        uint256 shares = VAULT.balanceOf(SAFE);
        assertGt(shares, 0, "SAFE should hold V2 shares at fork block");

        uint256 usdcBefore = USDC.balanceOf(SAFE);
        vm.prank(SAFE);
        VAULT.redeem(shares, SAFE, SAFE);
        uint256 redeemed = USDC.balanceOf(SAFE) - usdcBefore;

        assertEq(amount, redeemed, "Oracle balance should match actual redeemable amount");
        assertFalse(isDebt);
    }

    function test_getOraclePositions() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(SAFE, address(0));

        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, address(USDC));
        assertGt(positions[0].amount, 0);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Morpho");
        assertEq(positions[0].positionDetail, "kpkUSDC V2 Vault");
    }
}
