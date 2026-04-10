// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title weETH Custom Price Oracle (Mainnet)
/// @notice Returns the USD price of weETH by combining Chainlink's weETH/ETH feed with Chainlink's ETH/USD feed.
/// @dev The price is computed as `price = (weETH/ETH) * (ETH/USD)`, where both feeds are from Chainlink.
///      Both heartbeats are checked independently; if either feed is stale the result is marked stale.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract weETH_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice weETH token address.
    address public immutable WEETH;

    /// @notice Chainlink oracle for weETH to ETH exchange rate.
    AggregatorV3Interface public immutable WEETH_TO_ETH_CHAINLINK;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the weETH/ETH Chainlink oracle.
    uint256 public immutable WEETH_TO_ETH_HEARTBEAT;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param weEth_ The address of the weETH token.
    /// @param weEthToEthChainlink_ The address of the weETH to ETH Chainlink oracle.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param weEthToEthHeartbeat_ The time in seconds after which the weETH/ETH price is considered stale.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the ETH/USD price is considered stale.
    constructor(
        address weEth_,
        address weEthToEthChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 weEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        WEETH = OracleArgumentChecks.assertERC20Address(weEth_);
        WEETH_TO_ETH_CHAINLINK = OracleArgumentChecks.assertChainlinkOracle(weEthToEthChainlink_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        WEETH_TO_ETH_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(weEthToEthHeartbeat_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
    //

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 weEthToEthRate,, uint256 weEthToEthUpdatedAt,) = WEETH_TO_ETH_CHAINLINK.latestRoundData();
        (, int256 ethToUsdPrice,, uint256 ethToUsdUpdatedAt,) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (weEthToEthRate <= 0 || ethToUsdPrice <= 0) {
            return (0, true);
        }

        if (
            block.timestamp - weEthToEthUpdatedAt > WEETH_TO_ETH_HEARTBEAT
                || block.timestamp - ethToUsdUpdatedAt > ETH_TO_USD_CHAINLINK_HEARTBEAT
        ) {
            stale = true;
        }

        // weETH/ETH is 18 decimals (Chainlink), ETH/USD is 8 decimals → result is 8 decimals
        price = weEthToEthRate.toUint256().mulDiv(
            ethToUsdPrice.toUint256(), 10 ** WEETH_TO_ETH_CHAINLINK.decimals(), Math.Rounding.Floor
        );
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return WEETH;
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
