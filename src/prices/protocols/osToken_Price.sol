// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title StakeWise osToken Custom Price Oracle (generic)
/// @notice Returns the USD price of a StakeWise V3 osToken (osETH, osGNO, …) by combining the osToken→underlying
///         conversion rate with the underlying's Chainlink USD feed.
/// @dev `price = (osToken/underlying) * (underlying/USD)`, where:
///      - `osToken/underlying` is `OsTokenVaultController.convertToAssets(1e18)` (18 decimals)
///      - `underlying/USD` is a Chainlink oracle (e.g. ETH/USD for osETH, GNO/USD for osGNO; 8 decimals)
///      Scaled to the Chainlink feed's decimals: `price = convertToAssets(1e18) * underlyingUsd / 1e18`.
///      Generic over the osToken / underlying — instantiate one per (osToken, controller, underlying/USD feed).
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract osToken_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using Math for uint256;

    //
    // State
    //

    /// @notice The osToken whose USD price this feed returns (e.g. osETH, osGNO).
    address public immutable OS_TOKEN;

    /// @notice The StakeWise osToken vault controller (provides the osToken→underlying conversion rate).
    IOsTokenVaultController public immutable OS_TOKEN_VAULT_CONTROLLER;

    /// @notice Chainlink oracle for the underlying asset to USD (ETH/USD for osETH, GNO/USD for osGNO).
    AggregatorV3Interface public immutable UNDERLYING_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the underlying/USD Chainlink oracle.
    uint256 public immutable UNDERLYING_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with (matches the Chainlink feed).
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param osToken_ The osToken address (osETH, osGNO, …).
    /// @param osTokenVaultController_ The StakeWise OsTokenVaultController for this osToken.
    /// @param underlyingToUsdChainlinkOracle_ The Chainlink <underlying>/USD oracle (ETH/USD, GNO/USD, …).
    /// @param underlyingToUsdChainlinkHeartbeat_ Seconds after which the Chainlink price is considered stale.
    constructor(
        address osToken_,
        address osTokenVaultController_,
        address underlyingToUsdChainlinkOracle_,
        uint256 underlyingToUsdChainlinkHeartbeat_
    ) {
        OS_TOKEN = OracleArgumentChecks.assertERC20Address(osToken_);
        require(osTokenVaultController_.code.length > 0, "OsTokenVaultController must be a contract");
        OS_TOKEN_VAULT_CONTROLLER = IOsTokenVaultController(osTokenVaultController_);
        UNDERLYING_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(underlyingToUsdChainlinkOracle_);
        UNDERLYING_TO_USD_CHAINLINK_HEARTBEAT =
            OracleArgumentChecks.assertNotZeroNumber(underlyingToUsdChainlinkHeartbeat_);
        _decimals = UNDERLYING_TO_USD_CHAINLINK_ORACLE.decimals();
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
        int256 underlyingToUsdPrice;
        (roundId, underlyingToUsdPrice, startedAt, updatedAt, answeredInRound) =
            UNDERLYING_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (underlyingToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= UNDERLYING_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 rate = OS_TOKEN_VAULT_CONTROLLER.convertToAssets(1e18);
        if (rate == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        // convertToAssets(1e18) is 18 decimals, underlying/USD is 8 decimals → result is 8 decimals
        price = rate.mulDiv(uint256(underlyingToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return OS_TOKEN;
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
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

/// @notice Interface for interacting with StakeWise v3 osToken Vault Controllers.
interface IOsTokenVaultController {
    /// @notice Converts a given amount of osToken shares to the underlying asset amount.
    /// @param shares The amount of osToken shares to convert.
    /// @return assets The equivalent amount of underlying assets.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
