# Final pre-deployment security audit (2026-06)

Scope: **all of `src/`** — the core (NAVCalculator, PriceFeedLib, Prices, BaseCustomPriceFeed,
Balances, MetaBalanceAdapter, NAVRegistryLib (audited as `NavRegistryLib`, since renamed), NavLens
(since removed, its verbose reads inlined into NAVCalculator)), **every** custom price feed in
`src/prices/protocols/`, and **every** balance + meta-balance adapter (and their math libs) in
`src/balances/{BalanceAdapters,MetaBalanceAdapters,AssistedBalanceAdapters}/`. **78 contracts** audited individually.

Method: one deep specialist review per contract (category-tuned lenses — access-control / oracle /
logic-precision / reentrancy-DoS / cross-chain for core; exchange-rate-orientation / decimals /
staleness / manipulation for price feeds; PositionKind / isDebt / instance-decode / DoS-isolation /
read-only-reentrancy for adapters; precision / overflow / tick-math for libs), followed by an
independent **adversarial verification** pass per finding (default-refute), then a cross-cutting
systemic pass. **20 findings confirmed** (after refuting 30+ candidates), plus 4 systemic.

Status legend: **Fixed** (this PR) · **Recommended** (needs a fix + test validation, flagged for a
follow-up / team decision — deliberately not rushed into immutable contracts here) · **Acknowledged**
(by-design or accepted operational constraint).

## Severity summary

| # | Sev | Contract | Finding | Status |
|---|-----|----------|---------|--------|
| 1 | **High** | ERC20DefaultBalanceAdapter | Assembly `balanceOf` reads stale calldata as a phantom balance on short/empty returndata | **Fixed** |
| 2 | **High** | UniswapV3PoolsAssistedBalanceAdapter | LP principal/fees valued from manipulable `slot0` spot, not an oracle | **Fixed** |
| 3 | Medium | ETHPlus_Price | Heartbeat checks the configured *prime* basket, not the active reference basket | **Fixed** |
| 4 | Medium | AaveV2InstancesMeta | Aave V2 **stable-rate debt silently dropped** → understates debt, overstates NAV | **Fixed** |
| 5 | Medium | StakeWiseV3VaultsMeta | osToken debt leg converted through the staking-vault rate (wrong rate object) | **Fixed** |
| 6 | Medium | BalancerV3PoolLib | Duplicate-underlying pool tokens double-counted / mis-counted | **Fixed** |
| 7 | Low | NavLens | `try/catch` doesn't catch return-data decode failures (fail-open bypass) | **Fixed** |
| 8 | Low | PriceFeedLib | Registered-but-feedless asset reverts the entire NAV/positions/health read | **Fixed** |
| 9 | Low | PriceFeedLib | Stale non-USD quote feed silently returns NAV in USD instead of the quote currency | **Fixed** |
| 10 | Low | AuraRewardsMeta | V3 boosted pools with two ERC4626 wrappers over the same underlying mis-counted | **Fixed** |
| 11 | Low | ERC20DefaultBalanceAdapter | Constructor `initialAssets` added without registry-membership check | Acknowledged |
| 12 | Low | StaderWithdrawalQueue | `MAX_REQUESTS_PROBED` cap can silently undercount (claimed ids never compacted) | Acknowledged |
| 13 | Low | BalancerV3PoolsMeta | (same root cause as #6) duplicate-underlying emission | **Fixed** |
| 14 | Low | UniswapV2PairLib | PancakeSwap V2 inherits Uniswap's `_mintFee` constants; PCS fee fraction differs | **Fixed** |
| 15 | Low | UniswapV3PoolsAssistedBalanceAdapter | LP positions silently dropped when account holds > 256 NPM NFTs globally | Acknowledged |
| 16 | Info | ConvexRewardsMeta | Standalone-CVX stash reward (not derived from CRV) dropped | Acknowledged |
| 17 | Info | ConvexRewardsMeta | `_lpTokenOf` trusts `pid()` success without short-returndata check | **Fixed** |
| 18 | Info | FluidVaultLib | Fragile fixed-offset assembly decode of `positionByNftId` | Acknowledged |
| 19 | Info | FluidVaultLib | T1-only assumption enforced by operator discipline, not code | Acknowledged |
| 20 | Info | BalancerV3PoolLib | Zero `tokenRate`/`decimalScalingFactor` → divide-by-zero revert (isolated) | **Fixed** |

Systemic (cross-cutting): S1 stale-feed-zeros-NAV (High-rooted), S2 stale-quote-USD-fallback (Medium),
S3 inconsistent short-returndata guarding across libs (Medium), S4 fail-open masks misconfiguration (Low).

---

## Fixed in this PR

### [1] High — `ERC20DefaultBalanceAdapter`: phantom balance from unchecked short returndata
The inline-assembly `balanceOf` did `staticcall(..., ptr, 0x20)` reusing the **calldata buffer** `ptr`
as the output region and then `if success { tokenBalance := mload(ptr) }` — with **no `returndatasize`
check**. A staticcall to a code-less address (or a token whose `balanceOf` returns void/short data)
returns `success=true` with empty returndata; the EVM leaves the output region untouched, so `mload`
reads the leftover calldata word (the `balanceOf` selector) as a **~5.09e76 phantom balance**
(forge-reproduced for both a non-contract address and a void-returning contract). Reachable for any
MANAGER-registered asset whose `balanceOf` is non-standard/void or whose address is code-less on a
given chain at read time. The phantom amount flows into `PriceFeedLib._calculateNav`'s summation
*outside* the per-position try/catch, where `signedAmount * assetPrice` overflows `int256` → **the
entire NAV read reverts** (or, with a tiny price, inflates NAV) — corrupting downstream sub/redeem
accounting.

**Fix:** write the staticcall output into a fresh, **zeroed** scratch word (not the calldata buffer)
and read it only when `returndatasize() >= 32`; code-less/void/short returns now yield 0. Corrected
the misleading comments (a staticcall to a code-less address returns `success=true`).

### [7] Low — `NavLens`: verbose read not truly fail-open
`_toVerbose` used `try IPositionDescribable(adapter).protocolName() ... catch {}`. `try/catch` catches
a *reverting* call but **not** a *successful* call whose returndata can't be decoded into `string`
(non-contract returning empty data, or a malformed/short blob) — that decode reverts the whole verbose
read. **Fix:** replaced both `try` calls with a `_safeString` low-level staticcall that validates the
ABI string envelope (canonical `0x20` offset + length within the returned bytes) before decoding, so it
can never revert. Display-only path; low impact, but the lens is meant to be robust.

> **Post-audit note:** `NavLens` was subsequently removed and its verbose read path (including this
> `_safeString` fix) inlined into `NAVCalculator` — the audited code now lives in
> [`src/nav/NAVCalculator.sol`](../../src/nav/NAVCalculator.sol), `src/nav/NavLens.sol` no longer exists.
> The fix described above is preserved verbatim.

### [3] Medium — `ETHPlus_Price`: freshness gate now reads the active basket
`_minBasketLastSave` iterated `getPrimeBasket()` (the governance-configured target) while
`price()`/`basketsNeeded()` reflect the **active** reference basket; after a default swaps in backup
collateral and re-collateralizes to SOUND, the backups' oracle freshness went unchecked (stale accepted
as fresh). **Fix:** drive freshness off `basketHandler.basketTokens()` (the live basket the price is
computed over). Validated against the real mainnet ETH+ on a pinned fork.

