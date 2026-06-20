// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";

/// @title rsETH Custom Price Oracle
/// @notice USD price of Kelp DAO's rsETH = `RsETHRateProvider.getLatestRate()` (rsETH/ETH, 18 dec) × Chainlink
///         ETH/USD.
/// @dev Shared skeleton (staleness, decimals, latestRoundData, the `rate × ETH/USD / 1e18` math) lives in
///      BaseCustomPriceFeed; this feed supplies only the rsETH rate via `_rate()`.
/// @author kpk
/* solhint-disable contract-name-camelcase */
contract rsETH_PriceOracle is BaseCustomPriceFeed {
    /// @notice Kelp DAO Multi-Chain Rate Provider (rsETH/ETH rate).
    IRsETHRateProvider public immutable RATE_PROVIDER;

    /// @param rsEth_ The address of the rsETH token.
    /// @param rateProvider_ The address of the Kelp DAO Multi-Chain Rate Provider.
    /// @param ethToUsdChainlinkOracle_ The address of the ETH to USD Chainlink oracle.
    /// @param ethToUsdChainlinkHeartbeat_ The time in seconds after which the price is considered stale if not updated.
    constructor(
        address rsEth_,
        address rateProvider_,
        address ethToUsdChainlinkOracle_,
        uint256 ethToUsdChainlinkHeartbeat_
    ) BaseCustomPriceFeed(rsEth_, ethToUsdChainlinkOracle_, ethToUsdChainlinkHeartbeat_) {
        RATE_PROVIDER = IRsETHRateProvider(OracleArgumentChecks.assertNonZeroAddress(rateProvider_));
    }

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return RATE_PROVIDER.getLatestRate();
    }
}

interface IRsETHRateProvider {
    /// @notice Get the latest rate of rsETH in terms of ETH (18 decimals).
    function getLatestRate() external view returns (uint256);
}
