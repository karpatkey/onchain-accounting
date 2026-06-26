// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IBalanceAdapter
/// @notice Standard interface for balance adapter adapters (both default and custom)
/// @dev All balance adapters must implement this interface to work with the adapter-centric aggregation system
/// @dev Extends ERC165 to allow on‐chain discovery with `supportsInterface`.
/// @author KPK
interface IBalanceAdapter is IERC165 {
    /// @notice Get all positions from this adapter for an account
    /// @param account The account to query
    /// @param assetFilter Optional asset filter (address(0) for all assets)
    /// @return positions Array of balance-only PositionBalance structs from this adapter
    /// @dev Balance adapters return balance-only data without pricing. NAVCalculator enriches these with pricing.
    function getAdapterPositions(address account, address assetFilter)
        external
        view
        returns (INAVCalculator.PositionBalance[] memory positions);

    /// @notice Get balances from this adapter for an account
    /// @param account The account to query
    /// @return assets Array of asset addresses
    /// @return amounts Array of balance amounts (always non-negative magnitude)
    /// @return isDebt Array of debt flags (true = debt, false = credit)
    function getAdapterBalances(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt);

    /// @notice Get single balance for a specific asset (gas-optimized version)
    /// @param account The account to query
    /// @param asset The asset address
    /// @return amount Balance amount (non-negative magnitude)
    /// @return isDebt True if debt, false if credit
    function getAdapterBalanceForAsset(address account, address asset)
        external
        view
        returns (uint256 amount, bool isDebt);

    /// @notice Returns the list of all the underlying assets supported by this adapter
    /// @dev The returned list may be empty if the adapter cannot determine or provide the supported assets
    /// @return underlyingAssets The list of underlying asset addresses supported by this adapter (may be empty)
    function underlyingAssetsSupported() external view returns (address[] memory underlyingAssets);
}
