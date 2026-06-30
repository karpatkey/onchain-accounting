# 0003 — Integration-test snapshot workflow + Debank cross-check

**Status:** accepted

## Context

The integration tests under `test/integration/` deploy `NAVCalculator` on a forked chain at a pinned block, register every asset and balance adapter from chain config, and assert exact `getAccountNav` values for a set of accounts. Each per-chain test file (Mainnet, Optimism, Arbitrum, Base, Gnosis) hardcoded the fork block, the account addresses, and the expected NAVs as Solidity constants.

This worked but had three structural problems as the adapter and feed surface grew:

1. **Fork blocks rot.** They were captured once and never refreshed. The fixture aged and stopped representing current chain state.
2. **Adding a test account = editing 5 Solidity files.** The friction was high enough that we accumulated only three accounts (`ACCOUNT_1`, `ACCOUNT_2`, `ACCOUNT_3`) over the project lifetime, even though we wanted broader coverage for new adapters.
3. **No external sanity check.** The expected NAVs were captured by running the test once and writing down the output. Nothing independently confirmed the output was right at capture time — the per-chain test files literally had a comment `Compare value/1e8 against Debank's USD total for each account.` as a manual instruction.

The user wanted a script-driven workflow that, on demand, (a) bumps every chain's fork block to latest, (b) regenerates expected NAV values, (c) cross-checks each account's NAV against an authoritative external reference (Debank), with a tolerance assertion at bump time so future test runs stay deterministic but every refresh is independently validated.

## Decision

A single JSON file — `test/integration/accounts.json` — is the source of truth for chain fork blocks, the account list, the per-chain enable flags, and the snapshotted expected NAVs (and Debank references). All test code, scripts, and CI consume this file; nothing else stores expected NAVs.

A bump-and-snapshot workflow regenerates the JSON in four discrete steps:

1. **Bump fork blocks.** `cast block-number` per chain, write `forkBlock` back to JSON.
2. **Refresh NAV.** `forge test --match-test test_emitSnapshots` per chain. The test forks at the bumped block, replays the integration test deploy pipeline (NAV + every enabled price feed + every enabled balance adapter), reads NAV per enabled account, and emits structured `SNAPSHOT|…` log lines. The shell wrapper parses those lines and writes `navUsd8dp` into JSON via `jq`. (The original design used a dedicated `forge script script/test/RefreshIntegrationSnapshot.s.sol`; `forge script` hung indefinitely on Mainnet, so the refresh script switched to `forge test`, which runs the identical pipeline. The script is retained for reference but no longer invoked — see the howto doc.)
3. **Refresh Debank reference (optional).** `curl /v1/user/all_complex_protocol_list` (and `/v1/user/token_list`) per account when `DEBANK_API_KEY` is set, summing the relevant per-chain USD value. Write `debankUsd` into JSON.
4. **Tolerance check + report.** For every (chain × account) with both `navUsd8dp` and `debankUsd`, assert `|nav/1e8 − debank| / debank ≤ tolerance`. Print a markdown report; exit code 2 if any drift exceeds tolerance.

Tests stay deterministic: `_assertNavsForCurrentChain` asserts `nav.value == expected.<chainId>.navUsd8dp` from JSON. The Debank cross-check is bump-time only.

A GitHub Actions workflow (`.github/workflows/refresh-integration-snapshot.yml`) provides a `workflow_dispatch` trigger and a weekly cron. It runs the bump script, opens a PR with the updated JSON and the report as the body, and surfaces tolerance violations. Humans merge — matching the rest of this repo's policy.

## Consequences

**Positive:**

- Adding a test account is one JSON edit + a script run. No Solidity changes; no per-chain duplication.
- Fork blocks can be refreshed at will without touching test code.
- The Debank cross-check is an independent reference — the snapshots are no longer "correct because we said so." Drift beyond tolerance fails the bump (but never a normal CI run).
- Tests remain deterministic. CI reruns produce identical results until the JSON is regenerated.
- Debank dependency is opt-in. A missing or out-of-units key gracefully degrades to "snapshots refreshed, no cross-check," not a hard failure.

**Negative / things to watch:**

- The JSON can drift quietly between bumps if no one runs the script. Mitigation: weekly cron in CI.
- Debank's "current" view and our "fork at block N" can diverge on volatile assets in the seconds between `cast block-number` and the Debank query. The 1% default tolerance is calibrated for normal market moves; protocols with poor Debank coverage or peg-stressed stables may need temporary tolerance adjustments.
- Forge's `vm.writeJson` has unreliable JSONPath array-index handling, which is why the forge script *prints* `SNAPSHOT|…` lines that the shell wrapper applies via `jq` rather than writing JSON in-process. This is an extra hop but portable across Foundry versions.
- Single test method per chain (`test_accountNavs`) loops over accounts. On failure, the method logs a `[NAV-MISMATCH]` line carrying the account label and chainId before reverting with a generic message, so failures are still attributable from the logs — but you don't get the "X passed, Y failed per account" view that one-method-per-account would. Acceptable trade-off for the JSON-driven shape.

## Alternatives considered

1. **Live Debank assertions on every CI run.** Rejected. Costs Debank units on every run, depends on Debank uptime, and timing drift between forge's fork block and Debank "now" introduces noise that would make CI flaky. Tolerance check at bump time gives the same signal without these costs.
2. **One test method per account (`test_account1_nav`, …) backed by JSON.** Rejected. Would require either codegenning per-account methods at fork-setup time (Solidity can't) or hardcoding N method stubs in each per-chain test (defeats the JSON-driven goal).
3. **`forge test`-based snapshot generator that early-returns on every normal run.** Rejected as the *registered test*. A dedicated `forge script`, invoked only when the user runs the refresh, was chosen instead so normal CI runs don't pay the `setUp` cost for a snapshot path. (Note: snapshot emission later moved into a dedicated `test_emitSnapshots` method because `forge script` hung on Mainnet — see step 2. Because it lives in the same contract as `test_accountNavs`, it shares that contract's `setUp`, adding no *extra* per-chain setup over the assertion test the run already pays for. It does still execute on every normal `forge test` run — emitting `SNAPSHOT|…` lines and rewriting `nav-positions-<chainId>.json` — but asserts nothing, so it is a cheap, harmless side path; the refresh script invokes it deliberately via `--match-test`.)
4. **`vm.writeJson` writing back to the same file from Solidity.** Rejected after testing — the array-index path syntax `.accounts[i].expected.<chainId>.navUsd8dp` is interpreted as an object key in the version of Foundry pinned by this repo, producing `"accounts[0]": {…}` siblings rather than updating `.accounts[0]`. Log-then-jq sidesteps the bug.

## Reference

- Workflow doc: [`docs/howto/refresh-integration-test-blocks.md`](../howto/refresh-integration-test-blocks.md)
- Source of truth: `test/integration/accounts.json`
- Test base: `test/integration/IntegrationFromConfigBase.fork.sol`
- Snapshot emission: `test_emitSnapshots` in `test/integration/IntegrationFromConfigBase.fork.sol` (run via `forge test --match-test`)
- Legacy forge script (retained, no longer invoked): `script/test/RefreshIntegrationSnapshot.s.sol`
- Shell orchestrator: `script/test/refresh-integration-snapshot.sh`
- CI workflow: `.github/workflows/refresh-integration-snapshot.yml`
- Related decision: ADR [0004](0004-morpho-projected-vs-stored-balances.md) — Morpho projected vs stored balances, the main source of expected Debank drift
