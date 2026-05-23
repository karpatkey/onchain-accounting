// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title sDAI (Savings xDAI) Custom Price Oracle
/// @notice Returns the USD price of sDAI by combining Chainlink’s xDAI/USD feed with the sDAI ERC-4626 exchange rate.
/// @dev sDAI is an ERC-4626 share token representing claims on an xDAI-denominated vault. The price is computed as:
///      `price = (xDAI/USD) * (assetsPerShare)`, where
///      `assetsPerShare = IERC4626(sDAI).convertToAssets(10**shareDecimals) / 10**shareDecimals`.
///      - The xDAI/USD quote comes from `X_DAI_TO_USD_CHAINLINK_ORACLE` and the returned price uses `_decimals`.
///      - Freshness of the Chainlink feed is checked against `X_DAI_TO_USD_CHAINLINK_HEARTBEAT`; if exceeded,
///        the function returns `(0, true)`.
///      - Multiplication/division is performed via `Math.mulDiv(..., Math.Rounding.Floor)` so the result is
///        scaled back to `_decimals` and rounded down.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sDAI_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice savingsXDai contract interface
    address public immutable S_DAI;

    /// @notice Chainlink oracle for xDAI to USD
    AggregatorV3Interface public immutable X_DAI_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the Chainlink oracle.
    uint256 public immutable X_DAI_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param sDai_ The address of the Savings xDai contract.
    /// @param xDaiToUsdChainlinkOracle_ The address of the xDAI to USD Chainlink oracle.
    /// @param xDaiToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not
    /// updated.
    constructor(address sDai_, address xDaiToUsdChainlinkOracle_, uint256 xDaiToUsdChainlinkHeartbeat_) {
        S_DAI = OracleArgumentChecks.assertERC20Address(sDai_);

        X_DAI_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(xDaiToUsdChainlinkOracle_);

        X_DAI_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(xDaiToUsdChainlinkHeartbeat_);

        _decimals = X_DAI_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
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
        int256 xDaiToUsdPrice;
        (roundId, xDaiToUsdPrice, startedAt, updatedAt, answeredInRound) =
            X_DAI_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (xDaiToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= X_DAI_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 underlyingValue = IERC4626(S_DAI).convertToAssets(10 ** _decimals);
        price = xDaiToUsdPrice.toUint256().mulDiv(underlyingValue, 10 ** _decimals, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return address(S_DAI);
    }

    /// @inheritdoc IPriceFeedCustom
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
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
