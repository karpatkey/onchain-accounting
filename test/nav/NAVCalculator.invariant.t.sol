// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SuperTest} from "test/SuperTest.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_PriceOracleChainlink} from "test/mocks/price_oracles.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {aa} from "test/helpers/AdapterArray.sol";
import {NAV_DECIMALS, MAX_DECIMAL_EXPONENT_INT256} from "src/constants.sol";

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

    /// @notice Helper to setup multiple adapters reporting the same asset
    function setupMultipleAdaptersForAsset(address asset, uint256 adapterCount)
        internal
        returns (Mock_CustomBalanceAdapter[] memory)
    {
        Mock_CustomBalanceAdapter[] memory adapters = new Mock_CustomBalanceAdapter[](adapterCount);

        for (uint256 i = 0; i < adapterCount; i++) {
            Mock_CustomBalanceAdapter adapter = new Mock_CustomBalanceAdapter();
            adapter.setBalances(IBalances(address(nav)));
            address[] memory assets = new address[](1);
            assets[0] = asset;
            adapter.setUnderlyingAssetsSupported(assets);
            adapters[i] = adapter;

            vm.startPrank(navCalculatorManager);
            nav.addBalanceAdapters(aa(address(adapter)));
            vm.stopPrank();
        }

        return adapters;
    }

    /// @notice Helper to assert price consistency
    function assertPriceConsistent(address asset, uint256 expectedPrice, uint8 expectedDecimals, bool expectedStale)
        internal
        view
    {
        (int256 price1, uint8 decimals1, bool stale1,) = nav.latestPrice(asset);
        (int256 price2, uint8 decimals2, bool stale2,) = nav.latestPrice(asset);

        assertEq(price1, price2, "Price should be consistent within same block");
        assertEq(decimals1, decimals2, "Decimals should be consistent");
        assertEq(stale1, stale2, "Staleness should be consistent");

        if (expectedPrice > 0) {
            assertEq(price1, SafeCast.toInt256(expectedPrice), "Price should match expected");
            assertEq(decimals1, expectedDecimals, "Decimals should match expected");
            assertEq(stale1, expectedStale, "Staleness should match expected");
        }
    }

    // ============================================
    // Adapter Aggregation Invariant
    // ============================================

    /// @notice Test that multiple adapters reporting same asset aggregate correctly
    function test_invariant_adapterAggregation() public {
        // Setup: Multiple adapters reporting USDC
        uint256 adapterCount = 5;
        Mock_CustomBalanceAdapter[] memory adapters = setupMultipleAdaptersForAsset(address(usdc), adapterCount);

        // Set different balances for each adapter
        int256[] memory adapterBalances = new int256[](adapterCount);
        int256 totalExpectedBalance = 0;

        for (uint256 i = 0; i < adapterCount; i++) {
            int256 balance = int256((i + 1) * 100 * 10 ** usdc.decimals());
            adapterBalances[i] = balance;
            totalExpectedBalance += balance;
            adapters[i].setBalance(address(usdc), safe, uint256((i + 1) * 100 * 10 ** usdc.decimals()), false);
        }

        // Also mint some USDC directly to safe (ERC20DefaultBalanceAdapter)
        uint256 directBalance = 50 * 10 ** usdc.decimals();
        usdc.mint(safe, directBalance);
        totalExpectedBalance += SafeCast.toInt256(directBalance);

        // Get positions for USDC
        INAVCalculator.Position[] memory positions = nav.getAccountPositionsForAsset(safe, address(usdc), address(0));

        // Verify all positions are for USDC
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(usdc), "All positions should be for USDC");
        }

        // Verify no duplicate positions (check by balanceAdapter address)
        for (uint256 i = 0; i < positions.length; i++) {
            for (uint256 j = i + 1; j < positions.length; j++) {
                assertTrue(
                    positions[i].balanceAdapter != positions[j].balanceAdapter,
                    "No duplicate positions from same adapter"
                );
            }
        }

        // Verify total balance matches sum of adapter balances
        // positions[i].value is in USD (8 decimals), so we need to convert expected balance to USD
        int256 totalBalance = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            // Use value which already accounts for isDebt
            totalBalance += positions[i].value;
        }

        // Convert expected balance from asset decimals to USD (8 decimals)
        // For USDC: price is 1e8 (1 USD), so conversion is: balance * 10^(8 - 6) = balance * 100
        (int256 usdcPrice, uint8 priceDecimals,,) = nav.latestPrice(address(usdc));
        uint8 assetDecimals = usdc.decimals();
        uint256 denominator = assetDecimals + priceDecimals - 8; // NAV_DECIMALS = 8
        int256 totalExpectedUsdValue = (totalExpectedBalance * int256(usdcPrice)) / SafeCast.toInt256(10 ** denominator);

        assertEq(totalBalance, totalExpectedUsdValue, "Total balance should equal sum of all adapter balances");

        // Verify NAV consistency
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        int256 positionsSum = sumPositionValues(positions);
        assertEq(navTotal.value, positionsSum, "NAV should equal sum of position values");
    }

    /// @notice Test that adapter aggregation works with negative balances
    function test_invariant_adapterAggregation_negativeBalances() public {
        // Setup: Multiple adapters with mixed positive and negative balances
        uint256 adapterCount = 3;
        Mock_CustomBalanceAdapter[] memory adapters = setupMultipleAdaptersForAsset(address(usdc), adapterCount);

        // Set mixed balances
        adapters[0].setBalance(address(usdc), safe, 1000 * 10 ** usdc.decimals(), false);
        adapters[1].setBalance(address(usdc), safe, 300 * 10 ** usdc.decimals(), true);
        adapters[2].setBalance(address(usdc), safe, 200 * 10 ** usdc.decimals(), false);

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
        (int256 usdcPrice, uint8 priceDecimals,,) = nav.latestPrice(address(usdc));
        uint8 assetDecimals = usdc.decimals();
        uint256 denominator = assetDecimals + priceDecimals - 8; // NAV_DECIMALS = 8
        int256 expectedUsdValue = (expectedTotal * int256(usdcPrice)) / SafeCast.toInt256(10 ** denominator);

        assertEq(totalBalance, expectedUsdValue, "Total balance should aggregate correctly with negative balances");
    }

    // ============================================
    // Price Feed Consistency Invariant
    // ============================================

    /// @notice Test that same asset returns same price within same block
    function test_invariant_priceFeedConsistency() public view {
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
        Mock_PriceOracleChainlink staleAdapter = new Mock_PriceOracleChainlink("Stale", 1, 8);

        vm.startPrank(navCalculatorManager);
        nav.addPriceFeed(address(usdc), address(staleAdapter), IPrices.PriceType.Chainlink, 1); // 1 second heartbeat
        nav.removePriceFeed(address(usdc), address(usdcAdapter)); // remove original so only staleAdapter remains
        vm.stopPrank();

        // Make price stale by warping time
        vm.warp(block.timestamp + 2);

        // Query multiple times - staleness should be consistent
        (int256 price1,, bool stale1,) = nav.latestPrice(address(usdc));
        (int256 price2,, bool stale2,) = nav.latestPrice(address(usdc));
        (int256 price3,, bool stale3,) = nav.latestPrice(address(usdc));

        assertEq(stale1, stale2, "Staleness should be consistent");
        assertEq(stale2, stale3, "Staleness should be consistent");
        assertTrue(stale1, "Price should be stale");
        assertEq(price1, price2, "Price should be consistent");
        assertEq(price2, price3, "Price should be consistent");
    }

    /// @notice Test that getPriceData returns consistent results
    function test_invariant_priceFeedConsistency_getPriceData() public view {
        INAVCalculator.PriceFeedData memory feed1 = nav.getPriceData(address(usdc));
        INAVCalculator.PriceFeedData memory feed2 = nav.getPriceData(address(usdc));

        assertEq(feed1.price, feed2.price, "Price should be consistent");
        assertEq(feed1.decimals, feed2.decimals, "Decimals should be consistent");
        assertEq(feed1.stale, feed2.stale, "Staleness should be consistent");
        assertEq(feed1.priceFeed, feed2.priceFeed, "Price feed should be consistent");
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
            address asset = positions[i].balanceAsset.asset;
            assertTrue(nav.isAssetRegistered(asset), "All position assets should be registered");
        }

        // Verify all registered assets can be queried.
        //
        // Both assertions in this loop used to be tautologies and checked nothing: `decimals <= 255` is always
        // true for a `uint8`, and `bytes(symbol).length >= 0` is always true for a `uint256` length. They read
        // like bounds checks, which is why they survived review.
        //
        // Assert instead what the registry actually guarantees, and only that. `NAVRegistryLib.registerAsset`
        // does NOT bound decimals and does NOT require a non-empty symbol — it copies whatever the token's
        // `decimals()` / `symbol()` returned — so a non-empty-symbol assertion here would be inventing an
        // invariant the code does not hold. What IS guaranteed is that the array and the index agree, and that
        // the record is reachable by its own address; that is what "can be queried" was reaching for.
        INAVCalculator.Asset[] memory registeredAssets = nav.getRegisteredAssets();
        for (uint256 i = 0; i < registeredAssets.length; i++) {
            address registered = registeredAssets[i].asset;
            assertTrue(registered != address(0), "a registered record must name an asset");
            assertTrue(nav.isAssetRegistered(registered), "every array entry must be reachable by address");

            // Assert the predicate `PriceFeedLib._priceConversion` ACTUALLY enforces, not a proxy for it. Its two
            // guards are both on the EXPONENT `assetDecimals + assetPriceDecimals - NAV_DECIMALS`:
            //   - it reverts `InvalidAssetDecimals` when that sum is below NAV_DECIMALS (underflow), and
            //   - it reverts `InvalidDecimalExponent` when the resulting exponent exceeds the 10**x bound.
            // An earlier revision of this line asserted `decimals <= 77` instead. That was wrong twice over: it
            // checked `assetDecimals` in ISOLATION, when neither guard is a function of it alone, and 77 is
            // off-by-one against `MAX_DECIMAL_EXPONENT_INT256 = 76`. It could therefore pass for an asset whose
            // pricing path reverts — a check that looks like a bound and is not one, which is the exact defect
            // this loop was being fixed for. Caught in review by Copilot.
            (, uint8 priceDecimals,,) = nav.latestPrice(registered);
            uint256 sum = uint256(registeredAssets[i].decimals) + uint256(priceDecimals);
            assertGe(sum, NAV_DECIMALS, "asset+feed decimals must reach NAV_DECIMALS or _priceConversion reverts");
            assertLe(
                sum - NAV_DECIMALS, MAX_DECIMAL_EXPONENT_INT256, "exponent must stay inside the int256 10**x bound"
            );
        }
    }

    /// @notice Test that asset count matches actual registered assets
    function test_invariant_assetRegistryConsistency_count() public view {
        uint256 assetCount = nav.getAssetCount();
        INAVCalculator.Asset[] memory assets = nav.getRegisteredAssets();

        assertEq(assetCount, assets.length, "Asset count should match assets array length");

        // Verify no duplicates in assets array
        for (uint256 i = 0; i < assets.length; i++) {
            for (uint256 j = i + 1; j < assets.length; j++) {
                assertTrue(assets[i].asset != assets[j].asset, "No duplicate assets in registry");
            }
        }
    }

    // ============================================
    // Adapter Registry Consistency Invariant
    // ============================================

    /// @notice Test that all adapters implement IBalanceAdapter
    function test_invariant_adapterRegistryConsistency() public view {
        address[] memory allAdapters = nav.getAllAdapters();

        // Verify ERC20DefaultBalanceAdapter is always present
        bool foundErc20Default = false;
        for (uint256 i = 0; i < allAdapters.length; i++) {
            if (allAdapters[i] == nav.erc20DefaultBalanceAdapter()) {
                foundErc20Default = true;
            }

            // Verify all adapters implement IBalanceAdapter
            IBalanceAdapter adapter = IBalanceAdapter(allAdapters[i]);
            try adapter.supportsInterface(type(IBalanceAdapter).interfaceId) returns (bool supported) {
                assertTrue(supported, "Adapter should support IBalanceAdapter");
            } catch {
                revert("Adapter should support IBalanceAdapter interface");
            }
        }

        assertTrue(foundErc20Default, "ERC20DefaultBalanceAdapter should always be registered");
    }

    /// @notice Test that all adapters can be queried without reverting
    function test_invariant_adapterRegistryConsistency_queryable() public view {
        address[] memory allAdapters = nav.getAllAdapters();

        for (uint256 i = 0; i < allAdapters.length; i++) {
            IBalanceAdapter adapter = IBalanceAdapter(allAdapters[i]);

            // Should be able to query underlyingAssetsSupported
            try adapter.underlyingAssetsSupported() returns (
                address[] memory
            ) {
            // Success
            }
            catch {
                revert("Adapter should support underlyingAssetsSupported()");
            }

            // Should be able to query balance for a test account
            try adapter.getAdapterBalanceForAsset(safe, address(usdc)) returns (
                uint256, bool
            ) {
            // Success
            }
                catch {
                // Some adapters might not support all assets, that's okay
            }
        }
    }

    /// @notice Test that adapter count matches actual registered adapters
    function test_invariant_adapterRegistryConsistency_count() public view {
        uint256 adapterCount = nav.getAdapterCount();
        address[] memory allAdapters = nav.getAllAdapters();

        assertEq(adapterCount, allAdapters.length, "Adapter count should match adapters array length");

        // Verify no duplicates
        for (uint256 i = 0; i < allAdapters.length; i++) {
            for (uint256 j = i + 1; j < allAdapters.length; j++) {
                assertTrue(allAdapters[i] != allAdapters[j], "No duplicate adapters in registry");
            }
        }
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
        (int256 daiPrice, uint8 daiPriceDecimals,,) = nav.latestPrice(address(dai));
        (int256 wethPrice, uint8 wethPriceDecimals,,) = nav.latestPrice(address(weth));

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
