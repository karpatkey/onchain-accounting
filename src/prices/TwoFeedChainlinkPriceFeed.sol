// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TwoFeedChainlinkPriceFeed
/// @author KPK
/// @notice Shared skeleton for "asset/USD via a Chainlink rate feed × the NAV's base/USD" custom price feeds: an asset
///         whose USD price is derived from a `RATE_FEED` (asset priced in some base unit, e.g. cbETH/ETH, weETH/eETH,
///         syrupUSDC/USDC, or the generic Y/X) composed with the **NAV's own base/USD price** for that base unit
///         (`getPriceData(BASE_ASSET)` — e.g. ETH/USD, USDC/USD). Used when no direct asset/USD feed exists. Concrete
///         feeds (cbETH_L2, rsETH_L2, weETH, weETH_L2, LDO, syrupUSDC_L2, wstETH_L2, and the generic CrossRate) supply
///         only the rate feed + its heartbeat plus the NAV and base asset, and keep their own named contract.
/// @dev Price is `rate · base8 / 10**rateDecimals` (Math.Rounding.Floor) — i.e. `(asset/base) · (base/USD)`, with the
///      rate feed's decimals cancelled out — returned in `NAV_DECIMALS` (8). The rate feed is read each call and the
///      base/USD term is read from the NAV. The result is `(0, true)` when the rate answer is non-positive or the NAV
///      has no usable base price. It keeps its computed price, flagged stale (ADR 0029), when the rate feed is past its
///      own heartbeat or the NAV reports the base feed stale (no base feed fresh; L2 sequencer-down alone does not —
///      it surfaces via the NAV's top-level `sequencerDown` flag). Rate-leg freshness uses
///      `effectiveUpdatedAt = min(updatedAt, block.timestamp)` to avoid upstream-clock bias; the returned `updatedAt`
///      is the more conservative `min(rateLegUpdatedAt, baseUpdatedAt)`. Sourcing base/USD from the NAV (rather than a
///      hardcoded Chainlink oracle) makes the base term identical to the one the NAV prices the base asset's own legs
///      with — so it cancels cleanly when NAV is quoted in the base (see {NavBaseUsdLib}, incl. the circularity
///      invariant). The 5 `ICustomPriceFeed` thunks, the immutables, and constructor validation live here once instead
///      of being copy-pasted into each two-feed feed. Feeds with a single 18-decimal rate over a NAV base use
///      {BaseCustomPriceFeed}; ERC-4626 vault-rate feeds use {ERC4626VaultRatePriceFeed}.
abstract contract TwoFeedChainlinkPriceFeed is ICustomPriceFeed, INavSourcedPriceFeed {
    using Math for uint256;

    /// @notice The asset whose USD price is returned.
    address public immutable UNDERLYING_ASSET;

    /// @notice Chainlink oracle quoting the asset in its base unit (e.g. cbETH/ETH, Y/X). Its decimals scale the product.
    AggregatorV3Interface public immutable RATE_FEED;

    /// @notice NAVCalculator (proxy) the base/USD price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset whose USD price is read from the NAV (e.g. WETH). Must be priced by DIRECT feeds on the
    ///         NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} circularity invariant).
    address public immutable override BASE_ASSET;

    /// @notice Heartbeat (seconds) after which the rate feed is considered stale.
    uint256 public immutable RATE_HEARTBEAT;

    /// @notice `10 ** RATE_FEED.decimals()`, captured once — the rate feed's decimals are immutable, so this avoids
    ///         an external STATICCALL to `decimals()` on every price read.
    uint256 private immutable _rateUnit;

    /// @notice Decimals of the returned price — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    /// @param underlyingAsset_ The asset being priced (must be ERC20-like).
    /// @param rateFeed_        Chainlink asset/base feed (e.g. cbETH/ETH).
    /// @param rateHeartbeat_   Staleness threshold (seconds) for the rate feed.
    /// @param nav_             The NAVCalculator proxy to read base/USD from.
    /// @param baseAsset_       The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address underlyingAsset_, address rateFeed_, uint256 rateHeartbeat_, address nav_, address baseAsset_) {
        UNDERLYING_ASSET = OracleArgumentChecks.assertERC20Address(underlyingAsset_);
        RATE_FEED = OracleArgumentChecks.assertChainlinkOracle(rateFeed_);
        RATE_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(rateHeartbeat_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        _decimals = NAV_DECIMALS;
        _rateUnit = 10 ** uint256(AggregatorV3Interface(rateFeed_).decimals());
    }

    /// @notice Reads the rate feed + the NAV base/USD and composes `rate · base8 / 10**rateDecimals`. A stale base or
    ///         a rate leg past `RATE_HEARTBEAT` still prices the asset, flagged stale (ADR 0029); only a missing base
    ///         price or a non-positive rate returns 0.
    function _compute()
        internal
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

        // Base/USD from the NAV's selector (normalized to NAV_DECIMALS = 8); it marks the base stale on
        // no-base-feed-fresh only (L2 sequencer-down alone does NOT — NavBaseUsdLib un-folds pd.sequencerDown; ADR 0019).
        (uint256 base8, bool baseStale, uint256 baseUpdatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);

        // Report the more conservative (older) updatedAt across the rate leg and the NAV base read.
        updatedAt = rateUpdatedAt <= baseUpdatedAt ? rateUpdatedAt : baseUpdatedAt;

        if (base8 == 0 || rate <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        uint256 effRate = rateUpdatedAt > block.timestamp ? block.timestamp : rateUpdatedAt;
        stale = baseStale || block.timestamp - effRate >= RATE_HEARTBEAT;

        // asset/USD = (asset/base) * (base/USD) / 10^rateDecimals
        price = uint256(rate).mulDiv(base8, _rateUnit, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view virtual override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view virtual override returns (address) {
        return UNDERLYING_ASSET;
    }

    /// @inheritdoc ICustomPriceFeed
    function decimals() external view virtual override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc ICustomPriceFeed
    function latestRoundData()
        external
        view
        virtual
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        bool stale;
        (price, stale, roundId, startedAt, updatedAt, answeredInRound) = _compute();
        answer = stale ? int256(0) : int256(price);
    }

    /// @inheritdoc ICustomPriceFeed
    /// @dev Two Chainlink legs: the rate feed (`RATE_HEARTBEAT`) and the NAV's base/USD leg (its own configured
    ///      heartbeat). Report whichever has the larger `age/heartbeat` ratio — the input closest to its own
    ///      staleness limit. If the rate feed is unreadable, fall back to the base leg.
    function governingFeedFreshness() external view virtual override returns (uint256 updatedAt, uint256 heartbeat) {
        (uint256 baseUpdatedAt, uint256 baseHeartbeat) = NavBaseUsdLib.baseFreshness(NAV, BASE_ASSET);
        uint256 rateUpdatedAt;
        try RATE_FEED.latestRoundData() returns (uint80, int256, uint256, uint256 u, uint80) {
            rateUpdatedAt = u;
        } catch {
            return (baseUpdatedAt, baseHeartbeat); // rate leg unreadable → report the base leg
        }
        return _governingLeg(rateUpdatedAt, RATE_HEARTBEAT, baseUpdatedAt, baseHeartbeat);
    }

    /// @notice Returns the `(updatedAt, heartbeat)` of the leg with the greater `age/heartbeat` ratio (age measured
    ///         against `block.timestamp`; a future timestamp counts as age 0). A leg with a zero heartbeat is treated
    ///         as non-governing (the other leg wins). Compared via cross-multiplication to avoid division.
    /// @dev Overflow-safe: a base leg may be registered with a `type(uint256).max` heartbeat (the documented
    ///      "disable the staleness gate" sentinel, see PRICE_ADAPTERS.md). The ratio compare cross-multiplies
    ///      (`ageA*hB` vs `ageB*hA`), so a cross-product can exceed uint256. `Math.tryMul` detects that; an overflow
    ///      means that leg's heartbeat is astronomically large, so its `age/heartbeat` ratio is ≈ 0 and the OTHER leg
    ///      governs (`!okA` ⇒ `hB` huge ⇒ leg A wins; `!okB` ⇒ `hA` huge ⇒ leg B wins). Without this a direct caller of
    ///      `governingFeedFreshness()` would revert (the `buildPriceData` path already swallows reverts, but callers
    ///      reading the feed straight should not).
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
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
