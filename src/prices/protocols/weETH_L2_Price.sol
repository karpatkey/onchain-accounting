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

/// @title weETH L2 Custom Price Oracle
/// @notice Returns the USD price of weETH on L2 by combining Chainlink weETH/eETH × Chainlink ETH/USD.
/// @dev price = (weETH/eETH) * (ETH/USD). Assumes eETH ≈ ETH 1:1. Both heartbeats checked independently.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract weETH_L2_PriceOracle is IPriceFeedCustom {
    using SafeCast for int256;
    using Math for uint256;

    address public immutable WEETH;
    AggregatorV3Interface public immutable WEETH_TO_EETH_CHAINLINK;
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;
    uint256 public immutable WEETH_TO_EETH_HEARTBEAT;
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;
    uint8 internal _decimals;

    constructor(
        address weEth_,
        address weEthToEethChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 weEthToEethHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        WEETH = OracleArgumentChecks.assertERC20Address(weEth_);
        WEETH_TO_EETH_CHAINLINK = OracleArgumentChecks.assertChainlinkOracle(weEthToEethChainlink_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        WEETH_TO_EETH_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(weEthToEethHeartbeat_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 weEthToEethRate,, uint256 weEthToEethUpdatedAt,) = WEETH_TO_EETH_CHAINLINK.latestRoundData();
        (, int256 ethToUsdPrice,, uint256 ethToUsdUpdatedAt,) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (weEthToEethRate <= 0 || ethToUsdPrice <= 0) {
            return (0, true);
        }

        if (
            block.timestamp - weEthToEethUpdatedAt > WEETH_TO_EETH_HEARTBEAT
                || block.timestamp - ethToUsdUpdatedAt > ETH_TO_USD_CHAINLINK_HEARTBEAT
        ) {
            stale = true;
        }

        price = weEthToEethRate.toUint256()
            .mulDiv(ethToUsdPrice.toUint256(), 10 ** WEETH_TO_EETH_CHAINLINK.decimals(), Math.Rounding.Floor);
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
