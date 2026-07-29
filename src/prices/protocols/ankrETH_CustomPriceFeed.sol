// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ankrETH Custom Price Oracle
/// @notice Returns the USD price of ankrETH by combining ankrETH's ratio with the NAV's ETH/USD price.
/// @dev ankrETH is a reward-bearing token whose ETH value grows over time. The `ratio()` returns the amount
///      of ankrETH per 1 ETH (18 decimals, decreasing over time), so ETH per ankrETH = 1e18 / ratio.
///      The price is computed as `price = (ETH/USD) * 1e18 / ratio`, where:
///      - `ratio` comes from the ankrETH contract's `ratio()` function (18 decimals, ankrETH-per-ETH)
///      - `ETH/USD` (base/USD) comes from the NAV's own selector (`getPriceData(BASE_ASSET)`, 8 decimals)
///      Result is scaled to `NAV_DECIMALS` (8): `price = ETH/USD * 1e18 / ratio`.
/// @dev Intentionally NOT a {BaseCustomPriceFeed} subclass: `ratio()` is ankrETH-PER-ETH, so the rate enters as a
///      DENOMINATOR (`* 1e18 / ratio`) with the division kept last for precision. BaseCustomPriceFeed assumes the
///      rate is a direct 18-decimal multiplier (`rate * base / 1e18`); expressing this feed that way would require a
///      pre-inverted `_rate() = 1e36 / ratio`, whose intermediate floor would shift the result by up to 1 unit. So
///      this feed keeps its own division-last `_compute`. (The direct-multiplier rate feeds — NXM, ezETH_L2 — do
///      use BaseCustomPriceFeed.) Base/USD sourced from the NAV cancels cleanly when NAV is quoted in the base (see
///      {NavBaseUsdLib}, incl. the circularity invariant).
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ankrETH_CustomPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice ankrETH token address.
    address public immutable ANKR_ETH;

    /// @notice NAVCalculator (proxy) the base/USD (ETH/USD) price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset whose USD price is read from the NAV (e.g. WETH). Must be priced by DIRECT feeds on the
    ///         NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} circularity invariant).
    address public immutable BASE_ASSET;

    /// @notice Number of decimals the returned price is represented with — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    /// @param ankrEth_ The address of the ankrETH token.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address ankrEth_, address nav_, address baseAsset_) {
        ANKR_ETH = OracleArgumentChecks.assertERC20Address(ankrEth_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        _decimals = NAV_DECIMALS;
    }

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
        // Base/USD (ETH/USD) from the NAV's selector (normalized to NAV_DECIMALS = 8); it marks the base stale on
        // all-base-feeds-stale only (L2 sequencer-down alone does NOT — NavBaseUsdLib un-folds pd.sequencerDown; ADR 0019). roundId/startedAt/answeredInRound have no meaning for a NAV read.
        uint256 base8;
        (base8, stale, updatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);
        if (stale) return (0, true, 0, 0, updatedAt, 0);
        // ratio() is ankrETH-per-ETH (18 decimals). ETH-per-ankrETH = 1e18 / ratio.
        uint256 ratio = IankrETH(ANKR_ETH).ratio();
        if (ratio == 0) return (0, true, 0, 0, updatedAt, 0);
        // price = (ETH/USD) * 1e18 / ratio → 8 decimals (ETH/USD) since the 1e18 numerator cancels ratio's scale
        price = base8.mulDiv(1e18, ratio, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return ANKR_ETH;
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
    /// @dev One Chainlink leg — the NAV's ETH/USD base feed (the ankrETH `ratio()` is an on-chain value, not an oracle).
    function governingFeedFreshness() external view override returns (uint256 updatedAt, uint256 heartbeat) {
        return NavBaseUsdLib.baseFreshness(NAV, BASE_ASSET);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface IankrETH {
    /// @notice Amount of ankrETH per 1 ETH (18 decimals); decreases as staking rewards accrue.
    function ratio() external view returns (uint256);
}
