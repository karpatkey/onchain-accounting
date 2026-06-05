# Uniswap V2 — balance-adapter verification

> **Historical evidence pack (pre-meta).** This verification was done against the per-pool
> `UniswapV2.sol` adapter, which `main` has since replaced with the immutable
> `UniswapV2PoolsMeta` meta-adapter (ADR 0010). The per-pool dev-wiring helper
> (`deploy-uniV2-adapters-mainnet.sh`) was removed in the meta reconciliation. The
> ground-truth math, holder, and expected amounts below remain valid as reference; the
> dashboard wiring (§9) will be re-done with a meta-based deploy helper when V2 is
> re-verified against `UniswapV2PoolsMeta`.

## 1. Adapter under test

`src/balances/protocols/UniswapV2.sol` — one adapter instance per pair (immutable). The adapter holds a single LP balance per address and reports the underlying token amounts pro-rata to the holder's share of `totalSupply`, with a dilution adjustment when the factory's `feeTo` is set.

### Inheritance + per-chain scope

- **Inheritance:** direct `IBalanceOracleAdapter` implementer. `PancakeSwapV2BalanceOracle is UniswapV2BalanceOracle` — a constructor-only subclass with **zero overrides** (verified in `src/balances/protocols/pancakeswap/PancakeSwapV2.sol`). The PCS V2 adapter's math, dilution formula, asset-filter behaviour, and pro-rata derivation are byte-for-byte the same code path the V2 fork test in this PR exercises. PancakeSwap V2 is therefore considered **verified by inheritance** as part of this PR — no separate verification PR is needed for PCS V2. Existing `test/balances/protocols/PancakeSwapV2.t.sol` and `test/balances/protocols/fork/PancakeSwapV2.BSC.fork.t.sol` provide the PCS-instance regression coverage on top of the inherited semantics.
- **Per-chain scope:** Uniswap V2 is deployed on Ethereum and a handful of L2s, but only Ethereum has V2 instances configured in `script/config/chains/1.json`. The adapter has **zero per-chain code branches** — pair ABI/bytecode is identical on every chain. Single-chain (mainnet) fork tests are sufficient.
- **Math branches:** dilution-inactive (`feeTo == 0`, exercised by the existing mock-based test in §2) and dilution-active with `kLast > 0` and `rootK > rootKLast` (the dominant production branch — exercised by the multi-pool holder in §5; the fork test explicitly asserts `kLast > 0` for every pool). The `kLast == 0` sub-branch (factory just turned `feeTo` on, no swaps yet) is **not** covered by either case: catching a pool in the brief window between `feeTo` being set and the next swap would require either a mocked pair state or a synthetic test. Documented here so the next adapter-touching PR has a clear gap to close if it cares about that branch.

## 2. Existing fork test coverage

`test/balances/protocols/fork/UniswapV2.fork.t.sol` →
`UniswapV2BalanceOracleForkTest_USDC_WETH` (pre-existing):

- USDC/WETH pair on mainnet at block 24,444,658.
- LP balance is **synthetic** — `deal()`-planted on a `makeAddr("alice")` test address, not a real holder.
- Pro-rata math correctness against live `getReserves()` / `totalSupply()`.
- Dilution branch correctness via **mocked** `factory.feeTo()` + **mocked** `pair.kLast()` — the canonical Uniswap V2 factory had `feeTo == address(0)` historically, so the dilution branch was never active on a real mainnet pair until this PR's holder was selected.
- Position aggregation + asset-filter behaviour.

Kept untouched as a regression net for math correctness with mocks.

## 3. What this case adds

- **Real holder** with non-zero LP across **6 canonical V2 pairs** simultaneously.
- The holder is the **current value of `UniswapV2Factory.feeTo()`** — so the dilution branch is exercised **live** at the pinned block, not via mocks.
- **Strict equality** against the dilution-adjusted formula in arbitrary precision (Python derivation in `compute-expected.py`), which equals what `pair.burn(holder)` would transfer on a real exit when `feeTo != 0`.
- Coverage of token-decimal heterogeneity (USDC/USDT = 6, WBTC = 8, WETH/DAI = 18).

## 4. Adapter formula recap

For a holder of `lp` LP tokens of a V2 pair with reserves `(r0, r1)`, `totalSupply`, and `kLast`:

```
# Dilution adjustment — pendingProtocolMint, only when feeTo != address(0)
if feeTo == address(0) or kLast == 0:
    pendingProtocolMint = 0
else:
    rootK     = sqrt(r0 * r1)
    rootKLast = sqrt(kLast)
    if rootK > rootKLast:
        numerator   = totalSupply * (rootK - rootKLast)
        denominator = rootK * 5 + rootKLast
        pendingProtocolMint = numerator / denominator
    else:
        pendingProtocolMint = 0

# Underlying amounts
effectiveSupply = totalSupply + pendingProtocolMint
amount0 = (lp * r0) / effectiveSupply
amount1 = (lp * r1) / effectiveSupply
```

