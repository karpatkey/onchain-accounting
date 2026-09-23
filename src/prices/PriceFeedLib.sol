// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPrices} from "./IPrices.sol";
import {ICustomPriceFeed} from "./ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "./INavSourcedPriceFeed.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IMetaBalanceAdapter} from "src/balances/IMetaBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {ArrayLib} from "src/utils/ArrayLib.sol";
import {GasStipendLib} from "src/utils/GasStipendLib.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @notice Minimal view of `NAVCalculator`'s `decodeStringArray` shim, which stays on the CONTRACT rather than moving
///         here with the rest of the verbose read path.
/// @dev It must stay there because `try`/`catch` requires an EXTERNAL call, and it is guarded by
///      `msg.sender != address(this)` so it is not usable as public API. That guard keeps working across this move
///      unchanged: {PriceFeedLib} runs under DELEGATECALL, so `address(this)` is still the NAVCalculator proxy and the
///      call it makes to itself arrives with `msg.sender == address(this)`. **Do not weaken or remove that guard**, and
///      do not "simplify" this into a direct `abi.decode` here — the whole point is that the decode can revert and only
///      an external call can be wrapped in `try`/`catch`.
interface INavLabelDecoder {
    function decodeStringArray(bytes calldata data) external view returns (string[] memory);
}

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
        // True if the asset HAS monitors configured but none of them was readable, so the MONITOR-DIVERGENCE check
        // did not run. It says nothing about `irregular` above, which is NOT necessarily false in this state: the
        // absolute peg guard is monitor-independent, so a stablecoin with a non-zero `pegToleranceBps` trading off $1
        // is `irregular` AND `monitorsUnhealthy` at the same time — divergence unchecked, peg breached. NOT set for an
        // asset with no monitors configured, nor when the primary is unusable — see
        // {INAVCalculator.NAV.monitorsUnhealthyPriceAssets}.
        bool monitorsUnhealthy;
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
        //
        // NOTE: `pegToleranceBps` has a SECOND consumer off this path — `AssetKindRegistry` derives `PegKind` from it
        // (non-zero => Pegged). So it is not purely a local pricing knob any more; zeroing it also reclassifies the
        // asset. See the warning on `NAVCalculator.setPegTolerance`.
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

        // Report the freshness pair (updatedAt, chainlinkHeartbeat) of the selected feed.
        if (config.priceType == IPrices.PriceType.Custom) {
            // Custom feeds are composites whose staleness is per-underlying-leg, so a single (updatedAt, heartbeat)
            // can't be read off latestRoundData (which returns the worst-case/min timestamp with no companion
            // heartbeat). Instead report the "governing leg" — the underlying Chainlink leg closest to its own
            // staleness limit — so the pair is a real, matched pair from one oracle (a single-leg custom feed reports
            // that leg). This OVERRIDES the config heartbeat set above. See ICustomPriceFeed.governingFeedFreshness.
            try ICustomPriceFeed(config.priceFeed).governingFeedFreshness() returns (
                uint256 govUpdatedAt, uint256 govHeartbeat
            ) {
                priceFeedData.updatedAt = govUpdatedAt;
                priceFeedData.chainlinkHeartbeat = govHeartbeat;
            } catch {} // updatedAt stays 0 / heartbeat stays the registered config value if the feed reverts
        } else {
            // AggregatorV3-shaped feeds (Chainlink, Redstone, API3): report the selected feed's own updatedAt against
            // its configured heartbeat (already set above). A revert leaves updatedAt at 0.
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

    /// @notice Validates a caller-supplied adapter slice for the paginated NAV read and returns it as a memory
    ///         array, ready to hand straight to {computeNav} as its `allAdapters` argument.
    /// @dev Every rejection here is a case that would otherwise return a plausible-looking slice with a wrong
    ///      `value`, which is strictly worse than a revert because the caller sums it and never finds out:
    ///
    ///      - **Empty** → a zero NAV indistinguishable from "worth nothing".
    ///      - **Unregistered** → no positions to report, so the slice is short by whatever the caller thought that
    ///        address covered, and `adaptersCovered` can no longer be read as a coverage record.
    ///      - **Duplicate** → the adapter is queried and summed twice, over-reporting the slice by its full value.
    ///
    ///      Lives here rather than in NAVCalculator purely for EIP-170 headroom (that contract is a few hundred
    ///      bytes from the limit), and is a separate function from {computeNav} rather than a branch inside it so
    ///      the complete read pays nothing for the partial read's existence — neither in gas nor in the `via_ir`
    ///      compile cost of that function's IR.
    ///
    ///      Both scans are over memory arrays with no external calls: O(n²) for the duplicate check and O(n·m)
    ///      against the registry, with an adapter registry in the tens. A few thousand gas against a read costing
    ///      tens of millions. A registration mapping or a sorted-input requirement would each be cheaper and
    ///      neither is worth it — the sorted variant would also push a correctness obligation onto the caller,
    ///      which is the opposite of this API's design.
    /// @param allAdapters The FULL global adapter registry (`getAllAdapters()`), the authority every supplied
    ///        adapter is checked against. Passing the complete list rather than a registration mapping makes
    ///        "registered" mean exactly "in the list the complete read scans".
    /// @param adapters The caller's slice.
    /// @return covered `adapters` copied to memory, order preserved — both {computeNav}'s scan list and the
    ///         `PartialNAV.adaptersCovered` receipt, so the two can never disagree.
    function validateAdapterSlice(address[] memory allAdapters, address[] calldata adapters)
        external
        pure
        returns (address[] memory covered)
    {
        uint256 len = adapters.length;
        if (len == 0) revert INAVCalculator.EmptyAdapterSlice();

        covered = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            address adapter = adapters[i];

            // Duplicate check against what has already been accepted, so the FIRST repeat is what gets named
            // rather than whichever element a full pairwise sweep reached last. Scans the already-copied prefix of
            // `covered`, which is element-for-element `adapters[0..i)`, so this is the same comparison one memory
            // read cheaper than re-reading calldata.
            for (uint256 j = 0; j < i; j++) {
                if (covered[j] == adapter) revert INAVCalculator.DuplicateAdapterInSlice(adapter);
            }

            bool registered;
            uint256 total = allAdapters.length;
            for (uint256 k = 0; k < total; k++) {
                if (allAdapters[k] == adapter) {
                    registered = true;
                    break;
                }
            }
            if (!registered) revert INAVCalculator.AdapterNotRegistered(adapter);

            covered[i] = adapter;
        }
    }

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
    ///
    ///      **This is also the PAGINATED read.** `NAVCalculator.getAccountNavForAdapters` calls this very function
    ///      with a caller-supplied subset of `getAllAdapters()` in `allAdapters`, having first run that subset
    ///      through {validateAdapterSlice}. There is deliberately no second NAV entrypoint for the partial read:
    ///      one existed during development and was removed, because a second copy of this body roughly doubles the
    ///      IR the `via_ir` optimizer has to chew through for the largest function in the largest library here, and
    ///      that was enough to push CI's whole-project compile past the runner's memory (SIGTERM mid-compile, twice,
    ///      reproducibly). Sharing this function instead costs nothing and makes the partition invariant — sum of
    ///      slices == complete NAV — hold because it is literally the same code, not because two bodies agree.
    ///
    ///      Consequently **nothing in this function may become adapter-set-dependent beyond scanning
    ///      `allAdapters`.** Anything derived from "the whole registry" rather than from the adapters passed in
    ///      would silently change meaning for a slice.
    ///
    /// @dev **STACK BUDGET — this function sits AT the `via_ir` stack limit. Adding a local, a parameter, or an
    ///      inlined call here will overflow it.** Five storage pointers (`priceOracles`, `monitorFeeds`,
    ///      `assetPricing`, `assetIndex`, `registeredAssets`) plus `sequencerDown` and the `nav` return struct stay
    ///      live for the whole body, and the optimizer inlines the position-gathering helpers, so their loop
    ///      counters land in this frame too. The failure mode is a compile error — `Variable ... is 1 too deep in
    ///      the stack` — NOT a test failure, and because `via_ir` allocates across the whole compilation unit it can
    ///      appear in CI while a warm local build passes. **Reproduce with `forge clean` first;** a warm cache hides
    ///      it. If you must add something here, free a slot the way {_sumPositionValues} did: move a block of locals
    ///      into a `private` helper so they are live in that frame instead of this one. Packing the storage pointers
    ///      into a struct is NOT an option — Solidity cannot hold storage references in a memory struct.
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
            nav.monitorsUnhealthyPriceAssets = new INAVCalculator.Asset[](0);
            return nav; // value 0, sequencerDown false (no assets registered)
        }

        INAVCalculator.PositionBalance[] memory allPositions =
            _getPositionBalances(allAdapters, assetIndex, account, address(0));

        nav.sequencerDown = sequencerDown;
        if (allPositions.length == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            nav.irregularPriceAssets = new INAVCalculator.Asset[](0);
            nav.monitorsUnhealthyPriceAssets = new INAVCalculator.Asset[](0);
            return nav; // value 0
        }

        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);
        PriceFeedCache[] memory priceFeeds =
            _buildPriceFeedCache(priceOracles, monitorFeeds, assetPricing, assetsWithPositions, sequencerDown);
        _assignHealthArrays(nav, assetIndex, registeredAssets, priceFeeds);

        nav.value = _sumPositionValues(assetIndex, registeredAssets, allPositions, priceFeeds, quoteInfo);
    }

    /// @notice Sums every position's quote-denominated value. Extracted from {computeNav} to keep that function
    ///         inside the `via_ir` stack limit — see the stack-budget note on {computeNav}. The loop's four
    ///         per-iteration locals (`pos`, `asset`, `feed`, `canonicalDecimals`) plus the accumulator and the
    ///         counter live in THIS frame instead of being live across `computeNav`'s deepest point, where five
    ///         storage pointers and the inlined position-gathering counters are already resident.
    /// @dev Keep this a separate function. Folding the loop back into {computeNav} reintroduces the overflow, and it
    ///      surfaces only as a `via_ir` "Variable is 1 too deep in the stack" error at compile time.
    function _sumPositionValues(
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        INAVCalculator.PositionBalance[] memory allPositions,
        PriceFeedCache[] memory priceFeeds,
        QuoteAssetInfo memory quoteInfo
    ) private view returns (int256 totalValue) {
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
            nav.monitorsUnhealthyPriceAssets = new INAVCalculator.Asset[](0);
            positions = new INAVCalculator.Position[](0);
            return (nav, positions); // value 0, sequencerDown false (no assets registered)
        }

        INAVCalculator.PositionBalance[] memory allPositions =
            _getPositionBalances(allAdapters, assetIndex, account, address(0));

        nav.sequencerDown = sequencerDown;
        if (allPositions.length == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            nav.irregularPriceAssets = new INAVCalculator.Asset[](0);
            nav.monitorsUnhealthyPriceAssets = new INAVCalculator.Asset[](0);
            positions = new INAVCalculator.Position[](0);
            return (nav, positions); // value 0
        }

        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);
        PriceFeedCache[] memory priceFeeds =
            _buildPriceFeedCache(priceOracles, monitorFeeds, assetPricing, assetsWithPositions, sequencerDown);
        _assignHealthArrays(nav, assetIndex, registeredAssets, priceFeeds);

        (positions, nav.value) =
            _enrichAll(allPositions, priceFeeds, quoteInfo, quoteAssetIrregular, assetIndex, registeredAssets);
    }

    /// @dev Enrichment loop for `computeNavAndPositions`, extracted purely to stay under the `via_ir` stack limit.
    ///      That function keeps five storage pointers plus the quote-asset info live across its whole body; folding
    ///      this loop's locals (`i`, `balance`, `registered`, `feed`, `length`, `totalValue`) in on top put it one
    ///      slot over ("Variable _mpos_1 is 1 too deep in the stack"). Behaviour is byte-for-byte the same as the
    ///      inline loop — do not re-inline it. Note the limit is reached only in a WHOLE-PROJECT compile, so an
    ///      incremental `forge build` will not reproduce a regression here; use `forge clean && forge build`.
    ///
    ///      **Historical note, so the reason is not mistaken for the current shape.** This note used to cite the
    ///      "inlined `_buildStaleAssets` / `_buildIrregularAssets` loops" as part of the load. They are no longer
    ///      invoked from this caller's frame — {_assignHealthArrays} now holds all three health-array calls in its own
    ///      frame. That is the second extraction made for this limit; `_enrichAll` — called only from
    ///      `computeNavAndPositions` — was the first. Both are extracted OUT of their callers, not out of each other.
    ///      The stack pressure that
    ///      justifies keeping `_enrichAll` separate is therefore the five storage pointers plus this loop's own
    ///      locals, NOT the health-array builders. Do not read the removal of that clause as headroom.
    function _enrichAll(
        INAVCalculator.PositionBalance[] memory allPositions,
        PriceFeedCache[] memory priceFeeds,
        QuoteAssetInfo memory quoteInfo,
        bool quoteAssetIrregular,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets
    ) private view returns (INAVCalculator.Position[] memory positions, int256 totalValue) {
        uint256 length = allPositions.length;
        positions = new INAVCalculator.Position[](length);
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
    }

    /// @notice True if the account holds any non-zero position. Mirrors NAVCalculator.hasPositions, and inherits
    ///         `_getAdapterPositions`'s policy: a reverting adapter is skipped, one that exhausts its gas
    ///         stipend reverts the scan rather than being read as "no positions".
    function hasPositions(
        address[] memory allAdapters,
        uint256 metaInstanceTotal,
        mapping(address => uint256) storage assetIndex,
        uint256 assetCount,
        address account
    ) external view returns (bool) {
        // Nothing can be counted with an empty registry — `_isCounted` discards every row — so skip the fan-out
        // entirely, as the NAV entrypoints already do. Without this the scan still runs, and a starved adapter
        // makes this revert where `computeNav` answers 0 on the same state.
        if (assetCount == 0) return false;
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
        // See `hasPositions`: an empty registry cannot yield a counted row, so do not fan out for one.
        if (assetCount == 0) return new address[](0);
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
    ///         by `assetFilter` (address(0) = all). A reverting adapter is skipped; one that exhausts its gas
    ///         stipend reverts the whole read (see {_getAdapterPositions}). Mirrors the former
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

    /// @notice Bytes of revert data copied when an adapter's call fails: the exact ABI size of
    ///         {InstanceGasExhausted} (selector + four words).
    /// @dev A bound, not a size hint. The parameterless `catch` below copies nothing on its own, and switching to
    ///      `catch (bytes memory)` to read the selector would `returndatacopy` the WHOLE revert payload — which a
    ///      hostile adapter sizes, and which has been measured on this repo in the hundreds of millions of gas.
    ///      Reading the selector straight out of the returndata buffer and copying only this many bytes keeps the
    ///      cost flat. A forged payload is therefore truncated to a well-formed error, never propagated whole.
    uint256 private constant INSTANCE_EXHAUSTED_BYTES = 4 + 32 * 4;

    /// @notice Calls an adapter's `getAdapterPositions`, failing open on a revert but NOT on gas exhaustion.
    /// @dev The two failure modes look identical to `catch` and must not be treated identically:
    ///
    ///      - **A revert** means the adapter answered: it has nothing to report. Returning an empty list is the
    ///        long-standing fail-open behaviour, so one misconfigured adapter cannot take down the whole read.
    ///      - **Running out of gas** means the adapter did NOT answer. Reporting that as an empty list drops its
    ///        legs, and a dropped *debt* leg RAISES the reported NAV — a silent over-report, produced by the read
    ///        itself rather than by any adapter. It is also self-propagating: whatever an adapter burns is gone
    ///        from the budget the adapters after it need, so one runaway adapter starves the rest and each of
    ///        them disappears the same silent way.
    ///
    ///      So exhaustion reverts with {AdapterGasExhausted}. The stipend is exactly what the EVM would forward
    ///      anyway (63/64 of what this frame holds) — deliberately NOT a smaller fixed ceiling. A fixed ceiling
    ///      would make exhaustion unrecoverable: `ERC20DefaultBalanceAdapter`'s cost grows with the asset
    ///      registry, and per-account adapters can be inflated by anyone who can add entries to the account's
    ///      list at a protocol (a withdrawal-queue request names its own owner), so a ceiling turns ordinary
    ///      registry growth and cheap third-party griefing alike into a permanent outage that no caller can
    ///      escape and only a redeploy can lift. Keyed to the caller's own budget instead, the same situations
    ///      surface as "this read needs more gas", which the caller can act on.
    ///
    ///      A meta-adapter raises {InstanceGasExhausted} when one of its governed instances runs out of gas, and
    ///      that selector is honoured HERE regardless of what the gas figures say. It has to be: the meta-adapter
    ///      may raise it having spent very little — an early instance starves, the fan-out stops — and the gas
    ///      test would then read a deliberate exhaustion signal as a benign revert and fail open, dropping the
    ///      WHOLE meta-adapter rather than the one instance. An explicit signal beats a heuristic wherever one
    ///      exists, and the specific error is re-raised rather than replaced with {AdapterGasExhausted}, so the
    ///      failing instance stays named. See {_reraiseIfInstanceExhausted} for what that signal must satisfy.
    ///
    ///      **Scope, stated plainly. Apart from that signal this guard only ever sees a FAILED call, so anything
    ///      an adapter absorbs internally is invisible to it. Two things sit outside:**
    ///      - An adapter that fails open in its own frame and returns SUCCESSFULLY. The most common shape, and
    ///        the one present on every chain: `ERC20DefaultBalanceAdapter` reads each asset with an unstipended
    ///        `staticcall` and records 0 on failure, so a single token whose `balanceOf` loops takes 63/64 of
    ///        that adapter's budget, drops its own wallet balance from the NAV, and still returns normally. No
    ///        classifier upstream is reached, because nothing failed from where this function is standing. The
    ///        meta-adapter position fan-out used to behave this way too and now raises instead — but its
    ///        `positionIds` and `_assetsForInstances` siblings still absorb a starved instance silently.
    ///      - The `returndatacopy` and ABI decode of the adapter's reply are charged to THIS frame, outside the
    ///        stipend, because a typed `try … returns (…[] memory)` copies whatever arrives. The stipend bounds
    ///        it only indirectly, through what the callee could afford to build. The outcome is a loud
    ///        out-of-gas rather than a wrong number, so this is availability, not correctness.
    ///
    ///      Nor is any fixed fraction exact: deep enough nesting always leaves enough unspent to slip under the
    ///      threshold. This narrows the silent window; it does not close it.
    function _getAdapterPositions(address adapter, address account, address assetFilter)
        private
        view
        returns (INAVCalculator.PositionBalance[] memory)
    {
        // One sample, used both to derive the stipend and to measure against it — see GasStipendLib.exhausted.
        uint256 available = gasleft();
        uint256 stipend = GasStipendLib.stipendFrom(available);

        try IBalanceAdapter(adapter).getAdapterPositions{gas: stipend}(account, assetFilter) returns (
            INAVCalculator.PositionBalance[] memory pos
        ) {
            return pos;
        } catch {
            // FIRST, before any bookkeeping of our own: `consumed` must measure what the CALL cost, which is what
            // {GasStipendLib.exhausted} is defined against and what the error reports. Reading it after the
            // selector work below would fold this frame's own gas into the figure.
            uint256 consumed = available - gasleft();

            _reraiseIfInstanceExhausted(adapter);

            if (GasStipendLib.exhausted(stipend, consumed)) {
                revert INAVCalculator.AdapterGasExhausted(adapter, stipend, consumed);
            }
            return new INAVCalculator.PositionBalance[](0);
        }
    }

    /// @notice Re-raises a meta-adapter's {InstanceGasExhausted}, still resident in the returndata buffer, so a
    ///         starved INSTANCE is not re-scored by the gas heuristic and failed open.
    /// @dev Needed because the heuristic cannot see this case: a meta-adapter that stops on its FIRST starved
    ///      instance has spent almost nothing, so `consumed` is small and the failure would be read as a benign
    ///      revert — dropping the whole adapter rather than surfacing the one instance.
    ///
    ///      Honouring a callee-chosen selector is a decision to let a callee force a revert, so it is gated
    ///      hard, cheapest check first, and every gate must pass:
    ///      1. **Exactly** {INSTANCE_EXHAUSTED_BYTES} of revert data. A shorter payload carrying the selector
    ///         would otherwise be re-raised as-is and could not be decoded against the error's signature; a
    ///         longer one is not something the error can produce.
    ///      2. The selector matches.
    ///      3. The adapter answers ERC165 for {IMetaBalanceAdapter}. Only a meta-adapter has instances, so only
    ///         a meta-adapter can mean anything by this signal. This runs last because it is the only gate that
    ///         costs a call, and by then the two cheap gates have already excluded ordinary reverts — so the
    ///         normal fail-open path never pays for it.
    ///
    ///      The `adapter` word is then OVERWRITTEN with the address actually called, rather than trusted from
    ///      the payload. The callee wrote those bytes; left alone, a misbehaving adapter could name an innocent
    ///      one and send an operator to remove the wrong thing. `instance`, `stipend` and `consumed` are still
    ///      the callee's own account of itself and can only be read as such.
    ///
    ///      What this does NOT bound is a registered adapter deliberately forging the selector to turn its own
    ///      failure into a whole-read revert. That is adapter-controlled, not account-controlled — a registered
    ///      adapter can already stop a read by burning gas — and no third-party path reaches this buffer: a
    ///      meta-adapter's per-instance `catch` swallows an inner protocol's revert before it can surface here,
    ///      and the plain adapters read constructor-pinned addresses.
    /// @param adapter The adapter whose call just failed, used to overwrite the payload's first word.
    function _reraiseIfInstanceExhausted(address adapter) private view {
        uint256 size = INSTANCE_EXHAUSTED_BYTES;
        if (_returndatasize() != size) return;

        // Save the payload BEFORE anything else can touch the returndata buffer. The ERC165 probe below is an
        // external call, and a call REPLACES this frame's returndata — read it after and you get the probe's
        // answer, not the adapter's error. Allocated properly rather than scribbled above the free pointer,
        // because the probe's own calldata is allocated there.
        bytes memory payload = new bytes(size);
        bytes4 want = INAVCalculator.InstanceGasExhausted.selector;
        bool matches;
        assembly ("memory-safe") {
            returndatacopy(add(payload, 0x20), 0x00, size)
            matches := eq(shr(224, mload(add(payload, 0x20))), shr(224, want))
        }
        if (!matches) return;
        if (!adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId)) return;

        assembly ("memory-safe") {
            // Word 0 is the callee's claim about which adapter failed; replace it with the one actually called.
            mstore(add(payload, 0x24), adapter)
            revert(add(payload, 0x20), size)
        }
    }

    /// @notice `returndatasize()` as a Solidity value, so the gates above read as plain control flow.
    function _returndatasize() private pure returns (uint256 size) {
        assembly ("memory-safe") {
            size := returndatasize()
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

    /// @notice Builds the selected-feed price cache for a list of assets — the per-asset `irregular` divergence flag
    ///         AND the `monitorsUnhealthy` flag (monitors configured, none readable, primary usable).
    /// @dev Divergence folds the NAV-level `sequencerDown` into the primary's staleness (see {_divergenceFor}), so
    ///      both flags are suppressed while the sequencer is down; `sequencerDown` itself is surfaced separately on
    ///      the NAV struct. (An earlier version of this note claimed the primary is treated as stale "exactly when
    ///      its feed is stale", which understated the fold.)
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
                // monitorsUnhealthy stays false: a feedless asset is reported via `stalePriceAssets`, and its monitor
                // health is not the reason its price is unusable.
                priceFeeds[i] = PriceFeedCache({
                    asset: asset,
                    price: 0,
                    decimals: NAV_DECIMALS,
                    stale: true,
                    irregular: false,
                    monitorsUnhealthy: false
                });
                continue;
            }
            (int256 price, uint8 decimals, bool stale,,) = _selectFeedCore(priceOracles, asset);
            // Only run the divergence check (and the price normalization it needs) when the asset actually has
            // monitors or a peg tolerance — otherwise `irregular` is definitionally false, and skipping avoids
            // `_scaleTo8` overflowing on a pathological high-decimals feed before the value path's own guard fires.
            // Fold the NAV-level `sequencerDown` into staleness so `NAV.irregularPriceAssets` / `Position.irregular`
            // stay consistent with getPriceData / healthCheck on L2 during sequencer downtime.
            bool irregular = false;
            bool monitorsUnhealthy = false;
            if (_hasDivergenceChecks(monitorFeeds, assetPricing, asset)) {
                // `healthyMonitors` is the count {_monitorDivergence} already computed for its own guard — taken from
                // the return rather than re-derived, so this costs no extra feed reads on the hot path.
                uint256 healthyMonitors;
                int256 primaryPrice8;
                (primaryPrice8,,,, irregular, healthyMonitors,) =
                    _divergenceFor(monitorFeeds, assetPricing, asset, price, decimals, stale, sequencerDown);
                // Monitors exist, none answered, and the primary was usable — so the divergence check was skipped for
                // want of MONITOR data, which is the only thing this flag is entitled to claim.
                //
                // `primaryPrice8 > 0` is the exact negation of the other half of {_monitorDivergence}'s own guard
                // (`n > 0 && !primaryStale && primaryPrice8 > 0`), and it is deliberately used INSTEAD of
                // `!stale && !sequencerDown`: it subsumes both (`primaryPrice8` is forced to 0 whenever
                // `primaryStale`, i.e. whenever the feed is stale OR the sequencer is down) AND it additionally
                // covers the case those two miss — {_scaleTo8} returning 0 for a NON-stale primary, which it does
                // for a primary whose `decimals != 8` when the exponent is unusable, when `price` truncates to 0
                // scaling down, or when scaling up would overflow. In that state `healthyMonitors` is 0 for a reason
                // that has nothing to do with the monitors, and blaming them would send an operator to the wrong
                // contract. Not reachable with today's uniformly-8-decimal primaries, but `addFeed` permits others.
                monitorsUnhealthy = healthyMonitors == 0 && primaryPrice8 > 0 && monitorFeeds[asset].length > 0;
            }
            priceFeeds[i] = PriceFeedCache({
                asset: asset,
                price: price,
                decimals: decimals,
                stale: stale,
                irregular: irregular,
                monitorsUnhealthy: monitorsUnhealthy
            });
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

    /// @notice Builds all THREE per-asset health arrays and assigns them onto `nav`.
    /// @dev Exists to relieve `via_ir` stack pressure in {computeNav} / {computeNavAndPositions} — the same reason
    ///      {_enrichAll} exists, and load-bearing for the same reason. Those callers keep five storage pointers plus
    ///      `nav` (and, in the positions variant, `positions`) live across their whole body, and THREE sequential
    ///      builder calls each re-established `assetIndex` / `registeredAssets` / `priceFeeds` as live in the CALLER's
    ///      frame. Collapsing them into one call is what resolved the overflow AT THAT TREE — stated in the past tense
    ///      deliberately, because the paragraph below records that the present-tense version was measured and found
    ///      false.
    ///
    ///      **Prefer not to re-inline these three assignments — but be precise about why, because the stronger version
    ///      of this warning was MEASURED AND FOUND FALSE.** This note used to say re-inlining "reproduces
    ///      `Variable _mpos_1 is 1 too deep in the stack`". A cold `forge clean && forge build --force` with both call
    ///      sites re-inlined **compiled successfully** (exit 0), so re-inlining is NOT currently rejected by the
    ///      compiler and that claim was unsupported. What can be shown:
    ///
    ///      - the extraction was made when the margin WAS tight, and it is what resolved the overflow at that tree;
    ///      - the margin is whole-program: Foundry hands all of `src` + `test` + `script` to a single solc invocation,
    ///        so `via_ir` allocates stack across the entire program and the headroom here depends on code with nothing
    ///        to do with this file — adding an unrelated contract under `src/` has been enough to tip it before;
    ///      - so today's success is a property of today's tree, not a licence. It can regress without any change to
    ///        this file, and an incremental `forge build` will not show it — nor will CI's Build job off a warm cache.
    ///        Only `forge clean && forge build --force` will.
    ///
    ///      The extraction also stands on its own merits independently of the stack: it shrank `PriceFeedLib` by 69
    ///      bytes. Keep it. Just do not cite a compile error that does not currently occur as the reason.
    function _assignHealthArrays(
        INAVCalculator.NAV memory nav,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        PriceFeedCache[] memory priceFeeds
    ) private view {
        nav.stalePriceAssets = _buildStaleAssets(assetIndex, registeredAssets, priceFeeds);
        nav.irregularPriceAssets = _buildIrregularAssets(assetIndex, registeredAssets, priceFeeds);
        nav.monitorsUnhealthyPriceAssets = _buildMonitorsUnhealthyAssets(assetIndex, registeredAssets, priceFeeds);
    }

    /// @notice Collects the assets whose monitors are all unreadable — configured, but none of them answered — from
    ///         the per-asset flag computed once in {_buildPriceFeedCache}.
    /// @dev Sibling of {_buildIrregularAssets}, deliberately kept separate rather than folded into it behind a
    ///      selector flag: the two lists mean different things (one says a check FIRED, the other says the
    ///      monitor-divergence check did NOT RUN) and a caller that confuses them draws the wrong conclusion. They
    ///      are NOT mutually exclusive — an asset can appear in both, because the peg guard is monitor-independent:
    ///      a stablecoin off $1 whose monitors are all unreadable is `irregular` (peg) AND monitors-unhealthy
    ///      (divergence unchecked). Lives here in the library, so its bytes do not count against
    ///      {NAVCalculator}'s EIP-170 ceiling.
    function _buildMonitorsUnhealthyAssets(
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        PriceFeedCache[] memory priceFeeds
    ) private view returns (INAVCalculator.Asset[] memory unhealthyAssets) {
        uint256 feedsLength = priceFeeds.length;
        address[] memory temp = new address[](feedsLength);
        uint256 count = 0;
        for (uint256 i = 0; i < feedsLength; i++) {
            if (priceFeeds[i].monitorsUnhealthy) temp[count++] = priceFeeds[i].asset;
        }
        address[] memory addrs = ArrayLib.copySliceAddress(temp, count);

        uint256 length = addrs.length;
        unhealthyAssets = new INAVCalculator.Asset[](length);
        for (uint256 i = 0; i < length; i++) {
            unhealthyAssets[i] = _getRegisteredAsset(assetIndex, registeredAssets, addrs[i]);
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
        if (heartbeat == 0) revert IPrices.InvalidPriceOracle();

        // IDENTITY checks stay above the loop; only the LIVE HEALTH check moves below it. A code-less feed
        // must fail by name here — `_resolveFeedDecimals` would otherwise reach it first and revert with
        // EMPTY returndata, which is how moving the whole validator broke
        // test_RevertWhen_{addFeeds,registerAsset}_codelessPriceFeed.
        if (priceFeed == address(0) || asset == address(0)) revert IPrices.InvalidPriceOracle();
        AddressCheckLib.requireContract(priceFeed, "priceFeed");

        IPrices.PriceFeedConfig[] storage configs = priceOracles[asset];
        uint256 len = configs.length;

        // Resolved BEFORE the dedup loop so the UPSERT path revalidates too, matching `addMonitorFeed`.
        //
        // The read path scales with the STORED value — `_scaleTo8(rawPrice, cfg.decimals)` — and never
        // re-reads `decimals()`. So if a feed's decimals drift away from what was stored, every price for
        // that asset is wrong by 10**delta, and a POSITIVE delta OVER-reports: the one direction this repo
        // never licenses. Chainlink's `AggregatorProxy.decimals()` forwards to the swappable current
        // aggregator rather than being immutable, so the drift is not structurally impossible.
        //
        // This was previously resolved only on the append path, below the loop. The 4-transaction mirror
        // dance the upsert replaced ended in an `addPriceFeed` that ran this check, so the upsert quietly
        // removed the one thing that would have caught the drift. Reverting is the safe direction: it
        // surfaces the drift instead of preserving a stale scale.
        uint8 dec = _resolveFeedDecimals(priceFeed, priceType);
        if (len > 0 && configs[0].decimals != dec) {
            revert IPrices.PriceFeedDecimalsMismatch(asset, configs[0].decimals, dec);
        }

        for (uint256 i; i < len; ++i) {
            if (configs[i].priceFeed != priceFeed) continue;
            // ALREADY REGISTERED -> UPDATE THE HEARTBEAT IN PLACE, do not revert.
            //
            // The heartbeat is registration CONFIGURATION and has to be changeable. Until now it was
            // effectively immutable: `removeFeed` refuses an asset's LAST feed and this function refused a
            // feed address the asset already carried, and every registered asset holds exactly one feed — so
            // both orderings were closed. Changing one number meant registering a MIRROR of the incumbent
            // feed to escape the last-feed guard, swapping through it, then removing it: four transactions
            // per asset, with an unaudited pass-through contract transiently in the pricing path.
            //
            // Only the heartbeat moves. The feed address, priceType, decimals and array position are all
            // untouched, so this cannot change WHICH oracle prices the asset — only when its answer is
            // considered stale. `priceType`/decimals are deliberately NOT re-applied: a caller trying to
            // change those is changing the feed's identity and must remove and re-add it explicitly.
            // Reject a changed `priceType` rather than ignoring it. The comment above says a caller changing the
            // feed's identity "must remove and re-add it explicitly" — but nothing enforced that, and the
            // validator cannot: it groups Chainlink, Redstone and API3 into one branch, so submitting a
            // Chainlink feed as Redstone passes validation, moves the heartbeat, and leaves the type untouched.
            // The caller reads that as success for a change that never happened.
            if (configs[i].priceType != priceType) revert IPrices.PriceFeedTypeImmutable(asset, priceFeed);

            uint256 oldHeartbeat = configs[i].chainlinkHeartbeat;
            if (oldHeartbeat == heartbeat) revert IPrices.PriceFeedAlreadyRegistered(asset, priceFeed);
            configs[i].chainlinkHeartbeat = heartbeat;
            // MONITORING NOTE: this is now the ONLY event a heartbeat change emits. The mirror-swap dance it
            // replaced surfaced as a `PriceFeedAdded`/`PriceFeedRemoved` pair, so any alerting subscribed to
            // that pair will no longer see staleness-window changes. Subscribe to this event instead.
            emit IPrices.PriceFeedHeartbeatUpdated(asset, priceFeed, oldHeartbeat, heartbeat);
            return;
        }

        // ADMISSION validation, deliberately BELOW the upsert loop. It calls latestRoundData() and reverts
        // InvalidPriceOracle on answer <= 0 — which, run above the loop, made a heartbeat-only change
        // impossible for exactly the feed needing one: TIGHTENING a window is the standard response to a feed
        // reporting a non-positive answer, and that feed could not be touched. Blast radius was a whole chain,
        // since RealignHeartbeats calls this inside its broadcast loop and forge script simulates end to end.
        // It also froze any feed registered before the Custom guards (#199, #268) existed.
        //
        // The upsert path needs none of it: the feed is already admitted, its identity is pinned by the
        // priceType equality check, and its SCALE is revalidated by _resolveFeedDecimals, which reads
        // decimals() only and is unaffected by a bad answer.
        _validateFeedSupportInternal(asset, priceFeed, priceType);

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

    /// @notice Adds a monitor (divergence-only) feed, or UPDATES the heartbeat of one already registered.
    /// @dev A new monitor requires the divergence tolerance to be set first (>0); an in-place heartbeat update
    ///      does not, since that check admits a monitor rather than validating an existing one. Both paths
    ///      require the feed to report NAV_DECIMALS decimals — the read path scales by the stored value.
    function addMonitorFeed(
        mapping(address => IPrices.PriceFeedConfig[]) storage monitorFeeds,
        mapping(address => IPrices.AssetPricing) storage assetPricing,
        address asset,
        address priceFeed,
        uint256 heartbeat,
        IPrices.PriceType priceType
    ) external {
        // IDENTITY checks stay above the loop; the LIVE HEALTH check moves below it, for the same reason
        // `addFeed` does it. `_validateFeedSupportInternal` calls `latestRoundData()` and reverts
        // `InvalidPriceOracle` on a non-positive answer, so running it here made a heartbeat-only change
        // impossible for exactly the monitor that needs one — and `RealignHeartbeats` batches every drifted
        // monitor into one simulated broadcast, so that single monitor aborted the whole chain's realignment.
        // The primary axis was fixed for this; leaving the monitor axis unfixed kept the same total blockage
        // one axis over.
        if (priceFeed == address(0) || asset == address(0)) revert IPrices.InvalidPriceOracle();
        AddressCheckLib.requireContract(priceFeed, "priceFeed");

        if (heartbeat == 0) revert IPrices.InvalidPriceOracle();

        uint8 dec = _resolveFeedDecimals(priceFeed, priceType);
        // Monitors must be USD-comparable to the primary (always NAV_DECIMALS).
        if (dec != NAV_DECIMALS) revert IPrices.MonitorFeedDecimalsMismatch(asset, NAV_DECIMALS, dec);

        IPrices.PriceFeedConfig[] storage monitors = monitorFeeds[asset];
        uint256 len = monitors.length;
        for (uint256 i; i < len; ++i) {
            if (monitors[i].priceFeed != priceFeed) continue;
            // ALREADY REGISTERED -> UPSERT THE HEARTBEAT, mirroring `addFeed`.
            //
            // Without this a monitor's heartbeat could only be changed by remove-then-add, which is TWO
            // transactions with no atomicity: an interrupted run leaves the monitor removed and divergence
            // detection silently degraded until someone notices. There is no last-monitor guard to work
            // around, so unlike the primary-feed case this was never impossible — just unsafe.
            //
            // Same two guards as the primary path: an identical re-register still reverts, and the feed's
            // type is identity rather than configuration, so a changed `priceType` is rejected.
            if (monitors[i].priceType != priceType) revert IPrices.PriceFeedTypeImmutable(asset, priceFeed);
            uint256 oldHeartbeat = monitors[i].chainlinkHeartbeat;
            if (oldHeartbeat == heartbeat) revert IPrices.MonitorFeedAlreadyRegistered(asset, priceFeed);
            monitors[i].chainlinkHeartbeat = heartbeat;
            emit IPrices.MonitorFeedHeartbeatUpdated(asset, priceFeed, oldHeartbeat, heartbeat);
            return;
        }

        // ADMISSION check, deliberately below the upsert loop: a zero tolerance means a NEW monitor would have
        // nothing to compare against, which says nothing about one already admitted.
        //
        // This is ordering hygiene, NOT a bug fix, and the distinction is worth recording. A review argued the
        // check above the loop would lock out a heartbeat update on an asset whose tolerance had been zeroed
        // "operationally". It would — but that state is unreachable: `setDivergenceTolerance` rejects zero with
        // `InvalidTolerance` (pinned by `test_divergenceToleranceCannotBeZeroed`), and admitting a monitor at
        // all requires a non-zero tolerance, so every monitored asset has one. Keeping the check here because
        // an admission check belongs on the admission path, not because it was reachable from below.
        //
        // The decimals guard above the loop is a different matter and stays there: it protects the read path,
        // which scales by the STORED value and never re-reads.
        if (assetPricing[asset].divergenceToleranceBps == 0) revert IPrices.DivergenceToleranceRequired(asset);

        // LIVE HEALTH check, below the loop for the same reason the admission check is: a monitor that is
        // currently reporting a non-positive answer must still be able to have its window changed, and only a
        // NEW monitor needs to prove it answers at all.
        _validateFeedSupportInternal(asset, priceFeed, priceType);

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
        // A code-less `priceFeed` must fail by name, here, for the same reason the asset is checked at the
        // NAVCalculator call site: the AggregatorV3 branch below ends in a HIGH-LEVEL `latestRoundData()`, whose
        // `extcodesize` precheck fires in this frame before the call and reverts with empty returndata — no
        // selector for the MANAGER to read. The zero-address check above does not cover it; an EOA or a mistyped
        // address is non-zero and code-less. Placed in the shared validator rather than at each entry point so
        // `registerAsset`, `addPriceFeed` and `addMonitorFeed` all answer the same way.
        AddressCheckLib.requireContract(priceFeed, "priceFeed");
        if (priceType == IPrices.PriceType.Custom) {
            if (!priceFeed.supportsInterface(type(ICustomPriceFeed).interfaceId)) revert IPrices.InvalidPriceOracle();
            // A custom feed prices exactly ONE asset (1:1 contract-to-asset, see PRICE_ADAPTERS.md) and reports which
            // one via `underlyingAssetSupported()`. Nothing else in the system reads that value, so without this check
            // registering feed A for asset B succeeds silently and every B position is then priced at A's price
            // forever — a plausible-looking number, `stale = false`, `irregular = false`, no on-chain trace. Feeds are
            // resolved by STRING KEY from config (`nav-config[asset].priceFeeds[].feed` →
            // `deployments.customPriceFeeds[<name>]`) across near-identical names (`ezETH`/`ezETHCrossRate`,
            // `NXM`/`wNXM`, `weETH_L2`/`weETHCrossRate`), which is exactly where the two get crossed. The feed already
            // knows the answer; ask it.
            //
            // Deliberately a direct high-level call, not `try`/`catch`: a feed that claims `ICustomPriceFeed` via
            // `supportsInterface` (checked above) but cannot answer `underlyingAssetSupported()` is broken, and
            // failing the registration is the safe direction. Matches the AggregatorV3 branch below, which likewise
            // lets a malformed feed revert rather than swallowing it.
            address feedAsset = ICustomPriceFeed(priceFeed).underlyingAssetSupported();
            if (feedAsset != token) revert IPrices.CustomFeedAssetMismatch(token, priceFeed, feedAsset);
            _validateFeedNotCircular(token, priceFeed);
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

    /// @notice Rejects a `Custom` feed whose NAV-sourced base asset is the very asset it is being registered for.
    /// @dev **The failure.** A NAV-sourced custom feed prices its asset as `rate × base/USD` and reads the `base/USD`
    ///      term back out of THIS NAV — `NavBaseUsdLib.baseUsd(NAV, BASE_ASSET)` → `getPriceData(BASE_ASSET)`
    ///      (ADR 0019). The circularity invariant that makes this safe (`BASE_ASSET` must be priced by DIRECT feeds,
    ///      never by a feed that calls back into the NAV) is stated in {NavBaseUsdLib} and held by CONVENTION only:
    ///      `BASE_ASSET` is a constructor argument checked for nothing but ERC20-ness, and until this gate nothing
    ///      on the registration path could even see it. Register such a feed for its own base and
    ///      `getPriceData(token)` → feed → `getPriceData(token)` recurses until the ~1024 call-depth limit. The read
    ///      still SUCCEEDS — `_selectFeedCore`'s per-feed `try`/`catch` swallows the depth failure and continues to
    ///      the healthy feed — so there is no revert, no event and no wrong number to notice; the only symptom is
    ///      that every read of that asset, and of every position priced from it, burns gas proportional to ~1024
    ///      nested `STATICCALL` frames, forever.
    /// @dev **Why here.** Registration is the chokepoint the NAV actually controls. A constructor assertion in the
    ///      feed bases would bind only feeds deployed from this repo after that change — not an already-deployed
    ///      feed, not a third-party one, and not anything a MANAGER registers later. Those are precisely the cases
    ///      the invariant has to survive.
    /// @dev **Why unreadable is a rejection.** `BASE_ASSET()` is probed with a raw `staticcall` because a feed that
    ///      does not implement it must be distinguishable from one that does — but "we could not read it" is then
    ///      deliberately NOT allowed to collapse into "it is fine", because the failure being closed is unbounded
    ///      recursion. A feed with no NAV dependency at all declares that by answering `address(0)`, which passes
    ///      (`address(0)` is never a registrable asset, so it can never equal `token`). Every in-repo custom feed
    ///      answers: the three NAV-sourced bases and `ankrETH_CustomPriceFeed` expose `BASE_ASSET` as an immutable,
    ///      and `ETHPlus_CustomPriceFeed` — which prices from the Reserve Protocol basket and never calls back into
    ///      the NAV — declares it `address(0)`. A third-party feed must do likewise to be registrable; that
    ///      requirement is the price of the guard being able to answer NO.
    /// @dev **Scope — an admission check, not a runtime invariant**, exactly like the `underlyingAssetSupported()`
    ///      binding above. It is read once, at registration, never on a read path. A feed with a MUTABLE base can
    ///      pass here and recurse afterwards, and a hostile feed can re-enter the NAV without exposing a base at
    ///      all — neither is what this closes. What it closes is the MISCONFIGURATION: a legitimate, honest feed
    ///      pointed at its own base by a config typo, on a registration path driven from an EOA.
    /// @dev **A MULTI-HOP CYCLE IS NOT CAUGHT, AND THAT IS DELIBERATE.** Feed for A based on B, feed for B based on
    ///      A: each passes every check here — `underlyingAssetSupported()` matches its own asset, and neither base
    ///      equals the asset it is registered for. Both legs register cleanly through the normal MANAGER path, **in
    ///      either order**, because this function receives only `(token, priceFeed)` and never reads the registry;
    ///      there is no "second leg trips it" ordering to rely on.
    ///
    ///      **CYCLE LENGTH DOES NOT MATTER, AND NEITHER DOES DEPTH.** Swept on a real proxy at a fixed 8,000,000-gas
    ///      budget, ring sizes 2/3/4/5/6 all cost an IDENTICAL 7,732,849 gas. What the cost actually tracks is the
    ///      CALLER'S BUDGET: sweeping the budget at a fixed ring size gives 0.49M/0.92M/1.94M/3.87M/7.73M/15.45M
    ///      for 0.5M/1M/2M/4M/8M/16M supplied — a flat ~96.6% of whatever is offered, against a no-cycle control
    ///      that stays at ~14k regardless. That is the 63/64 call-gas forwarding rule: every level forwards all but
    ///      1/64 of what it holds and the recursion runs until the gas is gone, so the loop body and the number of
    ///      distinct assets in the ring are both irrelevant. "How deep can it go" is therefore the wrong question —
    ///      the answer is "as deep as the gas you supplied allows", and the bill is a fraction of the budget rather
    ///      than any fixed figure.
    ///
    ///      Below roughly 1M gas the read does not merely get expensive, it FAILS (`ok == false` at a 0.5M budget):
    ///      the 1/64 the outermost frame retains is no longer enough to finish the healthy feed after the `catch`.
    ///      So "returns the correct price while burning the gas" is itself budget-dependent — it holds for a
    ///      generous `eth_call`, not for a gas-constrained on-chain caller, which simply reverts.
    ///
    ///      Not enforced on chain because the only on-chain fix is an ordering-dependent scan of the registry, and
    ///      that scan cannot answer NO reliably: a base with no custom feed today can acquire one tomorrow, so it
    ///      would have to run on every registration in both directions and would STILL miss a cycle completed by a
    ///      later registration. A check that cannot answer NO is the failure mode this whole guard exists to avoid.
    ///
    ///      It is instead unconstructible in configuration, and that is where it is enforced: a cycle of any length
    ///      needs at least one base asset to itself be priced by a Custom primary, and **0 of the 41** configured
    ///      Custom (asset, feed) pairs across all 7 chains have one — every base resolves to a Chainlink-only asset
    ///      (WETH, USDC, GHO, USDS, USDe, GNO, WXDAI). `script/deploy/preflight/preflight_config.py` now makes that
    ///      an ERROR rather than a property, so the config cannot drift into a cycle unnoticed. Re-derive both
    ///      numbers with `python3 script/deploy/preflight/preflight_config.py --base-report` (see that file's
    ///      `base_allowlist_findings` docstring). The related and STRICTLY WORSE gap is a base that is merely the
    ///      WRONG asset rather than a cyclic one: it has no gas signature, no `stale` and no `irregular` — only a
    ///      wrong number, at an ordinary 43,738-gas read. **35 of the 41** pairs rely on config correctness for it;
    ///      the other 6 are the ERC-4626 family (`sUSDe`, `sUSDS`, `syrupUSDC`, `RWIV`, `sGHO`, `sXDAI`), whose
    ///      constructor pins the base to `IERC4626(vault).asset()` and reverts `BaseAssetMismatch` otherwise. The
    ///      preflight narrows the remaining 35 from "any of the 93 registered assets" to "a direct-priced base",
    ///      but cannot tell WETH from USDC for an LST — there is no on-chain ground truth for what an LST's base
    ///      ought to be, which is exactly why the ERC-4626 family can be pinned and the rest cannot.
    /// @dev No gas cap on the probe: this runs only on a MANAGER-authorized registration transaction, so a feed that
    ///      burns the caller's gas here grieves only the caller, and it fails closed (the registration reverts).
    function _validateFeedNotCircular(address token, address priceFeed) private view {
        (bool ok, bytes memory ret) =
            priceFeed.staticcall(abi.encodeWithSelector(INavSourcedPriceFeed.BASE_ASSET.selector));
        // A missing function, a revert, or anything that is not a single ABI word is unreadable. Note a code-less
        // target would return `ok == true` with empty returndata, which this also catches — though
        // `AddressCheckLib.requireContract` above has already excluded that case.
        if (!ok || ret.length != 32) revert IPrices.CustomFeedBaseUnreadable(token, priceFeed);
        // Decode as uint256 and range-check by hand rather than `abi.decode(ret, (address))`: the ABI decoder
        // reverts on a dirty upper 96 bits with empty returndata, which would surface to the MANAGER as an
        // anonymous revert instead of a named error.
        uint256 rawBase = abi.decode(ret, (uint256));
        if (rawBase > type(uint160).max) revert IPrices.CustomFeedBaseUnreadable(token, priceFeed);
        if (address(uint160(rawBase)) == token) revert IPrices.CustomFeedBaseCircular(token, priceFeed);
    }

    /// @notice Enriches a Position[] with human-readable labels from IPositionDescribable on each adapter, with the
    ///         `AssetKindRegistry`'s per-adapter operator overrides taking precedence over the adapter's own reply.
    /// @dev **The overrides ride the EXISTING per-adapter cache, which is what makes them affordable.** Both are
    ///      per-adapter constants, so they are fetched in the same `adapter != prevAdapter` branch that already
    ///      guarded the `protocolName()` staticcall — one extra flat-string read plus one extra ARRAY read per
    ///      DISTINCT adapter, not per position. On the real mainnet fixture that is a handful of adapters against
    ///      117 positions.
    ///
    ///      **On a protocol-name hit the adapter staticcall is skipped**, so an overridden adapter trades one cold
    ///      `staticcall` to the adapter for reads of the registry, which is warm after the first adapter since it is
    ///      the same address every time.
    ///
    ///      ⚠️ **That does NOT make the change gas-negative, and an earlier revision of this note claimed it did.**
    ///      Measured against a real no-registry baseline, not reasoned. ⚠️ **These are ILLUSTRATIVE readings, not
    ///      CI-pinned constants** — the tests assert the ORDERING and an upper BOUND, never these exact values, and
    ///      the figures drift with solc and EVM settings. They already drifted across runs of this very tree
    ///      (~109.1k vs ~109.0k baseline, ~5.1k vs ~5.3k surcharge under the retired scalar read), which is precisely
    ///      why nothing asserts them exactly. Re-measured on the array-override tree — the whole block moved, so do
    ///      not carry the old numbers forward:
    ///
    ///        no registry 109,418  <  hit 114,597  <  miss 116,981   (single-adapter fixture)
    ///
    ///      So the ordering is `no registry < hit < miss`, and THAT is what is pinned. The override never pays for
    ///      itself outright; it only claws back the one adapter staticcall it skips. **The MISS path is the common
    ///      case — no adapter has an override today — so this is strictly more expensive than before this change.**
    ///
    ///      ⚠️ **RE-MEASURED when the segment-0-only category override became the per-segment {setAdapterLabels}
    ///      array override, and the figures MOVED. This note quoted ~5.3k for one adapter and ~10.7k for two, from
    ///      the scalar `_safeString` read; both are retired.** The registry read is now a `string[]` behind the
    ///      isolating decode shim ({_labelOverride}), which costs more:
    ///
    ///        per-DISTINCT-ADAPTER surcharge, 2-adapter / 3-position fixture:  9,790 (scalar)  ->  15,343 (array)
    ///
    ///      i.e. roughly **+5.5k per distinct adapter**, and that increase is the PRICE of correctable deep
    ///      segments rather than a regression to be optimised away. Still per DISTINCT ADAPTER, not per position —
    ///      that is the property `test_gas_labelOverride_isPerAdapter_notPerPosition` and
    ///      `test_gas_surchargeIsPerAdapter_notPerPosition` exist to hold, and both bounds are set from a MUTATION
    ///      (the read moved into the loop body), never from taste. The mutant figures are deliberately not quoted
    ///      here: an earlier revision named a pair that those tests' own docstrings had already retired as
    ///      instrument-contaminated, so this comment contradicted the tests it cited.
    ///
    ///      ⚠️ Two earlier revisions of this note quoted a "~9.6k cold, from an independent 20-adapter sweep"
    ///      figure; that measurement was made outside this repo and NOTHING here reproduces it, so it was removed
    ///      rather than left as an unverifiable number in a comment. Every figure quoted above comes from a test in
    ///      this tree. **All of it is a synthetic warm fixture — no real portfolio has been measured.** Real
    ///      portfolios touch each adapter's mapping slot cold, so treat these as a FLOOR, not a forecast.
    ///      `AdapterLabelOverrides.t.sol::test_gas_registryLegIsBounded` measures the ordering above and bounds the
    ///      single-adapter surcharge.
    ///
    ///      **Fail-open, exactly like the adapter reads.** The protocol-name override is reached through the
    ///      {_safeString} shim and the label override through {_safeStringArray} — both gas-capped and
    ///      output-windowed — so a broken, hostile or absent registry degrades to "no override" instead of
    ///      reverting the verbose read. `registry == address(0)` (a NAV deployed before `08` wires one)
    ///      short-circuits before any call rather than relying on that degradation.
    ///
    ///      **The override is applied SEGMENT BY SEGMENT through {_applyLabelOverride}, the one helper both display
    ///      surfaces share.** Only indices `i < min(reply.length, override.length)` are touched, and an override
    ///      element of `""` leaves that segment exactly as the adapter derived it, live, on this call. So a reply the
    ///      adapter shortened (or declined to make at all) can never be written past — see
    ///      {IAssetKindRegistry.setAdapterLabels} for why that bound is load-bearing rather than defensive, and for
    ///      which segments an operator should be leaving alone.
    ///
    ///      **An empty reply is left empty here and GROWN on the configuration path**, and that divergence is
    ///      deliberate; the reasoning lives at {adapterDisplayInfo}'s else-branch. Note it now falls out of the shared
    ///      bound rather than needing its own guard: `min(0, n) == 0`, so there is no index to write.
    /// @param pos The positions to enrich.
    /// @param registry The chain's `AssetKindRegistry`, or `address(0)` when none is wired. Passed in rather than
    ///        read from storage because this library is reached by DELEGATECALL and has no view of `NAVCalculator`'s
    ///        layout; passing it also avoids a second registry pointer on a contract that is effectively full.
    ///        (For the current margin see {NAVCalculator}'s header, which is the single authority — this line used
    ///        to restate it and drifted. The history worth keeping: this PR spent 47 B threading the argument
    ///        through three call sites, then 354 B on {NAVCalculator.getAdapterDisplayInfo} — the latter against a
    ///        "+182 B floor" estimate that was wrong in BOTH directions, understating the cost of a nested
    ///        `string[][]` return AND wrongly calling it unaffordable.)
    function toVerbose(INAVCalculator.Position[] memory pos, address registry)
        external
        view
        returns (INAVCalculator.VerbosePosition[] memory verbose)
    {
        uint256 len = pos.length;
        verbose = new INAVCalculator.VerbosePosition[](len);
        // protocolName() takes no args, so its calldata is identical for every position — encode it once.
        bytes memory protocolNameCall = abi.encodeCall(IPositionDescribable.protocolName, ());
        // protocolName() returns a per-adapter constant, and positions are grouped by adapter (PriceFeedLib
        // concatenates each adapter's positions contiguously), so cache the last adapter's name and only
        // re-staticcall when the adapter changes — one protocolName() call per distinct adapter, not per position.
        // positionLabels() varies by positionId, so it stays per-position; the OVERRIDE that rewrites it does not —
        // it is keyed by adapter — so it is read here alongside the name, once per distinct adapter. Reading it inside
        // the loop body instead would turn a per-adapter cost into a per-position one;
        // `test_gas_labelOverride_isPerAdapter_notPerPosition` is what holds that.
        address prevAdapter;
        string memory prevName;
        string[] memory prevOverride;
        for (uint256 i = 0; i < len; i++) {
            address adapter = pos[i].balanceAdapter;
            if (i == 0 || adapter != prevAdapter) {
                prevName = _effectiveProtocolName(registry, adapter, protocolNameCall);
                prevOverride = _labelOverride(registry, adapter);
                prevAdapter = adapter;
            }
            // Labels are derived lazily from positionId (display only, off the NAV hot path) via a fail-open,
            // gas-capped staticcall — an adapter that doesn't implement positionLabels yields an empty array.
            // Field-by-field assignment (not a VerbosePosition literal, which would deep-copy the 17-field Position
            // as one expression) keeps this loop under the via_ir stack limit — which is also why the override is
            // applied in place on `verbose[i].labels` rather than through a local.
            verbose[i].position = pos[i];
            verbose[i].protocolName = prevName;
            verbose[i].labels = _safeStringArray(
                adapter,
                abi.encodeCall(IPositionDescribable.positionLabels, (pos[i].positionId)),
                _LABEL_READ_GAS,
                _LABELS_RETURN_BYTES,
                _LABEL_DECODE_GAS
            );
            // Overlay in place; the helper is shared with the configuration path so the two cannot drift. It writes
            // nothing when either array is empty, which is how "an empty reply stays empty" holds here.
            _applyLabelOverride(verbose[i].labels, prevOverride);
        }
    }

    /// @notice **The ONE place protocol-name precedence is decided**: the registry override wins, the adapter's own
    ///         `protocolName()` answers on a miss.
    /// @dev Called by BOTH the position path ({toVerbose}) and the configuration path ({adapterDisplayInfo}). That
    ///      sharing is the point and is load-bearing: it is what makes the two surfaces agree **by construction**
    ///      rather than by two implementations happening to match today and drifting apart later. Before this
    ///      existed, an override changed `getAccountPositionsVerbose` while a consumer enumerating
    ///      `getAllAdapters()` still saw the adapter's constant — two surfaces silently disagreeing about the same
    ///      adapter, which is the phantom-sibling split {IPositionDescribable.protocolName} exists to prevent.
    ///      **If a third display surface is ever added, it must call this too.**
    ///
    ///      Fail-open throughout: an absent, broken or hostile registry yields "" and falls through to the adapter.
    ///      On a hit the adapter staticcall is skipped entirely.
    function _effectiveProtocolName(address registry, address adapter, bytes memory protocolNameCall)
        private
        view
        returns (string memory name)
    {
        if (registry != address(0)) {
            name = _safeString(registry, abi.encodeCall(IAssetKindRegistry.getAdapterProtocolName, (adapter)));
            if (bytes(name).length != 0) return name;
        }
        return _safeString(adapter, protocolNameCall);
    }

    /// @notice The ONE place the per-segment label override is READ, shared by both display surfaces for the same
    ///         by-construction reason as {_effectiveProtocolName}. An empty array means no override.
    /// @dev Reached through {_safeStringArray} — the same fail-open shim the adapter's own `positionLabels` uses — so a
    ///      broken, hostile or absent registry degrades to "no override" rather than reverting a display read.
    ///
    ///      **The three bounds are TIGHTER here than for the adapter read, deliberately.** Reusing
    ///      {_LABEL_READ_GAS}/{_LABELS_RETURN_BYTES}/{_LABEL_DECODE_GAS} (1M / 4 KB / 1M) would have raised the
    ///      hostile-registry ceiling from 3x{_NAME_READ_GAS} (name-override read + label-override read + decode
    ///      shim, 300k) to ~2.1M **per distinct adapter**, which on a
    ///      fifteen-adapter account is over 31M gas — an availability regression on the verbose path introduced by a
    ///      display feature. A legitimate override is at most {_OVERRIDE_RETURN_BYTES} bytes of returndata and
    ///      one `SLOAD` chain, so the tight triple is orders of magnitude more than it needs.
    function _labelOverride(address registry, address adapter) private view returns (string[] memory) {
        if (registry == address(0)) return new string[](0);
        return _safeStringArray(
            registry,
            abi.encodeCall(IAssetKindRegistry.getAdapterLabels, (adapter)),
            _NAME_READ_GAS,
            _OVERRIDE_RETURN_BYTES,
            _OVERRIDE_DECODE_GAS
        );
    }

    /// @notice **The ONE place an override is overlaid onto an adapter's reply**, shared by the position path
    ///         ({toVerbose}) and the configuration path ({adapterDisplayInfo}).
    /// @dev That sharing is load-bearing for exactly the reason given on {_effectiveProtocolName}: two copies of this
    ///      rule would agree today and drift later, and "the two display surfaces disagree about one adapter" is a
    ///      failure this feature has already shipped twice. If a third display surface is ever added, it must call
    ///      this too.
    ///
    ///      Two rules, both of which have already bitten this codebase:
    ///
    ///      1. **`min(labels.length, over.length)`.** Writing index `i` of a shorter array is `Panic(0x32)` and the
    ///         never-revert property of the whole label path is gone. Adapter replies are NOT fixed-length:
    ///         `ConvexCurveLPStakingMetaBalanceAdapter` returns 2 or 3 elements depending on whether its
    ///         `rewarderCoinSymbols` probe answers, and most of the meta family returns 0, 1 or 2 depending on whether
    ///         its leaf read succeeded. The same bound is what stops an override LENGTHENING a reply past
    ///         `NAVCalculator`'s `_MAX_LABEL_ELEMENTS` ceiling.
    ///      2. **`""` skips.** An empty element means "leave this segment alone", which is how a computed leaf stays
    ///         derived live under a category-only correction. Dropping the check would blank every segment the
    ///         operator declined to specify.
    ///
    ///      Mutates `labels` in place (it is a memory reference), so the caller's array is updated without a copy —
    ///      which is also what keeps {toVerbose}'s loop inside the `via_ir` stack budget.
    function _applyLabelOverride(string[] memory labels, string[] memory over) private pure {
        uint256 n = labels.length < over.length ? labels.length : over.length;
        for (uint256 i = 0; i < n; i++) {
            if (bytes(over[i]).length != 0) labels[i] = over[i];
        }
    }

    /// @notice The override's LEADING NON-EMPTY PREFIX — what the configuration path grows an EMPTY reply to.
    /// @dev The prefix, not the whole array, and not just element 0. Copying the whole array would surface `""`
    ///      elements as blank breadcrumb segments for values the operator explicitly declined to supply and the
    ///      adapter did not supply either. Stopping at the first empty element is what preserves index alignment with
    ///      the position path: an override of `["", "Curve Pool"]` grows to NOTHING rather than promoting
    ///      `"Curve Pool"` to index 0, where it would contradict the category the position path shows.
    function _overridePrefix(string[] memory over) private pure returns (string[] memory out) {
        uint256 n;
        while (n < over.length && bytes(over[n]).length != 0) {
            ++n;
        }
        out = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = over[i];
        }
    }

    /// @notice The CONFIGURATION read path: each adapter's effective display name and its positionId-independent
    ///         breadcrumb, with the same overrides the position path applies.
    /// @dev Closes the surface split described on {_effectiveProtocolName}. A consumer pairs this with
    ///      `IBalances.getAllAdapters()` instead of staticcalling `protocolName()` on each adapter itself, and then
    ///      groups configured adapters by exactly the string the position path reports.
    ///
    ///      `positionLabels("")` is the interface's own convention for "no account, no positionId": an adapter whose
    ///      breadcrumb is positionId-independent answers with its full constant breadcrumb, and one that derives it
    ///      per position returns `[]`. So a computed adapter legitimately yields an empty array here, exactly as it
    ///      does today — this does not invent a breadcrumb for it.
    /// @param adapters The adapters to describe, typically `getAllAdapters()`.
    /// @param registry The chain's `AssetKindRegistry`, or `address(0)` when none is wired.
    function adapterDisplayInfo(address[] memory adapters, address registry)
        external
        view
        returns (string[] memory names, string[][] memory labels)
    {
        uint256 len = adapters.length;
        names = new string[](len);
        labels = new string[][](len);
        bytes memory protocolNameCall = abi.encodeCall(IPositionDescribable.protocolName, ());
        bytes memory labelsCall = abi.encodeCall(IPositionDescribable.positionLabels, (bytes("")));
        for (uint256 i = 0; i < len; i++) {
            address adapter = adapters[i];
            names[i] = _effectiveProtocolName(registry, adapter, protocolNameCall);
            labels[i] = _safeStringArray(adapter, labelsCall, _LABEL_READ_GAS, _LABELS_RETURN_BYTES, _LABEL_DECODE_GAS);
            string[] memory over = _labelOverride(registry, adapter);
            if (over.length == 0) continue;
            if (labels[i].length != 0) {
                // Overlay through the SHARED helper — the same call {toVerbose} makes, which is what makes the two
                // surfaces agree by construction rather than by two implementations matching. It bounds itself at
                // `min(...)`, so it can neither write past a shorter reply (Panic(0x32), and the never-revert property
                // gone) nor lengthen one.
                //
                // A reply SHORTER than the override is truncated rather than grown, unlike the empty case below. The
                // asymmetry is on purpose: growing a non-empty reply would emit a segment at an index the position
                // path leaves absent, so the two surfaces would disagree about the array's shape. Only the
                // has-nothing-to-say case is grown, and only because the operator's answer is then the whole answer.
                _applyLabelOverride(labels[i], over);
            } else {
                // **The empty case diverges from the position path ON PURPOSE, and getting this wrong left the two
                // surfaces disagreeing across most of the fleet.** Every meta-adapter answers `positionLabels("")` with
                // `[]` — `MetaBalanceAdapter._pidAddress` rejects a non-32-byte pid, so `_addressLabels` returns an
                // empty array — which is the interface's documented "no positionId, breadcrumb is per-position"
                // reply. Skipping the override there (as the position path does) meant an operator who set a
                // category on a Morpho or Uniswap meta-adapter saw it on `getAccountPositionsVerbose` and NOT on
                // this surface: exactly the split this function exists to close.
                //
                // The two paths ask different questions, which is why the answers differ. The POSITION path asks
                // "what is this position's breadcrumb" — a position the adapter declined to describe must not gain
                // one. This path asks "what breadcrumb is this ADAPTER configured with", and the operator has
                // answered that explicitly. So the override is surfaced directly, and it agrees with the position
                // path's segments rather than contradicting them.
                //
                // The grown array is the override's LEADING NON-EMPTY PREFIX, not the whole thing: a `""` element is
                // "leave the adapter's value alone", and there is no adapter value here, so surfacing it would render
                // a blank segment nobody supplied — and promoting a LATER segment into the gap would put it at an
                // index the position path never shows it at. See {_overridePrefix}.
                labels[i] = _overridePrefix(over);
            }
        }
    }

    /// @notice Gas stipend for the `decodeStringArray` shim (see `_safeStringArray`). Generous for any legitimate
    ///         label array (a handful of short strings decode in well under this) yet small enough that a
    ///         pathological declared length OOGs within a bounded budget instead of starving the verbose read.
    uint256 private constant _LABEL_DECODE_GAS = 1_000_000;

    /// @notice Gas stipend for EVERY registry-or-name read on the verbose path: the outer `protocolName()` staticcall,
    ///         the protocol-name override read ({_effectiveProtocolName}) — both through {_safeString} — AND the
    ///         per-segment label-override read ({_labelOverride}), which is an ARRAY read through
    ///         {_safeStringArray} but is deliberately given THIS stipend rather than the far larger
    ///         {_LABEL_READ_GAS}.
    /// @dev Every `protocolName()` in this repo is a `pure` constant string and an override read is a bounded `SLOAD`
    ///      chain over at most {MAX_OVERRIDE_SEGMENTS} 32-byte strings, so this is orders of magnitude more than any
    ///      legitimate read needs; it exists to bound a broken or hostile callee. Note the consequence of the shared
    ///      stipend: a hostile registry can burn 2x this per DISTINCT ADAPTER on the ACCOUNT path, which caches per
    ///      adapter — plus {_OVERRIDE_DECODE_GAS} for the array read's decode shim, so 3x this in total.
    ///      ⚠️ The CONFIGURATION path ({adapterDisplayInfo}) has no such cache — it is a flat loop over the caller's
    ///      array — so there the ceiling is the SAME 3x, but per ARRAY ENTRY rather than per distinct adapter, and a
    ///      caller passing the same adapter N times pays N times. **The composition is identical on both paths; only
    ///      the denominator differs.** (An earlier revision of this sentence said 2x here, silently dropping the
    ///      {_OVERRIDE_DECODE_GAS} term the account-path sentence two lines above already counts.) That is bounded
    ///      by the caller's own gas and its own array, not by the fleet size.
    ///
    ///      The decode shim's stipend IS spendable: a registry returning a well-formed `string[]` head clears
    ///      {_safeStringArray}'s `>= 64` guard, the decode runs and costs gas, and only then is the reply rejected
    ///      on `_MAX_LABEL_ELEMENTS` — after paying. It stays comfortably inside {_OVERRIDE_DECODE_GAS} because
    ///      {_OVERRIDE_RETURN_BYTES} bounds the work by the size of the copy window, not by anything the decoder
    ///      does. ⚠️ Do NOT restate that as a property of `abi.decode`: generalised to the ADAPTER read, whose
    ///      window is {_LABELS_RETURN_BYTES} = 4 KB, it is false — `NAVCalculator.decodeStringArray` records a
    ///      measured ~30x aliasing expansion there, which is precisely what {_LABEL_DECODE_GAS} guards.
    ///
    ///      ⚠️ **NO GAS FIGURES ARE QUOTED HERE, DELIBERATELY. Do not add any.** Four successive revisions of this
    ///      note stated the ceiling's composition and its measured cost in prose, and every one was wrong in a
    ///      different way — a multiple below its own arithmetic floor, a total reported as a marginal, a 4 KB
    ///      measurement attached to the 896-byte window, an ordering inverted, and twice a test named as evidence
    ///      for a bound it never reaches. The figures are unverifiable by CI, so nothing catches them when they rot.
    ///      What is true and checkable lives in the constants above and in the two assertions that bound this path:
    ///      `AdapterLabelOverrides.t.sol::test_gas_hostileRegistryIsBoundedByTheStipend` (ACCOUNT) and
    ///      `test_gas_configurationSurface_hostileRegistryIsBounded` (CONFIGURATION). If you need a number, measure
    ///      it and put it in an assertion — not in this comment.
    uint256 private constant _NAME_READ_GAS = 100_000;

    /// @notice Gas stipend for the outer `positionLabels()` staticcall. An order of magnitude above
    ///         {_NAME_READ_GAS} because a legitimate label leaf does real work: the joined multi-token leaves
    ///         (`_joinTokenSymbols` over a Balancer pool, `CurvePoolLib.coinSymbols` over an 8-coin pool) make
    ///         several `LabelLib` reads plus the pool reads that enumerate them. It is charged **per position**,
    ///         not per read path, so it is deliberately not larger: a portfolio of N positions makes N of these
    ///         calls in one frame, and the stipend times N is what a broken adapter can cost the verbose read.
    uint256 private constant _LABEL_READ_GAS = 1_000_000;

    /// @notice Bytes of `protocolName()` returndata copied into this frame: two ABI head words plus 256 bytes of
    ///         payload, matching `LabelLib`'s own metadata window. A longer name yields "".
    uint256 private constant _NAME_RETURN_BYTES = 320;

    /// @notice Bytes of `positionLabels()` returndata copied into this frame. A typical reply — a category plus a
    ///         leaf — is a few hundred bytes. The worst legitimate one is a joined multi-token leaf, whose
    ///         symbols are each capped at `LabelLib.MAX_METADATA_BYTES`; at eight tokens that is ~2.4 KB encoded,
    ///         inside this window.
    ///
    ///         **The token count is protocol-supplied, not capped, on the Balancer side.**
    ///         `CurvePoolLib.coinSymbols` stops at 8 coins, but `MetaBalanceAdapter._joinTokenSymbols` iterates
    ///         whatever the pool reports, and Balancer V2 permits up to 50 tokens. Live symbols are short, so
    ///         nothing deployed approaches this — but the honest bound is the sum of the symbol lengths, not a
    ///         token count, and a pool with many long symbols would cross it. A reply that does exceed the window
    ///         is truncated, fails to decode and yields no labels: display degrades, NAV does not move.
    uint256 private constant _LABELS_RETURN_BYTES = 4096;

    /// @notice Most segments a legitimate label override can carry — `AssetKindRegistry.MAX_ADAPTER_LABEL_SEGMENTS`.
    /// @dev Restated as a local literal rather than read off the registry, on purpose: the registry is untrusted on
    ///      this path (it may be an EOA, a self-destructed contract or hostile), so a bound taken FROM it would be a
    ///      bound it chooses. This is only ever used to size the copy window below; the registry enforces the real
    ///      bound on the write side, and a reply exceeding this window simply fails to decode and yields no override.
    ///
    ///      ⚠️ **This value is COUPLED to `NAVCalculator._MAX_LABEL_ELEMENTS`, and raising the registry's write-side
    ///      cap alone would silently break overrides.** {_labelOverride} reaches the registry through the same
    ///      {_safeStringArray} shim as an adapter, so the reply passes through `decodeStringArray`, which REVERTS on
    ///      `arr.length > _MAX_LABEL_ELEMENTS` — and the caller's `catch` turns that into "no override", with no
    ///      event and no error. So an operator who set a 9-segment override after someone raised
    ///      `MAX_ADAPTER_LABEL_SEGMENTS` past 8 would see the write succeed and the whole override vanish on read.
    ///      All three numbers (`_MAX_LABEL_ELEMENTS`, `MAX_ADAPTER_LABEL_SEGMENTS`, this one) are 8 and must move
    ///      together.
    ///
    ///      ⚠️ **`AssetKindRegistry.MAX_ASSET_LABEL_BYTES = 32` is a FOURTH member of that set, on the byte axis
    ///      rather than the count axis, and it is the one most easily missed.** {_OVERRIDE_RETURN_BYTES} below
    ///      hardcodes `96` bytes per element as `32 offset + 32 length + 32 padded payload`; that last 32 IS
    ///      `MAX_ASSET_LABEL_BYTES`, rounded up to a word. Because payloads are `ceil32`-padded, raising the byte cap
    ///      to just 33 makes each element cost 128 instead of 96, so a maximal 8-segment override encodes to 1,088
    ///      bytes against an unchanged 896-byte window: it overflows, fails to decode, and the override vanishes IN
    ///      FULL with no event and no error — the identical silent-loss failure this note already describes for the
    ///      count axis. The coupling is NOT compiler-checked (the constant lives in `AssetKindRegistry`, and pulling
    ///      it in would put a `src/nav` dependency on the pricing library for a compile-time literal), so it is held
    ///      by `test_labelsOverride_maximalOverrideSurvivesTheReturnWindow` instead, which drives the true worst case
    ///      (8 x 32 bytes = 832 bytes, 64 bytes of slack) through the read path and asserts CONTENT, not lengths.
    uint256 private constant MAX_OVERRIDE_SEGMENTS = 8;

    /// @notice Bytes of `getAdapterLabels()` returndata copied into this frame.
    /// @dev Derived, not guessed. The registry caps each segment at `MAX_ASSET_LABEL_BYTES = 32`, so a `string[]` of
    ///      `n` such elements encodes as
    ///      `32 (array offset) + 32 (length) + n*32 (element offsets) + n*(32 length + 32 padded payload)`
    ///      = `64 + 96n`, plus two words of slack. **Written as the expression rather than the number** so the
    ///      SEGMENT-COUNT half of the derivation is checked by the compiler and {MAX_OVERRIDE_SEGMENTS} is
    ///      load-bearing instead of decorative — note the BYTE half is not, since the `96` embeds
    ///      `MAX_ASSET_LABEL_BYTES = 32` as a literal (see the warning on {MAX_OVERRIDE_SEGMENTS});
    ///      it folds to 896 at compile time and costs nothing. A reply exceeding the window is truncated, fails to
    ///      decode, and yields no override — display degrades, nothing reverts. Far tighter than
    ///      {_LABELS_RETURN_BYTES}, and that is the point: see {_labelOverride}. (An earlier revision said "two
    ///      orders of magnitude"; the two constants are visible three lines apart, so quantifying the ratio in prose
    ///      bought nothing and was wrong by roughly twentyfold.)
    uint256 private constant _OVERRIDE_RETURN_BYTES = 64 + 96 * MAX_OVERRIDE_SEGMENTS + 64;

    /// @notice Gas stipend for the `decodeStringArray` shim when decoding a label OVERRIDE (see {_labelOverride}).
    /// @dev A tenth of {_LABEL_DECODE_GAS}. The reason for the difference is not the payload — it is that this decode
    ///      runs once per DISTINCT ADAPTER on the account path in the same frame as everything else, on returndata
    ///      already truncated to {_OVERRIDE_RETURN_BYTES}. It still has to be capped rather than removed — but be
    ///      precise about WHICH shape it defends against, because an earlier revision named the wrong one.
    ///
    ///      NOT the over-declared length: a declared array length is independent of the returndata size, but a
    ///      memory-source `abi.decode` bounds-checks it against the blob and rejects it cheaply, without allocating.
    ///      The expensive shapes are the ones that DECODE — many elements, and offsets aliasing one payload, so a
    ///      reply that fits the window expands to a multiple of it (`NAVCalculator.decodeStringArray` records ~30x
    ///      for a 4 KB blob). Inside this 896-byte window that expansion stays well under this stipend; on the
    ///      ADAPTER path, with a 4 KB window, it is what {_LABEL_DECODE_GAS} exists for. No figure is quoted here on
    ///      purpose — see the note on {_NAME_READ_GAS}.
    uint256 private constant _OVERRIDE_DECODE_GAS = 100_000;

    /// @notice Staticcall bounded in BOTH directions — a gas stipend on the callee and a fixed output window on
    ///         the reply — returning the success flag and the bytes actually copied.
    /// @dev Both bounds are load-bearing and neither substitutes for the other. Same shape as `LabelLib`'s
    ///      metadata reader, for the same two reasons:
    ///
    ///      - **The stipend** bounds what the callee spends. Uncapped, a callee that loops takes 63/64 of
    ///        everything this frame holds, and in `_toVerbose` that frame is the whole verbose read — so one
    ///        broken adapter costs every position's labels and, past a point, the read itself. Note also that a
    ///        raw staticcall assigning `(bool, bytes memory)` `returndatacopy`s a revert payload, which a
    ///        parameterless `catch {}` does not: on the failure path the uncapped raw form is the expensive one,
    ///        reaching ~1e9 gas against a callee that returns megabytes.
    ///      - **The output window** bounds what this frame copies, which a stipend alone does not. A ~200 KB
    ///        reply costs the callee only ~95k of memory expansion — well inside any stipend here — while the
    ///        caller pays `returndatacopy` plus its own monotonically growing memory, charged outside the stipend
    ///        and quadratic in the frame's total. `_toVerbose` reads `positionLabels` once per position in a
    ///        single frame, so that total is exactly the cost that matters: eight such replies in one verbose
    ///        read cost ~8.9M gas without the window and under 3M with it, and the gap widens with position
    ///        count. An explicit output size makes the per-read cost flat instead.
    ///
    ///      `returndatasize()` is reported untruncated, so callers bound their head validation on what was
    ///      actually copied (`ret.length`), never on what the callee claimed to send.
    /// @param target The contract to probe.
    /// @param callData The encoded call.
    /// @param gasStipend Maximum gas forwarded to `target`.
    /// @param maxReturnBytes Maximum bytes copied into this frame's memory, whatever the callee returns.
    /// @return ok The raw staticcall success flag.
    /// @return ret The copied returndata, truncated to `maxReturnBytes`.
    function _boundedRead(address target, bytes memory callData, uint256 gasStipend, uint256 maxReturnBytes)
        private
        view
        returns (bool ok, bytes memory ret)
    {
        // Discard the reply at the call (`outsize = 0`), then copy back only what is both present and wanted.
        // Allocating `maxReturnBytes` up front instead would charge this frame for the worst case on every read,
        // however small the real reply: `_toVerbose` reads once per position in a SINGLE frame, memory cost is
        // quadratic in that frame's total, and the honest path would pay it. Copying after the fact keeps the
        // ceiling while charging only the actual size.
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(gasStipend, target, add(callData, 0x20), mload(callData), 0x00, 0x00)
            // `returndatasize()` is the untruncated size — the bound below is on what we choose to take.
            size := returndatasize()
            if gt(size, maxReturnBytes) { size := maxReturnBytes }
        }
        // A failed call's payload is discarded by both callers, so do not pay to carry it. `_toVerbose` runs this
        // once per position in a single frame and Solidity never reclaims memory, so copying revert data would
        // accumulate across the whole position list for something no one reads.
        if (!ok) return (false, ret);
        ret = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0x00, size)
        }
    }

    /// @notice Fully fail-open string read: staticcalls `target` and returns the decoded string only when the
    ///         returndata is a well-formed ABI string, otherwise "".
    /// @dev A plain `try/catch` only catches a reverting call — it does NOT catch a *successful* call whose
    ///      returndata cannot be decoded into `string` (e.g. a non-contract returning empty data, or a contract
    ///      returning a malformed/short blob), which would revert the whole verbose read. This validates the
    ///      ABI envelope (canonical 0x20 offset + length within bounds) before decoding so the decode itself can
    ///      never revert on bounds. (Bounds, not cost — see the inline note at the guard.)
    ///
    ///      **The bound is the RAW declared length, not `ceil32` of it.** A memory-source `abi.decode` bounds on
    ///      the declared length itself: it needs `64 + strLen <= ret.length`, and reads exactly `strLen` bytes
    ///      (under cancun, an `mcopy` of precisely that many). Verified on solc 0.8.34 / via_ir / cancun —
    ///      `offset = 0x20`, `strLen = 5`, `ret.length = 69` decodes to a 5-character name rather than reverting.
    ///      A `ceil32` bound would be *stricter* than `abi.decode`, rejecting the band
    ///      `64 + strLen <= ret.length < 64 + ceil32(strLen)` — a reply declaring a length whose payload is
    ///      delivered unpadded — and a guard stricter than the thing it protects is a silent drop, not safety.
    ///      solc and vyper always pad an encoded `string` to a word, so that band is reachable only from a
    ///      hand-rolled assembly return or a non-solc toolchain; matching `abi.decode` exactly is still the
    ///      guard worth having.
    ///
    ///      Cost is a separate concern from bounds, and is handled separately: {_boundedRead} caps both what the
    ///      target may spend ({_NAME_READ_GAS}) and what this frame copies ({_NAME_RETURN_BYTES}). The head
    ///      validation is what makes the decode total; the stipend and the output window are what make its cost
    ///      total.
    function _safeString(address target, bytes memory callData) private view returns (string memory) {
        (bool ok, bytes memory ret) = _boundedRead(target, callData, _NAME_READ_GAS, _NAME_RETURN_BYTES);
        if (!ok || ret.length < 64) return ""; // need at least offset(32) + length(32)
        uint256 offset;
        uint256 strLen;
        assembly {
            offset := mload(add(ret, 0x20))
            strLen := mload(add(ret, 0x40))
        }
        // Canonical ABI string: offset == 0x20 and the declared body fits inside the returndata. `ret.length >= 64`
        // is guaranteed by the early return above, so the subtraction cannot underflow. This is exactly the bound
        // `abi.decode` itself applies, so the decode below cannot revert on bounds.
        //
        // That is a bounds claim, not a cost one: it buys that the decode can never allocate beyond what the
        // target actually delivered, and nothing about what the target may spend or send. Cost is bounded
        // separately and unconditionally by `_boundedRead` — `ret.length` is at most {_NAME_RETURN_BYTES}
        // however large the reply was, so `strLen` is bounded by that too, and an over-long name (or a reply
        // whose payload lands outside the copied window) simply yields "".
        if (offset != 0x20 || strLen > ret.length - 64) return "";
        return abi.decode(ret, (string));
    }

    /// @notice Fail-open `string[]` read: staticcalls `target` and decodes a `string[]`, returning an empty array on
    ///         a failed/short call or any decode failure rather than reverting the whole verbose read. A `string[]`
    ///         has nested offsets/lengths that are impractical to validate inline (as `_safeString` does for a flat
    ///         string), so the possibly-reverting `abi.decode` is isolated behind a try/catch — which needs an
    ///         external call boundary (`decodeStringArray`).
    /// @dev Three bounds, one per thing the callee can spend on this frame's behalf; none of them covers what
    ///      the other two do:
    ///      1. `decodeGas` on the shim — a reply whose `string[]` element offsets ALL point at the same payload
    ///         decodes to a multiple of the window (measured ~30x for a 4 KB blob; see
    ///         `NAVCalculator.decodeStringArray`), and that expansion is allocated inside this frame. The declared
    ///         array length is independent of the returndata size, which is why `_safeString`'s head validation has
    ///         no analogue here and the decode must be isolated instead. (An earlier revision attributed the cost to
    ///         a huge DECLARED length "burning ~63/64 of the remaining gas". That shape is the cheap one: a
    ///         memory-source `abi.decode` bounds-checks the length against the blob and rejects it without
    ///         allocating. The expensive shapes are the ones that DECODE — many elements, or offsets aliasing one
    ///         payload — which succeed and are only then rejected on the element cap.)
    ///      2. `gasStipend` on the call — the shim's cap says nothing about the callee itself, which can loop and
    ///         never return.
    ///      3. `maxReturnBytes` on the reply — a gas stipend alone leaves the `returndatacopy` this frame
    ///         pays unbounded; see {_boundedRead}.
    ///      Together they contain a broken callee to the labels of whatever it was asked about, which then come back
    ///      `[]`. Legitimate label arrays are far inside all three.
    ///
    ///      **All three are PARAMETERS rather than the constants they used to be**, because this shim now serves two
    ///      callees with very different legitimate worst cases: an adapter's `positionLabels` (which does real
    ///      on-chain work and can return a joined multi-token leaf) and the registry's `getAdapterLabels` (a bounded
    ///      `SLOAD` chain). Reusing the adapter's generous triple for the registry read raised the hostile-registry
    ///      ceiling by an order of magnitude per distinct adapter; see {_labelOverride}. Passing them explicitly also
    ///      puts each bound where a reader can see which callee it is defending against.
    /// @param target The contract to read from.
    /// @param callData The encoded call.
    /// @param gasStipend Maximum gas forwarded to `target`.
    /// @param maxReturnBytes Maximum bytes of reply copied into this frame.
    /// @param decodeGas Maximum gas the isolated `abi.decode` may spend.
    function _safeStringArray(
        address target,
        bytes memory callData,
        uint256 gasStipend,
        uint256 maxReturnBytes,
        uint256 decodeGas
    ) private view returns (string[] memory) {
        (bool ok, bytes memory ret) = _boundedRead(target, callData, gasStipend, maxReturnBytes);
        if (!ok || ret.length < 64) return new string[](0); // need at least offset(32) + length(32)
        try INavLabelDecoder(address(this)).decodeStringArray{gas: decodeGas}(ret) returns (string[] memory arr) {
            return arr;
        } catch {
            return new string[](0);
        }
    }
}
