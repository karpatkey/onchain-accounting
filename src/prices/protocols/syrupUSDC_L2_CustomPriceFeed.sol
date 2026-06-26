// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title syrupUSDC L2 Custom Price Oracle
/// @notice Returns the USD price of syrupUSDC on L2 using Chainlink syrupUSDC/USDC x Chainlink USDC/USD.
/// @dev price = (syrupUSDC/USDC) * (USDC/USD). Both heartbeats checked independently.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract syrupUSDC_L2_CustomPriceFeed is ICustomPriceFeed {
    using SafeCast for int256;
    using Math for uint256;

    address public immutable SYRUP_USDC;
    AggregatorV3Interface public immutable SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE;
    AggregatorV3Interface public immutable USDC_TO_USD_CHAINLINK_ORACLE;
    uint256 public immutable SYRUP_USDC_TO_USDC_CHAINLINK_HEARTBEAT;
    uint256 public immutable USDC_TO_USD_CHAINLINK_HEARTBEAT;
    uint8 private immutable _decimals;

    constructor(
        address syrupUsdc_,
        address syrupUsdcToUsdcChainlink_,
        address usdcToUsdChainlinkOracle_,
        uint256 syrupUsdcToUsdcHeartbeat_,
        uint256 usdcToUsdChainlinkHeartbeat_
    ) {
        SYRUP_USDC = OracleArgumentChecks.assertERC20Address(syrupUsdc_);
        SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(syrupUsdcToUsdcChainlink_);
        USDC_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(usdcToUsdChainlinkOracle_);
        SYRUP_USDC_TO_USDC_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(syrupUsdcToUsdcHeartbeat_);
        USDC_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdcToUsdChainlinkHeartbeat_);
        _decimals = USDC_TO_USD_CHAINLINK_ORACLE.decimals();
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
        (uint80 r1, int256 syrupUsdcToUsdcRate, uint256 s1, uint256 u1, uint80 ar1) =
            SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE.latestRoundData();
        (uint80 r2, int256 usdcToUsdPrice, uint256 s2, uint256 u2, uint80 ar2) =
            USDC_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (u1 <= u2) {
            (roundId, startedAt, updatedAt, answeredInRound) = (r1, s1, u1, ar1);
        } else {
            (roundId, startedAt, updatedAt, answeredInRound) = (r2, s2, u2, ar2);
        }

        if (syrupUsdcToUsdcRate <= 0 || usdcToUsdPrice <= 0) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        uint256 effectiveSyrupUpdatedAt = u1 > block.timestamp ? block.timestamp : u1;
        uint256 effectiveUsdcUpdatedAt = u2 > block.timestamp ? block.timestamp : u2;
        if (
            block.timestamp - effectiveSyrupUpdatedAt >= SYRUP_USDC_TO_USDC_CHAINLINK_HEARTBEAT
                || block.timestamp - effectiveUsdcUpdatedAt >= USDC_TO_USD_CHAINLINK_HEARTBEAT
        ) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        price = syrupUsdcToUsdcRate.toUint256()
            .mulDiv(
                usdcToUsdPrice.toUint256(), 10 ** SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor
            );
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return SYRUP_USDC;
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
