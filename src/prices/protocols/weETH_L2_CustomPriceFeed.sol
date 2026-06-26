// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
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
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract weETH_L2_CustomPriceFeed is ICustomPriceFeed {
    using SafeCast for int256;
    using Math for uint256;

    address public immutable WEETH;
    AggregatorV3Interface public immutable WEETH_TO_EETH_CHAINLINK;
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;
    uint256 public immutable WEETH_TO_EETH_HEARTBEAT;
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;
    uint8 private immutable _decimals;

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
        (uint80 r1, int256 weEthToEethRate, uint256 s1, uint256 u1, uint80 ar1) =
            WEETH_TO_EETH_CHAINLINK.latestRoundData();
        (uint80 r2, int256 ethToUsdPrice, uint256 s2, uint256 u2, uint80 ar2) =
            ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (u1 <= u2) {
            (roundId, startedAt, updatedAt, answeredInRound) = (r1, s1, u1, ar1);
        } else {
            (roundId, startedAt, updatedAt, answeredInRound) = (r2, s2, u2, ar2);
        }

        if (weEthToEethRate <= 0 || ethToUsdPrice <= 0) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        uint256 effectiveWeEthUpdatedAt = u1 > block.timestamp ? block.timestamp : u1;
        uint256 effectiveEthUpdatedAt = u2 > block.timestamp ? block.timestamp : u2;
        if (
            block.timestamp - effectiveWeEthUpdatedAt >= WEETH_TO_EETH_HEARTBEAT
                || block.timestamp - effectiveEthUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT
        ) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        price = weEthToEethRate.toUint256()
            .mulDiv(ethToUsdPrice.toUint256(), 10 ** WEETH_TO_EETH_CHAINLINK.decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return WEETH;
    }

    /// @inheritdoc ICustomPriceFeed
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc ICustomPriceFeed
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
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
