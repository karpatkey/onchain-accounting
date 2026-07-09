// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BaseCustomPriceFeed
/// @author KPK
/// @notice Shared skeleton for the "exchange-rate × base/USD" custom price feeds: it reads the base asset's USD price
///         from the **NAV** (`getPriceData(BASE_ASSET)` — the NAV's own selector, typically ETH/USD), applies the
///         staleness gate, multiplies by a protocol-supplied 18-decimal exchange rate, and returns the result in
///         `NAV_DECIMALS` (8). Concrete feeds implement only `_rate()` — the protocol's exchange rate as 18-decimal
///         base-token units per 1 `UNDERLYING` (e.g. ETH per rETH), the orientation the multiply expects.
/// @dev Sourcing base/USD from the NAV (rather than a hardcoded Chainlink oracle) makes the base term identical to the
///      one the NAV prices the base asset's own legs with — so it cancels cleanly when NAV is quoted in the base.
///      See {NavBaseUsdLib} (incl. the circularity invariant) and `docs/decisions`. Math: `price = rate · base8 / 1e18`
///      (Floor); stale when the NAV reports the base stale (all-feeds-stale/sequencer-down) or `_rate()` is 0.
abstract contract BaseCustomPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice The token this feed prices (returned by `underlyingAssetSupported`).
    address public immutable UNDERLYING;

    /// @notice NAVCalculator (proxy) the base/USD price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset whose USD price is read from the NAV (e.g. WETH). Must be priced by DIRECT feeds on the
    ///         NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} circularity invariant).
    address public immutable BASE_ASSET;

    /// @notice Decimals of the returned price — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    /// @param underlying_ The token being priced (must be ERC20-like).
    /// @param nav_        The NAVCalculator proxy to read base/USD from.
    /// @param baseAsset_  The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address underlying_, address nav_, address baseAsset_) {
        UNDERLYING = OracleArgumentChecks.assertERC20Address(underlying_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        _decimals = NAV_DECIMALS;
    }

    /// @notice The protocol's exchange rate, expressed as 18-decimal base-token units per 1 `UNDERLYING`
    ///         (e.g. ETH per rETH). Return 0 to mark the price stale/unavailable.
    /// @dev The only hook a concrete feed must implement.
    function _rate() internal view virtual returns (uint256);

    /// @notice Reads the base feed + rate, applies staleness, and combines them. Mirrors the former per-feed
    ///         `_compute()`. Exposed to subclasses that need a different `latestRoundData` shape.
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
        // Base/USD from the NAV's selector (normalized to NAV_DECIMALS = 8); its staleness folds in
        // all-base-feeds-stale + sequencer-down. roundId/startedAt/answeredInRound have no meaning for a NAV read.
        uint256 base8;
        (base8, stale, updatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);
        if (stale) return (0, true, 0, 0, updatedAt, 0);
        uint256 rate = _rate();
        if (rate == 0) return (0, true, 0, 0, updatedAt, 0);
        // rate is 18 decimals, base8 is 8 decimals → result in NAV_DECIMALS (8).
        price = rate.mulDiv(base8, 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view virtual override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view virtual override returns (address) {
        return UNDERLYING;
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
