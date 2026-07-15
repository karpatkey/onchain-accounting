// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPrices} from "./IPrices.sol";
import {PriceFeedLib} from "./PriceFeedLib.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Prices
/// @notice Manages multiple price feeds per asset, returning the freshest non-stale value on each read.
/// @dev The read path applies a per-feed staleness gate and then picks the feed with the largest
/// effectiveUpdatedAt (clamped to block.timestamp to avoid upstream-clock bias). stale=true
/// is returned only when every registered feed fails the staleness gate.
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

    /// @notice Price feed configurations per asset (multiple feeds supported for redundancy)
    mapping(address asset => PriceFeedConfig[] feeds) internal _priceOracles;

    /// @notice Per-asset growth-cap config for yield-bearing CAPO feeds (ADR 0021). Read by the immutable feed via
    ///         {getRateCap}; mutated only through the MANAGER-gated setters on NAVCalculator. Keeping it here (not on
    ///         the feed) is what lets the feeds stay immutable.
    mapping(address asset => RateCap cap) internal _rateCaps;

    /// @dev Reserved storage gap for future Prices expansions (49 slots; one consumed by `_rateCaps`).
    // solhint-disable-next-line var-name-mixedcase
    uint256[49] private __pricesGap;

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
    function latestPrice(address token) external view returns (int256 price, uint8 decimals, bool stale) {
        (price, decimals, stale,,) = _selectFeed(token);
        stale = checkL2SequencerUptime() || stale;
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
    function getRateCap(address asset) external view returns (RateCap memory) {
        return _rateCaps[asset];
    }

    /// @notice Sets an asset's max-APR growth cap (bps/yr). MANAGER-gated at the NAVCalculator level.
    function _setRateCapApr(address asset, uint256 maxAprBps) internal {
        _rateCaps[asset].maxAprBps = maxAprBps;
        emit RateCapAprSet(asset, maxAprBps);
    }

    /// @notice (Re-)snapshots an asset's rate baseline; the growth cap ratchets forward from here. MANAGER-gated.
    function _setRateCapSnapshot(address asset, uint256 snapshotRate) internal {
        _rateCaps[asset].snapshotRate = snapshotRate;
        _rateCaps[asset].snapshotTimestamp = uint64(block.timestamp);
        emit RateCapSnapshotUpdated(asset, snapshotRate, uint64(block.timestamp));
    }

    /// @notice Returns the latest price for a given token without checking the L2 sequencer uptime.
    function _latestPrice(address token) internal view returns (int256 price, uint8 decimals, bool stale) {
        (price, decimals, stale,,) = _selectFeed(token);
    }

    /// @notice Selects the freshest non-stale feed for an asset.
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
}
