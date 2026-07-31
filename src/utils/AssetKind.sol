// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice What an asset's PRICE tracks, relative to the NAV's quote asset.
/// @dev `Pegged` means pegged to the **quote asset** (USD for a `quoteAsset == address(0)` read) — not "pegged to
///      something". So USDC/USDT/DAI/USDe are `Pegged`; **wstETH is `Floating`**, even though it is rigidly related to
///      stETH, because its USD price moves with ETH.
///
///      The axis is not cosmetic: it predicts an operational property. A zero-heartbeat-margin staleness condition
///      bites `Pegged` feeds and not `Floating` ones, because a floating asset's divergence threshold fires long
///      before its heartbeat expires, while a pegged asset can sit quietly at its peg until the heartbeat lapses.
///      An axis that predicts which feeds a class of failure reaches is an axis worth storing.
/// @author KPK
enum PegKind {
    Pegged, // tracks the quote asset (USD): USDC, USDT, DAI, USDe, GHO
    Floating // moves against the quote asset: WETH, wstETH, rETH, WBTC, ARB
}

/// @notice HOW an asset accrues value, if it accrues at all. Orthogonal to {PegKind}.
/// @dev `Rebasing` = the BALANCE grows while the unit price stays put (aTokens, stETH). `Appreciating` = the
///      exchange RATE grows while the balance is static (sDAI, wstETH, ERC-4626 shares). `None` = neither; value
///      changes only with the market price.
///
///      **Why two axes and not one enum.** A single enum forces a wrong answer on assets this repo already
///      registers, because peg and accrual vary independently. All six cells are real:
///
///      | | `None` | `Rebasing` | `Appreciating` |
///      |---|---|---|---|
///      | `Pegged`   | USDC | aUSDC | sDAI |
///      | `Floating` | WETH | stETH | wstETH |
///
///      Note `Pegged + Rebasing` has **no registered member today** — no aToken is currently registered — but the
///      cell is reachable and the first aToken registration is a plausible near-term event, so it is a supported
///      combination rather than a hypothetical one, and it is covered by tests.
/// @author KPK
enum AccrualKind {
    None, // no intrinsic accrual: WETH, USDC, WBTC, ARB
    Rebasing, // balance grows: aTokens, stETH
    Appreciating // exchange rate grows: sDAI, wstETH, ERC-4626 shares
}
