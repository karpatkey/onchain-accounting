// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ankrETH Custom Price Oracle
/// @notice Returns the USD price of ankrETH by combining ankrETH's ratio with Chainlink's ETH/USD feed.
/// @dev ankrETH is a reward-bearing token whose ETH value grows over time. The `ratio()` returns the amount
///      of ankrETH per 1 ETH (18 decimals, decreasing over time), so ETH per ankrETH = 1e18 / ratio.
///      The price is computed as `price = (ETH/USD) * 1e18 / ratio`, where:
///      - `ratio` comes from the ankrETH contract's `ratio()` function (18 decimals, ankrETH-per-ETH)
///      - `ETH/USD` comes from Chainlink oracle (8 decimals)
///      Result is scaled to 8 decimals: `price = ETH/USD * 1e18 / ratio`.
/// @dev Intentionally NOT a {BaseCustomPriceFeed} subclass: `ratio()` is ankrETH-PER-ETH, so the rate enters as a
///      DENOMINATOR (`* 1e18 / ratio`) with the division kept last for precision. BaseCustomPriceFeed assumes the
///      rate is a direct 18-decimal multiplier (`rate * base / 1e18`); expressing this feed that way would require a
///      pre-inverted `_rate() = 1e36 / ratio`, whose intermediate floor would shift the result by up to 1 unit. So
///      this feed keeps its own division-last `_compute`. (The direct-multiplier rate feeds — NXM, ezETH_L2 — do
///      use BaseCustomPriceFeed.)
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ankrETH_CustomPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    /// @notice ankrETH token address.
    address public immutable ANKR_ETH;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    /// @param ankrEth_ The address of the ankrETH token.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(address ankrEth_, address ethToUsdChainlinkOracle_, uint256 ethToUsdChainlinkHeartbeat_) {
        ANKR_ETH = OracleArgumentChecks.assertERC20Address(ankrEth_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
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
        int256 ethToUsdPrice;
        (roundId, ethToUsdPrice, startedAt, updatedAt, answeredInRound) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        if (ethToUsdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }
        // ratio() is ankrETH-per-ETH (18 decimals). ETH-per-ankrETH = 1e18 / ratio.
        uint256 ratio = IankrETH(ANKR_ETH).ratio();
        if (ratio == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        // price = (ETH/USD) * 1e18 / ratio → 8 decimals (ETH/USD) since the 1e18 numerator cancels ratio's scale
        price = uint256(ethToUsdPrice).mulDiv(1e18, ratio, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return ANKR_ETH;
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

interface IankrETH {
    /// @notice Amount of ankrETH per 1 ETH (18 decimals); decreases as staking rewards accrue.
    function ratio() external view returns (uint256);
}