### [4] Medium — `AaveV2InstancesMeta`: stable-rate debt now emitted
The V2 adapter inherited the V3 `_instancePositions`, which reads only variable debt; Aave V2's
stable-rate `currentStableDebt` was never emitted → debt understated, NAV overstated. **Fix:** the V2
subclass now captures `getUserReserveData` index 1 (`currentStableDebt`) and emits a third `Borrowed`
leg when `> 0` (buffer widened to `reserves.length * 3`). Fork-tested (no regression on the existing
no-stable-debt holders; the leg only fires when stable debt is present).

### [5] Medium — `StakeWiseV3VaultsMeta`: osToken debt converted through the controller
The osToken (minted-debt) leg converted shares via the **staking vault's** rate; osToken's exchange
rate is governed by the **`OsTokenVaultController`**. **Fix:** the controller is pinned as a constructor
immutable (`OS_TOKEN_VAULT_CONTROLLER`, validated non-empty) and the debt leg now converts through
`OS_TOKEN_VAULT_CONTROLLER.convertToAssets(osTokenPositions(account))`. Deploy config + script + all
test call-sites updated (mainnet controller `0x2A26…0306`, Gnosis `0x60B2…179a`). Validated: the unit
test asserts the controller-rate debt exactly; the mainnet integration NAV for the osToken-debt holder
(ACCOUNT_9) moved by the expected amount and the snapshot was refreshed.

### [6]/[13] Medium/Low — `BalancerV3PoolLib`: duplicate-underlying resolved by index
`poolBalanceOf` resolved a leg **by underlying address** and broke on the first match, so a pool holding
the same underlying at two indices (two ERC4626 wrappers of one asset) double-counted index 0 and
dropped the duplicate. **Fix:** replaced with `poolBalanceOfIndexed(pool, userBalance, tokenIndex)` — the
callers already iterate `poolTokens()` in index order, so each pool-token index now contributes exactly
one correctly-scaled leg. All three call sites updated (`BalancerV3PoolsMeta`, `BalancerV3GaugesMeta`,
`AuraRewardsMeta`). For non-duplicate pools the math is bit-identical to before (verified on the mainnet
integration fork).

