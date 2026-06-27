# M-01: UniswapV3/PancakeSwapV3 fee-growth branch selected via oracle-implied tick, not pool tick — can over-report or under-report unclaimed fees

## Summary

`UniswapV3PoolsMetaBalanceAdapter._computeFees` selects which feeGrowthInside formula to apply based on `sqrtPriceX96` reconstructed from oracle prices, while the pool's stored `feeGrowthOutside` values in each tick's state are anchored to the pool's ACTUAL current tick. When the oracle-implied price disagrees with the pool's real price enough to cross a position's tick boundary, the wrong branch is used and the wrapped-unchecked arithmetic can yield a fee value that is orders of magnitude too large.

## Vulnerability Detail

### Root Cause

The pool's `feeGrowthOutside` tick-level accounting is updated when the pool crosses a tick at its real price. The correct formula for `feeGrowthInside` at any moment depends on where the ACTUAL pool tick is relative to the position's range. The adapter substitutes the oracle-reconstructed `sqrtPriceX96` for the actual pool tick to prevent manipulation of the liquidity split, but this substitution is also applied to the fee-growth branch selection.

### Code Location
- File: `src/balances/AssistedBalanceAdapters/UniswapV3PoolsMetaBalanceAdapter.sol`
- Function: `_computeFees`
- Lines: 214–248

```solidity
// @audit branch selected via oracle-derived sqrtPriceX96, but fgOutLower/fgOutUpper are
// anchored to the pool's real tick crossings — mismatch when oracle diverges across boundary
if (sqrtPriceX96 < sqrtLower) {
    fgInside0 = fgOutLower0 - fgOutUpper0;   // formula correct only when pool tick < tickLower
    fgInside1 = fgOutLower1 - fgOutUpper1;
} else if (sqrtPriceX96 < sqrtUpper) {
    fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0;
    fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1;
} else {
    fgInside0 = fgOutUpper0 - fgOutLower0;   // formula correct only when pool tick >= tickUpper
    fgInside1 = fgOutUpper1 - fgOutLower1;
}

// @audit unchecked subtraction: if wrong fgInside < fgInside0Last the wrap yields ~2^256
f0 = Math.mulDiv(fgInside0 - fgInside0Last, liquidity, FixedPoint128.Q128) + tokensOwed0;
f1 = Math.mulDiv(fgInside1 - fgInside1Last, liquidity, FixedPoint128.Q128) + tokensOwed1;
```

Compare to `UniswapV3PoolLib._computeFees` (lines 202–218) which correctly uses the pool's real `tickCurrent` for the branch, noting it reads `tickCurrent` from `slot0`.

### The over-report path

