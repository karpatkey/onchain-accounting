# `MetaBalanceAdapter._getAssetInfo` — registry re-fetch cost, measured

Investigation record, 2026-07-28, against `main` @ `b652ac47`. **Not an ADR** — it records measurements and
the file/line facts a fix needs, so they do not have to be re-derived.

**Outcome: Fix B (expose an O(1) single-asset getter) was chosen**, assigned to the session that already
owns `INAVCalculator.sol` + `NAVCalculator.sol` for a concurrent PR, so the two-library pin regen absorbs
both moves once. Fix A (thread a per-adapter snapshot through `_instancePositions`) was **rejected** —
worse result for ~21 adapter rewrites, once the pin cost is already sunk.

Reproduce with `test/balances/GetAssetInfoGasScaling.t.sol` (this branch). That test is the agreed
regression test for the fix; it is assertion-free on absolute gas by design, so it cannot rot into a
brittle threshold.

> **Line numbers**: verified against `main` @ `b652ac47`. Note the figures circulating before this
> investigation (`_getAssetInfo` at `:422`, `_eligible` at `:437`) were **stale** — the file grew during the
> #175–#183 wave. On `b652ac47` they are `:461` and `:470`. Re-check after the pin-regen PR lands, since
> that tree will differ again.

---

## What the code does today

`MetaBalanceAdapter._getAssetInfo` (`src/balances/MetaBalanceAdapter.sol:461`, body at `:463`):

```solidity
return RegisteredAssetLib.find(NAV_CALCULATOR.getRegisteredAssets(), asset);
```

Every call fetches the **whole** registered-asset array across an external call and linear-scans it.
`_eligible` (`:470`) wraps it as "the filter-then-registry gate every per-instance read applies before
emitting a leg".

## 1. Cost of one call

Mocks deployed in `setUp()`, never in the test body — forge resets the EIP-2929 access list between them,
so the first touch in a body is genuinely cold and the second is warm. Bare external-hop baseline:
**3,096 cold / 600 warm**, so essentially all of the below is fetch-and-scan.

| registered assets | cold (first) | **warm (marginal)** | miss (full scan) | O(1) cold | O(1) warm |
|---|---|---|---|---|---|
| 43 (mainnet today) | 359,109 | **100,576** | 100,778 | 5,926 | 3,930 |
| 65 | 542,207 | **151,675** | 151,880 | 5,926 | 3,930 |
| 80 | 667,359 | **186,826** | 187,036 | 5,926 | 3,930 |
| 100 | 834,623 | **234,089** | 234,302 | 5,927 | 3,930 |

- Linear at **~2,342 gas per registered asset**. The O(1) column is flat — 5,926/3,930 at every size.
- **~25× the O(1) equivalent at 43 assets, ~60× at 100.**
- Cold is ~3.5× warm because the array is cold storage (`Asset` = 1 packed slot for `address`+`uint8`,
  plus 1 slot for a ≤31-byte `symbol`, so ~2 slots/asset × 2100).
- Hit and miss differ by <210 gas: **the fetch is the cost, not the scan.** An asset at index 0 saves
  nothing, so "reorder the registry" is not a mitigation.
- Cross-check: 100,576 for one lookup is consistent with the independently observed StakeWise Tier-2
  label figure of ~150k at 43 assets (one `_getAssetInfo` + label work).

## 2. It is on the NAV path — but the failure mode is availability, not over-report

Call-site census: **42 sites across 21 files** (not the 11 originally suspected). **33 are on the
position-emission path** — 31 in `_instancePositions`, plus `getAdapterPositions` and `_rows` — and 8 more
are leg-emission helpers reached from it (`_addReward`, `_appendCollateral`, `_appendBorrow`,
`_debtReportable`, `_hasUnreportableDebt`, `_hasUnreportableDebtByScan`). Exactly **one** is label-only.
So `getAccountNav` pays this per token per instance.

**The obvious over-report argument does not hold, because #178/#182 closed it.**
`MetaBalanceAdapter._positionsForInstances:259` **reverts `InstanceGasExhausted`** on a starved instance
rather than absorbing it, and `PriceFeedLib._reraiseIfInstanceExhausted` honours that selector regardless
of what the gas figures say. A gas-starved meta adapter therefore fails the **whole NAV read loudly**; it
does not drop a debt leg and silently raise NAV.

Residual silent-absorb windows are `positionIds` (`MetaBalanceAdapter:108-110`) and `_assetsForInstances`
(`:279-282`) — neither feeds NAV value.

⇒ Treat this as **denial-of-read**, not a correctness bug. Serious, but do not prioritise it as an
over-report. The stipend is `available - available/64` (`GasStipendLib.stipendFrom:46`).

## 3. Worst realistic multiplication, and it is super-linear

50 lookups in one call — the Balancer V2 ManagedPool token cap, whose token list is mutable after
registration. Measured as a real loop (1 cold + 49 warm), **not** multiplied:

| registered assets | O(N) total | O(1) total | saving |
|---|---|---|---|
| 43 | **6,274,562** | 263,843 | 6.01M |
| 65 | 10,451,223 | 277,843 | 10.17M |
| 80 | 13,668,417 | 277,843 | 13.39M |
| 100 | **18,459,988** | 277,844 | 18.18M |

