// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ERC4626VaultRatePriceFeed
/// @author KPK
/// @notice Shared skeleton for the "ERC-4626 vault share × Chainlink asset/USD" custom price feeds — a vault share
///         token whose USD price is the vault's live exchange rate (`convertToAssets`) times a Chainlink quote for
///         the vault's underlying asset. Concrete feeds (sUSDe, sUSDS, sXDAI, syrupUSDC, RWIV, sGHO) supply only the
///         three constructor arguments (vault, asset/USD oracle, heartbeat); all of them keep their own named contract.
/// @dev The price is `assetUsd · convertToAssets(10**vaultDecimals) / 10**vaultDecimals` (Math.Rounding.Floor),
///      i.e. `(asset/USD) · (assets per share)`, returned in the asset/USD feed's own decimals. `convertToAssets`
///      is linear in shares, so dividing by the same `10**vaultDecimals` passed in yields the per-share rate at the
///      asset's decimals; the feed/rate decimals then cancel to leave the feed's decimals. Staleness mirrors the
///      former per-feed `_compute`: stale when the Chainlink answer is non-positive or the feed is past its
///      heartbeat, using `effectiveUpdatedAt = min(updatedAt, block.timestamp)` to avoid upstream-clock bias. The
///      5 `ICustomPriceFeed` thunks, the immutables, and the constructor validation live here once instead of being
///      copy-pasted into each vault feed. Feeds whose rate is a non-ERC4626 source (e.g. sDAI's DSR `chi`) stay
///      bespoke; feeds with an 18-decimal rate against an ETH base use {BaseCustomPriceFeed} instead.
abstract contract ERC4626VaultRatePriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice The ERC-4626 vault share token this feed prices (returned by `underlyingAssetSupported`).
    address public immutable VAULT;

    /// @notice Chainlink oracle for the vault's underlying asset vs USD (e.g. USDe/USD, GHO/USD).
    AggregatorV3Interface public immutable ASSET_USD_ORACLE;

    /// @notice Heartbeat (seconds) after which the asset/USD feed is considered stale.
    uint256 public immutable ASSET_USD_HEARTBEAT;

    /// @notice Decimals of the returned price (inherited from the asset/USD Chainlink feed).
    uint8 private immutable _decimals;

    /// @notice Decimals of the vault share token (used for the `convertToAssets` scaling unit).
    uint8 private immutable _vaultDecimals;

    /// @param vault_         The ERC-4626 vault share token (must be ERC20-like).
    /// @param assetUsdOracle_ The Chainlink asset/USD oracle for the vault's underlying.
    /// @param heartbeat_     Staleness threshold (seconds) for the asset/USD feed.
    constructor(address vault_, address assetUsdOracle_, uint256 heartbeat_) {
        VAULT = OracleArgumentChecks.assertERC20Address(vault_);
        ASSET_USD_ORACLE = OracleArgumentChecks.assertChainlinkOracle(assetUsdOracle_);
        ASSET_USD_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(heartbeat_);
        _decimals = ASSET_USD_ORACLE.decimals();
        _vaultDecimals = IERC4626(vault_).decimals();
    }

    /// @notice Reads the asset/USD feed, applies staleness, and scales it by the vault's live per-share rate.
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
        int256 assetUsd;
        (roundId, assetUsd, startedAt, updatedAt, answeredInRound) = ASSET_USD_ORACLE.latestRoundData();
        if (assetUsd <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= ASSET_USD_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 unit = 10 ** uint256(_vaultDecimals);
        uint256 assetsPerShare = IERC4626(VAULT).convertToAssets(unit);
        price = assetsPerShare.mulDiv(uint256(assetUsd), unit, Math.Rounding.Floor);
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
