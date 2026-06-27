# Vigilo Per-Adapter Audit — balance / meta / assisted adapters + custom price feeds

**Date:** 2026-06-27
**Branch:** `audit/vigilo-fixes`
**Scope:** every contract, audited individually, in:
- `src/balances/BalanceAdapters/` (10 plain adapters)
- `src/balances/MetaBalanceAdapters/` (12 lending/vault metas + balancer/curve/uniswap/pancakeswap subtrees + math libs)
- `src/balances/AssistedBalanceAdapters/` (6 adapters)
- `src/prices/protocols/` (27 custom price feeds)

**Method:** five specialist passes (defi, access-control, logic ×2, oracle) each covering its full slice contract-by-contract, then **adversarial verification of every High-candidate**. Raw output under `.vigilo/adapter-audit/` (per-finding files + per-component coverage tables + verifier verdicts).

> Companion to the prior full-repo audit (`2026-06-vigilo-automated-audit.md`) and remediation (`2026-06-vigilo-remediation.md`). This pass is deeper but narrower: one lens per contract.

---

## Result at a glance

| Severity | Count | Notes |
|---|---|---|
| **High** | 0 | The one High-candidate (FluidVaultLib ABI offset) was **refuted** on verification |
| **Medium** | 6 | 1 new (UniV3 fee branch), 1 corroborates M-13, 4 are LST/restaking price-feed freshness |
| **Low** | 9 | mostly corroborations of prior findings + minor griefing/consistency |

✅ **Verified positive — the assisted-adapter invariant holds.** "A faulty or compromised assistant can only **under-report**, never over-report" was re-checked per contract and **holds** for Merkl, ether.fi, and StakeWise V3 (proof bound to live Distributor root; exit-queue adapters re-verify on-chain ownership and read amounts live every call, all external reads `try/catch`→0).

---

## Refuted on verification (no issue)

**FluidVaultLib ABI offset (`meta-lending/M-01`) — REFUTED.** The finding claimed `FluidVaultLib._readUserPositionPrefix` reads struct fields 32 bytes too low (an ABI offset-pointer word), silently dropping *all* Fluid T1 positions. Verification established that `positionByNftId` returns a **single struct of static members**, which Solidity ABI-encodes inline with **no leading offset word** — so the offsets are correct (`mload(dataPtr+64)` → `isLiquidated`, `+288` → `supply`, `+320` → `borrow`). The unit test asserts exact non-zero amounts `[5e18, 1000e6, 2e18, 1e18]` that would be zeroed if the bug were real. (Verdict: `.vigilo/adapter-audit/verify/fluid-vault-lib-offset.md`.)

---

## Medium

### M-A1 — Uniswap V3 / PancakeSwap V3: fee-growth branch selected by oracle price, not the pool's real tick  *(NEW, confirmed)*
**Location:** `src/balances/AssistedBalanceAdapters/UniswapV3PoolsMetaBalanceAdapter.sol:235-243` (`_computeFees`); inherited by `PancakeSwapV3PoolsMetaBalanceAdapter`.
The uncollected-fee computation picks the below/in/above-range `feeGrowthInside` branch by comparing the **oracle-reconstructed** `sqrtPriceX96` against the position's tick-boundary sqrt ratios (lines 235/238, intentional per the comment at 208-213). But `feeGrowthOutside` (read from `pool.ticks(tick)`, line 252) is anchored to the pool's **real** current tick. When the oracle-implied price and the real pool price straddle a position boundary, the wrong branch is selected; the `unchecked` `fgInside − fgInsideLast` subtraction then wraps to ~2²⁵⁶, so `Math.mulDiv(…, liquidity, Q128)` either **reverts** (the per-instance `try/catch` drops the whole NFT position → under-report of principal+fees) or returns a **grossly inflated fee** → NAV over-report. The canonical reference `MetaBalanceAdapters/uniswap/UniswapV3PoolLib._computeFees` correctly takes the real `tickCurrent`.
**Likelihood low, impact high.** Verdict: `.vigilo/adapter-audit/verify/univ3-fee-branch.md`.
**Recommendation:** select the fee-growth branch using the pool's real `slot0.tick` (consistent with the `feeGrowthOutside` anchoring), while keeping the oracle-reconstructed price for the **principal** amounts. Fee manipulation via `slot0.tick` is bounded (an attacker moving the real tick also moves `feeGrowthOutside` consistently) and fees are a small fraction of LP value, so this trades a non-issue for correctness. The principal stays manipulation-resistant.

