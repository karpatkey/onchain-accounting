# Reading NAV in slices (paginated NAV)

`NAVCalculator.getAccountNav` scans **every** registered balance adapter in one `eth_call`. That cost grows with
the asset registry and the adapter set, and past a node's `eth_call` gas cap the complete read stops returning
anything at all — not a degraded NAV, no NAV, and no smaller question to ask.

`getAccountNavForAdapters` is the smaller question:

```solidity
function getAccountNavForAdapters(address account, address quoteAsset, address[] calldata adapters)
    external view returns (PartialNAV memory);
```

It values **only** the adapters you name, and returns a `PartialNAV` — a type deliberately distinct from `NAV`, so a
slice cannot be passed where a complete NAV is expected.

---

## What it does not do

Read this before reaching for it.

- **It does not reduce the total gas of reading a NAV.** It reduces the gas of *one call*. Reading the whole
  portfolio in slices costs slightly *more* in total, because per-call overhead is paid per slice.
- **It does nothing for an on-chain consumer.** A contract that must read a NAV inside a transaction needs one
  complete answer in one frame; it cannot make several `eth_call`s and add them up. If an on-chain consumer is
  hitting the block gas limit, pagination is not the fix — reducing the cost of the read or shrinking the registry
  is.
- **It cannot page within one adapter.** See [A meta-adapter is the atomic unit](#a-meta-adapter-is-the-atomic-unit).

It is for **off-chain readers**: indexers, reconciliation jobs, dashboards, anything that can pin a block and issue
several calls.

There is **no verbose (labelled) paginated read**. The label paths carry the heavier gas pressure and their bounds
are still being re-derived; a paginated verbose read built against numbers about to change would be wasted work.

---

## Why a set of addresses and not an index range

Because index ranges are silently wrong.

`getAllAdapters()` is maintained with **swap-and-pop** (see `NAVRegistryLib.removeBalanceAdapter` and
`removeBalanceAdapters`): removing an adapter moves the **last** adapter into the removed one's index — always to a
**lower** index.

So a caller paging `[0,10)` then `[10,20)` across a governance removal **silently skips** the moved adapter: it was at
the tail, it lands in a slot already passed, and it is never read. Both pages look completely well-formed and the
total is short by that adapter's positions.

Because elements only ever move *down*, a removal cannot make an already-read adapter reappear in a later page — the
hazard is a **missed** adapter, not a double-counted one. Naming the adapters removes the whole class instead of
documenting it away.

---

## The caller contract

Four obligations. The contract enforces the first two; the last two it cannot see, and they are where a reassembled
NAV goes wrong.

### 1. Every adapter must be registered, and appear at most once

| Input | Revert |
|---|---|
| empty `adapters` | `EmptyAdapterSlice()` |
| an address not in `getAllAdapters()` | `AdapterNotRegistered(address adapter)` |
| the same address twice | `DuplicateAdapterInSlice(address adapter)` |

All three are rejections rather than best-effort answers, because each would otherwise return a **well-formed slice
carrying a silently wrong `value`**: an empty or unregistered entry contributes zero (indistinguishable from "worth
nothing"), and a duplicate is summed twice.

`AdapterNotRegistered` is also what tells you a cached adapter list has gone stale — the registry is governed, and
an adapter can be removed under a paging loop.

### 2. Read all slices at the same block

Pass an **explicit block number** to every call — not `latest`, which lets successive calls land on different heads.
Positions and prices both move between blocks, so slices taken from different heads sum to a number that was never
any account's NAV, and the sum will look entirely reasonable. **Pinning the block in the request is the only real
control.**

> `PartialNAV.timestamp` is a **cross-check, not the check.** Equal timestamps do not imply the same block: Arbitrum
> Nitro mints blocks roughly every 250ms and this contract is deployed there, so consecutive blocks routinely share a
> `block.timestamp`. The field catches slices seconds apart and is blind to two blocks inside one second — which is
> exactly what an unpinned paging loop produces. `PartialNAV` carries no block number to check instead, deliberately:
> it would not rescue an unpinned caller, and pinning the request already does.

Re-read `getAllAdapters()` **at the same pinned block** too, rather than trusting a cached list.

### 3. The union of slices must cover `getAllAdapters()` exactly once

`PartialNAV.adaptersCovered` is how you verify it: concatenate it across all slices and compare against
`getAllAdapters()` read at the pinned block.

- A **missing** adapter ⇒ the assembled NAV is short by that adapter's positions.
- A **repeated** adapter ⇒ it is double-counted.

Neither is detectable from `value`, because a short NAV is a perfectly plausible number. Check coverage explicitly;
do not infer it from the total looking sensible.

### 4. Union the health flags — **on every slice**

This is the dangerous one.

**`value` is the only field that composes by addition.** Everything else is per-slice:

| Field | How it composes | Why |
|---|---|---|
| `value` | **sum** | Signed; debt legs are already negative, and prices are per-asset and independent of which adapter reported the position. Exact arithmetic — but equality with the complete read assumes **no adapter was gas-starved in either read**, and when that fails **neither side is reliably the larger**. See [the precondition](#the-precondition-is-not-theoretical--read-this-before-reconciling). |
| `stalePriceAssets` | **union, de-duplicated** | Restricted to the assets *this slice's* positions touched. An asset held only through an adapter in another slice is absent here. Two slices holding the same stale asset each report it. |
| `irregularPriceAssets` | **union, de-duplicated** | Same restriction. This is the depeg signal. |
| `monitorsUnhealthyPriceAssets` | **union, de-duplicated** | Same restriction. Assets with monitor feeds configured where **none was readable**, so the divergence check did not run — `irregularPriceAssets` being empty says nothing about them. Dropping this one under-reports monitor failure, the falsely-reassuring direction. |
| `sequencerDown` | **OR** | Derived from the sequencer config, so invariant across slices — but reading it on one slice relies on that invariant rather than checking it. |
| `quoteAssetStale` | **OR** | Invariant across slices, and *more* dangerous to skip for it: if true, **every** slice's `value` was converted at the quote's last-known (stale) price. A quote with no usable price at all reverts `QuoteAssetUnpriceable` on every slice instead ([ADR 0029](../decisions/0029-staleness-flags-never-changes-value.md)). |
| `quoteAssetIrregular` | **OR** | Invariant across slices; always false for a USD quote. |
| `timestamp`, `quoteAsset` | **assert equal** | Differing values mean the slices are not comparable. Necessary but **not sufficient** for `timestamp` — see obligation 2. |

> **A caller that checks the flags on one slice — or on the last slice, or on whichever slice it happened to keep —
> silently loses every staleness, depeg and sequencer-down signal carried by the others, and gets a NAV number that
> looks fine.**

That failure shape is exactly what this repo's fail-open hardening work exists to eliminate. Do not reintroduce it
at the reassembly boundary.

---

## A meta-adapter is the atomic unit

A slice naming a meta-adapter includes **all** of that adapter's governed instances — every Aave V3 instance, every
Morpho market, every Curve pool. There is no way to page *within* one meta-adapter, by design:

- the governed instance set is itself swap-and-pop mutable (`addMetaInstances` / `removeMetaInstances`), so an
  instance-level range would carry the same reordering hazard this API exists to avoid; and
- an instance-level set would require the adapter to accept a filter it does not have.

So **one adapter is the finest slice available.** If a *single* meta-adapter's read alone exceeds the gas budget,
pagination does not help you — the problem is that adapter's per-instance cost, which is a different problem with a
different fix.

This is not hypothetical. On mainnet at the time of writing, `AaveV3InstancesMeta` alone costs **~12.3M gas** for a
diversified account — about 41% of the entire portfolio read, from one adapter with only two governed instances.

---

## One thing pagination *does* fix beyond gas

The per-adapter gas stipend in the read path is a share of what the **read** still holds (see
`PriceFeedLib._getAdapterPositions`). An adapter starved into `AdapterGasExhausted` inside the complete scan may
have ample budget when asked for on its own.

So a slice can get an answer out of a portfolio whose complete read has started reverting.

> **⚠️ But a slice can also turn that loud revert into a silent omission — read this before relying on it.**
>
> Exhaustion is classified by `GasStipendLib.exhausted` as `consumed >= stipend - stipend/8`, measured against a
> stipend that is itself a share of the *caller's* budget. Consider an adapter that fails at a roughly fixed cost
> `G` for a **non-gas** reason (say, a multi-item adapter reverting on one malformed entry):
>
> | read | stipend `S` | verdict | result |
> |---|---|---|---|
> | complete | small | `G >= 0.875·S` → **exhausted** | loud `AdapterGasExhausted` revert |
> | slice | ~10× larger | `G < 0.875·S` → **benign revert** | fail open, legs dropped, **nothing flagged** |
>
> `adaptersCovered` still lists that adapter, so the documented coverage check reports full coverage. If a dropped
> leg is a **debt** leg, the reassembled NAV **over-reports** — the exact failure class this repo's hardening work
> exists to eliminate.
>
> Treat a slice that succeeds where the complete read reverted as **evidence about gas, not a repaired answer.** Do
> not silently promote the slice sum to the authoritative NAV.
>
> And note the trap in "just give the complete read more gas and compare": raising the budget raises the stipend,
> which puts a fixed-cost failure below the same 7/8 bar for the *complete* read as well. Both reads then fail open on
> the same adapter and **agree on the same wrong number.** The signal is the `AdapterGasExhausted` *disappearing*, not
> the two figures converging.
>
> **Scope, and it is narrower than the table suggests.** A *fixed absolute cost* `G` is the ONLY case whose verdict
> moves with the budget — and slicing is merely one way to change the budget, not the mechanism. The ordinary case,
> an adapter that genuinely runs out of gas and bubbles it, is **completely budget-invariant**: `consumed` and
> `stipend` are both proportional to the gas available at that point, so the ratio the classifier tests reduces to
> `≈ (63/64)^d` for nesting depth `d`, and the budget cancels. Slice size moves the budget; it does not move `d`.
>
> Measured across a 50× budget spread (600k to 30M) through the paginated entrypoint at slice size 1: the verdict
> flips from loud to silent between `d = 8` and `d = 9`, **at the same depth for every budget**, and the complete
> read agrees with a slice of 1 at every depth. `SLACK_DIVISOR = 8` is what puts the maximum detectable nesting depth
> at exactly 8 — far past the realistic chain (classifier → meta-adapter → instance → protocol read, `d ≤ 5`), which
> classified loud at every budget from 400k up.
>
> One consequence runs the reassuring way: a *larger* stipend moves the spurious-exhaustion window
> (`consumed ∈ [0.875·stipend, stipend]`) to higher absolute cost, so **slice size 1 minimises spurious
> `AdapterGasExhausted`**, it does not maximise it.

---

## Measured cost

Mainnet fork, the integration harness's registry (**41 registered assets, 21 registered adapters**; the production
config had 42 assets and 27 adapters when this was measured), most diversified test account.

> **These are MEASURED figures from a fork run, not derived counts — they are as of that run and are not
> updated when the registry grows.** PR #308 adds a Symbiotic meta-adapter AND the wARS asset, so it moves
> the ADAPTER axis and the ASSET axis both: the production config went from 42 assets / 27 adapters to 43 / 28
> (measured on both sides), and the harness gains BOTH — the same adapter and the same asset. The gas numbers below were NOT
> re-measured, so the counts are left at the values they were measured against rather than silently
> re-stated against a registry the measurement never saw. Re-run the harness to refresh both together.

| Read | Gas |
|---|---|
| complete `getAccountNav` | **~30.0M** |
| largest single-adapter slice (`AaveV3InstancesMeta`) | ~12.3M |
| second largest (`MorphoMarketsMeta`) | ~3.2M |
| median single-adapter slice | ~300k |

Against a typical 50M `eth_call` cap the complete read still fits, with roughly 1.7× headroom. That is *inside* the
cap but within 2× of it, on a registry that is still growing — so the downstream cutover to slice-based reads is not
an emergency, and should not be treated as optional either.

Reproduce with:

```bash
FOUNDRY_PROFILE=slow forge test \
  --match-path "test/integration/NAV.PaginatedNav.Mainnet.integration.fork.t.sol" \
  --match-test test_reportSliceGas -vv
```

---

## Worked example

```ts
const block = await provider.getBlockNumber();          // pin it once
const all = await nav.getAllAdapters({ blockTag: block });

const SLICE = 4;
let value = 0n;
const covered: string[] = [];
const stale = new Set<string>();
const irregular = new Set<string>();
const monitorsUnhealthy = new Set<string>();   // monitors configured but none readable
let sequencerDown = false, quoteAssetStale = false, quoteAssetIrregular = false;
let timestamp: bigint | undefined;

for (let i = 0; i < all.length; i += SLICE) {
  const p = await nav.getAccountNavForAdapters(
    account, quoteAsset, all.slice(i, i + SLICE), { blockTag: block },
  );

  if (timestamp === undefined) timestamp = p.timestamp;
  else if (p.timestamp !== timestamp) throw new Error("slices read at different blocks");
  if (p.quoteAsset.asset.toLowerCase() !== quoteAsset.toLowerCase()) {
    throw new Error("slice denominated in a different quote asset");   // composition table: assert, don't combine
  }

  value += p.value;                                     // the ONLY field that sums
  covered.push(...p.adaptersCovered);
  for (const a of p.stalePriceAssets) stale.add(a.asset);
  for (const a of p.irregularPriceAssets) irregular.add(a.asset);
  for (const a of p.monitorsUnhealthyPriceAssets) monitorsUnhealthy.add(a.asset);
  sequencerDown ||= p.sequencerDown;
  quoteAssetStale ||= p.quoteAssetStale;
  quoteAssetIrregular ||= p.quoteAssetIrregular;
}

// Coverage check — NOT optional. A short NAV is a plausible number.
if (covered.length !== all.length || new Set(covered).size !== all.length) {
  throw new Error("slice partition did not cover getAllAdapters() exactly once");
}

// RECONCILE before publishing. `value` is only equal to the complete read when nothing was gas-starved, and
// when they differ NEITHER side is reliably the correct one — see the precondition section above. Do not
// resolve a mismatch by picking the larger or the smaller.
const complete = await nav.getAccountNav(account, quoteAsset, { blockTag: block });
if (value !== complete.value) {
  // Expected causes: an adapter starved in one of the two reads. The signal to key on is which read raised
  // AdapterGasExhausted / InstanceGasExhausted — not which number is bigger. If neither reverted, publish
  // neither and alert: you cannot tell which read is short.
  throw new Error(`slice sum ${value} != complete ${complete.value} — reconcile, do not pick`);
}

// And only now act on the unioned flags, exactly as you would on a complete NAV.
```

> Reconciling against `getAccountNav` obviously defeats the point when the complete read is what you could not
> afford in the first place. In that case you have no second opinion available, and the honest position is that
> the slice sum is **unverified** — publish it labelled as such, and treat any `AdapterGasExhausted` from a slice
> as disqualifying. Do not silently drop the check because it is inconvenient.

---

## The invariant, and where it is pinned

> The sum of `getAccountNavForAdapters` over a disjoint partition covering all of `getAllAdapters()` equals
> `getAccountNav` — the `value`, and the union of every flag — **provided no adapter was gas-starved in either
> read.** When that precondition fails, the two can differ in **either** direction.

The arithmetic half is a property of the code, not of two implementations agreeing:
`NAVCalculator.getAccountNavForAdapters` calls the **same** `PriceFeedLib.computeNav` that `getAccountNav` calls,
differing only in which adapters are handed to it. There is no second NAV entrypoint to drift from.

### The precondition is not theoretical — read this before reconciling

Some adapters **fail open inside their own frame and return successfully having dropped legs.**
`AssistedCoordCache._collect` isolates each cached coordinate behind a per-item
`try this.valueCoordSelf{gas: stipend}(…)` and discards any coordinate that reverts (starvation is the one case its
`catch` raises on, as `CoordinateGasExhausted`), and `ERC20DefaultBalanceAdapter` records `0` for an asset whose
unstipended `balanceOf` staticcall fails. Nothing upstream can detect either — see the "Scope, stated plainly" note on
`PriceFeedLib._getAdapterPositions`.

The per-adapter gas stipend is a share of what the **read** still holds *at the moment that adapter is reached*, and
`computeNav` scans the supplied array **in order**. So the stipend depends on **slice composition *and ordering***,
not merely on how few adapters a slice names — and **both directions of error are reachable**:

| slice shape | effect on that adapter's stipend |
|---|---|
| singleton | **more** gas than the full scan gave it — it may value legs the complete read dropped |
| multi-adapter, adapter placed **behind** an expensive one | **less** gas than the full scan gave it — it may drop legs the complete read valued |

**Which read ends up larger is a separate question, and the table above does not answer it.** The *sign* of the skew
is set by the `isDebt` of the legs that got dropped, not by which read dropped them:

- a dropped **credit** leg makes that read **lower**;
- a dropped **debt** leg makes that read **higher**.

So each row above has two possible skews, giving four combinations in total. (This is why the repo's own
`test_sliceOrderingCanManufactureAnOverReport` produces `sum(slices) > complete` from the *second* row's shape: its
fixture drops a debt leg.)

The second row is not hypothetical. **`getAllAdapters()[0]` is permanently `ERC20DefaultBalanceAdapter`** — pushed in
`initialize`, unremovable, and swap-and-pop only ever fills the hole at a removed index, which index 0 can never be.
So the complete read already hands it the largest stipend any read can, and **a slice can only ever give it less.**
That adapter is itself one of the absorbers, and it is credit-only — so starving it makes the *slice* the lower and
the *complete read* the correct one.

> ### ⛔ Do not assume a direction, and do not pick by magnitude
>
> **There is no "trust the slice" rule, and there is no "take the lower" rule either.** Nothing in either result says
> which one is short. Worse, magnitude is actively misleading: with today's credit-only absorbers, starvation can only
> **lower** a read — so "take the lower" would select the *starved* number every single time the two disagree.
>
> "Conservative" is also the wrong frame. An under-reported NAV is not a safe default: a sub/redeem processor pricing
> shares off it **over-issues** to a subscriber. It is a wealth transfer in the other direction, not free.
>
> **Reconcile before publishing either number.** If you must automate a choice, key it to the *signal*, not the
> magnitude: prefer the read that did **not** raise `AdapterGasExhausted` / `InstanceGasExhausted`, and refuse to
> publish at all if neither raised one and the two still disagree.
>
> Also do **not** treat "the two reads agree" as a health check that quietly passes — they agree whenever nothing was
> starved, which is the ordinary case and therefore tells you nothing.

**One load-bearing invariant, and it currently has known exceptions.** What would keep a starved read from
*over*-reporting is:

> **No adapter emits an `isDebt == true` leg from behind *any* fail-open read.**

Note "any" — **a gas *cap* makes this worse, not better.** An uncapped fail-open read at least lets the caller recover
by supplying more gas; a capped one (`StaticCallLib.PROBE_GAS` is 100,000) is starved by the *cap*, so no amount of
caller gas fixes it and the drop is unconditional. That is the same reasoning `GasStipendLib`'s own docstring uses to
reject a fixed ceiling.

**Three shipped adapters currently break it**, and they are listed here rather than papered over — each drops a debt
leg while sibling credit legs survive, which raises reported NAV:

| site | shape |
|---|---|
| `EulerVaultsMetaBalanceAdapter._safeDebt` | `StaticCallLib.probeWordMetered` on `debtOf`; a revert — or a reply shorter than one word — means "no debt leg" while the supply leg is still emitted. Starvation is the one case it does *not* absorb: it raises `DebtReadGasExhausted`. |
| `FluidVaultLib.aggregate` | `resolver.staticcall(positionByNftId)` under a frame-derived stipend, `continue` on a reply that is unreadable rather than starved (starvation raises `FluidPositionGasExhausted`); the `continue` drops that NFT's supply *and* borrow, so it over-reports when the dropped NFT is net-debt or is the only debt-carrying one. |
| `GearboxV3CreditAccountsMetaBalanceAdapter._appendBorrow` | uncapped `try`/`catch` that drops only the borrow leg. Mitigated by the `_debtReportable(cm)` gate that drops the whole position first, but that gate is evaluated *before* the gas is drained, so it is a narrow TOCTOU rather than a closed hole. |

None of these is introduced or fixed by the paginated read — they are pre-existing, and two of them over-report the
**complete** read just as much as a slice. They are named so the invariant tells the truth. Treat it as a property to
check when adding or changing an adapter, alongside the `GasStipendLib` "Scope, stated plainly" note.

There is a second, sharper edge in the same mechanism, covered under
[One thing pagination *does* fix](#one-thing-pagination-does-fix-beyond-gas): a slice's larger stipend can convert a
loud `AdapterGasExhausted` into a **silent** fail-open drop, and `adaptersCovered` will still claim full coverage.

### Where it is pinned

`test/integration/NAV.PaginatedNav.Mainnet.integration.fork.t.sol` — under a singleton partition, a batched
partition, and a second portfolio shape, with a non-vacuity guard so the assertions cannot pass against an account
that holds nothing. **That harness covered 41 assets / 21 adapters at the time of measurement, against a production 42 / 27** — the six skipped are
`EthenaCooldown`, `LidoWithdrawalQueue`, `EulerVaultsMeta` and the three assisted adapters, and that six-adapter
*gap* is asserted by name in `test_harnessCoverageGapIsWhatTheDocblockClaims` so this claim cannot silently rot. The
counts themselves are deliberately **not** pinned — asserting them would redden the suite whenever the mainnet asset
config grows — so treat 41 / 21 as descriptive. Note that a fork test cannot exercise the starvation case at all:
forge grants effectively unlimited gas, so no adapter is ever starved there.

Unit-level cases (the three rejections, order preservation, an adapter removed from the registry mid-paging, debt
netting across a slice boundary, and slice-locality + union recovery for **both** `stalePriceAssets` and
`irregularPriceAssets`) are in `test/nav/NAVCalculator.paginatedNav.t.sol`.
