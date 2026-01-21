// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title IBalanceOracleAdapter
/// @notice Standard interface for balance oracle adapters (both default and custom)
/// @dev All balance oracles must implement this interface to work with the oracle-centric aggregation system
interface IBalanceOracleAdapter {
    /// @notice Get all positions from this oracle for an account
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of Position structs from this oracle
    function getOraclePositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.Position[] memory positions);

    /// @notice Get balances from this oracle for an account
    /// @param account The account to query
    /// @param asset Optional asset filter (address(0) for all assets)
    /// @return assets Array of asset addresses (empty if asset != address(0))
    /// @return amounts Array of balances (empty if asset != address(0))
    function getOracleBalance(address account, address asset)
        external
        view
        returns (address[] memory assets, int256[] memory amounts);

    /// @notice Get single balance for a specific asset (gas-optimized version)
    /// @param account The account to query
    /// @param asset The asset address
    /// @return balance The balance for this asset from this oracle
    function getOracleBalanceForAsset(address account, address asset) external view returns (int256 balance);
}
