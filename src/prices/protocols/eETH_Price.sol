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

/// @title eETH Custom Price Oracle
/// @notice Returns the USD price of eETH by deriving eETH/ETH from weETH data and combining with ETH/USD.
/// @dev The price is computed as `price = (eETH/ETH) * (ETH/USD)`, where:
///      - `eETH/ETH = (weETH/ETH) ÷ (eETH/weETH)`
///      - `weETH/ETH` comes from Chainlink weETH/ETH oracle (18 decimals)
///      - `eETH/weETH` comes from weETH contract's `getRate()` function (18 decimals, eETH per weETH)
///      - `ETH/USD` comes from Chainlink oracle (8 decimals)
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract eETH_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice eETH token address.
    address public immutable EETH;

    /// @notice weETH token address (used to get weETH/eETH rate via getRate()).
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

    /// @param eEth_ The address of the eETH token.
    /// @param weEth_ The address of the weETH token (used to get weETH/eETH rate).
    /// @param weEthToEthChainlink_ The address of the weETH to ETH Chainlink oracle.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param weEthToEthHeartbeat_ The time in seconds after which the weETH/ETH price is considered stale.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the ETH/USD price is considered stale.
    constructor(
        address eEth_,
        address weEth_,
        address weEthToEthChainlink_,
        address ethToUsdChainlinkOracle_,
        uint256 weEthToEthHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        EETH = OracleArgumentChecks.assertERC20Address(eEth_);
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

        uint256 weEthToEEthRate = IweETH(WEETH).getRate();

        if (weEthToEEthRate == 0) {
            return (0, true);
        }

        if (
            block.timestamp - weEthToEthUpdatedAt > WEETH_TO_ETH_HEARTBEAT
                || block.timestamp - ethToUsdUpdatedAt > ETH_TO_USD_CHAINLINK_HEARTBEAT
        ) {
            stale = true;
        }

        // eETH/ETH = weETH/ETH ÷ eETH/weETH (both 18 dec → result 18 dec)
        uint256 eEthToEthRate = weEthToEthRate.toUint256().mulDiv(1e18, weEthToEEthRate, Math.Rounding.Floor);

        // eETH/ETH (18 dec) * ETH/USD (8 dec) / 1e18 = 8 dec
        price = eEthToEthRate.mulDiv(ethToUsdPrice.toUint256(), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return EETH;
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

interface IweETH {
    /// @notice Get amount of eETH per weETH (18 decimals). Used as divisor to derive eETH/ETH from weETH/ETH.
    function getRate() external view returns (uint256);
}
