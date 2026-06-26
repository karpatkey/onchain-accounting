// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {Balances} from "src/balances/Balances.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/protocols/ERC20DefaultBalanceAdapter.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {aa} from "test/helpers/AdapterArray.sol";

/// @notice Balances harness for fork tests
/// @dev Extends Balances and implements a minimal asset registry so it can stand in for NAVCalculator.
///      Adapters call getRegisteredAssets() etc.; this harness maintains its own _registeredAssets.
contract BalancesHarnessForFork is Balances {
    ERC20DefaultBalanceAdapter public defaultAdapter;

    INAVCalculator.Asset[] private _registeredAssets;
    mapping(address => uint256) private _assetIndex;

    constructor() initializer {
        __Balances_init();
        defaultAdapter = new ERC20DefaultBalanceAdapter(address(this), new address[](0));
        _setErc20DefaultBalanceAdapter(address(defaultAdapter));
    }

    function registerAssetForTest(address asset, uint8 decimals, string memory symbol) public {
        if (_assetIndex[asset] != 0) return;
        _registeredAssets.push(INAVCalculator.Asset({asset: asset, symbol: symbol, decimals: decimals}));
        _assetIndex[asset] = _registeredAssets.length;
        if (address(defaultAdapter) != address(0)) {
            defaultAdapter.addSupportedAsset(asset);
        }
    }

    function getRegisteredAssets() external view returns (INAVCalculator.Asset[] memory) {
        return _registeredAssets;
    }

    function getAssetCount() external view returns (uint256) {
        return _registeredAssets.length;
    }

    function isAssetRegistered(address asset) external view returns (bool) {
        return _assetIndex[asset] != 0;
    }

    function getAssetDecimals(address asset) external view returns (uint8) {
        uint256 idx = _assetIndex[asset];
        require(idx != 0, "AssetNotFound");
        return _registeredAssets[idx - 1].decimals;
    }

    function getAssetSymbol(address asset) external view returns (string memory) {
        uint256 idx = _assetIndex[asset];
        require(idx != 0, "AssetNotFound");
        return _registeredAssets[idx - 1].symbol;
    }

    // -------------------------------------------------------------------------
    // Minimal price surface (for adapters that read oracle prices, e.g. UniswapV3PoolsMeta after [2]).
    // Unset assets return price 0 / stale=false → treated as unpriceable (price <= 0) by such adapters.
    // -------------------------------------------------------------------------

    mapping(address => INAVCalculator.PriceFeedData) private _priceData;

    /// @notice Sets a (USD) price for `asset` so `getPriceData` reports it. `decimals` is the price's decimals.
    function setAssetPrice(address asset, int256 price, uint8 decimals) external {
        INAVCalculator.PriceFeedData memory d;
        d.price = price;
        d.decimals = decimals;
        d.stale = false;
        _priceData[asset] = d;
    }

    /// @notice Mirrors NAVCalculator.getPriceData for the subset adapters consume (price/decimals/stale).
    function getPriceData(address asset) external view returns (INAVCalculator.PriceFeedData memory) {
        return _priceData[asset];
    }
}

