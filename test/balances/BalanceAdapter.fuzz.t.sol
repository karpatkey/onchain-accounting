// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";

/// @title Balance Adapter Fuzz Tests
/// @notice Property-based fuzz tests for balance oracle adapters
contract BalanceAdapterFuzzTest is Test {
    BalancesHarness public balances;
    ERC20DefaultOracle public erc20DefaultOracle;
    Mock_CustomBalanceOracle public customOracle;
    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;

    address public alice;

    function setUp() public {
        balances = new BalancesHarness();
        erc20DefaultOracle = balances.defaultOracle();
        customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalances(balances);

        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);

        balances.registerAssetForTest(address(usdc), 6);
        balances.registerAssetForTest(address(dai), 18);
        balances.registerAssetForTest(balances.NATIVE_ADDRESS(), 18);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        customOracle.setUnderlyingAssetsSupported(assets);
        customOracle.setPositionMetadata("Test Protocol", "Test Position");

        balances.addBalanceOracleDirect(address(0), address(customOracle), IBalances.OracleType.Custom);

        alice = makeAddr("alice");
    }

    /// @notice Helper to sum balances from positions
    function sumPositionBalances(INAVCalculator.PositionBalance[] memory positions) internal pure returns (int256) {
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            // Sum amounts (debt positions are negative in NAV calculation)
            if (positions[i].isDebt) {
                sum -= int256(positions[i].amount);
            } else {
                sum += int256(positions[i].amount);
            }
        }
        return sum;
    }

    // ============================================
    // Fuzz Tests for getOracleBalanceForAsset
    // ============================================

    /// @notice Fuzz test for getOracleBalanceForAsset with random accounts and assets
    function testFuzz_getOracleBalanceForAsset(address account, address asset, uint256 amountSeed) public {
        vm.assume(account != address(0));
        vm.assume(asset != address(0));

        // Bound amount to reasonable range (avoid overflow)
        uint96 amount = uint96(bound(amountSeed, 0, type(uint96).max / 2));

        // Try to get balance - should not revert
        int256 balance1 = erc20DefaultOracle.getOracleBalanceForAsset(account, asset);

        // If asset is registered, mint tokens and check again
        if (asset == address(usdc) || asset == address(dai)) {
            if (asset == address(usdc)) {
                usdc.mint(account, amount);
            } else {
                dai.mint(account, amount);
            }

            int256 balance2 = erc20DefaultOracle.getOracleBalanceForAsset(account, asset);

            // Balance should have increased (and should still be credit/positive)
            assertGe(balance2, balance1, "Balance should increase after minting");
            assertGt(balance2, 0, "ERC20DefaultOracle should return positive balances");
        }
    }

    /// @notice Fuzz test for getOracleBalanceForAsset with custom oracle
    function testFuzz_getOracleBalanceForAsset_customOracle(
        address account,
        uint256 assetSeed,
        uint256 amountSeed,
        bool isDebtSeed
    ) public {
        vm.assume(account != address(0));

        // Bound asset selection
        address asset = assetSeed % 2 == 0 ? address(usdc) : address(dai);

        // Bound amount to reasonable range
        uint256 amount = bound(amountSeed, 1, type(uint96).max);
        // Use isDebtSeed directly
        bool isDebt = isDebtSeed;

        // Set balance in custom oracle
        customOracle.setBalance(asset, account, amount, isDebt);

        // Get balance - should match
        int256 retrievedBalance = customOracle.getOracleBalanceForAsset(account, asset);
        if (isDebt) {
            assertEq(retrievedBalance, -int256(amount), "Debt balance should be negative");
        } else {
            assertEq(retrievedBalance, int256(amount), "Credit balance should be positive");
        }
    }

    /// @notice Fuzz test for getOracleBalanceForAsset with debt positions
    function testFuzz_getOracleBalanceForAsset_debtPositions(address account, uint256 amountSeed) public {
        vm.assume(account != address(0));

        // Bound amount
        uint256 amount = bound(amountSeed, 1, 1_000_000 * 10 ** usdc.decimals());

        // Set debt position (isDebt = true)
        customOracle.setBalance(address(usdc), account, amount, true);

        // Get balance - should be debt (negative)
        int256 retrievedBalance = customOracle.getOracleBalanceForAsset(account, address(usdc));
        assertEq(retrievedBalance, -int256(amount), "Debt balance should be negative");
    }

    // ============================================
    // Fuzz Tests for getOraclePositions
    // ============================================

    /// @notice Fuzz test for getOraclePositions with random accounts and asset filters
    function testFuzz_getOraclePositions(address account, uint256 filterSeed) public {
        vm.assume(account != address(0));

        // Get valid asset filter (or zero for all)
        address assetFilter = address(0);
        if (filterSeed % 3 == 0) {
            assetFilter = address(usdc);
        } else if (filterSeed % 3 == 1) {
            assetFilter = address(dai);
        }

        // Should not revert
        INAVCalculator.PositionBalance[] memory positions = erc20DefaultOracle.getOraclePositions(account, assetFilter);

        // Verify no zero amounts
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount != 0, "No zero amounts should be returned");

            // If filter is set, all positions should match filter
            if (assetFilter != address(0)) {
                assertEq(positions[i].underlyingAsset.asset, assetFilter, "All positions should match filter");
            }
        }
    }

    /// @notice Fuzz test for getOraclePositions with custom oracle
    function testFuzz_getOraclePositions_customOracle(address account, uint256 balanceSeed1, uint256 balanceSeed2)
        public
    {
        vm.assume(account != address(0));

        // Set random amounts (always positive, isDebt = false for credit positions)
        uint256 amount1 = bound(balanceSeed1, 1, 1_000_000 * 10 ** usdc.decimals());
        uint256 amount2 = bound(balanceSeed2, 0, 1_000_000 * 10 ** dai.decimals());

        customOracle.setBalance(address(usdc), account, amount1, false);
        if (amount2 > 0) {
            customOracle.setBalance(address(dai), account, amount2, false);
        }

        // Get positions
        INAVCalculator.PositionBalance[] memory positions = customOracle.getOraclePositions(account, address(0));

        // Should have at least one position (USDC)
        assertGe(positions.length, 1, "Should have at least one position");

        // Verify no zero amounts
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount != 0, "No zero amounts");
        }
    }

    // ============================================
    // Fuzz Tests for getOracleBalance
    // ============================================

    /// @notice Fuzz test for getOracleBalance with random accounts
    function testFuzz_getOracleBalance(address account, uint256 amountSeed1, uint256 amountSeed2) public {
        vm.assume(account != address(0));

        // Bound amounts
        uint256 amount1 = bound(amountSeed1, 0, 1_000_000 * 10 ** usdc.decimals());
        uint256 amount2 = bound(amountSeed2, 0, 1_000_000 * 10 ** dai.decimals());

        // Mint tokens if amounts > 0
        if (amount1 > 0) {
            usdc.mint(account, amount1);
        }
        if (amount2 > 0) {
            dai.mint(account, amount2);
        }

        // Get balance
        (address[] memory assets, int256[] memory balances) = erc20DefaultOracle.getOracleBalance(account);

        // Arrays should have same length
        assertEq(assets.length, balances.length, "Assets and balances arrays should have same length");

        // Verify no zero balances
        for (uint256 i = 0; i < balances.length; i++) {
            assertTrue(balances[i] != 0, "No zero balances should be returned");
        }

        // Verify consistency with getOraclePositions
        INAVCalculator.PositionBalance[] memory positions = erc20DefaultOracle.getOraclePositions(account, address(0));

        int256 positionsSum = sumPositionBalances(positions);
        int256 balanceSum = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            balanceSum += balances[i];
        }

        assertEq(positionsSum, balanceSum, "Sum of positions should equal sum of balances");
    }

    // ============================================
    // Fuzz Tests for underlyingAssetsSupported
    // ============================================

    /// @notice Fuzz test for underlyingAssetsSupported consistency
    function testFuzz_underlyingAssetsSupported_consistency() public {
        // Query multiple times - should be consistent
        address[] memory assets1 = erc20DefaultOracle.underlyingAssetsSupported();
        address[] memory assets2 = erc20DefaultOracle.underlyingAssetsSupported();
        address[] memory assets3 = erc20DefaultOracle.underlyingAssetsSupported();

        // Should all be same length
        assertEq(assets1.length, assets2.length, "Length should be consistent");
        assertEq(assets2.length, assets3.length, "Length should be consistent");

        // Should all have same assets (order may vary, but content should match)
        for (uint256 i = 0; i < assets1.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < assets2.length; j++) {
                if (assets1[i] == assets2[j]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Assets should be consistent");
        }
    }

    /// @notice Fuzz test for underlyingAssetsSupported with custom oracle
    function testFuzz_underlyingAssetsSupported_customOracle() public view {
        address[] memory assets = customOracle.underlyingAssetsSupported();

        // Should have 2 assets (USDC and DAI)
        assertEq(assets.length, 2, "Should have 2 supported assets");

        // Verify assets are USDC and DAI
        bool foundUsdc = false;
        bool foundDai = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(usdc)) foundUsdc = true;
            if (assets[i] == address(dai)) foundDai = true;
        }
        assertTrue(foundUsdc, "Should support USDC");
        assertTrue(foundDai, "Should support DAI");
    }

    // ============================================
    // Fuzz Tests for Balance Aggregation
    // ============================================

    /// @notice Fuzz test for balance aggregation across multiple adapters
    function testFuzz_balanceAggregation_multipleAdapters(address account, uint256 erc20Amount, uint256 customAmount)
        public
    {
        vm.assume(account != address(0));

        // Bound amounts
        erc20Amount = bound(erc20Amount, 1, 1_000_000 * 10 ** usdc.decimals());
        customAmount = bound(customAmount, 1, 1_000_000 * 10 ** usdc.decimals());

        // Mint to ERC20DefaultOracle
        usdc.mint(account, erc20Amount);

        // Set in custom oracle (credit position)
        customOracle.setBalance(address(usdc), account, customAmount, false);

        // Get balances from both
        int256 erc20Balance = erc20DefaultOracle.getOracleBalanceForAsset(account, address(usdc));
        int256 customBalance = customOracle.getOracleBalanceForAsset(account, address(usdc));

        // Both should be credit positions (positive)
        assertGt(erc20Balance, 0, "ERC20DefaultOracle should return positive balance");
        assertGt(customBalance, 0, "Custom oracle should return positive balance");

        // ERC20DefaultOracle should match minted amount
        assertEq(uint256(erc20Balance), erc20Amount, "ERC20DefaultOracle should match minted amount");

        // Custom oracle should match set amount
        assertEq(uint256(customBalance), customAmount, "Custom oracle should match set amount");
    }

    // ============================================
    // Fuzz Tests for Edge Cases
    // ============================================

    /// @notice Fuzz test for zero address account
    function testFuzz_zeroAddressAccount(address asset) public {
        // Zero address should return zero balance
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(address(0), asset);
        assertEq(balance, 0, "Zero address should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultOracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0, "Zero address should return no positions");
    }

    /// @notice Fuzz test for unregistered asset
    function testFuzz_unregisteredAsset(address account, address unregisteredAsset) public {
        vm.assume(account != address(0));
        vm.assume(unregisteredAsset != address(0));
        vm.assume(unregisteredAsset != address(usdc));
        vm.assume(unregisteredAsset != address(dai));
        vm.assume(unregisteredAsset != balances.NATIVE_ADDRESS());

        // Unregistered asset should return zero balance
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(account, unregisteredAsset);
        assertEq(balance, 0, "Unregistered asset should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultOracle.getOraclePositions(account, unregisteredAsset);
        assertEq(positions.length, 0, "Unregistered asset should return no positions");
    }

    /// @notice Fuzz test for very large balances
    function testFuzz_largeBalances(address account, uint256 amountSeed) public {
        vm.assume(account != address(0));

        // Use uint96 to avoid overflow
        uint96 amount = uint96(bound(amountSeed, 1, type(uint96).max / 2));

        usdc.mint(account, amount);

        // Should handle large balances without reverting
        int256 retrievedBalance = erc20DefaultOracle.getOracleBalanceForAsset(account, address(usdc));
        assertEq(uint256(retrievedBalance), amount, "Should handle large balances");
        assertGt(retrievedBalance, 0, "Should be positive balance");
    }
}
