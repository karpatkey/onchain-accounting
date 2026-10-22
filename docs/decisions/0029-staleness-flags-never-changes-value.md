# 0029 — Staleness flags a price, it never changes the NAV value

**Status:** Proposed (2026-10-21)
**Amends:** [0009](0009-multi-feed-price-redundancy.md) (feed selection when no feed is fresh),
[0019](0019-nav-sourced-base-price.md) (a stale base leaves the derived asset unpriced),
[0025](0025-heartbeat-equals-declared.md) (staleness "surfaces as a refusal, never as a wrong number").
**Issue:** #351

## Decision

The NAV always returns the best value it has. A price past its heartbeat keeps being used, and the asset is
reported in `stalePriceAssets` (and `quoteAssetStale` for the quote asset). Staleness is a flag for the consumer;
it is never a reason to change `value`.

Concretely, in `PriceFeedLib._selectFeedCore` every registered feed of an asset is one of:

| Class | Rule | Effect |
|---|---|---|
| **Fresh** | not self-reported stale, and younger than its heartbeat | counted in `healthyFeedCount`; always outranks any stale feed |
| **Usable-stale** | positive price, past its heartbeat (or a Custom feed reporting itself stale), last update younger than `MAX_STALE_PRICE_AGE` | used only when no feed is fresh; the asset is flagged stale |
| **Unusable** | the read reverts; a non-positive or out-of-range price; an API3 answer scaling to 0; a stale rate-only Custom feed (no timestamp to age); a last update at least `MAX_STALE_PRICE_AGE` old | never used |

Ranking is unchanged within a tier: a real-timestamp feed beats a rate-only one, then the larger `effectiveTime`
wins, and ties keep the earliest-registered feed. A fresh feed therefore wins exactly as before; the only new
behaviour is what happens when **no** feed is fresh. `price == 0` with `stale == true` now means "no feed has a
usable price at all", and only then does the asset contribute 0.

Three further rules:

1. **`MAX_STALE_PRICE_AGE = 7 days`** (`src/constants.sol`), absolute, measured from the feed's `effectiveTime`.
   Every registered finite primary heartbeat must be below it. `PriceFeedLib.addFeed` rejects one at or above it
   (`IPrices.HeartbeatNotBelowStaleCap`) on add and on modify, and the preflight heartbeat guard checks the config.
   `type(uint256).max` stays allowed for any feed type: it disables the heartbeat gate, so such a feed is never
   stale by age and the cap never applies to it. Use it only for a feed that reports its own staleness. The guard
   runs only when a heartbeat is written, so the rollout sweeps the heartbeats already on-chain
   ([`script/deploy/ADR0029_ROLLOUT.md`](../../script/deploy/ADR0029_ROLLOUT.md)).
2. **A non-USD quote asset with no usable price reverts** `INAVCalculator.QuoteAssetUnpriceable(quoteAsset)`
   from every read that converts into it. A merely stale quote converts at its last-known price, with
   `quoteAssetStale` set, and the value stays in quote units. The USD quote, `address(0)`, never reverts.
3. **Custom feeds carry a stale input instead of zeroing.** `NavBaseUsdLib.baseUsd` returns the base price with
   `stale = true` when the base is stale, and each NAV-sourced feed class (`BaseCustomPriceFeed`,
   `ERC4626VaultRatePriceFeed`, `TwoFeedChainlinkPriceFeed`, `ankrETH`) computes its price from it and reports
   `stale = true`. The feeds that read their own Chainlink legs instead of the NAV
   (`InvertedChainlinkCustomPriceFeed`, `ChainlinkCrossRateCustomPriceFeed`) apply the same rule to each leg: a leg
   past its heartbeat keeps the price and sets `stale`. Structural failures (a zero rate, a non-positive answer, a
   decimals or band violation) still return 0.

Divergence keeps working while a price is stale, as far as the monitors allow: a usable stale primary is still
compared against every monitor that is fresh, so a frozen feed that drifts from the market raises `irregular`
alongside `stale`. Only an L2 sequencer outage suppresses the check, as before. This catches a frozen feed only
where a fresh monitor exists: the configured Custom monitors are NAV-sourced off the same base as their primary,
so when that base crosses its heartbeat they go stale together and no comparison runs. For the same reason a
stale primary is not listed in `monitorsUnhealthyPriceAssets` (its monitors are not to blame, and
`stalePriceAssets` already reports the event). The rule applies to every asset, including those whose monitors
are independent direct feeds: if such a monitor is also dead while the primary is stale, that surfaces in
`monitorsUnhealthyPriceAssets` only once the primary is fresh again. An accepted trade-off against hourly noise.

## Why

**Live incident, Ethereum mainnet, 2026-10-10.** `getAccountNav(0x0295E5d0…752D, WBTC)` returned `477998010`
(4.78 WBTC) at block 26161130 and `194871206` at block 26161132, two blocks later. At 26161132 the Chainlink
BTC/USD feed was 3,612 s old against a 3,600 s heartbeat. The old selection skipped it, so:

- the 4.78 WBTC of positions were valued at **0**;
- the quote asset, WBTC, had no price, so `_priceConversion` returned the remaining **USD** sum ($1.9487 of net
  USDC legs) as if it were WBTC.

