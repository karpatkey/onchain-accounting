// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @notice Semantic discriminator for a PositionBalance entry.
/// @dev Used by NAVCalculator consumers to branch on action family without string parsing.
///      `isDebt` on the enclosing PositionBalance is the canonical NAV-sign signal;
///      `PositionKind` provides human-readable category context on top of that.
enum PositionKind {
    Wallet, // plain ERC20 / native-token balance held directly (ERC20DefaultOracle)
    Supplied, // credit deployed into a protocol: lending supply, vault shares, staking principal, LP principal
    Borrowed, // debt owed to a protocol (isDebt = true)
    Collateral, // credit locked as collateral (e.g. Aave reserve with usageAsCollateralEnabled = true)
    Earned // accrued but not yet claimed: rewards, uncollected LP fees
}
