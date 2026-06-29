// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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

    /// @notice Feed-selection core, shared by the external `selectFeed` wrapper and `buildPriceData` so the latter
    ///         reuses the logic via an internal jump rather than a second DELEGATECALL.
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
        winnerIdx = type(uint256).max;

        for (uint256 i; i < len; ++i) {
            IPrices.PriceFeedConfig storage cfg = configs[i];
            int256 rawPrice;
            uint256 updatedAt;

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

            if (winnerIdx == type(uint256).max || effectiveTime > bestTime) {
                bestTime = effectiveTime;
                bestPrice = rawPrice;
                bestDecimals = cfg.decimals;
                winnerIdx = i;
            }
        }

        if (winnerIdx == type(uint256).max) {
            return (0, configs[0].decimals, true, type(uint256).max, 0);
        }

        return (bestPrice, bestDecimals, false, winnerIdx, healthyFeedCount);
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
        address asset,
        bool sequencerDown
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

        uint256 assetCount = registeredAssets.length;
        if (assetCount == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            return nav; // value 0, sequencerDown false (no assets registered)
        }

        INAVCalculator.PositionBalance[] memory allPositions =
            _getPositionBalances(allAdapters, assetIndex, account, address(0));

        nav.sequencerDown = sequencerDown;
        if (allPositions.length == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            return nav; // value 0
        }

        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);
        PriceFeedCache[] memory priceFeeds = _buildPriceFeedCache(priceOracles, assetsWithPositions);
        nav.stalePriceAssets = _buildStaleAssets(assetIndex, registeredAssets, priceFeeds);

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
    ///         (assetFilter == address(0) means all assets). Mirrors NAVCalculator._getAccountPositionsInternal.
    /// @dev The caller validates the quote asset and (when set) the asset filter before calling.
    function computeAccountPositions(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        mapping(address => uint256) storage assetIndex,
        INAVCalculator.Asset[] storage registeredAssets,
        address[] memory allAdapters,
        uint256 metaInstanceTotal,
        address account,
        address assetFilter,
        address quoteAsset,
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

        PriceFeedCache[] memory priceFeeds = _buildPriceFeedCache(priceOracles, assetsWithPositions);
        QuoteAssetInfo memory quoteInfo =
            _getQuoteAssetInfo(priceOracles, assetIndex, registeredAssets, quoteAsset, nativeTokenSymbol);

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

        uint256 assetCount = registeredAssets.length;
        if (assetCount == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            positions = new INAVCalculator.Position[](0);
            return (nav, positions); // value 0, sequencerDown false (no assets registered)
        }

        INAVCalculator.PositionBalance[] memory allPositions =
            _getPositionBalances(allAdapters, assetIndex, account, address(0));

        nav.sequencerDown = sequencerDown;
        if (allPositions.length == 0) {
            nav.stalePriceAssets = new INAVCalculator.Asset[](0);
            positions = new INAVCalculator.Position[](0);
            return (nav, positions); // value 0
        }

        address[] memory assetsWithPositions = _extractUniqueAssets(allPositions);
        PriceFeedCache[] memory priceFeeds = _buildPriceFeedCache(priceOracles, assetsWithPositions);
        nav.stalePriceAssets = _buildStaleAssets(assetIndex, registeredAssets, priceFeeds);

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
        INAVCalculator.Asset[] storage registeredAssets,
        bool sequencerDown
    ) external view returns (bool, address[] memory stalePriceAssets) {
        uint256 totalAssets = registeredAssets.length;
        if (totalAssets == 0) {
            return (sequencerDown, new address[](0));
        }

        address[] memory staleAssetsTemp = new address[](totalAssets);
        uint256 staleCount = 0;
        for (uint256 i = 0; i < totalAssets; i++) {
            address assetAddr = registeredAssets[i].asset;
            // _selectFeedCore reverts PriceFeedNotSet(assetAddr) when the asset has no feeds (same selector as the
            // former explicit _requirePriceFeedExists guard), so no separate length check is needed here.
            (,, bool stale,,) = _selectFeedCore(priceOracles, assetAddr);
            if (stale) staleAssetsTemp[staleCount++] = assetAddr;
        }
        stalePriceAssets = ArrayLib.copySliceAddress(staleAssetsTemp, staleCount);
        return (sequencerDown, stalePriceAssets);
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

    /// @notice Builds the selected-feed price cache for a list of assets.
    function _buildPriceFeedCache(
        mapping(address => IPrices.PriceFeedConfig[]) storage priceOracles,
        address[] memory assets
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
                priceFeeds[i] = PriceFeedCache({asset: asset, price: 0, decimals: NAV_DECIMALS, stale: true});
                continue;
            }
            (int256 price, uint8 decimals, bool stale,,) = _selectFeedCore(priceOracles, asset);
            priceFeeds[i] = PriceFeedCache({asset: asset, price: price, decimals: decimals, stale: stale});
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
        position.quoteAssetStale = quoteAssetStale;
    }

    /// @notice Converts an amount of one asset to value in quote (USD when quotePrice is 0). Mirrors the former
    ///         NAVCalculator._priceConversion.
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

        uint8 dec;
        if (priceType == IPrices.PriceType.Custom) {
            dec = ICustomPriceFeed(priceFeed).decimals();
        } else if (priceType == IPrices.PriceType.API3) {
            uint8 sourceDec = AggregatorV3Interface(priceFeed).decimals();
            if (sourceDec != 18) revert IPrices.InvalidPriceOracle();
            dec = 8;
        } else {
            dec = AggregatorV3Interface(priceFeed).decimals();
        }

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
        uint256 len = configs.length;

        if (index >= len) revert IPrices.PriceFeedIndexOutOfBounds(asset, index);
        if (len == 1) revert IPrices.CannotRemoveLastFeed(asset);

        address removedFeed = configs[index].priceFeed;

        if (index != len - 1) {
            address movedFeed = configs[len - 1].priceFeed;
            configs[index] = configs[len - 1];
            emit IPrices.PriceFeedIndexChanged(asset, movedFeed, len - 1, index);
        }
        configs.pop();

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
                // inline removeFeedAt to avoid a second delegatecall
                if (len == 1) revert IPrices.CannotRemoveLastFeed(asset);
                if (i != len - 1) {
                    address movedFeed = configs[len - 1].priceFeed;
                    configs[i] = configs[len - 1];
                    emit IPrices.PriceFeedIndexChanged(asset, movedFeed, len - 1, i);
                }
                configs.pop();
                emit IPrices.PriceFeedRemoved(asset, priceFeed, i);
                return;
            }
        }

        revert IPrices.PriceFeedNotFound(asset, priceFeed);
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