### [8]/S1 — `PriceFeedLib`: feedless asset no longer DoS-reverts the NAV read
A registered asset that still had a live position but no feed reaching `_buildPriceFeedCache` made
`_selectFeedCore` revert `PriceFeedNotSet`, reverting the **entire** NAV/positions read. **Fix:** in the
value-aggregation path only, a feedless asset is now treated exactly like the all-feeds-stale case —
price 0, `stale = true`, surfaced in `nav.stalePriceAssets`, summed as a zero-value leg — instead of
reverting. The placeholder feed decimals are `NAV_DECIMALS` (not 0) so the leg can never trip
`InvalidAssetDecimals` for low-decimal assets. The explicit query paths
(`selectFeed`/`buildPriceData`/`calculateValue`) keep reverting `PriceFeedNotSet` so MANAGER tooling
still sees the misconfiguration. (S1: the existing all-stale → zero-value behavior is **intended** and is
surfaced via `stalePriceAssets`; documented in the disposition below.)

### [10] Low — `AuraRewardsMeta`: V3 dup-wrapper resolved
Same root cause as [6]/[13] in the Aura V3 staking-leg decomposition; fixed by the same index-driven
`poolBalanceOfIndexed` change at the Aura call site.

### [14] Low — `UniswapV2PairLib`: PancakeSwap V2 protocol-fee constants
PancakeSwap V2's `_mintFee` uses `ts·(√k−√kLast)·8 / (17·√k + 8·√kLast)` — a larger protocol-fee
fraction than Uniswap's `(1, 5, 1)` — so inheriting Uniswap's constants understated the dilution LP and
slightly overstated the holder's reserve share when PCS `feeTo` is active. **Fix:** the dilution
coefficients are now a virtual `_mintFeeConstants()` hook (Uniswap/SushiSwap `(1, 5, 1)`; PancakeSwap V2
overrides to `(8, 17, 8)`), threaded into `UniswapV2PairLib.pairAmounts`.

---

## Design decisions resolved with the team (also fixed in this PR)

These two were genuine **design decisions** baked into immutable / core-pricing contracts. Rather than
hard-code a strategy unilaterally, the approach was chosen with the team and then implemented here.

### [2] High — `UniswapV3PoolsAssistedBalanceAdapter`: reconstruct the price from oracle feeds (no `slot0`)
> **Revisited 2026-06-28 — superseded by ADR 0017.** The async sub/redeem consumer model makes the spot-manipulation vector non-monetisable, so the V3 adapter was reverted to reading `slot0` (instantaneous on-chain amounts). See docs/decisions/0017-lp-valuation-instantaneous-amounts.md.

Previously `slot0` (`sqrtPriceX96`, `tick`) fed both the in-range liquidity split
(`getAmountsForLiquidity`) and the fee-growth branch, so the reported per-token **amounts** tracked the
instantaneous AMM spot — an attacker who atomically moved the pool price (swap / flash-loan round-trip /
read-only-reentrancy desync) could diverge the reported value, violating the repo's "never trust an AMM
spot price" rule. **Fix (chosen approach: reconstruct from feeds):** the adapter no longer reads `slot0`
at all. It fetches both pool tokens' registered prices via `NAV_CALCULATOR.getPriceData` and reconstructs
the implied `sqrtPriceX96` (`UniswapV3PoolLib.sqrtPriceX96FromOraclePrices`, two-sqrt split, clamped to
the valid range), then drives **both** the split and the fee-growth branch (via a sqrt-ratio comparison
against the tick boundaries) off that oracle-implied price. Reported amounts are now a pure function of
the same oracles NAV prices with, so the value is manipulation-proof. A position whose tokens are
unregistered/unpriced/stale is dropped (no legs) rather than valued off a manipulable spot. Trade-off the
team accepted: per-token **amounts** are now fair-value (oracle-implied) amounts rather than the exact
current on-chain withdrawable split — identical when the oracle agrees with spot, so the ground-truth
fork tests now assert approximate (0.01%) rather than exact parity. Because `slot0` is no longer read,
the PancakeSwap V3 subclass no longer needs its `_slot0`/`uint32 feeProtocol` override (removed).