The NAV reported a wrong number with only a flag to say so, which is the opposite of what 0025 intended.
Chainlink rounds routinely land a few seconds past the heartbeat (0025 measured +2 s … +96 s), so this happens
roughly every hour on BTC/USD, ETH/USD and DAI/USD. Adding a heartbeat margin would hide the flag; 0025 rejects
that, and this ADR keeps 0025's strict freshness while removing its consequence for the value.

The three failure modes the old behaviour produced:

1. **A stale asset was valued at 0**, under-reporting what the account holds.
2. **A stale debt disappeared**, over-reporting the account.
3. **A stale quote silently switched the units to USD**, an arbitrarily large error.

## Why a fixed 7-day cap, not a multiple of the heartbeat

A price must stop being used at some point, or a deprecated feed would report a dead number forever. A multiple
of the heartbeat ties that point to a liveness number: registered heartbeats differ by more than 300× across
feeds for the same question ("is this still a fair value?"), and a small multiple would bring back the value cliff
after a two-hour outage on hourly feeds, which is exactly the case this ADR fixes. A fixed cap is one sentence
for consumers ("the NAV never uses a price older than 7 days"), cannot overflow on the `type(uint256).max`
"gate disabled" heartbeat, and exceeds every registered heartbeat (the largest in this repo's configs is 90,000 s;
Robinhood's equity feeds, configured outside this repo, use 518,400 s — six days — which the rollout must confirm
on-chain, see `script/deploy/ADR0029_ROLLOUT.md`).

## Consequences

- **Consumers gate on the flags, not on the value.** Anything that relied on a stale asset dropping to 0 must
  read `stalePriceAssets`, `quoteAssetStale` and `healthyFeedCount` instead. `stale` is the alert key; during a
  holdover, `irregular` additionally fires if the stale price has drifted from a fresh monitor.
- **`stalePriceAssets` mixes two cases.** A listed asset was normally still valued, at its stale price; it
  contributed 0 only when no feed was usable at all (every read failed, or the last update is 7 days old). The
  position's `price` (or `getPriceData(asset).price`) is 0 only in the second case, and that is how to tell them
  apart. A consumer that alerts on the cliff should alert on `price == 0`, not on the flag alone.
- **Over-report window, accepted.** During a crash a frozen-but-positive primary is used for up to 7 days; only
  the `stale` flag (and `irregular`, where a fresh monitor exists) signals it.
- **A stale debt now lowers the NAV** instead of vanishing.
- **Callers converting into a non-USD quote must handle `QuoteAssetUnpriceable`**, typically by falling back
  to the USD quote. The revert does not depend on the account holding anything: an unfiltered read of an empty
  account reverts too. The one exception is the asset-filtered `computeAccountPositions` path, which returns an
  empty list before it reads the quote when the account holds nothing in the filtered asset.
- **`calculateValue` has no per-asset staleness output.** It values stale assets at their last-known price;
  callers check `healthCheck` or `getPriceData`.
- **`getPriceData` / `getPriceDivergence` report the stale winner:** its price, feed address and heartbeat, with
  `healthyFeedCount == 0`.
- **Rollout order: feeds first, then the library (or both in one batch).** A NEW feed under the OLD library is
  safe: the old library prices a stale base at 0, so the new feed returns `(0, true)` exactly as today. An OLD feed
  under the NEW library is NOT safe on an L2: the deployed feeds' `NavBaseUsdLib` flags a base stale only when
  `pd.stale && !pd.sequencerDown`, which relied on a stale base having price 0. Under the new library a stale
  base keeps its price, so while the L2 sequencer is down an old feed reports a stale base as FRESH and the
  derived asset drops out of `stalePriceAssets`. So on every chain the feed swap must land before the
  implementation upgrade, or in the same Safe batch ([`script/deploy/ADR0029_ROLLOUT.md`](../../script/deploy/ADR0029_ROLLOUT.md)). On L1 (no sequencer) an old feed under the new library is
  merely unusable when its base is stale, which is today's behaviour. The new `NavBaseUsdLib` keys staleness on
  `healthyFeedCount == 0`, which does not depend on the sequencer.
- **Rate-only stale Custom feeds become unusable.** None is registered on any chain today.

## Alternatives considered

- **Return 0 for a quote with no usable price.** Rejected: there is no meaningful number in a unit that has no
  price, and a 0 reads like a real (empty) account.
- **Fix only the NAV library.** Rejected: Chainlink-direct assets would carry their price while every LST, vault
  and cross-rate feed priced off the same stale base would still drop to 0, producing an inconsistent NAV.
- **Add a heartbeat margin instead.** Rejected by 0025, and it only hides the flag; it does not remove the cliff.

## References

- Issue #351; `src/prices/PriceFeedLib.sol` (`_selectFeedCore`, `_readPrimaryFeed`, `_outranks`,
  `_getQuoteAssetInfo`, `_divergenceFor`); `src/constants.sol` (`MAX_STALE_PRICE_AGE`);
  `src/prices/NavBaseUsdLib.sol`.
- Precedent: 0019 already keeps a value and only flags it when the L2 sequencer is down.
- 0020 (custom-feed `getPriceData` freshness) is unchanged.
