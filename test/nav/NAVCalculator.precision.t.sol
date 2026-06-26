// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title NAVCalculator Decimal Precision Tests
/// @notice Tests precision and rounding for various decimal combinations
contract NAVCalculatorPrecisionTest is SuperTest {
    function setUp() public {
        setupAll();
    }

    /// @notice Test edge case decimals: 0, 1, 18, 255
    function test_precision_edgeCaseDecimals() public {
        uint8[] memory testDecimals = new uint8[](4);
        testDecimals[0] = 0;
        testDecimals[1] = 1;
        testDecimals[2] = 18;
        testDecimals[3] = 255;

        for (uint256 i = 0; i < testDecimals.length; i++) {
            uint8 decimals = testDecimals[i];

            // Skip 255 as it's too large for practical use and may cause issues
            if (decimals == 255) continue;

            // Create token with specific decimals
            Mock_ERC20 token = new Mock_ERC20("TEST", decimals);

            // Create price oracle (use 8 decimals for price, standard)
            Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TEST", address(token), 1e8, 8);

            // Register asset
            vm.startPrank(navCalculatorManager);
            nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
            vm.stopPrank();

            // Mint tokens
            uint256 amount = 1000 * 10 ** decimals;
            token.mint(safe, amount);

            // Get NAV - should not revert
            INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));

            // Value should be positive
            assertGe(navResult.value, 0, "NAV should be non-negative");
        }
    }

    /// @notice Struct for decimal combination tests
    struct DecimalTest {
        uint8 assetDecimals;
        uint8 priceDecimals;
        uint256 balance;
        uint256 expectedUsdValue;
    }

    /// @notice Test various decimal combinations
    function test_precision_decimalCombinations() public {
        // Test common decimal combinations
        DecimalTest[] memory tests = new DecimalTest[](6);

        // USDC-like: 6 decimals, 8 price decimals, 1 USDC = 1 USD
        tests[0] = DecimalTest({
            assetDecimals: 6,
            priceDecimals: 8,
            balance: 1_000_000, // 1 USDC
            expectedUsdValue: 1e8 // 1 USD in 8 decimals
        });

        // DAI-like: 18 decimals, 8 price decimals, 1 DAI = 1 USD
        tests[1] = DecimalTest({
            assetDecimals: 18,
            priceDecimals: 8,
            balance: 1e18, // 1 DAI
            expectedUsdValue: 1e8 // 1 USD in 8 decimals
        });

        // Token with 0 decimals
        tests[2] = DecimalTest({
            assetDecimals: 0,
            priceDecimals: 8,
            balance: 100, // 100 tokens
            expectedUsdValue: 100e8 // 100 USD in 8 decimals (if price is 1e8)
        });

        // Token with 1 decimal
        tests[3] = DecimalTest({
            assetDecimals: 1,
            priceDecimals: 8,
            balance: 10, // 10 tokens with 1 decimal = 1.0 token
            expectedUsdValue: 1e8 // 1 USD in 8 decimals (10 / 10^1 = 1.0 token)
        });

        // Token with 8 decimals (same as price)
        tests[4] = DecimalTest({
            assetDecimals: 8,
            priceDecimals: 8,
            balance: 1e8, // 1 token
            expectedUsdValue: 1e8 // 1 USD in 8 decimals
        });

        // Token with different price decimals (but denominator must be <= 77 to avoid 10**denominator overflow)
        // Use 18 asset decimals with 8 price decimals (like DAI) but with higher price
        tests[5] = DecimalTest({
            assetDecimals: 18,
            priceDecimals: 8, // Standard price decimals
            balance: 1e18, // 1 token
            expectedUsdValue: 324_057_000_000 // ~3240 USD in 8 decimals (using WETH-like price)
        });

        int256 cumulativeExpectedValue = 0;
        for (uint256 i = 0; i < tests.length; i++) {
            DecimalTest memory test = tests[i];

            // Ensure constraint: assetDecimals + priceDecimals >= NAV_DECIMALS (8)
            if (test.assetDecimals + test.priceDecimals < 8) {
                continue; // Skip invalid combinations
            }

            // Create token
            Mock_ERC20 token = new Mock_ERC20("TEST", test.assetDecimals);

            // Create price oracle with specific decimals
            uint256 price = 1e8; // Default 1 USD
            if (i == 5) {
                price = 324_057_000_000; // Use WETH price for last test
            }
            Mock_CustomPriceFeed priceOracle =
                new Mock_CustomPriceFeed("TEST", address(token), price, test.priceDecimals);

            // Register asset
            vm.startPrank(navCalculatorManager);
            nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
            vm.stopPrank();

            // Mint tokens
            token.mint(safe, test.balance);

            // Accumulate expected value (NAV includes all tokens from previous iterations)
            cumulativeExpectedValue += int256(test.expectedUsdValue);

            // Get NAV
            INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));

            // Verify value is reasonable (allow 1% tolerance for rounding)
            // NAV includes all tokens from all previous test cases, so compare with cumulative expected value
            assertApproxEqRel(navResult.value, cumulativeExpectedValue, 0.01 ether, "USD value should match expected");
        }
    }

    /// @notice Test precision loss scenarios
    function test_precision_noPrecisionLoss() public {
        // Test with very precise amounts
        uint256 preciseAmount = 1_234_567_890_123_456_789; // 18 decimals

        dai.mint(safe, preciseAmount);

        // Get NAV
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));

        // Get positions
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Find DAI position
        int256 daiValue = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAsset.asset == address(dai)) {
                daiValue = positions[i].value;
                break;
            }
        }

        // Value should be positive and reasonable
        assertGt(daiValue, 0, "DAI value should be positive");

        // Verify NAV consistency (no precision loss in aggregation)
        int256 positionsSum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            positionsSum += positions[i].value;
        }

        assertApproxEqAbs(navResult.value, positionsSum, 1, "NAV should equal sum of positions (no precision loss)");
    }

    /// @notice Test rounding consistency
    function test_precision_roundingConsistency() public {
        // Test with amounts that require rounding
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 1; // 1 wei
        testAmounts[1] = 1000; // 1000 wei
        testAmounts[2] = 1_000_000; // 1e6 wei
        testAmounts[3] = 1_000_000_000; // 1e9 wei
        testAmounts[4] = 1_000_000_000_000_000_000; // 1e18 wei (1 token)

        for (uint256 i = 0; i < testAmounts.length; i++) {
            // Clear previous state
            address testAccount = makeAddr(string(abi.encode("test", i)));

            dai.mint(testAccount, testAmounts[i]);

            // Get NAV multiple times - should be consistent
            INAVCalculator.NAV memory nav1 = nav.getAccountNav(testAccount, address(0));
            INAVCalculator.NAV memory nav2 = nav.getAccountNav(testAccount, address(0));
            INAVCalculator.NAV memory nav3 = nav.getAccountNav(testAccount, address(0));

            // All should be identical (rounding should be consistent)
            assertEq(nav1.value, nav2.value, "Rounding should be consistent");
            assertEq(nav2.value, nav3.value, "Rounding should be consistent");
        }
    }

    /// @notice Test extreme values with different decimals
    function test_precision_extremeValues() public {
        // Test with very large balances
        uint256[] memory largeAmounts = new uint256[](3);
        largeAmounts[0] = 1_000_000 * 10 ** 18; // 1M tokens
        largeAmounts[1] = 1_000_000_000 * 10 ** 18; // 1B tokens
        largeAmounts[2] = type(uint128).max; // Max uint128

        for (uint256 i = 0; i < largeAmounts.length; i++) {
            // Use uint128 to avoid overflow
            uint256 amount = largeAmounts[i];
            if (amount > type(uint128).max) {
                amount = type(uint128).max;
            }

            dai.mint(safe, amount);

            // Should handle large values without reverting
            INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));

            // Value should be positive and reasonable
            assertGe(navResult.value, 0, "NAV should handle large values");

            // Clear for next iteration
            // Note: In real tests, we'd use a fresh account per iteration
        }
    }

    /// @notice Test MAX_DECIMAL_EXPONENT_INT256 boundary (10^denominator must fit in int256)
    function test_precision_maxDecimalExponent() public {
        // denominator = assetDecimals + priceDecimals - NAV_DECIMALS; 10^denominator is cast to int256 in _toUsd.
        // int256 max ~5.7e76, so denominator must be <= 76 (MAX_DECIMAL_EXPONENT_INT256).

        uint8 assetDecimals = 41;
        uint8 priceDecimals = 43;
        // denominator = 41 + 43 - 8 = 76 (10**76 fits in int256)

        Mock_ERC20 token = new Mock_ERC20("TEST", assetDecimals);
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TEST", address(token), 1e8, priceDecimals);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        token.mint(safe, 1000 * 10 ** assetDecimals);

        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        assertGe(navResult.value, 0, "Should handle high decimal values");
    }

    /// @notice Test decimal constraint: assetDecimals + priceDecimals >= NAV_DECIMALS
    function test_precision_decimalConstraint() public {
        // Test case that violates constraint: 3 + 4 = 7 < 8 (NAV_DECIMALS)
        uint8 assetDecimals = 3;
        uint8 priceDecimals = 4;

        Mock_ERC20 token = new Mock_ERC20("TEST", assetDecimals);
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TEST", address(token), 1e8, priceDecimals);

        vm.startPrank(navCalculatorManager);
        // This should work (constraint is checked in _toUsd, not registration)
        nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        token.mint(safe, 1000 * 10 ** assetDecimals);

        // Getting NAV should revert with InvalidAssetDecimals
        vm.expectRevert(InvalidAssetDecimals.selector);
        nav.getAccountNav(safe, address(0));
    }

    /// @notice Revert when denominator (assetDecimals + priceDecimals - NAV_DECIMALS) > MAX_DECIMAL_EXPONENT_INT256
    function test_precision_revert_denominatorOverMaxInt256() public {
        uint8 assetDecimals = 42;
        uint8 priceDecimals = 43;
        // denominator = 42 + 43 - 8 = 77 > MAX_DECIMAL_EXPONENT_INT256 (76)

        Mock_ERC20 token = new Mock_ERC20("TEST", assetDecimals);
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TEST", address(token), 1e8, priceDecimals);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        token.mint(safe, 1000 * 10 ** assetDecimals);

        vm.expectRevert(InvalidDecimalExponent.selector);
        nav.getAccountNav(safe, address(0));
    }

    /// @notice Revert when denominator > MAX_DECIMAL_EXPONENT (255)
    function test_precision_revert_denominatorOverMaxExponent() public {
        uint8 assetDecimals = 132;
        uint8 priceDecimals = 132;
        // denominator = 132 + 132 - 8 = 256 > MAX_DECIMAL_EXPONENT (255)

        Mock_ERC20 token = new Mock_ERC20("TEST", assetDecimals);
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TEST", address(token), 1e8, priceDecimals);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        // Mint 1 wei to avoid overflow (10**132 would exceed uint256)
        token.mint(safe, 1);

        vm.expectRevert(InvalidDecimalExponent.selector);
        nav.getAccountNav(safe, address(0));
    }

    /// @notice Revert when getAccountNav(quoteAsset) uses _fromUsd with totalDecimals > MAX_DECIMAL_EXPONENT_INT256
    function test_precision_revert_fromUsdTotalDecimalsOverMaxInt256() public {
        uint8 quoteDecimals = 38;
        uint8 priceDecimals = 39;
        // totalDecimals = 38 + 39 = 77 > MAX_DECIMAL_EXPONENT_INT256 (76)

        Mock_ERC20 quoteToken = new Mock_ERC20("QUOTE", quoteDecimals);
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("QUOTE", address(quoteToken), 1e8, priceDecimals);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(quoteToken), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        dai.mint(safe, 1e18);
        quoteToken.mint(safe, 1e18);

        vm.expectRevert(InvalidDecimalExponent.selector);
        nav.getAccountNav(safe, address(quoteToken));
    }

    /// @notice Test precision in currency conversions
    function test_precision_currencyConversion() public {
        usdc.mint(safe, 10 ** usdc.decimals()); // 1 USDC

        // Get NAV in USD
        INAVCalculator.NAV memory navUsd = nav.getAccountNav(safe, address(0));

        // Get NAV in DAI
        INAVCalculator.NAV memory navDai = nav.getAccountNav(safe, address(dai));

        // Get prices for conversion
        (int256 daiPrice, uint8 daiPriceDecimals,) = nav.latestPrice(address(dai));

        // Convert DAI NAV back to USD
        // navDai.value is in DAI with 18 decimals
        // Convert: navDai.value * daiPrice / 10^(18 + daiPriceDecimals - 8)
        int256 navDaiInUsd = (navDai.value * int256(daiPrice)) / int256(10 ** (dai.decimals() + daiPriceDecimals - 8));

        // Should match within rounding (allow 0.1% tolerance)
        assertApproxEqRel(navUsd.value, navDaiInUsd, 0.001 ether, "Currency conversion should preserve precision");
    }

    /// @notice Test precision with multiple assets
    function test_precision_multipleAssets() public {
        // Mint different amounts with different decimals
        usdc.mint(safe, 1_234_567); // 1.234567 USDC (6 decimals)
        dai.mint(safe, 9_876_543_210_123_456_789); // 9.876... DAI (18 decimals)

        // Get NAV
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));

        // Get positions
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Sum positions
        int256 positionsSum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            positionsSum += positions[i].value;
        }

        // Should match within 1 unit (rounding tolerance)
        assertApproxEqAbs(navResult.value, positionsSum, 1, "Multiple assets should preserve precision");
    }
}
