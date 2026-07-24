// SPDX-License-Identifier: BUSL-1.1
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

    /// @notice Returns the staleness data of the worst-case underlying oracle.
    /// @dev Matches the AggregatorV3Interface.latestRoundData() signature. Custom feeds still handle
    ///      staleness internally in getLatestPrice() (its `stale` flag is honored), but the read path
    ///      (PriceFeedLib.selectFeed, invoked via Prices) ALSO calls this and uses the returned
    ///      `updatedAt` as the feed's freshness timestamp — for the per-feed heartbeat gate and for
    ///      picking the freshest feed among redundant ones. A revert or a zero `updatedAt` is treated
    ///      as a no-timestamp oracle and a `block.timestamp - 1` sentinel is applied instead.
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

    /// @notice The freshness of the underlying Chainlink leg that GOVERNS this feed's staleness — the leg with the
    ///         greatest age-to-heartbeat ratio (i.e. closest to, or furthest past, its own staleness deadline).
    /// @dev Read path (`NAVCalculator.getPriceData`) reports this `(updatedAt, heartbeat)` pair for a Custom feed so
    ///      the two values are a REAL, MATCHED pair from one actual oracle — unlike `latestRoundData().updatedAt`
    ///      (which returns the worst-case/min timestamp for feed *selection* and carries no companion heartbeat).
    /// @dev For a feed backed by a single Chainlink oracle: return that oracle's `(updatedAt, heartbeat)`.
    /// @dev For a feed backed by two or more Chainlink oracles: return the `(updatedAt, heartbeat)` of whichever leg
    ///      has the largest `age/heartbeat` ratio — the input most at risk of being stale.
    /// @dev For feeds with no trackable Chainlink dependency: return `(0, 0)`.
    /// @return updatedAt The governing leg's `latestRoundData` update timestamp (0 if it has no push timestamp).
    /// @return heartbeat The governing leg's staleness window in seconds (0 if not representable).
    function governingFeedFreshness() external view returns (uint256 updatedAt, uint256 heartbeat);
}
