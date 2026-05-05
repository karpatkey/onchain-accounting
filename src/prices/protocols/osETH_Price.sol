// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title osETH Custom Price Oracle
/// @notice Returns the USD price of StakeWise V3 osETH by combining the OsTokenVaultController exchange rate with Chainlink ETH/USD.
/// @dev The price is computed as `price = (ETH/osETH) * (ETH/USD)`, where:
///      - `ETH/osETH` comes from `OsTokenVaultController.convertToAssets(1e18)` (18 decimals)
///      - `ETH/USD` comes from Chainlink (8 decimals)
///      Multiplied and scaled to 8 decimals: `price = exchangeRate * ETH/USD / 1e18`
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract osETH_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using Math for uint256;

    //
    // State
    //

    /// @notice osETH token address.
    address public immutable OS_ETH;

    /// @notice StakeWise V3 OsTokenVaultController (rate provider).
    IOsTokenVaultController public immutable OS_TOKEN_VAULT_CONTROLLER;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param osEth_ The address of the osETH token.
    /// @param osTokenVaultController_ The address of the OsTokenVaultController (exposes convertToAssets()).
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(
        address osEth_,
        address osTokenVaultController_,
        address ethToUsdChainlinkOracle_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        OS_ETH = OracleArgumentChecks.assertERC20Address(osEth_);
        OracleArgumentChecks.assertNonZeroAddress(osTokenVaultController_);
        if (osTokenVaultController_.code.length == 0) revert InvalidArguments();
        OS_TOKEN_VAULT_CONTROLLER = IOsTokenVaultController(osTokenVaultController_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
    //

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 ethToUsdPrice,, uint256 ethToUsdUpdatedAt,) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (ethToUsdPrice <= 0) {
            return (0, true);
        }

        if (block.timestamp - ethToUsdUpdatedAt > ETH_TO_USD_CHAINLINK_HEARTBEAT) {
            stale = true;
        }

        // convertToAssets(1e18) gives ETH-per-osETH with 18 decimals
        uint256 exchangeRate = OS_TOKEN_VAULT_CONTROLLER.convertToAssets(1e18);

        if (exchangeRate == 0) {
            return (0, true);
        }

        // exchangeRate is 18 decimals (ETH per osETH), ETH/USD is 8 decimals → result is 8 decimals
        price = exchangeRate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return OS_ETH;
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface IOsTokenVaultController {
    /// @notice Converts a given amount of osETH shares to the underlying ETH amount (18 decimals).
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
