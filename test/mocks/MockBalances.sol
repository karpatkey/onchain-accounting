// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {AssetNotFound} from "src/errors.sol";

/// @title MockBalances
/// @notice Minimal mock implementation of IBalances for protocol oracle tests
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

    // Stub implementations for other IBalances methods (not used in protocol oracle tests)
    function balanceOf(address, uint256, address) external pure returns (int256) {
        return 0;
    }

    function checkBalanceOracleSupport(address) external pure {}

    function getAllOracles() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getOracleCount() external pure returns (uint256) {
        return 0;
    }

    function isOracleRegistered(address) external pure returns (bool) {
        return false;
    }

    function getOracleType(address) external pure returns (OracleType) {
        return OracleType.Default;
    }

    function getOraclesForAsset(address) external pure returns (address[] memory) {
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
