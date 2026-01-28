// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";

/// @title Mock_NAVCalculator
/// @notice Mock implementation of INAVCalculator for adapter testing
/// @dev Only implements the minimal interface methods needed by adapters (ERC20DefaultOracle)
contract Mock_NAVCalculator is INAVCalculator {
    /// @notice Registered assets with their metadata
    struct AssetInfo {
        address asset;
        uint8 decimals;
        string symbol;
    }

    AssetInfo[] private _assets;
    mapping(address => bool) private _isRegistered;

    /// @notice Optional default oracle; when set, registering an asset also adds it to this oracle's inclusion list
    address public defaultOracle;

    /// @notice Set the default oracle so that registerAsset* also add assets to it (for adapter tests)
    function setDefaultOracle(address defaultOracle_) external {
        defaultOracle = defaultOracle_;
    }

    /// @notice Register an asset
    function registerAsset(address asset, uint8 decimals, string memory symbol) external {
        require(!_isRegistered[asset], "Asset already registered");
        _assets.push(AssetInfo({asset: asset, decimals: decimals, symbol: symbol}));
        _isRegistered[asset] = true;
        if (defaultOracle != address(0)) {
            ERC20DefaultOracle(defaultOracle).addSupportedAsset(asset);
        }
    }

    /// @notice Register an asset using ERC20 metadata
    function registerAssetFromERC20(address asset) external {
        require(!_isRegistered[asset], "Asset already registered");
        uint8 decimals = IERC20Metadata(asset).decimals();
        string memory symbol = IERC20Metadata(asset).symbol();
        _assets.push(AssetInfo({asset: asset, decimals: decimals, symbol: symbol}));
        _isRegistered[asset] = true;
        if (defaultOracle != address(0)) {
            ERC20DefaultOracle(defaultOracle).addSupportedAsset(asset);
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
    function assets() external view override returns (address[] memory) {
        address[] memory result = new address[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            result[i] = _assets[i].asset;
        }
        return result;
    }

    /// @inheritdoc INAVCalculator
    function assetCount() external view override returns (uint256) {
        return _assets.length;
    }

    /// @inheritdoc INAVCalculator
    function assetAt(uint256 idx) external view override returns (Asset memory) {
        require(idx < _assets.length, "Index out of bounds");
        AssetInfo memory info = _assets[idx];
        return Asset({asset: info.asset, symbol: info.symbol, decimals: info.decimals});
    }

    /// @notice Check if an asset is registered
    function isAssetRegistered(address asset) external view returns (bool) {
        return _isRegistered[asset];
    }

    // Stub implementations for other INAVCalculator methods (not used by adapters)
    function getAccountNav(address, address) external pure override returns (NAV memory) {
        revert("Not implemented in mock");
    }

    function getAccountNavForRange(address, uint256, uint256, address) external pure override returns (NAV memory) {
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

    function setPriceFeed(address, address, IPrices.PriceType, uint256) external pure override {
        revert("Not implemented in mock");
    }

    function addBalanceOracle(address) external pure override {
        revert("Not implemented in mock");
    }

    function removeBalanceOracle(address) external pure override {
        revert("Not implemented in mock");
    }

    function excludeAssetFromDefaultOracle(address) external pure override {
        revert("Not implemented in mock");
    }

    function includeAssetInDefaultOracle(address) external pure override {
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

    function unsetPriceFeed(address) external pure override {
        revert("Not implemented in mock");
    }

    function unregisterAsset(address) external pure override {
        revert("Not implemented in mock");
    }

    function setNativeTokenSymbol(string memory) external pure override {
        revert("Not implemented in mock");
    }

    function setChainlinkL2SequencerUptimeFeed(address) external pure override {
        revert("Not implemented in mock");
    }

    function setChainlinkL2SequencerGracePeriod(uint256) external pure override {
        revert("Not implemented in mock");
    }
}
