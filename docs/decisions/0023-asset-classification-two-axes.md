# 0023 — Asset classification on two orthogonal axes (`PegKind` × `AccrualKind`), not one flat enum

- Status: **Proposed.** The classification is decided (two axes, definitions below). The **surfacing
  mechanism is deliberately left open** pending a byte measurement — see
  [Surfacing mechanism](#surfacing-mechanism-pending-measurement). Do not implement against a shape
  this ADR has not chosen.

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
| `Pegged` | `Rebasing` | **aUSDC** *(illustrative)* | ❌ **empty — no aToken registered** | **stablecoin AND yield-bearing AND rebasing — pick one** |
| `Pegged` | `Appreciating` | sUSDS, sDAI | ✅ mainnet, Gnosis | **stablecoin AND yield-bearing, NOT rebasing — pick one** |
| `Floating` | `None` | WETH | ✅ 6 chains | `Standard` — unambiguous |
| `Floating` | `Rebasing` | **stETH** | ✅ mainnet | **yield-bearing AND rebasing — pick one** |
| `Floating` | `Appreciating` | **wstETH** | ✅ 5 chains | **yield-bearing, NOT rebasing — inexpressible** |

Three of the six need an arbitrary primary choice, and the sixth cannot be expressed at all: wstETH is
yield-bearing but not rebasing, and `YieldBearing` vs `Rebasing` gives no way to say so — they are a
false dichotomy over the same axis.

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
not hypothetically, to sUSDS and stETH — each occupies a cell that a flat enum can only half-describe.

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

The decision accepts those costs for drift-resistance, on the identity taxonomy's reasoning. Revisit if
the byte cost forces a compromise elsewhere.

## Surfacing mechanism (PENDING MEASUREMENT)

**Not decided. Do not infer a shape from this ADR.**

`NAVCalculator` has **68 bytes free** under the 24,576-byte EIP-170 limit. A docstring inside
`NAVCalculator.sol` still claims **325**, which is stale by 144 and must not be used for planning. The
arithmetic: the margin was 181 bytes before the last struct field, that field cost **113**, and
181 − 113 = 68.

So a field of comparable cost **does not fit**, and neither does a minimal external getter on
`NAVCalculator` (~122 bytes). The obvious shapes are already ruled out by arithmetic; the rest differ by
amounts only measurement resolves.

> **PENDING — this section is deliberately unfilled; the numbers decide it, not this ADR.**
>
> Measured so far by a concurrent session, against the **68-byte** budget:
>
> - **A — fields on the `Asset` struct.** Breaks the `Asset` struct **ABI** against **27 deployed
>   immutable adapters**, with **13 construction sites across 9 files outside `src/`** plus 5 inside.
>   Widest blast radius of any option.
> - **C1 — an option the original framing did not anticipate**, surfaced by measuring rather than
>   reasoning. Cheap on blast radius — it broke **exactly one positional constructor in a test
>   helper** — but measured **+367 bytes**, so it **does not fit**.
> - **B — `getAssetKinds()` with the work in `PriceFeedLib`.** Library bytecode deploys separately and
>   does not count against `NAVCalculator`'s limit, but B **is C1 plus a batch view**, so it cannot fit
>   **by arithmetic**. It would also move the `PriceFeedLib` pin.
> - **The irreducible floor — still being measured.** A widened struct and a widened *existing* getter:
>   no setter, no new selector, nothing optional.
>
> **If even the floor exceeds 68 bytes, the honest outcome is that this feature does not fit on-chain
> as things stand** — and this ADR should then record that, not a shape. The two live conclusions in
> that case are (a) reclaim space from `NAVCalculator` first and revisit, or (b) give the
> classification an off-chain home and accept the drift risk that the
> [Why this lives on-chain](#why-this-lives-on-chain) section argues against. **Neither is precluded
> here.** The taxonomy above stands on its own either way: it is a decision about how to classify
> assets, not about where the bytes live.

Recording the constraint now, with the correct baseline, is the useful half: it stops the next reader
planning against headroom that does not exist.

## Consequences

- **Two enums to document and keep consistent, not one** — a real cost, not a free choice. Every new
  asset needs two values decided instead of one, both documented, both verified at review, and the two
  can be set inconsistently in ways one enum makes impossible. The judgement is that five occupied cells
  plus one reachable-and-imminent empty one justify the second axis, not that the second axis is cheap.
- Consumers stop maintaining private token-to-category tables, and stop silently disagreeing about
  aUSDC and sDAI.
- The classification is **quote-relative**; documentation must say so, or a reader takes
  `wstETH = Floating` for a bug.
- `NAVCalculator` and the touched libraries **redeploy**. Whether a library pin moves depends on the
  surfacing option: `NAVCalculator`-only edits move neither pin, while work placed in `PriceFeedLib`
  moves that pin and needs a regeneration against a clean full build.
- Until the surfacing mechanism is decided, **nothing here is implementable.** This ADR records the
  classification and the rejected alternative so that reasoning is not re-litigated; it does not
  authorise code.

## References

- ADR 0009 — multi-feed price redundancy (the divergence machinery `Pegged` complements)
- ADR 0016 — `isLocked` position status (per-position status, deliberately not an asset-level axis)
- ADR 0020 — custom-feed governing-leg freshness
- `docs/howto/position-identity-schema.md` — the taxonomy whose self-describing argument this reuses
