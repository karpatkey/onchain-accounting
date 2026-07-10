// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title eETH Custom Price Oracle
/// @notice Returns the USD price of eETH by deriving eETH/ETH from weETH data and combining with the NAV's ETH/USD.
/// @dev The price is computed as `price = (eETH/ETH) * (ETH/USD)`, where:
///      - `eETH/ETH = (weETH/ETH) ÷ (eETH/weETH)`
///      - `weETH/ETH` comes from Chainlink weETH/ETH oracle (18 decimals)
///      - `eETH/weETH` comes from weETH contract's `getRate()` function (18 decimals, eETH per weETH)
///      - `ETH/USD` (base/USD) comes from the NAV's own selector (`getPriceData(BASE_ASSET)`, 8 decimals)
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract eETH_CustomPriceFeed is ICustomPriceFeed {
    //
    // Libraries
    //
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice eETH token address.
    address public immutable EETH;

    /// @notice weETH token address (used to get the eETH/weETH rate via getRate()).
    address public immutable WEETH;

    /// @notice Chainlink oracle for weETH to ETH exchange rate.
    AggregatorV3Interface public immutable WEETH_TO_ETH_CHAINLINK;

    /// @notice NAVCalculator (proxy) the base/USD (ETH/USD) price is read from via its selector.
    INAVCalculator public immutable NAV;

    /// @notice The base asset whose USD price is read from the NAV (e.g. WETH). Must be priced by DIRECT feeds on the
    ///         NAV — never by a NAV-sourced custom feed (see {NavBaseUsdLib} circularity invariant).
    address public immutable BASE_ASSET;

    /// @notice The heartbeat interval for the weETH/ETH Chainlink oracle.
    uint256 public immutable WEETH_TO_ETH_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with — `NAV_DECIMALS` (8).
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param eEth_ The address of the eETH token.
    /// @param weEth_ The address of the weETH token (used to get the eETH/weETH rate).
    /// @param weEthToEthChainlink_ The address of the weETH to ETH Chainlink oracle.
    /// @param weEthToEthHeartbeat_ The time in seconds after which the weETH/ETH price is considered stale.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(
        address eEth_,
        address weEth_,
        address weEthToEthChainlink_,
        uint256 weEthToEthHeartbeat_,
        address nav_,
        address baseAsset_
    ) {
        EETH = OracleArgumentChecks.assertERC20Address(eEth_);
        WEETH = OracleArgumentChecks.assertERC20Address(weEth_);
        WEETH_TO_ETH_CHAINLINK = OracleArgumentChecks.assertChainlinkOracle(weEthToEthChainlink_);
        WEETH_TO_ETH_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(weEthToEthHeartbeat_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        _decimals = NAV_DECIMALS;
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
        // weETH/ETH rate leg (Chainlink), plus the base/USD (ETH/USD) term from the NAV's selector. The returned
        // updatedAt is the more conservative min(rateLegUpdatedAt, baseUpdatedAt) so callers see worst-case freshness.
        int256 weEthToEthRate;
        uint256 rateUpdatedAt;
        (roundId, weEthToEthRate, startedAt, rateUpdatedAt, answeredInRound) = WEETH_TO_ETH_CHAINLINK.latestRoundData();

        (uint256 base8, bool baseStale, uint256 baseUpdatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);

        updatedAt = rateUpdatedAt <= baseUpdatedAt ? rateUpdatedAt : baseUpdatedAt;

        if (baseStale || weEthToEthRate <= 0) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        uint256 effectiveWeEthUpdatedAt = rateUpdatedAt > block.timestamp ? block.timestamp : rateUpdatedAt;
        if (block.timestamp - effectiveWeEthUpdatedAt >= WEETH_TO_ETH_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        uint256 weEthToEEthRate = IweETH(WEETH).getRate();
        if (weEthToEEthRate == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        // eETH/ETH = weETH/ETH ÷ eETH/weETH (both 18 dec → result 18 dec)
        uint256 eEthToEthRate = weEthToEthRate.toUint256().mulDiv(1e18, weEthToEEthRate, Math.Rounding.Floor);

        // eETH/ETH (18 dec) * ETH/USD (8 dec) / 1e18 = 8 dec
        price = eEthToEthRate.mulDiv(base8, 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return EETH;
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface IweETH {
    /// @notice Get amount of eETH per weETH (18 decimals). Used as divisor to derive eETH/ETH from weETH/ETH.
    function getRate() external view returns (uint256);
}
