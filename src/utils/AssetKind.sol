// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice What an asset's PRICE tracks, relative to the NAV's quote asset.
/// @dev `Pegged` means pegged to the **quote asset** (USD for a `quoteAsset == address(0)` read) — not "pegged to
///      something". So USDC/USDT/DAI/USDe are `Pegged`; **wstETH is `Floating`**, even though it is rigidly related to
///      stETH, because its USD price moves with ETH.
///
///      The axis is not cosmetic: it correlates with an operational property. A zero-heartbeat-margin staleness
///      condition bites HEARTBEAT-DRIVEN feeds, and a pegged asset can sit quietly at its peg until its heartbeat
///      lapses, whereas an asset that moves usually republishes on its **deviation threshold** first so the heartbeat
///      never binds. Note "deviation" (the feed's own publish trigger), NOT `divergenceToleranceBps` — that is this
///      repo's separate cross-feed comparison and does not cause a feed to publish.
///
///      It is a correlation, not a law: the exposure follows the feed's publish behaviour, not the peg, and there are
///      `Floating` feeds in this repo that the same condition reached. Do not use this axis as a staleness oracle.
///      An axis that predicts which feeds a class of failure reaches is an axis worth having. (It is not STORED: see
///      the derivation note on {AccrualKind} — `AssetKindRegistry` computes it from the NAV's `pegToleranceBps`.)
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
///      a static balance moves the USD price off $1. Hence the `Pegged + Appreciating` cell being empty in practice.
///
///      **Why two axes and not one enum.** A single enum forces a wrong answer on assets this repo already
///      registers, because peg and accrual vary independently:
///
///      | | `None` | `Rebasing` | `Appreciating` |
///      |---|---|---|---|
///      | `Pegged`   | USDC | aUSDC | *(cannot be asserted — see below)* |
///      | `Floating` | WETH | stETH | wstETH, **sDAI**, sGHO, sUSDe, sUSDS |
///
///      **`sDAI` is `Floating`, not `Pegged`** — a yield-bearing wrapper has no peg. Its USD price is not $1 and rises
///      with its accrued yield, which is the same reason wstETH is `Floating`. This is not a judgement call: the repo's
///      pricing layer already encodes it. {PriceFeedLib}'s absolute peg guard is enabled per-asset by a non-zero
///      `pegToleranceBps`, described there as set "only on assets whose fundamental value is $1", and across the seven
///      configured chains it is set on exactly 25 rows — the true stablecoins (on mainnet: USDC, USDS, USDT, DAI, GHO,
///      USDe, RLUSD, crvUSD). **No yield-bearing wrapper carries it** — not sDAI, sGHO, sUSDe, sUSDS or syrupUSDC —
///      which is the discriminator, and it holds for every one of them.
///
///      Be careful not to over-state the parallel: only `sUSDe` additionally gets wstETH's exact treatment
///      (`divergenceToleranceBps` + monitor feeds); sGHO, sUSDS and syrupUSDC carry neither, because no independent
///      market feed exists for them. And `sDAI` is not a mainnet-registered asset at all — it is configured only on
///      Gnosis (chain 100). So the shared fact is the ABSENCE of a peg tolerance, not the presence of divergence
///      monitoring. There is no longer anything to keep in agreement: the peg axis is DERIVED from `pegToleranceBps`,
///      so a classification contradicting the pricing layer is not merely detectable — the contradictory sentence is
///      unwriteable. (An earlier revision asserted `Pegged` ⇔ `pegToleranceBps > 0` in `08`; that guard is deleted,
///      because a guard against a state the type system cannot express is dead code that reads as protection.)
///
///      **`Pegged + Appreciating` can no longer be ASSERTED — but be precise about what that does and does not mean.**
///      The peg axis is not stored, so there is no parameter with which to claim an appreciating asset is pegged; the
///      contradiction that used to be expressible in config is now unwriteable. That is the real gain.
///
///      It is NOT the same as the cell being unreachable. If an operator sets a non-zero `pegToleranceBps` on an asset
///      stored as `Appreciating`, the pair reads back `Pegged + Appreciating` — because the peg is computed from that
///      tolerance. What changed is WHERE such a state comes from: it can only arise from a real pricing decision on the
///      NAV, never from a mistyped classification, and it is then a true report of the NAV's own configuration rather
///      than a second opinion contradicting it. (No test pins this: it is a property of where the value comes from, not
///      a branch the registry can be made to take — the registry stores no peg to assert against.)
///
///      **`Pegged + Rebasing` remains real and REACHABLE.** An aToken for USDC has a growing balance at a $1 price and
///      carries a peg tolerance, so it derives `Pegged` and stores `Rebasing`. No aToken is registered today; the first
///      one legitimately occupies this cell.
///
/// @author KPK
enum AccrualKind {
    None, // no intrinsic accrual: WETH, USDC, WBTC, ARB
    Rebasing, // balance grows: aTokens, stETH
    Appreciating // exchange rate grows: sDAI, wstETH, ERC-4626 shares
}
