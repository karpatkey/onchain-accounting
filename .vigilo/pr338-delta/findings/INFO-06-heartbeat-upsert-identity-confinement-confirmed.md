# INFO-06: Heartbeat-upsert (`addFeed`/`addMonitorFeed`) confirmed confined to the `chainlinkHeartbeat` field only — no address/decimals/priceType/array-position mutation path found

## Summary
Per audit brief item 1(a)/(c)/(d): traced `PriceFeedLib.addFeed` (`src/prices/PriceFeedLib.sol:1653-1740`) and
`addMonitorFeed` (`src/prices/PriceFeedLib.sol:1788-1859`) end to end. The only storage write on the
already-registered branch is `configs[i].chainlinkHeartbeat = heartbeat;` (line 1713) /
`monitors[i].chainlinkHeartbeat = heartbeat;` (line 1828). No other field of `IPrices.PriceFeedConfig` (`priceFeed`,
`priceType`, `decimals`) is ever reassigned on the upsert path, and the array index `i` the matched feed lives at is
never touched (no `push`/`pop`/reorder happens on this branch — those only occur on `removeFeedAt`/`removeFeed` via
`_swapPopFeed`, an entirely different code path). Confirmed fail-safe on every sub-question raised:

- **(a) Cannot change feed address / decimals / priceType / array position.** The match key is
  `configs[i].priceFeed == priceFeed` (an exact address match is required to reach the upsert branch at all), the
  `priceType` is verified unchanged before any write (`PriceFeedTypeImmutable` guard, line 1709), `decimals` is
  never reassigned on this branch (only compared, at line 1685, against the freshly resolved value — a mismatch
  reverts rather than rescales), and array position is untouched since no `configs[i] = ...` or swap/pop runs here.
- **(b) The type-immutable guard reliably rejects every type-change attempt traced** (see the companion finding
  LOW-05 for the one caveat: the guard's *effect* — rejection — is unconditionally correct, but the *named error*
  surfaced varies depending on which two `priceType`s are involved, since `_resolveFeedDecimals` can itself revert
  or coincidentally match before the identity check at line 1709 is reached).
- **(c) `heartbeat == 0` is rejected** (`if (heartbeat == 0) revert IPrices.InvalidPriceOracle();`, line 1660 /
  1806). There is **no upper bound** on `heartbeat` beyond that zero check, in either the append or upsert branch —
  this predates PR #338 (the pre-PR "mirror-swap" admission path used the identical `addFeed`/`addPriceFeed`
  function for its final registration step, so the absence of a ceiling is not a new regression introduced by the
  heartbeat-upsert feature). An absurdly large heartbeat set by a MANAGER would loosen — never tighten past
  intent — staleness detection for that feed, and an absurdly *small* (but nonzero) heartbeat would make the feed
  perpetually stale. Both are MANAGER-privileged actions (`NAVCalculator.addOrModifyPriceFeed` /
  `addMonitorFeed`, both gated by `_requireManager()`), and the perpetual-staleness direction resolves to
  `_selectFeedCore` returning `price = 0, stale = true` when no feed is healthy
  (`src/prices/PriceFeedLib.sol:188-190`) — the codebase's documented safe (under-report, never over-report)
  direction — rather than any silent over-valuation. No code change recommended; flagged for completeness per the
  brief's explicit ask.
- **(d) Decimals re-resolution + drift check.** `_resolveFeedDecimals` (lines 1625-1634) is called on *every*
  `addFeed` invocation — append or upsert — and its result is compared against `configs[0].decimals`
  (lines 1685-1687), reverting `PriceFeedDecimalsMismatch` on any drift. This is a genuine improvement over the
  pre-PR admission-only check (per the inline comment at lines 1674-1683): previously a feed's decimals could only
  be caught at initial registration; now any voluntary heartbeat-upsert touch on that feed **also** re-validates its
  live decimals against what was stored, surfacing drift (e.g. a Chainlink `AggregatorProxy` whose underlying
  aggregator was swapped to a different `decimals()`) the next time an operator touches that feed's config. Note
  this is a re-validation-on-touch, not a continuous live re-check — the ordinary read path
  (`_selectFeedCore`/`_scaleTo8`) still uses the cached `cfg.decimals` on every price read and does not itself
  detect drift between touches; that is pre-existing behavior unchanged by this PR, and out of scope as a
  delta-introduced issue.

## Verification
- File: `src/prices/PriceFeedLib.sol`
- Functions read in full: `addFeed` (1653-1740), `addMonitorFeed` (1788-1859), `_resolveFeedDecimals` (1625-1634),
  `_swapPopFeed` (1639-1651), `removeFeedAt`/`removeFeed` (1743-1778), `_selectFeedCore` (102-193).
- Access control confirmed: `NAVCalculator.addOrModifyPriceFeed` (`src/nav/NAVCalculator.sol:199-214`) and
  `addMonitorFeed` (`src/nav/NAVCalculator.sol:216-`) both call `_requireManager()` before delegating to these
  library functions — the upsert path is not reachable by an unprivileged caller.

## Impact
- **Severity**: Informational — confirms the PR's own stated invariant ("Only the heartbeat moves") holds under
  direct code inspection; no exploitable gap found.

## Recommended Mitigation
None required for (a)/(b)/(d). Optional hardening for (c), not required by any exploit path found: consider an
upper-bound sanity check on `heartbeat` (e.g. reject values beyond a generous multi-day ceiling) purely to catch
operator fat-fingering (an extra zero) rather than any security gap, since the failure direction is already the
safe one (stale → price zeroed, never over-reported).
