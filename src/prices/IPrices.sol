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
    /// @param divergenceToleranceBps Max allowed basis-point gap between the primary price and the worst-case
    /// (furthest) healthy monitor price before the asset is flagged `irregular`. Must be non-zero when monitors exist.
    /// @param pegToleranceBps Absolute peg-deviation guard: max allowed basis-point deviation of the primary price
    /// from $1 before the asset is flagged `irregular`. Non-zero enables the guard (set it only on assets whose
    /// fundamental value is $1, i.e. stablecoins); zero disables it.
    struct AssetPricing {
        uint32 divergenceToleranceBps;
        uint32 pegToleranceBps;
    }

    /// @notice Struct representing a price feed configuration.
    /// @param priceFeed The address of the price feed contract (e.g. Chainlink aggregator or custom price feed).
    /// @param decimals The number of decimal places the price feed uses.
    /// @param priceType The type of the price feed.
    /// @param chainlinkHeartbeat Staleness window in seconds (non-zero for all types). For Chainlink/Redstone/API3
    /// feeds this gates freshness: block.timestamp - effectiveUpdatedAt >= chainlinkHeartbeat → the feed is stale.
    /// For Custom feeds the feed is fresh only if getLatestPrice() reports not-stale AND updatedAt from
    /// latestRoundData() passes the same heartbeat gate (updatedAt==0 is treated as block.timestamp-1 so rate-only
    /// feeds participate but yield to any feed with a real push timestamp). A fresh feed beats a stale one; then the
    /// largest effectiveUpdatedAt wins. A stale feed still prices until it is MAX_STALE_PRICE_AGE old (ADR 0029),
    /// so a finite primary heartbeat must be below it.
    struct PriceFeedConfig {
        address priceFeed;
        uint8 decimals;
        PriceType priceType;
        uint256 chainlinkHeartbeat;
    }

    /// @notice Emitted when an already-registered price feed's staleness heartbeat is changed in place.
    /// @param underlyingAsset The asset whose registration was updated.
    /// @param priceFeed The registered feed the heartbeat applies to.
    /// @param oldHeartbeat The previous heartbeat, in seconds.
    /// @param newHeartbeat The new heartbeat, in seconds.
    event PriceFeedHeartbeatUpdated(
        address indexed underlyingAsset, address indexed priceFeed, uint256 oldHeartbeat, uint256 newHeartbeat
    );

    /// @notice A registered MONITOR feed's heartbeat changed in place.
    /// @dev Mirrors {PriceFeedHeartbeatUpdated}. Emitted instead of a `MonitorFeedRemoved`/`MonitorFeedAdded`
    ///      pair, so alerting subscribed to that pair will not see monitor staleness-window changes.
    /// @param underlyingAsset The asset whose monitor feed changed.
    /// @param priceFeed The monitor feed whose staleness window moved.
    /// @param oldHeartbeat The previous staleness window, in seconds.
    /// @param newHeartbeat The new staleness window, in seconds.
    event MonitorFeedHeartbeatUpdated(
        address indexed underlyingAsset, address indexed priceFeed, uint256 oldHeartbeat, uint256 newHeartbeat
    );

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

    //
    // Errors
    //

    /// @notice Error when the price feed is not set for an asset
    /// @param asset The address of the asset
    error PriceFeedNotSet(address asset);

    /// @notice Error when the price feed is invalid
    error InvalidPriceOracle();

    /// @notice A primary feed's heartbeat is at or above MAX_STALE_PRICE_AGE (7 days) and is not the
    ///         `type(uint256).max` "gate disabled" value. Such a feed would go from fresh straight to unusable
    ///         (ADR 0029).
    /// @param heartbeat The rejected heartbeat, in seconds.
    error HeartbeatNotBelowStaleCap(uint256 heartbeat);

    /// @notice Error when the price feed type is not valid
    error InvalidPriceOracleType();

    /// @notice Error when attempting to remove the last remaining feed for an asset
    error CannotRemoveLastFeed(address asset);

    /// @notice Error when attempting to add a feed that is already registered for an asset
    error PriceFeedAlreadyRegistered(address asset, address feed);

    /// @notice The upsert path was given a `priceType` differing from the one the feed is registered with.
    /// @dev A feed's type is part of its IDENTITY, not its configuration — it selects the read path and the
    ///      decimals convention. Changing it means removing and re-adding the feed. Rejected rather than
    ///      ignored because `_validateFeedSupportInternal` puts Chainlink, Redstone and API3 in ONE branch, so a
    ///      mismatch inside that group passes validation and the caller would otherwise be told a request
    ///      succeeded that was never applied.
    error PriceFeedTypeImmutable(address asset, address feed);

    /// @notice Error when the feed index is out of bounds
    error PriceFeedIndexOutOfBounds(address asset, uint256 index);

    /// @notice Error when a feed address is not found in an asset's feed list
    error PriceFeedNotFound(address asset, address feed);

    /// @notice Error when a new feed's decimals do not match the decimals of existing feeds for the asset
    error PriceFeedDecimalsMismatch(address asset, uint8 existingDecimals, uint8 newDecimals);

    /// @notice Error when a monitor feed's decimals are not NAV_DECIMALS (monitors must be USD-comparable to the
    /// primary, which is always NAV_DECIMALS).
    error MonitorFeedDecimalsMismatch(address asset, uint8 expectedDecimals, uint8 actualDecimals);

    /// @notice Error when a `Custom` feed is being registered for an asset it does not price — i.e. the feed's own
    /// {ICustomPriceFeed-underlyingAssetSupported} does not equal the asset being registered.
    /// @param asset The asset the feed is being registered for.
    /// @param feed The custom feed address.
    /// @param feedAsset The asset the feed actually prices, per its own `underlyingAssetSupported()`.
    error CustomFeedAssetMismatch(address asset, address feed, address feedAsset);

    /// @notice Error when a `Custom` feed is being registered for the very asset it reads its own `base/USD` price
    /// for — i.e. the feed's {INavSourcedPriceFeed-BASE_ASSET} equals the asset being registered.
    /// @dev A NAV-sourced custom feed prices its asset as `rate × base/USD` and reads that `base/USD` back out of
    /// THIS NAV (`NavBaseUsdLib` → `getPriceData(BASE_ASSET)`; ADR 0019). If the base IS the asset, pricing the asset
    /// re-enters the same feed and recurses until the call stack is exhausted. The read still returns a price — the
    /// selector's per-feed `try`/`catch` swallows the depth failure and moves on — so the only symptom is that every
    /// read of that asset, and of everything priced from it, burns gas proportional to ~1024 nested `STATICCALL`
    /// frames. See the circularity invariant in {NavBaseUsdLib}.
    /// @param asset The asset the feed is being registered for.
    /// @param feed The custom feed address.
    error CustomFeedBaseCircular(address asset, address feed);

    /// @notice Error when a `Custom` feed does not answer {INavSourcedPriceFeed-BASE_ASSET}, so its NAV dependency
    /// cannot be established at registration.
    /// @dev Unreadable means REJECT, deliberately. The failure being closed is unbounded recursion, so "the base
    /// could not be read" must not be allowed to mean "the base is fine". A feed with no NAV dependency states that
    /// by answering `address(0)`; a feed that cannot answer at all is one whose base cannot be ruled out.
    /// @param asset The asset the feed is being registered for.
    /// @param feed The custom feed address.
    error CustomFeedBaseUnreadable(address asset, address feed);

    /// @notice Error when a monitor feed is already registered for an asset.
    error MonitorFeedAlreadyRegistered(address asset, address feed);

    /// @notice Error when a monitor feed address is not found in an asset's monitor list.
    error MonitorFeedNotFound(address asset, address feed);

    /// @notice Error when adding a monitor feed before the asset's divergence tolerance has been set (>0).
    error DivergenceToleranceRequired(address asset);

    /// @notice Error when a tolerance value is out of range. Divergence tolerance must be in (0, 10000];
    ///         peg tolerance must be in [0, 10000] (0 is allowed and disables the peg guard).
    error InvalidTolerance(uint32 toleranceBps);

    /// @notice Returns the latest price for a given token while checking if the price is stale.
    /// @dev Reverts PriceFeedNotSet if the asset has no registered feeds. When no feed is fresh, returns the
    /// freshest usable stale price with stale = true (ADR 0029); price 0 only when no feed is usable.
    /// @param underlyingAsset The address of the token.
    /// @return price The latest price of the token (int256; positive when any feed is usable, else 0).
    /// @return decimals The amount of decimal places the price is represented with.
    /// @return stale True if no registered feed is fresh, the L2 sequencer is down, or within grace period.
    /// @return irregular True if the primary price diverged from its monitor feeds beyond the divergence tolerance,
    /// or (stablecoins) from the $1 peg beyond the peg tolerance. A pricing-quality signal, not a validity flag;
    /// `price` is still populated. Evaluated on a stale-but-usable price too; always false when the L2 sequencer is
    /// down or no feed is usable (divergence is undefined for an unusable price).
    function latestPrice(address underlyingAsset)
        external
        view
        returns (int256 price, uint8 decimals, bool stale, bool irregular);

    /// @notice Checks the L2 sequencer uptime feed, returning True when it is signaling staleness (the sequencer
    /// is down or still within the grace period). If 'chainlinkL2SequencerUptimeFeed' is the zero address (e.g. on
    /// an L1) it returns false.
    /// @return stale True if the L2 sequencer is down or if it is within the grace period.
    function checkL2SequencerUptime() external view returns (bool stale);

    /// @notice Validates that a price feed is suitable for the given type, reverting if it is not. Returns nothing
    /// on success. Reverts InvalidPriceOracle when the asset or feed address is zero, the feed fails the
    /// ICustomPriceFeed/AggregatorV3 interface check for its type, or (for Chainlink/Redstone/API3) its
    /// latestRoundData reports a non-positive answer, a zero updatedAt, or a future timestamp; reverts
    /// InvalidPriceOracleType for an unsupported price type. For `Custom` feeds it additionally reverts
    /// CustomFeedAssetMismatch when the feed's own `underlyingAssetSupported()` is not `underlyingAsset` — a custom
    /// feed prices exactly one asset and must be registered for that asset — plus CustomFeedBaseUnreadable when the
    /// feed does not answer {INavSourcedPriceFeed-BASE_ASSET}, and CustomFeedBaseCircular when that base IS
    /// `underlyingAsset` (which would make pricing the asset re-enter the same feed).
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

    /// @notice Returns the per-asset pricing metadata (divergence/peg tolerances).
    /// @param asset The address of the asset.
    /// @return pricing The AssetPricing struct (zero-valued if never set: tolerances 0).
    function getAssetPricing(address asset) external view returns (AssetPricing memory pricing);
}
