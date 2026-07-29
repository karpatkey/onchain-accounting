// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";

/// @title ezETH L2 Custom Price Oracle
/// @notice Returns the USD price of ezETH on L2 as `ezETH/ETH × ETH/USD`, the Renzo `xRenzoDeposit.getRate()` rate
///         composed with the NAV's ETH/USD price.
/// @dev Thin {BaseCustomPriceFeed} subclass: `_rate()` is `xRenzoDeposit.getRate()` (ETH-per-ezETH, 18 decimals) and
///      the base composes it with the NAV's ETH/USD and applies the staleness gate.
/// @dev Staleness gap: `getRate()` returns a cross-chain rate relayed from L1 by a keeper. Only the NAV base/USD
///      staleness is verified; the ezETH/ETH rate has no independent age check. If Renzo's L1→L2 keeper lags (e.g.
///      during sequencer-downtime recovery) the returned rate may be stale without this adapter detecting it — an
///      architectural constraint of xRenzoDeposit not exposing a rate timestamp; the L1 adapter carries an analogous
///      limitation.
/// @author KPK
/* solhint-disable var-name-mixedcase, contract-name-camelcase */
contract ezETH_L2_CustomPriceFeed is BaseCustomPriceFeed {
    /// @notice Renzo xRenzoDeposit contract providing the cross-chain ezETH/ETH rate.
    IxRenzoDeposit public immutable X_RENZO_DEPOSIT;

    /// @param ezEth_ The ezETH token address.
    /// @param xRenzoDeposit_ The Renzo xRenzoDeposit contract (provides `getRate()`).
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address ezEth_, address xRenzoDeposit_, address nav_, address baseAsset_)
        BaseCustomPriceFeed(ezEth_, nav_, baseAsset_)
    {
        X_RENZO_DEPOSIT = IxRenzoDeposit(OracleArgumentChecks.assertNonZeroAddress(xRenzoDeposit_));
    }

    /// @inheritdoc BaseCustomPriceFeed
    /// @dev ETH-per-ezETH (18 decimals) from Renzo's cross-chain rate.
    function _rate() internal view override returns (uint256) {
        return X_RENZO_DEPOSIT.getRate();
    }
}

interface IxRenzoDeposit {
    function getRate() external view returns (uint256);
}
