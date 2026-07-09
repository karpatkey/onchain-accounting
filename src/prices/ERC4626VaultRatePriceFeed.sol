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
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ERC4626VaultRatePriceFeed
/// @author KPK
/// @notice Shared skeleton for the "ERC-4626 vault share × NAV base/USD" custom price feeds — a vault share token
///         whose USD price is the vault's live exchange rate (`convertToAssets`) times the **NAV's own base/USD price**
///         for the vault's underlying asset (`getPriceData(BASE_ASSET)`, e.g. USDe/USD, GHO/USD). Concrete feeds
///         (sUSDe, sUSDS, sXDAI, syrupUSDC, RWIV, sGHO) supply only the three constructor arguments (vault, NAV,
///         base asset); all of them keep their own named contract.
/// @dev The price is `base8 · convertToAssets(10**vaultDecimals) / 10**vaultDecimals` (Math.Rounding.Floor),
///      i.e. `(asset/USD) · (assets per share)`, returned in `NAV_DECIMALS` (8). `convertToAssets` is linear in
///      shares, so dividing by the same `10**vaultDecimals` passed in yields the per-share rate at the asset's
///      decimals; the rate decimals then cancel to leave the base/USD decimals. Stale when the NAV reports the base
///      stale (all-feeds-stale/sequencer-down). Sourcing base/USD from the NAV (rather than a hardcoded Chainlink
///      oracle) makes the base term identical to the one the NAV prices the base asset's own legs with — so it
///      cancels cleanly when NAV is quoted in the base (see {NavBaseUsdLib}, incl. the circularity invariant). The
///      5 `ICustomPriceFeed` thunks, the immutables, and the constructor validation live here once instead of being
///      copy-pasted into each vault feed. Feeds whose rate is a non-ERC4626 source (e.g. sDAI's DSR `chi`) stay
///      bespoke; feeds with an 18-decimal rate against a NAV base use {BaseCustomPriceFeed} instead.
abstract contract ERC4626VaultRatePriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice The ERC-4626 vault share token this feed prices (returned by `underlyingAssetSupported`).
    address public immutable VAULT;

    /// @notice NAVCalculator (proxy) the base/USD price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset (the vault's underlying) whose USD price is read from the NAV (e.g. USDe, GHO). Must be
    ///         priced by DIRECT feeds on the NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} invariant).
    address public immutable BASE_ASSET;

    /// @notice Decimals of the returned price — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    /// @notice Decimals of the vault share token (used for the `convertToAssets` scaling unit).
    uint8 private immutable _vaultDecimals;

    /// @param vault_     The ERC-4626 vault share token (must be ERC20-like).
    /// @param nav_       The NAVCalculator proxy to read base/USD from.
    /// @param baseAsset_ The base asset (the vault's underlying, e.g. USDe) whose NAV-selected USD price scales the rate.
    constructor(address vault_, address nav_, address baseAsset_) {
        VAULT = OracleArgumentChecks.assertERC20Address(vault_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        _decimals = NAV_DECIMALS;
        _vaultDecimals = IERC4626(vault_).decimals();
    }

    /// @notice Reads the NAV base/USD, applies staleness, and scales it by the vault's live per-share rate.
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
        uint256 unit = 10 ** uint256(_vaultDecimals);
        uint256 assetsPerShare = IERC4626(VAULT).convertToAssets(unit);
        price = assetsPerShare.mulDiv(base8, unit, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view virtual override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view virtual override returns (address) {
        return VAULT;
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
