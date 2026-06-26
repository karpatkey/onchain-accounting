// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ezETH Custom Price Oracle
/// @notice USD price of Renzo's ezETH = (RestakeManager TVL / ezETH supply) (ETH per ezETH, 18 dec) × Chainlink ETH/USD.
/// @dev Shared skeleton (staleness, decimals, latestRoundData, the `rate × ETH/USD / 1e18` math) lives in
///      BaseCustomPriceFeed; `_rate()` derives the ezETH/ETH rate from Renzo and returns 0 (→ stale) if
///      `calculateTVLs()` reverts or supply is 0.
/// @dev Staleness gap: calculateTVLs() reads Renzo's internal oracles, whose freshness is not independently
///      checked here. Only the ETH/USD Chainlink heartbeat is verified. This is an architectural constraint of
///      Renzo on mainnet; the L2 adapter (ezETH_L2_Price) avoids this by using xRenzoDeposit.getRate() directly.
/// @author kpk
/* solhint-disable contract-name-camelcase */
contract ezETH_CustomPriceFeed is BaseCustomPriceFeed {
    using Math for uint256;

    /// @notice Renzo RestakeManager (exposes calculateTVLs()).
    IRestakeManager public immutable RESTAKE_MANAGER;

    constructor(
        address ezEth_,
        address restakeManager_,
        address ethToUsdChainlinkOracle_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) BaseCustomPriceFeed(ezEth_, ethToUsdChainlinkOracle_, ethToUsdChainlinkHeartbeat_) {
        RESTAKE_MANAGER = IRestakeManager(OracleArgumentChecks.assertNonZeroAddress(restakeManager_));
    }

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        try RESTAKE_MANAGER.calculateTVLs() returns (uint256[][] memory, uint256[] memory, uint256 totalTVL) {
            uint256 supply = IERC20(UNDERLYING).totalSupply();
            if (supply == 0) return 0;
            return totalTVL.mulDiv(1e18, supply, Math.Rounding.Floor);
        } catch {
            return 0;
        }
    }
}

interface IRestakeManager {
    function calculateTVLs() external view returns (uint256[][] memory, uint256[] memory, uint256);
}
