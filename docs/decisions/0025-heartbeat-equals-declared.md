# 0025 — A registered heartbeat MUST equal the provider's declared heartbeat

**Status:** Accepted (2026-08-28)
**Supersedes:** the `declared + 1 h` convention encoded in `script/deploy/preflight/declared_heartbeat_guard.py`
and applied by `f047d350`.

## Decision

For every price feed registered on `NAVCalculator`, the registered heartbeat is **exactly the value the
provider declares** for that feed. No margin is added.

    H = declared

This applies to the NAV-side `priceFeeds[i].heartbeat` and, for custom feeds, to the constructor
`<stem>Heartbeat` — the two independent gates on the same publish cadence.

A feed with no declared value on record is left unchanged and listed in "Not covered" below; it is not
guessed at.

## Why, in one line

**Claiming a price is fresh when it might be stale is the only error this system treats as critical.**
Every second of margin above `declared` is a window in which a dead feed reads fresh.

## The mechanism, and why margin is tempting

Chainlink's heartbeat is a *round-initiation* commitment, not a landing guarantee. From
[the decentralised data model docs](https://docs.chain.link/architecture-overview/architecture-decentralized-model):

> "A new aggregation round **starts** after a specified amount of time from the last update."

and the answer is written only once "the data feed aggregator contract [receives] responses from a
minimum number of oracles". So the on-chain `updatedAt` lands *after* `declared` by an aggregation +
transmission + block-granularity delay.

MEASURED (2026-08-28, `getRoundData` round-walks, 43 feeds carrying a declared value, declared spanning
255 s … 86 400 s — a 339× range): that delay is **+2 s … +96 s**, an absolute band that does **not**
scale with the declared value. Proportional behaviour would put the 86 400 s feeds at ~678 s; they
land at +24…+96 s.

That is a real effect, and it is exactly what motivated the old `declared + 1 h` convention: at `H =
declared` a heartbeat-driven feed spends the landing delay of every cycle classified stale.

## Why we accept that cost anyway

Within `[declared, declared + X]` the price **might** be healthy-with-latency or **might** be a dead
feed. Nothing in the data distinguishes them, and X is a random variable. Any margin is a bet that the
ambiguity resolves the benign way. `H = declared` refuses the bet.

The cost is bounded and was measured before accepting it. Staleness share ≈ landing-delay ÷ publish
interval:

| feeds | stale share of reads | per day |
|---|---|---|
| most of the fleet (86 400 s class) | 0.00 – 0.03 % | < 30 s |
| chain 1 DAI, COMP (3 600 s) | 0.66 % | ~9.5 min |
| 8453 cbBTC (1 200 s) | 2.4 % | ~35 min |
| 42161 USDC, USDT (255 s) | 5.6 % | ~80 min |

The fast feeds pay most, because the landing delay is a large fraction of their publish interval. Those
same feeds were previously registered at 86 400 s against declared values of 255 s — a **~24-hour**
window in which a dead feed read fresh. The trade is ~80 min/day of refusing to price Arbitrum USDC in
exchange for closing a day-long false-fresh window on it.

## What this is NOT

It is not a claim that the provider is late, or that a stale verdict inside the landing window is
"wrong". When `updatedAt` is older than `declared`, the round that should have started has not landed;
whether that is latency or death is unknowable from the timestamp alone. Classifying it stale is the
honest answer to an ambiguous question, not a false positive.

It is also not a substitute for divergence monitoring. Within `age < declared` no age-based rule can
distinguish a quiet healthy feed from a dead one; that residual is irreducible by any heartbeat and is
what `irregular` / `divergenceBps` / `healthyFeedCount` exist for.

## Consequences

- **Availability**: NAV reads are refused for the shares above. Consumers already MUST gate on `stale`
  (`src/nav/INAVCalculator.sol:483-487`), so this surfaces as a refusal, never as a wrong number.
- **`f047d350` is superseded, not reverted.** That commit fixed a real defect (18 pegged feeds going
  stale every cycle) with the tool available at the time. Its evidence stands; its remedy — hour-rounded
  margin — is replaced, because the margin it added is the exposure this ADR eliminates.
- **The guard inverts**: `declared_heartbeat_guard.py` moves from "registered must EXCEED declared" to
  "registered must EQUAL declared". Its ALLOWLIST, which existed to excuse zero-margin registrations,
  becomes vestigial for that purpose — zero margin is now the required state.
- **The snapshot becomes load-bearing.** `chainlink_declared_heartbeats.json` is the sole input. A
  provider lowering a declared value while the snapshot is stale silently re-creates exposure. It needs a
  scheduled `--refresh`, and it covers Chainlink only — Redstone declared cadences are not on record.

## Not covered by this ADR

- **36 registrations have no declared value on record** (mostly `Custom` primaries). Left unchanged.
- **Custom-feed constructor legs are immutable, but none of them is currently misaligned.** An earlier
  draft of this ADR listed eight `yToXHeartbeat` legs as "deferred", describing an 86 400 → 86 400 change
  and a 300 s delta — two claims that cannot both be true, and neither of which was right. Measured: every
  `yToXHeartbeat` leg is already at 86 400, so there is nothing to align. Most of these rate legs have **no
  declared value on record at all** (the guard reports them as `has NO declared heartbeat recorded`), so
  equality cannot be evaluated for them either way. The immutability still matters — they are constructor
  args and change only on redeploy — but it is a constraint on FUTURE divergence, not a backlog item. The
  one constructor leg that is not at 86 400 is `wARS.usdToAssetChainlinkHeartbeat` (90 000) — and a
  refreshed snapshot now resolves its USD/ARS feed, which **declares 86 400** — a +3 600 s window in which
  a dead USD/ARS feed still reads fresh. Because the value is a constructor arg it could not be realigned,
  so **the feed was redeployed and the registration swapped**: new feed
  `0xbAcb08665c68b5798D6C6138cA02471e7c704931` on chain 1, `FEED_HEARTBEAT` 86 400, NAV-side registration
  also 86 400, price identical before and after (62 285). **Done, not deferred.**

- **CI does not run this guard against the real config** — `foundry.yml` runs `--self-test` only. A real
  ADR 0025 violation therefore cannot fail CI, which is how both POL and the wARS leg survived. Wiring the
  real-config run into CI is the durable fix and would go red on wARS until the redeploy lands.
- **Chains 56 and 137 have no cadence measurement** (RPC unavailable during the sweep). Their declared
  values are on record, which is all this rule needs; the unmeasured risk is that their landing jitter is
  larger than elsewhere, and that failure lands in the accepted direction (more false-stale).

## How to apply this to a new feed

1. Read the declared heartbeat from `chainlink_declared_heartbeats.json` (`--refresh` if absent).
2. Register exactly that value, in both gates if it is a custom feed.
3. If no declared value exists, say so in the config `$comment`; do not invent one.
4. Derived / NAV-sourced feeds inherit their governing leg's timestamp (ADR 0019) and must not be gated
   tighter than that leg — `preflight_config.py` enforces this second axis independently.
