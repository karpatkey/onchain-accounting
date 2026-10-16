# 0028 — Calendar-gated oracles: the holdover is a named policy in the custom feed, and the registered heartbeat equals it (amends 0025)

- Status: proposed
- Amends: [0025](0025-heartbeat-equals-declared.md) — for one narrow feed class, stated below

## Context

[ADR 0025](0025-heartbeat-equals-declared.md) sets `H = declared`: a registered heartbeat is exactly the
provider's declared publish cadence, no margin, because "claiming a price is fresh when it might be stale
is the only error this system treats as critical". That rule assumes a feed whose silence is evidence of
a problem.

Robinhood Chain (chain id 4663) carries tokenised US equities priced by Chainlink `us_equities_24/5`
feeds. Their silence is evidence of a **closed tape**. They publish on the US equity calendar: a 24 h
(86,400 s) cadence while the market is open, and nothing at all from Friday's close until Monday's.

MEASURED (round-walks of `getRoundData` on the SPY feed, 4663, Sep 2026): a legitimate weekend gap of
**290,892 s** (3.4 days), against a longest intra-week gap of **86,417 s** — the heartbeat tick itself.
So `H = declared = 86,400` is not merely conservative here: it false-positives on **every weekend, every
night and every US holiday**. That is when the pools earn: 25-67 % of these pools' fee income arrives
off-hours, a figure the chain-4663 wrapper's own header states as measured, and whose shape is visible in
the hour-of-week fee distribution in `kpk-labs/APE-robinhood` `research/flow/flow-attribution-2026-09-09.md`
(top bucket Thursday 21:00 UTC, 4.27 % of all fees, just outside US regular hours; MEASURED, 9 Sep 2026).
A NAV that refuses to price for most of the week is not a safer NAV; it is an unusable one, and the
operator's remedy would be to widen the registered heartbeat by hand — which is exactly the unexplained
margin ADR 0025 exists to abolish.

Widening the registered heartbeat is also the wrong *shape*: one number would then answer two unrelated
questions, "how often does this oracle publish" and "how long may we mark to a closed tape", and the
second silently disables the alarm for the first.

## Decision

For a **calendar-gated** oracle — one whose publication is governed by a trading calendar, not by a fixed
cadence — the two questions get two numbers, both immutable, both named, both in code:

- **`HEARTBEAT`** stays the provider's declared cadence (86,400 s for these feeds). It is what
  `governingFeedFreshness()` reports, so ADR 0020's freshness contract and every monitor that reads it
  keep seeing the real publish commitment. ADR 0025's equality rule applies here unchanged.
- **`MAX_HOLDOVER`** is a separate, deliberate policy: the longest a closed-tape price may be carried
  before the feed reports `stale = true`. The recommended value for `us_equities_24/5` is **432,000 s**
  (5 days) — a Friday close plus a Monday US holiday (e.g. 7 Sep 2026) plus margin over the measured
  290,892 s worst case.

**The NAV-side registered heartbeat for such a feed is set equal to `MAX_HOLDOVER`, and to nothing else.**
`PriceFeedLib._selectFeedCore` applies the registered heartbeat to `Custom` feeds too, so a registration
at the declared 86,400 s would discard the wrapper every weekend regardless of its `stale` flag and the
policy would be dead on arrival. Registering anything *larger* than `MAX_HOLDOVER` would re-create the
unexplained margin. Equality makes the outer gate fire at the same second as the policy — which holds
only because the wrapper's own test is the **inclusive** `age >= MAX_HOLDOVER`, the same bound
`_selectFeedCore`, `InvertedChainlinkCustomPriceFeed` and `TwoFeedChainlinkPriceFeed` use. A wrapper
written with `>` would leave the NAV refusing one second before its own policy does; the next
calendar-gated feed must keep the inclusive form.

**What bounds the exposure is `MAX_HOLDOVER`, not the registration.** This is what makes the carve-out
not a regression against ADR 0025: the wrapper returns `stale = true` past its holdover and
`PriceFeedLib` honours that flag first, so the false-fresh window 0025 protects is set by the wrapper's
gate, which is strictly tighter than anything the registered value could permit. Widening the
registration cannot widen the exposure; it can only make the two numbers disagree about which one is
the policy.

