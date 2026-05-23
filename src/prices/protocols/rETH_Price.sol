// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title rETH Custom Price Oracle
/// @notice Returns the USD price of rETH by combining rETH's getExchangeRate with Chainlink's ETH/USD feed.
/// @dev The price is computed as `price = (rETH/ETH) * (ETH/USD)`, where:
///      - `rETH/ETH` comes from rETH contract's `getExchangeRate()` function (18 decimals)
///      - `ETH/USD` comes from Chainlink oracle (8 decimals)
///      Multiplied and scaled to 8 decimals: `price = getExchangeRate * ETH/USD / 1e18`
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract rETH_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using Math for uint256;

    //
    // State
    //

    /// @notice rETH token address.
    address public immutable RETH;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param rEth_ The address of the rETH token.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(address rEth_, address ethToUsdChainlinkOracle_, uint256 ethToUsdChainlinkHeartbeat_) {
        RETH = OracleArgumentChecks.assertERC20Address(rEth_);
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
        returns (uint256 price, bool stale, uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        int256 ethToUsdPrice;
        (roundId, ethToUsdPrice, startedAt, updatedAt, answeredInRound) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (ethToUsdPrice <= 0) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }
        uint256 rate = IrETH(RETH).getExchangeRate();
        if (rate == 0) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }
        // getExchangeRate is 18 decimals, ETH/USD is 8 decimals → result is 8 decimals
        price = rate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return RETH;
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

interface IrETH {
    /// @notice Get amount of ETH backing 1 rETH (18 decimals).
    function getExchangeRate() external view returns (uint256);
}
