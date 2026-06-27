# Meta-AMM Adapter Audit — Coverage Summary

Per-adapter one-line balance derivation and verdict.

---

## Balancer V2

### `BalancerV2PoolsMetaBalanceAdapter.sol`
**Balance derivation:** `walletBpt / effectiveSupply * vault.getPoolTokens(poolId).balances[i]` per token (BPT self excluded).  
**Verdict:** Clean. Multiply-before-divide; rounding down (under-reports). M-13 (read-only reentrancy on Vault read) corroborated — see M-01 in meta-amm findings.

### `BalancerV2PoolLib.sol`
**Balance derivation:** `balances[i] * bptAmount / effectiveSupply`; `effectiveSupply` = `getActualSupply()` (composable-stable) or `totalSupply()` fallback.  
**Verdict:** Clean. Division last; rounds down. `effectiveSupply` fallback to `totalSupply()` can over-count for composable-stable pools when `getActualSupply()` reverts — results in near-zero amounts (under-report), acceptable.

### `BalancerV2GaugesMetaBalanceAdapter.sol`
**Balance derivation (staking):** Same as V2 Pools via `BalancerV2PoolLib.shares` on gauge's staked BPT. **Rewards:** `claimableBal` = `integrate_fraction(user) - minter.minted(user, gauge)` (BAL inflation model) + `gauge.claimable_reward(account, token)` per extra token.  
**Verdict:** One new LOW finding (L-01): `rewardCount` from `reward_count()` used directly in array allocation without bound; OOM on poison gauge drops that instance (isolated). M-13 corroborated. Reward math is correct for mainnet inflation model; loop overflow protection via Solidity 0.8+ checked subtraction causes revert (caught by try/catch, under-reports) rather than wrap. Clean otherwise.

---

## Balancer V3

### `BalancerV3PoolsMetaBalanceAdapter.sol`
**Balance derivation:** Delegates to `BalancerV3PoolLib.poolBalanceOfIndexed` per pool token index.  
**Verdict:** Clean. M-13 corroborated.

### `BalancerV3PoolLib.sol`
**Balance derivation:** `(balancesLiveScaled18[i] * userBalance / totalSupply) * 1e18 / (decimalScalingFactor * tokenRate)`, then `previewRedeem()` if ERC4626.  
**Verdict:** Clean. Double division is mathematically correct (undo scaling+rate). Intermediate products bounded for real assets. Zero scaling/rate guarded with explicit 0-return. M-13 applies via `getStablePoolDynamicData()`. ERC4626 `previewRedeem` (vs `convertToAssets`) correctly used.

### `IBalancerV3.sol`
Interface only. No logic.

### `BalancerV3GaugesMetaBalanceAdapter.sol`
**Balance derivation (staking):** `BalancerV3PoolLib.poolBalanceOfIndexed(staked, i)` per pool token. **Rewards:** Same `claimableBal` + `claimable_reward` pattern as V2 gauges (shared `calculateIntegrateFraction` / `calculateIntegrateFractionL2`).  
**Verdict:** Same L-01 as V2 gauge (unbounded `rewardCount` allocation). M-13 corroborated. Otherwise clean.

---

## Curve

### `CurvePoolsMetaBalanceAdapter.sol`
**Balance derivation:** `poolBalance[i] * walletLp / totalSupply` per coin.  
**Verdict:** Clean. `getLpToken` correctly handles classic/NG/self-LP. `getTotalSupply` handles both `totalSupply()` and `total_supply()` variants. Multiply-before-divide.

### `CurvePoolLib.sol`
**Balance derivation:** `proRataAmount = poolBalance * lpBalance / totalSupply`.  
**Verdict:** Clean. `uint256` fallback to `int128` for `coins()` and `balances()` is correct — Vyper 0.1.x int128 selectors handled. `int128` decode as `uint256` safe since Curve balances are never negative. CRV lower-bound (`integrate_fraction - minter.minted`) documented as stale between checkpoints — under-report only. `getPool` via `minter()` pattern correct for NG LP tokens.

### `CurveGaugesMetaBalanceAdapter.sol`
**Balance derivation (staking):** Same as pool adapter but on `gaugeStaked(gauge, account)` LP balance. **Rewards:** CRV lower-bound + `claimable_reward` per extra token.  
**Verdict:** Clean. Pre-allocation bounded at `MAX_COINS * 2 + 1 = 17`. CRV skip-check on `CRV_TOKEN == address(0)` (L2) safe: `break` on `address(0)` reward token fires before `== CRV_TOKEN` check. No double-count with Pools adapter (staked vs wallet LP are separate).

