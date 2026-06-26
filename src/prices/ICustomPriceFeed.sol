// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ICustomPriceFeed
/// @notice This interface defines the standard functions for a custom price feed.
/// @author KPK
interface ICustomPriceFeed is IERC165 {
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

    /// @notice Returns the staleness data of the worst-case underlying oracle for external observability.
    /// @dev Matches the AggregatorV3Interface.latestRoundData() signature. Prices.sol does NOT call
    ///      this for staleness — all custom feeds handle staleness internally in getLatestPrice().
    ///      This is provided for callers who want to inspect the underlying oracle freshness directly.
    /// @dev For feeds backed by one Chainlink oracle: return that oracle's round data directly.
    /// @dev For feeds backed by multiple Chainlink oracles: return the tuple with the lowest
    ///      updatedAt (worst case) so callers see the most-stale input.
    /// @dev For feeds with indirect oracle exposure (e.g. ETHPlus via Reserve Protocol): return
    ///      a meaningful updatedAt sourced from the underlying protocol's refresh timestamps.
    /// @dev For feeds with no trackable oracle dependency: return (0, 0, 0, 0, 0).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
