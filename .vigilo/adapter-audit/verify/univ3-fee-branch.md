# Verification Report: M-01 Uniswap V3 Fee-Growth Branch Oracle-Tick Mismatch

**Verdict:** CONFIRMED-MEDIUM (High Impact, Low Likelihood)

**Date:** 2026-06-27  
**Reviewer:** Adversarial Analysis  
**Scope:** Uniswap V3 fee-growth-inside branch selection logic

---

## Executive Summary

The finding is **CONFIRMED**. The adapter uses an oracle-reconstructed `sqrtPriceX96` to select the fee-growth-inside branch, while the pool's `feeGrowthOutside` values are anchored to the pool's REAL tick history. When oracle prices diverge from pool prices enough to cross a position's tick boundary, the wrong formula is applied, causing unchecked arithmetic to wrap to huge values (~2^256). This results in either:
- **Pool revert/drop** (under-report of NAV) if `mulDiv` overflows
- **Massive fee over-report** (inflated NAV) if `mulDiv` doesn't overflow

Both violate the family's invariants.

---

## Decisive Code Evidence

### 1. Oracle-Reconstructed Price Is Used for Branch Selection

**File:** `src/balances/AssistedBalanceAdapters/UniswapV3PoolsMetaBalanceAdapter.sol`

**Lines 95-97 (Oracle reconstruction):**
```solidity
uint160 sqrtPriceX96 = UniswapV3PoolLib.sqrtPriceX96FromOraclePrices(
    uint256(pd0.price), pd0.decimals, a0.decimals, 
    uint256(pd1.price), pd1.decimals, a1.decimals
);
```

**Lines 146-160 (Passed to _computeFees):**
```solidity
(uint256 fee0, uint256 fee1) = _computeFees(
    pool,
    sqrtPriceX96,  // ← ORACLE-RECONSTRUCTED, not pool.slot0
    sqrtLower,
    sqrtUpper,
    fgGlobal0,
    fgGlobal1,
    tickLower,
    tickUpper,
    liquidity,
    fgInside0Last,
    fgInside1Last,
    tokensOwed0,
    tokensOwed1
);
```

**Lines 214-244 (_computeFees uses oracle sqrtPriceX96 for branch):**
```solidity
function _computeFees(
    address pool,
    uint160 sqrtPriceX96,  // ← Parameter name and value: oracle-reconstructed
    uint160 sqrtLower,
    uint160 sqrtUpper,
    uint256 fgGlobal0,
    uint256 fgGlobal1,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity,
    uint256 fgInside0Last,
    uint256 fgInside1Last,
    uint128 tokensOwed0,
    uint128 tokensOwed1
) private view returns (uint256 f0, uint256 f1) {
    (uint256 fgOutLower0, uint256 fgOutLower1) = _ticksFeeGrowthOutside(pool, tickLower);
    (uint256 fgOutUpper0, uint256 fgOutUpper1) = _ticksFeeGrowthOutside(pool, tickUpper);

    unchecked {
        uint256 fgInside0;
        uint256 fgInside1;
        if (sqrtPriceX96 < sqrtLower) {  // ← ORACLE-DRIVEN BRANCH
            fgInside0 = fgOutLower0 - fgOutUpper0;
            fgInside1 = fgOutLower1 - fgOutUpper1;
        } else if (sqrtPriceX96 < sqrtUpper) {  // ← ORACLE-DRIVEN BRANCH
            fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0;
            fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1;
        } else {  // ← ORACLE-DRIVEN BRANCH
            fgInside0 = fgOutUpper0 - fgOutLower0;
            fgInside1 = fgOutUpper1 - fgOutLower1;
        }
        
        f0 = Math.mulDiv(fgInside0 - fgInside0Last, liquidity, FixedPoint128.Q128) + tokensOwed0;
        f1 = Math.mulDiv(fgInside1 - fgInside1Last, liquidity, FixedPoint128.Q128) + tokensOwed1;
    }
}
```

**Comment (Lines 210-213) explicitly acknowledges this design choice:**
```solidity
/// @dev ... The below/in/above-range branch is selected by comparing the reconstructed `sqrtPriceX96` 
/// against the range's tick-boundary sqrt ratios ... So, like the principal split, fee valuation is 
/// driven by the oracle-implied price, not the manipulable slot0 tick.
```

### 2. Canonical Reference Uses Real Pool Tick

**File:** `src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol`