### M-A2 — Balancer V2/V3 read-only reentrancy on pool-balance reads  *(corroborates prior M-13)*
**Location:** `MetaBalanceAdapters/balancer/BalancerV2PoolLib.shares` (`Vault.getPoolTokens`), `BalancerV3PoolLib.poolBalanceOfIndexed` (`getStablePoolDynamicData`).
Neither read is gated by the Balancer Vault reentrancy lock, so an on-chain consumer calling `getAccountNav` from inside a Vault callback observes mid-operation balances. The adapters are view-only (can't be forced re-entrant themselves); risk is to on-chain NAV consumers.
**Recommendation:** add `VaultReentrancyLib.ensureNotInVaultContext` (V2) / the V3 equivalent before the pool reads. Best handled in a focused follow-up PR.

### M-A3 / M-A4 / M-A5 — LST/restaking feeds with no freshness guard on a pushed/bridged rate
- **M-A3 ankrETH** (`prices/M-03`): `ratio()` is a keeper-updated storage slot; only the ETH/USD Chainlink heartbeat is enforced, none on the rate's age. (Corroborates prior M-2.)
- **M-A4 ezETH_L2** (`prices/M-02`): `xRenzoDeposit.getRate()` is L1→L2 keeper-relayed with no `updatedAt`; ETH/USD staleness alone is insufficient.
- **M-A5 ezETH (L1)** (`prices/M-01`): `RestakeManager.calculateTVLs()` is accepted without verifying the freshness of Renzo's internal sub-oracles or any TVL sanity bound.
**Recommendation:** add an explicit freshness gate for keeper/bridged rates (ezETH_L2, ankrETH) and a reasonableness/deviation bound for the TVL-derived L1 ezETH rate.

### M-A6 — weETH_L2 assumes eETH/ETH parity
**Location:** `prices/protocols/weETH_L2_CustomPriceFeed.sol` (`prices/M-04`).
Prices via Chainlink weETH/eETH × ETH/USD, treating eETH ≈ ETH 1:1. eETH can de-peg from ETH; the parity is not validated.
**Recommendation:** source an eETH/ETH (or weETH/ETH) feed where available, or document the parity assumption and its bound explicitly.

---

## Low (9) — corroborations & minor issues

| ID | Component | Summary |
|---|---|---|
| `balance/L-01` | AaveUmbrella | reward-token→bare-reserve resolution does one wrapper hop vs two for principal; latent mixed-unit/drop risk if a waToken reward is ever added |
| `balance/L-02` | ERC4626Wrap | `convertToAssets` ignores exit fees (prior M-4); no current wrapper charges one |
| `balance/L-03` | Cap | per-leg vs combined burn-quote inconsistency under non-proportional fees (prior M-15) |
| `balance/L-04` | LidoWithdrawalQueue | non-finalized requests valued at `amountOfStETH`, overstates after a negative rebase (prior M-6); temporary |
| `assisted/L-01` | NexusMutual | `getAdapterBalances` (`getAggregatedTokens`) vs `getAdapterPositions` (`getTokens`) can diverge — consistency, not over-report |
| `assisted/L-02` | Merkl | `clearAllocation` is `ASSISTANT_ROLE`-gated; a compromised assistant can delete a valid allocation (targeted **under**-report only; per ADR 0007 trust model) |
| `meta-amm/L-01` | Balancer gauges | reward array pre-allocated from raw `reward_count()`; a poison gauge can OOM and drop that instance (under-report) |
| `prices/L-01` | PriceFeedLib sentinel | `updatedAt==0 → block.timestamp-1` path is unreachable for `BaseCustomPriceFeed` descendants (they return the real Chainlink `updatedAt`); informational |
| `prices/L-02` | ERC4626 feeds | `convertToAssets` donation/inflation sensitivity; NAV is an `eth_call` so no atomic exploit — off-chain-read concern only |

---

## Per-component coverage (everything that came back clean)

- **Balance adapters:** AaveV3SafetyModule (uses `previewRedeem` — correct), ERC20Default (phantom-balance guard in place), EthenaCooldown (silo slot zeroed on claim), Kelp & Stader withdrawal queues (finalized/pending distinguished; no rebase discount), SparkLend (correct Collateral/Supplied/Borrowed split) — **clean**.
- **Meta lending/vault:** AaveV3Instances, CompoundV3 (uint64 truncation is under-report-only), Euler, FluidFTokens, FluidVaults (offset **refuted**), Gearbox, MorphoMarkets (correct Floor/Ceil rounding per ADR 0004), MorphoVaults, StakeWiseV3Vaults (osToken debt via controller rate — correct), ConvexRewards (CVX cliff is an upper-bound estimate, M-7) — **clean**.
- **Meta AMM:** Curve pools+gauges, UniswapV2/PancakeSwapV2 (mint-fee dilution modelled), Balancer V2/V3 pool math, the UniV3 math libs (TickMath/LiquidityAmounts/FixedPoint128 — correct ports) — **clean** apart from M-A2.
- **Price feeds:** 21 of 27 clean (CrossRate, ETHPlus, ETHx, LDO, NXM, cbETH/_L2, eETH, osToken, rETH, rsETH/_L2, sDAI, sGHO, sUSDS, sUSDe, sXDAI, syrupUSDC/_L2, weETH, wstETH/_L2). sUSDe/sUSDS share-unit re-confirmed **correct** (`10**_vaultDecimals`).

Full tables: `.vigilo/adapter-audit/findings/{balance,assisted,meta-lending,meta-amm,prices}-coverage.md`.

---

## Suggested next actions
1. **M-A1 (UniV3/PancakeSwap V3 fee branch)** — the one new, self-contained code fix worth doing: switch the fee-growth branch to the real `slot0.tick`. Has a fork-test surface, so verifiable.
2. **M-A2 (Balancer read-only reentrancy)** + **M-A3/4/5 (rate freshness bounds)** — group into the deferred valuation/hardening bucket from the remediation doc; both shift behavior only in stale/manipulated states (snapshot-safe in healthy state) but warrant fork tests.
3. Lows — fold into a future hardening pass; none is a fund-loss vector and several are config/trust-model accepted.

*Automated audit; a prioritized review queue, not a substitute for human review.*
