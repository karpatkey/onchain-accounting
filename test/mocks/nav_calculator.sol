// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20DefaultAdapter} from "src/balances/protocols/ERC20DefaultAdapter.sol";

/// @title Mock_NAVCalculator
/// @notice Mock implementation of INAVCalculator for adapter testing
/// @dev Only implements the minimal interface methods needed by adapters (ERC20DefaultAdapter)
contract Mock_NAVCalculator is INAVCalculator {
    /// @notice Registered assets with their metadata
    struct AssetInfo {
        address asset;
        uint8 decimals;
        string symbol;
    }

    AssetInfo[] private _assets;
    mapping(address => bool) private _isRegistered;

    /// @notice Optional default adapter; when set, registering an asset also adds it to this adapter's inclusion list
    address public defaultAdapter;

    /// @notice Set the default adapter so that registerAsset* also add assets to it (for adapter tests)
    function setDefaultAdapter(address defaultAdapter_) external {
        defaultAdapter = defaultAdapter_;
    }

    /// @notice Register an asset
    function registerAsset(address asset, uint8 decimals, string memory symbol) external {
        require(!_isRegistered[asset], "Asset already registered");
        _assets.push(AssetInfo({asset: asset, decimals: decimals, symbol: symbol}));
        _isRegistered[asset] = true;
        if (defaultAdapter != address(0)) {
            ERC20DefaultAdapter(defaultAdapter).addSupportedAsset(asset);
        }
    }

    /// @notice Register an asset using ERC20 metadata
    function registerAssetFromERC20(address asset) external {
        require(!_isRegistered[asset], "Asset already registered");
        uint8 decimals = IERC20Metadata(asset).decimals();
        string memory symbol = IERC20Metadata(asset).symbol();
        _assets.push(AssetInfo({asset: asset, decimals: decimals, symbol: symbol}));
        _isRegistered[asset] = true;
        if (defaultAdapter != address(0)) {
            ERC20DefaultAdapter(defaultAdapter).addSupportedAsset(asset);
        }
    }

    /// @notice Unregister an asset (helper method, not part of interface)
    function unregisterAssetHelper(address asset) external {
        require(_isRegistered[asset], "Asset not registered");
        _isRegistered[asset] = false;

        // Remove from array
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].asset == asset) {
                // Swap with last element and pop
                _assets[i] = _assets[_assets.length - 1];
                _assets.pop();
                break;
            }
        }
    }

    /// @inheritdoc INAVCalculator
    function getRegisteredAssets() external view override returns (Asset[] memory) {
        Asset[] memory result = new Asset[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            result[i] = Asset({asset: _assets[i].asset, symbol: _assets[i].symbol, decimals: _assets[i].decimals});
        }
        return result;
    }

    /// @inheritdoc INAVCalculator
    function assetCount() external view override returns (uint256) {
        return _assets.length;
    }

    /// @notice Check if an asset is registered (IBalances)
    function isAssetRegistered(address asset) external view override returns (bool) {
        return _isRegistered[asset];
    }

    function getAssetCount() external view override returns (uint256) {
        return _assets.length;
    }

    function getAssetDecimals(address asset) external view returns (uint8) {
        require(_isRegistered[asset], "Asset not registered");
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].asset == asset) return _assets[i].decimals;
        }
        revert("Asset not registered");
    }

    function getAssetSymbol(address asset) external view returns (string memory) {
        require(_isRegistered[asset], "Asset not registered");
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].asset == asset) return _assets[i].symbol;
        }
        revert("Asset not registered");
    }

    function checkBalanceAdapterSupport(address) external pure override {}

    function getAllAdapters() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function getAdapterCount() external pure override returns (uint256) {
        return 0;
    }

    function isAdapterRegistered(address) external pure override returns (bool) {
        return false;
    }

    function getAdapterType(address) external pure override returns (AdapterType) {
        return AdapterType.Default;
    }

    function getAdaptersForAsset(address) external pure override returns (address[] memory) {
        return new address[](0);
    }

    function getMetaInstances(address) external pure override returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function setMetaInstances(address, bytes32[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    // Stub implementations for other INAVCalculator methods (not used by adapters)
    function getAccountNav(address, address) external pure override returns (NAV memory) {
        revert("Not implemented in mock");
    }

    function getAccountPositions(address, address) external pure override returns (Position[] memory) {
        revert("Not implemented in mock");
    }

    function calculateValue(address[] memory, uint256[] memory, address) external pure override returns (int256) {
        revert("Not implemented in mock");
    }

    function registerAsset(address, address, IPrices.PriceType, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function addPriceFeed(address, address, IPrices.PriceType, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function addBalanceAdapters(address[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    function removeBalanceAdapters(address[] calldata) external pure override {
        revert("Not implemented in mock");
    }

    function excludeAssetFromDefaultAdapter(address) external pure override {
        revert("Not implemented in mock");
    }

    function includeAssetInDefaultAdapter(address) external pure override {
        revert("Not implemented in mock");
    }

    function healthCheck() external pure override returns (bool, address[] memory) {
        revert("Not implemented in mock");
    }

    function hasPositions(address) external pure override returns (bool) {
        revert("Not implemented in mock");
    }

    function version() external pure override returns (uint64) {
        return 1;
    }

    function usdDecimals() external pure override returns (uint8) {
        return 8;
    }

    function getPriceData(address) external pure override returns (PriceFeedData memory) {
        revert("Not implemented in mock");
    }

    function getAccountPositionsForAsset(address, address, address) external pure override returns (Position[] memory) {
        revert("Not implemented in mock");
    }

    function getAssetsWithPositions(address) external pure override returns (address[] memory) {
        revert("Not implemented in mock");
    }

    function removePriceFeedAt(address, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function removePriceFeed(address, address) external pure override {
        revert("Not implemented in mock");
    }

    function unregisterAsset(address) external pure override {
        revert("Not implemented in mock");
    }

    function setChainlinkL2SequencerUptimeFeed(address) external pure override {
        revert("Not implemented in mock");
    }

    function setChainlinkL2SequencerGracePeriod(uint256) external pure override {
        revert("Not implemented in mock");
    }
}
