# Uniswap V3 — balance-adapter verification

> **Historical evidence pack (pre-meta).** This verification was done against the per-pool
> `uniswap/UniswapV3Pool.sol` adapter, which `main` has since replaced with the immutable
> `UniswapV3PoolsMeta` meta-adapter (ADR 0010). The per-pool dev helpers
> (`deploy-uniV3-adapters-mainnet.sh`, `query-live-balances.s.sol`) were removed in the meta
> reconciliation. The ground-truth math, holders, and expected amounts below remain valid as
> reference; the dashboard wiring (§9) will be re-done with a meta-based deploy helper when V3
> is re-verified against `UniswapV3PoolsMeta`.

## 1. Adapter under test

`src/balances/MetaBalanceAdapters/uniswap/UniswapV3Pool.sol` — **removed** in the meta reconciliation; the live implementation is now the assisted `UniswapV3PoolsBalanceAdapter.sol` (`UniswapV3PoolsBalanceAdapter`; agent-fed, ADR 0015), which covers every pool from one contract. The per-pool adapter under test here was one instance per pool (immutable). Position discovery is dynamic (and carried over unchanged into the assisted adapter): it iterates the account's NFTs from the canonical `NonfungiblePositionManager` (NPM), filters those whose `(token0, token1, fee)` match the pool, and aggregates principal + fees per token. Bounded at 256 NFTs per query.

The math libraries (`TickMath`, `LiquidityAmounts`, `FixedPoint128`) live under `src/balances/MetaBalanceAdapters/uniswap/lib/` and carry `GPL-2.0-or-later`. Because the adapter imports and links those libs, the adapter file itself also carries `GPL-2.0-or-later` — there is no MIT file in this compilation unit — see [`docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md`](../../../../docs/decisions/0008-uniswap-v3-math-libs-gpl-license.md).

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** the per-pool adapter under test was a direct `IBalanceAdapter` implementer; the live `UniswapV3PoolsBalanceAdapter` is instead an `AssistedBalanceAdapter` (agent-fed; ADR 0015). In both, `_slot0()` is `virtual` — the override hook used by `PancakeSwapV3PoolsBalanceAdapter` to absorb PCS V3's `uint32 feeProtocol` ABI shim. Verification of that override is a separate task.
- **Per-chain scope:** Uniswap V3 is deployed on Ethereum, Optimism, Arbitrum, Base, Polygon, BSC and others; only Ethereum has V3 instances configured (now as meta-adapter instances under `script/config/nav-config/meta-balance-adapters/<chainId>.json`, governed via `addMetaInstances`) today (3 enabled: WBTC/WETH 0.3%, USDC/WETH 0.05%, WETH/USDT 0.3%). Gnosis has no Uniswap V3 deployment. The adapter has **zero per-chain code branches** — pool ABI/bytecode is identical on every chain; NPM is a constructor argument. Single-chain (mainnet) fork tests are sufficient.
- **Math branches** exercised in this case: in-range principal, above-range principal, below-range principal, in-range fee delta, out-of-range fee delta, settled `tokensOwed`, foreign-pool filter, closed-position filter, bounded iteration at scale.

## 2. Existing fork test coverage

`test/balances/protocols/fork/UniswapV3Pool.fork.t.sol` →
`UniswapV3PoolBalanceOracleForkTest_WBTC_WETH` (pre-existing):

- Real holder with 4 NFTs at mainnet block 24,987,608: 2 in WBTC/WETH 0.3% (above-range), 2 in unrelated pools.
- Strict-equality regression baseline for WBTC/WETH 0.3% above-range principal + fees.
- Foreign-pool filter sanity check.

Kept untouched as a regression net.

## 3. What this case adds

- Two new holders covering the WETH/USDT 0.3% and USDC/WETH 0.05% pools (the remaining two registered V3 instances).
- **In-range** principal + fee delta assertion — the previously-uncovered branch in fork tests.
- **Below-range** principal + fee delta assertion.
- **Settled `tokensOwed > 0`** assertion on both tokens.
- Foreign-pool + closed-position filter under load (33 NFTs across multiple pools).
- All assertions strict-equality (delta = 0).

