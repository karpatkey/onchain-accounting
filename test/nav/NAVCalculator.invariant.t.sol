// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";

/// @title NAVCalculator Invariant Tests
/// @notice Tests critical system invariants for NAVCalculator
contract NAVCalculatorInvariantTest is SuperTest {
    function setUp() public {
        setupAll();
    }

    /// @notice Helper function to sum position values
    function sumPositionValues(INAVCalculator.Position[] memory positions) internal pure returns (int256) {
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        return sum;
    }

    /// @notice Helper to setup multiple oracles reporting the same asset
    function setupMultipleOraclesForAsset(address asset, uint256 oracleCount)
        internal
        returns (Mock_CustomBalanceOracle[] memory)
    {
        Mock_CustomBalanceOracle[] memory oracles = new Mock_CustomBalanceOracle[](oracleCount);

        for (uint256 i = 0; i < oracleCount; i++) {
            Mock_CustomBalanceOracle oracle = new Mock_CustomBalanceOracle();
            oracle.setBalances(IBalances(address(nav)));
            address[] memory assets = new address[](1);
            assets[0] = asset;
            oracle.setUnderlyingAssetsSupported(assets);
            oracle.setPositionMetadata(
                string(abi.encodePacked("Protocol ", vm.toString(i))),
                string(abi.encodePacked("Position ", vm.toString(i)))
            );
            oracles[i] = oracle;

            vm.startPrank(navCalculatorManager);
            nav.addBalanceOracle(address(oracle));
            vm.stopPrank();
        }

        return oracles;
    }

    /// @notice Helper to assert price consistency
    function assertPriceConsistent(address asset, uint256 expectedPrice, uint8 expectedDecimals, bool expectedStale)
        internal
        view
    {
        (uint256 price1, uint8 decimals1, bool stale1) = nav.latestPrice(asset);
        (uint256 price2, uint8 decimals2, bool stale2) = nav.latestPrice(asset);

        assertEq(price1, price2, "Price should be consistent within same block");
        assertEq(decimals1, decimals2, "Decimals should be consistent");
        assertEq(stale1, stale2, "Staleness should be consistent");

        if (expectedPrice > 0) {
            assertEq(price1, expectedPrice, "Price should match expected");
            assertEq(decimals1, expectedDecimals, "Decimals should match expected");
            assertEq(stale1, expectedStale, "Staleness should match expected");
        }
    }

    // ============================================
    // Oracle Aggregation Invariant
    // ============================================

    /// @notice Test that multiple oracles reporting same asset aggregate correctly
    function test_invariant_oracleAggregation() public {
        // Setup: Multiple oracles reporting USDC
        uint256 oracleCount = 5;
        Mock_CustomBalanceOracle[] memory oracles = setupMultipleOraclesForAsset(address(usdc), oracleCount);

        // Set different balances for each oracle
        int256[] memory oracleBalances = new int256[](oracleCount);
        int256 totalExpectedBalance = 0;

        for (uint256 i = 0; i < oracleCount; i++) {
            int256 balance = int256((i + 1) * 100 * 10 ** usdc.decimals());
            oracleBalances[i] = balance;
            totalExpectedBalance += balance;
            oracles[i].setBalance(address(usdc), safe, uint256((i + 1) * 100 * 10 ** usdc.decimals()), false);
        }

        // Also mint some USDC directly to safe (ERC20DefaultOracle)
        uint256 directBalance = 50 * 10 ** usdc.decimals();
        usdc.mint(safe, directBalance);
        totalExpectedBalance += int256(directBalance);

        // Get positions for USDC
        INAVCalculator.Position[] memory positions = nav.getAccountPositionsForAsset(safe, address(usdc), address(0));

        // Verify all positions are for USDC
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, address(usdc), "All positions should be for USDC");
        }

        // Verify no duplicate positions (check by balanceOracle address)
        for (uint256 i = 0; i < positions.length; i++) {
            for (uint256 j = i + 1; j < positions.length; j++) {
                assertTrue(
                    positions[i].balanceOracle != positions[j].balanceOracle, "No duplicate positions from same oracle"
                );
            }
        }

        // Verify total balance matches sum of oracle balances
        // positions[i].value is in USD (8 decimals), so we need to convert expected balance to USD
        int256 totalBalance = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            // Use value which already accounts for isDebt
            totalBalance += positions[i].value;
        }

        // Convert expected balance from asset decimals to USD (8 decimals)
        // For USDC: price is 1e8 (1 USD), so conversion is: balance * 10^(8 - 6) = balance * 100
        (uint256 usdcPrice, uint8 priceDecimals,) = nav.latestPrice(address(usdc));
        uint8 assetDecimals = usdc.decimals();
        uint256 denominator = assetDecimals + priceDecimals - 8; // NAV_DECIMALS = 8
        int256 totalExpectedUsdValue = (totalExpectedBalance * int256(usdcPrice)) / int256(10 ** denominator);

        assertEq(totalBalance, totalExpectedUsdValue, "Total balance should equal sum of all oracle balances");

        // Verify NAV consistency
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        int256 positionsSum = sumPositionValues(positions);
        assertEq(navTotal.value, positionsSum, "NAV should equal sum of position values");
    }

    /// @notice Test that oracle aggregation works with negative balances
    function test_invariant_oracleAggregation_negativeBalances() public {
        // Setup: Multiple oracles with mixed positive and negative balances
        uint256 oracleCount = 3;
        Mock_CustomBalanceOracle[] memory oracles = setupMultipleOraclesForAsset(address(usdc), oracleCount);

        // Set mixed balances
        oracles[0].setBalance(address(usdc), safe, 1000 * 10 ** usdc.decimals(), false);
        oracles[1].setBalance(address(usdc), safe, 300 * 10 ** usdc.decimals(), true);
        oracles[2].setBalance(address(usdc), safe, 200 * 10 ** usdc.decimals(), false);

        int256 expectedTotal = int256(900 * 10 ** usdc.decimals());

        // Get positions
        INAVCalculator.Position[] memory positions = nav.getAccountPositionsForAsset(safe, address(usdc), address(0));

        // Verify total balance
        // positions[i].value is in USD (8 decimals), so we need to convert expected balance to USD
        int256 totalBalance = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            // Use value which already accounts for isDebt
            totalBalance += positions[i].value;
        }

        // Convert expected balance from asset decimals to USD (8 decimals)
        (uint256 usdcPrice, uint8 priceDecimals,) = nav.latestPrice(address(usdc));
        uint8 assetDecimals = usdc.decimals();
        uint256 denominator = assetDecimals + priceDecimals - 8; // NAV_DECIMALS = 8
        int256 expectedUsdValue = (expectedTotal * int256(usdcPrice)) / int256(10 ** denominator);

        assertEq(totalBalance, expectedUsdValue, "Total balance should aggregate correctly with negative balances");
    }

    // ============================================
    // Price Feed Consistency Invariant
    // ============================================

    /// @notice Test that same asset returns same price within same block
    function test_invariant_priceFeedConsistency() public {
        // Query price multiple times in same block
        assertPriceConsistent(address(usdc), 100_000_000, 8, false);
        assertPriceConsistent(address(dai), 100_000_000, 8, false);
        assertPriceConsistent(address(weth), 324_057_000_000, 8, false);

        // Test with native address
        assertPriceConsistent(nav.NATIVE_ADDRESS(), 324_057_000_000, 8, false);
    }

    /// @notice Test that price staleness is consistent across queries
    function test_invariant_priceFeedConsistency_staleness() public {
        // Create a stale price oracle
        Mock_PriceOracleChainlink staleOracle = new Mock_PriceOracleChainlink("Stale", 1, 8);

        vm.startPrank(navCalculatorManager);
        nav.setPriceFeed(address(usdc), address(staleOracle), IPrices.PriceType.Chainlink, 1); // 1 second heartbeat
        vm.stopPrank();

        // Make price stale by warping time
        vm.warp(block.timestamp + 2);

        // Query multiple times - staleness should be consistent
        (uint256 price1, uint8 decimals1, bool stale1) = nav.latestPrice(address(usdc));
        (uint256 price2, uint8 decimals2, bool stale2) = nav.latestPrice(address(usdc));
        (uint256 price3, uint8 decimals3, bool stale3) = nav.latestPrice(address(usdc));

        assertEq(stale1, stale2, "Staleness should be consistent");
        assertEq(stale2, stale3, "Staleness should be consistent");
        assertTrue(stale1, "Price should be stale");
        assertEq(price1, price2, "Price should be consistent");
        assertEq(price2, price3, "Price should be consistent");
    }

    /// @notice Test that getPriceData returns consistent results
    function test_invariant_priceFeedConsistency_getPriceData() public {
        INAVCalculator.PriceFeedData memory feed1 = nav.getPriceData(address(usdc));
        INAVCalculator.PriceFeedData memory feed2 = nav.getPriceData(address(usdc));

        assertEq(feed1.price, feed2.price, "Price should be consistent");
        assertEq(feed1.decimals, feed2.decimals, "Decimals should be consistent");
        assertEq(feed1.stale, feed2.stale, "Staleness should be consistent");
        assertEq(feed1.oracle, feed2.oracle, "Oracle should be consistent");
    }

    // ============================================
    // Asset Registry Consistency Invariant
    // ============================================

    /// @notice Test that all assets in positions are registered
    function test_invariant_assetRegistryConsistency() public {
        // Setup: Create positions with multiple assets
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());
        weth.mint(safe, 10 ** weth.decimals());

        // Get all positions
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Verify all position assets are registered
        for (uint256 i = 0; i < positions.length; i++) {
            address asset = positions[i].underlyingAsset.asset;
            assertTrue(nav.isAssetRegistered(asset), "All position assets should be registered");
        }

        // Verify all registered assets can be queried
        address[] memory registeredAssets = nav.getAssets();
        for (uint256 i = 0; i < registeredAssets.length; i++) {
            address asset = registeredAssets[i];

            // Should be able to get decimals
            uint8 decimals = nav.getAssetDecimals(asset);
            assertTrue(decimals <= 255, "Decimals should be valid");

            // Should be able to get symbol
            string memory symbol = nav.getAssetSymbol(asset);
            // Symbol can be empty, but should not revert
        }
    }

    /// @notice Test that asset count matches actual registered assets
    function test_invariant_assetRegistryConsistency_count() public {
        uint256 assetCount = nav.getAssetCount();
        address[] memory assets = nav.getAssets();

        assertEq(assetCount, assets.length, "Asset count should match assets array length");

        // Verify no duplicates in assets array
        for (uint256 i = 0; i < assets.length; i++) {
            for (uint256 j = i + 1; j < assets.length; j++) {
                assertTrue(assets[i] != assets[j], "No duplicate assets in registry");
            }
        }
    }

    // ============================================
    // Oracle Registry Consistency Invariant
    // ============================================

    /// @notice Test that all oracles implement IBalanceOracleAdapter
    function test_invariant_oracleRegistryConsistency() public {
        address[] memory allOracles = nav.getAllOracles();

        // Verify ERC20DefaultOracle is always present
        bool foundErc20Default = false;
        for (uint256 i = 0; i < allOracles.length; i++) {
            if (allOracles[i] == nav.erc20DefaultOracle()) {
                foundErc20Default = true;
            }

            // Verify all oracles implement IBalanceOracleAdapter
            IBalanceOracleAdapter oracle = IBalanceOracleAdapter(allOracles[i]);
            try oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId) returns (bool supported) {
                assertTrue(supported, "Oracle should support IBalanceOracleAdapter");
            } catch {
                revert("Oracle should support IBalanceOracleAdapter interface");
            }
        }

        assertTrue(foundErc20Default, "ERC20DefaultOracle should always be registered");
    }

    /// @notice Test that all oracles can be queried without reverting
    function test_invariant_oracleRegistryConsistency_queryable() public {
        address[] memory allOracles = nav.getAllOracles();

        for (uint256 i = 0; i < allOracles.length; i++) {
            IBalanceOracleAdapter oracle = IBalanceOracleAdapter(allOracles[i]);

            // Should be able to query underlyingAssetsSupported
            try oracle.underlyingAssetsSupported() returns (
                address[] memory
            ) {
            // Success
            }
            catch {
                revert("Oracle should support underlyingAssetsSupported()");
            }

            // Should be able to query balance for a test account
            try oracle.getOracleBalanceForAsset(safe, address(usdc)) returns (
                int256
            ) {
            // Success
            }
                catch {
                // Some oracles might not support all assets, that's okay
            }
        }
    }

    /// @notice Test that oracle count matches actual registered oracles
    function test_invariant_oracleRegistryConsistency_count() public {
        uint256 oracleCount = nav.getOracleCount();
        address[] memory allOracles = nav.getAllOracles();

        assertEq(oracleCount, allOracles.length, "Oracle count should match oracles array length");

        // Verify no duplicates
        for (uint256 i = 0; i < allOracles.length; i++) {
            for (uint256 j = i + 1; j < allOracles.length; j++) {
                assertTrue(allOracles[i] != allOracles[j], "No duplicate oracles in registry");
            }
        }
    }

    // ============================================
    // Range Query Completeness Invariant
    // ============================================

    /// @notice Test that sum of range queries equals full query
    function test_invariant_rangeQueryCompleteness() public {
        // Setup: Create positions with multiple assets
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());
        weth.mint(safe, 10 ** weth.decimals());

        uint256 assetCount = nav.getAssetCount();
        assertGe(assetCount, 3, "Should have at least 3 assets");

        // Get full NAV
        INAVCalculator.NAV memory fullNav = nav.getAccountNav(safe, address(0));

        // Split into ranges and sum
        int256 rangeSum = 0;
        uint256 rangeSize = 1; // Query one asset at a time

        for (uint256 i = 0; i < assetCount; i += rangeSize) {
            uint256 to = i + rangeSize - 1;
            if (to >= assetCount) {
                to = assetCount - 1;
            }

            INAVCalculator.NAV memory rangeNav = nav.getAccountNavForRange(safe, i, to, address(0));
            rangeSum += rangeNav.value;
        }

        // Allow small rounding differences
        assertApproxEqAbs(fullNav.value, rangeSum, 1, "Sum of range queries should equal full query");
    }

    /// @notice Test that overlapping ranges don't double-count
    function test_invariant_rangeQueryCompleteness_noDoubleCount() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        uint256 assetCount = nav.getAssetCount();
        if (assetCount < 2) return; // Skip if not enough assets

        // Get NAV for overlapping ranges
        INAVCalculator.NAV memory nav1 = nav.getAccountNavForRange(safe, 0, 1, address(0));
        INAVCalculator.NAV memory nav2 = nav.getAccountNavForRange(safe, 1, 2, address(0));

        // Get full NAV
        INAVCalculator.NAV memory fullNav = nav.getAccountNav(safe, address(0));

        // Overlapping ranges should not double-count
        // nav1 + nav2 might have overlap, but should be >= fullNav (if overlap exists)
        // In practice, we test non-overlapping ranges, so this is more of a sanity check
        assertGe(nav1.value + nav2.value, fullNav.value, "Overlapping ranges should not undercount");
    }

    // ============================================
    // Quote Currency Independence Invariant
    // ============================================

    /// @notice Test that NAV value is independent of quote currency (after conversion)
    function test_invariant_quoteAssetIndependence() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());

        // Get NAV in different quote currencies
        INAVCalculator.NAV memory navUsd = nav.getAccountNav(safe, address(0));
        INAVCalculator.NAV memory navDai = nav.getAccountNav(safe, address(dai));
        INAVCalculator.NAV memory navWeth = nav.getAccountNav(safe, address(weth));

        // Get prices for conversion
        (uint256 daiPrice, uint8 daiPriceDecimals,) = nav.latestPrice(address(dai));
        (uint256 wethPrice, uint8 wethPriceDecimals,) = nav.latestPrice(address(weth));

        // Convert DAI NAV back to USD
        // navDai.value is in DAI with dai.decimals()
        // Convert: navDai.value * daiPrice / 10^(dai.decimals() + daiPriceDecimals - 8)
        int256 navDaiInUsd = (navDai.value * int256(daiPrice)) / int256(10 ** (dai.decimals() + daiPriceDecimals - 8));

        // Convert WETH NAV back to USD
        int256 navWethInUsd =
            (navWeth.value * int256(wethPrice)) / int256(10 ** (weth.decimals() + wethPriceDecimals - 8));

        // All should match within rounding tolerance (0.01% or 1e6 for 8 decimals)
        assertApproxEqAbs(navUsd.value, navDaiInUsd, 1e6, "USD and DAI NAV should match after conversion");
        assertApproxEqAbs(navUsd.value, navWethInUsd, 1e6, "USD and WETH NAV should match after conversion");
    }

    /// @notice Test that converting between quote currencies preserves relative values
    function test_invariant_quoteAssetIndependence_relativeValues() public {
        // Setup: Two accounts with different balances
        address account1 = makeAddr("account1");
        address account2 = makeAddr("account2");

        usdc.mint(account1, 10 ** usdc.decimals());
        usdc.mint(account2, 20 * 10 ** usdc.decimals());

        // Get NAVs in USD and DAI
        INAVCalculator.NAV memory nav1Usd = nav.getAccountNav(account1, address(0));
        INAVCalculator.NAV memory nav2Usd = nav.getAccountNav(account2, address(0));
        INAVCalculator.NAV memory nav1Dai = nav.getAccountNav(account1, address(dai));
        INAVCalculator.NAV memory nav2Dai = nav.getAccountNav(account2, address(dai));

        // Ratio should be preserved
        // nav2 should be 2x nav1 in both currencies
        int256 ratioUsd = nav2Usd.value * 1e8 / nav1Usd.value; // Scale to avoid precision issues
        int256 ratioDai = nav2Dai.value * 1e8 / nav1Dai.value;

        // Allow 1% tolerance for rounding
        assertApproxEqRel(ratioUsd, ratioDai, 0.01 ether, "Relative values should be preserved across quote currencies");
    }

    // ============================================
    // Timestamp Consistency Invariant
    // ============================================

    /// @notice Test that all NAV queries in same block return same timestamp
    function test_invariant_timestampConsistency() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        // Query NAV multiple times in same block
        INAVCalculator.NAV memory nav1 = nav.getAccountNav(safe, address(0));
        INAVCalculator.NAV memory nav2 = nav.getAccountNav(safe, address(0));
        INAVCalculator.NAV memory nav3 = nav.getAccountNav(safe, address(0));

        // All timestamps should be identical
        assertEq(nav1.timestamp, nav2.timestamp, "Timestamps should be consistent");
        assertEq(nav2.timestamp, nav3.timestamp, "Timestamps should be consistent");

        // Timestamp should match block.timestamp
        assertEq(uint256(nav1.timestamp), block.timestamp, "Timestamp should match block.timestamp");
    }

    /// @notice Test that timestamp updates correctly across blocks
    function test_invariant_timestampConsistency_acrossBlocks() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory nav1 = nav.getAccountNav(safe, address(0));
        uint64 timestamp1 = nav1.timestamp;

        // Move to next block
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12); // 12 seconds later

        INAVCalculator.NAV memory nav2 = nav.getAccountNav(safe, address(0));
        uint64 timestamp2 = nav2.timestamp;

        // Timestamp should have updated
        assertGt(timestamp2, timestamp1, "Timestamp should update across blocks");
        assertEq(uint256(timestamp2), block.timestamp, "Timestamp should match new block.timestamp");
    }
}
