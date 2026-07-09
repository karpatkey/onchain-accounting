// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title ETHx Custom Price Oracle
/// @notice USD price of Stader's ETHx = `StaderStakePoolsManager.getExchangeRate()` (ETH/ETHx, 18 dec) × the NAV's
///         ETH/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base/USD / 1e18`
///      math) lives in BaseCustomPriceFeed; this feed supplies only the Stader exchange rate via `_rate()`.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract ETHx_CustomPriceFeed is BaseCustomPriceFeed {
    /// @notice Stader StakePoolsManager (rate provider).
    IStaderStakePoolsManager public immutable STAKE_POOLS_MANAGER;

    /// @param ethx_ The address of the ETHx token.
    /// @param stakePoolsManager_ The address of the StaderStakePoolsManager (exposes getExchangeRate()).
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address ethx_, address stakePoolsManager_, address nav_, address baseAsset_)
        BaseCustomPriceFeed(ethx_, nav_, baseAsset_)
    {
        OracleArgumentChecks.assertNonZeroAddress(stakePoolsManager_);
        if (stakePoolsManager_.code.length == 0) revert InvalidArguments();
        STAKE_POOLS_MANAGER = IStaderStakePoolsManager(stakePoolsManager_);
    }

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return STAKE_POOLS_MANAGER.getExchangeRate();
    }
}

interface IStaderStakePoolsManager {
    /// @notice Returns the ETH-per-ETHx exchange rate (18 decimals).
    function getExchangeRate() external view returns (uint256);
}
