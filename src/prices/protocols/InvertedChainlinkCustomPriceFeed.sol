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

/// @title Inverted Chainlink Price Adapter
/// @author KPK
/// @notice Computes `X/USD` from a Chainlink **`USD / X`** feed by INVERTING it: `price = 1 / (X per USD)`.
///         Use for any asset whose only Chainlink coverage is quoted the wrong way round — the feed answers
///         "how many X per one USD", while every primary feed this repo registers must answer "USD per one
///         asset".
/// @dev **Why this shape exists.** A `USD / X` feed is the RECIPROCAL of what {Prices} expects. The ARS
///      feed KPK uses, `0xBb65fa58BDb7d33e4a3D1A40a7A9BD99E746367b`, has `description() == "USD / ARS"` and
///      answers ~`158309760000` at 8 decimals — **1583.09 ARS per USD**. Registering it directly as a
///      `type: "Chainlink"` primary would value 1 wARS at ~$1,583 instead of ~$0.00063: an over-report of
///      ~2.5 MILLION x (1583^2). **Nothing in the config schema encodes feed direction and no preflight
///      guard checks it**, so the inversion has to live in a contract — this one.
/// @dev **CORRECTION — it is NOT the only ARS feed on mainnet.** An earlier revision of this docstring, and
///      of the commit message, asserted that. It is false, and was caught in review. A DIRECT
///      `ARS / USD` feed exists at `0xE41cD2DcC63EB63A9D9e62f2a3D9b49e6d0C0A1d` (8 decimals, answer
///      `67207` = $0.00067207, verified on-chain 2026-08-15) and could be registered as a plain
///      `type: "Chainlink"` primary with no custom contract at all. The two references **disagree by
///      ~6.4%** ($0.00063167 inverted vs $0.00067207 direct) — persistently, not as a staleness artifact.
///      `USD / ARS` is used deliberately because it is the reference the vault itself accounts in, and it
///      is the CONSERVATIVE of the two, so this is not an over-report. The direct feed is nevertheless
///      available as an independent divergence MONITOR, which wARS does not currently have.
/// @dev Price is `10**NAV_DECIMALS * 10**feedDecimals / answer` (Math.Rounding.Floor), returned in
///      `NAV_DECIMALS` (8). Worked example at the measured ARS answer:
///      `1e8 * 1e8 / 158309760000 = 63167` = $0.00063167 per wARS.
/// @dev **The division is kept LAST**, exactly as {ankrETH_CustomPriceFeed} does — the feed answer is a
///      DENOMINATOR here. Pre-inverting into an 18-decimal rate so this could reuse {BaseCustomPriceFeed} or
///      {TwoFeedChainlinkPriceFeed} would floor an intermediate and shift the result; both of those
///      skeletons assume the rate MULTIPLIES. So this feed implements {ICustomPriceFeed} directly.
/// @dev **No NAV dependency: `BASE_ASSET == address(0)`.** A `USD / X` pair is already USD-denominated, so
///      there is no base/USD leg to compose and no NAV read — hence no {NavBaseUsdLib} circularity invariant
///      applies and `preflight_config.py`'s base allowlist does not govern feeds of this shape. It still
///      IMPLEMENTS {INavSourcedPriceFeed} and answers `address(0)`, exactly as {ETHPlus_CustomPriceFeed}
///      does: registration probes `BASE_ASSET()` by raw staticcall and **fails closed**
///      (`IPrices.CustomFeedBaseUnreadable`, `PriceFeedLib._validateFeedNotCircular`) on a feed that cannot
///      answer. Omitting the function does NOT mean "no dependency" — it means UNREGISTERABLE.
/// @dev **THE CACHED `_feedUnit` IS RE-ASSERTED ON EVERY READ, and that is not belt-and-braces.** In
///      {TwoFeedChainlinkPriceFeed} and {ERC4626VaultRatePriceFeed} the cached unit DIVIDES a multiplied
///      rate, so an aggregator migrating to fewer decimals makes those feeds UNDER-report — the safe
///      direction. Here the unit is a NUMERATOR over the answer, so the identical change OVER-reports by
///      `10**(oldDecimals - newDecimals)`: measured at 100x for an 8 -> 6 migration publishing the same
///      real rate, with `stale == false` and a fresh timestamp. This is the first cached-unit feed in the
///      repo whose error direction points upward, and the contract is immutable, so the mismatch is
///      checked per read and reported STALE instead. The check uses {StaticCallLib-probeWord} rather than
///      `try/catch`, because `try/catch` catches a REVERT but not a DECODE failure — an aggregator
///      answering `success` with a short or dirty word would otherwise revert this frame, which is the
///      failure mode {ICustomPriceFeed} forbids. `probeWord` is total over any returndata.
/// @dev **PRECISION — read before adopting this for a new asset.** The result is floored at
///      `NAV_DECIMALS` (8), so an asset worth far less than $1 keeps only the significant digits that
///      survive: at 1583 ARS/USD a wARS is `63167` units, i.e. ~1.6e-5 relative resolution (fine), but an
///      asset at >1e6 per USD would floor to a handful of units and one worth >1e8 per USD would floor to
///      **zero**. Check the magnitude before registering an asset against this feed.
/// @dev **MODELLING ASSUMPTION.** Chainlink `USD / X` quotes the CURRENCY/reference X, not any particular
///      token that claims parity with it, so a token's depeg from X is invisible here. That is the same
///      treatment USDC gets from a USD feed, but unlike EURC — whose `EURC / USD` feed prices the TOKEN.
///      A non-USD fiat-backed asset registered against this feed must also carry **no `pegToleranceBps`**
///      (its USD price legitimately moves with X/USD, so a $1 peg guard would fire permanently — see the
///      EURC entry's `$kindComment`).
contract InvertedChainlinkCustomPriceFeed is ICustomPriceFeed, INavSourcedPriceFeed {
    using Math for uint256;

    /// @notice This feed reads NO base price out of the NAV — a `USD / X` pair is already USD-denominated.
    /// @dev Constant, not immutable: the answer can never vary by deployment for this shape.
    address public constant override BASE_ASSET = address(0);

    /// @notice The asset whose USD price is returned (X).
    address public immutable UNDERLYING_ASSET;

    /// @notice Chainlink `USD / X` oracle — reads as **X per USD**. Its answer is the price's DENOMINATOR.
    AggregatorV3Interface public immutable USD_TO_ASSET_FEED;

    /// @notice Heartbeat (seconds) after which `USD_TO_ASSET_FEED` is considered stale.
    uint256 public immutable FEED_HEARTBEAT;

    /// @notice `10 ** USD_TO_ASSET_FEED.decimals()`, captured once — a feed's decimals are immutable, so this
    ///         avoids recomputing the power on every price read.
    uint256 private immutable _feedUnit;

    /// @notice The decimals value itself, captured at construction. Compared against the live value per read.
    /// @dev Stored SEPARATELY from `_feedUnit` on purpose: comparing `liveDecimals` to this is a `uint8`
    ///      equality, whereas recomputing `10 ** liveDecimals` to compare units REVERTS for any
    ///      `liveDecimals >= 78` (10**78 exceeds uint256). A revert inside a `try` BODY is not caught by that
    ///      statement's own `catch`, so that form would turn a hostile or broken `decimals()` into a whole-feed
    ///      revert — exactly the failure mode {ICustomPriceFeed} forbids, since a Custom feed must report
    ///      `stale` rather than revert.
    uint8 private immutable _feedDecimals;

    /// @notice `10 ** NAV_DECIMALS`, the numerator that puts the inverted price in NAV decimals.
    uint256 private immutable _navUnit;

    /// @notice Decimals of the returned price — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    /// @notice Inclusive lower/upper bound on the RAW oracle answer, in the feed's own decimals.
    /// @dev **The direction pin, moved to READ time.** `RateFeedGuard` pins `description()` and a
    ///      plausibility band, but it is explicitly deploy-only (see {RateFeedGuard.checkAll}: "Call this
    ///      BEFORE deploying") — it cannot see a Chainlink proxy that later migrates its aggregator
    ///      at the SAME address with the SAME decimals. If such a migration re-quoted this feed as
    ///      `X / USD` instead of `USD / X`, the decimals check above would pass and the inversion would
    ///      report ~$1,583 instead of ~$0.00063 with `stale == false` — the exact 2.5-million-x
    ///      over-report this contract exists to prevent, on an IMMUTABLE contract, with nothing else to
    ///      catch it (wARS deliberately carries no `monitorFeeds` and no `pegToleranceBps`).
    ///      An inverted answer lands orders of magnitude outside the band, so the band catches the
    ///      re-quote that `decimals()` cannot — the same argument `RateFeedGuard` makes for having a band
    ///      at all, applied where an immutable contract can still act on it.
    uint256 public immutable MIN_ANSWER;
    uint256 public immutable MAX_ANSWER;

    /// @param underlyingAsset_   The asset being priced (X); must be ERC20-like.
    /// @param usdToAssetFeed_    Chainlink `USD / X` oracle (X per USD).
    /// @param feedHeartbeat_     Staleness threshold (seconds) for that oracle.
    /// @param minAnswer_         Inclusive lower bound on the raw answer, in the feed's decimals.
    /// @param maxAnswer_         Inclusive upper bound on the raw answer, in the feed's decimals.
    constructor(
        address underlyingAsset_,
        address usdToAssetFeed_,
        uint256 feedHeartbeat_,
        uint256 minAnswer_,
        uint256 maxAnswer_
    ) {
        if (minAnswer_ == 0 || maxAnswer_ <= minAnswer_) {
            revert InvalidArguments();
        }
        MIN_ANSWER = minAnswer_;
        MAX_ANSWER = maxAnswer_;
        UNDERLYING_ASSET = OracleArgumentChecks.assertERC20Address(underlyingAsset_);
        USD_TO_ASSET_FEED = OracleArgumentChecks.assertChainlinkOracle(usdToAssetFeed_);
        FEED_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(feedHeartbeat_);
        _feedDecimals = AggregatorV3Interface(usdToAssetFeed_).decimals();
        _feedUnit = 10 ** uint256(_feedDecimals);
        _navUnit = 10 ** uint256(NAV_DECIMALS);
        _decimals = NAV_DECIMALS;
    }

    /// @notice Reads the `USD / X` leg, applies staleness, and inverts it into X/USD.
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
        int256 answer;
        (roundId, answer, startedAt, updatedAt, answeredInRound) = USD_TO_ASSET_FEED.latestRoundData();

        // The cached `_feedUnit` is a NUMERATOR here, so a decimals() change flips the error UPWARD —
        // unlike every sibling feed, where the cached unit divides a multiplied rate and the same change
        // under-reports. Re-assert it per read: a mismatch (or an unreadable decimals()) is reported STALE
        // rather than silently rescaled. See the contract docstring for the measured 100x case.
        // `try/catch` is NOT sufficient here: it catches a revert from the call, but NOT a failure to
        // DECODE the reply, so an aggregator answering `success` with a dirty or short word would revert
        // this frame instead of reporting stale. `probeWord` is total over any returndata — no decode
        // step — so an unreadable, short, or out-of-range `decimals()` all land on the stale path.
        (, bool hasWord, uint256 liveDecimals) =
            StaticCallLib.probeWord(address(USD_TO_ASSET_FEED), abi.encodeCall(AggregatorV3Interface.decimals, ()));
        if (!hasWord || liveDecimals != uint256(_feedDecimals)) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        // A non-positive answer makes the inversion undefined — and a zero denominator would REVERT inside
        // mulDiv, which on the read path is a worse failure than reporting staleness. Gate it here.
        if (answer <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        // The band. See MIN_ANSWER/MAX_ANSWER: this is what survives an aggregator migration that
        // `decimals()` cannot detect, and it is the only runtime defence this asset has.
        uint256 raw = uint256(answer);
        if (raw < MIN_ANSWER || raw > MAX_ANSWER) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        // Guard against an upstream clock ahead of ours before measuring age (as {TwoFeedChainlinkPriceFeed}).
        uint256 eff = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - eff >= FEED_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        // X/USD = 1 / (X per USD), in NAV_DECIMALS. Division LAST — the answer is the denominator.
        price = _navUnit.mulDiv(_feedUnit, uint256(answer), Math.Rounding.Floor);
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
    /// @dev A single Chainlink leg, so it governs unconditionally. A `0` updatedAt on an unreadable leg is
    ///      the interface's documented "no push timestamp" value and the read path substitutes its own
    ///      sentinel, so it must not be confused with a fresh timestamp.
    function governingFeedFreshness() external view override returns (uint256 updatedAt, uint256 heartbeat) {
        try USD_TO_ASSET_FEED.latestRoundData() returns (uint80, int256, uint256, uint256 u, uint80) {
            return (u, FEED_HEARTBEAT);
        } catch {
            return (0, FEED_HEARTBEAT);
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
