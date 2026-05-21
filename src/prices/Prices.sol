// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPrices} from "./IPrices.sol";
import {IPriceFeedCustom} from "./IPriceFeedCustom.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Prices
/// @notice Manages multiple price feeds per asset, returning the freshest non-stale value on each read.
/// @dev The read path applies a per-feed staleness gate and then picks the feed with the largest
/// effectiveUpdatedAt (clamped to block.timestamp to avoid upstream-clock bias). stale=true
/// is returned only when every registered feed fails the staleness gate.
/// @author kpk
abstract contract Prices is IPrices, Initializable {
    //
    // Libraries
    //
    using ERC165Checker for address;
    using SafeCast for uint256;

    /// @notice Grace period for L2 sequencer downtime
    uint256 public chainlinkL2SequencerGracePeriod;

    /// @notice Uptime feed for L2 sequencer
    AggregatorV3Interface public chainlinkL2SequencerUptimeFeed;

    /// @notice Price feed configurations per asset (multiple feeds supported for redundancy)
    mapping(address asset => PriceFeedConfig[] feeds) internal _priceOracles;

    /// @dev Reserved storage gap for future Prices expansions (50 slots).
    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __pricesGap;

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

    /// @notice Returns the latest price for a given token without checking the L2 sequencer uptime.
    function _latestPrice(address token) internal view returns (int256 price, uint8 decimals, bool stale) {
        (price, decimals, stale,,) = _selectFeed(token);
    }

    /// @notice Selects the freshest non-stale feed for an asset.
    /// @dev All non-Custom (AggregatorV3-shaped) feed types share the same read path. Custom feeds are
    /// gated by their internal stale signal first, then use latestRoundData() for freshness comparison.
    /// Clock-skew: updatedAt is clamped to block.timestamp so a feed with a future timestamp cannot
    /// systematically beat on-chain-push feeds (Chainlink/Redstone). A Custom feed returning
    /// updatedAt == 0 ("no trackable oracle") is treated as block.timestamp - 1 so it participates
    /// but loses any tie against a feed that just refreshed.
    /// @param token The asset address.
    /// @return price Selected price (0 if all stale).
    /// @return decimals Decimals of the selected feed's output (first feed's decimals if all stale).
    /// @return stale True if no feed survived the staleness gate.
    /// @return winnerIdx Index of the selected feed; type(uint256).max when all stale.
    /// @return healthyFeedCount Number of feeds that passed all staleness gates. Below the total registered
    ///         count signals partial redundancy collapse (off-chain alerting via getPriceData recommended).
    function _selectFeed(address token)
        internal
        view
        returns (int256 price, uint8 decimals, bool stale, uint256 winnerIdx, uint256 healthyFeedCount)
    {
        PriceFeedConfig[] storage configs = _priceOracles[token];
        uint256 len = configs.length;

        if (len == 0) revert PriceFeedNotSet(token);

        int256 bestPrice;
        uint256 bestTime;
        uint8 bestDecimals;
        winnerIdx = type(uint256).max;

        for (uint256 i; i < len; ++i) {
            PriceFeedConfig storage cfg = configs[i];
            int256 rawPrice;
            uint256 updatedAt;

            if (cfg.priceType == PriceType.Custom) {
                // Custom feeds gate on their internal staleness signal first.
                uint256 customPrice;
                bool internalStale;
                try IPriceFeedCustom(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
                    customPrice = p;
                    internalStale = s;
                } catch {
                    continue;
                }
                if (internalStale || customPrice == 0) continue;
                rawPrice = customPrice.toInt256();
                // latestRoundData() provides updatedAt for freshness comparison.
                // updatedAt == 0 means "no trackable oracle" (e.g. an on-chain rate-only feed);
                // treat as block.timestamp - 1 so the feed participates but yields to any feed with
                // a real on-chain push timestamp.
                uint256 lrdUpdatedAt;
                try IPriceFeedCustom(cfg.priceFeed).latestRoundData() returns (
                    uint80, int256, uint256, uint256 u, uint80
                ) {
                    lrdUpdatedAt = u;
                } catch {
                    continue;
                }
                updatedAt = lrdUpdatedAt == 0 ? (block.timestamp > 0 ? block.timestamp - 1 : 0) : lrdUpdatedAt;
            } else {
                // Chainlink / Redstone / API3 — all implement AggregatorV3Interface.
                int256 answer;
                uint256 lrdUpdatedAt;
                try AggregatorV3Interface(cfg.priceFeed).latestRoundData() returns (
                    uint80, int256 a, uint256, uint256 u, uint80
                ) {
                    answer = a;
                    lrdUpdatedAt = u;
                } catch {
                    continue;
                }
                if (answer <= 0) continue;
                rawPrice = answer;
                updatedAt = lrdUpdatedAt;
            }

            // Clock-skew normalisation: clamp future timestamps to block.timestamp.
            uint256 effectiveTime = updatedAt > block.timestamp ? block.timestamp : updatedAt;

            // Per-feed staleness gate (>= aligns with the documented heartbeat semantic: stale after N seconds).
            if (block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat) continue;

            // Feed survived all gates — count it.
            ++healthyFeedCount;

            // Select the feed with the largest effective update time.
            if (effectiveTime > bestTime) {
                bestTime = effectiveTime;
                bestPrice = rawPrice;
                bestDecimals = cfg.decimals;
                winnerIdx = i;
            }
        }

        if (winnerIdx == type(uint256).max) {
            // All feeds stale: return the first feed's decimals for unit consistency downstream.
            return (0, configs[0].decimals, true, type(uint256).max, 0);
        }

        return (bestPrice, bestDecimals, false, winnerIdx, healthyFeedCount);
    }

    /// @inheritdoc IPrices
    function checkL2SequencerUptime() public view returns (bool stale) {
        stale = false;

        if (address(chainlinkL2SequencerUptimeFeed) != address(0)) {
            int256 answer;
            uint256 startedAt;
            try chainlinkL2SequencerUptimeFeed.latestRoundData() returns (
                uint80, int256 a, uint256 s, uint256, uint80
            ) {
                answer = a;
                startedAt = s;
            } catch {
                return true;
            }

            if (answer != 0) {
                stale = true;
            } else if (startedAt == 0) {
                // Arbitrum uptime feeds can return startedAt == 0 before initialization.
                stale = true;
            } else {
                // Make sure the grace period has passed after the
                // sequencer is back up.
                uint256 timeSinceUp = block.timestamp - startedAt;

                if (timeSinceUp <= chainlinkL2SequencerGracePeriod) stale = true;
            }
        }
    }

    /// @inheritdoc IPrices
    function checkPriceOracleSupport(address token, address priceFeed, PriceType priceType) public view {
        if (priceFeed == address(0) || token == address(0)) revert InvalidPriceOracle();
        if (priceType == PriceType.Custom) {
            if (!priceFeed.supportsInterface(type(IPriceFeedCustom).interfaceId)) revert InvalidPriceOracle();
        } else if (priceType == PriceType.Chainlink || priceType == PriceType.Redstone || priceType == PriceType.API3) {
            // Reject contracts that explicitly identify as IPriceFeedCustom — AggregatorV3-shaped feed
            // types and Custom are mutually exclusive.
            // ERC165Checker.supportsInterface() returns false (not revert) when the feed doesn't
            // implement ERC165, so this is safe to call on Chainlink/Redstone/API3 contracts.
            if (priceFeed.supportsInterface(type(IPriceFeedCustom).interfaceId)) revert InvalidPriceOracle();
            (,, uint256 startedAt, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
            // Reject feeds reporting future timestamps — guard against clock-skewed or malicious feeds
            // at registration time.
            if (updatedAt > block.timestamp || startedAt > block.timestamp) revert InvalidPriceOracle();
        } else {
            revert InvalidPriceOracleType();
        }
    }

    /// @notice Adds a price feed for an asset. The asset must be registered at the caller level.
    /// @dev Reverts if the feed address is already registered for this asset (deduplication).
    /// @param asset The asset address.
    /// @param priceFeed The price feed address.
    /// @param heartbeat Staleness threshold in seconds (must be non-zero).
    /// @param priceType The feed type.
    function _addPriceFeed(address asset, address priceFeed, uint256 heartbeat, PriceType priceType) internal {
        checkPriceOracleSupport(asset, priceFeed, priceType);

        if (heartbeat == 0) revert InvalidPriceOracle();

        // Disallow duplicate feeds for the same asset.
        PriceFeedConfig[] storage configs = _priceOracles[asset];
        uint256 len = configs.length;
        for (uint256 i; i < len; ++i) {
            if (configs[i].priceFeed == priceFeed) revert PriceFeedAlreadyRegistered(asset, priceFeed);
        }

        uint8 dec;
        if (priceType == PriceType.Custom) {
            dec = IPriceFeedCustom(priceFeed).decimals();
        } else {
            dec = AggregatorV3Interface(priceFeed).decimals();
        }

        if (len > 0 && configs[0].decimals != dec) {
            revert PriceFeedDecimalsMismatch(asset, configs[0].decimals, dec);
        }

        configs.push(
            PriceFeedConfig({priceFeed: priceFeed, priceType: priceType, decimals: dec, chainlinkHeartbeat: heartbeat})
        );

        emit PriceFeedAdded(asset, priceFeed, heartbeat, priceType, len); // `len` == old length == new index
    }

    /// @notice Removes the feed at `index` for an asset. Reverts if it is the last feed.
    /// @dev Swap-with-last + pop to avoid storage gaps.
    function _removePriceFeedAt(address asset, uint256 index) internal {
        PriceFeedConfig[] storage configs = _priceOracles[asset];
        uint256 len = configs.length;

        if (index >= len) revert PriceFeedIndexOutOfBounds(asset, index);
        if (len == 1) revert CannotRemoveLastFeed(asset);

        address removedFeed = configs[index].priceFeed;

        // Swap-with-last + pop (O(1), order not preserved).
        if (index != len - 1) {
            configs[index] = configs[len - 1];
        }
        configs.pop();

        emit PriceFeedRemoved(asset, removedFeed, index);
    }

    /// @notice Removes the feed with address `priceFeed` for an asset. Reverts if not found or last feed.
    function _removePriceFeed(address asset, address priceFeed) internal {
        PriceFeedConfig[] storage configs = _priceOracles[asset];
        uint256 len = configs.length;

        for (uint256 i; i < len; ++i) {
            if (configs[i].priceFeed == priceFeed) {
                _removePriceFeedAt(asset, i);
                return;
            }
        }

        revert PriceFeedNotFound(asset, priceFeed);
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