This matches Uniswap V2's `pair.burn()` math exactly modulo the protocol-fee mint sequence inside `_mintFee` — which is a no-op when `feeTo == 0`. So the burn simulation is bit-exact ground truth.

## 5. Cherry-picked accounts

| Holder | Address | Rationale |
|---|---|---|
| Fee receiver | `0xf38521f130fcCF29dB1961597bc5d2B60F995f85` | Current value of `UniswapV2Factory.feeTo()` — confirmed at the pinned block. LP positions present in all 6 canonical V2 pairs (selected via Dune query 7553459 ordered by pair count desc). Activates the dilution branch live. |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,144,444** |
| Block timestamp | 1779376566 (`0x6a0f21b6`) — **2026-05-21 15:16:06 UTC** |
| Factory | `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` |
| Factory `feeTo` at pinned block | `0xf38521f130fcCF29dB1961597bc5d2B60F995f85` (= holder; dilution branch active) |
| Adapter under test | `src/balances/protocols/UniswapV2.sol` (one instance per pair) |
| New fork-test contract | `UniswapV2BalanceOracleForkTest_MultiPool_FeeReceiver` in `test/balances/protocols/fork/UniswapV2.fork.t.sol` |
| Existing fork-test contract (kept) | `UniswapV2BalanceOracleForkTest_USDC_WETH` (block 24,444,658) |

### Per-pair state at the pinned block

Sanity values consumed by the dilution math in §4. Reproduced here for traceability of the §7 expected amounts.

| Pair | Pair address | totalSupply | reserve0 | reserve1 | kLast | Holder LP | Pending protocol mint |
|---|---|---|---|---|---|---|---|
| USDC/WETH | `0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc` | `71524960490263522` | `9283709548424` (USDC) | `4383885649164906350202` (WETH) | `40698714004570785604812811690423272` | `572118540385` | `1033333952` |
| USDT/WETH | `0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852` | `56039400702797694` | `3674300582886516441277` (WETH) | `7786636206675` (USDT) | `28609165329760219541904241659177024` | `524231255292` | `208380389358` |
| DAI/WETH | `0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11` | `42141463136922989994002` | `4266384178873238544406300` (DAI) | `2014912276979018836820` (WETH) | `8595243144053056738816447983195826337842631044` | `357754544446275522` | `468476215008095737` |
| WBTC/WETH | `0xBb2b8038a1640196FbE3e38816F3e67Cba72D940` | `2496662761488850` | `5489292249` (WBTC) | `1990980942207281690502` (WETH) | `10929054552648029973465918591327` | `27225977518` | `413125081` |
| USDC/USDT | `0x3041CbD36888bECc7bbCBc0045E3B1f144466f5f` | `1320325893212` | `1766966740090` (USDC) | `1771092143660` (USDT) | `3129395832903606990453598` | `54175` | `2288081` |
| DAI/USDC | `0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5` | `478938203185215845` | `543883002588485504333157` (DAI) | `545130320415` (USDC) | `296480131038030343968743552266109580` | `10981520318976` | `940214338605` |

