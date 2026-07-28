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
`removeBalanceAdapters`): removing an adapter moves the **last** adapter into the removed one's index. A caller
paging `[0,10)` then `[10,20)` with a governance removal landing between the two calls would read one adapter twice
and never see another — and both slices would look completely well-formed.

Naming the adapters removes the possibility instead of documenting it away.

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

Pass an explicit block number or tag to **every** call. Positions and prices both move between blocks, so slices
taken from different heads sum to a number that was never any account's NAV — and the sum will look entirely
reasonable.

`PartialNAV.timestamp` is the check. Assert it is identical across every slice before summing.

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
| `sequencerDown` | **OR** | Derived from the sequencer config, so invariant across slices — but reading it on one slice relies on that invariant rather than checking it. |
| `quoteAssetStale` | **OR** | Invariant across slices, and *more* dangerous to skip for it: if true, **every** slice's `value` is in USD (8dp) rather than the requested quote. |
| `quoteAssetIrregular` | **OR** | Invariant across slices; always false for a USD quote. |
| `timestamp`, `quoteAsset` | **assert equal** | Differing values mean the slices are not comparable. |

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
> Treat a slice that succeeds where the complete read reverted as **evidence about gas, not a repaired answer.**
> Raise the complete read's gas and compare, rather than silently promoting the slice sum to the authoritative NAV.

---

## Measured cost

Mainnet fork, the integration harness's registry (**41 registered assets, 21 registered adapters**; the production
config has 43 assets and 27 adapters, so production is somewhat higher), most diversified test account:

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
let sequencerDown = false, quoteAssetStale = false, quoteAssetIrregular = false;
let timestamp: bigint | undefined;

for (let i = 0; i < all.length; i += SLICE) {
  const p = await nav.getAccountNavForAdapters(
    account, quoteAsset, all.slice(i, i + SLICE), { blockTag: block },
  );

  if (timestamp === undefined) timestamp = p.timestamp;
  else if (p.timestamp !== timestamp) throw new Error("slices read at different blocks");

  value += p.value;                                     // the ONLY field that sums
  covered.push(...p.adaptersCovered);
  for (const a of p.stalePriceAssets) stale.add(a.asset);
  for (const a of p.irregularPriceAssets) irregular.add(a.asset);
  sequencerDown ||= p.sequencerDown;
  quoteAssetStale ||= p.quoteAssetStale;
  quoteAssetIrregular ||= p.quoteAssetIrregular;
}

// Coverage check — NOT optional. A short NAV is a plausible number.
if (covered.length !== all.length || new Set(covered).size !== all.length) {
  throw new Error("slice partition did not cover getAllAdapters() exactly once");
}

// And now act on the unioned flags, exactly as you would on a complete NAV.
```

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
`AssistedCoordCache._collect` isolates each cached coordinate behind an *uncapped*
`try this.valueCoordSelf(…)` / `catch {}`, and `ERC20DefaultBalanceAdapter` records `0` for an asset whose
`balanceOf` staticcall fails. Nothing upstream can detect either — see the "Scope, stated plainly" note on
`PriceFeedLib._getAdapterPositions`.

The per-adapter gas stipend is a share of what the **read** still holds *at the moment that adapter is reached*, and
`computeNav` scans the supplied array **in order**. So the stipend depends on **slice composition *and ordering***,
not merely on how few adapters a slice names — and **both directions of error are reachable**:

| slice shape | effect on that adapter's stipend | resulting skew |
|---|---|---|
| singleton | **more** gas than the full scan gave it | slice values legs the complete read dropped ⇒ `sum(slices) > complete` |
| multi-adapter, adapter placed **behind** an expensive one | **less** gas than the full scan gave it | slice drops legs the complete read valued ⇒ `sum(slices) < complete` |

The second row is not hypothetical. **`getAllAdapters()[0]` is permanently `ERC20DefaultBalanceAdapter`** — pushed in
`initialize`, unremovable, and swap-and-pop only ever fills the hole at a removed index, which index 0 can never be.
So the complete read already hands it the largest stipend any read can, and **a slice can only ever give it less.**
That adapter is one of the two known absorbers.

> ### ⛔ Do not assume a direction
>
> **There is no "trust the slice" rule.** Either side can be the short one, and nothing in either result says which.
> Reconcile before publishing either number. If you need one mechanical rule, the conservative choice is **take the
> lower**, never "take the slice".
>
> Also do **not** treat "the two reads agree" as a health check that quietly passes — they agree whenever nothing was
> starved, which is the ordinary case and therefore tells you nothing.

**One load-bearing invariant, enforced nowhere.** What keeps a starved read from *over*-reporting today is that
**no adapter emits an `isDebt == true` leg from behind an uncapped or `gas()`-forwarding fail-open read.** Both known
absorbers are credit-only, so a starved read currently under-reports. An adapter that broke that property would make
a starved read *raise* NAV — the failure class this repo's hardening work exists to eliminate. Treat it as an
invariant of the adapter layer when adding or changing one, alongside the `GasStipendLib` "Scope, stated plainly"
note.

There is a second, sharper edge in the same mechanism, covered under
[One thing pagination *does* fix](#one-thing-pagination-does-fix-beyond-gas): a slice's larger stipend can convert a
loud `AdapterGasExhausted` into a **silent** fail-open drop, and `adaptersCovered` will still claim full coverage.

### Where it is pinned

`test/integration/NAV.PaginatedNav.Mainnet.integration.fork.t.sol` — under a singleton partition, a batched
partition, and a second portfolio shape, with a non-vacuity guard so the assertions cannot pass against an account
that holds nothing. **That harness covers 41 assets / 21 adapters, not the production 43 / 27** — the six skipped are
`EthenaCooldown`, `LidoWithdrawalQueue`, `EulerVaultsMeta` and the three assisted adapters, and the counts are
asserted in the test so this claim cannot silently rot. Note that a fork test cannot exercise the starvation case at
all: forge grants effectively unlimited gas, so no adapter is ever starved there.

Unit-level cases (the three rejections, order preservation, an adapter removed from the registry mid-paging, debt
netting across a slice boundary, and slice-locality + union recovery for **both** `stalePriceAssets` and
`irregularPriceAssets`) are in `test/nav/NAVCalculator.paginatedNav.t.sol`.
