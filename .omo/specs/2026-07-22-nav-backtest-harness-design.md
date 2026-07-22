# NAV historical backtest harness + CI build cache — design

Date: 2026-07-22
Branch: `feat/nav-backtest-harness`
Status: approved pending user review of this document

## Problem

We want to (a) simulate deployment of the NAV stack at historical blocks and observe behavior over time — e.g. hourly `getAccountNav` for the previous 7 days for a few accounts, (b) catch fragile adapters/oracles that revert or produce garbage at some blocks, (c) pin the resulting time series as a regression snapshot, and (d) test **changes to oracle/price-feed code** against historical chain state **without deploying anything on-chain**.

Also: CI `forge build` takes ~15 min because compilation artifacts are never cached across runs, which makes every iteration on fork tests painful.

## Key facts established during investigation

- The integration tests (`test/integration/IntegrationFromConfigBase.fork.sol`) already deploy the full NAV stack from local source on a fork at a pinned block and snapshot `getAccountNav` into `test/integration/accounts.json`. This work generalizes that from one block to a time series.
- Foundry forks pinned to a block cache every RPC response on disk (`~/.foundry/cache/rpc/<chain>/<block>`). Each `vm.rollFork(block)` target has its own cache dir. Re-runs of a pinned sweep cost zero RPC.
- CI already caches `~/.foundry/cache/rpc` via `foundry-rs/foundry-toolchain` (`cache: true`, per-job keys). Verified hitting on run 29924013050.
- CI build is slow because `cache/` + `out/` are NOT in that cache (restored cache was 69 KB); every run cold-compiles 509 files with `via_ir` → solc 888 s.
- `eth_call` state overrides (Geth-standard: inject `code`/`balance`/`state` per address at any historical block, supported by Alchemy/QuickNode/etc., also Tenderly simulate APIs) are real and viable, but deferred (see Alternatives).

## Decisions (user-confirmed)

- Goal: all three — stability backtest + NAV time-series data + regression snapshots.
- Scope v1: **mainnet only**, accounts from `accounts.json`, one **fixed 30-day window** picked once and pinned (absolute from/to timestamps, hourly cadence → 721 points inclusive). Windows are **named** and multiple windows are supported in the fixture; extending the range or adding windows later is a generator run + snapshot, not a code change. All parameters env/flag-overridable.
- Execution: **on-demand only** (no cron, not per-PR).
- CI build-speed fix: **included, as a first standalone step/PR**.
- Work happens on a new branch (`feat/nav-backtest-harness`).

## Part 1 — CI build cache (standalone first step)

