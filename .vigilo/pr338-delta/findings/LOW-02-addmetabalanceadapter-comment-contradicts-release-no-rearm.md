# LOW-02: Stale comment in `addMetaBalanceAdapter` misstates the (correct) no-re-arm behavior of `_release`

## Summary
`NAVRegistryLib.addMetaBalanceAdapter`'s inline comment claims that wiping a freshly-registering adapter's dormant
instance set puts a registered-asset coordinate "back to ERC20DefaultBalanceAdapter." That is **not what the code
does** — `_release` (the function this call invokes per-coordinate) was deliberately changed to *never* re-arm the
default adapter, precisely to avoid a different double-count risk, and that reversal is extensively documented at
`_release`'s own definition. The two comments directly contradict each other. This is a documentation-accuracy bug,
not an exploitable path (the actual behavior is the safe, under-report direction), but a stale invariant claim like
this is exactly the kind of thing that misleads a future change into assuming a stronger guarantee than exists.

## Vulnerability Detail

### Root Cause
Two comments in the same file, both introduced/touched in the audited delta, assert opposite things about what
happens to a wiped coordinate that is a registered NAV asset:

### Code Location — the incorrect claim
- File: `src/nav/NAVRegistryLib.sol`
- Function: `addMetaBalanceAdapter`
- Lines: 180-183

```solidity
// Releasing first keeps the default adapter honest: a wiped coordinate that is a registered asset goes
// back to ERC20DefaultBalanceAdapter rather than being reported by nobody.
// @audit FALSE as of this same PR's `_release` — see NAVRegistryLib.sol:512-539. `_release` explicitly no
// longer re-arms the default adapter. A wiped coordinate that is a registered asset is reported by NOBODY
// until a MANAGER separately calls includeAssetInDefaultAdapter. This comment describes the OLD behavior
// the same author reversed a few hundred lines below.
_releaseInstances(claimant, metaInstances, adapter, erc20DefaultBalanceAdapter);
added = _appendInstances(claimant, metaInstances, adapter, instances, erc20DefaultBalanceAdapter);
```

### Code Location — the actual (correct) behavior, contradicting the above
- File: `src/nav/NAVRegistryLib.sol`
- Function: `_release`
- Lines: 512-539 (excerpt)

```solidity
// **RELEASING DOES NOT RE-ARM THE DEFAULT ADAPTER, and that is a deliberate reversal.** An earlier
// revision handed a released coordinate back to `ERC20DefaultBalanceAdapter` when it was a registered
// asset, so that retiring an adapter could not make a token vanish from NAV. ... has now reversed it,
// because the re-arm could not be made safe ...
// **So the trade is made explicitly in the licensed direction: releasing under-reports rather than
// risking a double count.**
```

## Impact
- **Likelihood**: N/A (documentation defect, not a code-path defect).
- **Impact**: Low — no functional consequence today, since the actual runtime behavior is the correct/safe one
  (under-report, not over-report). The risk is purely to future maintainers/auditors who trust the nearer comment
  (`addMetaBalanceAdapter`'s) without cross-checking `_release`'s own documentation, and who might therefore build a
  future change on the false assumption that a wiped-but-still-registered asset is automatically covered by the
  default adapter.
- **Severity**: LOW (informational-leaning, filed as Low because stale invariant claims directly caused confusion
  during this audit and are exactly the kind of thing `CLAUDE.md`'s doc-accuracy conventions exist to prevent).

## Attack Scenario
Not applicable — this is not an attacker-reachable bug. The "scenario" is a maintenance hazard: a developer reading
only `addMetaBalanceAdapter`'s comment could reasonably (and incorrectly) conclude that calling
`addMetaBalanceAdapter(existingButDormantAddress, [])` to clean up residue is fully benign for any registered-asset
coordinate held in that dormant set, without needing a follow-up `includeAssetInDefaultAdapter` call — and skip the
"re-arm first, deregister second" runbook step the project itself documents elsewhere (`_release`'s own comment,
lines 536-539).

## Recommended Mitigation
Correct the `addMetaBalanceAdapter` comment to match `_release`'s actual, current behavior, e.g.:

```solidity
// Releasing first prevents residue revival (issue #335): a wiped coordinate that is a registered asset is
// NOT automatically re-armed on ERC20DefaultBalanceAdapter (see _release's no-re-arm note below) — it is
// reported by nobody until a MANAGER calls includeAssetInDefaultAdapter. Releasing before appending only
// guarantees the wipe happens before the fresh claim, not that coverage is preserved.
```
