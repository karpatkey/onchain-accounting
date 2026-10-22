// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {StaticCallLib} from "src/utils/StaticCallLib.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {InvalidArguments} from "src/errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Chainlink Cross-Rate Price Adapter
/// @author KPK
/// @notice Computes `X/USD` from TWO Chainlink feeds read directly: an `X / B` rate feed and a `B / USD` feed,
///         `price = (X per B) * (USD per B)`. Use for an asset that has no direct Chainlink `X / USD` feed but
///         does have a Chainlink rate against some base B that itself has a Chainlink USD feed.
/// @dev **Why this shape exists, and why it is NOT {CrossRateCustomPriceFeed}.** The motivating case is mainnet
///      WBTC (issue #356). WBTC's primary is Chainlink `BTC / USD`, which prices BITCOIN, not the token, so a
///      WBTC depeg is invisible to it. Its divergence MONITOR must therefore be WBTC-specific, and mainnet has no
///      Chainlink `WBTC / USD`, so the monitor is `WBTC / BTC` x `BTC / USD`. The generic
///      {CrossRateCustomPriceFeed} reads its base/USD leg back OUT OF THE NAV (`getPriceData(BASE_ASSET)`), and
///      for WBTC the base asset the NAV prices BTC/USD on IS WBTC itself — registration rejects that outright
///      (`IPrices.CustomFeedBaseCircular`, `PriceFeedLib._validateFeedNotCircular`, on `addMonitorFeed` too). So
///      both legs are read from Chainlink here, and the feed has no NAV dependency at all.
/// @dev Price is `rate * baseUsd / 10**rateDecimals`, normalised from the base feed's decimals to
///      `NAV_DECIMALS` (8), in ONE `Math.mulDiv` (Math.Rounding.Floor) with the division last: the 512-bit
///      product cannot overflow, and nothing is floored before the final division. Worked example with both legs
///      at 8 decimals: rate `100_000_000` (1.0 WBTC/BTC) x base `10_000_000_000_000` ($100,000) /
///      `1e8` = `10_000_000_000_000` = $100,000.00 per WBTC.
/// @dev **No NAV dependency: `BASE_ASSET == address(0)`.** Neither leg is read from the NAV, so no
///      {NavBaseUsdLib} circularity invariant applies and `preflight_config.py`'s base allowlist does not govern
///      this feed. It still IMPLEMENTS {INavSourcedPriceFeed} and answers `address(0)`, exactly as
///      {InvertedChainlinkCustomPriceFeed} does: registration probes `BASE_ASSET()` by raw staticcall and
///      **fails closed** (`IPrices.CustomFeedBaseUnreadable`) on a feed that cannot answer. Omitting the function
///      does NOT mean "no dependency" — it means UNREGISTERABLE.
/// @dev **Staleness follows ADR 0029: a stale leg flags the price, it never changes it.** `stale` is set when
///      EITHER leg is at or past its own heartbeat (ages measured from `min(updatedAt, block.timestamp)`), and the
///      computed price is still returned. The returned `updatedAt` is the OLDER of the two legs' timestamps — the
///      NAV ages a Custom feed by it and stops using the feed once it is `MAX_STALE_PRICE_AGE` old, so it is never
///      `block.timestamp`. Only STRUCTURAL failures return `(0, true)`: a non-positive answer on either leg, a
///      live `decimals()` on either leg that differs from (or cannot be read as) the value pinned at
///      construction, or a rate answer outside `[MIN_RATE, MAX_RATE]`.
/// @dev **BOTH cached decimals are re-asserted on every read**, as {InvertedChainlinkCustomPriceFeed} does for its
///      one leg. Here the rate decimals DIVIDE (a decrease under-reports) but the base decimals set the
///      normalisation — a base feed migrating from 8 to 6 decimals while the cached denominator still assumed 8
///      would under-report 100x, and one migrating to MORE decimals would OVER-report by the same factor, with
///      `stale == false`. The contract is immutable, so a mismatch is reported structurally instead. The check
///      uses {StaticCallLib-probeWord}, which is total over any returndata, so an aggregator answering
///      `success` with a short or dirty word lands on the stale path instead of reverting this frame.
/// @dev **The rate band is the runtime pair pin.** `RateFeedGuard` pins `description()` and a plausibility band,
///      but only before deploy; it cannot see a Chainlink proxy that later re-points its aggregator at the same
///      address with the same decimals. A rate leg re-quoted to another pair (or inverted) lands far outside a
///      band sized for a near-parity wrapper, and is reported structurally. There is no band on the base leg: it
///      is a plain USD price and the NAV's own divergence machinery compares the result against the primary.
/// @dev **MODELLING ASSUMPTION.** The result is the price of X only to the extent the `X / B` feed prices the
///      TOKEN X. For WBTC, Chainlink `WBTC / BTC` is a market rate for the wrapper, which is exactly what makes it
///      a depeg monitor; a rate feed that tracked a protocol's internal exchange rate would not detect a market
///      discount.
contract ChainlinkCrossRateCustomPriceFeed is ICustomPriceFeed, INavSourcedPriceFeed {
    using Math for uint256;

    /// @notice This feed reads NO base price out of the NAV — both legs are read directly from Chainlink.
    /// @dev Constant, not immutable: the answer can never vary by deployment for this shape.
    address public constant override BASE_ASSET = address(0);

    /// @notice The asset whose USD price is returned (X).
    address public immutable UNDERLYING_ASSET;

    /// @notice Chainlink `X / B` oracle (e.g. `WBTC / BTC`) — reads as **B per X**. It MULTIPLIES the base price.
    AggregatorV3Interface public immutable RATE_FEED;

    /// @notice Heartbeat (seconds) after which `RATE_FEED` is considered stale.
    uint256 public immutable RATE_HEARTBEAT;

    /// @notice Chainlink `B / USD` oracle (e.g. `BTC / USD`) — reads as **USD per B**.
    AggregatorV3Interface public immutable BASE_USD_FEED;

    /// @notice Heartbeat (seconds) after which `BASE_USD_FEED` is considered stale.
    uint256 public immutable BASE_HEARTBEAT;

    /// @notice Inclusive lower/upper bound on the RAW rate answer, in `RATE_FEED`'s own decimals.
    /// @dev The runtime pair pin — see the contract docstring. Keep in step with the config's `rateFeedGuard`
    ///      band, which `RateFeedGuard` reconciles against the constructor band before deploy.
    uint256 public immutable MIN_RATE;
    uint256 public immutable MAX_RATE;

    /// @notice `RATE_FEED.decimals()` and `BASE_USD_FEED.decimals()`, captured at construction. Compared against
    ///         the live values per read.
    /// @dev Stored as the raw `uint8` on purpose (as {InvertedChainlinkCustomPriceFeed} explains): comparing the
    ///      live value to this is an equality, whereas recomputing `10 ** liveDecimals` REVERTS for
    ///      `liveDecimals >= 78`, turning a hostile or broken `decimals()` into a whole-feed revert.
    uint8 private immutable _rateDecimals;
    uint8 private immutable _baseDecimals;

    /// @notice Multiplier applied to the rate before the single `mulDiv` — `10 ** (NAV_DECIMALS - baseDecimals)`
    ///         when the base feed has fewer than `NAV_DECIMALS` decimals, else 1.
    /// @dev Applied to the BANDED rate rather than to the unbounded base answer, so the constructor can prove
    ///      `MAX_RATE * _rateScale` fits in a uint256 and the per-read multiplication can never overflow.
    uint256 private immutable _rateScale;

    /// @notice Divisor of the single `mulDiv` — `10 ** rateDecimals`, times `10 ** (baseDecimals - NAV_DECIMALS)`
    ///         when the base feed has more than `NAV_DECIMALS` decimals.
    uint256 private immutable _denominator;

    /// @notice Decimals of the returned price — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    /// @param underlyingAsset_ The asset being priced (X); must be ERC20-like.
    /// @param rateFeed_        Chainlink `X / B` oracle (B per X).
    /// @param rateHeartbeat_   Staleness threshold (seconds) for the rate oracle.
    /// @param baseUsdFeed_     Chainlink `B / USD` oracle (USD per B).
    /// @param baseHeartbeat_   Staleness threshold (seconds) for the base oracle.
    /// @param minRate_         Inclusive lower bound on the raw rate answer, in the rate feed's decimals.
    /// @param maxRate_         Inclusive upper bound on the raw rate answer, in the rate feed's decimals.
    constructor(
        address underlyingAsset_,
        address rateFeed_,
        uint256 rateHeartbeat_,
        address baseUsdFeed_,
        uint256 baseHeartbeat_,
        uint256 minRate_,
        uint256 maxRate_
    ) {
        if (minRate_ == 0 || maxRate_ <= minRate_) {
            revert InvalidArguments();
        }
        MIN_RATE = minRate_;
        MAX_RATE = maxRate_;
        UNDERLYING_ASSET = OracleArgumentChecks.assertERC20Address(underlyingAsset_);
        RATE_FEED = OracleArgumentChecks.assertChainlinkOracle(rateFeed_);
        RATE_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(rateHeartbeat_);
        BASE_USD_FEED = OracleArgumentChecks.assertChainlinkOracle(baseUsdFeed_);
        BASE_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(baseHeartbeat_);
        _rateDecimals = AggregatorV3Interface(rateFeed_).decimals();
        _baseDecimals = AggregatorV3Interface(baseUsdFeed_).decimals();
        _decimals = NAV_DECIMALS;

        // Checked arithmetic: a decimals value large enough to overflow these powers reverts HERE, at deploy,
        // never on the read path.
        uint256 rateUnit = 10 ** uint256(_rateDecimals);
        if (_baseDecimals >= NAV_DECIMALS) {
            _rateScale = 1;
            _denominator = rateUnit * 10 ** uint256(_baseDecimals - NAV_DECIMALS);
        } else {
            _rateScale = 10 ** uint256(NAV_DECIMALS - _baseDecimals);
            _denominator = rateUnit;
            // The banded rate is scaled up per read; prove here that the largest admissible rate cannot overflow.
            (bool ok,) = Math.tryMul(maxRate_, _rateScale);
            if (!ok) revert InvalidArguments();
        }
    }

    /// @notice Reads both legs and composes `rate * baseUsd / 10**rateDecimals` in `NAV_DECIMALS`. A leg past its
    ///         heartbeat still prices the asset, flagged stale (ADR 0029); a decimals mismatch, a non-positive
    ///         answer or an out-of-band rate return 0.
    /// @dev `roundId`, `startedAt` and `answeredInRound` are the RATE leg's (as {TwoFeedChainlinkPriceFeed});
    ///      `updatedAt` is the older of the two legs' timestamps on every path, including the structural ones.
    function _compute()
        private
        view
        returns (
            uint256 price,
            bool stale,
            uint80 roundId,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        int256 rate;
        uint256 rateUpdatedAt;
        (roundId, rate, startedAt, rateUpdatedAt, answeredInRound) = RATE_FEED.latestRoundData();
        (, int256 baseUsd,, uint256 baseUpdatedAt,) = BASE_USD_FEED.latestRoundData();

        // The OLDER leg ages the feed. Never block.timestamp: the NAV would then keep a dead feed usable forever.
        updatedAt = rateUpdatedAt <= baseUpdatedAt ? rateUpdatedAt : baseUpdatedAt;

        // Both cached decimals are re-asserted per read — see the contract docstring. `probeWord` rather than
        // `try/catch`, because `try/catch` does not catch a DECODE failure of a `success` reply.
        if (
            !_decimalsMatch(address(RATE_FEED), _rateDecimals) || !_decimalsMatch(address(BASE_USD_FEED), _baseDecimals)
        ) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        // A non-positive answer on either leg has no meaningful product, and `uint256(answer)` of a negative
        // value would be catastrophic rather than merely wrong. Gate both here.
        if (rate <= 0 || baseUsd <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        // The band: the runtime pin on the rate leg's pair. See MIN_RATE/MAX_RATE.
        uint256 raw = uint256(rate);
        if (raw < MIN_RATE || raw > MAX_RATE) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        // Guard against an upstream clock ahead of ours before measuring age (as {TwoFeedChainlinkPriceFeed}).
        uint256 effRate = rateUpdatedAt > block.timestamp ? block.timestamp : rateUpdatedAt;
        uint256 effBase = baseUpdatedAt > block.timestamp ? block.timestamp : baseUpdatedAt;
        stale = block.timestamp - effRate >= RATE_HEARTBEAT || block.timestamp - effBase >= BASE_HEARTBEAT;

        // X/USD = (B per X) * (USD per B), normalised to NAV_DECIMALS. One mulDiv, division LAST. `raw *
        // _rateScale` cannot overflow: raw <= MAX_RATE and the constructor proved MAX_RATE * _rateScale fits.
        price = (raw * _rateScale).mulDiv(uint256(baseUsd), _denominator, Math.Rounding.Floor);
    }

    /// @notice True iff `feed.decimals()` returns a full word equal to `pinned`.
    function _decimalsMatch(address feed, uint8 pinned) private view returns (bool) {
        (, bool hasWord, uint256 liveDecimals) =
            StaticCallLib.probeWord(feed, abi.encodeCall(AggregatorV3Interface.decimals, ()));
        return hasWord && liveDecimals == uint256(pinned);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return UNDERLYING_ASSET;
    }

    /// @inheritdoc ICustomPriceFeed
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc ICustomPriceFeed
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        bool stale;
        (price, stale, roundId, startedAt, updatedAt, answeredInRound) = _compute();
        answer = stale ? int256(0) : int256(price);
    }

    /// @inheritdoc ICustomPriceFeed
    /// @dev Two Chainlink legs, each with its own heartbeat. Report whichever has the larger `age/heartbeat`
    ///      ratio — the input closest to, or furthest past, its own staleness limit. An unreadable leg cannot
    ///      govern, so the other leg is reported; with both unreadable, `(0, RATE_HEARTBEAT)` — the interface's
    ///      documented "no push timestamp" value, which the read path does not mistake for a fresh timestamp.
    function governingFeedFreshness() external view override returns (uint256 updatedAt, uint256 heartbeat) {
        uint256 rateUpdatedAt;
        uint256 baseUpdatedAt;
        bool rateOk;
        bool baseOk;
        try RATE_FEED.latestRoundData() returns (uint80, int256, uint256, uint256 u, uint80) {
            (rateUpdatedAt, rateOk) = (u, true);
        } catch {}
        try BASE_USD_FEED.latestRoundData() returns (uint80, int256, uint256, uint256 u, uint80) {
            (baseUpdatedAt, baseOk) = (u, true);
        } catch {}
        if (!rateOk && !baseOk) return (0, RATE_HEARTBEAT);
        if (!rateOk) return (baseUpdatedAt, BASE_HEARTBEAT); // rate leg unreadable → report the base leg
        if (!baseOk) return (rateUpdatedAt, RATE_HEARTBEAT); // base leg unreadable → report the rate leg
        return _governingLeg(rateUpdatedAt, RATE_HEARTBEAT, baseUpdatedAt, BASE_HEARTBEAT);
    }

    /// @notice Returns the `(updatedAt, heartbeat)` of the leg with the greater `age/heartbeat` ratio (age measured
    ///         against `block.timestamp`; a future timestamp counts as age 0). A leg with a zero heartbeat is treated
    ///         as non-governing (the other leg wins). Compared via cross-multiplication to avoid division.
    /// @dev Copied from {TwoFeedChainlinkPriceFeed}. Both heartbeats here are constructor-pinned and non-zero, but
    ///      the overflow-safe compare is kept: a leg constructed with a `type(uint256).max` heartbeat (the
    ///      "disable the staleness gate" sentinel) would otherwise overflow the cross-product and revert a direct
    ///      caller. An overflow means that leg's ratio is ≈ 0, so the OTHER leg governs.
    function _governingLeg(uint256 tA, uint256 hA, uint256 tB, uint256 hB)
        private
        view
        returns (uint256 updatedAt, uint256 heartbeat)
    {
        if (hA == 0) return (tB, hB);
        if (hB == 0) return (tA, hA);
        uint256 nowTs = block.timestamp;
        uint256 ageA = tA >= nowTs ? 0 : nowTs - tA;
        uint256 ageB = tB >= nowTs ? 0 : nowTs - tB;
        // Governing = greater ratio: ageA/hA >= ageB/hB  <=>  ageA*hB >= ageB*hA  (hA, hB > 0).
        (bool okA, uint256 prodA) = Math.tryMul(ageA, hB);
        (bool okB, uint256 prodB) = Math.tryMul(ageB, hA);
        if (okA && okB) return prodA >= prodB ? (tA, hA) : (tB, hB);
        // Overflow: the leg whose heartbeat blew the product is effectively "never stale" (ratio ≈ 0) and loses.
        if (!okA) return (tA, hA); // hB astronomically large → leg B ratio ≈ 0 → leg A governs
        return (tB, hB); //          hA astronomically large → leg A ratio ≈ 0 → leg B governs
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