## 4. Adapter formula recap

For an NPM-managed Uniswap V3 NFT with `(tickLower, tickUpper, liquidity, feeGrowthInside0/1Last, tokensOwed0/1)`, the adapter computes:

```
# Principal — amounts the protocol would return on decreaseLiquidity(L) at the current price.
(amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
    sqrtPriceX96,
    TickMath.getSqrtRatioAtTick(tickLower),
    TickMath.getSqrtRatioAtTick(tickUpper),
    liquidity)

# Fee accrual since last position update — branches on current tick.
if tickCurrent < tickLower:
    fgInside0 = fgOutLower0 - fgOutUpper0
    fgInside1 = fgOutLower1 - fgOutUpper1
elif tickCurrent < tickUpper:
    fgInside0 = fgGlobal0 - fgOutLower0 - fgOutUpper0
    fgInside1 = fgGlobal1 - fgOutLower1 - fgOutUpper1
else:
    fgInside0 = fgOutUpper0 - fgOutLower0
    fgInside1 = fgOutUpper1 - fgOutLower1

fee0 = mulDiv(fgInside0 - feeGrowthInside0Last, liquidity, 2^128) + tokensOwed0
fee1 = mulDiv(fgInside1 - feeGrowthInside1Last, liquidity, 2^128) + tokensOwed1
```

All subtractions are intentionally `unchecked` — `fgInside*X128` and `fgOutside*X128` wrap mod 2^256, and the wrap cancels under the subtraction. Mirrors Uniswap v3-periphery's `PositionValue._fees` exactly, with `FullMath.mulDiv` replaced by OpenZeppelin's `Math.mulDiv` (bit-equivalent).

## 5. Cherry-picked accounts

