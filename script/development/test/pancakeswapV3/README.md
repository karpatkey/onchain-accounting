# PancakeSwap V3 — balance-adapter verification

## 1. Adapter under test

`src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol` — the immutable `PancakeSwapV3PoolsMetaBalanceAdapter` meta-adapter (ADR 0010): one adapter serves every PancakeSwap V3 pool, with the active pool set seeded on NAVCalculator at registration via `addMetaBalanceAdapter(adapter, instances)` and adjusted incrementally via `addMetaInstances`/`removeMetaInstances`. Constructor: `(positionManager, protocolName, navCalculator)`. Identity is derived on-chain (positionId = `abi.encode(npm, tokenId)`; positionLabels = `["Liquidity Pool", "NFT #<tokenId>"]`).

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** `PancakeSwapV3PoolsMetaBalanceAdapter is UniswapV3PoolsMetaBalanceAdapter`. PancakeSwap V3 is a byte-for-byte Uniswap V3 fork sharing every relevant view, so the subclass carries only **two overrides**:
  - `_slot0(pool)` — the **entire correctness surface**. PancakeSwap declares `slot0().feeProtocol` as `uint32` (Uniswap's `uint8`); Solidity 0.8's strict ABI decoder reverts on a `uint8` read whenever the high bits are set, which is the case on every active PCS pool. The override reads `slot0()` through a local `IPancakeV3Pool` interface so the `uint32` field decodes. `_slot0` is read once per pool (before the NFT loop) and feeds `getAmountsForLiquidity`, so a meaningful test needs an **active (liquidity > 0)** position.
  - `_protocolId()` — returns `ProtocolIds.PANCAKESWAP_V3` (the parent's was an inherited constant `uniswap-v3`; see §10). All other behaviour — NFT discovery, principal/fee math, NAV filtering — is the byte-for-byte same code path the Uniswap V3 fork test exercises, **verified by inheritance** (PR #43).
- **Per-chain scope:** PancakeSwap deploys V3 via CREATE2, so the NonfungiblePositionManager (`0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`) and factory (`0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`) — and therefore the pool bytecode and `slot0` ABI — are **byte-identical on every chain**. The adapter has **zero per-chain code branches**; only the constructor `navCalculator` and the `addMetaBalanceAdapter` pool list differ per deployment. Confirmed live: NPM + factory identical and `feeProtocol = 222825800 (> 255)` on Ethereum, Base, and Arbitrum (same value per fee tier). Optimism and Gnosis have **no** PCS V3 (no NPM code) so the adapter is never configured there. A single mainnet fork test is therefore sufficient for the chain-divergent code.
- **Math branches:** the `_slot0` override is exercised on the meaningful path by an in-range NFT (principal on both tokens + fee delta on both). Above-range, below-range, settled-`tokensOwed`, foreign-pool filter, and the 256-NFT iteration bound are all inherited and covered by the Uniswap V3 case (§2). **Coverage gap (documented, not covered):** farmed positions are staked into MasterChefV3 (`0x556B9306565093C855AEA9AE92A594704c2Cd59e`) and owned by it, not the user, so `NPM.tokenOfOwnerByIndex(account)` never sees them — the adapter misses farmed LP and pending CAKE entirely. Closing this requires a dedicated MasterChefV3 farm adapter (deferred).

## 2. Existing fork test coverage

- `test/balances/protocols/fork/UniswapV3PoolsMeta.fork.t.sol` — the inherited math (principal/fee branches, identity, filter) on the real mainnet WBTC/WETH 0.3% pool. PancakeSwap V3 inherits all of it unchanged except `_slot0`.
- `test/balances/protocols/fork/PancakeSwapV3PoolsMeta.Base.fork.t.sol` → `PancakeSwapV3PoolsMetaParityForkTest_Base` (pre-existing). Exercises the `_slot0` override on the real Base WETH/COW 0.25% pool, but the test holder's position is **closed** (liquidity 0) — so it only asserts the override **does not revert** and returns empty. It does not exercise the override on the principal-bearing path.

Both kept untouched as regression nets.

## 3. What this case adds

- A **real holder with an active (liquidity > 0) in-range position**, so the `_slot0` override is exercised on the path that matters: its `sqrtPriceX96`/`tick` feed `getAmountsForLiquidity`, and the principal amounts depend on the correctly-decoded `uint32 feeProtocol` read. A `uint8` read (the inherited Uniswap path) would revert here.
- **Ground-truth** equality against the protocol's own settlement (`NPM.decreaseLiquidity`) — see §8.
- Assertion that `protocolId == pancakeswap-v3` (the `_protocolId` override; §10).
- Mainnet coverage where both pool tokens (WETH/USDT) are registered Chainlink assets, so the position also values cleanly end-to-end.

## 4. Adapter formula recap

Identical to Uniswap V3 (the math is inherited); the only divergence is the `slot0` read in `_slot0`. For an NPM-managed NFT with `(tickLower, tickUpper, liquidity, feeGrowthInside0/1Last, tokensOwed0/1)`:

```
# Principal — amounts the protocol would return on decreaseLiquidity(L) at the current price.
(amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
    sqrtPriceX96,                       # <-- read via _slot0 (uint32 feeProtocol on PancakeSwap)
    TickMath.getSqrtRatioAtTick(tickLower),
    TickMath.getSqrtRatioAtTick(tickUpper),
    liquidity)

# Fee accrual since last position update — branches on current tick (read via _slot0).
fee0 = mulDiv(fgInside0 - feeGrowthInside0Last, liquidity, 2^128) + tokensOwed0
fee1 = mulDiv(fgInside1 - feeGrowthInside1Last, liquidity, 2^128) + tokensOwed1
```

Mirrors Uniswap v3-periphery's `PositionValue` exactly (with `FullMath.mulDiv` → OpenZeppelin `Math.mulDiv`, bit-equivalent). The `_slot0` override changes only how `sqrtPriceX96`/`tick` are decoded, not the math.

## 5. Cherry-picked accounts

| Holder | Address | Rationale |
|---|---|---|
| `ACTIVE_LP` | `0x783C3255340f8Ba524452A9BE5d12a77e9Ce1F53` | Holds an active in-range WETH/USDT 0.05% position (NFT #22279). One NFT exercises the full leg set the override touches: Supplied on both tokens + Fees on both tokens. (The same wallet also *farms* NFT #22272 via MasterChefV3 — the coverage gap in §1/§10.) |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,274,483** |
| Block timestamp | 1780943219 (`0x6a270973`) — **2026-06-08 18:26:59 UTC** |
| NPM | `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364` |
| Pool | `0x6CA298D2983aB03Aa1dA7679389D955A4eFEE15C` (WETH/USDT 0.05%) |
| Pool `feeProtocol` at block | `222825800` (> 255 → override required) |
| Adapter under test | `PancakeSwapV3PoolsMetaBalanceAdapter` |
| New fork-test contract | `PancakeSwapV3PoolsMetaParityForkTest` in `test/balances/protocols/fork/PancakeSwapV3PoolsMeta.fork.t.sol` |
| Companion fork-test (kept) | `PancakeSwapV3PoolsMetaParityForkTest_Base` (Base, closed position) |

### Per-NFT state at the pinned block

Sanity values consumed by the §4 math. The pool's NFTs churn owners (this wallet ↔ MasterChefV3), so the ground-truth test discovers active positions dynamically rather than hardcoding tokenIds.

| NFT | Pool | tickLower | tickUpper | currentTick | liquidity | tokensOwed0/1 | branch |
|---|---|---|---|---|---|---|---|
| #22279 | WETH/USDT 0.05% | -203910 | -198200 | -202019 | `64486550047297` | 0 / 0 | in-range — principal on both tokens + fee delta |

`sqrtPriceX96` at the block = `3253334064596920230428346`. token0 = WETH, token1 = USDT.

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-active-holder-mainnet.json` | Per-NFT machine-readable evidence pack with state, branch, and expected amounts |
| `query-live-balances.s.sol` | Forge script that forks Ethereum at a given block and prints the per-leg breakdown — used for ad-hoc cross-checks against the PancakeSwap UI / Debank |
| `script/development/deploy/deploy-pancakeswap-v3-meta.sh` | Meta-based dev-anvil deploy helper: deploys the adapter + `addMetaBalanceAdapter(adapter, instances)` (atomic register + seed, the ADR-0010 equivalent of the removed per-pool helpers) |

## 7. Expected balances

Values captured at the fork block in §5. Unlike the closed-form Uniswap V2 case, the test does **not** hardcode `EXPECTED_*` constants — it asserts the Supplied principal equals the protocol's own settlement (§8) and that both tokens are non-zero; the amounts below are the captured reference.

### 7a. Per-leg detail (every emission the adapter makes)

| Holder | Pool | NFT | Leg | Token | Amount (raw) | Amount (humanised) |
|---|---|---|---|---|---|---|
| ACTIVE_LP | WETH/USDT 0.05% | #22279 | Supplied | WETH | `272975132653695808` | 0.272975 WETH |
| ACTIVE_LP | WETH/USDT 0.05% | #22279 | Supplied | USDT | `238885630` | 238.885630 USDT |
| ACTIVE_LP | WETH/USDT 0.05% | #22279 | Fees | WETH | `187131191867546` | 0.000187 WETH |
| ACTIVE_LP | WETH/USDT 0.05% | #22279 | Fees | USDT | `326144` | 0.326144 USDT |

The `Supplied` legs come from `getAmountsForLiquidity(...)` (§4); the `Fees` legs from `mulDiv(feeGrowthInside − feeGrowthInsideLast, L, 2^128) + tokensOwed` (§4).

### 7b. Per-asset summary (the per-token NAV contribution)

Sum of the per-leg rows above for the same `(holder, pool, token)`.

| Holder | Pool | Token | Total (raw) | Total (humanised) | isDebt |
|---|---|---|---|---|---|
| ACTIVE_LP | WETH/USDT 0.05% | WETH | `273162263845563354` | 0.273162 WETH | false |
| ACTIVE_LP | WETH/USDT 0.05% | USDT | `239211774` | 239.211774 USDT | false |

## 8. Ground-truth cross-check

`test_groundTruth_principalEqualsNpmSettlement` runs the protocol's own settlement path against each active NFT and asserts the adapter's output equals what `NonfungiblePositionManager` would actually transfer:

| Test | NFT | Branch | Compared against |
|---|---|---|---|
| `test_groundTruth_principalEqualsNpmSettlement` | discovered dynamically (#22279 at this block) | in-range | `NPM.decreaseLiquidity(L)` |

The test reads the adapter's Supplied principal, then discovers the holder's active WETH/USDT 0.05% NFTs (`balanceOf` + `tokenOfOwnerByIndex`) and, impersonating the owner with `vm.prank` per NFT, calls `decreaseLiquidity` at full liquidity — whose return `(amount0, amount1)` is the principal the protocol would release. The adapter's principal must equal that **exactly** (both use the same round-down `SqrtPriceMath`).

This is the forked-EVM equivalent of a Tenderly `decreaseLiquidity` simulation: same NPM contract, same forked archive state at the same block, same EVM — no possibility of derivation drift. **Why no Python here:** the Uniswap V2 evidence pack uses a Python re-derivation because its dilution math is a small closed-form formula; the V3 family (Uniswap V3 and this) instead uses on-chain settlement, which is a stronger ground truth and avoids reimplementing the tick/fixed-point math. This case follows the Uniswap V3 precedent exactly.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-pancakeswap-v3-meta.sh` deploys + registers the meta-adapter on the local mainnet anvil so the dashboard renders the holder's position for a side-channel cross-check. Run after the dev anvil is up and the NAV proxy is deployed, then refork right before handoff so the live cross-check sees minutes of drift:

```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1
bash script/development/deploy/deploy-pancakeswap-v3-meta.sh 1 0x6CA298D2983aB03Aa1dA7679389D955A4eFEE15C
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The deployed adapter address is recorded in `script/development/state/1-addresses.json`. This step is separate from the fork test (which deploys its own adapter instance in `setUp()`) — it is purely the dashboard surface. The dashboard reads the adapter's `IPositionDescribable` layer, so the position renders under **PancakeSwap V3** with the **NFT #** label even where the typed `protocolId` is shared with Uniswap.

## 10. Test verdict (2026-06-08)

| Aspect | Status |
|---|---|
| Pre-flight: holder has an active in-range WETH/USDT 0.05% NFT | ✅ |
| `_slot0` override decodes `uint32 feeProtocol` on a live PCS pool (no revert) | ✅ |
| Active position → non-zero principal on both tokens (override fed `getAmountsForLiquidity`) | ✅ |
| Identity: positionId = `abi.encode(NPM, tokenId)`; protocolId = `pancakeswap-v3` | ✅ |
| Ground-truth: adapter principal == `NPM.decreaseLiquidity` (exact) | ✅ |
| Cross-chain: same NPM/factory bytecode + `feeProtocol > 255` on Base & Arbitrum | ✅ |
| Side channel: dev app vs Debank **and** PancakeSwap UI for #22279 | ✅ (sub-bp drift) |
| **Farmed positions + pending CAKE** | ❌ deferred — not covered (needs a MasterChefV3 farm adapter) |

**Mainnet: 3 / 3 fork tests pass; Base companion: 1 / 1.** The `_slot0` override is verified for in-wallet positions, and the cross-chain argument extends it to every chain by construction. PancakeSwap V3 is **not** marked fully verified until the farming-coverage gap is closed.

Two findings shipped/deferred (detail in `case-active-holder-mainnet.json`):
- **Fixed:** `protocolId` now `pancakeswap-v3` (was the inherited `uniswap-v3`).
- **Deferred:** farmed positions via MasterChefV3 are uncounted (material).

Run via:

```
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/PancakeSwapV3PoolsMeta*.fork.t.sol" -vv
```
