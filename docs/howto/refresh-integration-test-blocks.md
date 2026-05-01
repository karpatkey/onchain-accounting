# How to refresh integration-test fork blocks (and cross-check NAV against Debank)

The integration tests in `test/integration/` deploy `NAVCalculator` from scratch on a forked chain at a pinned block, register every asset and balance adapter from chain config, and assert exact `getAccountNav` values for a set of accounts. Over time those fork blocks rot and the expected NAVs drift from reality. This walkthrough covers the bump-and-snapshot workflow that keeps them current and (optionally) cross-checks each NAV against Debank's USD total.

The single source of truth is [`test/integration/accounts.json`](../../test/integration/accounts.json). The workflow reads and writes it; the integration tests assert against it. **Do not edit the per-chain `NAV.<Chain>.integration.fork.t.sol` files** when adding accounts or refreshing values — only edit `accounts.json`.

---

## When to run it

- After adding a new balance adapter, price feed, or asset that meaningfully changes NAV for an existing account.
- After adding a **new test account** (also a JSON edit; see §5 below).
- On a routine cadence so the fixture doesn't drift more than ~tolerance off reality. The repo includes a weekly cron in [`.github/workflows/refresh-integration-snapshot.yml`](../../.github/workflows/refresh-integration-snapshot.yml).
- Before bumping a release branch.

---

## What the workflow does

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. cast block-number per chain (PARALLEL) → forkBlock bumped         │
├──────────────────────────────────────────────────────────────────────┤
│ 2. forge build once (warm cache) → forge script per chain (PARALLEL) │
│    → deploys NAV stack at the new fork, reads NAV per enabled        │
│    account, emits SNAPSHOT|... lines that are applied via jq         │
├──────────────────────────────────────────────────────────────────────┤
│ 3. (optional) curl Debank /v1/user/chain_balance per (chain×account) │
│    → writes debankUsd into JSON                                      │
├──────────────────────────────────────────────────────────────────────┤
│ 4. tolerance check + diff report                                     │
└──────────────────────────────────────────────────────────────────────┘
```

Step 2 is the bottleneck (deploying a full NAV stack on a fork takes ~1–3 min per chain). Running all five chains in parallel reduces wall time from `sum(chains)` to `max(chains)` — typically Mainnet, since it has the most adapters. A single `forge build` runs before the parallel forge invocations so they share a warm cache without racing on `out/`. Each chain's stdout is captured to a per-chain log file in a temp directory; SNAPSHOT lines are applied to `accounts.json` in chain-id order after all forks finish, so output is deterministic and there's no jq-write race.

Tests stay deterministic: they assert against the snapshotted exact NAV in `accounts.json`. The Debank cross-check happens **at bump time only**, so test runs do not depend on Debank availability.

---

## Prerequisites

- `forge`, `cast` (Foundry).
- `jq`, `curl` (most systems already have these).
- Per-chain RPC access. The script picks RPC URLs in this order:
  1. Chain-specific env: `MAINNET_URL`, `ARBITRUM_URL`, `BASE_URL`, `OP_URL`, `GNOSIS_URL`.
  2. Falls back to `https://<alchemyNetwork>.g.alchemy.com/v2/$ALCHEMY_API_KEY` (where `alchemyNetwork` is read from `accounts.json`).
- Optional: `DEBANK_API_KEY` (Debank Pro). If unset, the cross-check is skipped — fork blocks and NAV snapshots still refresh.

---

## Run it locally

```bash
# Default (Debank cross-check on if DEBANK_API_KEY is set):
script/test/refresh-integration-snapshot.sh

# Force-skip Debank even if the key is in the environment:
DEBANK_API_KEY= script/test/refresh-integration-snapshot.sh
```

Output:

- `refresh-report.md` (project root) — markdown table per chain and per (chain × account).
- `test/integration/accounts.json` — updated in place. Inspect with `git diff` before committing.

Exit codes:

| Code | Meaning |
|---|---|
| `0` | All snapshots refreshed, no tolerance violations. |
| `2` | Snapshots refreshed, but at least one (chain × account) drifted beyond `tolerance` against Debank. Inspect the report. |
| `1` | Hard failure (RPC unreachable, `forge script` reverted, malformed JSON). |

After a clean run, verify the integration tests still pass against the new snapshots:

```bash
FOUNDRY_PROFILE=slow forge test --match-path "test/integration/**"
```

---

## Run it via CI

[`.github/workflows/refresh-integration-snapshot.yml`](../../.github/workflows/refresh-integration-snapshot.yml) exposes:

- A weekly cron (Mondays 06:00 UTC). Includes Debank.
- A `workflow_dispatch` trigger with an `include_debank` toggle.

The workflow runs the script, then opens (or updates) a PR titled `chore(integration): refresh fork blocks and Debank snapshots` with the updated `accounts.json` and the report as the PR body. **The workflow does not auto-merge** (matches the rest of this repo: humans merge).