**The registration path, not the policy constant, is the seam to bind to.** The wrapper exposes
`requiredRegistrationHeartbeat()` (what to register) and `registrationHeartbeatSatisfiesPolicy(uint256)`
(whether a proposed registration is acceptable). Deploy-time checks and monitors read those, not
`MAX_HOLDOVER()`: the first is an instruction to the registration path and the second is a policy
constant, and a guard bound to the constant breaks the first time the two legitimately diverge.

So ADR 0025 generalises rather than breaks: **the registered heartbeat equals the declared value of
whichever gate governs the feed.** For an ordinary feed that is the provider's cadence. For a
calendar-gated custom feed it is the holdover the wrapper declares, in a constant, with a measurement
behind it.

**This tightens what chain 4663 does today.** Its deploy gate requires the registered heartbeat to
*exceed* the largest wrapper holdover and registers **518,400 s** against a 432,000 s holdover
(MEASURED, `deploy.sh --verify-only`: "registrationHeartbeat 518400s exceeds the largest wrapper holdover
432000s"). The extra day buys one property — the wrapper's `stale` flag is then the only gate that can
fire, so there is exactly one place the decision lives — and costs the thing ADR 0025 was written about:
a 86,400 s window in which the NAV's own gate would accept a feed the policy has already given up on.
Both gates honour `stale`, so the safety difference is nil and the clarity difference is not. Equality is
the recommendation; adopting it means re-pointing the 4663 equity feeds' registered heartbeat from
518,400 to 432,000 at the next NAV change, which is a MANAGER call and no redeploy.

### What is explicitly not held over

Four conditions are hard staleness no matter how recent the timestamp, and the wrapper enforces all four:
a non-positive answer, `updatedAt == 0`, an effective multiplier of zero, and an active `oraclePaused()`
on the token. The last matters most: a corporate action (split, ticker change, delisting, halt) is
precisely the event that stops the last print from being a fair mark. Robinhood's documentation is
explicit that the flag is advisory and not enforced on-chain, so a paused oracle can still return a
value; the wrapper honouring it is the only thing that makes it bite anywhere in the NAV.

## Consequences

**Positive**

- The holdover is one reviewable line with a number and a measurement attached, instead of an emergent
  property of a heartbeat someone widened once.
- `governingFeedFreshness()` keeps reporting the true cadence, so monitoring can still see a feed that
  has stopped publishing *during* a session — the failure that matters — while the NAV keeps pricing
  across the weekend.
- The rule is bounded. It applies only to feeds whose underlying has a trading calendar, and each such
  feed must carry its own measured worst-case gap in the config `$comment`.

**Negative**

- **Between `HEARTBEAT` and `MAX_HOLDOVER` the feed reports `stale = false` while returning an answer
  that is stale in the ordinary Chainlink sense.** This is a stale-but-accepted mark and `MAX_HOLDOVER`
  sizes the exposure. The consequence is concrete: a subscription or redemption settled off-hours
  transacts at the last close, not at a live price, and if the equity gaps overnight the NAV used for
  that flow is wrong by the size of the gap and the counterparty captures the difference. Operators who
  do not accept that must gate flow on session times off-chain; the on-chain feed cannot make that
  distinction and does not pretend to. (On 4663 that gate exists: `ops/roles/settle_price.py` refuses to
  settle a vault holding equity outside the 24/5 window.)
- `declared_heartbeat_guard.py` must learn this class, or it will read an equity registration at 432,000
  against a declared 86,400 and fail. The guard asks the wrapper rather than carrying a second copy of
  the number: `registered == feed.requiredRegistrationHeartbeat()`, or equivalently
  `feed.registrationHeartbeatSatisfiesPolicy(registered)`, for any feed that answers those selectors,
  falling back to `registered == declared` for every feed that does not. Until that lands, no
  `us_equities_24/5` feed should be registered on a chain the guard covers.
- A second number per feed is a second thing to get wrong. The mitigation is that both are immutable
  constructor-time values on a contract with no admin: changing either means deploying a new wrapper and
  re-pointing the asset through the NAV's own MANAGER path, where it is visible.
