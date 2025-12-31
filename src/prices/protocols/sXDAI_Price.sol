// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceOracleCustom} from "src/prices/IPriceOracleCustom.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "src/errors.sol";

/// @title sDAI (Savings xDAI) Custom Price Oracle
/// @notice Returns the USD price of sDAI by combining Chainlink’s xDAI/USD feed with the sDAI ERC-4626 exchange rate.
/// @dev sDAI is an ERC-4626 share token representing claims on an xDAI-denominated vault. The price is computed as:
///      `price = (xDAI/USD) * (assetsPerShare)`, where
///      `assetsPerShare = IERC4626(sDAI).convertToAssets(10**shareDecimals) / 10**shareDecimals`.
///      - The xDAI/USD quote comes from `xDAI_to_USD_chainlinkOracle` and the returned price uses `_decimals`.
///      - Freshness of the Chainlink feed is checked against `xDAI_to_USD_chainlinkHertbeat`; if exceeded,
///        the function sets `stale = true` but still returns the computed price.
///      - Multiplication/division is performed via `Math.mulDiv(..., Math.Rounding.Floor)` so the result is
///        scaled back to `_decimals` and rounded down.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract sDAI_PriceOracle is IPriceOracleCustom {
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
    address public immutable sDAI;

    /// @notice Chainlink oracle for xDAI to USD
    AggregatorV3Interface public immutable xDAI_to_USD_chainlinkOracle;

    /// @notice The heartbeat interval for the Chainlink oracle.
    uint256 public immutable xDAI_to_USD_chainlinkHertbeat;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param sDAI_ The address of the Savings xDai contract.
    /// @param xDAI_to_USD_chainlinkOracle_ The address of the xDAI to USD Chainlink oracle.
    /// @param xDAI_to_USD_chainlinkHertbeat_ The time in seconds after which the price is considered stale if not
    /// updated.
    constructor(address sDAI_, address xDAI_to_USD_chainlinkOracle_, uint256 xDAI_to_USD_chainlinkHertbeat_) {
        sDAI = OracleArgumentChecks.assertERC20Address(sDAI_);

        xDAI_to_USD_chainlinkOracle = OracleArgumentChecks.assertChainlinkOracle(xDAI_to_USD_chainlinkOracle_);

        xDAI_to_USD_chainlinkHertbeat = OracleArgumentChecks.assertNotZeroNumber(xDAI_to_USD_chainlinkHertbeat_);

        _decimals = xDAI_to_USD_chainlinkOracle.decimals();
    }

    //
    // IPriceOracleCustom
    //

    /// @inheritdoc IPriceOracleCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 xDAI_to_USD_price,, uint256 xDAI_to_USD_updatedAt,) = xDAI_to_USD_chainlinkOracle.latestRoundData();

        if (xDAI_to_USD_price <= 0) {
            return (0, true);
        }

        IERC4626 sDAI_vault = IERC4626(sDAI);

        if (block.timestamp - xDAI_to_USD_updatedAt > xDAI_to_USD_chainlinkHertbeat) stale = true;

        uint256 underlyingValue = sDAI_vault.convertToAssets(10 ** sDAI_vault.decimals());

        price = xDAI_to_USD_price.toUint256().mulDiv(underlyingValue, 10 ** sDAI_vault.decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceOracleCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IPriceOracleCustom
    function underlyingAssetSupported() external view override returns (address) {
        return address(sDAI);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
