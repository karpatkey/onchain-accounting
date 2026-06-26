// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AssetNotFound} from "src/errors.sol";

/// @title MockBalances
/// @notice Minimal mock implementation of IBalances for protocol adapter tests
contract MockBalances is IBalances {
    mapping(address => uint8) private _assetDecimals;
    mapping(address => string) private _assetSymbols;
    mapping(address => bool) private _assetRegistered;

    function getAssetDecimals(address asset) external view returns (uint8) {
        if (!_assetRegistered[asset]) {
            revert AssetNotFound();
        }
        return _assetDecimals[asset];
    }

    function getAssetSymbol(address asset) external view returns (string memory) {
        return _assetSymbols[asset];
    }

    function setAssetDecimals(address asset, uint8 decimals) external {
        _assetDecimals[asset] = decimals;
        _assetRegistered[asset] = true;
    }

    function setAssetSymbol(address asset, string memory symbol) external {
        _assetSymbols[asset] = symbol;
    }

    // Stub implementations for other IBalances methods (not used in protocol adapter tests)
    function balanceOf(address, uint256, address) external pure returns (int256) {
        return 0;
    }

    function checkBalanceAdapterSupport(address) external pure {}

    function getAllAdapters() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getAdapterCount() external pure returns (uint256) {
        return 0;
    }

    function isAdapterRegistered(address) external pure returns (bool) {
        return false;
    }

    function getAdapterType(address) external pure returns (AdapterType) {
        return AdapterType.Default;
    }

    function getAdaptersForAsset(address) external pure returns (address[] memory) {
        return new address[](0);
    }

    function getMetaInstances(address) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function isAssetRegistered(address) external pure returns (bool) {
        return false;
    }

    function getRegisteredAssets() external pure returns (INAVCalculator.Asset[] memory) {
        return new INAVCalculator.Asset[](0);
    }

    function getAssetCount() external pure returns (uint256) {
        return 0;
    }
}
