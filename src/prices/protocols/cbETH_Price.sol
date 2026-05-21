// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title cbETH Custom Price Oracle
/// @notice Returns the USD price of cbETH by combining cbETH's exchange rate with Chainlink's ETH/USD feed.
/// @dev The price is computed as `price = (cbETH/ETH) * (ETH/USD)`, where:
///      - `cbETH/ETH` comes from cbETH contract's `exchangeRate()` function (18 decimals)
///      - `ETH/USD` comes from Chainlink oracle (8 decimals)
///      Multiplied and scaled to 8 decimals: `price = exchangeRate * ETH/USD / 1e18`
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract cbETH_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using Math for uint256;

    //
    // State
    //

    /// @notice cbETH token address.
    address public immutable CBETH;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param cbEth_ The address of the cbETH token.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(address cbEth_, address ethToUsdChainlinkOracle_, uint256 ethToUsdChainlinkHeartbeat_) {
        CBETH = OracleArgumentChecks.assertERC20Address(cbEth_);
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

        uint256 effectiveUpdatedAt = ethToUsdUpdatedAt > block.timestamp ? block.timestamp : ethToUsdUpdatedAt;
        if (block.timestamp - effectiveUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true);
        }

        uint256 rate = IcbETH(CBETH).exchangeRate();

        if (rate == 0) {
            return (0, true);
        }

        // exchangeRate is 18 decimals, ETH/USD is 8 decimals → result is 8 decimals
        price = rate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return CBETH;
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
        (roundId,, startedAt, updatedAt, answeredInRound) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        (uint256 price,) = this.getLatestPrice();
        answer = int256(price);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface IcbETH {
    /// @notice Get the exchange rate of cbETH to ETH (18 decimals).
    function exchangeRate() external view returns (uint256);
}
