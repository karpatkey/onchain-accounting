// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title LDO Custom Price Oracle
/// @notice This contract provides the price of LDO.
/// @dev The price is calculated by fetching the LDO/ETH price from a Chainlink oracle, and then converting it to USD
/// using another Chainlink oracle for ETH/USD.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract LDO_PriceOracle is IPriceFeedCustom {
    //
    // Libraries
    //
    using SafeCast for uint256;
    using SafeCast for int256;
    using Math for uint256;

    //
    // State
    //

    /// @notice LDO token address
    address public immutable LDO;

    /// @notice Chainlink oracle for LDO to ETH
    AggregatorV3Interface public immutable LDO_TO_ETH_CHAINLINK_ORACLE;

    /// @notice Chainlink oracle for ETH to USD
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;

    /// @notice The heartbeat interval for the LDO/ETH Chainlink oracle.
    uint256 public immutable LDO_TO_ETH_CHAINLINK_HEARTBEAT;

    /// @notice The heartbeat interval for the ETH/USD Chainlink oracle.
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;

    /// @notice Number of decimals the returned price is represented with.
    uint8 private immutable _decimals;

    //
    // Constructor
    //

    /// @param ldo_ The address of the LDO token.
    /// @param ldoToEthChainlinkAddress_ The address of the LDO to ETH Chainlink aggregator.
    /// @param ethToUsdChainlinkAddress_ The address of the ETH to USD Chainlink aggregator.
    /// @param ldoToEthChainlinkHeartbeat_ The time in seconds after which the LDO/ETH price is considered stale if
    /// not updated.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the ETH/USD price is considered stale if
    /// not updated.
    constructor(
        address ldo_,
        address ldoToEthChainlinkAddress_,
        address ethToUsdChainlinkAddress_,
        uint256 ldoToEthChainlinkHeartbeat_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        LDO = OracleArgumentChecks.assertERC20Address(ldo_);

        LDO_TO_ETH_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ldoToEthChainlinkAddress_);
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkAddress_);

        LDO_TO_ETH_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ldoToEthChainlinkHeartbeat_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);

        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    //
    // IPriceFeedCustom
    //

    function _compute()
        private
        view
        returns (uint256 price, bool stale, uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint80 r1, int256 ldoToEthPrice, uint256 s1, uint256 u1, uint80 ar1) =
            LDO_TO_ETH_CHAINLINK_ORACLE.latestRoundData();
        (uint80 r2, int256 ethToUsdPrice, uint256 s2, uint256 u2, uint80 ar2) =
            ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (u1 <= u2) {
            (roundId, startedAt, updatedAt, answeredInRound) = (r1, s1, u1, ar1);
        } else {
            (roundId, startedAt, updatedAt, answeredInRound) = (r2, s2, u2, ar2);
        }

        if (ldoToEthPrice <= 0 || ethToUsdPrice <= 0) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }

        // Check if either price is stale based on their respective heartbeats
        uint256 effectiveLdoUpdatedAt = u1 > block.timestamp ? block.timestamp : u1;
        uint256 effectiveEthUpdatedAt = u2 > block.timestamp ? block.timestamp : u2;
        if (
            block.timestamp - effectiveLdoUpdatedAt >= LDO_TO_ETH_CHAINLINK_HEARTBEAT
                || block.timestamp - effectiveEthUpdatedAt >= ETH_TO_USD_CHAINLINK_HEARTBEAT
        ) { return (0, true, roundId, startedAt, updatedAt, answeredInRound); }

        // LDO/ETH price is in 8 decimals, ETH/USD price is in 8 decimals
        // First multiply the prices together (this will have 8 + 8 = 16 decimals)
        // Then divide by 10^8 to get back to 8 decimals (matching ETH/USD)
        price = ldoToEthPrice.toUint256()
            .mulDiv(ethToUsdPrice.toUint256(), 10 ** LDO_TO_ETH_CHAINLINK_ORACLE.decimals(), Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc IPriceFeedCustom
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return LDO;
    }

    /// @inheritdoc IPriceFeedCustom
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
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
