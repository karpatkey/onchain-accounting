// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ezETH L2 Custom Price Oracle
/// @notice Returns the USD price of ezETH on L2 using Renzo xRenzoDeposit.getRate() x Chainlink ETH/USD.
/// @dev price = xRenzoDeposit.getRate() * (ETH/USD) / 1e18. ETH/USD heartbeat checked.
/// @dev Staleness gap: xRenzoDeposit.getRate() returns a cross-chain rate relayed from L1 by a keeper.
///      Only the ETH/USD Chainlink heartbeat is verified here; the ezETH/ETH rate has no independent
///      age check. If Renzo's L1→L2 keeper lags (e.g., during sequencer downtime recovery) the returned
///      rate may be stale without this adapter detecting it. This is an architectural constraint of
///      xRenzoDeposit not exposing a rate timestamp; the L1 adapter carries an analogous limitation.
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ezETH_L2_CustomPriceFeed is ICustomPriceFeed {
    using Math for uint256;

    address public immutable EZETH;
    IxRenzoDeposit public immutable X_RENZO_DEPOSIT;
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;
    uint8 private immutable _decimals;

    constructor(
        address ezEth_,
        address xRenzoDeposit_,
        address ethToUsdChainlinkOracle_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        EZETH = OracleArgumentChecks.assertERC20Address(ezEth_);
        X_RENZO_DEPOSIT = IxRenzoDeposit(OracleArgumentChecks.assertNonZeroAddress(xRenzoDeposit_));
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
        uint256 ezEthRate = X_RENZO_DEPOSIT.getRate();
        if (ezEthRate == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        // ezETH/ETH rate is 18 decimals, ETH/USD is 8 decimals -> result is 8 decimals
        price = ezEthRate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc ICustomPriceFeed
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    /// @inheritdoc ICustomPriceFeed
    function underlyingAssetSupported() external view override returns (address) {
        return EZETH;
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

interface IxRenzoDeposit {
    function getRate() external view returns (uint256);
}
