// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {Balances} from "src/balances/Balances.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IPrices} from "src/prices/IPrices.sol";

/// @title TestSetupHelpers
/// @notice Helper functions for consistent test setup patterns
/// @dev Provides utilities for safe oracle access, price feed setup, and balance oracle setup
abstract contract TestSetupHelpers is Test {
    // ============================================
    // Safe Oracle Access Helpers
    // ============================================

    /// @notice Safely gets a balance oracle at a specific index
    /// @param balances The Balances contract instance
    /// @param asset The asset address
    /// @param idx The oracle index
    /// @return oracle The oracle address
    /// @return exists Whether the oracle exists at that index
    function safeGetBalanceOracle(Balances balances, address asset, uint256 idx)
        internal
        view
        returns (address oracle, bool exists)
    {
        uint256 count = balances.balanceOracleCountFor(asset);
        if (idx >= count) {
            return (address(0), false);
        }
        (oracle,) = balances.balanceOracleAt(asset, idx);
        exists = oracle != address(0);
    }

    /// @notice Safely checks if a price oracle exists for an asset
    /// @param nav The NAVCalculator contract instance
    /// @param asset The asset address
    /// @return oracle The oracle address (address(0) if not set)
    /// @return exists Whether a price oracle exists
    function safeGetPriceOracle(NAVCalculator nav, address asset) internal view returns (address oracle, bool exists) {
        (oracle,,,) = nav.priceOracles(asset);
        exists = oracle != address(0);
    }

    // ============================================
    // Price Feed Setup Helpers
    // ============================================

    /// @notice Ensures a price feed is set up for an asset (registers asset if needed)
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param asset The asset address
    /// @param priceOracle The price oracle address
    /// @param priceType The price type (Chainlink or Custom)
    /// @param heartbeat The chainlink heartbeat (or max uint for custom)
    function ensurePriceFeed(
        NAVCalculator nav,
        address manager,
        address asset,
        address priceOracle,
        IPrices.PriceType priceType,
        uint256 heartbeat
    ) internal {
        // Register asset with price feed if not already registered
        if (!nav.isAssetRegistered(asset)) {
            vm.prank(manager);
            nav.registerAsset(asset, priceOracle, priceType, heartbeat);
        } else {
            // Check if price feed already exists, set if not
            (address existingOracle,,,) = nav.priceOracles(asset);
            if (existingOracle == address(0)) {
                vm.prank(manager);
                nav.setPriceFeed(asset, priceOracle, priceType, heartbeat);
            }
        }
    }

    /// @notice Ensures native address (ETH) has a price feed set up
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param ethOracle The ETH price oracle address
    /// @param heartbeat The chainlink heartbeat (or max uint for custom)
    function ensureNativePriceFeed(NAVCalculator nav, address manager, address ethOracle, uint256 heartbeat) internal {
        ensurePriceFeed(nav, manager, nav.NATIVE_ADDRESS(), ethOracle, IPrices.PriceType.Chainlink, heartbeat);
    }

    // ============================================
    // Balance Oracle Setup Helpers
    // ============================================

    /// @notice Ensures a balance oracle is set up for an asset
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param asset The asset address
    /// @param oracle The balance oracle address
    /// @param oracleType The oracle type (ERC20, Native, or Custom)
    function ensureBalanceOracle(
        NAVCalculator nav,
        address manager,
        address asset,
        address oracle,
        IBalances.OracleType oracleType
    ) internal {
        // Check if oracle already exists
        address[] memory existingOracles = nav.balanceOracles(asset);
        for (uint256 i = 0; i < existingOracles.length; i++) {
            if (existingOracles[i] == oracle) {
                return; // Already exists
            }
        }

        // Add the oracle
        vm.prank(manager);
        nav.addBalanceOracle(asset, oracle, oracleType);
    }

    /// @notice Ensures native address has a balance oracle set up
    /// @param balances The Balances contract instance
    /// @dev The native address should use the ERC20DefaultOracle
    function ensureNativeBalanceOracle(Balances balances) internal view {
        uint256 count = balances.balanceOracleCountFor(balances.NATIVE_ADDRESS());
        if (count == 0) {
            // This should not happen if ERC20DefaultOracle is properly set up
            // But we check to provide a clear error message
            revert("Native balance oracle not initialized. ERC20DefaultOracle should be set in constructor.");
        }
    }

    // ============================================
    // Asset Registration Helpers
    // ============================================

    /// @notice Ensures an asset is registered in NAVCalculator
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param asset The asset address
    /// @notice Ensures an asset is registered with a price feed
    /// @dev Assets must be registered with a price feed. This helper requires a price feed.
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param asset The asset address
    /// @param priceOracle The price oracle address
    /// @param priceType The price type (Chainlink or Custom)
    /// @param heartbeat The chainlink heartbeat (or max uint for custom)
    function ensureAssetRegistered(
        NAVCalculator nav,
        address manager,
        address asset,
        address priceOracle,
        IPrices.PriceType priceType,
        uint256 heartbeat
    ) internal {
        if (!nav.isAssetRegistered(asset)) {
            vm.prank(manager);
            nav.registerAsset(asset, priceOracle, priceType, heartbeat);
        }
    }

    // ============================================
    // Complete Asset Setup Helpers
    // ============================================

    /// @notice Sets up a complete asset (register + price feed + balance oracle)
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param asset The asset address
    /// @param priceOracle The price oracle address
    /// @param priceType The price type
    /// @param heartbeat The chainlink heartbeat
    /// @param balanceOracle The balance oracle address
    /// @param balanceOracleType The balance oracle type
    function setupCompleteAsset(
        NAVCalculator nav,
        address manager,
        address asset,
        address priceOracle,
        IPrices.PriceType priceType,
        uint256 heartbeat,
        address balanceOracle,
        IBalances.OracleType balanceOracleType
    ) internal {
        ensureAssetRegistered(nav, manager, asset, priceOracle, priceType, heartbeat);
        // Price feed is set during registration, but ensurePriceFeed will update if needed
        ensurePriceFeed(nav, manager, asset, priceOracle, priceType, heartbeat);
        ensureBalanceOracle(nav, manager, asset, balanceOracle, balanceOracleType);
    }

    /// @notice Sets up native address with price feed and ensures balance oracle exists
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param ethOracle The ETH price oracle address
    /// @param heartbeat The chainlink heartbeat
    function setupNativeAsset(NAVCalculator nav, address manager, address ethOracle, uint256 heartbeat) internal {
        ensureNativePriceFeed(nav, manager, ethOracle, heartbeat);
        ensureNativeBalanceOracle(nav);
    }
}
