// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterForkTestBase} from "test/balances/protocols/fork/BalanceAdapterForkTestBase.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {Id} from "morpho-blue/src/interfaces/IMorpho.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title MorphoMarketBalanceOracleForkTest
/// @notice Fork tests for MorphoMarketBalanceOracle using real mainnet contracts
/// @dev Tests adapter behavior with real Morpho protocol contracts and positions
contract MorphoMarketBalanceOracleForkTest is BalanceAdapterForkTestBase {
    // Morpho contract addresses (mainnet)
    address public constant MORPHO_MAINNET = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    
    // Market IDs (morpho-blue Id type)
    Id public constant MARKET_ID_WSTETH_USDC = Id.wrap(0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc);
    Id public constant MARKET_ID_USDC_DAI_MKR = Id.wrap(0x97bb820669a19ba5fa6de964a466292edd67957849f9631eb8b830c382f58b7f);
    
    // Token addresses
    address public constant USDC = MAINNET_USDC;
    address public constant DAI = MAINNET_DAI;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant MKR = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
    
    // Fork blocks
    uint256 public constant FORK_BLOCK_WSTETH_USDC = 20_361_884;
    uint256 public constant FORK_BLOCK_USDC_DAI_MKR = 20_728_491;
    
    // Oracle instance
    MorphoMarketBalanceOracle public oracle;
    
    // Real user addresses with positions in Morpho
    address public constant SUPPLY_USDC_USER = 0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B;
    address public constant BORROW_USDC_USER = 0x06bF1e959eDad7e1F7003a9Fa122233F1Bd22f34;

    // --- kpkUSDC Morpho vault (ERC4626) ---
    /// @notice kpkUSDC v1 Morpho vault address
    address public constant VAULT_V1 = 0xe108fbc04852B5df72f9E44d7C29F47e7A993aDd;
    /// @notice kpkUSDC v2 Morpho vault address
    address public constant VAULT_V2 = 0x4Ef53d2cAa51C447fdFEEedee8F07FD1962C9ee6;
    /// @notice USDC token address (vault's underlying asset)
    address public constant VAULT_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @notice Test user safe address
    address public constant SAFE = 0x17bC2E773d4b4e32002eDAaa54Ce756F523b44b7;
    /// @notice Test block number for v1
    uint256 public constant TEST_BLOCK_V1 = 23_641_970;
    /// @notice Test block number for v2
    uint256 public constant TEST_BLOCK_V2 = 23_741_965;
    /// @notice Expected v1 vault shares for the safe (shares are fixed per account at a block)
    uint256 public constant EXPECTED_SHARES_V1 = 2_982_110_271_240_305_431_905_256;
    /// @notice Expected v2 vault shares for the safe
    uint256 public constant EXPECTED_SHARES_V2 = 9_995_002_548_700_162_916_912;
    /// @notice Minimum v1 underlying USDC balance (value accrues per block; we only assert a floor)
    uint256 public constant MIN_BALANCE_V1 = 2_500_000_000_000; // ~2.5M USDC (6 decimals)
    /// @notice Minimum v2 underlying USDC balance (value accrues per block; we only assert a floor)
    uint256 public constant MIN_BALANCE_V2 = 9_000_000_000; // ~9k USDC (6 decimals)

    function setUp() public override {
        super.setUp();
    }
    
    // ============================================
    // Real Position Tests - wstETH/USDC Market
    // ============================================
    
    function test_getOracleBalanceForAsset_supply_usdc() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_WSTETH_USDC);
        
        address[] memory assets = new address[](2);
        assets[0] = WSTETH;
        assets[1] = USDC;
        balances = _deployBalancesForOracle(assets);
        
        oracle = new MorphoMarketBalanceOracle(
            MORPHO_MAINNET,
            Id.unwrap(MARKET_ID_WSTETH_USDC),
            "Morpho - wstETH/USDC",
            address(balances)
        );

        int256 balance = oracle.getOracleBalanceForAsset(SUPPLY_USDC_USER, USDC);
        assertGt(balance, 0, "User should have USDC supply position");
    }
    
    // ============================================
    // Real Position Tests - USDC/DAI/MKR Market
    // ============================================
    
    function test_getOracleBalanceForAsset_borrow_usdc() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_USDC_DAI_MKR);
        
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = DAI;
        assets[2] = MKR;
        balances = _deployBalancesForOracle(assets);
        
        oracle = new MorphoMarketBalanceOracle(
            MORPHO_MAINNET,
            Id.unwrap(MARKET_ID_USDC_DAI_MKR),
            "Morpho - USDC/DAI/MKR",
            address(balances)
        );

        int256 balanceUsdc = oracle.getOracleBalanceForAsset(BORROW_USDC_USER, USDC);
        assertLt(balanceUsdc, 0, "User should have USDC borrow position (negative balance)");
    }
    
    function test_getOracleBalanceForAsset_collateral_mkr() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_USDC_DAI_MKR);
        
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = DAI;
        assets[2] = MKR;
        balances = _deployBalancesForOracle(assets);
        
        oracle = new MorphoMarketBalanceOracle(
            MORPHO_MAINNET,
            Id.unwrap(MARKET_ID_USDC_DAI_MKR),
            "Morpho - USDC/DAI/MKR",
            address(balances)
        );

        int256 balanceMkr = oracle.getOracleBalanceForAsset(BORROW_USDC_USER, MKR);
        assertGt(balanceMkr, 0, "User should have MKR collateral position");
    }
    
    // ============================================
    // Supported Assets Tests
    // ============================================
    
    function test_underlyingAssetsSupported() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_WSTETH_USDC);
        
        address[] memory assetsToRegister = new address[](2);
        assetsToRegister[0] = WSTETH;
        assetsToRegister[1] = USDC;
        balances = _deployBalancesForOracle(assetsToRegister);
        
        oracle = new MorphoMarketBalanceOracle(
            MORPHO_MAINNET,
            Id.unwrap(MARKET_ID_WSTETH_USDC),
            "Morpho - wstETH/USDC",
            address(balances)
        );

        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 2);
        assertEq(assets[0], WSTETH);
        assertEq(assets[1], USDC);
    }
    
    // ============================================
    // Market Configuration Tests
    // ============================================
    
    function test_collateralAndLoanTokens() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_WSTETH_USDC);
        
        address[] memory assetsToRegister = new address[](2);
        assetsToRegister[0] = WSTETH;
        assetsToRegister[1] = USDC;
        balances = _deployBalancesForOracle(assetsToRegister);
        
        oracle = new MorphoMarketBalanceOracle(
            MORPHO_MAINNET,
            Id.unwrap(MARKET_ID_WSTETH_USDC),
            "Morpho - wstETH/USDC",
            address(balances)
        );

        assertEq(oracle.COLLATERAL_TOKEN(), WSTETH);
        assertEq(oracle.LOAN_TOKEN(), USDC);
    }
    
    // ============================================
    // Position Aggregation Tests
    // ============================================
    
    function test_getOracleBalance_aggregatesPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_USDC_DAI_MKR);
        
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = DAI;
        assets[2] = MKR;
        balances = _deployBalancesForOracle(assets);
        
        oracle = new MorphoMarketBalanceOracle(
            MORPHO_MAINNET,
            Id.unwrap(MARKET_ID_USDC_DAI_MKR),
            "Morpho - USDC/DAI/MKR",
            address(balances)
        );

        (address[] memory resultAssets, int256[] memory balances) = 
            oracle.getOracleBalance(BORROW_USDC_USER);
        
        // Should have at least USDC and MKR positions
        assertGe(resultAssets.length, 2, "Should have multiple positions");
        assertEq(resultAssets.length, balances.length, "Arrays should match length");
    }
    
    function test_getOraclePositions_returnsCorrectPositions() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK_WSTETH_USDC);
        
        address[] memory assets = new address[](2);
        assets[0] = WSTETH;
        assets[1] = USDC;
        balances = _deployBalancesForOracle(assets);
        
        oracle = new MorphoMarketBalanceOracle(
            MORPHO_MAINNET,
            Id.unwrap(MARKET_ID_WSTETH_USDC),
            "Morpho - wstETH/USDC",
            address(balances)
        );

        INAVCalculator.PositionBalance[] memory positions = 
            oracle.getOraclePositions(SUPPLY_USDC_USER, address(0));
        
        assertGe(positions.length, 1, "Should have at least one position");
        
        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }

    // ============================================
    // kpkUSDC Morpho Vault (ERC4626) Fork Tests
    // ============================================

    function test_kpkUSDC_v1_vault_sharesAndBalance() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), TEST_BLOCK_V1);
        IERC4626 vault = IERC4626(VAULT_V1);
        assertEq(vault.asset(), VAULT_USDC, "v1 vault asset should be USDC");

        uint256 shares = vault.balanceOf(SAFE);
        assertEq(shares, EXPECTED_SHARES_V1, "v1 vault shares for SAFE");

        uint256 assets = vault.convertToAssets(shares);
        assertGe(assets, MIN_BALANCE_V1, "v1 vault underlying USDC for SAFE (accrues per block)");
    }

    function test_kpkUSDC_v2_vault_sharesAndBalance() public {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), TEST_BLOCK_V2);
        IERC4626 vault = IERC4626(VAULT_V2);
        assertEq(vault.asset(), VAULT_USDC, "v2 vault asset should be USDC");

        uint256 shares = vault.balanceOf(SAFE);
        assertEq(shares, EXPECTED_SHARES_V2, "v2 vault shares for SAFE");

        uint256 assets = vault.convertToAssets(shares);
        assertGe(assets, MIN_BALANCE_V2, "v2 vault underlying USDC for SAFE (accrues per block)");
    }
}
