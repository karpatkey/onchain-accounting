# HIGH-01: `SwapMetaAdapter.plan()` — the documented "PRODUCTION path for the 24-adapter redeploy" hard-requires `deployments/<chainId>.pre-swap.json`, which no script in the repo produces, on any of the 8 asset chains

## Summary
`script/manage/SwapMetaAdapter.s.sol`'s `plan()` function is explicitly documented as *"PR #338 Phase 2: emit ONE
atomic ops-Safe MultiSend that swaps EVERY moved meta adapter old->new... This is the PRODUCTION path for the
24-adapter redeploy."* It derives each adapter's OLD address from `deployments/<chainId>.pre-swap.json`. No
script anywhere in this repository — including the purpose-built preflight tooling
(`reset_deployment_records.py`, `verify_step.py`, `snapshot_production.py`) — writes a file with that name. The
only pre-deploy snapshot mechanisms that exist write to `script/deploy/preflight/archive/<tag>/<chainId>.json`
and `script/deploy/preflight/snapshots/pre/<chainId>.json`, both different paths with different schemas. As
written, `plan()` cannot run on any of the 8 asset chains without an undocumented, ad-hoc, per-chain manual step
to fabricate `deployments/<chainId>.pre-swap.json` — exactly the kind of manual, error-prone, per-chain process
step that a fleet-wide migration should not depend on.

## Vulnerability Detail

### Root Cause
`plan()` reads two per-chain JSON files to compute each `(old, new)` adapter pair:

