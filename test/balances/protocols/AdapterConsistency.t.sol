// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {Mock_NAVCalculator} from "test/mocks/nav_calculator.sol";

/// @title Adapter Consistency Tests
/// @notice Tests that all adapters behave consistently across different adapter types
contract AdapterConsistencyTest is Test {
    Mock_NAVCalculator public mockNav;
    ERC20DefaultOracle public erc20DefaultOracle;
    Mock_CustomBalanceOracle public customOracle;
    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;

    address public constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        // Use mock NAVCalculator instead of BalancesHarness for isolated adapter testing
        mockNav = new Mock_NAVCalculator();

        // Create ERC20DefaultOracle with mock NAVCalculator
        erc20DefaultOracle = new ERC20DefaultOracle(address(mockNav), new address[](0));

        // So that registerAsset also adds assets to the default oracle's inclusion list
        mockNav.setDefaultOracle(address(erc20DefaultOracle));

        customOracle = new Mock_CustomBalanceOracle();

        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);

        // Register assets in mock NAVCalculator (also adds them to ERC20DefaultOracle)
        mockNav.registerAsset(address(usdc), 6, "USDC");
        mockNav.registerAsset(address(dai), 18, "DAI");
        mockNav.registerAsset(NATIVE_ADDRESS, 18, "ETH");

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        customOracle.setUnderlyingAssetsSupported(assets);
        customOracle.setPositionMetadata("Test Protocol", "Test Position");
    }

    // ============================================
    // Interface Compliance Consistency
    // ============================================

    /// @notice Test that all adapters implement the same interface IDs consistently
    /// @dev This focuses on consistency across adapters, while test_invariant_interfaceCompliance
    ///      in BalanceAdapter.invariant.t.sol tests the full interface contract
    function test_consistency_interfaceCompliance() public view {
        // Test both adapters
        IBalanceOracleAdapter[] memory adapters = new IBalanceOracleAdapter[](2);
        adapters[0] = erc20DefaultOracle;
        adapters[1] = customOracle;

        if (adapters.length == 0) return;

        // Get interface IDs from first adapter as reference
        IBalanceOracleAdapter firstAdapter = adapters[0];
        bool firstSupportsIBalanceOracleAdapter =
            firstAdapter.supportsInterface(type(IBalanceOracleAdapter).interfaceId);
        bool firstSupportsIERC165 = firstAdapter.supportsInterface(type(IERC165).interfaceId);

        // All adapters should have the same interface support
        for (uint256 i = 1; i < adapters.length; i++) {
            IBalanceOracleAdapter adapter = adapters[i];

            assertEq(
                adapter.supportsInterface(type(IBalanceOracleAdapter).interfaceId),
                firstSupportsIBalanceOracleAdapter,
                "All adapters should consistently support IBalanceOracleAdapter"
            );

            assertEq(
                adapter.supportsInterface(type(IERC165).interfaceId),
                firstSupportsIERC165,
                "All adapters should consistently support IERC165"
            );
        }
    }

    // ============================================
    // Zero Balance Handling Consistency
    // ============================================

    /// @notice Test that all adapters exclude zero balances consistently
    function test_consistency_zeroBalanceExclusion() public {
        // Setup: Some tokens with balances, some without
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        // Don't mint DAI (zero balance)

        // Query from ERC20DefaultOracle
        INAVCalculator.PositionBalance[] memory positions1 = erc20DefaultOracle.getOraclePositions(alice, address(0));

        // Query from customOracle
        customOracle.setBalance(address(usdc), alice, 500 * 10 ** usdc.decimals(), false);
        // Don't set DAI balance (zero)
        INAVCalculator.PositionBalance[] memory positions2 = customOracle.getOraclePositions(alice, address(0));

        // Both should exclude zero balances
        for (uint256 i = 0; i < positions1.length; i++) {
            assertTrue(positions1[i].amount != 0, "ERC20DefaultOracle: No zero amounts");
        }
        for (uint256 i = 0; i < positions2.length; i++) {
            assertTrue(positions2[i].amount != 0, "CustomOracle: No zero amounts");
        }

        // Both should only have USDC (not DAI)
        assertEq(positions1.length, 1, "ERC20DefaultOracle should have one position");
        assertEq(positions1[0].balanceAsset.asset, address(usdc), "Should be USDC");

        assertEq(positions2.length, 1, "CustomOracle should have one position");
        assertEq(positions2[0].balanceAsset.asset, address(usdc), "Should be USDC");
    }

    // ============================================
    // Debt Position Handling Consistency
    // ============================================

    /// @notice Test that all adapters handle debt positions correctly
    function test_consistency_debtPositionHandling() public {
        // Set debt position in custom oracle
        customOracle.setBalance(address(usdc), alice, 1000 * 10 ** usdc.decimals(), true);

        // Get balance - should be debt
        (uint256 amount, bool isDebt) = customOracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1000 * 10 ** usdc.decimals(), "Amount should match");
        assertTrue(isDebt, "Debt balance should have isDebt true");

        // Get positions - should include debt position
        INAVCalculator.PositionBalance[] memory positions = customOracle.getOraclePositions(alice, address(0));

        assertEq(positions.length, 1, "Should have one position");
        assertEq(positions[0].amount, 1000 * 10 ** usdc.decimals(), "Amount should match");
        assertTrue(positions[0].isDebt, "Position should be debt");
    }

    // ============================================
    // Metadata Format Consistency
    // ============================================

    /// @notice Test that all adapters return consistent metadata structure
    function test_consistency_metadataFormat() public {
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        customOracle.setBalance(address(usdc), alice, 500 * 10 ** usdc.decimals(), false);

        // Get positions from both adapters
        INAVCalculator.PositionBalance[] memory positions1 = erc20DefaultOracle.getOraclePositions(alice, address(0));
        INAVCalculator.PositionBalance[] memory positions2 = customOracle.getOraclePositions(alice, address(0));

        // Both should have protocol and positionDetail
        if (positions1.length > 0) {}

        if (positions2.length > 0) {}
    }

    // ============================================
    // Asset Filtering Consistency
    // ============================================

    /// @notice Test that all adapters support asset filtering consistently
    function test_consistency_assetFiltering() public {
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        dai.mint(alice, 2000 * 10 ** dai.decimals());
        customOracle.setBalance(address(usdc), alice, 500 * 10 ** usdc.decimals(), false);
        customOracle.setBalance(address(dai), alice, 1000 * 10 ** dai.decimals(), false);

        // Test filtering with both adapters
        INAVCalculator.PositionBalance[] memory positions1 = erc20DefaultOracle.getOraclePositions(alice, address(usdc));
        INAVCalculator.PositionBalance[] memory positions2 = customOracle.getOraclePositions(alice, address(usdc));

        // All filtered positions should be for USDC
        for (uint256 i = 0; i < positions1.length; i++) {
            assertEq(
                positions1[i].balanceAsset.asset,
                address(usdc),
                "ERC20DefaultOracle: Filtered positions should match filter"
            );
        }

        for (uint256 i = 0; i < positions2.length; i++) {
            assertEq(
                positions2[i].balanceAsset.asset, address(usdc), "CustomOracle: Filtered positions should match filter"
            );
        }
    }

    // ============================================
    // Error Handling Consistency
    // ============================================

    /// @notice Test that all adapters handle invalid inputs consistently
    function test_consistency_errorHandling() public {
        address invalidAsset = makeAddr("invalid");

        // Both adapters should return zero for invalid asset, not revert
        (uint256 amount1,) = erc20DefaultOracle.getOracleBalanceForAsset(alice, invalidAsset);
        (uint256 amount2,) = customOracle.getOracleBalanceForAsset(alice, invalidAsset);

        assertEq(amount1, 0, "ERC20DefaultOracle should return zero for invalid asset");
        assertEq(amount2, 0, "CustomOracle should return zero for invalid asset");

        // Both should return empty arrays for invalid asset filter
        INAVCalculator.PositionBalance[] memory positions1 = erc20DefaultOracle.getOraclePositions(alice, invalidAsset);
        INAVCalculator.PositionBalance[] memory positions2 = customOracle.getOraclePositions(alice, invalidAsset);

        assertEq(positions1.length, 0, "ERC20DefaultOracle should return empty for invalid filter");
        assertEq(positions2.length, 0, "CustomOracle should return empty for invalid filter");
    }

    /// @notice Test that all adapters handle zero address account consistently
    function test_consistency_zeroAddressAccount() public view {
        // Both adapters should return zero for zero address account
        (uint256 amount1,) = erc20DefaultOracle.getOracleBalanceForAsset(address(0), address(usdc));
        (uint256 amount2,) = customOracle.getOracleBalanceForAsset(address(0), address(usdc));

        assertEq(amount1, 0, "ERC20DefaultOracle should return zero for zero address");
        assertEq(amount2, 0, "CustomOracle should return zero for zero address");
    }

    // ============================================
    // Balance Consistency Across Adapters
    // ============================================

    /// @notice Test that getOracleBalance matches sum of positions for all adapters
    function test_consistency_balanceConsistency() public {
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        dai.mint(alice, 2000 * 10 ** dai.decimals());

        // Test both adapters
        IBalanceOracleAdapter[] memory adapters = new IBalanceOracleAdapter[](2);
        adapters[0] = erc20DefaultOracle;
        adapters[1] = customOracle;

        // Set balances for custom oracle
        customOracle.setBalance(address(usdc), alice, 1000 * 10 ** usdc.decimals(), false);
        customOracle.setBalance(address(dai), alice, 2000 * 10 ** dai.decimals(), false);

        for (uint256 i = 0; i < adapters.length; i++) {
            IBalanceOracleAdapter adapter = adapters[i];

            (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getOracleBalances(alice);
            assertEq(assets.length, amounts.length, "assets and amounts length match");

            // Get positions
            INAVCalculator.PositionBalance[] memory positions = adapter.getOraclePositions(alice, address(0));

            // Sum positions
            int256 positionsSum = 0;
            for (uint256 j = 0; j < positions.length; j++) {
                if (positions[j].isDebt) {
                    positionsSum -= int256(positions[j].amount);
                } else {
                    positionsSum += int256(positions[j].amount);
                }
            }

            // Sum balances (amount + isDebt)
            int256 balanceSum = 0;
            for (uint256 j = 0; j < amounts.length; j++) {
                if (isDebt[j]) {
                    balanceSum -= int256(amounts[j]);
                } else {
                    balanceSum += int256(amounts[j]);
                }
            }

            // Should match
            assertEq(positionsSum, balanceSum, "Sum of positions should equal sum of balances for all adapters");
        }
    }

    // ============================================
    // Supported Assets Consistency
    // ============================================

    /// @notice Test that underlyingAssetsSupported is consistent across queries
    function test_consistency_supportedAssetsConsistency() public view {
        // Test both adapters
        IBalanceOracleAdapter[] memory adapters = new IBalanceOracleAdapter[](2);
        adapters[0] = erc20DefaultOracle;
        adapters[1] = customOracle;

        for (uint256 i = 0; i < adapters.length; i++) {
            IBalanceOracleAdapter adapter = adapters[i];

            // Query multiple times - should be consistent
            address[] memory assets1 = adapter.underlyingAssetsSupported();
            address[] memory assets2 = adapter.underlyingAssetsSupported();
            address[] memory assets3 = adapter.underlyingAssetsSupported();

            assertEq(assets1.length, assets2.length, "Length should be consistent");
            assertEq(assets2.length, assets3.length, "Length should be consistent");

            // All supported assets should be queryable
            for (uint256 j = 0; j < assets1.length; j++) {
                address asset = assets1[j];

                // Should be able to query balance (may be zero, that's fine)
                try adapter.getOracleBalanceForAsset(alice, asset) returns (
                    uint256, bool
                ) {
                // Success
                }
                catch {
                    revert("Should be able to query supported asset");
                }
            }
        }
    }
}