Required secrets / repo vars:

| Name | Where | Notes |
|---|---|---|
| `KNODE_URL` (var) | repo variables | Existing — same one used by `foundry.yml`. |
| `KNODE_API_KEY` | repo secrets | Existing. |
| `ALCHEMY_API_KEY` | repo secrets | Existing fallback. |
| `DEBANK_API_KEY` | repo secrets | New. Used only when the workflow is triggered with `include_debank: true` (default for cron runs). |

---

## Adding a new test account

Edit `test/integration/accounts.json`:

```json
{
  "address": "0x…",
  "label": "ACCOUNT_4",
  "enabledChains": [1, 42161],
  "expected": {
    "1":     { "navUsd8dp": "", "debankUsd": "" },
    "42161": { "navUsd8dp": "", "debankUsd": "" }
  }
}
```

Then run the bump script. It will populate `navUsd8dp` (and, if Debank is configured, `debankUsd`) for the chains in `enabledChains`. No Solidity changes required.

To **remove** an account: delete the object. To **disable on a chain**: drop the chainId from `enabledChains`. The integration tests will skip whatever isn't enabled.

---

## Tolerance failures — how to triage

The script's exit-code 2 means at least one (chain × account) had `|navUsd − debankUsd| / debankUsd > tolerance` (default 1%). Common causes, in order of frequency:

1. **Block-time drift between fork and Debank "now."** Debank's `/v1/user/chain_balance` returns a current snapshot, while our forge run forks at the bumped block (which is a few minutes old). Spot prices for volatile assets (LSTs, LRTs, sometimes stables in stress) can move enough to exceed 1% over that window. Re-run the script; if it stabilises, this was the cause.
2. **Stale Debank cache for the protocol.** Debank's protocol valuations are refreshed asynchronously; their docs note up-to-12-hour worst case. If the affected position is in a freshly-onboarded protocol or one Debank has poor coverage of, expect drift here.
3. **Oracle vs market-rate disagreement.** Our NAV uses Chainlink + protocol on-chain rates; Debank uses Coingecko-ish market prices. For peg-deviating assets (USDe, sUSDe under stress) these can diverge meaningfully.
4. **A real adapter bug.** If 1–3 don't apply and the drift is large or persistent, the adapter is computing the wrong amount or sign. Open the per-protocol fork test for that adapter and compare.

To raise tolerance, edit the top-level `"tolerance"` field in `accounts.json` (and document why in the PR description).

---

## Debank tier introspection

When the script starts, it calls `/v1/account/units` and logs the units balance. If the call fails or returns no balance, the run continues with Debank skipped — no abort. The intent is graceful degradation: a missing or out-of-units key is a *warning*, not a failure.

If your tier is too low to cover a full run (~1 unit per `/v1/user/chain_balance` call × 5 chains × N accounts), use `DEBANK_API_KEY=` to skip Debank entirely and rely on the snapshotted NAVs alone. Snapshots are still valid for deterministic test asserts; they just lose their independent reference.

Reference: [Debank Cloud — User endpoints](https://docs.cloud.debank.com/en/readme/api-pro-reference/user). Pricing/units docs: [Units Usage](https://docs.cloud.debank.com/en/readme/auxiliary-feature/units).

---

## How the deterministic asserts work

`test/integration/IntegrationFromConfigBase.fork.sol` reads `accounts.json` in `setUp` and `_assertNavsForCurrentChain`:

- `_chainId` is set by the per-chain test contract.
- `_forkBlock` is read from `accounts.json[".chains.<chainId>.forkBlock"]` (unless the child sets a literal — used only for one-off debugging).
- For each account whose `enabledChains` includes `_chainId`, the test reads the expected `navUsd8dp` from `accounts.json[".accounts[i].expected.<chainId>.navUsd8dp"]` and `assertEq`'s the live NAV against it. Failures cite the account label.

Per-chain test contracts are stubs:

```solidity
contract MainnetIntegrationFromConfig is IntegrationFromConfigBase {
    function setUp() public {
        _chainId = 1;
        _forkNetwork = "eth-mainnet";
        _setupAndDeploy();
    }
    function test_accountNavs() public view { _assertNavsForCurrentChain(); }
}
```

The bump script regenerates the JSON; the tests just consume it.

---

## Files

- `test/integration/accounts.json` — source of truth.
- `test/integration/IntegrationFromConfigBase.fork.sol` — reads JSON; deploys NAV; asserts.
- `test/integration/NAV.<Chain>.integration.fork.t.sol` — chain stubs.
- `script/test/RefreshIntegrationSnapshot.s.sol` — forge script that emits `SNAPSHOT|…` lines.
- `script/test/refresh-integration-snapshot.sh` — orchestrator (cast + forge + curl + jq).
- `.github/workflows/refresh-integration-snapshot.yml` — CI workflow (manual + weekly).
- `docs/decisions/0003-integration-test-snapshot-workflow.md` — design rationale.
