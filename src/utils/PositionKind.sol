// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Semantic discriminator for a PositionBalance entry.
/// @dev Used by NAVCalculator consumers to branch on action family without string parsing.
///      `isDebt` on the enclosing PositionBalance is the canonical NAV-sign signal;
///      `PositionKind` provides human-readable category context on top of that.
///      Assignment rule: the kind reflects the OUTERMOST action family — what the account does to
///      enter/exit the position. A position exited via unstake is `Staking` regardless of what is
///      wrapped inside (e.g. gauge-staked LP); the inner exposure stays recoverable from
///      `protocolId`/`positionId`. LP principal sitting unstaked in the wallet is `Supplied`.
/// @author KPK
enum PositionKind {
    Wallet, // plain ERC20 / native-token balance held directly (ERC20DefaultBalanceAdapter)
    Supplied, // credit deployed into a protocol: lending supply, vault shares, unstaked LP principal
    Borrowed, // debt owed to a protocol (isDebt = true)
    Collateral, // credit locked as collateral (e.g. Aave reserve with usageAsCollateralEnabled = true)
    Staking, // staking principal: tokens locked behind an unstake action (Safety Module, Umbrella, StakeWise vaults, gauge/Convex-staked LP)
    Rewards, // accrued but not yet claimed reward tokens (e.g. CRV, CVX, BAL, COMP)
    Fees // uncollected protocol or LP fees (e.g. Uniswap V3 position fees)
}
