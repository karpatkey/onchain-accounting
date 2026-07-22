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
- Scope v1: **mainnet only**, accounts from `accounts.json`, **7-day window, hourly cadence** (168 points), all overridable via env vars.
- Execution: **on-demand only** (no cron, not per-PR).
- CI build-speed fix: **included, as a first standalone step/PR**.
- Work happens on a new branch (`feat/nav-backtest-harness`).

## Part 1 — CI build cache (standalone first step)

1. Add an `actions/cache` step for the project `cache/` + `out/` dirs in the Build job of `.github/workflows/foundry.yml`, keyed on `foundry.toml` hash + `FOUNDRY_VERSION` + source tree hash, with restore-key prefix fallback so PRs restore the most recent main build and recompile only the dirty subgraph. Expected: ~15 min → ~1–3 min for typical PRs.
2. Enable `dynamic_test_linking = true` in `foundry.toml` (foundry ≥1.1) so test-only edits don't recompile `src/`.
3. Keep `build_info = true` (required by openzeppelin-foundry-upgrades validation) — do not trim outputs in v1.
4. CREATE2 library pins are a function of pinned solc/forge version, not cache warmth — caching is safe for pin stability.

## Part 2 — backtest harness

### Components

1. **Block-list generator** — script step (in the driver, bash + `cast`/`curl`): map "every hour over the window" → block numbers via binary search on `eth_getBlockByNumber` timestamps. Writes `test/integration/backtest-blocks.json` (chainId → `[ {timestamp, block} ]`). Cached/committed so re-runs are deterministic.
2. **Forge backtest test** — `test/integration/NavBacktest.fork.t.sol`, reusing `IntegrationFromConfigBase`:
   - Read env: `BACKTEST_CHAIN` (default 1), `BACKTEST_BLOCKS_FILE`, `BACKTEST_ACCOUNTS` (default: enabled accounts from `accounts.json`), `BACKTEST_MODE` (`snapshot` | `assert` | `report`).
   - Create fork at the **oldest** block, deploy the full stack from local source once, `vm.makePersistent` the deployed contracts (+ `NAVRegistryLib`), then loop `vm.rollFork(block_i)` ascending, calling `getAccountNav(account, quote)` per account per block.
   - Per-point failures never abort the sweep: wrap the read in try/catch, record `REVERT:<reason>` — that IS the stability-backtest signal.
   - Emit machine-readable lines (`BACKTEST|chainId|block|timestamp|account|navOrError`) applied by the driver via jq, same pattern as the existing SNAPSHOT flow.
3. **Fixture** — `test/integration/nav-timeseries.json`: chainId → account → `[ {block, timestamp, nav|error} ]`, plus metadata (window, cadence, generation commit).
4. **Driver script** — `script/test/run-nav-backtest.sh`: generates/refreshes block list, runs forge with `FOUNDRY_PROFILE=slow`, applies output to the fixture (snapshot mode) or diffs against it (assert mode), prints a human-readable report (min/max/points, reverting blocks, largest hour-over-hour jumps).

### Modes

- `snapshot`: write/overwrite the fixture from the current run.
- `assert`: recompute and require exact equality with the fixture (regression mode). Deterministic because blocks are pinned and RPC responses are cached.
- `report`: compute and print without touching the fixture — used for oracle-diff runs.

### Oracle-change workflow (the "test changes without deploying" goal)

Forge fork deploys are local-only — nothing is ever broadcast. So testing a modified `Prices.sol` / custom feed against history is: edit source → `run-nav-backtest.sh --mode report` → diff against the committed fixture (or against a baseline run from `main`). First sweep pays RPC once; every subsequent sweep over the same blocks is served from the local RPC cache, so iterating on oracle code is fast and free.

### Error handling

- Merkl rewards at historical blocks where the fixture root doesn't match read as 0 (existing documented behavior) — noted in the report, not an error.
- Adapters/pools/feeds that didn't exist at older blocks within the window: the try/catch per point records them; the report flags any account whose NAV reverts at the oldest blocks.
- RPC failures: forge retries; the driver exits non-zero if any point is missing (distinct from an on-chain revert, which is recorded data).

### Testing the harness itself

- A tiny smoke configuration (2 blocks, 1 account) runs as part of the normal fork-test suite so the harness can't rot; the full 168-point sweep stays on-demand.

## Alternatives considered

- **A. Plain `eth_call` at historical blocks against the live deployment** — cheapest (1 RPC/point, no forge), but only tests the deployed code, not working-tree changes. Doesn't meet the oracle-change goal. May be added later as a trivial script for production monitoring.
- **B. Stateless "lens" contract injected via `eth_call` code override** — 1 RPC/point at any block with any code version, no storage reproduction needed (config passed as calldata). Powerful for long windows (months), but bypasses the real deploy/registry path and requires a new contract. Deferred; documented here as the escalation path if fork sweeps become too slow.
- **C. Foundry fork + deploy once + `rollFork` (chosen)** — exercises the real deployment path end-to-end, reuses the existing integration harness and fixtures, zero new on-chain surface, RPC-cache-friendly.

## Out of scope (v1)

- Chains other than mainnet (structure is per-chain-ready; adding a chain = block list + env var).
- Cron / per-PR execution.
- Tenderly integration.
- Debank cross-checking of historical points.
