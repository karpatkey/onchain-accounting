# 0023 — Asset classification on two orthogonal axes (`PegKind` × `AccrualKind`), not one flat enum

- Status: **Accepted.** Two axes, and the kinds are surfaced by a standalone `AssetKindRegistry` rather
  than on `NAVCalculator` — see
  [Surfacing mechanism](#surfacing-mechanism-a-standalone-assetkindregistry). The registry **does not
  hold the redeploy**.

## Context

The NAV reports a price and a balance per registered asset. It reports nothing about *what kind of
asset it is* — whether the price is expected to sit at 1.00 or to float, and whether value accrues by
the balance growing or by the exchange rate growing.

Consumers need that, and today each re-derives it: a dashboard shows stablecoins differently from
volatile holdings; a reconciliation job needs to know a stETH balance legitimately changes with no
transfer, so a delta is not a missing transaction; a depeg monitor needs to know which assets *have* a
peg to break. Each maintains its own token-address-to-category mapping — the duplication the
position-identity taxonomy exists to remove.

## Decision

Classify each registered asset on **two independent axes**:

```
PegKind      { Pegged, Floating }              -- what the price tracks
AccrualKind  { None, Rebasing, Appreciating }  -- how value accrues
```

1. **`PegKind`** — `Pegged` means the price is expected to track the NAV's **quote asset** (USD).
   `Floating` means it is not. See [What `Pegged` means](#what-pegged-means); that definition is the
   load-bearing part.

2. **`AccrualKind`** — `Rebasing`: the **balance** grows, `balanceOf` increases with no transfer
   (stETH, aTokens). `Appreciating`: the **exchange rate** grows while the balance stays static
   (wstETH, sDAI, ERC-4626 shares). `None`: neither. Not cosmetic — it tells a consumer whether an
   unexplained balance delta is yield (`Rebasing`) or a genuine anomaly (`Appreciating` / `None`).

3. **The axes are independent.** All six combinations are **reachable mechanisms**; five are occupied by
   a currently registered asset and one is empty today (see the table below).

## Alternatives considered

### Rejected: a single flat enum `{ Stablecoin, YieldBearing, Rebasing, Standard }`

The obvious first shape, and wrong, because **those categories are not mutually exclusive.** Several
assets fall into two or three at once, so the enum forces an arbitrary choice of which fact to keep and
which to discard.

The `Occupied` column is deliberate: it separates *reachable mechanism* from *currently registered
asset*, so the argument does not rest on a claim a reader can falsify from config.

| `PegKind` | `AccrualKind` | Example | Occupied today | Under the flat enum |
|---|---|---|---|---|
| `Pegged` | `None` | USDC | ✅ 6 chains | `Stablecoin` — unambiguous |
| `Pegged` | `Rebasing` | **aUSDC** *(illustrative)* | ❌ **empty — no aToken registered, but REACHABLE** | **stablecoin AND yield-bearing AND rebasing — pick one** |
| `Pegged` | `Appreciating` | — | ❌ **empty — cannot be *asserted*, but reachable** *(see below)* | *(no member to misclassify)* |
| `Floating` | `None` | WETH | ✅ 6 chains | `Standard` — unambiguous |
| `Floating` | `Rebasing` | **stETH** | ✅ mainnet | **yield-bearing AND rebasing — pick one** |
| `Floating` | `Appreciating` | **wstETH**, sUSDS, sGHO, sUSDe, sDAI | ✅ wstETH 5 chains; sUSDS/sGHO/sUSDe mainnet; sDAI Gnosis | **yield-bearing, NOT rebasing — inexpressible** |

Two of the six need an arbitrary primary choice, and a third cannot be expressed at all: wstETH is
yield-bearing but not rebasing, and `YieldBearing` vs `Rebasing` gives no way to say so — they are a
false dichotomy over the same axis.

> **Amended — the `Pegged + Appreciating` row originally read `sUSDS, sDAI | ✅ mainnet, Gnosis`.**
> That classification was **overruled after this ADR merged**: a yield-bearing wrapper has no peg, so
> sUSDS, sGHO, sUSDe and sDAI are `Floating + Appreciating`. `src/utils/AssetKind.sol` carries the
> corrected classification — on **PR #241, which is not yet merged**; neither that file nor the registry
> is on `main` today. The row is preserved as empty rather than deleted, because the cell itself is
> still part of the argument — see immediately below. Recorded rather than silently rewritten: this ADR taught the
> overruled classification for as long as it stood, and a reader who acted on it deserves to know it
> changed rather than to conclude they misread it.

**The two empty cells are empty for DIFFERENT reasons, and conflating them loses the argument.**

- **`Pegged + Rebasing` is genuinely REACHABLE** — an aToken for USDC has a growing balance at a $1
  price. It is unoccupied only because no aToken is registered; the first such registration legitimately
  occupies it.
- **`Pegged + Appreciating` cannot be ASSERTED — which is not the same as being unreachable.** Because the
  peg axis is derived rather than stored, there is no parameter with which to *claim* an appreciating asset
  is pegged; the contradiction that used to be expressible in config is now unwriteable. That is the real
  gain. But the cell **remains reachable**: if an operator sets a non-zero `pegToleranceBps` on an asset
  stored as `Appreciating`, the pair reads back `Pegged + Appreciating`, because the peg is computed from
  that tolerance. What changed is *where such a state can come from* — only ever from a real pricing
  decision on the NAV, never from a mistyped classification — and it is then a **true report of the NAV's
  own configuration** rather than a second opinion contradicting it.

That distinction is why the two rows must not be collapsed into one "empty" note: one is a
forward-compatibility slot to be filled, the other is a contradiction to be caught.

**This is not a judgement call, and the pricing layer already encodes it.** `PriceFeedLib`'s absolute peg
guard is enabled per-asset by a non-zero `pegToleranceBps`, described there as set "only on assets whose
fundamental value is $1". Across the seven configured chains it is set on exactly **25** rows — the true
stablecoins (on mainnet: USDC, USDS, USDT, DAI, GHO, USDe, RLUSD, crvUSD). **No yield-bearing wrapper
carries it** — not sDAI, sGHO, sUSDe, sUSDS or syrupUSDC. The absence of a peg tolerance is the
discriminator, and it holds for every one of them.
**There is exactly one authority, so there is nothing to cross-check.** The peg axis is **derived, not
stored** — `pegKind(asset)` is computed on read as `pegToleranceBps > 0` (implemented in
`AssetKindRegistry` on **PR #241**, still unmerged; neither it nor the registry is on `main` today). A
classification contradicting the pricing layer is therefore not merely detectable — **the contradictory
sentence is unwriteable**, because there is no parameter in which to write it.

**Recorded as a decision rather than a mechanism, deliberately.** An earlier revision of this paragraph
said a guard in `08_DeployAssetKindRegistry` *would* assert that the two authorities agree. #241 has since
**deleted** that guard, and deleting it was the stronger move: a guard against a state the design cannot
express is dead code that reads as protection. The durable fact is the **decision** — one authority, peg
derived from peg tolerance — not which script carries which check. That distinction is why this paragraph
now states the decision: the mechanism changed within hours of the previous revision, and the decision did
not.

**`Pegged + Rebasing` is empty today, and that strengthens the case rather than weakening it.** aUSDC is
listed as an illustration of the cell, not as evidence of current occupancy — no aToken is registered
(verified against `nav-config/assets-and-price-feeds/`: 93 asset refs across chains, 43 on mainnet, and
the only `a*` symbols are AAVE, a governance token, and ankrETH, an LST). The mechanism is real
regardless: an aToken *is* simultaneously a stablecoin, yield-bearing and rebasing, and that is a fact
about aTokens, not about our config.

The forward-compatibility argument is the point. Under a flat enum, whoever first registers an aToken
is forced at registration time to pick one of three labels and silently discard the other two — a
decision made under time pressure, by one person, inherited by every downstream consumer. Under two
axes the cell already exists and is already correct, and registering an aToken requires no new
judgement. Registering one is a plausible near-term event, so the empty cell is a
**forward-compatibility property, not dead weight**: it is precisely the case where a flat enum's
failure would be introduced by a routine config change rather than caught in review.

The failure mode is not imprecision, it is that **the arbitrary choice propagates silently.** Tag an
aToken `Rebasing` and every consumer filtering on `Stablecoin` would drop it from the stablecoin total,
with no error. Tag it `Stablecoin` and every consumer watching for rebase-driven deltas would treat its
yield as an anomaly. Each inherits a decision it did not make and cannot see. Two axes require no such
choice: it is `Pegged` **and** `Rebasing`, and both consumers get a true answer. The same applies today,
not hypothetically, to sUSDS and stETH — stETH occupies a cell a flat enum can only half-describe, and
sUSDS one it cannot express at all.

**For a future reader:** the pressure to collapse this back to one enum will recur, because one enum is
smaller and reads more simply. Check the table above against the then-registered asset set first. The
collapse is safe only if no registered asset occupies two categories — which has not been true at any
point in this repo's history.

### Rejected: more than two axes

Liquidity, custody model and redemption mechanics were considered and left out — each is either already
covered (`isLocked` per position, ADR 0016) or has no current consumer. Two axes is the smallest set
that resolves an ambiguity actually present in today's data.

## What `Pegged` means

**Pegged to the NAV's quote asset (USD).** Not "pegged to anything."

A deliberate narrowing, and **the judgement in this ADR most likely to be contested.** The looser
reading — "tracks some reference" — makes every liquid-staking token `Pegged`, since wstETH does track
ETH closely. Then nearly every asset held is `Pegged`, the axis partitions nothing, and no consumer can
separate "expected to be worth 1.00" from "expected to move."

The consequence, plainly: **wstETH is `Floating`**, as are stETH, rETH and every other ETH derivative.
Their tight relationship to ETH is real and is not what this axis records.

Two implications where the definition earns its keep:

- **Quote-relative, not intrinsic.** If the NAV's quote asset were ETH rather than USD, wstETH's
  correct value would change and so would USDC's. It describes the asset *as this NAV prices it*.
- **An expectation, not an assertion of correctness.** A depegged stablecoin is still `Pegged` — which
  is exactly what makes the flag useful to a monitor. This axis says where the price is supposed to be;
  the divergence machinery (ADR 0009, ADR 0020) says whether it is there.

An asset pegged to a non-USD reference (a EUR stablecoin) does not fit cleanly and is out of scope
until one is registered. Recording the gap beats widening `Pegged` and losing the discrimination.

## Why this lives on-chain

Static metadata that changes only on registration or a protocol mechanics change, so it *could* live in
an off-chain table keyed by token address. **The argument for on-chain is the one already accepted for
the position-identity taxonomy:** it makes the NAV **self-describing**. A consumer gets price, balance
and kind from one call at one block, and cannot hold a classification that disagrees with the NAV's own
view. A parallel table drifts — an asset is registered, the table is not updated, and the consumer
either fails to classify it or uses a stale row, silently. That is the drift the `protocolBrand` /
`protocolId` / `protocolSubId` taxonomy exists to prevent.

**The honest counter-argument**, to weigh rather than wave away:

- It spends the scarcest resource in the system. `NAVCalculator` is against EIP-170; every metadata
  byte is unavailable to valuation logic. Off-chain classification costs zero contract bytes.
- It is **immutable once deployed**, while classification is a judgement that may need revising. A
  wrong call is a one-line fix off-chain; on-chain it is a config change at best, a redeploy at worst.
- It has **no on-chain consumer.** Nothing here branches on these values; every reader is off-chain.
  That is a real cost for a correctness benefit rather than a functional one.

**The standalone-registry decision below answers the first two.** A separate contract spends none of
`NAVCalculator`'s budget, and MANAGER-gated writes make a wrong classification a transaction rather than
a redeploy — so "immutable once deployed" simply stops applying. The third stands: there is still no
on-chain consumer, and on-chain storage is still being paid for an off-chain audience. That cost is
accepted for the drift-resistance, on the identity taxonomy's reasoning.

## Surfacing mechanism: a standalone `AssetKindRegistry`

**Decided.** The kinds are **not** surfaced on `NAVCalculator`. They live in a standalone
`AssetKindRegistry` — one small contract per chain: `mapping(address => packed kinds)`, MANAGER-gated
writes, and a batched `getAssetKinds(address[])` read.

### Chosen on principle, not on affordability

The byte budget forced the question; it did not decide it. **This classification is static metadata, not
runtime state.** `PegKind` and `AccrualKind` do not change block to block, do not participate in
valuation, and nothing on the NAV read path consumes them.

The two properties that would justify a field *inside* the NAV read are **both absent**:

- **Atomicity with the price** — needed if a consumer had to know the kind *as of the same block* as the
  valuation. It does not; the kind is the same at every block.
- **Derivation from live state** — needed if the value came from a contract read that could change. It
  does not; it is a human judgement recorded once.

So a consumer does two calls and caches the kinds indefinitely. That is the correct shape for data with
these properties, independent of how many bytes were free.

### What was measured, and why the floor settles it

All figures from clean builds, against `NAVCalculator`'s **68 free bytes**:

| Option | Shape | `NAVCalculator` cost | Verdict |
|---|---|---|---|
| **C3** | widened `AssetPricing` + widened *existing* `getAssetPricing` return; no setter, no signature change, no new selector | **+92** | **24 OVER** |
| A | two fields on the `Asset` struct | +189 | OVER |
| C1 | C3 + one MANAGER setter | +367 | OVER |
| B | C1 + batch external view | ≥ +367 | excluded by arithmetic |

**C3 is decisive because it is the theoretical floor.** It widens a struct that already exists, exposed
through a getter that already exists, with zero new selectors and zero signature changes — and **it is
not even a working feature, because nothing can set the values.** It still misses by 24 bytes. If the
floor does not fit, no arrangement of these parts fits, and further search is wasted effort rather than
unexplored option space.

### Two predictions the measurement overturned

Both are counterintuitive, so they are recorded rather than quietly corrected:

1. **The binding constraint is any new EXTERNAL FUNCTION, not struct embedding.** The expectation was
   that A would be worst, since `Asset` is embedded in every `Position` and NAV array. A does overflow —
   but at **+189 it is cheaper *in `NAVCalculator`* than C1 at +367**, because it displaces cost into the
   libraries. **The MANAGER setter alone is 275 bytes.** Dispatch and ABI surface dominate; data shape
   does not.
2. **"Put the work in a library, its bytes don't count" FAILS here.** C3 moved `PriceFeedLib` by
   **+411**. The cost being paid is **external ABI surface, not work volume**, and surface cannot be
   displaced into a library. This invalidates the reasoning that made option B look promising — B was
   attractive on a premise that does not hold.

### One assumption elsewhere that this corrects

**Option A would also have moved `NAVRegistryLib`'s pin** (13,142 → 13,462). The second pin
regeneration's working assumption — that only `PriceFeedLib` moves — would have been **wrong** under
that option. It is not wrong under the registry, which moves neither.

### Rejected: reclaim space by relocating the verbose label block

The one path to fitting kinds inside `NAVCalculator` is to first move the verbose label block
(`_toVerbose` / `_safeString` / `_safeStringArray` / `decodeStringArray`) out to a **lens contract** —
necessarily a contract and not a library, because `decodeStringArray` must be externally callable for
`try/catch` to reach it.

Declined. It is real work, it would **hold the deploy**, and it would spend that work relocating
*static metadata into a hot read path it has no business occupying*. Recorded here as the documented
price should anyone later want kinds inside the NAV: the cost is a lens-contract extraction plus a
deploy delay, and the thing bought is atomicity that — per above — nothing needs.

Recording the constraint now, with the correct baseline, is the useful half: it stops the next reader
planning against headroom that does not exist.

## Consequences

- **Two enums to document and keep consistent, not one** — a real cost, not a free choice. Every new
  asset needs two values decided instead of one, both documented, both verified at review, and the two
  can be set inconsistently in ways one enum makes impossible. The judgement is that four occupied cells
  plus one reachable-and-imminent empty one justify the second axis, not that the second axis is cheap.
  (The sixth cell, `Pegged + Appreciating`, cannot be *asserted* — the peg axis is derived, so there is no
  parameter in which to claim it — and carries no weight in that judgement. It was counted as occupied
  before the classification was corrected.)
- Consumers stop maintaining private token-to-category tables, and stop silently disagreeing about
  aUSDC and sDAI.
- The classification is **quote-relative**; documentation must say so, or a reader takes
  `wstETH = Floating` for a bug.
- **The registry does not hold the redeploy.** It touches no NAV struct, breaks no adapter ABI, and moves
  **neither library pin** — so it can ship on its own schedule, before or after. This is a change from
  the premise this work started under, where every candidate shape implied a `NAVCalculator` change and
  therefore a coupling to the redeploy.
- **A second call, and a cache.** Consumers wanting price and kind together make two calls instead of
  one. Because the values are static, the kinds can be cached indefinitely and refreshed only when an
  asset is registered — so the cost is one extra call per deployment, not per read.
- **One more contract per chain** to deploy, verify, record in `deployments/<chainId>.json`, and hold a
  MANAGER role on. Small, but it is a new operational surface rather than a free win.
- The classification becomes **correctable by transaction** rather than by redeploy, which is the right
  property for a recorded judgement — see the reconciliation in
  [Why this lives on-chain](#why-this-lives-on-chain).

## References

- ADR 0009 — multi-feed price redundancy (the divergence machinery `Pegged` complements)
- ADR 0016 — `isLocked` position status (per-position status, deliberately not an asset-level axis)
- ADR 0020 — custom-feed governing-leg freshness
- `docs/howto/position-identity-schema.md` — the taxonomy whose self-describing argument this reuses
