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
///      Note that `Appreciating` is exactly the mechanism that makes an asset unpeggable: a growing redemption rate on
///      a static balance moves the USD price off $1. Hence the empty `Pegged + Appreciating` cell below.
///
///      **Why two axes and not one enum.** A single enum forces a wrong answer on assets this repo already
///      registers, because peg and accrual vary independently:
///
///      | | `None` | `Rebasing` | `Appreciating` |
///      |---|---|---|---|
///      | `Pegged`   | USDC | aUSDC | *(unreachable — see below)* |
///      | `Floating` | WETH | stETH | wstETH, **sDAI**, sGHO, sUSDe, sUSDS |
///
///      **`sDAI` is `Floating`, not `Pegged`** — a yield-bearing wrapper has no peg. Its USD price is not $1 and rises
///      with its accrued yield, which is the same reason wstETH is `Floating`. This is not a judgement call: the repo's
///      pricing layer already encodes it. {PriceFeedLib}'s absolute peg guard is enabled per-asset by a non-zero
///      `pegToleranceBps`, described there as set "only on assets whose fundamental value is $1", and on mainnet it is
///      set on exactly the eight true stablecoins (USDC, USDS, USDT, DAI, GHO, USDe, RLUSD, crvUSD). The
///      yield-bearing family — sDAI, sGHO, sUSDe, sUSDS, syrupUSDC — instead carries `divergenceToleranceBps` plus
///      monitor feeds, i.e. byte-for-byte the wstETH treatment. `08_DeployAssetKindRegistry` asserts the two
///      authorities agree (`Pegged` ⇔ `pegToleranceBps > 0`) so they can never silently diverge again.
///
///      **The two empty cells are empty for DIFFERENT reasons. Do not conflate them.**
///      - `Pegged + Rebasing` — empty today but genuinely **REACHABLE**: an aToken for USDC has a growing balance at a
///        $1 price. No aToken is currently registered, and the first such registration legitimately occupies this cell,
///        so it is a supported combination and is covered by tests deliberately.
///      - `Pegged + Appreciating` — arguably **UNREACHABLE**, not merely unoccupied. If the redemption rate grows while
///        the balance is static, the USD price must rise above $1 — which is precisely what "not pegged" means. If you
///        believe you have found a member, you have probably found a `Floating + Appreciating` asset.
/// @author KPK
enum AccrualKind {
    None, // no intrinsic accrual: WETH, USDC, WBTC, ARB
    Rebasing, // balance grows: aTokens, stETH
    Appreciating // exchange rate grows: sDAI, wstETH, ERC-4626 shares
}
