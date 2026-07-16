// SPDX-License-Identifier: BUSL-1.1
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

    /// @notice Per-asset pricing metadata governing divergence detection between the primary feed and its
    /// monitor feeds. Packs into a single storage slot (uint32 + uint32 = 8 bytes).
    /// @param divergenceToleranceBps Max allowed basis-point gap between the primary price and the mean of the
    /// healthy monitor prices before the asset is flagged `irregular`. Must be non-zero when monitors exist.
    /// @param pegToleranceBps Absolute peg-deviation guard: max allowed basis-point deviation of the primary price
    /// from $1 before the asset is flagged `irregular`. Non-zero enables the guard (set it only on assets whose
    /// fundamental value is $1, i.e. stablecoins); zero disables it.
    struct AssetPricing {
        uint32 divergenceToleranceBps;
        uint32 pegToleranceBps;
    }

    /// @notice Per-asset redemption-realizability config (see {IRealizabilitySource}). Packs into one slot
    /// (20 + 4 + 1 + 1 + 4 + 1 = 31 bytes). Resolution prefers `source` (an on-chain reader), falling back to the
    /// MANAGER-set scalar, then to unconfigured (no signal).
    /// @param source Optional pluggable IRealizabilitySource (address(0) = none → use the scalar).
    /// @param limitSeconds Max expected redemption time before the asset is flagged `unrealizable`. 0 disables the
    /// ETA threshold (only `withdrawalsEnabled`/`healthy` then gate the flag).
    /// @param scalarSet Whether the MANAGER scalar below is populated (used when `source` is unset or reverts).
    /// @param scalarWithdrawalsEnabled Scalar: whether redemptions are currently enabled.
    /// @param scalarEtaSeconds Scalar: expected redemption time in seconds.
    /// @param scalarHealthy Scalar: protocol-health flag.
    struct RealizabilityConfig {
        address source;
        uint32 limitSeconds;
        bool scalarSet;
        bool scalarWithdrawalsEnabled;
        uint32 scalarEtaSeconds;
        bool scalarHealthy;
    }

    /// @notice Struct representing a price feed configuration.
    /// @param priceFeed The address of the price feed contract (e.g. Chainlink aggregator or custom price feed).
    /// @param decimals The number of decimal places the price feed uses.
    /// @param priceType The type of the price feed.
    /// @param chainlinkHeartbeat Staleness window in seconds (non-zero for all types). For Chainlink/Redstone/API3
    /// feeds this gates participation: block.timestamp - effectiveUpdatedAt >= chainlinkHeartbeat → skip feed.
    /// For Custom feeds the internal stale signal from getLatestPrice() is the primary gate; updatedAt from
    /// latestRoundData() then applies the same heartbeat gate (updatedAt==0 is treated as block.timestamp-1
    /// so rate-only feeds participate but yield to any feed with a real push timestamp), and among survivors
    /// the largest effectiveUpdatedAt wins.
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

    /// @notice Emitted when a monitor (divergence-only) feed is added for a token.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the monitor feed.
    /// @param chainlinkHeartbeat The heartbeat interval in seconds.
    /// @param priceType The type of the monitor feed.
    /// @param index The index of the new monitor feed in the asset's monitor array.
    event MonitorFeedAdded(
        address indexed underlyingAsset,
        address indexed priceFeed,
        uint256 chainlinkHeartbeat,
        PriceType priceType,
        uint256 index
    );

    /// @notice Emitted when a monitor feed is removed for a token.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the removed monitor feed.
    /// @param index The former index of the removed monitor feed.
    event MonitorFeedRemoved(address indexed underlyingAsset, address indexed priceFeed, uint256 index);

    /// @notice Emitted when swap-and-pop relocates the last monitor feed into a vacated slot.
    /// @param underlyingAsset The address of the token.
    /// @param priceFeed The address of the monitor feed that was moved.
    /// @param fromIndex The former index (len-1 before the pop).
    /// @param toIndex The new index (the slot vacated by the removed monitor feed).
    event MonitorFeedIndexChanged(
        address indexed underlyingAsset, address indexed priceFeed, uint256 fromIndex, uint256 toIndex
    );

    /// @notice Emitted when all monitor feeds and pricing metadata are cleared for a token (asset unregistration).
    /// @param underlyingAsset The address of the token.
    event MonitorFeedsUnset(address indexed underlyingAsset);

    /// @notice Emitted when an asset's divergence tolerance is set.
    /// @param underlyingAsset The address of the token.
    /// @param divergenceToleranceBps The new tolerance in basis points.
    event DivergenceToleranceSet(address indexed underlyingAsset, uint32 divergenceToleranceBps);

    /// @notice Emitted when an asset's peg tolerance is set (stablecoins).
    /// @param underlyingAsset The address of the token.
    /// @param pegToleranceBps The new peg tolerance in basis points.
    event PegToleranceSet(address indexed underlyingAsset, uint32 pegToleranceBps);

    /// @notice Emitted when an asset's realizability source is set (address(0) clears it).
    event RealizabilitySourceSet(address indexed underlyingAsset, address indexed source);

    /// @notice Emitted when an asset's realizability scalar (MANAGER-fed status) is set.
    event RealizabilityScalarSet(
        address indexed underlyingAsset, bool withdrawalsEnabled, uint32 etaSeconds, bool healthy
    );

    /// @notice Emitted when an asset's realizability scalar is cleared.
    event RealizabilityScalarCleared(address indexed underlyingAsset);

    /// @notice Emitted when an asset's realizability limit (max expected redemption seconds) is set.
    event RealizabilityLimitSet(address indexed underlyingAsset, uint32 limitSeconds);

    /// @notice Emitted when all realizability config is cleared for a token (asset unregistration).
    event RealizabilityUnset(address indexed underlyingAsset);

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

    /// @notice Error when a monitor feed's decimals are not NAV_DECIMALS (monitors must be USD-comparable to the
    /// primary, which is always NAV_DECIMALS).
    error MonitorFeedDecimalsMismatch(address asset, uint8 expectedDecimals, uint8 actualDecimals);

    /// @notice Error when a monitor feed is already registered for an asset.
    error MonitorFeedAlreadyRegistered(address asset, address feed);

    /// @notice Error when a monitor feed address is not found in an asset's monitor list.
    error MonitorFeedNotFound(address asset, address feed);

    /// @notice Error when adding a monitor feed before the asset's divergence tolerance has been set (>0).
    error DivergenceToleranceRequired(address asset);

    /// @notice Error when a tolerance value is out of range (basis points must be in (0, 10000]).
    error InvalidTolerance(uint32 toleranceBps);

    /// @notice Error when a realizability source is zero, does not implement IRealizabilitySource, or is pinned to a
    /// different asset than the one it is being registered for.
    error InvalidRealizabilitySource(address asset, address source);

    /// @notice Returns the latest price for a given token while checking if the price is stale.
    /// @dev Reverts PriceFeedNotSet if the asset has no registered feeds. When at least one feed is registered
    /// but all are stale, returns price 0 with stale = true rather than reverting.
    /// @param underlyingAsset The address of the token.
    /// @return price The latest price of the token (int256; positive for all valid prices, 0 when stale).
    /// @return decimals The amount of decimal places the price is represented with.
    /// @return stale True if all registered feeds are stale, the L2 sequencer is down, or within grace period.
    /// @return irregular True if the primary price diverged from its monitor feeds beyond the divergence tolerance,
    /// or (stablecoins) from the $1 peg beyond the peg tolerance. A pricing-quality signal, not a validity flag;
    /// `price` is still populated. Always false when `stale` (divergence is undefined for an unusable price).
    /// @return unrealizable True if the asset's redemption is not realizable within its configured limit (withdrawals
    /// disabled, protocol unhealthy, or expected redemption time over the limit). Independent of price/staleness.
    function latestPrice(address underlyingAsset)
        external
        view
        returns (int256 price, uint8 decimals, bool stale, bool irregular, bool unrealizable);

    /// @notice Checks the L2 sequencer uptime feed, returning True when it is signaling staleness (the sequencer
    /// is down or still within the grace period). If 'chainlinkL2SequencerUptimeFeed' is the zero address (e.g. on
    /// an L1) it returns false.
    /// @return stale True if the L2 sequencer is down or if it is within the grace period.
    function checkL2SequencerUptime() external view returns (bool stale);

    /// @notice Validates that a price feed is suitable for the given type, reverting if it is not. Returns nothing
    /// on success. Reverts InvalidPriceOracle when the asset or feed address is zero, the feed fails the
    /// ICustomPriceFeed/AggregatorV3 interface check for its type, or (for Chainlink/Redstone/API3) its
    /// latestRoundData reports a non-positive answer, a zero updatedAt, or a future timestamp; reverts
    /// InvalidPriceOracleType for an unsupported price type.
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

    /// @notice Returns all monitor (divergence-only) feed configurations for an asset.
    /// @param asset The address of the asset.
    /// @return configs Array of monitor PriceFeedConfig (empty if none registered).
    function getMonitorFeeds(address asset) external view returns (PriceFeedConfig[] memory configs);

    /// @notice Returns the number of registered monitor feeds for an asset.
    /// @param asset The address of the asset.
    /// @return count Number of monitor feeds.
    function getMonitorFeedCount(address asset) external view returns (uint256 count);

    /// @notice Returns the per-asset pricing metadata (type + divergence/peg tolerances).
    /// @param asset The address of the asset.
    /// @return pricing The AssetPricing struct (zero-valued if never set: type Spot, tolerances 0).
    function getAssetPricing(address asset) external view returns (AssetPricing memory pricing);

    /// @notice Returns the raw per-asset realizability config (source + limit + MANAGER scalar).
    /// @param asset The address of the asset.
    /// @return config The RealizabilityConfig (zero-valued if never set → asset is treated as unconfigured).
    function getRealizabilityConfig(address asset) external view returns (RealizabilityConfig memory config);
}
