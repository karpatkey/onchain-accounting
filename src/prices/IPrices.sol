// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IPrices Interface
/// @notice Interface for managing price oracles for different tokens.
/// @author kpk
interface IPrices {
    /// @notice Enum representing the type of oracle.
    enum PriceType {
        Chainlink,
        Custom
    }

    /// @notice Struct representing a price feed configuration (stored oracle configuration).
    /// @param oracle The address of the oracle contract.
    /// @param decimals The number of decimal places the oracle uses.
    /// @param chainlinkHeartbeat The heartbeat interval for the Chainlink oracle. This is relevant only for Chainlink
    /// oracles.
    /// @param priceType The type of the oracle (Chainlink or Custom).
    struct PriceFeedConfig {
        address oracle;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        PriceType priceType;
    }

    /// @notice Emitted when a price feed is set for a token.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    /// @param chainlinkHeartbeat The heartbeat interval for the Chainlink oracle. This is relevant only for Chainlink
    /// oracles.
    /// @param priceType The type of the oracle.
    event PriceFeedSet(
        address indexed underlyingAsset, address indexed oracle, uint256 chainlinkHeartbeat, PriceType priceType
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

    /// @notice Error when the price oracle is invalid
    error InvalidPriceOracle();

    /// @notice Error when the price oracle type is not valid
    error InvalidPriceOracleType();

    /// @notice Returns the latest price for a given token while checking if the price is stale.
    /// @param underlyingAsset The address of the token.
    /// @return price The latest price of the token.
    /// @return decimals The amount of decimal places the price is represented with.
    /// @return stale If the price returned is stale, be it by heartbeat, L2 sequencer down or L2 sequencer's feed
    /// within grace period.
    function latestPrice(address underlyingAsset) external view returns (uint256 price, uint8 decimals, bool stale);

    /// @notice Checks if the L2 sequencer is up and running returning True if it is not signaling staleness. If
    /// 'chainlinkL2SequencerUptimeFeed' is the zero address (e.g. on an L1) it returns false.
    /// @return stale True if the L2 sequencer is down or if it is within the grace period.
    function checkL2SequencerUptime() external view returns (bool stale);

    /// @notice Checks if the oracle supports the given oracle type.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    /// @param priceType The type of the oracle.
    function checkPriceOracleSupport(address underlyingAsset, address oracle, PriceType priceType) external view;
}