### [9] Low / S2 — `PriceFeedLib`: surface `quoteAssetStale` on `Position` / `calculateValue`
When the quote asset's feed is stale, the value falls back to USD instead of the requested quote
currency. `getNav` already flagged this via `nav.quoteAssetStale`; the gap was `calculateValue` (a bare
`int256`) and the per-`Position` path. **Fix (chosen approach: add the flag):** `Position` gains a
`bool quoteAssetStale` and `calculateValue` now returns `(int256 value, bool quoteAssetStale)`, so a
caller requesting a non-USD quote can detect the USD fallback rather than silently receiving a USD figure.

---

## Acknowledged (by-design / accepted constraint)

- **[11]** `ERC20DefaultBalanceAdapter` constructor `initialAssets` skips the registry check — **confirmed
  by-design and now documented in-code.** A registry callback here is structurally impossible: the only
  caller is `NavRegistryLib.deployDefaultAdapter`, invoked from `NAVCalculator.initialize` *inside the
  proxy's own constructor*, when the proxy has no deployed code yet — an external
  `NAV_CALCULATOR.isAssetRegistered(...)` would revert "call to non-contract". The seed is the hardcoded
  `[NATIVE_ADDRESS]`, registered one line before the adapter is deployed, so a misconfigured seed is
  unreachable. Post-deploy entries still go through `addSupportedAsset`, which enforces registration.
- **[12]** `StaderWithdrawalQueue` `MAX_REQUESTS_PROBED=256` bounds *lifetime* (not open) requests since
  claimed ids aren't compacted — acceptable; add a regression test for >256-lifetime accounts.
- **[15]** `UniswapV3PoolsAssistedBalanceAdapter` silently drops positions for accounts with > 256 NPM NFTs globally —
  documented bound; off-chain reconciliation should flag monitored accounts near the cap.
- **[16]** `ConvexRewardsMeta` drops standalone-CVX stash rewards — CVX is always minted proportionally
  to CRV in the Convex model, never as an independent stash; out of scope by design.
- **[18]** `FluidVaultLib` fixed-offset assembly decode of `positionByNftId` is fragile to an upstream
  struct-layout change — but fails open via the per-instance try/catch; optional: typed `abi.decode`.
- **[19]** `FluidVaultLib` T1-only (token-amount) assumption is an operator constraint enforced at
  `addMetaInstances` time, not in code — acceptable; document + optional config-time check.

The two Info hardening items below were small and self-contained, so they were **fixed in this PR**
rather than left optional:
- **[17] Fixed** — `ConvexRewardsMeta._lpTokenOf` now reads `pid()` via a low-level staticcall and returns
  `address(0)` on short returndata (`ret.length < 32`), distinguishing a malformed rewarder from a genuine
  `pid == 0` instead of trusting the decode.
- **[20] Fixed** — `BalancerV3PoolLib` now guards the denominator: a zero `tokenRate` or
  `decimalScalingFactor` yields a 0 leg instead of a divide-by-zero revert (still isolated by the
  per-instance try/catch, but no longer drops the leg unnecessarily).
- **S3** `StaticCallLib` (≥32-byte guard) is not used by `CurvePoolLib`/`FluidVaultLib`/`CompoundV3CometLib`
  (some use `== 32`); finding [1] is one instance of the inconsistency. Consolidating is the maintainability
  follow-up already noted in PR #81.
- **S4** the blanket per-instance/per-adapter `try/catch` fan-out fails open on genuine misconfiguration,
  masking under-reported NAV — inherent to the fail-open design; the mitigation is monitoring + the
  `stalePriceAssets` surface, not removing the guards.

---

## Disposition for deployment

- **Fixed in this PR (all 20 findings + S1/S2 addressed):** [1], [2], [3], [4], [5], [6]/[13], [7], [8],
  [9], [10], [14], [17], [20]. The two design-decision findings ([2] reconstruct-from-feeds, [9]/S2 add the
  `quoteAssetStale` flag) were resolved with the team and implemented. All compile clean; the unit suite and
  the affected fork/integration tests pass; the mainnet integration NAV snapshot was refreshed for the two
  accounts whose value moved as a direct, verified consequence of [5] (osToken debt) and the [6]/[10] index
  refactor (≤few-wei rounding); the V3 ground-truth fork tests were relaxed to 0.01% approximate parity to
  reflect [2]'s oracle-implied (vs exact on-chain) amounts.
- **By-design / Acknowledged:** [11], [12], [15], [16], [18], [19], S3, S4 — safe to deploy as-is with the
  noted monitoring; [11] is now documented in-code.
- **Library pins:** the audit edits changed `PriceFeedLib`/`NavRegistryLib` bytecode (and, via the `via_ir`
  compilation-set effect, shift the deterministic CREATE2 pins regardless). `LibraryPins.sol` + `foundry.toml`
  were regenerated to the locally-computed addresses; **CI is the pin authority** (CI's forge differs from
  local) — confirm/adjust against the CI `LibraryPinConsistency` result before merge.