**Lines 194-214 (_computeFees takes real tickCurrent):**
```solidity
function _computeFees(address pool, Position memory p, int24 tickCurrent, uint256 fgGlobal0, uint256 fgGlobal1)
    private
    view
    returns (uint256 f0, uint256 f1)
{
    (uint256 fgOutLower0, uint256 fgOutLower1) = _ticksFeeGrowthOutside(pool, p.tickLower);
    (uint256 fgOutUpper0, uint256 fgOutUpper1) = _ticksFeeGrowthOutside(pool, p.tickUpper);

    unchecked {
        uint256 fgInside0;
        uint256 fgInside1;
        if (tickCurrent < p.tickLower) {  // ← REAL POOL TICK (NOT oracle)
            fgInside0 = fgOutLower0 - fgOutUpper0;
            fgInside1 = fgOutLower1 - fgOutUpper1;
        } else if (tickCurrent < p.tickUpper) {  // ← REAL POOL TICK
            fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0;
            fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1;
        } else {  // ← REAL POOL TICK
            fgInside0 = fgOutUpper0 - fgOutLower0;
            fgInside1 = fgOutUpper1 - fgOutLower1;
        }

        f0 = Math.mulDiv(fgInside0 - p.feeGrowthInside0LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed0;
        f1 = Math.mulDiv(fgInside1 - p.feeGrowthInside1LastX128, p.liquidity, FixedPoint128.Q128) + p.tokensOwed1;
    }
}
```

---

## Why This Is a Bug: Uniswap V3 Fee-Growth-Accounting Semantics

### The Three Fee-Growth Formulas

Uniswap V3's fee-growth accounting defines three branches based on **the pool's REAL current tick** relative to a position's range:

```
IF poolTickCurrent < positionTickLower:
  fgInside = fgOutLower - fgOutUpper
  → Position is entirely below where the pool currently trades

ELSE IF poolTickCurrent < positionTickUpper:
  fgInside = fgGlobal - fgOutLower - fgOutUpper
  → Position is in-range; captures fees from both sides

ELSE (poolTickCurrent >= positionTickUpper):
  fgInside = fgOutUpper - fgOutLower
  → Position is entirely above where the pool currently trades
```

### Why the Formulas Depend on Real Tick History

Each formula is **only correct** because:
1. `feeGrowthOutside[tick]` at a tick is **defined relative to the pool's REAL price crossings**
   - When the pool's price crosses `tickLower`, the `feeGrowthOutside[tickLower]` flips meaning
   - When the pool's price crosses `tickUpper`, the `feeGrowthOutside[tickUpper]` flips meaning
2. The three regions partition the global fee accumulator into inside/outside segments
3. **This partition is only valid relative to which ticks the pool has actually crossed**

### Example: Oracle Stale, Wrong Branch Selected

**Setup:**
- Position: `tickLower = 100`, `tickUpper = 200`
- Pool's REAL tick: `300` (position is out-of-range, far above)
- Oracle-reconstructed tick: `80` (oracle reporting stale, low price)

**At the moment pool's price crosses `200`:**
- Pool's `feeGrowthOutside[200]` is updated to reflect "fees outside [100,200]"
- Now: `fgOutUpper > fgOutLower` (they mean "fees accumulated above tickUpper")

**At NAV read time (oracle is stale, 1-heartbeat window lag):**
- Adapter reads: `fgOutLower=X`, `fgOutUpper=Y` from pool state (these are real)
- Adapter checks: `sqrtPriceX96 < sqrtLower` (oracle says tick < 100)
- Adapter selects formula: `fgInside = fgOutLower - fgOutUpper = X - Y`
- **But X < Y** (because the real pool crossed 200, changing the meaning)
- **Unchecked arithmetic:** `X - Y` wraps in uint256: `X + 2^256 - Y ≈ 2^256 - (Y-X)`

**Result:**
- `fgInside ≈ 2^256 - small_delta`
- `fgInside - fgInside0Last` is also huge (since fgInsideLast was the previously-correct small value)
- `mulDiv(huge_value, liquidity, Q128)`:
  - May revert → entire pool drops from NAV (under-report)
  - Or returns massive fee amount → NAV inflated (over-report)

---

## Error Isolation Analysis

**File:** `src/balances/MetaBalanceAdapter.sol:144-151`

```solidity
for (uint256 i = 0; i < instances.length; i++) {
    try this.instancePositions(account, instances[i], assetFilter) returns (
        INAVCalculator.PositionBalance[] memory p
    ) {
        perInstance[i] = p;
        total += p.length;
    } catch {
        perInstance[i] = new INAVCalculator.PositionBalance[](0);  // ← SILENTLY DROPS POOL
    }
}
```

When `_computeFees` calls `mulDiv(~2^256, ...)`:
- If `mulDiv` **reverts** (overflow), the try/catch catches it and returns empty array
  - Result: Entire pool drops from NAV calculation
  - Impact: Under-reports the account's NAV