| Holder | Address | Rationale |
|---|---|---|
| `ACCOUNT_12` | `0x8d27DEB2405717d649346502F52B959AAB4eb3af` | Listed in `test/integration/accounts.json` as `ACCOUNT_12_MAINNET_UNISWAP_V3_LP`, purpose-built for V3 verification. 4 NFTs in registered pools at the fork block, covering above-range + below-range + closed-position filter across two pools. |
| `HOLDER_B` | `0xa1097367be4C8bbdEf3D881E3c24E6260Afef36E` | Heavy mainnet V3 LP — 33 NFTs total, 19 in our registered pools. Active NFT #1287303 in WETH/USDT 0.3% is **in-range** at the fork block with non-zero `tokensOwed` on both tokens. The other 32 NFTs (18 closed, 14 in foreign pools) stress the bounded iteration loop and the `(token0, token1, fee)` filter. |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,151,872** |
| Block timestamp | 1779465815 (`0x6a107e57`) — **2026-05-22 16:03:35 UTC** |
| NPM | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` |
| Pool tick — USDC/WETH 0.05% | 199730 |
| Pool tick — WETH/USDT 0.3% | -199732 |
| Pool tick — WBTC/WETH 0.3% | 266166 |
| Adapter under test | `src/balances/MetaBalanceAdapters/uniswap/UniswapV3Pool.sol` (one instance per pool) |
| New fork-test contract | `UniswapV3PoolBalanceOracleForkTest_MultiHolder_LP` in `test/balances/protocols/fork/UniswapV3Pool.fork.t.sol` |
| Existing fork-test contract (kept) | `UniswapV3PoolBalanceOracleForkTest_WBTC_WETH` (block 24,987,608) |

## 6. Case files in this folder

Only `case-multi-holder-mainnet.json` survives today; the two dev helpers below were removed in the meta reconciliation (see banner) and are listed here for the historical record.

| File | Purpose | Status |
|---|---|---|
| `case-multi-holder-mainnet.json` | Per-holder, per-pool machine-readable evidence pack | present |
| `deploy-uniV3-adapters-mainnet.sh` | Deploy + register the 3 enabled V3 adapters on the dev mainnet anvil | removed (pre-meta) |
| `query-live-balances.s.sol` | Forge script that forks Ethereum at a given block and prints the principal/fees split — used for ad-hoc cross-checks against the live Uniswap UI | removed (pre-meta) |

## 7. Expected balances

Values are pinned at the fork block in §5 as `EXPECTED_*` constants in the test, and independently validated by the ground-truth cross-check in §8.

### 7a. Per-leg detail (every emission the adapter makes)

One row per `getAdapterPositions` entry the adapter would emit, plus rows for closed/filtered NFTs marked in italics so the filter behaviour is also visible.

| Holder | Pool | NFT | Leg | Token | Amount (raw) | Amount (humanised) |
|---|---|---|---|---|---|---|
| ACCOUNT_12 | USDC/WETH 0.05% | #1204560 | _closed (`liquidity = 0`)_ | — | — | — |
| ACCOUNT_12 | USDC/WETH 0.05% | #1231724 | Supply | WETH | `207115068443336551` | 0.207115 WETH |
| ACCOUNT_12 | WETH/USDT 0.3% | #1258127 | _closed (`liquidity = 0`)_ | — | — | — |
| ACCOUNT_12 | WETH/USDT 0.3% | #1276763 | Supply | WETH | `125413060602732741` | 0.125413 WETH |
| ACCOUNT_12 | WETH/USDT 0.3% | #1276763 | Fees | WETH | `476553808093438` | 0.000477 WETH |
| ACCOUNT_12 | WETH/USDT 0.3% | #1276763 | Fees | USDT | `740253` | 0.740253 USDT |
| HOLDER_B | USDC/WETH 0.05% | _various_ | _closed_ | — | — | — |
| HOLDER_B | WETH/USDT 0.3% | _remaining closed_ | _closed_ | — | — | — |
| HOLDER_B | WETH/USDT 0.3% | #1287303 | Supply | WETH | `14831585506412934519` | 14.831586 WETH |
| HOLDER_B | WETH/USDT 0.3% | #1287303 | Supply | USDT | `778180966` | 778.180966 USDT |
| HOLDER_B | WETH/USDT 0.3% | #1287303 | Fees | WETH | `63551228360345301` | 0.063551 WETH |
| HOLDER_B | WETH/USDT 0.3% | #1287303 | Fees | USDT | `136073640` | 136.073640 USDT |
| HOLDER_B | _14 NFTs in other pools_ | _various_ | _filtered (token0/token1/fee mismatch)_ | — | — | — |
| HOLDER_B | WBTC/WETH 0.3% | #1239418 | _closed (`liquidity = 0`)_ | — | — | — |

The `Supply` legs come from `LiquidityAmounts.getAmountsForLiquidity(...)` (§4). The `Fees` legs come from `mulDiv(feeGrowthInside − feeGrowthInsideLast, L, 2^128) + tokensOwed` (§4).

### 7b. Per-asset summary (what `getAdapterBalanceForAsset` returns)

This is what the strict-equality test asserts. Each value is the sum of the per-leg rows above for the same `(holder, pool, token)`.

| Holder | Pool | Token | Total (raw) | Total (humanised) | isDebt |
|---|---|---|---|---|---|
| ACCOUNT_12 | USDC/WETH 0.05% | USDC | `0` | 0 USDC | false |
| ACCOUNT_12 | USDC/WETH 0.05% | WETH | `207115068443336551` | 0.207115 WETH | false |
| ACCOUNT_12 | WETH/USDT 0.3% | WETH | `125889614410826179` | 0.125890 WETH | false |
| ACCOUNT_12 | WETH/USDT 0.3% | USDT | `740253` | 0.740253 USDT | false |
| ACCOUNT_12 | WBTC/WETH 0.3% | WBTC | `0` | 0 WBTC | false |
| ACCOUNT_12 | WBTC/WETH 0.3% | WETH | `0` | 0 WETH | false |
| HOLDER_B | USDC/WETH 0.05% | USDC | `0` | 0 USDC | false |
| HOLDER_B | USDC/WETH 0.05% | WETH | `0` | 0 WETH | false |
| HOLDER_B | WETH/USDT 0.3% | WETH | `14895136734773279820` | 14.895137 WETH | false |
| HOLDER_B | WETH/USDT 0.3% | USDT | `914254606` | 914.254606 USDT | false |
| HOLDER_B | WBTC/WETH 0.3% | WBTC | `0` | 0 WBTC | false |
| HOLDER_B | WBTC/WETH 0.3% | WETH | `0` | 0 WETH | false |

## 8. Ground-truth cross-check

Three `test_groundTruth_*` cases run the protocol's own settlement path against each active NFT and assert the adapter's output equals what `NonfungiblePositionManager` would actually transfer:

| Test | NFT | Branch | Compared against |
|---|---|---|---|
| `test_groundTruth_acct12_USDC_WETH_NFT1231724` | #1231724 | above-range | `NPM.decreaseLiquidity(L) + NPM.collect(uint128.max)` |
| `test_groundTruth_acct12_WETH_USDT_NFT1276763` | #1276763 | below-range | `NPM.decreaseLiquidity(L) + NPM.collect(uint128.max)` |
| `test_groundTruth_holderB_WETH_USDT_NFT1287303` | #1287303 | in-range, `tokensOwed > 0` | `NPM.decreaseLiquidity(L) + NPM.collect(uint128.max)` |

Each test impersonates the position owner with `vm.prank`, calls `decreaseLiquidity` at the full liquidity (which pushes principal into `tokensOwed*` on the NPM and zeros the position liquidity), then calls `collect` with `uint128.max` to pull principal + previously-settled `tokensOwed` + just-accrued fees into the returned `(amount0, amount1)`. The adapter's `getAdapterBalanceForAsset` for the same `(holder, token)` must equal that return value — both compute the same quantity: the total transferable amount the protocol would settle at the pinned block.

This is the forked-EVM equivalent of a Tenderly `decreaseLiquidity + collect` simulation. Same NPM contract, same forked archive state at the same block, same EVM — no possibility of derivation drift between the adapter's math and the protocol's settlement math.

## 9. Wiring the live dev-anvil dashboard

> **Stale (pre-meta).** `deploy-uniV3-adapters-mainnet.sh` no longer exists; the steps below are the historical per-pool flow and will be re-done with a meta-based deploy helper when V3 is re-verified against `UniswapV3PoolsMeta` (see banner).

`deploy-uniV3-adapters-mainnet.sh` deploys + registers all 3 enabled mainnet V3 adapters on the local mainnet anvil so the dashboard renders both holders' positions for a side-channel cross-check. Run after the dev anvil is up and the NAV proxy is deployed:

```bash
bash script/development/anvil/start-forks.sh
bash script/development/deploy/deploy.sh
bash script/development/test/uniswapV3/deploy-uniV3-adapters-mainnet.sh
bash script/development/app/sync-app-env.sh
# then start the Next.js dev server in app/
```

Deployed adapter addresses go to `script/development/state/1-uniV3-adapters.json`. This step is separate from the fork test (which deploys its own adapter instances in `setUp()`) — it is purely the dashboard surface.

## 10. Test verdict (2026-05-22)

| Aspect | Status |
|---|---|
| Pre-flight: `ACCOUNT_12` above + below-range NFTs active | ✅ |
| Pre-flight: `HOLDER_B` in-range NFT with `tokensOwed > 0` on both tokens | ✅ |
| Strict equality: `getAdapterBalanceForAsset` per (holder, pool, token) | ✅ |
| Strict equality: `getAdapterBalances` aggregate per (holder, pool) | ✅ |
| Structural: `getAdapterPositions` per-leg breakdown matches branch | ✅ |
| Foreign-pool + closed-position filter at scale (33 NFTs) | ✅ |
| Ground-truth: adapter == `NPM.decreaseLiquidity + NPM.collect` | ✅ |

**21 / 21 tests pass with zero drift.** Adapter output equals the captured baselines to the unit across all three enabled pools, both holders, and every covered branch. The three `test_groundTruth_*` cases independently confirm the adapter's output equals what the Uniswap V3 protocol itself would transfer on close.

Run via:

```bash
FOUNDRY_PROFILE=slow forge test --match-contract UniswapV3PoolBalanceOracleForkTest_MultiHolder_LP -vv
```
