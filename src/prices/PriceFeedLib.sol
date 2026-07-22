// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPrices} from "./IPrices.sol";
import {ICustomPriceFeed} from "./ICustomPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title PriceFeedLib
/// @notice External library hosting NAVCalculator's price-feed management AND its read/compute engine (NAV,
///         positions, health, value), extracted to keep NAVCalculator under the 24 576-byte EIP-170 limit.
/// @dev All functions are `external` so the library compiles as a separate artifact and is invoked via
///      DELEGATECALL — running in NAVCalculator's storage context through the passed `storage` references.
///      The read/compute entrypoints are computeNav / computeAccountPositions / computeNavAndPositions /
///      hasPositions / getAssetsWithPositions / healthCheck / calculateValue / buildPriceData. The position-bearing ones
///      build and consume the heavy PositionBalance[]/Position[] arrays entirely inside the library, so those
///      arrays never cross the NAV↔library ABI boundary (which is what makes piecemeal helper extraction
///      counter-productive under `via_ir`). NAV reads are off-chain eth_call, so the DELEGATECALL overhead is
///      immaterial.
///      Pre-linked at a deterministic CREATE2 address (see `foundry.toml`).
/// @author KPK
library PriceFeedLib {
    using ERC165Checker for address;
    using SafeCast for uint256;

    /// @notice Native-asset sentinel (mirrors Balances.NATIVE_ADDRESS).
    address private constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice Cached selected-feed price data for an asset (NAV read path).
    struct PriceFeedCache {
        address asset;
        int256 price;
        uint8 decimals;
        bool stale;
        // True if the primary price diverged from the asset's monitor feeds beyond tolerance (or, for stablecoins,
        // from the $1 peg). Pricing-quality signal only; `price` is still the primary and is used for valuation.
        bool irregular;
    }

    /// @notice Quote-asset info (struct + price data); address(0) = USD.
    struct QuoteAssetInfo {
        INAVCalculator.Asset assetStruct;
        int256 price;
        uint8 priceDecimals;
        uint8 assetDecimals;
        bool stale;
    }

    // -------------------------------------------------------------------------
    // Feed selection
    // -------------------------------------------------------------------------

    /// @notice Selects the freshest non-stale feed for an asset.
    /// @dev Mirrors Prices._selectFeed — see that function's NatSpec for full semantics.
    function selectFeed(mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles, address token)
        external
        view
        returns (int256 price, uint8 decimals, bool stale, uint256 winnerIdx, uint256 healthyFeedCount)
    {
        return _selectFeedCore(priceOracles, token);
    }

    /// @notice Feed-selection core, shared by the external `selectFeed` wrapper and the library's internal compute
    ///         paths (`buildPriceData`, `healthCheck`, `calculateValue`, `_getQuoteAssetInfo`, `_buildPriceFeedCache`)
    ///         so they reuse the logic via an internal jump rather than a second DELEGATECALL.
    function _selectFeedCore(mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles, address token)
        private
        view
        returns (int256 price, uint8 decimals, bool stale, uint256 winnerIdx, uint256 healthyFeedCount)
    {
        IPrices.PriceFeedConfig[] storage configs = priceOracles[token];
        uint256 len = configs.length;

        if (len == 0) revert IPrices.PriceFeedNotSet(token);

        int256 bestPrice;
        uint256 bestTime;
        uint8 bestDecimals;
        bool bestRateOnly; // winner so far is a rate-only feed (no push timestamp); a real-timestamp feed outranks it
        winnerIdx = type(uint256).max;

        for (uint256 i; i < len; ++i) {
            IPrices.PriceFeedConfig storage cfg = configs[i];
            int256 rawPrice;
            uint256 updatedAt;
            bool rateOnly; // Custom feed with no push timestamp (latestRoundData.updatedAt == 0)

            if (cfg.priceType == IPrices.PriceType.Custom) {
                uint256 customPrice;
                bool internalStale;
                try ICustomPriceFeed(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
                    customPrice = p;
                    internalStale = s;
                } catch {
                    continue;
                }
                if (internalStale || customPrice == 0) continue;
                if (customPrice > uint256(type(int256).max)) continue;
                rawPrice = int256(customPrice);
                uint256 lrdUpdatedAt;
                try ICustomPriceFeed(cfg.priceFeed).latestRoundData() returns (
                    uint80, int256, uint256, uint256 u, uint80
                ) {
                    lrdUpdatedAt = u;
                } catch {} // reverted: treat as no-timestamp oracle; sentinel updatedAt applied below
                // A rate-only feed (no push timestamp) PARTICIPATES — the block.timestamp-1 sentinel clears the
                // heartbeat gate below — but YIELDS to any feed with a real push timestamp (see the tiering at the
                // winner check, per IPrices.PriceFeedConfig). The sentinel is only for gate-passing, not ranking.
                rateOnly = lrdUpdatedAt == 0;
                updatedAt = lrdUpdatedAt == 0 ? (block.timestamp > 0 ? block.timestamp - 1 : 0) : lrdUpdatedAt;
            } else {
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
                if (cfg.priceType == IPrices.PriceType.API3) {
                    rawPrice = rawPrice / 1e10; // 18-dec → 8-dec
                    if (rawPrice == 0) continue;
                }
                updatedAt = lrdUpdatedAt;
            }

            uint256 effectiveTime = updatedAt > block.timestamp ? block.timestamp : updatedAt;

            if (block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat) continue;

            ++healthyFeedCount;

            // Tiering (IPrices.PriceFeedConfig): a real-timestamp feed always outranks a rate-only one; within
            // the same class the largest effectiveTime wins. So a rate-only custom feed can never override a fresh
            // Chainlink feed merely via the block.timestamp-1 sentinel.
            bool wins = winnerIdx == type(uint256).max // first healthy feed
                || (bestRateOnly && !rateOnly) // a real-timestamp feed beats the current rate-only leader
                || (bestRateOnly == rateOnly && effectiveTime > bestTime); // same class: freshest wins
            if (wins) {
                bestTime = effectiveTime;
                bestPrice = rawPrice;
                bestDecimals = cfg.decimals;
                bestRateOnly = rateOnly;
                winnerIdx = i;
            }
        }

        if (winnerIdx == type(uint256).max) {
            return (0, configs[0].decimals, true, type(uint256).max, 0);
        }

        return (bestPrice, bestDecimals, false, winnerIdx, healthyFeedCount);
    }

    // -------------------------------------------------------------------------
    // Divergence monitoring (primary vs monitor feeds)
    // -------------------------------------------------------------------------

    /// @notice Computes the divergence between an asset's primary price and its monitor feeds.
    /// @dev External wrapper over `_selectFeedCore` (primary) + `_monitorDivergence` (monitors). Read-only.
    /// @return primaryPrice The primary feed's price normalized to NAV_DECIMALS (0 if the primary is stale).
    /// @return monitorMedian Median of the healthy monitor prices, NAV_DECIMALS (0 if no healthy monitors).
    /// @return divergenceBps Worst-case |primary - monitor| * 1e4 / primary over the healthy monitors — the value
    ///         the `irregular` flag is thresholded on (0 if no monitors / primary stale).
    /// @return irregular True if divergenceBps exceeds the divergence tolerance, or (stablecoins) the primary
    ///         deviates from $1 beyond the peg tolerance.
    /// @return monitorFeedCount Number of healthy monitor feeds that contributed.
    /// @return primaryStale True if the primary feed is stale or the L2 sequencer is down.
    /// @return primaryAboveMonitors True if the primary is above the monitor median (a premium); false if
    ///         below/equal (for claim assets, below = the depeg direction). Meaningful only when monitorFeedCount > 0.
    /// @param sequencerDown Whether the L2 sequencer is currently down/in grace (false on L1); folded into
    ///        `primaryStale` so divergence is suppressed on an unusable price — parity with buildPriceData /
    ///        healthCheck.
    function computeDivergence(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset,
        bool sequencerDown
    )
        external
        view
        returns (
            int256 primaryPrice,
            int256 monitorMedian,
            uint256 divergenceBps,
            bool irregular,
            uint256 monitorFeedCount,
            bool primaryStale,
            bool primaryAboveMonitors
        )
    {
        (int256 price, uint8 decimals, bool stale,,) = _selectFeedCore(priceOracles, asset);
        // Treat the primary as stale during L2 sequencer downtime (parity with buildPriceData / healthCheck): the
        // price is unusable, so report primaryPrice=0, primaryStale=true and suppress the divergence/irregular flags.
        (primaryPrice, primaryStale, monitorMedian, divergenceBps, irregular, monitorFeedCount, primaryAboveMonitors) =
            _divergenceFor(monitorFeeds, assetPricing, asset, price, decimals, stale, sequencerDown);
    }

    /// @notice `irregular` flag for a primary that the caller has ALREADY selected (raw `price` in the feed's own
    ///         `decimals`). Lets a hot view that already ran feed selection (Prices.latestPrice) obtain the
    ///         divergence signal WITHOUT a second `_selectFeedCore` pass + re-read of the primary feed. Returns false
    ///         (no monitor reads) when the asset has no divergence checks. `sequencerDown` folds into staleness so
    ///         divergence is suppressed on an unusable price — parity with buildPriceData / computeDivergence.
    function irregularForSelected(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset,
        int256 price,
        uint8 decimals,
        bool feedStale,
        bool sequencerDown
    ) internal view returns (bool irregular) {
        if (!_hasDivergenceChecks(monitorFeeds, assetPricing, asset)) return false;
        (,,,, irregular,,) =
            _divergenceFor(monitorFeeds, assetPricing, asset, price, decimals, feedStale, sequencerDown);
    }

    /// @notice Shared divergence prologue used by every read path (getPriceData / latestPrice /
    ///         NAV.irregularPriceAssets / healthCheck / Position.irregular). Folds sequencer-down into staleness,
    ///         scales the primary to 8-dec (0 when stale), then runs `_monitorDivergence`. Centralizing it keeps the
    ///         normalization + staleness folding identical across all call sites (the parity the comments demand).
    function _divergenceFor(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset,
        int256 price,
        uint8 decimals,
        bool stale,
        bool sequencerDown
    )
        private
        view
        returns (
            int256 primaryPrice8,
            bool primaryStale,
            int256 monitorMedian,
            uint256 divergenceBps,
            bool irregular,
            uint256 monitorFeedCount,
            bool primaryAboveMonitors
        )
    {
        primaryStale = stale || sequencerDown;
        primaryPrice8 = primaryStale ? int256(0) : _scaleTo8(price, decimals);
        (monitorMedian, divergenceBps, irregular, monitorFeedCount, primaryAboveMonitors) =
            _monitorDivergence(monitorFeeds, assetPricing, asset, primaryPrice8, primaryStale);
    }

    /// @notice Core divergence computation given an already-selected (8-dec) primary price.
    /// @dev Reads every monitor feed for `asset`, skips stale/reverting ones (same per-feed gate as selection), and
    ///      flags `irregular` on inter-feed divergence (all types) or absolute peg deviation (stablecoins only).
    ///      The inter-feed flag is driven by the WORST single-monitor deviation (max), not an average — so a real
    ///      split can't be masked by two monitors straddling the primary. `monitorMedian` (central tendency) and
    ///      `primaryAboveMonitors` (sign vs the median) are exposed for the consumer, not used by the flag itself.
    ///      Never reverts.
    /// @return monitorMedian Median of the healthy monitor prices (NAV_DECIMALS); 0 if none.
    /// @return divergenceBps Worst-case |primary - monitor| / primary over the healthy monitors, in bps.
    /// @return irregular True if divergenceBps exceeds the divergence tolerance, or the peg guard fired.
    /// @return healthyMonitorCount Number of healthy monitors that contributed.
    /// @return primaryAboveMonitors True if the primary is above the monitor median (premium); false if below/equal
    ///         (for claim assets, below = the depeg direction). Meaningful only when healthyMonitorCount > 0.
    function _monitorDivergence(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset,
        int256 primaryPrice8,
        bool primaryStale
    )
        private
        view
        returns (
            int256 monitorMedian,
            uint256 divergenceBps,
            bool irregular,
            uint256 healthyMonitorCount,
            bool primaryAboveMonitors
        )
    {
        IPrices.PriceFeedConfig[] storage monitors = monitorFeeds[asset];
        uint256 len = monitors.length;
        int256[] memory prices = new int256[](len);
        uint256 n;
        for (uint256 i; i < len; ++i) {
            (int256 mp, bool ok) = _readFeedPrice(monitors[i]);
            if (!ok) continue;
            prices[n++] = mp;
        }

        IPrices.AssetPricing storage ap = assetPricing[asset];

        // Inter-feed divergence (all asset types): primary vs the WORST single monitor; median + sign exposed.
        // `healthyMonitorCount` (surfaced as `monitorFeedCount`) is set ONLY inside this guard, so it counts monitors
        // that actually CONTRIBUTED to the divergence check — it stays 0 when the check was suppressed (stale /
        // sequencer-down / unusable primary), rather than reporting count>0 alongside divergenceBps=0.
        if (n > 0 && !primaryStale && primaryPrice8 > 0) {
            healthyMonitorCount = n;
            _sortInPlace(prices, n);
            // Midpoint via the sorted difference (prices ascending) so the two-element sum can't overflow int256.
            monitorMedian = (n % 2 == 1) ? prices[n / 2] : prices[n / 2 - 1] + (prices[n / 2] - prices[n / 2 - 1]) / 2;
            primaryAboveMonitors = primaryPrice8 > monitorMedian;

            uint256 worst;
            for (uint256 i; i < n; ++i) {
                int256 d = primaryPrice8 - prices[i];
                if (d < 0) d = -d;
                // mulDiv (512-bit intermediate) so an extreme monitor price can't overflow uint256 and revert the read.
                uint256 bps = Math.mulDiv(uint256(d), 10_000, uint256(primaryPrice8));
                if (bps > worst) worst = bps;
            }
            divergenceBps = worst;
            if (ap.divergenceToleranceBps > 0 && worst > ap.divergenceToleranceBps) irregular = true;
        }

        // Absolute peg guard: primary vs $1 (= 10**NAV_DECIMALS). Enabled per-asset by a non-zero peg tolerance
        // (set only on assets whose fundamental value is $1, i.e. stablecoins). Independent of monitors.
        if (ap.pegToleranceBps > 0 && !primaryStale && primaryPrice8 > 0) {
            int256 one = int256(10 ** uint256(NAV_DECIMALS));
            int256 pegDiff = primaryPrice8 - one;
            if (pegDiff < 0) pegDiff = -pegDiff;
            uint256 pegBps = Math.mulDiv(uint256(pegDiff), 10_000, uint256(one));
            if (pegBps > ap.pegToleranceBps) irregular = true;
        }
    }

    /// @notice In-place insertion sort of the first `n` elements of `a` (n is a monitor count — a handful).
    function _sortInPlace(int256[] memory a, uint256 n) private pure {
        for (uint256 i = 1; i < n; ++i) {
            int256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = key;
        }
    }

    /// @notice True if an asset has anything to check for divergence: at least one monitor feed, or a non-zero peg
    ///         tolerance. When false, `irregular` is always false and the divergence computation (incl. price
    ///         normalization) can be skipped entirely.
    function _hasDivergenceChecks(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset
    ) internal view returns (bool) {
        return monitorFeeds[asset].length > 0 || assetPricing[asset].pegToleranceBps > 0;
    }

    /// @notice Reads a single feed's price applying the same validity + heartbeat gate as `_selectFeedCore`, and
    ///         normalizes the result to NAV_DECIMALS. Returns ok=false when the feed is stale, reverting, or
    ///         reports a non-positive/zero price. Used by the monitor-divergence loop.
    function _readFeedPrice(IPrices.PriceFeedConfig storage cfg) private view returns (int256 price8, bool ok) {
        int256 rawPrice;
        uint256 updatedAt;

        if (cfg.priceType == IPrices.PriceType.Custom) {
            uint256 customPrice;
            bool internalStale;
            try ICustomPriceFeed(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
                customPrice = p;
                internalStale = s;
            } catch {
                return (0, false);
            }
            if (internalStale || customPrice == 0) return (0, false);
            if (customPrice > uint256(type(int256).max)) return (0, false);
            rawPrice = int256(customPrice);
            uint256 lrdUpdatedAt;
            try ICustomPriceFeed(cfg.priceFeed).latestRoundData() returns (uint80, int256, uint256, uint256 u, uint80) {
                lrdUpdatedAt = u;
            } catch {} // reverted: treat as no-timestamp oracle; sentinel applied below
            updatedAt = lrdUpdatedAt == 0 ? (block.timestamp > 0 ? block.timestamp - 1 : 0) : lrdUpdatedAt;
        } else {
            int256 answer;
            uint256 lrdUpdatedAt;
            try AggregatorV3Interface(cfg.priceFeed).latestRoundData() returns (
                uint80, int256 a, uint256, uint256 u, uint80
            ) {
                answer = a;
                lrdUpdatedAt = u;
            } catch {
                return (0, false);
            }
            if (answer <= 0) return (0, false);
            rawPrice = answer;
            if (cfg.priceType == IPrices.PriceType.API3) {
                rawPrice = rawPrice / 1e10; // 18-dec → 8-dec
                if (rawPrice == 0) return (0, false);
            }
            updatedAt = lrdUpdatedAt;
        }

        uint256 effectiveTime = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat) return (0, false);

        return (_scaleTo8(rawPrice, cfg.decimals), true);
    }

    /// @notice Scales a price from `decimals` to NAV_DECIMALS. NEVER reverts: a pathological `decimals` (or a price
    ///         so large the scale-up would overflow) yields 0 — an unusable price that downstream treats as
    ///         no-divergence — rather than an arithmetic panic, preserving the read paths' never-revert invariant.
    ///         (Unlike monitor feeds, primary feeds are not decimals-capped at registration, so a misconfigured
    ///         primary could otherwise reach here with an out-of-range exponent.)
    function _scaleTo8(int256 price, uint8 decimals) private pure returns (int256) {
        if (decimals == NAV_DECIMALS) return price;
        if (decimals > NAV_DECIMALS) {
            uint256 exp = uint256(decimals) - NAV_DECIMALS;
            // 10 ** exp overflows uint256 (exp >= 78) or the int256 cast (exp == 77) beyond this bound → unusable.
            if (exp > MAX_DECIMAL_EXPONENT_INT256) return 0;
            return price / int256(10 ** exp);
        }
        int256 factor = int256(10 ** (uint256(NAV_DECIMALS) - uint256(decimals))); // exp <= 8 → factor <= 1e8
        if (price > type(int256).max / factor || price < type(int256).min / factor) return 0; // would overflow
        return price * factor;
    }

    // -------------------------------------------------------------------------
    // L2 sequencer uptime
    // -------------------------------------------------------------------------

    /// @notice Checks if the L2 sequencer uptime feed reports downtime or the grace period has not elapsed.
    /// @dev Mirrors Prices.checkL2SequencerUptime. Pass address(0) for uptimeFeed on L1 — returns false.
    function checkSequencerUptime(address uptimeFeed, uint256 gracePeriod) external view returns (bool stale) {
        if (uptimeFeed == address(0)) return false;

        int256 answer;
        uint256 startedAt;
        try AggregatorV3Interface(uptimeFeed).latestRoundData() returns (uint80, int256 a, uint256 s, uint256, uint80) {
            answer = a;
            startedAt = s;
        } catch {
            return true;
        }

        if (answer != 0) {
            stale = true;
        } else if (startedAt == 0) {
            stale = true;
        } else {
            uint256 effectiveStartedAt = startedAt > block.timestamp ? block.timestamp : startedAt;
            if (block.timestamp - effectiveStartedAt <= gracePeriod) stale = true;
        }
    }

    // -------------------------------------------------------------------------
    // Price-data view (extracted from NAVCalculator.getPriceData to stay under EIP-170)
    // -------------------------------------------------------------------------

    /// @notice Builds the full PriceFeedData view for an asset: selects the freshest feed, reports that feed's
    ///         config, folds in sequencer status, and fetches `updatedAt` for AggregatorV3-shaped feeds.
    /// @dev Mirrors the body of the former NAVCalculator.getPriceData. The caller is expected to have already
    ///      validated that the asset is registered and has at least one feed; `sequencerDown` is computed by the
    ///      caller (it depends on the caller's sequencer-feed config). When all feeds are stale the selected
    ///      winner index is sentinel `type(uint256).max`; this falls back to feed 0 for the reported config.
    /// @param priceOracles The per-asset feed-config storage map (caller's storage via DELEGATECALL).
    /// @param asset The asset to report.
    /// @param sequencerDown Whether the L2 sequencer is currently down/in grace (false on L1).
    /// @return priceFeedData The assembled price-feed view.
    function buildPriceData(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset,
        bool sequencerDown,
        bool withDivergence
    ) external view returns (INAVCalculator.PriceFeedData memory priceFeedData) {
        (int256 price, uint8 decimals, bool stale, uint256 winnerIdx, uint256 healthyFeedCount) =
            _selectFeedCore(priceOracles, asset);

        // Report the selected (freshest non-stale) feed's config.
        // When all feeds are stale winnerIdx == type(uint256).max; fall back to the first feed for config.
        uint256 configIdx = winnerIdx == type(uint256).max ? 0 : winnerIdx;
        IPrices.PriceFeedConfig storage config = priceOracles[asset][configIdx];

        priceFeedData.priceFeed = config.priceFeed;
        priceFeedData.priceType = config.priceType;
        priceFeedData.price = price;
        priceFeedData.decimals = decimals;
        priceFeedData.chainlinkHeartbeat = config.chainlinkHeartbeat;
        priceFeedData.stale = stale || sequencerDown;
        priceFeedData.healthyFeedCount = healthyFeedCount;

        // Fetch updatedAt for AggregatorV3-shaped feeds (Chainlink, Redstone, API3).
        if (config.priceType != IPrices.PriceType.Custom) {
            try AggregatorV3Interface(config.priceFeed).latestRoundData() returns (
                uint80, int256, uint256, uint256 roundUpdatedAt, uint80
            ) {
                priceFeedData.updatedAt = roundUpdatedAt;
            } catch {} // updatedAt stays 0 if the feed reverts
        }

        priceFeedData.sequencerDown = sequencerDown;

        // Divergence signal vs the asset's monitor feeds. Primary is treated as stale when the feed is stale or
        // the sequencer is down (either way the primary price is untrustworthy, so divergence is undefined). Skipped
        // (fields stay 0/false) when `withDivergence` is false (callers that only need the price — e.g. the
        // NAV-sourced base/USD term for custom feeds — avoid the monitor reads + sort) or the asset has no monitors
        // and no peg tolerance.
        if (withDivergence && _hasDivergenceChecks(monitorFeeds, assetPricing, asset)) {
            (,,, uint256 divergenceBps, bool irregular, uint256 monitorFeedCount,) =
                _divergenceFor(monitorFeeds, assetPricing, asset, price, decimals, stale, sequencerDown);
            priceFeedData.irregular = irregular;
            priceFeedData.divergenceBps = divergenceBps;
            priceFeedData.monitorFeedCount = monitorFeedCount;
        }
    }

    // -------------------------------------------------------------------------
    // NAV read / compute engine (extracted from NAVCalculator to stay under EIP-170)
    // -------------------------------------------------------------------------

    /// @notice Computes the full NAV snapshot for an account in a quote currency (address(0) = USD).
    /// @dev Mirrors the former NAVCalculator.getAccountNav + _readPositionsWithQuote. The caller validates the
    ///      quote asset and computes `sequencerDown` (it depends on the caller's sequencer-feed config) before
    ///      calling. All position arrays are built and consumed here, never crossing the ABI boundary.
    /// @dev The NAV-summation semantics here (quote-info fetch, empty-registry / empty-position early returns,
    ///      stale-asset build, per-position value accumulation) are intentionally duplicated in
    ///      `computeNavAndPositions` rather than shared via a helper: this lean path avoids materializing the
    ///      `Position[]` that `getAccountNav` does not need (the diff's via_ir note: helper extraction can cost
    ///      more than the inlined body). **Any change to the NAV math here MUST be mirrored in
    ///      `computeNavAndPositions` (and vice versa)** or `getAccountNav` and `getAccountNavVerbose` will diverge.
    function computeNav(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        address[] memory allAdapters,
        uint256 metaInstanceTotal,
        address account,
        address quoteAsset,
        bool sequencerDown,
        string memory nativeTokenSymbol
    ) external view returns (INAVCalculator.NAV memory nav) {
        nav.timestamp = uint64(block.timestamp);
        QuoteAssetInfo memory quoteInfo =
            _getQuoteAssetInfo(priceOracles, assetIndex, registeredAssets, quoteAsset, nativeTokenSymbol);
        nav.quoteAsset = quoteInfo.assetStruct;
        nav.quoteAssetStale = quoteInfo.stale;
        nav.quoteAssetIrregular = quoteAsset == address(0)
            ? false
            : irregularForSelected(
                monitorFeeds,
                assetPricing,
                quoteAsset,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.stale,
                sequencerDown
            );

        uint256 assetCount = registeredAssets.length;
        if (assetCount == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            nav.irregularPriceAssets = new INAVCalculator.Asset[](0);
            return nav; // value 0, sequencerDown false (no assets registered)
        }

        INAVCalculator.PositionBalance[] memory allPositions =
            _getPositionBalances(allAdapters, assetIndex, account, address(0));

        nav.sequencerDown = sequencerDown;
        if (allPositions.length == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            nav.irregularPriceAssets = new INAVCalculator.Asset[](0);
            return nav; // value 0
        }

        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);
        PriceFeedCache[] memory priceFeeds =
            _buildPriceFeedCache(priceOracles, monitorFeeds, assetPricing, assetsWithPositions, sequencerDown);
        nav.stalePriceAssets = _buildStaleAssets(assetIndex, registeredAssets, priceFeeds);
        nav.irregularPriceAssets = _buildIrregularAssets(assetIndex, registeredAssets, priceFeeds);

        int256 totalValue = 0;
        uint256 positionsLength = allPositions.length;
        for (uint256 i = 0; i < positionsLength; i++) {
            INAVCalculator.PositionBalance memory pos = allPositions[i];
            address asset = pos.balanceAsset.asset;
            PriceFeedCache memory feed = _findPriceFeed(priceFeeds, asset);
            uint8 canonicalDecimals = _getRegisteredAsset(assetIndex, registeredAssets, asset).decimals;
            totalValue += _priceConversion(
                pos.amount,
                pos.isDebt,
                canonicalDecimals,
                feed.price,
                feed.decimals,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.assetDecimals
            );
        }
        nav.value = totalValue;
    }

    /// @notice Computes enriched positions for an account, optionally filtered by a single asset
    ///         (assetFilter == address(0) means all assets). Mirrors the former NAVCalculator._getAccountPositionsInternal.
    /// @dev The caller validates the quote asset and (when set) the asset filter before calling.
    function computeAccountPositions(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        address[] memory allAdapters,
        uint256 metaInstanceTotal,
        address account,
        address assetFilter,
        address quoteAsset,
        bool sequencerDown,
        string memory nativeTokenSymbol
    ) external view returns (INAVCalculator.Position[] memory positions) {
        uint256 assetCount = registeredAssets.length;
        INAVCalculator.PositionBalance[] memory positionBalances;
        address[] memory assetsWithPositions;

        if (assetFilter == address(0)) {
            positionBalances = _getPositionBalances(allAdapters, assetIndex, account, address(0));
            assetsWithPositions = _extractUniqueAssets(positionBalances);
        } else {
            positionBalances = _getPositionBalances(allAdapters, assetIndex, account, assetFilter);
            if (positionBalances.length == 0) {
                return new INAVCalculator.Position[](0);
            }
            assetsWithPositions = new address[](1);
            assetsWithPositions[0] = assetFilter;
        }

        PriceFeedCache[] memory priceFeeds =
            _buildPriceFeedCache(priceOracles, monitorFeeds, assetPricing, assetsWithPositions, sequencerDown);
        QuoteAssetInfo memory quoteInfo =
            _getQuoteAssetInfo(priceOracles, assetIndex, registeredAssets, quoteAsset, nativeTokenSymbol);
        bool quoteAssetIrregular = quoteAsset == address(0)
            ? false
            : irregularForSelected(
                monitorFeeds,
                assetPricing,
                quoteAsset,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.stale,
                sequencerDown
            );

        uint256 length = positionBalances.length;
        positions = new INAVCalculator.Position[](length);
        for (uint256 i = 0; i < length; i++) {
            INAVCalculator.PositionBalance memory balance = positionBalances[i];
            address asset = balance.balanceAsset.asset;
            INAVCalculator.Asset memory registered = _getRegisteredAsset(assetIndex, registeredAssets, asset);
            PriceFeedCache memory feed = _findPriceFeed(priceFeeds, asset);
            positions[i] = _enrichPosition(
                balance,
                feed,
                quoteInfo.assetStruct,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.assetDecimals,
                quoteInfo.stale,
                registered.decimals,
                registered.symbol
            );
            positions[i].quoteAssetIrregular = quoteAssetIrregular;
        }
    }

    /// @notice Computes the account NAV and the full enriched position list in a single adapter scan.
    /// @dev Equivalent to calling `computeNav` and `computeAccountPositions` (with no asset filter) back to back,
    ///      but scans `allAdapters` / builds the price-feed cache only once. `nav.value` is the sum of the
    ///      per-position `value` fields (each computed by `_enrichPosition` via the same `_priceConversion`),
    ///      so the two results are guaranteed consistent. The caller validates the quote asset before calling.
    /// @dev The NAV-summation semantics here are intentionally duplicated from `computeNav` (the lean,
    ///      no-Position[] path used by `getAccountNav`); see the note on `computeNav`. **Keep the two in sync.**
    function computeNavAndPositions(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        address[] memory allAdapters,
        uint256 metaInstanceTotal,
        address account,
        address quoteAsset,
        bool sequencerDown,
        string memory nativeTokenSymbol
    ) external view returns (INAVCalculator.NAV memory nav, INAVCalculator.Position[] memory positions) {
        nav.timestamp = uint64(block.timestamp);
        QuoteAssetInfo memory quoteInfo =
            _getQuoteAssetInfo(priceOracles, assetIndex, registeredAssets, quoteAsset, nativeTokenSymbol);
        nav.quoteAsset = quoteInfo.assetStruct;
        nav.quoteAssetStale = quoteInfo.stale;
        bool quoteAssetIrregular = quoteAsset == address(0)
            ? false
            : irregularForSelected(
                monitorFeeds,
                assetPricing,
                quoteAsset,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.stale,
                sequencerDown
            );
        nav.quoteAssetIrregular = quoteAssetIrregular;

        uint256 assetCount = registeredAssets.length;
        if (assetCount == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            nav.irregularPriceAssets = new INAVCalculator.Asset[](0);
            positions = new INAVCalculator.Position[](0);
            return (nav, positions); // value 0, sequencerDown false (no assets registered)
        }

        INAVCalculator.PositionBalance[] memory allPositions =
            _getPositionBalances(allAdapters, assetIndex, account, address(0));

        nav.sequencerDown = sequencerDown;
        if (allPositions.length == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            nav.irregularPriceAssets = new INAVCalculator.Asset[](0);
            positions = new INAVCalculator.Position[](0);
            return (nav, positions); // value 0
        }

        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);
        PriceFeedCache[] memory priceFeeds =
            _buildPriceFeedCache(priceOracles, monitorFeeds, assetPricing, assetsWithPositions, sequencerDown);
        nav.stalePriceAssets = _buildStaleAssets(assetIndex, registeredAssets, priceFeeds);
        nav.irregularPriceAssets = _buildIrregularAssets(assetIndex, registeredAssets, priceFeeds);

        uint256 length = allPositions.length;
        positions = new INAVCalculator.Position[](length);
        int256 totalValue = 0;
        for (uint256 i = 0; i < length; i++) {
            INAVCalculator.PositionBalance memory balance = allPositions[i];
            INAVCalculator.Asset memory registered =
                _getRegisteredAsset(assetIndex, registeredAssets, balance.balanceAsset.asset);
            PriceFeedCache memory feed = _findPriceFeed(priceFeeds, balance.balanceAsset.asset);
            positions[i] = _enrichPosition(
                balance,
                feed,
                quoteInfo.assetStruct,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.assetDecimals,
                quoteInfo.stale,
                registered.decimals,
                registered.symbol
            );
            positions[i].quoteAssetIrregular = quoteAssetIrregular;
            totalValue += positions[i].value;
        }
        nav.value = totalValue;
    }

    /// @notice True if the account holds any non-zero position. Mirrors NAVCalculator.hasPositions (fail-open via
    ///         the per-adapter try/catch in `_getPositionBalances`).
    function hasPositions(
        address[] memory allAdapters,
        uint256 metaInstanceTotal,
        mapping(address => uint256) storage assetIndex,
        uint256 assetCount,
        address account
    ) external view returns (bool) {
        INAVCalculator.PositionBalance[] memory positions =
            _getPositionBalances(allAdapters, assetIndex, account, address(0));
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].amount != 0) return true;
        }
        return false;
    }

    /// @notice The distinct registered assets the account holds positions in. Mirrors
    ///         NAVCalculator.getAssetsWithPositions.
    function getAssetsWithPositions(
        address[] memory allAdapters,
        uint256 metaInstanceTotal,
        mapping(address => uint256) storage assetIndex,
        uint256 assetCount,
        address account
    ) external view returns (address[] memory) {
        return _extractUniqueAssets(_getPositionBalances(allAdapters, assetIndex, account, address(0)));
    }

    /// @notice Returns sequencer status and the registered assets whose price is currently stale. Mirrors
    ///         NAVCalculator.healthCheck; `sequencerDown` is computed by the caller and echoed back.
    function healthCheck(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        INAVCalculator.Asset[] storage registeredAssets,
        bool sequencerDown
    ) external view returns (bool, address[] memory stalePriceAssets, address[] memory irregularPriceAssets) {
        uint256 totalAssets = registeredAssets.length;
        if (totalAssets == 0) {
            return (sequencerDown, new address[](0), new address[](0));
        }

        address[] memory staleAssetsTemp = new address[](totalAssets);
        address[] memory irregularAssetsTemp = new address[](totalAssets);
        uint256 staleCount = 0;
        uint256 irregularCount = 0;
        for (uint256 i = 0; i < totalAssets; i++) {
            address assetAddr = registeredAssets[i].asset;
            // _selectFeedCore reverts PriceFeedNotSet(assetAddr) when the asset has no feeds (same selector as the
            // former explicit _requirePriceFeedExists guard), so no separate length check is needed here.
            (int256 price, uint8 decimals, bool stale,,) = _selectFeedCore(priceOracles, assetAddr);
            if (stale) staleAssetsTemp[staleCount++] = assetAddr;

            if (_hasDivergenceChecks(monitorFeeds, assetPricing, assetAddr)) {
                (,,,, bool irregular,,) =
                    _divergenceFor(monitorFeeds, assetPricing, assetAddr, price, decimals, stale, sequencerDown);
                if (irregular) irregularAssetsTemp[irregularCount++] = assetAddr;
            }
        }
        stalePriceAssets = ArrayLib.copySliceAddress(staleAssetsTemp, staleCount);
        irregularPriceAssets = ArrayLib.copySliceAddress(irregularAssetsTemp, irregularCount);
        return (sequencerDown, stalePriceAssets, irregularPriceAssets);
    }

    /// @notice Values explicit (asset, amount) pairs in a quote currency. Mirrors NAVCalculator.calculateValue.
    function calculateValue(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        address[] memory assetAddresses,
        uint256[] memory amounts,
        address quoteAsset,
        string memory nativeTokenSymbol
    ) external view returns (int256 value, bool quoteAssetStale) {
        if (assetAddresses.length != amounts.length) {
            revert ArrayLengthMismatch();
        }
        // For a non-USD quote, require it is registered; its feed-existence check is handled by _getQuoteAssetInfo
        // below (which reverts PriceFeedNotSet(quoteAsset) via its own guard / _selectFeedCore).
        if (quoteAsset != address(0) && assetIndex[quoteAsset] == 0) revert AssetNotFound();

        QuoteAssetInfo memory quoteInfo =
            _getQuoteAssetInfo(priceOracles, assetIndex, registeredAssets, quoteAsset, nativeTokenSymbol);
        // [9]/S2: surface that a stale non-USD quote made `_priceConversion` fall back to USD, instead of a
        // silent unit switch. (quoteInfo.stale is always false for a USD quote.)
        quoteAssetStale = quoteInfo.stale;

        value = 0;
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;

            address asset = assetAddresses[i];
            if (assetIndex[asset] == 0) revert AssetNotFound();
            uint8 assetDecimals = _getRegisteredAsset(assetIndex, registeredAssets, asset).decimals;
            // _selectFeedCore reverts PriceFeedNotSet(asset) when the asset has no feeds (same selector as the
            // former explicit guard), so no separate length check is needed.
            (int256 usdRate, uint8 usdRateDecimals,,,) = _selectFeedCore(priceOracles, asset);
            value += _priceConversion(
                amount,
                false,
                assetDecimals,
                usdRate,
                usdRateDecimals,
                quoteInfo.price,
                quoteInfo.priceDecimals,
                quoteInfo.assetDecimals
            );
        }
    }

    // -------------------------------------------------------------------------
    // Read-engine internals (private; shared by the compute entrypoints above)
    // -------------------------------------------------------------------------

    /// @notice Gathers an account's registered-asset positions across all adapters (single-leg + meta), filtered
    ///         by `assetFilter` (address(0) = all). A reverting adapter is skipped (fail-open). Mirrors the former
    ///         NAVCalculator._getPositionBalances. Each adapter is queried once and its rows retained, then a
    ///         counting pass sizes the output to the EXACT number of surviving rows (registered asset + matching
    ///         filter) — not a fixed `2·(adapters+instances)·assetCount` heuristic, which a multi-leg adapter
    ///         (e.g. the Uniswap / PancakeSwap V3 assisted adapters, up to 4 legs per LP NFT) could overflow, and not
    ///         the sum-of-all-returned-rows, which would over-allocate when rows are filtered out.
    function _getPositionBalances(
        address[] memory allAdapters,
        mapping(address => uint256) storage assetIndex,
        address account,
        address assetFilter
    ) private view returns (INAVCalculator.PositionBalance[] memory positions) {
        uint256 totalAdapters = allAdapters.length;

        // First pass: query each adapter once (the only external calls) and retain its returned rows. Extracted to
        // its own frame so the per-adapter try/catch fan-out does not inline into this function's stack (via_ir).
        INAVCalculator.PositionBalance[][] memory perAdapter = _queryAllAdapters(allAdapters, account, assetFilter);

        // Second pass (in-memory, no external calls): count exactly the rows that survive the
        // registered-asset + assetFilter predicate, so `positions` is allocated to the precise size — no
        // over-allocation from filtered-out rows, and no fixed-heuristic under-allocation that a multi-leg
        // adapter (e.g. the Uniswap/PancakeSwap V3 assisted adapters) could overflow.
        uint256 count;
        for (uint256 i = 0; i < totalAdapters; i++) {
            INAVCalculator.PositionBalance[] memory adapterPositions = perAdapter[i];
            for (uint256 j = 0; j < adapterPositions.length; j++) {
                if (_isCounted(assetIndex, adapterPositions[j].balanceAsset.asset, assetFilter)) ++count;
            }
        }

        // Third pass (in-memory): copy the surviving rows into the exactly-sized output.
        positions = new INAVCalculator.PositionBalance[](count);
        uint256 k;
        for (uint256 i = 0; i < totalAdapters; i++) {
            INAVCalculator.PositionBalance[] memory adapterPositions = perAdapter[i];
            for (uint256 j = 0; j < adapterPositions.length; j++) {
                if (_isCounted(assetIndex, adapterPositions[j].balanceAsset.asset, assetFilter)) {
                    positions[k++] = adapterPositions[j];
                }
            }
        }
    }

    /// @notice First pass of {_getPositionBalances}: query every adapter once (the only external calls) and retain
    ///         each adapter's returned rows. Kept in its own frame so the per-adapter try/catch fan-out does not
    ///         inline into the caller's stack (via_ir stack limit).
    function _queryAllAdapters(address[] memory allAdapters, address account, address assetFilter)
        private
        view
        returns (INAVCalculator.PositionBalance[][] memory perAdapter)
    {
        uint256 totalAdapters = allAdapters.length;
        perAdapter = new INAVCalculator.PositionBalance[][](totalAdapters);
        for (uint256 i = 0; i < totalAdapters; i++) {
            perAdapter[i] = _getAdapterPositions(allAdapters[i], account, assetFilter);
        }
    }

    /// @notice Whether a position row is kept: its asset must be registered, and (when an `assetFilter` is set)
    ///         must equal it. Single predicate so the count and copy passes can never diverge.
    function _isCounted(mapping(address => uint256) storage assetIndex, address asset, address assetFilter)
        private
        view
        returns (bool)
    {
        if (assetIndex[asset] == 0) return false;
        if (assetFilter != address(0) && asset != assetFilter) return false;
        return true;
    }

    /// @notice Calls an adapter's getAdapterPositions in a try/catch (fail-open: returns empty on revert). Meta
    ///         adapters read their NAV-configured instance set themselves, so the call path is uniform.
    function _getAdapterPositions(address adapter, address account, address assetFilter)
        private
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        try IBalanceAdapter(adapter).getAdapterPositions(account, assetFilter) returns (
            INAVCalculator.PositionBalance[] memory pos
        ) {
            return pos;
        } catch {
            return new INAVCalculator.PositionBalance[](0);
        }
    }

    /// @notice The de-duplicated set of assets referenced by a list of position balances.
    function _extractUniqueAssets(INAVCalculator.PositionBalance[] memory positions)
        private
        pure
        returns (address[] memory)
    {
        uint256 length = positions.length;
        address[] memory allAssets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            allAssets[i] = positions[i].balanceAsset.asset;
        }
        return ArrayLib.deduplicateAddresses(allAssets);
    }

    /// @notice Builds the selected-feed price cache (incl. the per-asset divergence `irregular` flag) for a list
    ///         of assets. Divergence treats the primary as stale exactly when its feed is stale; the NAV-level
    ///         sequencer-down flag is surfaced separately on the NAV struct.
    function _buildPriceFeedCache(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address[] memory assets,
        bool sequencerDown
    ) private view returns (PriceFeedCache[] memory priceFeeds) {
        uint256 length = assets.length;
        priceFeeds = new PriceFeedCache[](length);
        for (uint256 i = 0; i < length; i++) {
            address asset = assets[i];
            // [8]/S1 — A feedless asset that still has a live position must NOT revert the whole NAV/positions
            // read. `_selectFeedCore` reverts PriceFeedNotSet when len == 0; here in the value-aggregation path we
            // instead treat it exactly like the all-feeds-stale case: price 0, stale = true. The asset is then
            // surfaced in `nav.stalePriceAssets` and summed as a zero-value (stale) leg rather than DoS-reverting
            // the entire read. The explicit query paths (selectFeed/buildPriceData/calculateValue) keep reverting
            // PriceFeedNotSet so MANAGER tooling still sees the misconfiguration.
            if (priceOracles[asset].length == 0) {
                // decimals = NAV_DECIMALS (not 0): _priceConversion reverts InvalidAssetDecimals when
                // assetDecimals + priceDecimals < NAV_DECIMALS, so a 0 here would re-introduce a DoS for
                // low-decimal assets (e.g. USDC). NAV_DECIMALS guarantees the guard passes; price 0 → value 0.
                priceFeeds[i] =
                    PriceFeedCache({asset: asset, price: 0, decimals: NAV_DECIMALS, stale: true, irregular: false});
                continue;
            }
            (int256 price, uint8 decimals, bool stale,,) = _selectFeedCore(priceOracles, asset);
            // Only run the divergence check (and the price normalization it needs) when the asset actually has
            // monitors or a peg tolerance — otherwise `irregular` is definitionally false, and skipping avoids
            // `_scaleTo8` overflowing on a pathological high-decimals feed before the value path's own guard fires.
            // Fold the NAV-level `sequencerDown` into staleness so `NAV.irregularPriceAssets` / `Position.irregular`
            // stay consistent with getPriceData / healthCheck on L2 during sequencer downtime.
            bool irregular = false;
            if (_hasDivergenceChecks(monitorFeeds, assetPricing, asset)) {
                (,,,, irregular,,) =
                    _divergenceFor(monitorFeeds, assetPricing, asset, price, decimals, stale, sequencerDown);
            }
            priceFeeds[i] =
                PriceFeedCache({asset: asset, price: price, decimals: decimals, stale: stale, irregular: irregular});
        }
    }

    /// @notice Finds an asset's cached feed in the cache array; reverts AssetNotFound if absent.
    function _findPriceFeed(PriceFeedCache[] memory priceFeeds, address asset)
        private
        pure
        returns (PriceFeedCache memory priceFeed)
    {
        uint256 length = priceFeeds.length;
        for (uint256 i = 0; i < length; i++) {
            priceFeed = priceFeeds[i];
            if (priceFeed.asset == asset) return priceFeed;
        }
        revert AssetNotFound();
    }

    /// @notice Builds the stale-price Asset[] from the cache (the cache assets are already unique).
    function _buildStaleAssets(
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        PriceFeedCache[] memory priceFeeds
    ) private view returns (INAVCalculator.Asset[] memory staleAssets) {
        uint256 feedsLength = priceFeeds.length;
        address[] memory temp = new address[](feedsLength);
        uint256 count = 0;
        for (uint256 i = 0; i < feedsLength; i++) {
            if (priceFeeds[i].stale) temp[count++] = priceFeeds[i].asset;
        }
        address[] memory staleAddrs = ArrayLib.copySliceAddress(temp, count);

        uint256 staleLength = staleAddrs.length;
        staleAssets = new INAVCalculator.Asset[](staleLength);
        for (uint256 i = 0; i < staleLength; i++) {
            staleAssets[i] = _getRegisteredAsset(assetIndex, registeredAssets, staleAddrs[i]);
        }
    }

    /// @notice Builds the irregular-price Asset[] from the cache (peer to {_buildStaleAssets}). The `irregular`
    ///         flag was computed once per asset in {_buildPriceFeedCache} from the monitor-divergence check.
    function _buildIrregularAssets(
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        PriceFeedCache[] memory priceFeeds
    ) private view returns (INAVCalculator.Asset[] memory irregularAssets) {
        uint256 feedsLength = priceFeeds.length;
        address[] memory temp = new address[](feedsLength);
        uint256 count = 0;
        for (uint256 i = 0; i < feedsLength; i++) {
            if (priceFeeds[i].irregular) temp[count++] = priceFeeds[i].asset;
        }
        address[] memory irregularAddrs = ArrayLib.copySliceAddress(temp, count);

        uint256 irregularLength = irregularAddrs.length;
        irregularAssets = new INAVCalculator.Asset[](irregularLength);
        for (uint256 i = 0; i < irregularLength; i++) {
            irregularAssets[i] = _getRegisteredAsset(assetIndex, registeredAssets, irregularAddrs[i]);
        }
    }

    /// @notice Assembles quote-asset info (struct + price data); address(0) = USD.
    function _getQuoteAssetInfo(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        address quoteAsset,
        string memory nativeTokenSymbol
    ) private view returns (QuoteAssetInfo memory info) {
        if (quoteAsset == address(0)) {
            info.assetStruct = INAVCalculator.Asset({asset: address(0), symbol: "USD", decimals: NAV_DECIMALS});
            info.price = 0;
            info.priceDecimals = 0;
            info.assetDecimals = NAV_DECIMALS;
        } else {
            // _selectFeedCore reverts PriceFeedNotSet(quoteAsset) when the quote asset has no feeds (same selector
            // as a separate guard would), so no extra length check is needed here.
            (info.price, info.priceDecimals, info.stale,,) = _selectFeedCore(priceOracles, quoteAsset);
            INAVCalculator.Asset memory reg = _getRegisteredAsset(assetIndex, registeredAssets, quoteAsset);
            info.assetStruct = INAVCalculator.Asset({
                asset: quoteAsset,
                symbol: quoteAsset == NATIVE_ADDRESS ? nativeTokenSymbol : reg.symbol,
                decimals: reg.decimals
            });
            info.assetDecimals = reg.decimals;
        }
    }

    /// @notice Returns the registered Asset struct (decimals + symbol) for `asset`; reverts AssetNotFound if absent.
    function _getRegisteredAsset(
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        address asset
    ) private view returns (INAVCalculator.Asset memory) {
        uint256 idx = assetIndex[asset];
        if (idx == 0) revert AssetNotFound();
        return registeredAssets[idx - 1];
    }

    /// @notice Enriches a balance-only position with pricing to create a full Position. Mirrors the former
    ///         NAVCalculator._enrichPositionWithPricing.
    function _enrichPosition(
        INAVCalculator.PositionBalance memory balance,
        PriceFeedCache memory priceFeed,
        INAVCalculator.Asset memory quoteAssetStruct,
        int256 quoteAssetPrice,
        uint8 quoteAssetPriceDecimals,
        uint8 quoteAssetDecimals,
        bool quoteAssetStale,
        uint8 canonicalDecimals,
        string memory canonicalSymbol
    ) private pure returns (INAVCalculator.Position memory position) {
        int256 value = _priceConversion(
            balance.amount,
            balance.isDebt,
            canonicalDecimals,
            priceFeed.price,
            priceFeed.decimals,
            quoteAssetPrice,
            quoteAssetPriceDecimals,
            quoteAssetDecimals
        );

        // Field-by-field assignment to the named return (not a 17-field struct literal) so this stays under the
        // via_ir stack limit when inlined into the per-position enrichment loop.
        position.balanceAsset = INAVCalculator.Asset({
            asset: balance.balanceAsset.asset, symbol: canonicalSymbol, decimals: canonicalDecimals
        });
        position.balanceAdapter = balance.balanceAdapter;
        position.amount = balance.amount;
        position.isDebt = balance.isDebt;
        position.protocolBrand = balance.protocolBrand;
        position.protocolId = balance.protocolId;
        position.protocolSubId = balance.protocolSubId;
        position.positionId = balance.positionId;
        position.positionKind = balance.positionKind;
        position.isLocked = balance.isLocked;
        position.positionInstanceId = balance.positionInstanceId;
        position.quoteAsset = quoteAssetStruct;
        position.value = value;
        position.price = priceFeed.price;
        position.priceDecimals = priceFeed.decimals;
        position.stale = priceFeed.stale;
        position.irregular = priceFeed.irregular;
        position.quoteAssetStale = quoteAssetStale;
    }

    /// @notice Converts an amount of one asset to value in quote (USD when quotePrice is non-positive). Mirrors the
    ///         former NAVCalculator._priceConversion.
    function _priceConversion(
        uint256 amount,
        bool isDebt,
        uint8 assetDecimals,
        int256 assetPrice,
        uint256 assetPriceDecimals,
        int256 quotePrice,
        uint8 quotePriceDecimals,
        uint8 quoteDecimals
    ) private pure returns (int256 value) {
        if (assetDecimals + assetPriceDecimals < NAV_DECIMALS) {
            revert InvalidAssetDecimals();
        }
        uint256 denom1 = assetDecimals + assetPriceDecimals - NAV_DECIMALS;
        if (denom1 > MAX_DECIMAL_EXPONENT || denom1 > MAX_DECIMAL_EXPONENT_INT256) {
            revert InvalidDecimalExponent();
        }

        int256 signedAmount = isDebt ? -SafeCast.toInt256(amount) : SafeCast.toInt256(amount);
        int256 usdValue = (signedAmount * assetPrice) / SafeCast.toInt256(10 ** denom1);

        if (quotePrice <= 0) {
            return usdValue; // USD (NAV_DECIMALS)
        }

        uint256 totalDecimals = uint256(quoteDecimals) + uint256(quotePriceDecimals);
        if (totalDecimals > MAX_DECIMAL_EXPONENT || totalDecimals > MAX_DECIMAL_EXPONENT_INT256) {
            revert InvalidDecimalExponent();
        }
        int256 numerator = usdValue * SafeCast.toInt256(10 ** totalDecimals);
        int256 denom2 = quotePrice * SafeCast.toInt256(10 ** NAV_DECIMALS);
        return numerator / denom2;
    }

    // -------------------------------------------------------------------------
    // Feed registration / deregistration
    // -------------------------------------------------------------------------

    /// @notice Validates that a price feed contract is suitable for the given type at registration time.
    function validateFeedSupport(address token, address priceFeed, IPrices.PriceType priceType) external view {
        _validateFeedSupportInternal(token, priceFeed, priceType);
    }

    /// @notice Adds a price feed for an asset. Reverts on duplicates or decimal mismatch.
    /// @notice Resolves a feed's on-chain decimals by type — shared by addFeed/addMonitorFeed. API3 dAPIs must be
    ///         18-dec at source (the read path scales them to 8); Custom/Chainlink/Redstone report their own.
    function _resolveFeedDecimals(address priceFeed, IPrices.PriceType priceType) private view returns (uint8 dec) {
        if (priceType == IPrices.PriceType.Custom) {
            dec = ICustomPriceFeed(priceFeed).decimals();
        } else if (priceType == IPrices.PriceType.API3) {
            if (AggregatorV3Interface(priceFeed).decimals() != 18) revert IPrices.InvalidPriceOracle();
            dec = 8;
        } else {
            dec = AggregatorV3Interface(priceFeed).decimals();
        }
    }

    /// @notice Swap-and-pop the feed at `index` from `arr` — shared array mutation for price- and monitor-feed
    ///         removals (which differ only in the events they emit, so the caller emits). Returns the removed feed,
    ///         the feed moved into the hole (address(0) if none), the index it moved FROM, and whether a move happened.
    function _swapPopFeed(IPrices.PriceFeedConfig[] storage arr, uint256 index)
        private
        returns (address removedFeed, address movedFeed, uint256 movedFrom, bool didMove)
    {
        movedFrom = arr.length - 1;
        removedFeed = arr[index].priceFeed;
        if (index != movedFrom) {
            movedFeed = arr[movedFrom].priceFeed;
            arr[index] = arr[movedFrom];
            didMove = true;
        }
        arr.pop();
    }

    function addFeed(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        address asset,
        address priceFeed,
        uint256 heartbeat,
        IPrices.PriceType priceType
    ) external {
        _validateFeedSupportInternal(asset, priceFeed, priceType);

        if (heartbeat == 0) revert IPrices.InvalidPriceOracle();

        IPrices.PriceFeedConfig[] storage configs = priceOracles[asset];
        uint256 len = configs.length;
        for (uint256 i; i < len; ++i) {
            if (configs[i].priceFeed == priceFeed) revert IPrices.PriceFeedAlreadyRegistered(asset, priceFeed);
        }

        uint8 dec = _resolveFeedDecimals(priceFeed, priceType);

        if (len > 0 && configs[0].decimals != dec) {
            revert IPrices.PriceFeedDecimalsMismatch(asset, configs[0].decimals, dec);
        }

        configs.push(
            IPrices.PriceFeedConfig({
                priceFeed: priceFeed, priceType: priceType, decimals: dec, chainlinkHeartbeat: heartbeat
            })
        );

        emit IPrices.PriceFeedAdded(asset, priceFeed, heartbeat, priceType, len);
    }

    /// @notice Removes the feed at `index` for an asset. Reverts if it is the last feed.
    function removeFeedAt(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        address asset,
        uint256 index
    ) external {
        IPrices.PriceFeedConfig[] storage configs = priceOracles[asset];

        if (index >= configs.length) revert IPrices.PriceFeedIndexOutOfBounds(asset, index);
        if (configs.length == 1) revert IPrices.CannotRemoveLastFeed(asset);

        (address removedFeed, address movedFeed, uint256 movedFrom, bool didMove) = _swapPopFeed(configs, index);
        if (didMove) emit IPrices.PriceFeedIndexChanged(asset, movedFeed, movedFrom, index);
        emit IPrices.PriceFeedRemoved(asset, removedFeed, index);
    }

    /// @notice Removes the feed with address `priceFeed` for an asset. Reverts if not found or last feed.
    function removeFeed(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        address asset,
        address priceFeed
    ) external {
        IPrices.PriceFeedConfig[] storage configs = priceOracles[asset];
        uint256 len = configs.length;

        for (uint256 i; i < len; ++i) {
            if (configs[i].priceFeed == priceFeed) {
                if (len == 1) revert IPrices.CannotRemoveLastFeed(asset);
                (, address movedFeed, uint256 movedFrom, bool didMove) = _swapPopFeed(configs, i);
                if (didMove) emit IPrices.PriceFeedIndexChanged(asset, movedFeed, movedFrom, i);
                emit IPrices.PriceFeedRemoved(asset, priceFeed, i);
                return;
            }
        }

        revert IPrices.PriceFeedNotFound(asset, priceFeed);
    }

    // -------------------------------------------------------------------------
    // Monitor feed registration / deregistration
    // -------------------------------------------------------------------------

    /// @notice Adds a monitor (divergence-only) feed for an asset. Requires the divergence tolerance to be set
    ///         first (>0) and the feed to report NAV_DECIMALS decimals. Reverts on duplicates.
    function addMonitorFeed(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset,
        address priceFeed,
        uint256 heartbeat,
        IPrices.PriceType priceType
    ) external {
        _validateFeedSupportInternal(asset, priceFeed, priceType);

        if (heartbeat == 0) revert IPrices.InvalidPriceOracle();
        if (assetPricing[asset].divergenceToleranceBps == 0) revert IPrices.DivergenceToleranceRequired(asset);

        uint8 dec = _resolveFeedDecimals(priceFeed, priceType);
        // Monitors must be USD-comparable to the primary (always NAV_DECIMALS).
        if (dec != NAV_DECIMALS) revert IPrices.MonitorFeedDecimalsMismatch(asset, NAV_DECIMALS, dec);

        IPrices.PriceFeedConfig[] storage monitors = monitorFeeds[asset];
        uint256 len = monitors.length;
        for (uint256 i; i < len; ++i) {
            if (monitors[i].priceFeed == priceFeed) revert IPrices.MonitorFeedAlreadyRegistered(asset, priceFeed);
        }

        monitors.push(
            IPrices.PriceFeedConfig({
                priceFeed: priceFeed, priceType: priceType, decimals: dec, chainlinkHeartbeat: heartbeat
            })
        );

        emit IPrices.MonitorFeedAdded(asset, priceFeed, heartbeat, priceType, len);
    }

    /// @notice Removes the monitor feed at `index` for an asset. Monitor feeds are optional — the last one may be
    ///         removed (no CannotRemoveLastFeed guard).
    function removeMonitorFeedAt(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        address asset,
        uint256 index
    ) external {
        IPrices.PriceFeedConfig[] storage monitors = monitorFeeds[asset];

        if (index >= monitors.length) revert IPrices.PriceFeedIndexOutOfBounds(asset, index);

        (address removedFeed, address movedFeed, uint256 movedFrom, bool didMove) = _swapPopFeed(monitors, index);
        if (didMove) emit IPrices.MonitorFeedIndexChanged(asset, movedFeed, movedFrom, index);
        emit IPrices.MonitorFeedRemoved(asset, removedFeed, index);
    }

    /// @notice Removes the monitor feed with address `priceFeed` for an asset. Reverts if not found.
    function removeMonitorFeed(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        address asset,
        address priceFeed
    ) external {
        IPrices.PriceFeedConfig[] storage monitors = monitorFeeds[asset];
        uint256 len = monitors.length;

        for (uint256 i; i < len; ++i) {
            if (monitors[i].priceFeed == priceFeed) {
                (, address movedFeed, uint256 movedFrom, bool didMove) = _swapPopFeed(monitors, i);
                if (didMove) emit IPrices.MonitorFeedIndexChanged(asset, movedFeed, movedFrom, i);
                emit IPrices.MonitorFeedRemoved(asset, priceFeed, i);
                return;
            }
        }

        revert IPrices.MonitorFeedNotFound(asset, priceFeed);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    function _validateFeedSupportInternal(address token, address priceFeed, IPrices.PriceType priceType) private view {
        if (priceFeed == address(0) || token == address(0)) revert IPrices.InvalidPriceOracle();
        if (priceType == IPrices.PriceType.Custom) {
            if (!priceFeed.supportsInterface(type(ICustomPriceFeed).interfaceId)) revert IPrices.InvalidPriceOracle();
        } else if (
            priceType == IPrices.PriceType.Chainlink || priceType == IPrices.PriceType.Redstone
                || priceType == IPrices.PriceType.API3
        ) {
            if (priceFeed.supportsInterface(type(ICustomPriceFeed).interfaceId)) {
                revert IPrices.InvalidPriceOracle();
            }
            (, int256 answer, uint256 startedAt, uint256 updatedAt,) =
                AggregatorV3Interface(priceFeed).latestRoundData();
            if (answer <= 0 || updatedAt == 0) revert IPrices.InvalidPriceOracle();
            if (updatedAt > block.timestamp || startedAt > block.timestamp) revert IPrices.InvalidPriceOracle();
        } else {
            revert IPrices.InvalidPriceOracleType();
        }
    }
}
