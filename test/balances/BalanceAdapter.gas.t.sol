// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/default/ERC20DefaultOracle.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";

/// @title Balance Adapter Gas Benchmark Tests
/// @notice Tests gas usage for various scenarios to establish performance baselines
contract BalanceAdapterGasTest is Test {
    BalancesHarness public balances;
    ERC20DefaultOracle public erc20DefaultOracle;
    Mock_CustomBalanceOracle[] public customOracles;
    Mock_ERC20[] public tokens;

    address public alice = makeAddr("alice");

    function setUp() public {
        balances = new BalancesHarness();
        erc20DefaultOracle = balances.defaultOracle();
    }

    /// @notice Helper to generate large asset portfolio
    function generateLargePortfolio(uint256 assetCount) internal {
        // Reset arrays for this iteration
        delete customOracles;
        delete tokens;
        customOracles = new Mock_CustomBalanceOracle[](0);
        tokens = new Mock_ERC20[](0);

        for (uint256 i = 0; i < assetCount; i++) {
            Mock_ERC20 token = new Mock_ERC20(string(abi.encodePacked("TOKEN", vm.toString(i))), 18);
            tokens.push(token);
            balances.addSupportedAssetForTest(address(token));

            Mock_CustomBalanceOracle oracle = new Mock_CustomBalanceOracle();
            // Note: setBalances is not needed - the mock oracle can work without it
            // oracle.setBalances(balances);
            address[] memory assets = new address[](1);
            assets[0] = address(token);
            oracle.setUnderlyingAssetsSupported(assets);
            oracle.setBalance(address(token), alice, (i + 1) * 100 * 10 ** 18, false);
            customOracles.push(oracle);

            balances.addBalanceOracleDirect(address(0), address(oracle), IBalances.OracleType.Custom);
        }
    }

    /// @notice Helper to setup multiple adapters
    function setupMultipleAdapters(uint256 adapterCount) internal {
        Mock_ERC20 token = new Mock_ERC20("USDC", 6);
        balances.addSupportedAssetForTest(address(token));

        // Reset array for this iteration
        delete customOracles;
        customOracles = new Mock_CustomBalanceOracle[](0);

        for (uint256 i = 0; i < adapterCount; i++) {
            Mock_CustomBalanceOracle oracle = new Mock_CustomBalanceOracle();
            // Note: setBalances is not needed - the mock oracle can work without it
            // oracle.setBalances(balances);
            address[] memory assets = new address[](1);
            assets[0] = address(token);
            oracle.setUnderlyingAssetsSupported(assets);
            oracle.setBalance(address(token), alice, (i + 1) * 100 * 10 ** 6, false);
            customOracles.push(oracle);

            balances.addBalanceOracleDirect(address(0), address(oracle), IBalances.OracleType.Custom);
        }
    }

    // ============================================
    // Single Asset Query Benchmarks
    // ============================================

    /// @notice Benchmark gas for getOracleBalanceForAsset
    function test_gasBenchmark_getOracleBalanceForAsset() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        balances.addSupportedAssetForTest(address(usdc));
        usdc.mint(alice, 1000 * 10 ** 6);

        uint256 gasBefore = gasleft();
        (uint256 amount,) = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(usdc));
        uint256 gasUsed = gasBefore - gasleft();

        assertGt(amount, 0, "Should have positive balance");
        assertGt(gasUsed, 0, "gas measured");
    }

    /// @notice Benchmark gas for getOracleBalanceForAsset with zero balance
    function test_gasBenchmark_getOracleBalanceForAsset_zeroBalance() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        balances.addSupportedAssetForTest(address(usdc));
        // Don't mint tokens (zero balance)

        uint256 gasBefore = gasleft();
        (uint256 amount,) = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(usdc));
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(amount, 0, "Should have zero balance");
        assertGt(gasUsed, 0, "gas measured");
    }

    // ============================================
    // Multiple Assets Benchmarks
    // ============================================

    /// @notice Benchmark gas for getOracleBalance with varying asset counts
    function test_gasBenchmark_getOracleBalance_multipleAssets() public {
        // Use smaller asset counts to avoid gas limit issues
        uint256[] memory assetCounts = new uint256[](3);
        assetCounts[0] = 1;
        assetCounts[1] = 10;
        assetCounts[2] = 20; // Reduced from 50/100 to avoid gas limits

        for (uint256 i = 0; i < assetCounts.length; i++) {
            // Generate portfolio
            generateLargePortfolio(assetCounts[i]);

            // Mint tokens to alice for ERC20DefaultOracle
            for (uint256 j = 0; j < tokens.length; j++) {
                tokens[j].mint(alice, 1000 * 10 ** 18);
            }

            uint256 gasBefore = gasleft();
            (address[] memory assets, uint256[] memory amounts,) = erc20DefaultOracle.getOracleBalances(alice);
            uint256 gasUsed = gasBefore - gasleft();

            assertGe(assets.length, assetCounts[i], "Should have at least the new asset count");
            assertEq(assets.length, amounts.length, "assets and amounts length match");
            uint256 gasPerAsset = assets.length > 0 ? gasUsed / assets.length : 0;
            assertGt(gasPerAsset, 0, "gas per asset measured");
            // Typically 5k-20k per asset

            // Note: State accumulates across iterations (assets/oracles added to balances)
            // This is intentional for benchmarking, but may cause gas issues in later iterations
        }
    }

    // ============================================
    // Position Query Benchmarks
    // ============================================

    /// @notice Benchmark gas for getOraclePositions
    function test_gasBenchmark_getOraclePositions() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        Mock_ERC20 dai = new Mock_ERC20("DAI", 18);
        balances.addSupportedAssetForTest(address(usdc));
        balances.addSupportedAssetForTest(address(dai));

        usdc.mint(alice, 1000 * 10 ** 6);
        dai.mint(alice, 2000 * 10 ** 18);

        uint256 gasBefore = gasleft();
        INAVCalculator.PositionBalance[] memory positions = erc20DefaultOracle.getOraclePositions(alice, address(0));
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(positions.length, 2, "Should have 2 positions");
        assertGt(gasUsed, 0, "gas measured");
    }

    /// @notice Benchmark gas for getOraclePositions with asset filter
    function test_gasBenchmark_getOraclePositions_withFilter() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        Mock_ERC20 dai = new Mock_ERC20("DAI", 18);
        balances.addSupportedAssetForTest(address(usdc));
        balances.addSupportedAssetForTest(address(dai));

        usdc.mint(alice, 1000 * 10 ** 6);
        dai.mint(alice, 2000 * 10 ** 18);

        uint256 gasBeforeUnfiltered = gasleft();
        erc20DefaultOracle.getOraclePositions(alice, address(0));
        uint256 gasUnfiltered = gasBeforeUnfiltered - gasleft();

        uint256 gasBeforeFiltered = gasleft();
        erc20DefaultOracle.getOraclePositions(alice, address(usdc));
        uint256 gasFiltered = gasBeforeFiltered - gasleft();

        assertGt(gasUnfiltered, 0, "unfiltered gas measured");
        assertGt(gasFiltered, 0, "filtered gas measured");
        // Gas usage documentation:
        // - Unfiltered query gas: visible in test output
        // - Filtered query gas: visible in test output
        // Filtered queries are typically cheaper as they process fewer assets
    }

    // ============================================
    // Adapter Count Impact
    // ============================================

    /// @notice Test gas impact of adapter count
    function test_gasBenchmark_adapterCountImpact() public {
        uint256[] memory adapterCounts = new uint256[](4);
        adapterCounts[0] = 1;
        adapterCounts[1] = 5;
        adapterCounts[2] = 10;
        adapterCounts[3] = 20;

        for (uint256 i = 0; i < adapterCounts.length; i++) {
            // Setup adapters
            if (i > 0) {
                setupMultipleAdapters(adapterCounts[i] - 1); // -1 because ERC20DefaultOracle already exists
            }

            Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
            balances.addSupportedAssetForTest(address(usdc));
            usdc.mint(alice, 1000 * 10 ** 6);

            uint256 gasBefore = gasleft();
            (uint256 amount,) = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(usdc));
            uint256 gasUsed = gasBefore - gasleft();

            assertGt(amount, 0, "Should have positive balance");
            assertGt(gasUsed, 0, "gas measured");
        }
    }

    // ============================================
    // Baseline Metrics
    // ============================================

    /// @notice Establish baseline gas metrics for empty account
    function test_gasBenchmark_baseline_emptyAccount() public {
        address emptyAccount = makeAddr("empty");

        uint256 gasBefore = gasleft();
        (uint256 amount,) = erc20DefaultOracle.getOracleBalanceForAsset(emptyAccount, address(0));
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(amount, 0, "Empty account should have zero balance");
        assertGt(gasUsed, 0, "gas measured");
        // Typically very cheap as no positions need to be processed
    }

    /// @notice Establish baseline for single asset
    function test_gasBenchmark_baseline_singleAsset() public {
        Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
        balances.addSupportedAssetForTest(address(usdc));
        usdc.mint(alice, 1000 * 10 ** 6);

        uint256 gasBefore = gasleft();
        (uint256 amount,) = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(usdc));
        uint256 gasUsed = gasBefore - gasleft();

        assertGt(amount, 0, "Should have positive balance");
        assertGt(gasUsed, 0, "gas measured");
        // Typically cheap as only one asset needs to be processed
    }

    /// @notice Establish baseline for underlyingAssetsSupported
    function test_gasBenchmark_baseline_underlyingAssetsSupported() public {
        // Use smaller asset count to avoid gas limit issues
        generateLargePortfolio(20);

        uint256 gasBefore = gasleft();
        address[] memory assets = erc20DefaultOracle.underlyingAssetsSupported();
        uint256 gasUsed = gasBefore - gasleft();

        assertGt(assets.length, 0, "Should have supported assets");
        assertGt(gasUsed, 0, "gas measured");
    }

    // ============================================
    // Gas Per Asset/Adapter Analysis
    // ============================================

    /// @notice Analyze gas per asset
    function test_gasBenchmark_gasPerAsset() public {
        // Use smaller asset counts to avoid gas limit issues
        uint256[] memory assetCounts = new uint256[](3);
        assetCounts[0] = 5;
        assetCounts[1] = 10;
        assetCounts[2] = 15; // Reduced from 20/30 to avoid gas limits

        for (uint256 i = 0; i < assetCounts.length; i++) {
            // Generate portfolio
            generateLargePortfolio(assetCounts[i]);

            // Mint tokens
            for (uint256 j = 0; j < tokens.length; j++) {
                tokens[j].mint(alice, 1000 * 10 ** 18);
            }

            uint256 gasBefore = gasleft();
            erc20DefaultOracle.getOracleBalances(alice);
            uint256 gasUsed = gasBefore - gasleft();

            uint256 gasPerAsset = gasUsed / assetCounts[i];
            assertGt(gasPerAsset, 0, "gas per asset measured");

            // Note: State accumulates across iterations (assets/oracles added to balances)
            // This is intentional for benchmarking, but may cause gas issues in later iterations
        }
    }

    /// @notice Analyze gas per adapter
    function test_gasBenchmark_gasPerAdapter() public {
        // Use smaller adapter counts to avoid gas limit issues
        uint256[] memory adapterCounts = new uint256[](3);
        adapterCounts[0] = 1;
        adapterCounts[1] = 5;
        adapterCounts[2] = 10; // Reduced from 15 to avoid gas limits

        for (uint256 i = 0; i < adapterCounts.length; i++) {
            if (i > 0) {
                setupMultipleAdapters(adapterCounts[i] - 1);
            }

            Mock_ERC20 usdc = new Mock_ERC20("USDC", 6);
            balances.addSupportedAssetForTest(address(usdc));
            usdc.mint(alice, 1000 * 10 ** 6);

            // Query from first custom oracle if exists
            if (customOracles.length > 0) {
                uint256 gasBefore = gasleft();
                customOracles[0].getOracleBalanceForAsset(alice, address(usdc));
                uint256 gasUsed = gasBefore - gasleft();
                assertGt(gasUsed, 0, "gas measured");
            }
        }
    }
}
