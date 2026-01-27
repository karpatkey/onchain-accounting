// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MockContract} from "test/mocks/MockContract.sol";

/// @title NAVCalculator Fuzz Tests
/// @notice Property-based fuzz tests for core NAVCalculator functions
contract NAVCalculatorFuzzTest is SuperTest {
    /// @notice An account with no token/native balances (address of a contract never funded)
    address public emptyAccount;

    function setUp() public {
        setupAll();
        emptyAccount = address(new MockContract());
    }
    
    /// @notice Helper function to sum position values
    function sumPositionValues(INAVCalculator.Position[] memory positions) internal pure returns (int256) {
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        return sum;
    }
    
    /// @notice Helper to check if amount * price would overflow
    /// @dev Returns true if the multiplication is safe
    function isSafeMultiplication(uint256 amount, uint256 price) internal pure returns (bool) {
        if (amount == 0 || price == 0) return true;
        // Check if amount * price would overflow
        // amount * price <= type(uint256).max
        // This is equivalent to: amount <= type(uint256).max / price
        return amount <= type(uint256).max / price;
    }
    
    /// @notice Helper to get a safe bound for amount given max price
    /// @dev Returns a bound that ensures amount * maxPrice won't overflow
    function getSafeAmountBound(uint256 seed, uint8 decimals, uint256 maxPrice) internal pure returns (uint256) {
        // Calculate max safe amount: type(uint256).max / maxPrice
        // But also respect the decimals-based max
        uint256 maxByDecimals = 1_000_000 * 10 ** decimals;
        uint256 maxByPrice = type(uint256).max / maxPrice;
        uint256 maxSafe = maxByDecimals < maxByPrice ? maxByDecimals : maxByPrice;
        return bound(seed, 1, maxSafe);
    }

    /// @notice Helper to get a valid quote asset from registered assets
    function getValidQuoteAsset(uint256 seed) internal view returns (address) {
        address[] memory assets = nav.getAssets();
        if (assets.length == 0) {
            return address(0); // USD
        }
        uint256 index = bound(seed, 0, assets.length);
        if (index == assets.length) {
            return address(0); // USD
        }
        return assets[index];
    }

    // ============================================
    // Fuzz Tests for getAccountNav
    // ============================================

    /// @notice Fuzz test for getAccountNav with random accounts and quote assets
    function testFuzz_getAccountNav(address account, uint256 quoteAssetSeed) public {
        // Bound account to non-zero address
        vm.assume(account != address(0));
        
        // Get valid quote asset
        address quoteAsset = getValidQuoteAsset(quoteAssetSeed);
        
        // If quote asset is not USD, verify it has a price feed
        if (quoteAsset != address(0)) {
            vm.assume(nav.isAssetRegistered(quoteAsset));
            (address oracle,,,) = nav.priceOracles(quoteAsset);
            vm.assume(oracle != address(0));
        }
        
        // Should not revert (unless account has invalid state, which is unlikely)
        INAVCalculator.NAV memory navResult = nav.getAccountNav(account, quoteAsset);
        
        // Verify basic properties
        assertEq(navResult.timestamp, block.timestamp, "Timestamp should match block.timestamp");
        assertTrue(navResult.quoteAsset.asset == quoteAsset, "Quote asset should match");
        
        // Verify NAV consistency invariant
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, quoteAsset);
        int256 positionsSum = sumPositionValues(positions);
        
        // Allow small rounding differences
        assertApproxEqAbs(navResult.value, positionsSum, 1, "NAV should equal sum of positions");
    }

    /// @notice Fuzz test for getAccountNav with account that has positions
    function testFuzz_getAccountNav_withPositions(address account, uint256 amountSeed) public {
        vm.assume(account != address(0));
        vm.assume(account != address(nav));
        
        // Bound amount to reasonable range (avoid overflow)
        uint256 amount = bound(amountSeed, 1, 1_000_000 * 10 ** usdc.decimals());
        
        // Mint tokens to account
        usdc.mint(account, amount);
        
        // Get NAV
        INAVCalculator.NAV memory navResult = nav.getAccountNav(account, address(0));
        
        // Should have positive value
        assertGe(navResult.value, 0, "NAV should be non-negative for positive balances");
        
        // Verify positions exist
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, address(0));
        assertGt(positions.length, 0, "Should have positions");
        
        // Verify consistency
        int256 positionsSum = sumPositionValues(positions);
        assertApproxEqAbs(navResult.value, positionsSum, 1, "NAV should equal sum of positions");
    }

    // ============================================
    // Fuzz Tests for getAccountPositions
    // ============================================

    /// @notice Fuzz test for getAccountPositions with random quote currencies
    function testFuzz_getAccountPositions(address account, uint256 quoteAssetSeed) public {
        vm.assume(account != address(0));
        
        // Get valid quote asset
        address quoteAsset = getValidQuoteAsset(quoteAssetSeed);
        
        if (quoteAsset != address(0)) {
            vm.assume(nav.isAssetRegistered(quoteAsset));
            (address oracle,,,) = nav.priceOracles(quoteAsset);
            vm.assume(oracle != address(0));
        }
        
        // Should not revert
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, quoteAsset);
        
        // Verify all positions have correct quote asset
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].quoteAsset.asset, quoteAsset, "Quote asset should match");
            assertTrue(positions[i].value != 0, "No zero positions");
        }
        
        // Verify NAV consistency
        INAVCalculator.NAV memory navResult = nav.getAccountNav(account, quoteAsset);
        int256 positionsSum = sumPositionValues(positions);
        assertApproxEqAbs(navResult.value, positionsSum, 1, "NAV should equal sum of positions");
    }

    // ============================================
    // Fuzz Tests for Decimal Combinations
    // ============================================

    /// @notice Fuzz test for various decimal combinations
    function testFuzz_decimalCombinations(
        uint8 assetDecimals,
        uint8 priceDecimals,
        uint256 balanceAmount
    ) public {
        // Bound decimals to valid range (0-255, but avoid extreme values that cause overflow)
        assetDecimals = uint8(bound(assetDecimals, 0, 18)); // Common range
        priceDecimals = uint8(bound(priceDecimals, 0, 18)); // Common range
        
        // Ensure we don't violate the constraint: decimals + priceDecimals >= NAV_DECIMALS (8)
        if (assetDecimals + priceDecimals < 8) {
            // Adjust to meet constraint
            if (assetDecimals < 8) {
                assetDecimals = 8;
            } else {
                priceDecimals = 8 - assetDecimals;
            }
        }
        
        // Bound balance to avoid overflow
        balanceAmount = bound(balanceAmount, 1, 1_000_000 * 10 ** assetDecimals);
        
        // Create mock token with specific decimals
        Mock_ERC20 token = new Mock_ERC20("TEST", assetDecimals);
        
        // Create price oracle with specific decimals
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TEST", address(token), 1e8, priceDecimals);
        
        // Register asset
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        
        // Mint tokens
        token.mint(safe, balanceAmount);
        
        // Get NAV - should not revert
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        
        // Value should be positive
        assertGe(navResult.value, 0, "NAV should be non-negative");
    }

    // ============================================
    // Fuzz Tests for Range Queries
    // ============================================

    /// @notice Fuzz test for range queries with random boundaries
    function testFuzz_rangeQueries(address account, uint256 fromSeed, uint256 toSeed) public {
        vm.assume(account != address(0));
        
        uint256 assetCount = nav.getAssetCount();
        if (assetCount == 0) return; // Skip if no assets
        
        // Bound from and to to valid range
        uint256 from = bound(fromSeed, 0, assetCount - 1);
        uint256 to = bound(toSeed, from, assetCount - 1);
        
        // Get range NAV
        INAVCalculator.NAV memory rangeNav = nav.getAccountNavForRange(account, from, to, address(0));
        
        // Verify basic properties
        assertEq(rangeNav.timestamp, block.timestamp, "Timestamp should match");
        assertEq(rangeNav.quoteAsset.asset, address(0), "Quote asset should be USD");
        
        // Value should be reasonable
        assertTrue(rangeNav.value >= type(int128).min && rangeNav.value <= type(int128).max, "Value should be reasonable");
    }

    /// @notice Fuzz test for range query completeness
    function testFuzz_rangeQueries_completeness(address account, uint256 chunkSizeSeed) public {
        vm.assume(account != address(0));
        
        uint256 assetCount = nav.getAssetCount();
        if (assetCount == 0) return;
        
        // Get full NAV
        INAVCalculator.NAV memory fullNav = nav.getAccountNav(account, address(0));
        
        // Bound chunk size
        uint256 chunkSize = bound(chunkSizeSeed, 1, assetCount);
        
        // Split into chunks and sum
        int256 rangeSum = 0;
        for (uint256 i = 0; i < assetCount; i += chunkSize) {
            uint256 to = i + chunkSize - 1;
            if (to >= assetCount) {
                to = assetCount - 1;
            }
            
            INAVCalculator.NAV memory rangeNav = nav.getAccountNavForRange(account, i, to, address(0));
            rangeSum += rangeNav.value;
        }
        
        // Sum should equal full NAV (within rounding)
        assertApproxEqAbs(fullNav.value, rangeSum, 1, "Sum of ranges should equal full NAV");
    }

    // ============================================
    // Fuzz Tests for Edge Cases
    // ============================================

    /// @notice Fuzz test for very large balances
    function testFuzz_largeBalances(address account, uint256 amountSeed) public {
        vm.assume(account != address(0));
        vm.assume(account != address(nav));
        
        // Use uint96 to avoid overflow issues
        uint96 amount = uint96(bound(amountSeed, 1, type(uint96).max / 2));
        
        // Mint tokens
        usdc.mint(account, amount);
        
        // Should handle large balances without reverting
        INAVCalculator.NAV memory navResult = nav.getAccountNav(account, address(0));
        
        // Value should be positive
        assertGe(navResult.value, 0, "NAV should be non-negative");
    }

    /// @notice Test that an account with no balances returns no positions and zero NAV
    /// @dev Uses emptyAccount (address of a deployed contract that is never funded) so
    ///      we don't depend on fuzz input; arbitrary addresses may have balance in test env.
    function testFuzz_zeroBalances() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(emptyAccount, address(0));

        assertEq(positions.length, 0, "Zero balances should be excluded");

        INAVCalculator.NAV memory navResult = nav.getAccountNav(emptyAccount, address(0));
        assertEq(navResult.value, 0, "NAV should be zero for empty account");
    }
}