Token0/token1 ordering is the pair's `token0()` / `token1()` (sorted by address ascending).

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-multi-pool-mainnet.json` | Per-pair machine-readable evidence pack with state, dilution intermediates, and expected amounts |
| `compute-expected.py` | Python derivation of the dilution-adjusted expected amounts (the independent ground truth referenced in §8) |
| `deploy-uniV2-adapters-mainnet.sh` | Deploy + register the 6 mainnet V2 adapters on the dev mainnet anvil |

## 7. Expected balances

Values are pinned at the fork block in §5 as `EXPECTED_*` constants in the test, and independently validated by the ground-truth derivation in §8.

### 7a. Per-leg detail

Uniswap V2 is single-leg per pair (`Supply` from the LP token's pro-rata share). One row per token per pair the holder is in.

| Holder | Pair | Leg | Token | Amount (raw) | Amount (humanised) |
|---|---|---|---|---|---|
| Fee receiver | USDC/WETH | Supply | USDC | `74259143` | 74.259143 USDC |
| Fee receiver | USDC/WETH | Supply | WETH | `35066111262254964` | 0.035066 WETH |
| Fee receiver | USDT/WETH | Supply | WETH | `34371817334190102` | 0.034372 WETH |
| Fee receiver | USDT/WETH | Supply | USDT | `72841301` | 72.841301 USDT |
| Fee receiver | DAI/WETH | Supply | DAI | `36218518466527858189` | 36.218518 DAI |
| Fee receiver | DAI/WETH | Supply | WETH | `17105149103443307` | 0.017105 WETH |
| Fee receiver | WBTC/WETH | Supply | WBTC | `59860` | 0.0005986 WBTC |
| Fee receiver | WBTC/WETH | Supply | WETH | `21711539995652021` | 0.021712 WETH |
| Fee receiver | USDC/USDT | Supply | USDC | `72501` | 0.072501 USDC |
| Fee receiver | USDC/USDT | Supply | USDT | `72670` | 0.072670 USDT |
| Fee receiver | DAI/USDC | Supply | DAI | `12470607855679992115` | 12.470608 DAI |
| Fee receiver | DAI/USDC | Supply | USDC | `12499207` | 12.499207 USDC |

Each amount is `(holderLP * reserveX) / (totalSupply + pendingProtocolMint)` from §4, using the per-pair state in §5.

### 7b. Per-asset summary (what `getOracleBalanceForAsset` returns)

This is what the strict-equality test asserts. For Uniswap V2, single-leg → 7a and 7b are identical row-for-row. The redundant `isDebt` column is shown for structural consistency with multi-leg / debt-carrying adapters (V2 LPs never carry debt).

| Holder | Pair | Token | Total (raw) | Total (humanised) | isDebt |
|---|---|---|---|---|---|
| Fee receiver | USDC/WETH | USDC | `74259143` | 74.259143 USDC | false |
| Fee receiver | USDC/WETH | WETH | `35066111262254964` | 0.035066 WETH | false |
| Fee receiver | USDT/WETH | WETH | `34371817334190102` | 0.034372 WETH | false |
| Fee receiver | USDT/WETH | USDT | `72841301` | 72.841301 USDT | false |
| Fee receiver | DAI/WETH | DAI | `36218518466527858189` | 36.218518 DAI | false |
| Fee receiver | DAI/WETH | WETH | `17105149103443307` | 0.017105 WETH | false |
| Fee receiver | WBTC/WETH | WBTC | `59860` | 0.0005986 WBTC | false |
| Fee receiver | WBTC/WETH | WETH | `21711539995652021` | 0.021712 WETH | false |
| Fee receiver | USDC/USDT | USDC | `72501` | 0.072501 USDC | false |
| Fee receiver | USDC/USDT | USDT | `72670` | 0.072670 USDT | false |
| Fee receiver | DAI/USDC | DAI | `12470607855679992115` | 12.470608 DAI | false |
| Fee receiver | DAI/USDC | USDC | `12499207` | 12.499207 USDC | false |

## 8. Ground-truth cross-check

The expected amounts in §7 are derived **independently** of the adapter contract by re-running the V2 dilution math in arbitrary precision against the on-chain state at the pinned block:

- `compute-expected.py` reads `totalSupply`, reserves, `kLast`, and `holderLP` per pair, then computes `pendingProtocolMint` and the dilution-adjusted `amount0` / `amount1` as Python integers (no rounding loss vs Solidity's `uint256` math).
- The strict-equality test asserts the adapter's `getOracleBalanceForAsset(holder, token)` returns exactly these Python-derived values per pair, per token.

Bit-exact equivalence with the protocol settlement path: `pair.burn(holder)` simulated at the pinned block would transfer exactly the §7 amounts when `feeTo != 0`. The Python derivation is the ground truth; the adapter matches it; the protocol matches both.

## 9. Wiring the live dev-anvil dashboard

`deploy-uniV2-adapters-mainnet.sh` deploys + registers all 6 mainnet V2 adapters on the local mainnet anvil so the dashboard renders the holder's positions for a side-channel cross-check. Run after the dev anvil is up and the NAV proxy is deployed:

```bash
bash script/development/anvil/start-forks.sh
bash script/development/deploy/deploy.sh
bash script/development/test/uniswapV2/deploy-uniV2-adapters-mainnet.sh
bash script/development/app/sync-app-env.sh
# then start the Next.js dev server in app/
```

Deployed adapter addresses go to `script/development/state/1-uniV2-adapters.json`. This step is separate from the fork test (which deploys its own adapter instances in `setUp()`) — it is purely the dashboard surface.

## 10. Test verdict (2026-05-21)

| Aspect | Status |
|---|---|
| Pre-flight: holder is `factory.feeTo` | ✅ |
| Pre-flight: dilution branch active in every pair | ✅ |
| Strict equality: `getOracleBalanceForAsset(token0)` per pair | ✅ |
| Strict equality: `getOracleBalanceForAsset(token1)` per pair | ✅ |
| Strict equality: `getOracleBalances()` aggregate per pair | ✅ |
| Strict equality: `getOraclePositions()` per pair | ✅ |

**6 / 6 tests pass with zero drift.** Adapter output equals the dilution-adjusted expected amounts to the unit across all 6 pairs and across both tokens — `getOracleBalanceForAsset` / `getOracleBalances` / `getOraclePositions` surfaces all agree.

Run via:

```
FOUNDRY_PROFILE=slow forge test --match-contract UniswapV2BalanceOracleForkTest_MultiPool_FeeReceiver -vv
```
