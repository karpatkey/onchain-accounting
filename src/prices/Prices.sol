// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPrices} from "./IPrices.sol";
import {PriceFeedLib} from "./PriceFeedLib.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Prices
/// @notice Manages multiple price feeds per asset, returning the best-available value on each read.
/// @dev The read path prefers a fresh feed and picks the one with the largest effectiveUpdatedAt (clamped to
/// block.timestamp to avoid upstream-clock bias). When no feed is fresh it returns the freshest usable stale price
/// with stale=true; the price is 0 only when no feed is usable (ADR 0029).
/// @author KPK
abstract contract Prices is IPrices, Initializable {
    //
    // Libraries
    //
    using PriceFeedLib for mapping(address => PriceFeedConfig[]);

    /// @notice Grace period for L2 sequencer downtime
    uint256 public chainlinkL2SequencerGracePeriod;

    /// @notice Uptime feed for L2 sequencer
    AggregatorV3Interface public chainlinkL2SequencerUptimeFeed;

    /// @notice Price feed configurations per asset. NAV prices off the single primary feed per asset; a second
    /// entry participates in the legacy freshest-wins selection as a fallback (see PriceFeedLib._selectFeedCore),
    /// but the intended production configuration is exactly one primary feed per asset, with redundancy moved to
    /// {_monitorFeeds}.
    mapping(address asset => PriceFeedConfig[] feeds) internal _priceOracles;

    /// @notice Monitor (divergence-only) feed configurations per asset. NEVER used to price the NAV; read only to
    /// detect divergence between the primary price and the healthy monitor prices.
    mapping(address asset => PriceFeedConfig[] feeds) internal _monitorFeeds;

    /// @notice Per-asset pricing metadata: divergence/peg tolerances (see IPrices.AssetPricing).
    mapping(address asset => AssetPricing pricing) internal _assetPricing;

    /// @dev Reserved storage gap for future Prices expansions. Started at 50; 2 consumed by `_monitorFeeds` and
    /// `_assetPricing`.
    // solhint-disable-next-line var-name-mixedcase
    uint256[48] private __pricesGap;

    /// @notice Initializer for UUPS proxy
    /// @param chainlinkL2SequencerUptimeFeed_ The address of the Chainlink feed for the L2 sequencer
    /// uptime. If this is run on a chain without the need of an uptime feed (e.g. L1), this parameter
    /// should be set to 0.
    // solhint-disable-next-line func-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-function)
    function __Prices_init(address chainlinkL2SequencerUptimeFeed_) internal onlyInitializing {
        chainlinkL2SequencerUptimeFeed = AggregatorV3Interface(chainlinkL2SequencerUptimeFeed_);
        chainlinkL2SequencerGracePeriod = 1 hours; // This is initialised with 1 hour by default.
    }

    /// @inheritdoc IPrices
    function latestPrice(address token)
        external
        view
        returns (int256 price, uint8 decimals, bool stale, bool irregular)
    {
        bool sequencerDown = checkL2SequencerUptime();
        bool feedStale;
        (price, decimals, feedStale,,) = _selectFeed(token);
        stale = sequencerDown || feedStale;
        // Divergence-vs-monitors signal (parity with getPriceData / NAV.irregularPriceAssets), computed from the
        // primary we JUST selected — irregularForSelected reuses (price, decimals) instead of re-running feed
        // selection, so this hot view reads the primary feed once, not twice. It internally skips the monitor
        // reads when the asset has no divergence check, and suppresses the flag only when the sequencer is down or no feed is usable (a stale primary is still checked).
        irregular = PriceFeedLib.irregularForSelected(
            _monitorFeeds, _assetPricing, token, price, decimals, feedStale, sequencerDown
        );
    }

    /// @inheritdoc IPrices
    function getPriceFeeds(address asset) external view returns (PriceFeedConfig[] memory) {
        return _priceOracles[asset];
    }

    /// @inheritdoc IPrices
    function getPriceFeedCount(address asset) external view returns (uint256) {
        return _priceOracles[asset].length;
    }

    /// @inheritdoc IPrices
    function getPriceFeedAt(address asset, uint256 index) external view returns (PriceFeedConfig memory) {
        if (index >= _priceOracles[asset].length) revert PriceFeedIndexOutOfBounds(asset, index);
        return _priceOracles[asset][index];
    }

    /// @inheritdoc IPrices
    function getMonitorFeeds(address asset) external view returns (PriceFeedConfig[] memory) {
        return _monitorFeeds[asset];
    }

    /// @inheritdoc IPrices
    function getMonitorFeedCount(address asset) external view returns (uint256) {
        return _monitorFeeds[asset].length;
    }

    /// @inheritdoc IPrices
    function getAssetPricing(address asset) external view returns (AssetPricing memory) {
        return _assetPricing[asset];
    }

    /// @notice Returns the latest price for a given token without checking the L2 sequencer uptime.
    function _latestPrice(address token) internal view returns (int256 price, uint8 decimals, bool stale) {
        (price, decimals, stale,,) = _selectFeed(token);
    }

    /// @notice Selects the price for an asset: the freshest fresh feed, else the freshest usable stale feed.
    /// @dev Delegates to PriceFeedLib.selectFeed via DELEGATECALL to keep NAVCalculator under EIP-170.
    /// See PriceFeedLib.selectFeed for full semantics.
    function _selectFeed(address token)
        internal
        view
        returns (int256 price, uint8 decimals, bool stale, uint256 winnerIdx, uint256 healthyFeedCount)
    {
        return _priceOracles.selectFeed(token);
    }

    /// @inheritdoc IPrices
    function checkL2SequencerUptime() public view returns (bool stale) {
        return
            PriceFeedLib.checkSequencerUptime(address(chainlinkL2SequencerUptimeFeed), chainlinkL2SequencerGracePeriod);
    }

    /// @inheritdoc IPrices
    function checkPriceOracleSupport(address token, address priceFeed, PriceType priceType) public view {
        PriceFeedLib.validateFeedSupport(token, priceFeed, priceType);
    }

    /// @notice Adds a price feed for an asset. The asset must be registered at the caller level.
    /// @dev Delegates to PriceFeedLib.addFeed via DELEGATECALL to keep NAVCalculator under EIP-170.
    function _addPriceFeed(address asset, address priceFeed, uint256 heartbeat, PriceType priceType) internal {
        _priceOracles.addFeed(asset, priceFeed, heartbeat, priceType);
    }

    /// @notice Removes the feed at `index` for an asset. Reverts if it is the last feed.
    /// @dev Delegates to PriceFeedLib.removeFeedAt via DELEGATECALL.
    function _removePriceFeedAt(address asset, uint256 index) internal {
        _priceOracles.removeFeedAt(asset, index);
    }

    /// @notice Removes the feed with address `priceFeed` for an asset. Reverts if not found or last feed.
    /// @dev Delegates to PriceFeedLib.removeFeed via DELEGATECALL.
    function _removePriceFeed(address asset, address priceFeed) internal {
        _priceOracles.removeFeed(asset, priceFeed);
    }

    /// @notice Removes all price feeds for an asset (called on full asset unregistration).
    function _removeAllPriceFeeds(address asset) internal {
        delete _priceOracles[asset];
        emit PriceFeedUnset(asset);
    }

    /// @notice Returns the number of feeds registered for an asset.
    function _priceFeedCount(address asset) internal view returns (uint256) {
        return _priceOracles[asset].length;
    }

    // -------------------------------------------------------------------------
    // Monitor feeds & pricing metadata (divergence detection)
    // -------------------------------------------------------------------------

    /// @notice Adds a monitor (divergence-only) feed for an asset. Requires the divergence tolerance to be set
    /// first (>0). Monitor feeds never price the NAV.
    /// @dev Delegates to PriceFeedLib.addMonitorFeed via DELEGATECALL to keep NAVCalculator under EIP-170.
    function _addMonitorFeed(address asset, address priceFeed, uint256 heartbeat, PriceType priceType) internal {
        _monitorFeeds.addMonitorFeed(_assetPricing, asset, priceFeed, heartbeat, priceType);
    }

    /// @notice Removes the monitor feed at `index` for an asset.
    /// @dev Delegates to PriceFeedLib.removeMonitorFeedAt via DELEGATECALL.
    function _removeMonitorFeedAt(address asset, uint256 index) internal {
        _monitorFeeds.removeMonitorFeedAt(asset, index);
    }

    /// @notice Removes the monitor feed with address `priceFeed` for an asset.
    /// @dev Delegates to PriceFeedLib.removeMonitorFeed via DELEGATECALL.
    function _removeMonitorFeed(address asset, address priceFeed) internal {
        _monitorFeeds.removeMonitorFeed(asset, priceFeed);
    }

    /// @notice Clears all monitor feeds and pricing metadata for an asset (called on full asset unregistration).
    function _removeAllMonitorFeeds(address asset) internal {
        delete _monitorFeeds[asset];
        delete _assetPricing[asset];
        emit MonitorFeedsUnset(asset);
    }

    /// @notice Sets the divergence tolerance (basis points, in (0, 10000]).
    function _setDivergenceTolerance(address asset, uint32 divergenceToleranceBps) internal {
        if (divergenceToleranceBps == 0 || divergenceToleranceBps > 10_000) {
            revert InvalidTolerance(divergenceToleranceBps);
        }
        _assetPricing[asset].divergenceToleranceBps = divergenceToleranceBps;
        emit DivergenceToleranceSet(asset, divergenceToleranceBps);
    }

    /// @notice Sets the stablecoin peg tolerance (basis points, in [0, 10000]; 0 disables the peg guard).
    function _setPegTolerance(address asset, uint32 pegToleranceBps) internal {
        if (pegToleranceBps > 10_000) revert InvalidTolerance(pegToleranceBps);
        _assetPricing[asset].pegToleranceBps = pegToleranceBps;
        emit PegToleranceSet(asset, pegToleranceBps);
    }
}
