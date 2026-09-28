# LOW-03: `GasStipendLib` classification has a documented, narrow residual window where a real gas-exhaustion is misread as a clean revert (dropped debt leg raises reported NAV)

## Summary
The new gas-metered fan-out in `MetaBalanceAdapter._positionsForInstances`/`_assetsForInstances` reverts
`InstanceGasExhausted` (fail-closed) when a per-instance call is classified as having run out of gas, which is the
correct design to prevent a silently-truncated read. However, the classifier it depends on
(`GasStipendLib.exhausted`) uses a fixed `1/8` slack tolerance that its own documentation states only **narrows**,
not **closes**, the window in which a genuinely gas-starved call is misclassified as an ordinary (non-exhaustion)
revert. In that narrow window, the instance's legs are silently dropped instead of the read reverting — and for a
**debt** leg, a dropped leg makes reported NAV read *higher* than it should, i.e. an over-statement in net terms,
even though no single balance is literally double-counted.

## Vulnerability Detail

### Root Cause
- File: `src/utils/GasStipendLib.sol`
- Function: `exhausted`
- Lines: 58-60

```solidity
function exhausted(uint256 stipend, uint256 consumed) internal pure returns (bool) {
    // @audit SLACK_DIVISOR = 8 (1/8 tolerance). The library's own docs (lines 14-20) state: "An exact test
    // sees the shortfall and calls a starved callee healthy... no fixed fraction is exact either, so
    // SLACK_DIVISOR narrows the silent window rather than closing it." A genuinely-starved call whose
    // nesting depth leaves it just outside the 7/8*stipend threshold is classified `exhausted == false`.
    return consumed >= stipend - stipend / SLACK_DIVISOR;
}
```

Consumers rely on this classification to decide between reverting loudly (`InstanceGasExhausted`) and silently
dropping an instance's legs:

- File: `src/balances/MetaBalanceAdapter.sol`
- Function: `_positionsForInstances`
- Lines: 370-386 (the debt-leg risk is explicitly named in this function's own docstring, lines 331-338:
  *"a dropped debt leg RAISES the reported NAV"*)
- Function: `_assetsForInstances` (the delta's NEW gas-metering, applied here for the first time per the PR
  description quoted in-file) — Lines: 401-433, same classify-or-drop shape.

### Residual, acknowledged in-code
`GasStipendLib.sol:25-30`:
> "**What this cannot see at all.** ... A callee that wraps its own read in `try`/`catch` — or in a fail-open
> low-level staticcall — absorbs the out-of-gas itself ... and RETURNS SUCCESSFULLY with a leg missing. No
> classifier upstream is reached..."

This is a second, independent residual (an adapter's *own* internal `try/catch` swallowing its out-of-gas) on top of
the SLACK_DIVISOR classification gap — both land in the same place: a leg silently missing instead of a loud revert.

## Impact
- **Likelihood**: Low. Landing exactly in the classification's blind spot requires an attacker (or organic protocol
  growth, e.g. a permissionless per-account withdrawal-request list the docstring calls out at
  `MetaBalanceAdapter.sol:355-361`) to tune the per-instance read's gas cost to within the ~1/8 slack band of the
  forwarded stipend — a narrow, hard-to-target window, not a free-form griefing primitive.
- **Impact**: Low-Medium if hit — a debt leg for one instance goes missing from one account's NAV read, overstating
  that account's *net* reported value by the size of that debt leg. It is not a duplicate-reporting event in the
  sense the audit brief calls Critical (no single balance is counted by two adapters); it is a net overstatement via
  omission, on a single instance, for the specific account that triggers it.
- **Severity**: LOW — bounded to at most one dropped debt leg per triggering read, requires precise gas targeting,
  and the vast majority of genuine exhaustion is already correctly caught and reverted by this same mechanism (that
  is the point of the PR's fail-closed redesign; this finding is about the residual the design's own comments say
  remains).

## Attack Scenario

### Preconditions
- A meta-adapter instance whose per-instance debt-leg read cost can be influenced by a third party (e.g. a
  protocol that lets anyone grow a per-account list the adapter must iterate, as already flagged for the
  positions fan-out at `MetaBalanceAdapter.sol:355-361`).
- The attacker can iterate/tune the added cost so the per-instance call's gas consumption lands just under
  `stipend - stipend/8` for the account's own `getAccountNav` call's outer gas budget.

### Attack Steps
1. Attacker grows the target account's per-instance state (e.g. adds entries to a permissionless list the debt-leg
   read must scan) until the read's gas cost approaches, but does not exceed, the exhaustion threshold at the
   `eth_call`/outer-caller's current gas budget.
2. A NAV read (`getAccountNav`) reaches this instance. `_positionsForInstances` samples `available = gasleft()`,
   forwards `stipend = stipendFrom(available)`, and the per-instance call reverts from genuine gas starvation but
   consumes just under `stipend - stipend/8`.
3. `GasStipendLib.exhausted` returns `false` (misclassified as an ordinary revert, not exhaustion).
4. `_positionsForInstances`'s `catch` branch records `perInstance[i] = new PositionBalance[](0)` instead of
   reverting `InstanceGasExhausted` — the debt leg for this instance is silently dropped.
5. The read returns successfully; the account's reported NAV is higher than it should be by the value of the
   dropped debt leg, with no health flag distinguishing this read from a fully-covered one.

### Expected Impact
- The account's reported net asset value is overstated by the value of one dropped debt leg, on the specific
  account and instance the attacker (or organic gas growth) targeted, until the underlying gas-cost growth is
  addressed (removing the instance, per the docstring's own stated remedy at `MetaBalanceAdapter.sol:361-362`).

## Recommended Mitigation
This is an accepted, documented trade-off inherent to any threshold-based gas classifier, and the PR's own docs
already state the tolerance only narrows rather than closes the window — no code change is strictly required. If
tighter bounds are wanted: lower `SLACK_DIVISOR`'s effective tolerance for the specific families most likely to hit
it (per-account, permissionlessly-growable lists), or add a secondary hard cap on iteration count for those
specific instances so their worst-case cost cannot approach the classifier's blind spot at all.
