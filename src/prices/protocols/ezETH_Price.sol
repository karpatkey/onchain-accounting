// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ezETH Custom Price Oracle
/// @notice Returns the USD price of ezETH using Renzo RestakeManager TVL / ezETH supply x Chainlink ETH/USD.
/// @dev price = (totalTVL / ezETHSupply) * (ETH/USD). calculateTVLs() may revert -- caught and marked stale.
/// @author kpk
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ezETH_PriceOracle is IPriceFeedCustom {
    using Math for uint256;

    address public immutable EZETH;
    IRestakeManager public immutable RESTAKE_MANAGER;
    AggregatorV3Interface public immutable ETH_TO_USD_CHAINLINK_ORACLE;
    uint256 public immutable ETH_TO_USD_CHAINLINK_HEARTBEAT;
    uint8 private _decimals;

    constructor(
        address ezEth_,
        address restakeManager_,
        address ethToUsdChainlinkOracle_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) {
        EZETH = OracleArgumentChecks.assertERC20Address(ezEth_);
        RESTAKE_MANAGER = IRestakeManager(OracleArgumentChecks.assertNonZeroAddress(restakeManager_));
        ETH_TO_USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(ethToUsdChainlinkOracle_);
        ETH_TO_USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(ethToUsdChainlinkHeartbeat_);
        _decimals = ETH_TO_USD_CHAINLINK_ORACLE.decimals();
    }

    /// @inheritdoc IPriceFeedCustom
    function getLatestPrice() external view override returns (uint256 price, bool stale) {
        (, int256 ethToUsdPrice,, uint256 ethToUsdUpdatedAt,) = ETH_TO_USD_CHAINLINK_ORACLE.latestRoundData();

        if (ethToUsdPrice <= 0) {
            return (0, true);
        }

        if (block.timestamp - ethToUsdUpdatedAt > ETH_TO_USD_CHAINLINK_HEARTBEAT) {
            stale = true;
        }

        uint256 ezEthRate;
        try RESTAKE_MANAGER.calculateTVLs() returns (uint256[][] memory, uint256[] memory, uint256 totalTVL) {
            uint256 supply = IERC20(EZETH).totalSupply();
            if (supply == 0) {
                return (0, true);
            }
            ezEthRate = totalTVL.mulDiv(1e18, supply, Math.Rounding.Floor);
        } catch {
            return (0, true);
        }

        if (ezEthRate == 0) {
            return (0, true);
        }

        // ezETH/ETH rate is 18 decimals, ETH/USD is 8 decimals -> result is 8 decimals
        price = ezEthRate.mulDiv(uint256(ethToUsdPrice), 1e18, Math.Rounding.Floor);
    }

    /// @inheritdoc IPriceFeedCustom
    function underlyingAssetSupported() external view override returns (address) {
        return EZETH;
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

interface IRestakeManager {
    function calculateTVLs()
        external
        view
        returns (
            uint256[][] memory operatorDelegatorTokenTVLs,
            uint256[] memory operatorDelegatorTVLs,
            uint256 totalTVL
        );
}
