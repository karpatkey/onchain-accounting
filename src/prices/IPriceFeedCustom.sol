// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPriceFeedCustom
/// @notice This interface defines the standard functions for a custom price feed.
/// @author kpk
interface IPriceFeedCustom is IERC165 {
    /// @notice Returns the latest price for the underlying asset, and whether the price is stale
    /// (only relevant when this custom price feed makes use of an external oracle)
    /// @return price The latest price of the underlying asset.
    /// @return stale If the price returned is stale.
    function getLatestPrice() external view returns (uint256 price, bool stale);

    /// @notice Returns the number of decimals the price feed uses.
    /// @return decimals the number of decimals the price feed uses.
    function decimals() external view returns (uint8 decimals);

    /// @notice Returns the address of the underlying asset supported by this price feed.
    /// @return underlyingAsset The address of the underlying asset supported by this price feed.
    function underlyingAssetSupported() external view returns (address underlyingAsset);
}
