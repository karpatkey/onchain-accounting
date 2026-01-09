// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceOracleCustom} from "src/prices/IPriceOracleCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "src/errors.sol";

/// @title LDO Custom Price Oracle
/// @notice This contract provides the price of LDO.
/// @dev The price is calculated by fetching the LDO/ETH price from a Chainlink oracle, and then converting it to USD
/// using another Chainlink oracle for ETH/USD.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract LDO_PriceOracle is IPriceOracleCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice LDO token address
    address public immutable LDO;

    /// @notice Chainlink oracle for LDO to ETH
    AggregatorV3Interface public immutable LDO_to_ETH_chainlinkOracle;

    /// @notice Chainlink oracle for ETH to USD
    AggregatorV3Interface public immutable ETH_to_USD_chainlinkOracle;

    /// @notice The heartbeat interval for the LDO/ETH Chainlink oracle.
    uint256 public immutable LDO_to_ETH_chainlinkHeartbeat;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_to_USD_chainlinkHeartbeat;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param LDO_ The address of the LDO token.
    /// @param LDO_to_ETH_ChainlinkAddress_ The address of the LDO to ETH Chainlink aggregator.
    /// @param ETH_to_USD_ChainlinkAddress_ The address of the ETH to USD Chainlink aggregator.
    /// @param LDO_to_ETH_chainlinkHeartbeat_ The time in seconds after which the LDO/ETH price is considered stale if
    /// not updated.
    /// @param ETH_to_USD_chainlinkHeartbeat_ The time in seconds after which the ETH/USD price is considered stale if
    /// not updated.
    constructor(
        address LDO_,
        address LDO_to_ETH_ChainlinkAddress_,
        address ETH_to_USD_ChainlinkAddress_,
        uint256 LDO_to_ETH_chainlinkHeartbeat_,
        uint256 ETH_to_USD_chainlinkHeartbeat_
    ) {
        LDO = OracleArgumentChecks.assertERC20Address(LDO_);

        LDO_to_ETH_chainlinkOracle = OracleArgumentChecks.assertChainlinkOracle(LDO_to_ETH_ChainlinkAddress_);
        ETH_to_USD_chainlinkOracle = OracleArgumentChecks.assertChainlinkOracle(ETH_to_USD_ChainlinkAddress_);

        LDO_to_ETH_chainlinkHeartbeat = OracleArgumentChecks.assertNotZeroNumber(LDO_to_ETH_chainlinkHeartbeat_);
        ETH_to_USD_chainlinkHeartbeat = OracleArgumentChecks.assertNotZeroNumber(ETH_to_USD_chainlinkHeartbeat_);

        _decimals = ETH_to_USD_chainlinkOracle.decimals();
    }

    //
    // IPriceOracleCustom
    //

    /// @inheritdoc IPriceOracleCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 LDO_to_ETH_price,, uint256 LDO_to_USD_updatedAt,) = LDO_to_ETH_chainlinkOracle.latestRoundData();
        (, int256 ETH_to_USD_price,, uint256 ETH_to_USD_updatedAt,) = ETH_to_USD_chainlinkOracle.latestRoundData();

        if (LDO_to_ETH_price <= 0 || ETH_to_USD_price <= 0) {
            return (0, true);
        }

        // Check if either price is stale based on their respective heartbeats
        if (
            block.timestamp - LDO_to_USD_updatedAt > LDO_to_ETH_chainlinkHeartbeat
                || block.timestamp - ETH_to_USD_updatedAt > ETH_to_USD_chainlinkHeartbeat
        ) {
            stale = true;
        }

        // LDO/ETH price is in 8 decimals, ETH/USD price is in 8 decimals
        // First multiply the prices together (this will have 8 + 8 = 16 decimals)
        // Then divide by 10^8 to get back to 8 decimals (matching ETH/USD)
        price = LDO_to_ETH_price.toUint256()
            .mulDiv(ETH_to_USD_price.toUint256(), 10 ** LDO_to_ETH_chainlinkOracle.decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceOracleCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IPriceOracleCustom
    function underlyingAssetSupported() external view override returns (address) {
        return LDO;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceOracleCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
