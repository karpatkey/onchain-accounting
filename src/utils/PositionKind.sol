// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @notice Semantic discriminator for a PositionBalance entry.
/// @dev Used by NAVCalculator consumers to branch on action family without string parsing.
///      `isDebt` on the enclosing PositionBalance is the canonical NAV-sign signal;
///      `PositionKind` provides human-readable category context on top of that.
enum PositionKind {
    Wallet, // plain ERC20 / native-token balance held directly (ERC20DefaultOracle)
    Supplied, // credit deployed into a protocol: lending supply, vault shares, LP principal
    Borrowed, // debt owed to a protocol (isDebt = true)
    Collateral, // credit locked as collateral (e.g. Aave reserve with usageAsCollateralEnabled = true)
    Staking, // staking principal: tokens locked in a staking contract (e.g. Safety Module, Umbrella).
            // NOTE: reserved for future migration — no adapter currently emits Staking; all staking
            // principals still use Supplied pending the per-adapter assignment pass.
    Rewards, // accrued but not yet claimed reward tokens (e.g. CRV, CVX, BAL, AURA, COMP)
    Fees // uncollected protocol or LP fees (e.g. Uniswap V3 position fees)
}
