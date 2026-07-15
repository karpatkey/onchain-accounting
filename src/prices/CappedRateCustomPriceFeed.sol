// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {ICappedRateFeed} from "src/prices/ICappedRateFeed.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CappedRateCustomPriceFeed
/// @author KPK
/// @notice Base for yield-bearing "exchange-rate × base/USD" feeds that bound the exchange rate before pricing, to
///         defend the subscription/redemption share price (ADR 0021). It layers two protections on the raw
///         protocol rate a subclass supplies via {_rawRate}:
///           1. GROWTH CAP — the rate may not exceed a governance snapshot grown at `maxAprBps` per year. This
///              blunts a compromised/buggy rate provider whose rate jumps. Config (`maxAprBps`, snapshot) lives on
///              the NAV (`IPrices.getRateCap`), NOT here — so this feed stays IMMUTABLE (no admin surface). It is
///              armed by the MANAGER calling `NAVCalculator.snapshotRateCap` once post-deploy; until then the cap
///              is inactive (raw rate passes through).
///           2. MARKET FLOOR (optional) — `min(rate, marketRate)` against a market feed (base-per-underlying,
///              e.g. a Chainlink LST/ETH feed) so a genuine depeg pulls the price DOWN. Immutable constructor arg;
///              `address(0)` = growth-cap-only (used where no suitable market feed exists). Fail-open: a stale or
///              reverting market feed simply skips the floor (it is a secondary layer, never a reason to stale).
/// @dev Subclasses implement {_rawRate} (uncapped 18-dec base-per-underlying, fail-to-stale by returning 0). The
///      base/USD term, staleness and the `rate × base/USD` math are inherited from {BaseCustomPriceFeed}. A raw
///      rate of 0 marks the asset stale (BaseCustomPriceFeed); the cap/floor only ever LOWER the rate, never raise
///      it — so this can only under-report, never over-report.
abstract contract CappedRateCustomPriceFeed is BaseCustomPriceFeed, ICappedRateFeed {
    using Math for uint256;

    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BPS = 10_000;

    /// @notice Optional market feed for the depeg floor (base-per-underlying). `address(0)` ⇒ growth-cap-only.
    AggregatorV3Interface public immutable MARKET_FEED;

    /// @notice `10 ** MARKET_FEED.decimals()`, captured once; 0 when no market feed.
    uint256 internal immutable _marketUnit;

    /// @notice Staleness window (seconds) for the market feed; the floor is skipped past it.
    uint256 public immutable MARKET_HEARTBEAT;

    /// @param underlying_   The yield-bearing token being priced.
    /// @param nav_          The NAVCalculator proxy (base/USD source + cap config source).
    /// @param baseAsset_    The base asset whose NAV-selected USD price scales the rate (e.g. WETH).
    /// @param marketFeed_   Market feed for the depeg floor (base-per-underlying), or `address(0)` for none.
    /// @param marketHeartbeat_ Staleness window for the market feed (ignored when `marketFeed_` is `address(0)`).
    constructor(address underlying_, address nav_, address baseAsset_, address marketFeed_, uint256 marketHeartbeat_)
        BaseCustomPriceFeed(underlying_, nav_, baseAsset_)
    {
        MARKET_FEED = AggregatorV3Interface(marketFeed_);
        MARKET_HEARTBEAT = marketHeartbeat_;
        _marketUnit = marketFeed_ == address(0) ? 0 : 10 ** uint256(AggregatorV3Interface(marketFeed_).decimals());
    }

    /// @notice The uncapped protocol exchange rate (18-dec, base-per-underlying). Subclass hook; return 0 to mark
    ///         the price stale (e.g. on a reverting/stale provider — wrap the external read in try/catch).
    function _rawRate() internal view virtual returns (uint256);

    /// @inheritdoc ICappedRateFeed
    function rawRate() external view returns (uint256) {
        return _rawRate();
    }

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev The single rate the pricing math uses: raw → growth-capped → market-floored. Both steps only lower it.
    function _rate() internal view override returns (uint256) {
        uint256 rate = _rawRate();
        if (rate == 0) return 0;
        rate = _applyGrowthCap(rate);
        rate = _applyMarketFloor(rate);
        return rate;
    }

    /// @notice Caps `rate` at `snapshotRate` grown by `maxAprBps`/yr since the snapshot. Inactive (returns `rate`)
    ///         when the cap is un-armed (snapshotRate == 0) or disabled (maxAprBps == 0).
    function _applyGrowthCap(uint256 rate) internal view returns (uint256) {
        IPrices.RateCap memory c = IPrices(address(NAV)).getRateCap(UNDERLYING);
        if (c.snapshotRate == 0 || c.maxAprBps == 0) return rate;
        uint256 elapsed = block.timestamp > c.snapshotTimestamp ? block.timestamp - c.snapshotTimestamp : 0;
        // cap = snapshotRate * (1 + maxAprBps/BPS * elapsed/YEAR); mulDiv avoids intermediate overflow.
        uint256 growth = c.snapshotRate.mulDiv(c.maxAprBps * elapsed, BPS * YEAR, Math.Rounding.Floor);
        uint256 cap = c.snapshotRate + growth;
        return rate > cap ? cap : rate;
    }

    /// @notice Floors `rate` at the market feed's base-per-underlying quote (depeg protection). Fail-open: a
    ///         missing/reverting/stale/non-positive market feed skips the floor and returns `rate` unchanged.
    function _applyMarketFloor(uint256 rate) internal view returns (uint256) {
        if (address(MARKET_FEED) == address(0)) return rate;
        try MARKET_FEED.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return rate;
            if (updatedAt == 0 || block.timestamp - updatedAt >= MARKET_HEARTBEAT) return rate; // stale → skip floor
            uint256 marketRate = uint256(answer).mulDiv(1e18, _marketUnit, Math.Rounding.Floor); // → 18-dec
            return rate < marketRate ? rate : marketRate;
        } catch {
            return rate;
        }
    }

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev Must keep advertising ICustomPriceFeed (registration requires it) and adds ICappedRateFeed.
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ICappedRateFeed).interfaceId;
    }
}
