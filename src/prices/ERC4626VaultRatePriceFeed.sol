// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ERC4626VaultRatePriceFeed
/// @author KPK
/// @notice Shared skeleton for the "ERC-4626 vault share × NAV base/USD" custom price feeds — a vault share token
///         whose USD price is the vault's live exchange rate (`convertToAssets`) times the **NAV's own base/USD price**
///         for the vault's underlying asset (`getPriceData(BASE_ASSET)`, e.g. USDe/USD, GHO/USD). Concrete feeds
///         (sUSDe, sUSDS, sXDAI, syrupUSDC, RWIV, sGHO) supply only the three constructor arguments (vault, NAV,
///         base asset); all of them keep their own named contract.
/// @dev The price is `base8 · convertToAssets(10**shareDecimals) / 10**assetDecimals` (Math.Rounding.Floor),
///      i.e. `(asset/USD) · (assets per share)`, returned in `NAV_DECIMALS` (8). `convertToAssets(10**shareDecimals)`
///      returns the assets for one whole share denominated in the **underlying asset's** decimals, so the divisor is
///      `10**assetDecimals` (NOT `10**shareDecimals` — those differ when the vault uses a decimals offset, e.g.
///      18-decimal shares over 6-decimal USDC); the asset decimals then cancel to leave the base/USD decimals. Stale, keeping the computed price, when the NAV
///      reports the base feed stale (no base feed fresh; NOT L2 sequencer-down alone; ADR 0029). Sourcing base/USD from the NAV (rather than a hardcoded Chainlink
///      oracle) makes the base term identical to the one the NAV prices the base asset's own legs with — so it
///      cancels cleanly when NAV is quoted in the base (see {NavBaseUsdLib}, incl. the circularity invariant). The
///      5 `ICustomPriceFeed` thunks, the immutables, and the constructor validation live here once instead of being
///      copy-pasted into each vault feed. Feeds whose rate is a non-ERC4626 source (e.g. a DSR-`chi`-style accumulator) stay
///      bespoke; feeds with an 18-decimal rate against a NAV base use {BaseCustomPriceFeed} instead.
abstract contract ERC4626VaultRatePriceFeed is ICustomPriceFeed, INavSourcedPriceFeed {
    using Math for uint256;

    /// @notice Thrown when the configured `baseAsset_` is not the vault's own `asset()` underlying — the base/USD
    ///         price is read for `baseAsset_`, so a mismatch would price shares against the wrong asset's USD value.
    error BaseAssetMismatch(address vaultAsset, address baseAsset);

    /// @notice The ERC-4626 vault share token this feed prices (returned by `underlyingAssetSupported`).
    address public immutable VAULT;

    /// @notice NAVCalculator (proxy) the base/USD price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset (the vault's underlying) whose USD price is read from the NAV (e.g. USDe, GHO). Must be
    ///         priced by DIRECT feeds on the NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} invariant).
    address public immutable override BASE_ASSET;

    /// @notice Decimals of the returned price — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    /// @notice `10 ** shareDecimals` — one whole share, the amount passed to `convertToAssets`.
    uint256 private immutable _shareUnit;

    /// @notice `10 ** assetDecimals` — the underlying-asset scaling unit `convertToAssets` output is denominated in.
    ///         The correct divisor; equals `_shareUnit` only when the vault has no decimals offset.
    uint256 private immutable _assetUnit;

    /// @param vault_     The ERC-4626 vault share token (must be ERC20-like).
    /// @param nav_       The NAVCalculator proxy to read base/USD from.
    /// @param baseAsset_ The base asset (the vault's underlying, e.g. USDe) whose NAV-selected USD price scales the rate.
    constructor(address vault_, address nav_, address baseAsset_) {
        VAULT = OracleArgumentChecks.assertERC20Address(vault_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        // The base/USD price is read for BASE_ASSET, so it MUST be the vault's own underlying — otherwise shares
        // would be priced against the wrong asset's USD value (e.g. a USDC vault priced with ETH/USD).
        address underlying = IERC4626(vault_).asset();
        if (baseAsset_ != underlying) revert BaseAssetMismatch(underlying, baseAsset_);
        _decimals = NAV_DECIMALS;
        _shareUnit = 10 ** uint256(IERC4626(vault_).decimals());
        _assetUnit = 10 ** uint256(IERC20Metadata(underlying).decimals());
    }

    /// @notice Reads the NAV base/USD and scales it by the vault's live per-share rate. A stale base still prices the
    ///         share, flagged stale (ADR 0029); only a missing base price or a zero share rate returns 0.
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
        // Base/USD from the NAV's selector (normalized to NAV_DECIMALS = 8); it marks the base stale on
        // no-base-feed-fresh only (L2 sequencer-down alone does NOT — NavBaseUsdLib un-folds pd.sequencerDown; ADR 0019). roundId/startedAt/answeredInRound have no meaning for a NAV read.
        uint256 base8;
        (base8, stale, updatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);
        if (base8 == 0) return (0, true, 0, 0, updatedAt, 0);
        // convertToAssets(1 whole share) is denominated in the underlying asset's decimals, so divide by _assetUnit
        // (10**assetDecimals), not _shareUnit — the two differ when the vault uses a decimals offset.
        uint256 assetsPerShare = IERC4626(VAULT).convertToAssets(_shareUnit);
        if (assetsPerShare == 0) return (0, true, 0, 0, updatedAt, 0);
        price = assetsPerShare.mulDiv(base8, _assetUnit, Math.Rounding.Floor);
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

    /// @inheritdoc ICustomPriceFeed
    /// @dev One Chainlink leg — the NAV's base/USD feed (the ERC-4626 share rate is an on-chain value, not an
    ///      oracle). So the governing leg is always the base leg.
    function governingFeedFreshness() external view virtual override returns (uint256 updatedAt, uint256 heartbeat) {
        return NavBaseUsdLib.baseFreshness(NAV, BASE_ASSET);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