1. **Migrate CI to Blacksmith runners.** Replace `runs-on: ubuntu-latest` with Blacksmith tags in all jobs of `.github/workflows/foundry.yml` and `.github/workflows/refresh-integration-snapshot.yml`. Build job gets a larger tier (e.g. `blacksmith-8vcpu-ubuntu-2404` — via_ir solc parallelizes across compilation units); other jobs `blacksmith-4vcpu-ubuntu-2404` (or 2vcpu for lint). Prereq: install the Blacksmith GitHub App on this repo (and on every repo using `blacksmith-*` labels, to avoid cross-repo runner poaching/queueing). Existing `actions/cache`-based caching (incl. foundry-toolchain's RPC cache) transparently redirects to Blacksmith's colocated cache — no key changes needed; 25 GB/repo/week vs GitHub's 10 GB total.
2. **Persist build artifacts with a Blacksmith sticky disk.** Mount `useblacksmith/stickydisk` (key `${{ github.repository }}-forge-build`) at the project `cache/` + `out/` paths in the Build job so forge's incremental compilation works across runs — no tar/upload of the multi-GB via_ir artifact dir (superior to plain `actions/cache` for this). Expected: ~15 min cold compile → ~1–3 min for typical PRs.
3. Enable `dynamic_test_linking = true` in `foundry.toml` (foundry ≥1.1) so test-only edits don't recompile `src/`.
4. Keep `build_info = true` (required by openzeppelin-foundry-upgrades validation) — do not trim outputs in v1.
5. CREATE2 library pins are a function of pinned solc/forge version, not cache warmth — caching/sticky disks are safe for pin stability.

## Part 2 — backtest harness

### Components

1. **Block-list generator** — script step (in the driver, bash + `cast`/`curl`): given a **named window with absolute `--from`/`--to` timestamps** (not relative-to-now), map every hour → block numbers via `cast find-block`. Writes `test/integration/backtest-blocks.json` (`windows.<name>.chains.<chainId> → {from, to, cadenceHours, points: [{timestamp, block}]}`). Committed, so the window is pinned and re-runs are deterministic; adding/extending windows is a generator run, not a code change.
2. **Forge backtest test** — `test/integration/NavBacktest.fork.t.sol`, reusing `IntegrationFromConfigBase`:
   - Read env: `BACKTEST_CHAIN` (default 1), `BACKTEST_BLOCKS_FILE` (unset ⇒ 2-point smoke sweep), `BACKTEST_WINDOW` (window name, default `w1-30d`). Accounts are always the chain-enabled accounts from `accounts.json` (single source of truth — no account env override in v1). Modes live in the driver script, not the forge test.
   - Create fork at the **oldest** block, deploy the full stack from local source once, `vm.makePersistent` the deployed contracts (+ `NAVRegistryLib`), then loop `vm.rollFork(block_i)` ascending, calling `getAccountNav(account, quote)` per account per block.
   - Per-point failures never abort the sweep: wrap the read in try/catch, record `ERROR:<reason>` — that IS the stability-backtest signal.
   - Emit machine-readable lines (`BACKTEST|chainId|block|timestamp|account|navOrError`) applied by the driver via jq, same pattern as the existing SNAPSHOT flow.
3. **Fixture** — `test/integration/nav-timeseries.json`: `windows.<name>.chains.<chainId> → {generatedAtCommit, accounts.<address>: [ {block, timestamp, nav|error} ]}`. Window/cadence metadata lives in `backtest-blocks.json` under the same window name (single definition). Multiple named windows coexist; assert mode checks the window it's given.
4. **Driver script** — `script/test/run-nav-backtest.sh --window <name> --mode report|snapshot|assert`: runs forge with `FOUNDRY_PROFILE=slow`, applies output to the fixture (snapshot) or diffs against it (assert), prints a report (points + reverting count per account, largest hour-over-hour jump).

### Modes

- `snapshot`: write/overwrite the fixture from the current run.
- `assert`: recompute and require exact equality with the fixture (regression mode). Deterministic because blocks are pinned and RPC responses are cached.
- `report`: compute and print without touching the fixture — used for oracle-diff runs.

### Oracle-change workflow (the "test changes without deploying" goal)

Forge fork deploys are local-only — nothing is ever broadcast. So testing a modified `Prices.sol` / custom feed against history is: edit source → `run-nav-backtest.sh --mode report` → diff against the committed fixture (or against a baseline run from `main`). First sweep pays RPC once; every subsequent sweep over the same blocks is served from the local RPC cache, so iterating on oracle code is fast and free.

### Error handling

- The Merkl rewards adapter was removed from the repo (pending rewrite, per CLAUDE.md) — no Merkl-specific handling needed; if it returns, its historical-root-mismatch-reads-0 behavior becomes a documented caveat.
- Adapters/pools/feeds that didn't exist at older blocks within the window: the try/catch per point records them; the report flags any account whose NAV reverts at the oldest blocks.
- RPC failures: forge retries; the driver exits non-zero if any point is missing (distinct from an on-chain revert, which is recorded data).

### Testing the harness itself

- A tiny smoke configuration (2 blocks, all enabled accounts — same account-loading path as the full sweep) runs as part of the normal fork-test suite so the harness can't rot; the full 721-point pinned-window sweep stays on-demand.

## Alternatives considered

- **A. Plain `eth_call` at historical blocks against the live deployment** — cheapest (1 RPC/point, no forge), but only tests the deployed code, not working-tree changes. Doesn't meet the oracle-change goal. May be added later as a trivial script for production monitoring.
- **B. Stateless "lens" contract injected via `eth_call` code override** — 1 RPC/point at any block with any code version, no storage reproduction needed (config passed as calldata). Powerful for long windows (months), but bypasses the real deploy/registry path and requires a new contract. Deferred; documented here as the escalation path if fork sweeps become too slow.
- **C. Foundry fork + deploy once + `rollFork` (chosen)** — exercises the real deployment path end-to-end, reuses the existing integration harness and fixtures, zero new on-chain surface, RPC-cache-friendly.

## Out of scope (v1)

- Chains other than mainnet (structure is per-chain-ready; adding a chain = block list + env var).
- Cron / per-PR execution.
- Tenderly integration.
- Debank cross-checking of historical points.
