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
/// @notice Returns the USD price of wstETH by combining wstETH's on-chain stEthPerToken rate with Chainlink's
///         stETH/ETH and ETH/USD feeds.
/// @dev The price is computed as `price = stEthPerToken * (stETH/ETH) * (ETH/USD)`, where:
///      - `stEthPerToken` (stETH per 1 wstETH) comes from the wstETH contract (18 decimals)
///      - `stETH/ETH` (ETH per 1 stETH) comes from a Chainlink oracle (18 decimals)
///      - `ETH/USD` comes from a Chainlink oracle (8 decimals)
///      Intermediate `stEthPerToken * (stETH/ETH) / 1e18` yields ETH per wstETH (i.e. the wstETH/ETH price,
///      18 decimals — note the stETH/ETH feed returns ETH per stETH); multiplying by ETH/USD and scaling by
///      1e18 yields the USD price (8 decimals).
///      Using the real stETH/ETH rate (rather than assuming stETH == ETH 1:1) keeps the price accurate and lets
///      ETH/USD cancel cleanly when NAV is quoted in ETH — the same pattern the L2 variant uses with a wstETH/ETH
///      feed.
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

    /// @notice Chainlink oracle for stETH to ETH (ETH per 1 stETH).
    AggregatorV3Interface public immutable STETH_TO_ETH_CHAINLINK_ORACLE;

    /// @notice Chainlink oracle for ETH to USD.
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the stETH/ETH Chainlink oracle.
    uint256 public immutable STETH_TO_ETH_CHAINLINK_HEARTBEAT;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 internal _decimals;

    //
    // Constructor
    //

    /// @param wstEth_ The address of the wstETH token.
    /// @param stEthToEthChainlinkOracle_ The address of the stETH to ETH Chainlink oracle.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param stEthToEthHeartbeat_ The time in seconds after which the stETH/ETH price is considered stale.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the ETH/USD price is considered stale.
    constructor(
        address wstEth_,
        address stEthToEthChainlinkOracle_,
        address ethToUsdChainlinkOracle_,
        uint256 stEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        WSTETH = OracleArgumentChecks.assertERC20Address(wstEth_);
        STETH_TO_ETH_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(stEthToEthChainlinkOracle_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        STETH_TO_ETH_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(stEthToEthHeartbeat_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
    //

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 stEthToEthRate,, uint256 stEthToEthUpdatedAt,) = STETH_TO_ETH_CHAINLINK_ORACLE.latestRoundData();
        (, int256 ethToUsdPrice,, uint256 ethToUsdUpdatedAt,) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (stEthToEthRate <= 0 || ethToUsdPrice <= 0) {
            return (0, true);
        }

        if (
            block.timestamp - stEthToEthUpdatedAt > STETH_TO_ETH_CHAINLINK_HEARTBEAT
                || block.timestamp - ethToUsdUpdatedAt > ETH_TO_USD_CHAINLINK_HEARTBEAT
        ) {
            stale = true;
        }

        uint256 stEthPerToken = IwstETH(WSTETH).stEthPerToken();

        if (stEthPerToken == 0) {
            return (0, true);
        }

        // stEthPerToken (18) * stETH/ETH (18) / 1e18 = ETH per wstETH (the wstETH/ETH price, 18 decimals)
        uint256 ethPerWstEth = stEthPerToken.mulDiv(
            uint256(stEthToEthRate), 10 ** STETH_TO_ETH_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor
        );
        // (ETH per wstETH, 18) * ETH/USD (8) / 1e18 = USD price (8 decimals)
        price = ethPerWstEth.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return WSTETH;
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

interface IwstETH {
    /// @notice Get amount of stETH for 1 wstETH (18 decimals).
    function stEthPerToken() external view returns (uint256);
}
