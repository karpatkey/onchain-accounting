// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {FluidVaultBalanceOracle, IFluidVaultT1} from "src/balances/protocols/FluidVault.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title FluidVaultBalanceOracle fork tests — wstETH/USDC vault (Mainnet)
/// @notice Drives the adapter against a real Fluid T1 vault on Mainnet. We don't open a position
///         on-chain (that would require simulating the vault's `operate` call which is non-trivial)
///         — instead we assert the constructor decodes the vault correctly via the real resolver,
///         the adapter returns zero for accounts with no positions, and that asset filtering /
///         registry intersection behave as expected against the live registry.
contract FluidVaultBalanceOracleForkTest_wstETH_USDC is BalanceAdapterTestBase {
    // Canonical Fluid Mainnet addresses (see Fluid docs/deployments).
    address public constant VAULT_WSTETH_USDC = 0x51197586F6A9e2571868b6ffaef308f3bdfEd3aE;
    address public constant VAULT_RESOLVER = 0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC;

    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // A recent Mainnet block where the general VaultResolver
    // (0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC, deployed between blocks ~23.8M and ~23.9M)
    // is live alongside the wstETH/USDC T1 vault.
    uint256 public constant FORK_BLOCK = 23_950_000;

    FluidVaultBalanceOracle public oracle;

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
        // Register both legs of the vault in the test balance harness so getOraclePositions can
        // emit positions for either side.
        address[] memory assets = new address[](2);
        assets[0] = WSTETH;
        assets[1] = MAINNET_USDC;
        balances = _deployBalancesForOracle(assets);

        oracle = new FluidVaultBalanceOracle(
            VAULT_WSTETH_USDC, VAULT_RESOLVER, "Fluid Vault", "{\"protocol\":\"Fluid\",\"product\":\"Vault\"", "0x0000000000000000000000000000000000000001", address(balances)
        );
    }

    // ============================================
    // Constructor decodes vault constants correctly
    // ============================================

    function test_constructor_resolvesCollateralAndDebtTokens() public view {
        assertEq(oracle.COLLATERAL_TOKEN(), WSTETH, "collateral should be wstETH");
        assertEq(oracle.DEBT_TOKEN(), MAINNET_USDC, "debt should be USDC");
    }

    function test_constructor_storesImmutables() public view {
        assertEq(oracle.VAULT(), VAULT_WSTETH_USDC);
        assertEq(address(oracle.VAULT_RESOLVER()), VAULT_RESOLVER);
        assertEq(address(oracle.NAV_CALCULATOR()), address(balances));
    }

    // ============================================
    // Interface Compliance
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], WSTETH);
        assertEq(assets[1], MAINNET_USDC);
    }

    // ============================================
    // Zero-position behaviour
    // ============================================

    function test_getOracleBalanceForAsset_addressWithNoPosition() public view {
        address freshAccount = address(0xBEEF);
        (uint256 amountCol, bool isDebtCol) = oracle.getOracleBalanceForAsset(freshAccount, WSTETH);
        (uint256 amountDbt, bool isDebtDbt) = oracle.getOracleBalanceForAsset(freshAccount, MAINNET_USDC);
        assertEq(amountCol, 0);
        assertFalse(isDebtCol);
        assertEq(amountDbt, 0);
        assertTrue(isDebtDbt); // requested debt asset, returned 0 with debt flag set
    }

    function test_getOracleBalances_addressWithNoPosition() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(address(0xBEEF));
        // Empty: we filter out zero-amount entries
        assertEq(assets.length, 0);
    }

    function test_getOraclePositions_addressWithNoPosition() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0xBEEF), address(0));
        assertEq(positions.length, 0);
    }

    // ============================================
    // Resolver integration
    // ============================================

    function test_vault_constantsViewIsT1() public view {
        // Verify directly against the vault — same source the adapter constructor consults.
        IFluidVaultT1.ConstantViews memory cv = IFluidVaultT1(VAULT_WSTETH_USDC).constantsView();
        assertEq(cv.supplyToken, WSTETH);
        assertEq(cv.borrowToken, MAINNET_USDC);
        assertEq(cv.supplyDecimals, 18);
        assertEq(cv.borrowDecimals, 6);
    }

    function test_assetFilter_isolatesLegs() public view {
        // Filter to wstETH alone — empty when no position
        INAVCalculator.PositionBalance[] memory col = oracle.getOraclePositions(address(0xBEEF), WSTETH);
        assertEq(col.length, 0);

        // Filter to USDC alone — empty when no position
        INAVCalculator.PositionBalance[] memory dbt = oracle.getOraclePositions(address(0xBEEF), MAINNET_USDC);
        assertEq(dbt.length, 0);
    }
}
