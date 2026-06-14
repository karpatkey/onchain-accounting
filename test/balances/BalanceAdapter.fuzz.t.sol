// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultAdapter} from "src/balances/protocols/ERC20DefaultAdapter.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";

/// @title Balance Adapter Fuzz Tests
/// @notice Property-based fuzz tests for balance adapter adapters
contract BalanceAdapterFuzzTest is Test {
    BalancesHarness public balances;
    ERC20DefaultAdapter public erc20DefaultAdapter;
    Mock_CustomBalanceAdapter public customAdapter;
    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;

    address public alice;

    function setUp() public {
        // Etch NavRegistryLib (pre-linked external lib, DELEGATECALL'd by Balances) at its deterministic address.
        vm.etch(0xC1a8D82555aBB46bCdbFDe09E4B9aB6a862A18d1, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);
        balances = new BalancesHarness();
        erc20DefaultAdapter = balances.defaultAdapter();
        customAdapter = new Mock_CustomBalanceAdapter();
        customAdapter.setBalances(balances);

        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);

        balances.addSupportedAssetForTest(address(usdc));
        balances.addSupportedAssetForTest(address(dai));
        balances.addSupportedAssetForTest(balances.NATIVE_ADDRESS());

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        customAdapter.setUnderlyingAssetsSupported(assets);
        customAdapter.setPositionMetadata("Test Protocol", "Test Position");

        balances.addBalanceAdapterDirect(address(0), address(customAdapter), IBalances.AdapterType.Custom);

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
    // Fuzz Tests for getAdapterBalanceForAsset
    // ============================================

    /// @notice Fuzz test for getAdapterBalanceForAsset with random accounts and assets
    function testFuzz_getAdapterBalanceForAsset(address account, address asset, uint256 amountSeed) public {
        vm.assume(account != address(0));
        vm.assume(asset != address(0));

        // Bound amount to reasonable range (avoid overflow); minimum 1 so assertGt(amount2, 0) is valid
        uint96 amount = uint96(bound(amountSeed, 1, type(uint96).max / 2));

        // Try to get balance - should not revert
        (uint256 amount1,) = erc20DefaultAdapter.getAdapterBalanceForAsset(account, asset);

        // If asset is registered, mint tokens and check again
        if (asset == address(usdc) || asset == address(dai)) {
            if (asset == address(usdc)) {
                usdc.mint(account, amount);
            } else {
                dai.mint(account, amount);
            }

            (uint256 amount2, bool isDebt2) = erc20DefaultAdapter.getAdapterBalanceForAsset(account, asset);

            // Balance should have increased (and should still be credit/positive)
            assertGe(amount2, amount1, "Balance should increase after minting");
            assertFalse(isDebt2, "ERC20DefaultAdapter should return credit (not debt)");
            assertGt(amount2, 0, "ERC20DefaultAdapter should return positive amounts");
        }
    }

    /// @notice Fuzz test for getAdapterBalanceForAsset with custom adapter
    function testFuzz_getAdapterBalanceForAsset_customAdapter(
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

        // Set balance in custom adapter
        customAdapter.setBalance(asset, account, amount, isDebt);

        // Get balance - should match
        (uint256 retrievedAmount, bool retrievedIsDebt) = customAdapter.getAdapterBalanceForAsset(account, asset);
        assertEq(retrievedAmount, amount, "Amount should match");
        assertEq(retrievedIsDebt, isDebt, "isDebt should match");
    }

    /// @notice Fuzz test for getAdapterBalanceForAsset with debt positions
    function testFuzz_getAdapterBalanceForAsset_debtPositions(address account, uint256 amountSeed) public {
        vm.assume(account != address(0));

        // Bound amount
        uint256 amount = bound(amountSeed, 1, 1_000_000 * 10 ** usdc.decimals());

        // Set debt position (isDebt = true)
        customAdapter.setBalance(address(usdc), account, amount, true);

        // Get balance - should be debt
        (uint256 retrievedAmount, bool retrievedIsDebt) = customAdapter.getAdapterBalanceForAsset(account, address(usdc));
        assertEq(retrievedAmount, amount, "Amount should match");
        assertTrue(retrievedIsDebt, "Debt balance should have isDebt true");
    }

    // ============================================
    // Fuzz Tests for getAdapterPositions
    // ============================================

    /// @notice Fuzz test for getAdapterPositions with random accounts and asset filters
    function testFuzz_getAdapterPositions(address account, uint256 filterSeed) public view {
        vm.assume(account != address(0));

        // Get valid asset filter (or zero for all)
        address assetFilter = address(0);
        if (filterSeed % 3 == 0) {
            assetFilter = address(usdc);
        } else if (filterSeed % 3 == 1) {
            assetFilter = address(dai);
        }

        // Should not revert
        INAVCalculator.PositionBalance[] memory positions = erc20DefaultAdapter.getAdapterPositions(account, assetFilter);

        // Verify no zero amounts
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount != 0, "No zero amounts should be returned");

            // If filter is set, all positions should match filter
            if (assetFilter != address(0)) {
                assertEq(positions[i].balanceAsset.asset, assetFilter, "All positions should match filter");
            }
        }
    }

    /// @notice Fuzz test for getAdapterPositions with custom adapter
    function testFuzz_getAdapterPositions_customAdapter(address account, uint256 balanceSeed1, uint256 balanceSeed2)
        public
    {
        vm.assume(account != address(0));

        // Set random amounts (always positive, isDebt = false for credit positions)
        uint256 amount1 = bound(balanceSeed1, 1, 1_000_000 * 10 ** usdc.decimals());
        uint256 amount2 = bound(balanceSeed2, 0, 1_000_000 * 10 ** dai.decimals());

        customAdapter.setBalance(address(usdc), account, amount1, false);
        if (amount2 > 0) {
            customAdapter.setBalance(address(dai), account, amount2, false);
        }

        // Get positions
        INAVCalculator.PositionBalance[] memory positions = customAdapter.getAdapterPositions(account, address(0));

        // Should have at least one position (USDC)
        assertGe(positions.length, 1, "Should have at least one position");

        // Verify no zero amounts
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount != 0, "No zero amounts");
        }
    }

    // ============================================
    // Fuzz Tests for getAdapterBalance
    // ============================================

    /// @notice Fuzz test for getAdapterBalance with random accounts
    function testFuzz_getAdapterBalances(address account, uint256 amountSeed1, uint256 amountSeed2) public {
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
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            erc20DefaultAdapter.getAdapterBalances(account);

        // Arrays should have same length
        assertEq(assets.length, amounts.length, "Assets and amounts arrays should have same length");
        assertEq(amounts.length, isDebt.length, "Amounts and isDebt arrays should have same length");

        // Verify no zero amounts
        for (uint256 i = 0; i < amounts.length; i++) {
            assertTrue(amounts[i] != 0, "No zero amounts should be returned");
        }

        // Verify consistency with getAdapterPositions
        INAVCalculator.PositionBalance[] memory positions = erc20DefaultAdapter.getAdapterPositions(account, address(0));

        int256 positionsSum = sumPositionBalances(positions);
        int256 balanceSum = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (isDebt[i]) {
                balanceSum -= int256(amounts[i]);
            } else {
                balanceSum += int256(amounts[i]);
            }
        }

        assertEq(positionsSum, balanceSum, "Sum of positions should equal sum of balances");
    }

    // ============================================
    // Fuzz Tests for underlyingAssetsSupported
    // ============================================

    /// @notice Fuzz test for underlyingAssetsSupported consistency
    function testFuzz_underlyingAssetsSupported_consistency() public view {
        // Query multiple times - should be consistent
        address[] memory assets1 = erc20DefaultAdapter.underlyingAssetsSupported();
        address[] memory assets2 = erc20DefaultAdapter.underlyingAssetsSupported();
        address[] memory assets3 = erc20DefaultAdapter.underlyingAssetsSupported();

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

    /// @notice Fuzz test for underlyingAssetsSupported with custom adapter
    function testFuzz_underlyingAssetsSupported_customAdapter() public view {
        address[] memory assets = customAdapter.underlyingAssetsSupported();

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

        // Mint to ERC20DefaultAdapter
        usdc.mint(account, erc20Amount);

        // Set in custom adapter (credit position)
        customAdapter.setBalance(address(usdc), account, customAmount, false);

        // Get balances from both
        (uint256 erc20Amount_, bool erc20IsDebt) = erc20DefaultAdapter.getAdapterBalanceForAsset(account, address(usdc));
        (uint256 customAmount_, bool customIsDebt) = customAdapter.getAdapterBalanceForAsset(account, address(usdc));

        // Both should be credit positions (positive amount, not debt)
        assertGt(erc20Amount_, 0, "ERC20DefaultAdapter should return positive balance");
        assertFalse(erc20IsDebt, "ERC20DefaultAdapter should be credit");
        assertGt(customAmount_, 0, "Custom adapter should return positive balance");
        assertFalse(customIsDebt, "Custom adapter should be credit");

        // ERC20DefaultAdapter should match minted amount
        assertEq(erc20Amount_, erc20Amount, "ERC20DefaultAdapter should match minted amount");

        // Custom adapter should match set amount
        assertEq(customAmount_, customAmount, "Custom adapter should match set amount");
    }

    // ============================================
    // Fuzz Tests for Edge Cases
    // ============================================

    /// @notice Fuzz test for zero address account
    function testFuzz_zeroAddressAccount(address asset) public view {
        // Zero address should return zero balance
        (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(address(0), asset);
        assertEq(amount, 0, "Zero address should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultAdapter.getAdapterPositions(address(0), address(0));
        assertEq(positions.length, 0, "Zero address should return no positions");
    }

    /// @notice Fuzz test for unregistered asset
    function testFuzz_unregisteredAsset(address account, address unregisteredAsset) public view {
        vm.assume(account != address(0));
        vm.assume(unregisteredAsset != address(0));
        vm.assume(unregisteredAsset != address(usdc));
        vm.assume(unregisteredAsset != address(dai));
        vm.assume(unregisteredAsset != balances.NATIVE_ADDRESS());

        // Unregistered asset should return zero balance
        (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(account, unregisteredAsset);
        assertEq(amount, 0, "Unregistered asset should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultAdapter.getAdapterPositions(account, unregisteredAsset);
        assertEq(positions.length, 0, "Unregistered asset should return no positions");
    }

    /// @notice Fuzz test for very large balances
    function testFuzz_largeBalances(address account, uint256 amountSeed) public {
        vm.assume(account != address(0));

        // Use uint96 to avoid overflow
        uint96 amount = uint96(bound(amountSeed, 1, type(uint96).max / 2));

        usdc.mint(account, amount);

        // Should handle large balances without reverting
        (uint256 retrievedAmount, bool retrievedIsDebt) =
            erc20DefaultAdapter.getAdapterBalanceForAsset(account, address(usdc));
        assertEq(retrievedAmount, amount, "Should handle large balances");
        assertFalse(retrievedIsDebt, "Should be credit (not debt)");
    }
}
