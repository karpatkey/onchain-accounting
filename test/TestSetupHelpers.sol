// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {Balances} from "src/balances/Balances.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Balances harness for fork tests
/// @dev This contract extends Balances and exposes internal functions for testing.
///      Implements INAVCalculator view methods (assets, assetCount, assetAt) so adapters'
///      getOraclePositions() work when this contract is passed as "NAVCalculator".
contract BalancesHarnessForFork is Balances {
    ERC20DefaultOracle public defaultOracle;

    constructor() initializer {
        __Balances_init();
        // Set up ERC20DefaultOracle
        defaultOracle = new ERC20DefaultOracle(address(this));
        _setErc20DefaultOracle(address(defaultOracle));
    }

    // Expose internal functions for testing
    function registerAssetForTest(address asset, uint8 decimals) public {
        _registerAsset(asset, decimals);
    }

    function setAssetSymbolForTest(address asset, string memory symbol) public {
        _setAssetSymbol(asset, symbol);
    }

    /// @notice INAVCalculator.assets() compatibility for getOraclePositions in fork tests
    function assets() external view returns (address[] memory) {
        return getAssets();
    }

    /// @notice INAVCalculator.assetCount() compatibility for getOraclePositions in fork tests
    /// @dev Returns getAssets().length so iteration 0..assetCount()-1 is always valid for assetAt(i)
    function assetCount() external view returns (uint256) {
        return getAssets().length;
    }

    /// @notice INAVCalculator.assetAt() compatibility for getOraclePositions in fork tests
    function assetAt(uint256 idx) external view returns (INAVCalculator.Asset memory) {
        address[] memory assts = getAssets();
        require(idx < assts.length, "assetAt: index out of range");
        address asset = assts[idx];
        return INAVCalculator.Asset({asset: asset, symbol: getAssetSymbol(asset), decimals: getAssetDecimals(asset)});
    }
}

/// @title TestSetupHelpers
/// @notice Helper functions for consistent test setup patterns
/// @dev Provides utilities for safe oracle access, price feed setup, and balance oracle setup
abstract contract TestSetupHelpers is Test {
    // ============================================
    // Safe Oracle Access Helpers
    // ============================================

    /// @notice Safely gets a balance oracle at a specific index from the global registry
    /// @param balances The Balances contract instance
    /// @param idx The oracle index in the global registry
    /// @return oracle The oracle address
    /// @return exists Whether the oracle exists at that index
    function safeGetBalanceOracle(Balances balances, uint256 idx) internal view returns (address oracle, bool exists) {
        address[] memory allOracles = balances.getAllOracles();
        if (idx >= allOracles.length) {
            return (address(0), false);
        }
        oracle = allOracles[idx];
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

    /// @notice Ensures a balance oracle is registered globally
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param oracle The balance oracle address
    function ensureBalanceOracle(NAVCalculator nav, address manager, address oracle) internal {
        // Check if oracle already exists in global registry
        if (nav.isOracleRegistered(oracle)) {
            return; // Already exists
        }

        // Add the oracle globally
        vm.prank(manager);
        nav.addBalanceOracle(oracle);
    }

    /// @notice Ensures native address has a balance oracle set up
    /// @param balances The Balances contract instance
    /// @dev The native address should use the ERC20DefaultOracle
    function ensureNativeBalanceOracle(Balances balances) internal view {
        if (!balances.isOracleRegistered(balances.erc20DefaultOracle())) {
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
    /// @param balanceOracle The balance oracle address (optional, ERC20DefaultOracle is always available)
    function setupCompleteAsset(
        NAVCalculator nav,
        address manager,
        address asset,
        address priceOracle,
        IPrices.PriceType priceType,
        uint256 heartbeat,
        address balanceOracle
    ) internal {
        ensureAssetRegistered(nav, manager, asset, priceOracle, priceType, heartbeat);
        // Price feed is set during registration, but ensurePriceFeed will update if needed
        ensurePriceFeed(nav, manager, asset, priceOracle, priceType, heartbeat);
        // Only add custom balance oracle if provided (ERC20DefaultOracle is always available)
        if (balanceOracle != address(0)) {
            ensureBalanceOracle(nav, manager, balanceOracle);
        }
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

    // ============================================
    // Balances Deployment Helpers for Fork Tests
    // ============================================

    /// @notice Deploys a Balances contract in the fork and registers the provided assets
    /// @param assets Array of asset addresses to register
    /// @return balancesInstance The deployed Balances contract with assets registered
    /// @dev This function attempts to read decimals from each asset contract, falling back to 18 if it fails.
    ///      Symbol is read via low-level call so both string and bytes32 (e.g. MKR) return types are supported.
    function deployBalancesInFork(address[] memory assets) internal returns (BalancesHarnessForFork) {
        BalancesHarnessForFork balancesInstance = new BalancesHarnessForFork();

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            try IERC20Metadata(asset).decimals() returns (uint8 decimals) {
                balancesInstance.registerAssetForTest(asset, decimals);
            } catch {
                balancesInstance.registerAssetForTest(asset, 18);
            }

            string memory symbol = _safeTokenSymbol(asset);
            balancesInstance.setAssetSymbolForTest(asset, symbol);
        }

        return balancesInstance;
    }

    /// @notice Reads token symbol safely for fork tests. Handles both string and bytes32 (old ERC20) returns.
    /// @param asset Token address
    /// @return symbol The symbol string, or "" if the call fails or returns unreadable data
    function _safeTokenSymbol(address asset) internal view returns (string memory symbol) {
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSignature("symbol()"));
        if (!ok || data.length == 0) return "";
        if (data.length == 32) {
            // Old ERC20 (e.g. MKR) returns bytes32; left-padded, trailing zeros
            bytes32 b = abi.decode(data, (bytes32));
            if (b == 0) return "";
            uint256 len;
            for (uint256 i = 0; i < 32; i++) {
                if (uint8(uint256(b) >> (248 - i * 8)) == 0) break;
                len++;
            }
            bytes memory s = new bytes(len);
            for (uint256 i = 0; i < len; i++) {
                s[i] = bytes1(uint8(uint256(b) >> (248 - i * 8)));
            }
            return string(s);
        }
        // ABI-encoded string: offset (32) + length (32) + data
        if (data.length >= 64) {
            uint256 offset = abi.decode(data, (uint256));
            if (offset != 32) return "";
            uint256 strLen;
            assembly {
                strLen := mload(add(add(data, 32), 32))
            }
            if (64 + strLen > data.length || strLen > 256) return "";
            bytes memory s = new bytes(strLen);
            for (uint256 i = 0; i < strLen; i++) {
                s[i] = data[64 + i];
            }
            return string(s);
        }
        return "";
    }

    /// @notice Deploys a Balances contract in the fork and registers a single asset
    /// @param asset The asset address to register
    /// @return balancesInstance The deployed Balances contract with the asset registered
    function deployBalancesInFork(address asset) internal returns (BalancesHarnessForFork) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        return deployBalancesInFork(assets);
    }
}