/// @title TestSetupHelpers
/// @notice Helper functions for consistent test setup patterns
/// @dev Provides utilities for safe adapter access, price feed setup, and balance adapter setup
abstract contract TestSetupHelpers is Test {
    // ============================================
    // Safe Adapter Access Helpers
    // ============================================

    /// @notice Safely gets a balance adapter at a specific index from the global registry
    /// @param balances The Balances contract instance
    /// @param idx The adapter index in the global registry
    /// @return adapter The adapter address
    /// @return exists Whether the adapter exists at that index
    function safeGetBalanceAdapter(Balances balances, uint256 idx)
        internal
        view
        returns (address adapter, bool exists)
    {
        address[] memory allAdapters = balances.getAllAdapters();
        if (idx >= allAdapters.length) {
            return (address(0), false);
        }
        adapter = allAdapters[idx];
        exists = adapter != address(0);
    }

    /// @notice Safely checks if a price oracle exists for an asset
    /// @param nav The NAVCalculator contract instance
    /// @param asset The asset address
    /// @return adapter The first adapter address (address(0) if none registered)
    /// @return exists Whether at least one price oracle exists
    function safeGetPriceOracle(NAVCalculator nav, address asset) internal view returns (address adapter, bool exists) {
        uint256 count = nav.getPriceFeedCount(asset);
        if (count == 0) return (address(0), false);
        adapter = nav.getPriceFeedAt(asset, 0).priceFeed;
        exists = true;
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
            // Check if price feed already exists, add if not
            if (nav.getPriceFeedCount(asset) == 0) {
                vm.prank(manager);
                nav.addPriceFeed(asset, priceOracle, priceType, heartbeat);
            }
        }
    }

    /// @notice Ensures native address (ETH) has a price feed set up
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param ethAdapter The ETH price oracle address
    /// @param heartbeat The chainlink heartbeat (or max uint for custom)
    function ensureNativePriceFeed(NAVCalculator nav, address manager, address ethAdapter, uint256 heartbeat) internal {
        ensurePriceFeed(nav, manager, nav.NATIVE_ADDRESS(), ethAdapter, IPrices.PriceType.Chainlink, heartbeat);
    }

    // ============================================
    // Balance Adapter Setup Helpers
    // ============================================

    /// @notice Ensures a balance adapter is registered globally
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param adapter The balance adapter address
    function ensureBalanceAdapter(NAVCalculator nav, address manager, address adapter) internal {
        // Check if adapter already exists in global registry
        if (nav.isAdapterRegistered(adapter)) {
            return; // Already exists
        }

        // Add the adapter globally
        vm.prank(manager);
        nav.addBalanceAdapters(aa(adapter));
    }

    /// @notice Ensures native address has a balance adapter set up
    /// @param balances The Balances contract instance
    /// @dev The native address should use the ERC20DefaultBalanceAdapter
    function ensureNativeBalanceAdapter(Balances balances) internal view {
        if (!balances.isAdapterRegistered(balances.erc20DefaultBalanceAdapter())) {
            // This should not happen if ERC20DefaultBalanceAdapter is properly set up
            // But we check to provide a clear error message
            revert("Native balance adapter not initialized. ERC20DefaultBalanceAdapter should be set in constructor.");
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

    /// @notice Sets up a complete asset (register + price feed + balance adapter)
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param asset The asset address
    /// @param priceOracle The price oracle address
    /// @param priceType The price type
    /// @param heartbeat The chainlink heartbeat
    /// @param balanceAdapter The balance adapter address (optional, ERC20DefaultBalanceAdapter is always available)
    function setupCompleteAsset(
        NAVCalculator nav,
        address manager,
        address asset,
        address priceOracle,
        IPrices.PriceType priceType,
        uint256 heartbeat,
        address balanceAdapter
    ) internal {
        ensureAssetRegistered(nav, manager, asset, priceOracle, priceType, heartbeat);
        // Price feed is set during registration, but ensurePriceFeed will update if needed
        ensurePriceFeed(nav, manager, asset, priceOracle, priceType, heartbeat);
        // Only add custom balance adapter if provided (ERC20DefaultBalanceAdapter is always available)
        if (balanceAdapter != address(0)) {
            ensureBalanceAdapter(nav, manager, balanceAdapter);
        }
    }

    /// @notice Sets up native address with price feed and ensures balance adapter exists
    /// @param nav The NAVCalculator contract instance
    /// @param manager The manager address with permissions
    /// @param ethAdapter The ETH price oracle address
    /// @param heartbeat The chainlink heartbeat
    function setupNativeAsset(NAVCalculator nav, address manager, address ethAdapter, uint256 heartbeat) internal {
        ensureNativePriceFeed(nav, manager, ethAdapter, heartbeat);
        ensureNativeBalanceAdapter(nav);
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
            string memory symbol = _safeTokenSymbol(asset);
            try IERC20Metadata(asset).decimals() returns (uint8 decimals) {
                balancesInstance.registerAssetForTest(asset, decimals, symbol);
            } catch {
                balancesInstance.registerAssetForTest(asset, 18, symbol);
            }
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
                if (((uint256(b) >> (248 - i * 8)) & 0xFF) == 0) break;
                len++;
            }
            bytes memory s = new bytes(len);
            for (uint256 i = 0; i < len; i++) {
                s[i] = bytes1(uint8((uint256(b) >> (248 - i * 8)) & 0xFF));
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
