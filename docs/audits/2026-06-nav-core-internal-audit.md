# Internal security audit — NAV core, Prices, Balances (2026-06)

Scope: `src/nav/` (NAVCalculator, NavLens, NavRegistryLib), `src/prices/` (Prices,
PriceFeedLib + custom feeds), `src/balances/` (registry framework + all per-protocol
balance adapters). Bridge was out of scope.

Method: multi-agent review — per-lens passes over the core framework (access-control /
upgradeability, oracle correctness, logic / precision, reentrancy / external-call) plus
per-family passes over the adapters (lending / meta, AMM / LP, staking / rewards /
queues). Every candidate finding was independently adversarially verified (default-refute)
before inclusion. 12 raw candidates → **6 confirmed**.

Five are fixed in this PR; the sixth (#5) is a deprecated opt-in deploy path and is
documented rather than code-changed (see its note). None affect funds directly (this layer
is read-only accounting), but one is a denial-of-service on the core NAV read path.

| # | Severity | Area | Status |
|---|----------|------|--------|
| 1 | High | `PriceFeedLib._getPositionBalances` buffer overflow (V3 multi-leg) | Fixed |
| 2 | Medium | `SparkLend` per-asset filter scans only the first reserve | Fixed |
| 3 | Low | `SparkLend.getAdapterBalances` marks every net position as debt | Fixed |
| 4 | Low | Aura/Convex `_instanceAssets` dedup loop emits duplicates | Fixed |
| 5 | Low | Legacy split deploy path leaves proxy on no-auth UUPS placeholder | Documented (see note) |
| 6 | Info | Aura V2 `getPoolId()` revert drops reward legs too | Fixed |

---

## 1 — High — NAV read buffer overflow bricks `getAccountNav` for an account

**Files:** `src/prices/PriceFeedLib.sol` (`_getPositionBalances`),
`src/balances/protocols/uniswap/UniswapV3PoolsMetaBalanceAdapter.sol`,
`src/balances/protocols/pancakeswap/PancakeSwapV3PoolsMetaBalanceAdapter.sol`.

`_getPositionBalances` sized its scratch buffer as
`2 * (totalAdapters + metaInstanceTotal) * assetCount`, assuming each
(adapter-or-meta-instance, asset) pair contributes at most 2 rows. That holds for the
lending/LP-pool meta adapters but is violated by the Uniswap V3 / PancakeSwap V3 meta
adapter, which iterates an account's LP NFTs in a pool (up to `MAX_POSITIONS = 256`) and
emits up to **4 rows per NFT** (Supplied ×2 + Fees ×2) — up to ~1024 rows for a single
instance referencing only 2 assets, ~12× its budgeted allotment.

The amplified array is returned correctly-sized by the adapter, so neither the
per-instance try/catch in `MetaBalanceAdapter` nor the per-adapter try/catch in
`PriceFeedLib` catches anything. The overflow happens in `_getPositionBalances`' own copy
loop (`temp[count++]`), outside any try/catch: once `count` reaches `maxPositions` the
write triggers `Panic(0x32)` and the whole call reverts.

**Impact:** `getAccountNav`, `getAccountPositions`, `hasPositions`, and `getAssetsWithPositions` revert
(hard, uncatchable) for any account whose emitted rows exceed the global budget — a heavy
V3 LP hits this naturally, and an external party can push a victim account over the edge by
transferring in-range LP NFTs (ERC-721). The buffer is per-call with `account` as a
parameter, so other accounts are unaffected (hence High, not Critical), but NAV is the
accounting primitive downstream sub/redeem layers read.

**Fix:** Size the buffer from the **actual** rows the adapters return. A first pass queries
each adapter once and retains its array; a second in-memory pass counts exactly the rows
that survive the registered-asset + `assetFilter` predicate (`_isCounted`); the copy buffer
is then allocated to that exact count. Counting only the surviving rows — rather than the
raw sum of `adapterPositions.length` — also avoids over-allocating when rows are filtered
out. Each adapter is still called exactly once. The bound is now exact and overflow-proof
regardless of per-instance leg count.

## 2 — Medium — `SparkLend` per-asset filter only checks the first reserve

**File:** `src/balances/protocols/SparkLendBalanceAdapter.sol:118-127`

The `assetFilter` membership scan placed `break;` outside the `if`, so the loop exited
after iteration 0 and only ever compared `assetFilter` against `active[0]`. Any registered
Spark reserve that is not first in the reserves∩registered intersection failed the
membership check and the function returned an empty array.

**Impact:** Per-asset reads (`getAccountPositionsForAsset` and the per-asset value path,
which forward a non-zero `assetFilter` into `getAdapterPositions`) silently under-report —
return zero — a real Spark supply/collateral/borrow leg for every reserve except the first.
The aggregate NAV path uses `assetFilter == address(0)` and skips the block entirely, so
aggregate NAV is unaffected (hence Medium). The silent zero can mask missing positions for
off-chain reconciliation consumers.

**Fix:** Brace the conditional and break only on a match.

## 3 — Low — `SparkLend.getAdapterBalances` marks every net position as debt

**File:** `src/balances/protocols/SparkLendBalanceAdapter.sol:80-88`

The net amount was computed correctly for both branches but `isDebt` was hard-coded `true`,
so a pure supplier (debt == 0) was reported as if it owed that amount — inverting the sign.
This contradicts the sibling `getAdapterBalanceForAsset` and the NAV-path
`getAdapterPositions`.

**Impact:** `getAdapterBalances` is not on the NAV trust path (NAV uses
`getAdapterPositions`) and every in-repo caller discards `isDebt`, so impact is confined to
external/off-chain callers of this public accessor (hence Low). Still a genuine correctness
bug.

**Fix:** Set the flag from the comparison (`isDebt` only when `debt > supply`).

## 4 — Low — Aura/Convex `_instanceAssets` dedup loop emits duplicates

**Files:** `src/balances/protocols/AuraRewardsMeta.sol:290-295`,
`src/balances/protocols/ConvexRewardsMetaBalanceAdapter.sol:240-245`

The reward-token dedup loop had `break;` outside the `if`, so it only ever compared a
candidate token against `rwd[0]` (the main reward token, BAL/CRV). An extra-reward token
equal to AURA/CVX, or any duplicate extra-reward token, was not detected and got appended
again, so `underlyingAssetsSupported()` could return duplicate addresses.

**Impact:** Asset-enumeration only, not the NAV value path — the single on-chain consumer
(`NavRegistryLib.getAdaptersForAsset`) uses it as a membership check (`break` on first
match), so duplicates do not double-count. The concrete impact is duplicate addresses in
the public asset-enumeration reads consumed by off-chain config/registration tooling (hence
Low).

**Fix:** Move the `break` inside the match branch, in both files.

## 5 — Low — Legacy split deploy path leaves the proxy on a no-auth UUPS placeholder

**Files:** `script/deploy/02_2_DeployNAVProxy.s.sol` (legacy branch),
`src/utils/UUPSPlaceholder.sol`

The NAVCalculator proxy is created (via canonical CREATE2, deterministic address) pointing
at `UUPSPlaceholder`, whose `_authorizeUpgrade` is an empty no-op — any caller may
`upgradeToAndCall` while the proxy still points at it. The **default** deploy uses
`AtomicNAVProxyDeployer`, which does deploy + upgrade-to-real-impl + initialize + grant +
renounce in a single constructor tx, leaving no gap. The opt-in `USE_LEGACY_DEPLOY=1` path
splits these into separate broadcast txs, so between proxy creation and the deployer's
upgrade an attacker who observes the creation (or front-runs on a not-yet-launched chain,
since the address is identical cross-chain) can seize `DEFAULT_ADMIN_ROLE`/`MANAGER`.

**Status — documented, not code-changed.** This is a deploy-script risk on a deprecated,
explicitly opt-in path that already carries an in-code warning (`// Legacy multi-tx path
(each step can be front-run).`) and is steered away from by every deploy doc. A correctly
executed (atomic, default) deploy yields a proxy whose live impl has a proper
`_authorizeUpgrade`. **Operational guidance: never use `USE_LEGACY_DEPLOY=1` on a public
network; always deploy atomically.** If the legacy path is ever retained for production it
should deploy the proxy with init data so upgrade+initialize are atomic with creation, or
pin the placeholder's `_authorizeUpgrade` to the deployer.

## 6 — Info — Aura V2 `getPoolId()` revert drops reward legs too

**File:** `src/balances/protocols/AuraRewardsMeta.sol:159`

In the V2 staking-decomposition block, a reverting `getPoolId()` executed
`return positions;`, bailing out of the **entire** function and skipping the BAL / extra /
AURA reward legs (steps 2-4), which do not depend on the pool decomposition. Only reachable
for a malformed/non-standard V2 instance (a real Balancer V2 pool always implements
`getPoolId()`), so in practice this only fires under trusted-role misconfiguration — hence
Info. Still a latent control-flow defect.

**Fix:** Wrap only the V2 shares math in `if (poolIdOk)` so a `getPoolId()` failure skips
just the staking legs and falls through to the reward legs.
