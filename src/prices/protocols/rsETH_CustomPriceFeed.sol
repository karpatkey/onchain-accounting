// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";

/// @title rsETH Custom Price Oracle
/// @notice USD price of Kelp DAO's rsETH = `RsETHRateProvider.getLatestRate()` (ETH per rsETH, 18 dec) × the NAV's
///         ETH/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base/USD / 1e18`
///      math) lives in BaseCustomPriceFeed; this feed supplies only the rsETH rate via `_rate()`.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract rsETH_CustomPriceFeed is BaseCustomPriceFeed {
    /// @notice Kelp DAO Multi-Chain Rate Provider (rsETH/ETH rate).
    IRsETHRateProvider public immutable RATE_PROVIDER;

    /// @param rsEth_ The address of the rsETH token.
    /// @param rateProvider_ The address of the Kelp DAO Multi-Chain Rate Provider.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address rsEth_, address rateProvider_, address nav_, address baseAsset_)
        BaseCustomPriceFeed(rsEth_, nav_, baseAsset_)
    {
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