1. Position range: tickLower = T_L, tickUpper = T_U.
2. Pool real current tick ≥ T_U (position out of range, above). The pool has therefore crossed T_U, and the tick-level `feeGrowthOutside` values reflect this. Correct formula: `fgInside0 = fgOutUpper0 - fgOutLower0`.
3. Oracle-reconstructed `sqrtPriceX96 < sqrtLower` (oracle reports a price below the lower bound of the position, due to a stale or lagging feed relative to the pool's real price).
4. Adapter applies: `fgInside0 = fgOutLower0 - fgOutUpper0`.
5. After tick T_U crossing, `fgOutUpper0 > fgOutLower0`, so `fgOutLower0 - fgOutUpper0` wraps in unchecked to a value near `2^256`.
6. `Math.mulDiv((~2^256) - fgInside0Last, liquidity, Q128)` may revert (mulDiv overflow) or produce a grossly inflated fee amount.
7. NAVCalculator does NOT wrap `getAdapterPositions` in a try/catch that would silently drop the fee legs — the MetaBalanceAdapter's `_positionsForInstances` does wrap `instancePositions` per pool via `this.instancePositions(...)`, so an overflow-revert would drop the entire pool's position, but a non-reverting large value would be emitted as the reported fee balance.

## Impact
- **Likelihood**: Low — requires oracle price to diverge from pool price enough to cross a tick boundary. This can occur during oracle staleness windows, high-volatility periods, or cross-chain bridge lag.
- **Impact**: High — when the arithmetic does not revert, the reported fee for an NFT position can be massively overstated, inflating the account's reported NAV. When it reverts, the entire pool instance silently drops from NAV (under-report). Both violate the family invariant.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- Account holds a Uniswap V3 LP NFT in a pool where the price has moved substantially.
- The pool's real tick is above the position's `tickUpper` (price moved up out of range).
- The Chainlink feed for one of the tokens is at the end of its heartbeat / stale window, still reporting the old (lower) price.

### Attack Steps
1. Wait for or cause pool price to move above the position's `tickUpper`. The pool's `feeGrowthOutside` values on `tickUpper` and `tickLower` now reflect the above-range state.
2. At NAV read time, one or both oracle prices have not yet updated (stale within the allowed staleness window).
3. The oracle-reconstructed `sqrtPriceX96` falls in the below-range region (`sqrtPriceX96 < sqrtLower`).
4. Adapter computes `fgInside0 = fgOutLower0 - fgOutUpper0`, where `fgOutLower0 < fgOutUpper0` (since pool crossed T_U). Unchecked wrap yields a value ≈ `2^256 - delta`.
5. `(fgInside0 - fgInside0Last)` is also huge; if `mulDiv` does not overflow (depends on `liquidity` magnitude), the fee leg is emitted with an astronomically large token amount.
6. NAVCalculator prices this at the Chainlink price and adds it to the account's reported NAV.

### Expected Impact
- Account's reported NAV is materially overstated (potentially by orders of magnitude) for the duration of the oracle divergence window.
- Alternatively, if `mulDiv` overflows and reverts, the entire pool instance drops from NAV (under-report), which violates the under-report-only family invariant in the opposite direction.

## Recommended Mitigation

For fee computation, use the pool's actual `slot0.tick` (or `slot0.sqrtPriceX96`) for the branch selection, not the oracle-reconstructed price. The oracle-derived price should only be used for the principal liquidity split (where manipulation resistance is important). The fee growth calculation cannot be manipulated by moving the pool's tick because the `fgGrowthInside` formula correctly accounts for the tick-crossing history; the security concern for fees is the magnitude (governed by on-chain accumulation), not the branch.

Alternatively, compute the feeGrowthInside directly from the pool's tick-level state using the real pool `slot0.sqrtPriceX96` / `slot0.tick` only for the branch decision, while keeping the principal liquidity split oracle-driven.

---

## CORRECTION (post-review) — recommendation revised

The original recommendation here (use the pool's real `slot0.tick` for the fee branch) is **superseded**. The adapter deliberately never reads `slot0` — both for manipulation resistance (prior `[2]` finding) and for PancakeSwap-V3 ABI compatibility (`UniswapV3PoolsMetaBalanceAdapter.sol:28-34`). Using `slot0.tick` would regress both.

**Revised fix (oracle-only preserving):** bound the inside-growth delta — a position's inside fee-growth can never exceed the pool's global fee-growth, so clamp:
```solidity
uint256 d0 = fgInside0 - fgInside0Last;   // unchecked
if (d0 > fgGlobal0) d0 = 0;               // inconsistent branch / wrap → no phantom fees
f0 = Math.mulDiv(d0, liquidity, FixedPoint128.Q128) + tokensOwed0;   // (same for d1/f1)
```
Accurate fees in the normal case; conservative 0 (safe under-report) on oracle/pool divergence; no `slot0`, PancakeSwap-V3-compatible. See docs/audits/2026-06-vigilo-adapter-audit.md §M-A1.

---

## RESOLUTION (implemented) — tokensOwed-only

A follow-up code review showed the `fgGlobal` clamp is only a partial fix (a branch mismatch can yield a plausible delta ≤ fgGlobal that still over-reports). Final fix: the fee legs now report **only the position's settled `tokensOwed0/1`**; the tick-dependent `feeGrowthInside` component is dropped entirely. Provably never over-reports, fully oracle-only (no slot0), PancakeSwap-V3-compatible. Accepted cost: under-reports uncollected fees on un-poked positions (safe direction). See docs/audits/2026-06-vigilo-adapter-audit.md §M-A1.
