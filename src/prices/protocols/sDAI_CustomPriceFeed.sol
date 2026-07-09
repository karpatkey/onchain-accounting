// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title sDAI Custom Price Oracle
/// @notice Returns the USD price of sDAI by combining the NAV’s DAI/USD price with Maker’s DSR “chi” ratio.
/// @dev The price is computed as `price = (DAI/USD) * (sDAI/DAI)`, where:
///      - `DAI/USD` (base/USD) comes from the NAV's own selector (`getPriceData(BASE_ASSET)`, 8 decimals).
///      - `sDAI/DAI` is Maker’s DSR Pot `chi` (27-decimals, RAY) read via `RATE_PROVIDER`.
///      The function multiplies these two values and divides by `10**RATIO_DECIMALS` (1e27) so the result has
///      `NAV_DECIMALS` (8). Freshness follows the NAV's base feed staleness (all-feeds-stale; NOT L2 sequencer-down alone); if the
///      NAV reports the base stale or `chi` is 0, the function returns `(0, true)` to signal staleness.
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sDAI_CustomPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    //
    // State
    //

    /// @notice NAVCalculator (proxy) the base/USD (DAI/USD) price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset whose USD price is read from the NAV (e.g. DAI). Must be priced by DIRECT feeds on the
    ///         NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} circularity invariant).
    address public immutable BASE_ASSET;

    /// @notice rate provider for (sDAI / DAI)
    PotLike public immutable RATE_PROVIDER;

    /// @notice Address of the sDAI token
    address public immutable S_DAI;

    /// @notice Number of decimals for sDAI / DAI ratio
    uint8 public constant RATIO_DECIMALS = 27;

    /// @notice Number of decimals the returned price is represented with — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param sDai_ The address of the sDAI token
    /// @param dsrManager_ The address of the DSR Manager contract
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (DAI) whose NAV-selected USD price scales the rate.
    constructor(address sDai_, address dsrManager_, address nav_, address baseAsset_) {
        S_DAI = OracleArgumentChecks.assertERC20Address(sDai_);

        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);

        DsrManager dsrManager = DsrManager(OracleArgumentChecks.assertNonZeroAddress(dsrManager_));

        _decimals = NAV_DECIMALS;
        RATE_PROVIDER = dsrManager.pot();
    }

    //
    // ICustomPriceFeed
    //

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
        // Base/USD (DAI/USD) from the NAV's selector (normalized to NAV_DECIMALS = 8); it marks the base stale on
        // all-base-feeds-stale only (L2 sequencer-down alone does NOT — NavBaseUsdLib un-folds pd.sequencerDown; ADR 0019). roundId/startedAt/answeredInRound have no meaning for a NAV read.
        uint256 base8;
        (base8, stale, updatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);
        if (stale) return (0, true, 0, 0, updatedAt, 0);
        uint256 chi = RATE_PROVIDER.chi();
        if (chi == 0) return (0, true, 0, 0, updatedAt, 0);
        price = base8.mulDiv(chi, 10 ** uint256(RATIO_DECIMALS), Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return S_DAI;
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface DsrManager {
    /// @notice from the original DsrManager contract
    /// @return The pot value
    function pot() external view returns (PotLike);
}

interface PotLike {
    /// @notice from the original Pot contract
    /// @return chi The chi value
    function chi() external view returns (uint256 chi);
}
