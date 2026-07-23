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
- Scope v1: **mainnet only**, one fixed **24-hour window** named `w1-1d`, ending at the integration pin and defined in blocks: `{fromBlock, toBlock, blockStep, metrics, accounts}`. Mainnet ~12s blocks ⇒ hourly step 300; 24 hours = 7,200 blocks → 25 inclusive points. The explicit account allowlist contains the first two mainnet-enabled accounts from `accounts.json`; the harness validates that each remains present and enabled there. No timestamp→block mapping.
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

1. **Window definition** — block-based, no timestamp→block mapping: a named window is `{fromBlock, toBlock, blockStep, metrics?, accounts}`. `accounts` is a required explicit address allowlist validated against chain-enabled entries in `accounts.json`; the inherited 2-point smoke path has no window config and still exercises every enabled account. `w1-1d` spans blocks `25419715..25426915`, step 300, 25 inclusive points, metrics `["nav"]`, first two mainnet accounts.
2. **Forge backtest test** — `test/integration/NavBacktest.fork.t.sol`, reusing `IntegrationFromConfigBase`:
   - Read env: `BACKTEST_CHAIN` (default 1), `BACKTEST_BLOCKS_FILE` (unset ⇒ 2-point all-account smoke sweep), `BACKTEST_WINDOW` (window name, default `w1-1d`). Named windows require an explicit account subset, and every selected address must exist and be enabled for the chain in `accounts.json`.
   - Compute the block list from `{fromBlock, toBlock, blockStep}` in-test. Create fork at **fromBlock**, deploy the full stack from local source once, `vm.makePersistent` the deployed contracts, then loop `vm.rollFork(block_i)` ascending, evaluating each configured **metric** per account per block.
   - **Metric registry:** metrics are named view probes `(account) → string` implemented in the test; v1 ships only `"nav"` (`getAccountNav(account, QUOTE_USD).value`). Which metrics run is selected by the window's `metrics` config, not code — snapshotting a new function later = implement one probe + list its name in JSON. Unknown metric names revert setUp (fail fast).
   - Per-point failures never abort the sweep: wrap the read in try/catch, record `ERROR:<reason>` — that IS the stability-backtest signal.
   - Emit machine-readable lines (`BACKTEST|chainId|block|timestamp|account|metric|valueOrError`) where `timestamp` is the fork's `block.timestamp` at that point (free, human-readable time without any timestamp→block mapping); applied by the driver, same pattern as the existing SNAPSHOT flow.
3. **Fixture** — `test/integration/nav-timeseries.json`: `windows.<name>.chains.<chainId> → {generatedAtCommit, accounts.<address>.<metric>: [ {block, timestamp, value|error} ]}`. Adding a metric extends the fixture without invalidating existing series; assert compares metric-by-metric. Window/step/metrics metadata lives in `backtest-blocks.json` under the same window name (single definition). Multiple named windows coexist; assert mode checks the window it's given.
4. **Driver script** — single-file Bun TypeScript, `script/test/nav-backtest.ts` (`bun script/test/nav-backtest.ts --window <name> --mode report|snapshot|assert`): runs forge with `FOUNDRY_PROFILE=slow`, parses BACKTEST lines with typed schemas (no jq), applies output to the fixture (snapshot) or deep-diffs against it (assert), prints a report (points + reverting count per account×metric, largest step-over-step jump). Bun is the only new toolchain dependency; the script is dependency-free (no package.json) and only needed for on-demand runs.

### Modes

- `snapshot`: write/overwrite the fixture from the current run.
- `assert`: recompute and require exact equality with the fixture (regression mode). Deterministic because blocks are pinned and RPC responses are cached.
- `report`: compute and print without touching the fixture — used for oracle-diff runs.

### Oracle-change workflow (the "test changes without deploying" goal)

Forge fork deploys are local-only — nothing is ever broadcast. So testing a modified `Prices.sol` / custom feed against history is: edit source → `bun script/test/nav-backtest.ts --mode report` → diff against the committed fixture (or against a baseline run from `main`). First sweep pays RPC once; every subsequent sweep over the same blocks is served from the local RPC cache, so iterating on oracle code is fast and free.

### Error handling

- The Merkl rewards adapter was removed from the repo (pending rewrite, per CLAUDE.md) — no Merkl-specific handling needed; if it returns, its historical-root-mismatch-reads-0 behavior becomes a documented caveat.
- Adapters/pools/feeds that didn't exist at older blocks within the window: the try/catch per point records them; the report flags any account whose NAV reverts at the oldest blocks.
- RPC failures: forge retries; the driver exits non-zero if any point is missing (distinct from an on-chain revert, which is recorded data).

### Testing the harness itself

- A tiny smoke configuration (2 blocks, all enabled accounts) runs as part of the normal fork-test suite so the harness cannot rot; the pinned 25-point/two-account window stays on-demand.

## Alternatives considered

- **A. Plain `eth_call` at historical blocks against the live deployment** — cheapest (1 RPC/point, no forge), but only tests the deployed code, not working-tree changes. Doesn't meet the oracle-change goal. May be added later as a trivial script for production monitoring.
- **B. Stateless "lens" contract injected via `eth_call` code override** — 1 RPC/point at any block with any code version, no storage reproduction needed (config passed as calldata). Powerful for long windows (months), but bypasses the real deploy/registry path and requires a new contract. Deferred; documented here as the escalation path if fork sweeps become too slow.
- **C. Foundry fork + deploy once + `rollFork` (chosen)** — exercises the real deployment path end-to-end, reuses the existing integration harness and fixtures, zero new on-chain surface, RPC-cache-friendly.

## Out of scope (v1)

- Chains other than mainnet (structure is per-chain-ready; adding a chain = block list + env var).
- Cron / per-PR execution.
- Tenderly integration.
- Debank cross-checking of historical points.
