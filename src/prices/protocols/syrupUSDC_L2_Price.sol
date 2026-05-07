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

/// @title syrupUSDC L2 Custom Price Oracle
/// @notice Returns the USD price of syrupUSDC on L2 using Chainlink syrupUSDC/USDC x Chainlink USDC/USD.
/// @dev price = (syrupUSDC/USDC) * (USDC/USD). Both heartbeats checked independently.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract syrupUSDC_L2_PriceOracle is IPriceFeedCustom {
    using SafeCast for int256;
    using Math for uint256;

    address public immutable SYRUP_USDC;
    AggregatorV3Interface public immutable SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE;
    AggregatorV3Interface public immutable USDC_TO_USD_CHAINLINK_ORACLE;
    uint256 public immutable SYRUP_USDC_TO_USDC_CHAINLINK_HEARTBEAT;
    uint256 public immutable USDC_TO_USD_CHAINLINK_HEARTBEAT;
    uint8 internal _decimals;

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

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 syrupUsdcToUsdcRate,, uint256 syrupUsdcToUsdcUpdatedAt,) =
            SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE.latestRoundData();
        (, int256 usdcToUsdPrice,, uint256 usdcToUsdUpdatedAt,) = USDC_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (syrupUsdcToUsdcRate <= 0 || usdcToUsdPrice <= 0) {
            return (0, true);
        }

        if (
            block.timestamp - syrupUsdcToUsdcUpdatedAt > SYRUP_USDC_TO_USDC_CHAINLINK_HEARTBEAT
                || block.timestamp - usdcToUsdUpdatedAt > USDC_TO_USD_CHAINLINK_HEARTBEAT
        ) {
            stale = true;
        }

        price = syrupUsdcToUsdcRate.toUint256()
            .mulDiv(
                usdcToUsdPrice.toUint256(), 10 ** SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor
            );
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return SYRUP_USDC;
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
        (uint80 r1,, uint256 s1, uint256 u1, uint80 ar1) = SYRUP_USDC_TO_USDC_CHAINLINK_ORACLE.latestRoundData();
        (uint80 r2,, uint256 s2, uint256 u2, uint80 ar2) = USDC_TO_USD_CHAINLINK_ORACLE.latestRoundData();
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
