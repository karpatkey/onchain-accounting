// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IBalances} from "src/balances/IBalances.sol";

/// @title MockBalances
/// @notice Minimal mock implementation of IBalances for protocol oracle tests
contract MockBalances is IBalances {
    mapping(address => uint8) private _assetDecimals;
    mapping(address => string) private _assetSymbols;

    function getAssetDecimals(address asset) external view returns (uint8) {
        return _assetDecimals[asset];
    }

    function getAssetSymbol(address asset) external view returns (string memory) {
        return _assetSymbols[asset];
    }

    function setAssetDecimals(address asset, uint8 decimals) external {
        _assetDecimals[asset] = decimals;
    }

    function setAssetSymbol(address asset, string memory symbol) external {
        _assetSymbols[asset] = symbol;
    }

    // Stub implementations for other IBalances methods (not used in protocol oracle tests)
    function balanceOf(address, uint256, address) external pure returns (int256) {
        return 0;
    }

    function balanceOracleCountFor(address) external pure returns (uint256) {
        return 0;
    }

    function balanceOracleAt(address, uint256) external pure returns (address, OracleType) {
        return (address(0), OracleType.ERC20);
    }

    function balanceOracles(address) external pure returns (address[] memory) {
        return new address[](0);
    }

    function checkBalanceOracleSupport(address, address, OracleType) external pure {}

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
        return OracleType.ERC20;
    }

    function isAssetRegistered(address) external pure returns (bool) {
        return false;
    }

    function getAssets() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getAssetCount() external pure returns (uint256) {
        return 0;
    }
}