- File: `script/manage/SwapMetaAdapter.s.sol`
- Function: `plan()`
- Lines: 356-433 (the two file reads: lines 369-370; the docstring's own description of provenance: lines 344-349)

```solidity
string memory record = vm.readFile(string.concat("script/config/deployments/", idStr, ".json"));
// @audit REQUIRED input with NO producer anywhere in this repo:
string memory preSwap = vm.readFile(string.concat("script/config/deployments/", idStr, ".pre-swap.json"));
...
address newA = vm.keyExistsJson(record, ptr) ? vm.parseJsonAddress(record, ptr) : address(0);
address old = vm.keyExistsJson(preSwap, ptr) ? vm.parseJsonAddress(preSwap, ptr) : address(0);
```

The function's own docstring states the intended provenance:

```
///        - OLD addr = `deployments/<chainId>.pre-swap.json` `.balanceAdapters.<name>` (snapshotted by the
///                     preflight BEFORE the meta keys were cleared and `04` ran)
```

But grepping the entire repository for the literal string `pre-swap` (case-insensitive) turns up exactly two
hits: this file itself, and one finding written by a prior audit pass that also only *reads* the term from this
file — never a producer:

- `script/deploy/preflight/reset_deployment_records.py` — the actual "clear the meta keys before `04` runs" tool
  — archives the pre-clear record to `script/deploy/preflight/archive/<tag>/<chainId>.json` (see its own
  docstring, "The pre-clear record is archived to `script/deploy/preflight/archive/<tag>/<chainId>.json`
  first"), **not** to `deployments/<chainId>.pre-swap.json`.
- `script/deploy/preflight/verify_step.py` corroborates: it reads the pre-clear generation from
  `archive(tag, chain_id)` (→ `archive/<tag>/<chainId>.json`) and `snapshots/pre/<chainId>.json`, never from any
  `.pre-swap.json` path.
- `script/deploy/REDEPLOY_RUNBOOK.md` — the living operational runbook — has zero mentions of `pre-swap`,
  `SwapMetaAdapter.plan()`, or "PR #338 Phase 2" anywhere in its text (only one incidental mention of
  `SwapMetaAdapter.s.sol` in a retrospective note about `PolygonStakingMeta` bypassing the runbook entirely).

So the two tools that exist for exactly this purpose (`reset_deployment_records.py` + `verify_step.py`) use a
**different filename and directory** than the one `plan()` requires, and the runbook that is supposed to walk an
operator through a redeploy never bridges the gap.

### Consequence
`vm.readFile` reverts if the target file does not exist. On every one of the 8 asset chains (1, 10, 56, 100, 137,
8453, 42161 — Arc/5042 needs no swap, since it has no predecessor generation), `plan()` as currently wired simply
**cannot execute** unless an operator manually creates `deployments/<chainId>.pre-swap.json` by hand (e.g. an ad
hoc `cp deployments/<chainId>.json deployments/<chainId>.pre-swap.json` run at some undocumented point before
`04`). That manual step:
- has no tooling support, no dry-run, no validation that it was taken at the *correct* moment (before `04`
  overwrites the record, matching the doc comment's "snapshotted... BEFORE the meta keys were cleared and `04`
  ran"),
- must be repeated correctly, independently, by hand, across all 7 pre-existing chains, and
- if skipped, mistimed, or done against a stale copy on even one chain, `plan()` either reverts (file absent),
  or — more dangerously — silently reads a WRONG "old" address (e.g. a stale copy taken after a previous,
  unrelated adapter swap) and pairs it into the MultiSend batch. `plan()`'s own fail-closed checks
  (`_isMetaAdapter(old)`, `isAdapterRegistered(old)`) catch a plainly wrong address, but a *plausible* stale
  address (an adapter that happens to still be registered, just not the immediate predecessor) would not
  necessarily be caught, and is exactly the kind of per-chain data-entry error a manual, undocumented step
  invites.

## Impact
- **Likelihood**: High — this is not a conditional trigger, it is the default state of the repository today:
  attempting to follow `plan()`'s own documented procedure on any of the 7 pre-existing asset chains fails
  immediately for lack of the required input file.
- **Impact**: Medium-High — in the best case this is a hard blocker (script reverts, nothing broadcasts, caught
  immediately). In the worse case, an operator works around it by hand-authoring `.pre-swap.json` files under
  time pressure across 7 chains with no tooling support, which is exactly the scaled, manual, per-chain process
  this audit brief is looking for as a source of fleet inconsistency.
- **Severity**: HIGH — blocks (or forces an unsupported manual workaround for) the only atomic, over-report-safe
  production path for PR #338's fleet-wide meta-adapter migration.

## Attack Scenario
### Preconditions
- Chain X has had its `balanceAdapters.*` deployment-record keys cleared and `04_DeployBalanceAdapters` re-run,
  per the intended PR #338 flow.
- No `deployments/<chainId>.pre-swap.json` exists (the default, current state).

### Attack Steps
1. Operator runs `forge script script/manage/SwapMetaAdapter.s.sol --sig 'plan()' --rpc-url $RPC` for chain X, as
   directed by the script's own docstring ("This is the PRODUCTION path for the 24-adapter redeploy").
2. `vm.readFile("script/config/deployments/<X>.pre-swap.json")` reverts — file not found. The script halts before
   emitting any Safe batch.
3. To unblock the migration, an operator manually copies `deployments/<X>.json` to `deployments/<X>.pre-swap.json`
   at some point they judge to be "before `04` ran" — a judgment call repeated independently for chains 1, 10,
   56, 100, 137, 8453, 42161.
4. If that judgment is wrong on even one chain (e.g. the copy is taken AFTER `04` already wrote new addresses, so
   `old == new` for every adapter), `plan()`'s own skip logic (`old == newA` → "address unchanged") silently
   produces a batch with **zero adapters swapped** on that chain (`NoMetaAdaptersToSwap` revert) — an
   easy-to-miss, per-chain "this chain didn't actually migrate" outcome, or worse, a partially-correct
   hand-copied file pairs a wrong-but-plausible predecessor.

### Expected Impact
- Best case: the migration is blocked outright on every pre-existing chain until this gap is noticed and worked
  around — a process delay, not a fund-loss event.
- Worst case: an inconsistent, per-chain manual workaround produces a fleet where some chains complete the swap
  correctly and others silently fail to swap at all (still on pre-#338 bytecode) or pair a wrong predecessor,
  with no automated cross-chain check (see MEDIUM-02) surfacing the divergence.

## Recommended Mitigation
1. Add a `snapshot_preswap.py` (or extend `reset_deployment_records.py`) that writes
   `deployments/<chainId>.pre-swap.json` as a copy of the deployment record **at the same clearing step** that
   blanks the `balanceAdapters.*` keys — i.e. make the file `plan()` expects an actual artifact of the tool that
   already performs "snapshot before clearing", rather than an undocumented manual step.
2. Alternatively, change `plan()` to derive OLD addresses from `archive/<tag>/<chainId>.json` (the file that
   actually exists), taking `--archive-tag` as an input the same way `verify_step.py` does, so the two halves of
   the toolchain (clear + swap) share one snapshot format instead of two incompatible ones.
3. Add this step explicitly to `REDEPLOY_RUNBOOK.md` (or a PR #338-specific runbook), naming the exact command
   sequence and ordering, so "snapshot before clear" is not left to per-operator judgment on each of the 8
   chains.
