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

/// @title wstETH L2 Custom Price Oracle
/// @notice Returns the USD price of wstETH on L2 by combining Chainlink's wstETH/ETH feed with Chainlink's ETH/USD feed.
/// @dev The price is computed as `price = (wstETH/ETH) * (ETH/USD)`, where both feeds are from Chainlink.
///      Both heartbeats are checked independently; if either feed is stale the result is marked stale.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract wstETH_L2_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice wstETH token address.
    address public immutable WSTETH;

    /// @notice Chainlink oracle for wstETH to ETH exchange rate.
    AggregatorV3Interface public immutable WSTETH_TO_ETH_CHAINLINK_ORACLE;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the wstETH/ETH Chainlink oracle.
    uint256 public immutable WSTETH_TO_ETH_CHAINLINK_HEARTBEAT;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param wstEth_ The address of the wstETH token.
    /// @param wstEthToEthChainlink_ The address of the wstETH to ETH Chainlink oracle.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param wstEthToEthHeartbeat_ The time in seconds after which the wstETH/ETH price is considered stale.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the ETH/USD price is considered stale.
    constructor(
        address wstEth_,
        address wstEthToEthChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 wstEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        WSTETH = OracleArgumentChecks.assertERC20Address(wstEth_);
        WSTETH_TO_ETH_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(wstEthToEthChainlink_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        WSTETH_TO_ETH_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(wstEthToEthHeartbeat_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
    //

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 wstEthToEthRate,, uint256 wstEthToEthUpdatedAt,) = WSTETH_TO_ETH_CHAINLINK_ORACLE.latestRoundData();
        (, int256 ethToUsdPrice,, uint256 ethToUsdUpdatedAt,) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (wstEthToEthRate <= 0 || ethToUsdPrice <= 0) {
            return (0, true);
        }

        if (
            block.timestamp - wstEthToEthUpdatedAt > WSTETH_TO_ETH_CHAINLINK_HEARTBEAT
                || block.timestamp - ethToUsdUpdatedAt > ETH_TO_USD_CHAINLINK_HEARTBEAT
        ) {
            stale = true;
        }

        // wstETH/ETH is 18 decimals (Chainlink), ETH/USD is 8 decimals → result is 8 decimals
        price = wstEthToEthRate.toUint256()
            .mulDiv(ethToUsdPrice.toUint256(), 10 ** WSTETH_TO_ETH_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return WSTETH;
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
        (uint80 r1,, uint256 s1, uint256 u1, uint80 ar1) = WSTETH_TO_ETH_CHAINLINK_ORACLE.latestRoundData();
        (uint80 r2,, uint256 s2, uint256 u2, uint80 ar2) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (u1 <= u2) {
            (roundId, startedAt, updatedAt, answeredInRound) = (r1, s1, u1, ar1);
        } else {
            (roundId, startedAt, updatedAt, answeredInRound) = (r2, s2, u2, ar2);
        }
        (uint256 price,) = this.getLatestPrice();
        answer = int256(price);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
