// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IPrices Interface
/// @notice Interface for managing price feeds for different tokens.
/// @author kpk
interface IPrices {
    /// @notice Enum representing the type of price feed.
    enum PriceType {
        Chainlink,
        Custom
    }

    /// @notice Struct representing a price feed configuration (stored price feed configuration).
    /// @param priceFeed The address of the price feed contract (e.g. Chainlink aggregator or custom price feed).
    /// @param decimals The number of decimal places the price feed uses.
    /// @param chainlinkHeartbeat The heartbeat interval for the Chainlink feed. This is relevant only for Chainlink
    /// price feeds.
    /// @param priceType The type of the price feed (Chainlink or Custom).
    struct PriceFeedConfig {
        address priceFeed;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        PriceType priceType;
    }

    /// @notice Emitted when a price feed is set for a token.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the price feed.
    /// @param chainlinkHeartbeat The heartbeat interval for the Chainlink feed. This is relevant only for Chainlink
    /// price feeds.
    /// @param priceType The type of the price feed.
    event PriceFeedSet(
        address indexed underlyingAsset, address indexed priceFeed, uint256 chainlinkHeartbeat, PriceType priceType
    );

    /// @notice Emitted when a price feed is removed for a token.
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

    /// @notice Returns the latest price for a given token while checking if the price is stale.
    /// @param underlyingAsset The address of the token.
    /// @return price The latest price of the token (int256; Chainlink and custom feeds use positive prices).
    /// @return decimals The amount of decimal places the price is represented with.
    /// @return stale If the price returned is stale, be it by heartbeat, L2 sequencer down or L2 sequencer's feed
    /// within grace period.
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
}
