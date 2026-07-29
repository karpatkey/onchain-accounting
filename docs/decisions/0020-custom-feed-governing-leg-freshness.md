# 0020 — Custom-feed `getPriceData` reports the *governing leg*'s freshness

**Status:** accepted

## Context

`NAVCalculator.getPriceData(asset)` returns a `PriceFeedData` view whose `updatedAt` + `chainlinkHeartbeat`
fields let a consumer (e.g. the kpk-app price-feeds page) show "last updated" and a per-feed staleness/heartbeat
signal. For **Chainlink/Redstone/API3** feeds this is unambiguous: report the selected feed's
`latestRoundData().updatedAt` against its configured heartbeat.

For **Custom feeds** it was broken and, on closer inspection, under-specified:

1. **Blank values.** `PriceFeedLib.buildPriceData` fetched `updatedAt` only for `priceType != Custom`, so every
   custom feed reported `updatedAt = 0`. The UI then rendered "—" for both *last-updated* and *heartbeat* on all
   custom-priced assets (wstETH, weETH, LDO, sDAI, osGNO, …), even though the underlying feeds demonstrably expose
   fresh timestamps on-chain.

2. **A composite has no single honest `(updatedAt, heartbeat)`.** Custom feeds are *composites* — most are
   `rate × base/USD` ([ADR 0019](0019-nav-sourced-base-price.md)), depending on **two** Chainlink legs (a rate feed
   with its own heartbeat, plus the NAV's base/USD leg with a different heartbeat). The oldest leg and the
   tightest-heartbeat leg are usually different feeds, so no single pair faithfully summarises staleness:
   - `updatedAt = min(legs)` (worst-case freshness) paired with `heartbeat = min(legs)` → a healthy feed whose slow
     leg (e.g. LDO/ETH, ~daily) is routinely hours old, compared against the fast leg's ~20-min heartbeat, shows a
     **permanent false "Warning."**
   - paired with `heartbeat = max(legs)` → a genuinely stale *fast* leg is **hidden** (the freshest-looking math
     says "within 24 h"), contradicting the authoritative `stale` flag.

   This is why per-leg staleness already lives *inside* each feed as the `getLatestPrice().stale` boolean — the
   safety-critical signal is correct regardless of what we display. The open question was purely what to *show*.

## Decision

`getPriceData` reports, for a custom feed, the **governing leg** — the underlying Chainlink leg with the greatest
`age / heartbeat` ratio (the input closest to, or furthest past, its own staleness deadline) — and surfaces *that
leg's* `(updatedAt, heartbeat)`. The pair is therefore a **real, matched pair from one actual oracle**, and it
reduces to the obvious answer for a single-leg feed.

Concretely:

- **New interface method** `ICustomPriceFeed.governingFeedFreshness() → (updatedAt, heartbeat)`. Each feed computes
  its governing leg:
  - **Single Chainlink leg** (`BaseCustomPriceFeed`, `ERC4626VaultRatePriceFeed`, and the bespoke `sDAI`, `ankrETH`
    — one Chainlink base/USD leg + an on-chain, non-oracle rate) → that base leg, via the new
    `NavBaseUsdLib.baseFreshness(nav, baseAsset)` which returns `(pd.updatedAt, pd.chainlinkHeartbeat)` from the base
    asset's own NAV selector.
  - **Two Chainlink legs** (`TwoFeedChainlinkPriceFeed`, and `CrossRateCustomPriceFeed` by inheritance) → the rate
    leg `(rateUpdatedAt, RATE_HEARTBEAT)` vs the base leg `(baseUpdatedAt, baseHeartbeat)`, whichever has the larger
    `age/heartbeat` ratio (compared by cross-multiplication, no division). If the rate feed is unreadable, fall back
    to the base leg.
  - **`ETHPlus`** (Reserve basket — many collateral oracles collapsed to one aggregate) → `(min(lastSave) across the
    active basket, RESERVE_PROTOCOL_HEARTBEAT)`, which is already the governing pair.
  - **No trackable Chainlink leg / revert** → `(0, 0)`, rendered as "no timestamp."

- **`buildPriceData`** branches on `priceType`: Custom → `governingFeedFreshness()` (overriding the config
  heartbeat); everything else → `latestRoundData().updatedAt` against the configured heartbeat (unchanged). The call
  is wrapped in `try/catch` — a reverting feed leaves `updatedAt = 0` and the registered config heartbeat.

- **`latestRoundData().updatedAt` is unchanged** — it still returns the worst-case/`min` timestamp used by
  `_selectFeedCore` for feed *selection*, ranking and the outer heartbeat gate. The governing pair is an **additive,
  view-only** concern: `getPriceData` uses it for display; the selection/validation core is untouched. This keeps
  the two roles cleanly separated (selection wants worst-case; display wants the matched at-risk pair).

- **Staleness rule (unchanged, re-affirmed):** a custom feed backed by *n* Chainlink legs is stale iff **any** leg
  is stale. This is already enforced inside each feed's `getLatestPrice()`/`_compute` (`TwoFeedChainlinkPriceFeed`:
  `baseStale || rate past RATE_HEARTBEAT`), and `getPriceData.stale` derives from it via `_selectFeedCore`. The
  governing-leg change does not alter it.

## Consequences

**Positive**
- Custom-priced assets show a real *last-updated* and a **meaningful heartbeat + "approaching-stale" Warning** — the
  Warning fires exactly when the most-at-risk underlying leg nears its own deadline, never chronically and never
  hiding a stale leg.
