// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

/// @title IPrices Interface
/// @notice Interface for managing price feeds for different tokens.
/// @author KPK
interface IPrices {
    /// @notice Enum representing the type of price feed.
    enum PriceType {
        Chainlink, // 0 — Chainlink AggregatorV3Interface (on-chain push)
        Redstone, // 1 — Redstone Classic Push (AggregatorV3-compatible, same read path as Chainlink)
        API3, // 2 — API3 dAPI via Api3ReaderProxyV1 (AggregatorV3-compatible, 18-dec proxy scaled to 8-dec at read)
        Custom // 3 — custom ICustomPriceFeed adapter (internal staleness logic)
    }

    /// @notice Struct representing a price feed configuration.
    /// @param priceFeed The address of the price feed contract (e.g. Chainlink aggregator or custom price feed).
    /// @param decimals The number of decimal places the price feed uses.
    /// @param chainlinkHeartbeat Staleness window in seconds (non-zero for all types). For Chainlink/Redstone/API3
    /// feeds this gates participation: block.timestamp - effectiveUpdatedAt >= chainlinkHeartbeat → skip feed.
    /// For Custom feeds the internal stale signal from getLatestPrice() is the primary gate; updatedAt from
    /// latestRoundData() then applies the same heartbeat gate (updatedAt==0 is treated as block.timestamp-1
    /// so rate-only feeds participate but yield to any feed with a real push timestamp), and among survivors
    /// the largest effectiveUpdatedAt wins.
    /// @param priceType The type of the price feed.
    struct PriceFeedConfig {
        address priceFeed;
        uint8 decimals;
        PriceType priceType;
        uint256 chainlinkHeartbeat;
    }

    /// @notice Emitted when a price feed is added for a token.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the price feed.
    /// @param chainlinkHeartbeat The heartbeat interval in seconds.
    /// @param priceType The type of the price feed.
    /// @param index The index of the new feed in the asset's feed array.
    event PriceFeedAdded(
        address indexed underlyingAsset,
        address indexed priceFeed,
        uint256 chainlinkHeartbeat,
        PriceType priceType,
        uint256 index
    );

    /// @notice Emitted when a single price feed is removed for a token.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the removed feed.
    /// @param index The former index of the removed feed.
    event PriceFeedRemoved(address indexed underlyingAsset, address indexed priceFeed, uint256 index);

    /// @notice Emitted when swap-and-pop relocates the last feed into a vacated slot.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the feed that was moved.
    /// @param fromIndex The former index (len-1 before the pop).
    /// @param toIndex The new index (the slot vacated by the removed feed).
    event PriceFeedIndexChanged(
        address indexed underlyingAsset, address indexed priceFeed, uint256 fromIndex, uint256 toIndex
    );

    /// @notice Emitted when all price feeds are cleared for a token (asset unregistration).
    /// @param underlyingAsset The address of the token.
    event PriceFeedUnset(address indexed underlyingAsset);

    //
    // Errors
    //

    /// @notice Error when the price feed is not set for an asset
    /// @param asset The address of the asset
    error PriceFeedNotSet(address asset);

    /// @notice Error when the price feed is invalid
    error InvalidPriceOracle();

    /// @notice Error when the price feed type is not valid
    error InvalidPriceOracleType();

    /// @notice Error when attempting to remove the last remaining feed for an asset
    error CannotRemoveLastFeed(address asset);

    /// @notice Error when attempting to add a feed that is already registered for an asset
    error PriceFeedAlreadyRegistered(address asset, address feed);

    /// @notice Error when the feed index is out of bounds
    error PriceFeedIndexOutOfBounds(address asset, uint256 index);

    /// @notice Error when a feed address is not found in an asset's feed list
    error PriceFeedNotFound(address asset, address feed);

    /// @notice Error when a new feed's decimals do not match the decimals of existing feeds for the asset
    error PriceFeedDecimalsMismatch(address asset, uint8 existingDecimals, uint8 newDecimals);

    /// @notice Returns the latest price for a given token while checking if the price is stale.
    /// @param underlyingAsset The address of the token.
    /// @return price The latest price of the token (int256; positive for all valid prices).
    /// @return decimals The amount of decimal places the price is represented with.
    /// @return stale True if all registered feeds are stale, the L2 sequencer is down, or within grace period.
    function latestPrice(address underlyingAsset) external view returns (int256 price, uint8 decimals, bool stale);

    /// @notice Checks if the L2 sequencer is up and running returning True if it is not signaling staleness. If
    /// 'chainlinkL2SequencerUptimeFeed' is the zero address (e.g. on an L1) it returns false.
    /// @return stale True if the L2 sequencer is down or if it is within the grace period.
    function checkL2SequencerUptime() external view returns (bool stale);

    /// @notice Checks if the price feed supports the given price feed type.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the price feed.
    /// @param priceType The type of the price feed.
    function checkPriceOracleSupport(address underlyingAsset, address priceFeed, PriceType priceType) external view;

    /// @notice Returns all price feed configurations for an asset.
    /// @param asset The address of the asset.
    /// @return configs Array of PriceFeedConfig (empty if no feeds registered).
    function getPriceFeeds(address asset) external view returns (PriceFeedConfig[] memory configs);

    /// @notice Returns the number of registered price feeds for an asset.
    /// @param asset The address of the asset.
    /// @return count Number of feeds.
    function getPriceFeedCount(address asset) external view returns (uint256 count);

    /// @notice Returns the price feed configuration at a specific index.
    /// @param asset The address of the asset.
    /// @param index Index into the feed array (reverts with PriceFeedIndexOutOfBounds if out of range).
    /// @return config The PriceFeedConfig at that index.
    function getPriceFeedAt(address asset, uint256 index) external view returns (PriceFeedConfig memory config);
}