**One 50-token instance costs 6.27M gas in registry lookups alone at today's 43 assets — ~21% of a 30M
block. At 100 assets it is 18.5M, over half a block, for a single instance.**

**It is worse than linear** — this is the finding that changed the decision. 50 × 100,576 = 5.03M, but the
measured loop is 6.27M (**+25%**): each fetch allocates a fresh N-struct array in memory that is never
freed, so memory expansion is quadratic in token count. Token scaling at N=43 (warm basis):

| tokens | O(N) | O(1) |
|---|---|---|
| 4 | 378,377 | 19,069 |
| 8 | 775,736 | 37,175 |
| 16 | **1,630,471** | 73,415 |
| 32 | **3,580,016** | 146,003 |
| 50 | **6,099,888** | 199,836 |

16→32 is 2.20× for 2× the tokens; 32→50 is 1.70× for 1.56×. (The 2-token row measured 441,201 — above the
4-token row — because it is the first loop iteration and carries cold-probe effects. Ignore it; use rows
4–50 for the slope.)

## 4. The O(1) path already exists in storage and is unexposed

| what | where |
|---|---|
| `mapping(address => uint256) private _assetIndex` — **1-based**, 0 = not registered | `src/nav/NAVCalculator.sol:44` |
| `INAVCalculator.Asset[] private _registeredAssets` | `src/nav/NAVCalculator.sol:41` |
| **`_getRegisteredAsset(address)` — already exactly the O(1) lookup, but `internal`** | `src/nav/NAVCalculator.sol:785` |
| `isAssetRegistered(address)` — O(1) but returns only a **bool** | `src/nav/NAVCalculator.sol:655` |
| index maintained on register | `src/nav/NAVRegistryLib.sol:93` |
| index maintained on unregister (swap-and-pop) | `src/nav/NAVRegistryLib.sol:114`, `:117` |
| `getRegisteredAssets()` / `getAssetCount()` — the O(N) surface in use | `src/nav/NAVCalculator.sol:645`, `:650` |

Exposing it is **additive** — a new view function, no behaviour change.

### Signature caveat — do not just flip the visibility

`_getRegisteredAsset` **reverts `AssetNotFound()`** when the asset is absent. Adapters need the
non-reverting `(INAVCalculator.Asset memory, bool found)` shape, because "not registered" is an ordinary,
expected outcome on the emission path — `_eligible` returns `false` and the leg is skipped. A reverting
getter would turn every unregistered token into a failed instance read.

So the fix adds a **new non-reverting variant** (e.g.
`getRegisteredAsset(address) returns (Asset memory, bool)`); it does not merely widen `:785`.

## 5. File set, and the pin coupling

**Fix B (chosen):** `src/nav/INAVCalculator.sol` (interface), `src/nav/NAVCalculator.sol` (getter),
`src/balances/MetaBalanceAdapter.sol` (`_getAssetInfo` body). Concrete adapters unchanged — all 42 call
sites go through `_getAssetInfo`/`_eligible`.

**Pin impact: this moves BOTH library pins.** `INAVCalculator.sol` is imported by
`src/prices/PriceFeedLib.sol:11` **and** `src/nav/NAVRegistryLib.sol:6`, so it is inside both libraries'
compilation closures. Per the closure model, a change there is not pin-neutral. This is why the fix was
folded into the session already touching those files, ahead of the pin regen, rather than landing
separately.

**Fix A (rejected):** fetch the registry once inside the adapter's own populated path and thread it
through `_instancePositions`. Meta-adapter-only, so pin-neutral (the #186 precedent), but ~21 adapters
change and the result is worse — one fetch **per adapter** rather than none.

### `BALANCE_ADAPTERS.md` §6.4 must be updated by whoever implements

§6.4 "Rejected: registry fetch-once threading" records this whole class as deliberately rejected, because
NAV has no synchronous on-chain consumer (ADR 0017) so the gas has no payer. **That rationale is still
true for cost and it predates #178/#182** — it does not address the availability failure, which is a
different argument the rejection never weighed. Note also that §6.4 rejected threading *from
`PriceFeedLib`/`NAVCalculator`*, whose measured defect was eagerly fetching for adapters that early-return
(empty-account read <100k → ~166k). Fix B avoids that entirely: same lazy call sites, same call count,
O(1) payload. Do not let §6.4 stand unqualified against Fix B.

## Caveat, and the one number still owed

These are **mock-calibrated**, not measured against a deployed `NAVCalculator` with its libraries linked.
The mock replicates the exact ABI shape and storage layout of `getRegisteredAssets()`, and the StakeWise
~150k cross-check supports it, but treat the figures as calibration.

**➜ Action for whoever runs the from-scratch deploy's fork rehearsal
(`script/deploy/preflight/rehearse_fork.sh`): take the production number there.** A mainnet fork has a
real `NAVCalculator` at 43 registered assets, so a single `getAccountNav` on a multi-token instance yields
the true figure at no extra setup cost. Record it back here.