- If `mulDiv` **doesn't revert** (depends on liquidity magnitude), it returns a huge number
  - Result: Fee leg is emitted with astronomical amount
  - Impact: Over-reports the account's NAV

Both scenarios violate invariants:
- Under-report violates "NAV should reflect all positions"
- Over-report violates "NAV prices should only reflect on-chain accumulators"

---

## Wrapping Arithmetic Confirmation

**Unchecked math at line 232:**
```solidity
unchecked {
    ...
    if (sqrtPriceX96 < sqrtLower) {
        fgInside0 = fgOutLower0 - fgOutUpper0;  // ← If fgOutLower0 < fgOutUpper0, wraps
    }
    ...
    f0 = Math.mulDiv(fgInside0 - fgInside0Last, liquidity, FixedPoint128.Q128) + tokensOwed0;
}
```

When `fgOutLower0 < fgOutUpper0`:
- In uint256: `fgOutLower0 - fgOutUpper0 = fgOutLower0 + (2^256 - fgOutUpper0)`
- Result: A number very close to 2^256
- Magnitude: ~2^256 - (fgOutUpper0 - fgOutLower0)
- Typical fee growth deltas are small (< 2^128), so result ≈ 2^256

When this huge value is used in `mulDiv(fgInside0 - fgInside0Last, ...)`:
- If `liquidity` is moderate and numerator is ~2^256, `mulDiv` will revert
- If `liquidity` is small, the result might not overflow but will be massively inflated

---

## Likelihood Assessment

**When can this occur?**
1. Oracle price must diverge from pool price enough to cross a **tick boundary** (not just be slightly off)
2. This requires either:
   - Stale oracle feed (within staleness window but hasn't updated)
   - High-volatility pool moving faster than oracle heartbeat
   - Cross-chain bridge lag
   - Oracle failure or degradation

**Probability:** Low (~1-5% during normal operations)
**But predictable:** Can be triggered/worsened during market stress or oracle failures

---

## Impact Assessment

**Severity: MEDIUM** (High Impact × Low Likelihood)

- **Impact if over-reports:** Account's NAV could be inflated by orders of magnitude for a period
- **Impact if under-reports:** Account's NAV would be under-reported; silently drops from portfolio view
- **Duration:** Persists until oracle updates and catches up to pool price, or NAV is re-queried after oracle stabilizes
- **Scope:** Affects only that specific pool; other pools unaffected (per-instance error isolation)

---

## Mitigation

The recommended fix is to use the pool's **real `slot0.tick`** (or equivalently, the pool's `slot0.sqrtPriceX96`) for fee-growth branch selection, while keeping the oracle-derived price for principal liquidity split (where manipulation resistance is needed).

The fee-growth calculation **cannot** be manipulated by artificially moving the tick because:
- `feeGrowthOutside` is maintained by the pool's own tick-crossing logic
- Fees are only accumulated when liquidity is actually used to facilitate swaps
- The magnitude of fees depends on on-chain history, not current price

Example fix:
```solidity
// Read the pool's real tick ONCE for fee branching
(uint160 poolSqrtPriceX96, int24 poolTickCurrent,,,,, ) = IUniswapV3Pool(pool).slot0();

// Use oracle price for principal split (manipulation-resistant)
(liq0, liq1) = LiquidityAmounts.getAmountsForLiquidity(
    sqrtPriceX96,  // ← Oracle-derived (manipulation-resistant)
    sqrtLower,
    sqrtUpper,
    liquidity
);

// Use REAL pool tick for fee branch (correct accounting)
(uint256 fee0, uint256 fee1) = _computeFees(
    pool,
    poolTickCurrent,  // ← REAL pool tick, not oracle
    sqrtLower,
    sqrtUpper,
    fgGlobal0,
    fgGlobal1,
    tickLower,
    tickUpper,
    liquidity,
    fgInside0Last,
    fgInside1Last,
    tokensOwed0,
    tokensOwed1
);
```

---

## Conclusion

**FINDING CONFIRMED-MEDIUM**

The adapter intentionally uses an oracle-reconstructed price for fee-growth branch selection to prevent slot0 manipulation. However, this creates a mismatch: `feeGrowthOutside` values are anchored to the pool's **real** tick history, not the oracle-reconstructed tick. When prices diverge enough to cross a position's tick boundary, the wrong formula is applied, causing unchecked arithmetic to wrap to huge values. This results in either pool drops (under-report) or massive fee over-reports (over-report), both violating NAV invariants.

**Likelihood:** Low (requires oracle to diverge across a tick boundary)  
**Impact:** High (when it occurs, can corrupt NAV by orders of magnitude or drop positions entirely)  
**Severity:** MEDIUM
