// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title wstETH Custom Price Oracle
/// @notice Returns the USD price of wstETH by combining wstETH's stEthPerToken rate with Chainlink's ETH/USD feed.
/// @dev The price is computed as `price = (stETH/wstETH) * (ETH/USD)`, where:
///      - `stETH/wstETH` comes from wstETH contract's `stEthPerToken()` function (18 decimals)
///      - `ETH/USD` comes from Chainlink oracle (8 decimals)
///      Multiplied and scaled to 8 decimals: `price = stEthPerToken * ETH/USD / 1e18`
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract wstETH_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using Math for uint256;

    //
    // State
    //

    /// @notice wstETH token address.
    address public immutable WSTETH;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param wstEth_ The address of the wstETH token.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(address wstEth_, address ethToUsdChainlinkOracle_, uint256 ethToUsdChainlinkHeartbeat_) {
        WSTETH = OracleArgumentChecks.assertERC20Address(wstEth_);
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

        uint256 stEthPerToken = IwstETH(WSTETH).stEthPerToken();

        if (stEthPerToken == 0) {
            return (0, true);
        }

        // stEthPerToken is 18 decimals, ETH/USD is 8 decimals → result is 8 decimals
        price = stEthPerToken.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
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
        (roundId,, startedAt, updatedAt, answeredInRound) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();
        (uint256 price,) = this.getLatestPrice();
        answer = int256(price);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

interface IwstETH {
    /// @notice Get amount of stETH for 1 wstETH (18 decimals).
    function stEthPerToken() external view returns (uint256);
}
