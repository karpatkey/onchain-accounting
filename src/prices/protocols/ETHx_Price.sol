// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ETHx Custom Price Oracle
/// @notice Returns the USD price of Stader's ETHx by combining the StakePoolsManager exchange rate with Chainlink ETH/USD.
/// @dev The price is computed as `price = (ETH/ETHx) * (ETH/USD)`, where:
///      - `ETH/ETHx` comes from `StaderStakePoolsManager.getExchangeRate()` (18 decimals)
///      - `ETH/USD` comes from Chainlink (8 decimals)
///      Multiplied and scaled to 8 decimals: `price = exchangeRate * ETH/USD / 1e18`
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ETHx_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using Math for uint256;

    //
    // State
    //

    /// @notice ETHx token address.
    address public immutable ETHX;

    /// @notice Stader StakePoolsManager (rate provider).
    IStaderStakePoolsManager public immutable STAKE_POOLS_MANAGER;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param ethx_ The address of the ETHx token.
    /// @param stakePoolsManager_ The address of the StaderStakePoolsManager (exposes getExchangeRate()).
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(
        address ethx_,
        address stakePoolsManager_,
        address ethToUsdChainlinkOracle_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        ETHX = OracleArgumentChecks.assertERC20Address(ethx_);
        OracleArgumentChecks.assertNonZeroAddress(stakePoolsManager_);
        if (stakePoolsManager_.code.length == 0) revert InvalidArguments();
        STAKE_POOLS_MANAGER = IStaderStakePoolsManager(stakePoolsManager_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
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
        int256 ethToUsdPrice;
        (roundId, ethToUsdPrice, startedAt, updatedAt, answeredInRound) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (ethToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        uint256 exchangeRate = STAKE_POOLS_MANAGER.getExchangeRate();
        if (exchangeRate == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        // exchangeRate is 18 decimals (ETH per ETHx), ETH/USD is 8 decimals → result is 8 decimals
        price = exchangeRate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return ETHX;
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

interface IStaderStakePoolsManager {
    /// @notice Returns the ETH-per-ETHx exchange rate (18 decimals).
    function getExchangeRate() external view returns (uint256);
}
