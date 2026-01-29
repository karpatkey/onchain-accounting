// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IBalanceOracleAdapter
/// @notice Standard interface for balance oracle adapters (both default and custom)
/// @dev All balance oracles must implement this interface to work with the oracle-centric aggregation system
/// @dev Extends ERC165 to allow on‐chain discovery with `supportsInterface`.
interface IBalanceOracleAdapter is IERC165 {
    /// @notice Get all positions from this oracle for an account
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of balance-only PositionBalance structs from this oracle
    /// @dev Balance oracles return balance-only data without pricing. NAVCalculator enriches these with pricing.
    function getOraclePositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions);

    /// @notice Get balances from this oracle for an account
    /// @param account The account to query
    /// @return assets Array of asset addresses
    /// @return amounts Array of balance amounts (always non-negative magnitude)
    /// @return isDebt Array of debt flags (true = debt, false = credit)
    function getOracleBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt);

    /// @notice Get single balance for a specific asset (gas-optimized version)
    /// @param account The account to query
    /// @param asset The asset address
    /// @return amount Balance amount (non-negative magnitude)
    /// @return isDebt True if debt, false if credit
    function getOracleBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt);

    /// @notice Returns the list of all the underlying assets supported by this oracle
    /// @dev The returned list may be empty if the oracle cannot determine or provide the supported assets
    /// @return underlyingAssets The list of underlying asset addresses supported by this oracle (may be empty)
    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets);
}