---

## Uniswap V2

### `UniswapV2PoolsMetaBalanceAdapter.sol`
**Balance derivation:** `balance * reserve0 / effectiveSupply` per token (effectiveSupply = totalSupply + pendingProtocolMint).  
**Verdict:** Clean. `_mintFee` dilution correctly modelled. Virtual `_mintFeeConstants()` hook enables fork-specific constants.

### `UniswapV2PairLib.sol`
**Balance derivation:** `balance * reserve / (totalSupply + _pendingProtocolMint)`. `_pendingProtocolMint = ts * (rootK - rootKLast) * numFactor / (rootKCoeff * rootK + rootKLastCoeff * rootKLast)`.  
**Verdict:** Clean. Overflow analysis: max `totalSupply ≈ 2^112` (bounded by `sqrt(r0*r1)` with `r0,r1 ≤ 2^112`), so `ts * (rootK - rootKLast) * numFactor ≤ 2^112 * 2^112 * 8 = 2^227`. Within `uint256`. `feeTo` and `kLast` reads are defensive via `staticcall`.

---

## Uniswap V3

### `UniswapV3PoolLib.sol`
**Balance derivation:** `LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity)` for principal; `mulDiv((fgInside - fgInsideLast), liquidity, Q128) + tokensOwed` for fees.  
**Verdict:** The `accountAggregates` function correctly uses `tickCurrent` from `slot0` for the fee-growth branch. However, `accountAggregates` is **not called** by the current adapter (the adapter has its own inline loop). Dead code in scope. The fee computation in the lib is correct when called with a real `tickCurrent`.

### `lib/TickMath.sol`
**Verdict:** Correct port of Uniswap V3 TickMath. Unchecked block preserved for bit-manipulation magic constants (intentional; matches Uniswap V3's original 0.7 semantics). Tick bounds validated. `getSqrtRatioAtTick` correct.

### `lib/LiquidityAmounts.sol`
**Verdict:** Clean. `Math.mulDiv` (OZ 512-bit) replaces original `FullMath.mulDiv` — mathematically identical floor semantics. Both `getAmount0ForLiquidity` and `getAmount1ForLiquidity` are correct. Swap ensures A ≤ B before subtraction.

### `lib/FixedPoint128.sol`
**Verdict:** Trivial constant `Q128 = 2^128`. Correct.

---

## PancakeSwap

### `PancakeSwapV2PoolsMetaBalanceAdapter.sol`
**Balance derivation:** Inherits `UniswapV2PoolsMetaBalanceAdapter` with `_mintFeeConstants() = (8, 17, 8)` per PancakeSwap V2's `_mintFee` formula.  
**Verdict:** Clean. Constants verified against PancakeSwap V2 source. Protocol slug correctly overridden.

---

## Cross-cutting

### Prior M-13 (Balancer read-only reentrancy)
**Status: CONFIRMED.** Corroborated with fresh eyes — `getPoolTokens` (V2) and `getStablePoolDynamicData` (V3) are not gated by the Vault's reentrancy lock. Risk is limited to on-chain consumers of NAV. Documented in `.vigilo/adapter-audit/findings/medium/meta-amm/M-01-balancer-v2-v3-read-only-reentrancy.md`.

### UniswapV3 oracle-vs-pool-tick fee mismatch
**Status: Already filed as `medium/assisted/M-01-univ3-fee-branch-oracle-tick-mismatch.md`.** Scope of this audit confirmed: the mismatch is in `UniswapV3PoolsMetaBalanceAdapter._computeFees` (oracle-derived `sqrtPriceX96` used for branch selection) vs `UniswapV3PoolLib._computeFees` (correct `tickCurrent` used). The lib version is not called by the adapter. Finding stands.

---

## Findings written

| File | Severity | Title |
|------|----------|-------|
| `medium/meta-amm/M-01-balancer-v2-v3-read-only-reentrancy.md` | Medium | Corroboration of M-13: Balancer V2/V3 Vault read-only reentrancy |
| `low/meta-amm/L-01-balancer-gauge-unbounded-reward-count-allocation.md` | Low | Unbounded `rewardCount` from gauge causes per-instance OOM drop |
