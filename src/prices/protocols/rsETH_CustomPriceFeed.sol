// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CappedRateCustomPriceFeed} from "src/prices/CappedRateCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";

/// @title rsETH Custom Price Oracle (growth-capped)
/// @notice USD price of Kelp DAO's rsETH = `RsETHRateProvider.getLatestRate()` (ETH per rsETH, 18 dec) × the NAV's
///         ETH/USD price, with the rate growth-capped per ADR 0021 (cap config on the NAV; this feed is immutable).
/// @dev rsETH has no suitable Chainlink market feed on mainnet, so there is no market floor — growth-cap-only.
///      The Kelp rate provider exposes no timestamp, so a frozen rate cannot be detected; a REVERTING provider is
///      handled fail-to-stale (returns 0 → BaseCustomPriceFeed marks the price stale) rather than reverting the
///      whole NAV read. Supplies only `_rawRate()`; the cap/floor/base/USD math lives in CappedRateCustomPriceFeed.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract rsETH_CustomPriceFeed is CappedRateCustomPriceFeed {
    /// @notice Kelp DAO Multi-Chain Rate Provider (rsETH/ETH rate).
    IRsETHRateProvider public immutable RATE_PROVIDER;

    /// @param rsEth_ The address of the rsETH token.
    /// @param rateProvider_ The address of the Kelp DAO Multi-Chain Rate Provider.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price and cap config from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address rsEth_, address rateProvider_, address nav_, address baseAsset_)
        CappedRateCustomPriceFeed(rsEth_, nav_, baseAsset_, address(0), 0) // growth-cap-only, no market floor

    {
        RATE_PROVIDER = IRsETHRateProvider(OracleArgumentChecks.assertNonZeroAddress(rateProvider_));
    }

    /// @inheritdoc CappedRateCustomPriceFeed
    function _rawRate() internal view override returns (uint256) {
        try RATE_PROVIDER.getLatestRate() returns (uint256 r) {
            return r;
        } catch {
            return 0; // fail-to-stale: never DoS the NAV read on a reverting provider
        }
    }
}

interface IRsETHRateProvider {
    /// @notice Get the latest rate of rsETH in terms of ETH (18 decimals).
    function getLatestRate() external view returns (uint256);
}