- For the common configuration (the feed's config heartbeat ≥ every leg heartbeat), `age vs heartbeat` on the
  reported pair tracks the true worst per-leg ratio, so the soft Warning aligns with the hard `stale` flag. Where they
  can diverge, `stale` is authoritative — see the advisory-pair caveat below.
- Single-leg feeds report exactly their one Chainlink leg's `(updatedAt, heartbeat)` — the intuitive answer — with
  **no config duplication**: the base leg's heartbeat is read live from the base asset's own NAV registration, so it
  can't drift.
- No change to the safety-critical `_selectFeedCore` selection/gate or to registration validation.

**Negative / watch**
- **The pair is ADVISORY; `stale` is the authoritative verdict.** `(updatedAt, chainlinkHeartbeat)` describes only
  the governing oracle leg's push freshness. `stale` (and `sequencerDown`) additionally folds in the rate answer's
  validity, the L2 sequencer, and the feed's own configured heartbeat gate — none of which the pair can express — so
  the pair can read "fresh" (`age < heartbeat`) while `stale` is true. Concretely: (a) a rate leg with a recent
  timestamp but a non-positive answer makes the feed stale while the pair looks fresh; (b) if a feed is registered
  with a config heartbeat *tighter* than the governing leg's own heartbeat, `_selectFeedCore`'s outer gate marks it
  stale on the min timestamp while the reported governing heartbeat is looser; (c) during an L2 sequencer outage
  `stale` is true while the legs' timestamps are fresh. Consumers MUST gate on `stale`/`sequencerDown`, never
  recompute staleness from the pair alone. This is documented on `PriceFeedData` and `governingFeedFreshness`.
- **The displayed pair is a moving target.** Which leg governs changes over time as the `age/heartbeat` ratios
  cycle, so a two-leg feed's shown heartbeat can alternate between its legs' values between reads. This is inherent
  to compressing a composite into one pair; it is honest (always the at-risk leg) but can surprise a user who
  expects a constant per-feed heartbeat.
- **Overflow safety.** A base leg may be registered with a `type(uint256).max` heartbeat (the documented
  "disable the staleness gate" sentinel), so `_governingLeg`'s cross-multiplication `age * heartbeat` can exceed
  uint256. It uses `Math.tryMul` and, on overflow, treats that (astronomically-large-heartbeat, ratio ≈ 0) leg as
  the loser — so a direct external caller of `governingFeedFreshness()` never reverts.
- **Interface change → redeploy, in order.** Adding `governingFeedFreshness` changes
  `type(ICustomPriceFeed).interfaceId` (checked at registration via `supportsInterface`). Migration order: upgrade
  `PriceFeedLib`/`NAVCalculator`, **redeploy every custom feed**, then re-register. Re-registering a pre-PR feed
  reverts `InvalidPriceOracle` (old interface id); reads of a not-yet-redeployed feed are safe — `buildPriceData`'s
  `try/catch` swallows the missing-method revert and reports `(updatedAt = 0, chainlinkHeartbeat = config value)`,
  i.e. degrades to "stale", until the feed is redeployed. Folds into the pending clean-redeploy migration.
- `getPriceData.updatedAt` for a custom feed is the governing leg's timestamp, **not** the strict oldest — a
  slightly less conservative "last updated" than `latestRoundData().updatedAt` (min). The conservative min remains
  available on the feed's `latestRoundData()` and is what selection uses.
- Each custom-feed `getPriceData` now does one extra `staticcall` (`governingFeedFreshness`, which for the base leg
  re-reads `getPriceDataNoDivergence(baseAsset)` — an unavoidable second base selection on this view-only path).
  `ETHPlus.governingFeedFreshness` computes only the min-`lastSave` freshness scan, **not** a second full basket
  price (`_compute`), so its view read isn't doubled. Negligible overall — reads are off-chain `eth_call`.

## Alternatives considered

- **Empty heartbeat for n≥2, leg values for n=1** ("Design A"). Honest (a composite has no single heartbeat, so show
  none), and no feed redeploy — but the ~13 multi-leg feeds lose the "approaching-stale" Warning entirely (only
  Fresh/Stale), it requires *relaxing the registration `heartbeat != 0` check* **and** a `_selectFeedCore`
  skip-on-zero gate (both in the shared safety path), and the single-leg heartbeat becomes a config-duplicated copy
  of the base asset's heartbeat (drift risk + on-chain re-registration). Rejected: concentrates risk in the
  selection core and gives a strictly poorer UI than the governing leg.
- **`min(leg heartbeats)`** as the reported heartbeat. Safe against false-negatives but produces chronic false
  "Warning" for feeds with heterogeneous leg cadences (see Context). Rejected.
- **`max(leg heartbeats)`** (≈ the current loose config value). Stable, but hides a stale short-heartbeat leg from
  the Warning. Rejected.
- **Per-leg data to the UI** (arrays of `(updatedAt, heartbeat)`). The most faithful representation, but grows the
  ABI struct to arrays and needs real UI work to render multiple legs per row. Deferred as over-scoped for the
  value; the governing leg captures the decision-relevant leg in a single pair.

## References
- [ADR 0019](0019-nav-sourced-base-price.md) — custom feeds source base/USD from the NAV (the reason most custom
  feeds have a *base* Chainlink leg reachable via `NavBaseUsdLib`).
- [ADR 0009](0009-multi-feed-price-redundancy.md) — multi-feed freshest-wins selection.
- `src/prices/ICustomPriceFeed.sol` (`governingFeedFreshness`), `src/prices/NavBaseUsdLib.sol` (`baseFreshness`),
  `src/prices/PriceFeedLib.sol` (`buildPriceData`).
