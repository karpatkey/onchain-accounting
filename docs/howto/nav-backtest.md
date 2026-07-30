# How to run the NAV historical backtest harness

The backtest harness re-evaluates NAV (and any other registered metric) for a fixed set of accounts across a pinned block range, so you can spot drift after an adapter / feed change, validate a refactor against a known-stable history, or write a regression test that pins a specific past window. It is **not** the live integration test (which is JSON-driven and asserts against a single fork block); it sweeps many blocks and emits a per-point time series.

A single command runs the sweep, parses the per-block output, and either prints a report, snapshots the fixture, or asserts the sweep matches the fixture.

---

## What it does

`script/test/nav-backtest.ts` (a single-file Bun script with no external deps) shells out to a Foundry test (`test/integration/NavBacktest.fork.t.sol`) that:

1. Loads the configured window from `test/integration/backtest-blocks.json` (block range, step, metrics, account allowlist).
2. Deploys the full NAV stack from local source at the window's `fromBlock`.
3. For each block in the range (inclusive of `toBlock`, at `blockStep` intervals), `vm.rollFork`s forward and emits a `BACKTEST|<chain>|<block>|<timestamp>|<account>|<metric>|<value>` line for every (account × metric).
4. Per-point reverts are caught and recorded as `ERROR:<kind>:<detail>` — `revert:<sanitised string>`, `panic:<code>`, `custom:<4-byte selector>`, or `empty:0` (no returndata, typically out-of-gas). They are the stability signal, not fatal. Three conditions *are* fatal, because they mean the harness rather than the protocol is broken: a stack address that lost its code across a roll (`BacktestStackNotPersistent`), an exhausted sweep gas budget (`BacktestGasBudgetExhausted`), and a sweep in which every single point reverted (`BacktestAllPointsFailed`).

The driver collects those lines into a `Series` (chain → window → accounts → metrics → points), runs completeness checks (every account produced all expected points, no missing/extra accounts), prints a per-(account × metric) report with the worst step-to-step percentage jump, then dispatches by mode.

A point's `value` is the metric's stringified output. For the `nav` metric it is the raw `uint256` value as returned by `NAVCalculator.getAccountNav` in NAV's 8-decimal USD fixed-point precision (the same kind of value the live integration test asserts on). There is no scaling or sign flipping; you compare strings.

---

## Prerequisites

- **Bun** (any recent 1.x). The driver is a single-file script, no `package.json` install step.
- **`forge`** on PATH (Foundry).
- **`ALCHEMY_API_KEY`** in the environment, the **only** required RPC credential for mainnet.

The fork RPC URL is resolved by `TestEnvConfigurator.getAlchemyUrl(network)` (see `test/TestEnvConfigurator.sol`). The chain config in `test/integration/accounts.json` selects the Alchemy network slug per chain (mainnet → `eth-mainnet`), and `getAlchemyUrl` builds `https://<network>.g.alchemy.com/v2/<ALCHEMY_API_KEY>`. To override, set the chain-specific env var instead: `MAINNET_URL`, `ARBITRUM_URL`, `BASE_URL`, `OP_URL`, `GNOSIS_URL`, `BSC_URL`. If neither is set, the test reverts with `RpcUrlNotSet`.

`BACKTEST_BLOCKS_FILE` and `BACKTEST_WINDOW` are read by the Solidity test, not the driver. The driver sets them in the `forge` subprocess env automatically (see "Internal env" below). You do not need to export them yourself.

---

## Quickstart

All commands assume the repo root. The window `w1-1d` is the only one shipped today (mainnet, blocks 25419715..25426915, step 300, two accounts, metric `nav`).

```bash
# Report: run the sweep, print per-(account × metric) summary, do not touch the fixture
bun script/test/nav-backtest.ts --mode report

# Snapshot: run the sweep and (over)write the w1-1d / chain 1 entry in
# test/integration/nav-timeseries.json. Records generatedAtCommit from `git rev-parse --short HEAD`.
bun script/test/nav-backtest.ts --mode snapshot

# Assert: run the sweep and deep-diff against the fixture. Exit 1 on any difference
# (exit 2 on bad CLI / missing fixture). Use in CI to lock a window to a known-good baseline.
bun script/test/nav-backtest.ts --mode assert
```

By default the chain is `1` (mainnet) and the window is `w1-1d`. Override with `--chain <id>` and `--window <name>`. Unknown modes fail with exit code 2; missing or unparseable windows/blocks file also fail with 2.

### Internal env

The driver runs `forge` with these env vars set (you do not need to export them):

- `BACKTEST_CHAIN=<--chain>` (default `1`)
- `BACKTEST_BLOCKS_FILE=test/integration/backtest-blocks.json`
- `BACKTEST_WINDOW=<--window>` (default `w1-1d`)
- `FOUNDRY_PROFILE=slow` (RPC throttling, see Caveats)

To run the Solidity test directly without the driver, set them yourself:

```bash
FOUNDRY_PROFILE=slow BACKTEST_CHAIN=1 \
  BACKTEST_BLOCKS_FILE=test/integration/backtest-blocks.json \
  BACKTEST_WINDOW=w1-1d \
  forge test --match-contract NavBacktest --match-test test_backtestSweep -vv
```

---

## Workflow: refreshing the fixture after an oracle / adapter change

When you change anything that affects NAV output (a price feed, a balance adapter, a new asset registration, a math refactor, etc.), the pinned `w1-1d` window will go stale and `--mode assert` will fail. Refresh it:

1. Run the sweep in `report` mode and eyeball the worst step jumps and per-account error counts:
   ```bash
   bun script/test/nav-backtest.ts --mode report
   ```
   Large jumps or new `reverting` counts on a previously-clean window are a flag to investigate before snapshotting.
2. When you're confident the new output is correct (compare against a manual NAV spot-check, a Debank cross-check, or the live integration test for the window's `fromBlock`), overwrite the fixture:
   ```bash
   bun script/test/nav-backtest.ts --mode snapshot
   ```
   The driver's `generatedAtCommit` becomes the current `git rev-parse --short HEAD`. Commit `test/integration/nav-timeseries.json` alongside the code change so reviewers can see both the diff and the resulting numbers.
3. Re-run `assert` to confirm the fixture is reproducible:
   ```bash
   bun script/test/nav-backtest.ts --mode assert
   ```
   The fixture is a record of what the harness produced; it is not auto-checked on every CI run. Wire `assert` into your local pre-merge check or a dedicated workflow if you want CI to catch unintended drift.

The fixture is a normal JSON file. The driver sorts keys before comparing in `assert` mode, so a key-order-only diff won't fail.

---

## Modes and exit codes

| Mode | What it does | Exit codes |
|---|---|---|
| `report` (default) | Run the sweep and print a per-(account × metric) summary. | `0` on success (even if some points reverted; the report shows the count). `1` if completeness checks fail (missing accounts, missing points, extra accounts). `2` on bad CLI / missing blocks file / no `BACKTEST` lines. |
| `snapshot` | Run the sweep, then (over)write the window's entry in `test/integration/nav-timeseries.json`. | `0` on success. `1` if completeness checks fail, or if any point reverted and `--allow-errors` was not passed (you can't snapshot a partial or all-error sweep). `2` on bad CLI / missing blocks file / a fixture that exists but does not parse. |
| `assert` | Run the sweep and deep-diff against the fixture. Prints the reverting-point count even when it matches. | `0` if the sweep matches the fixture. `1` on any difference (up to 30 diff lines printed). `2` if the fixture is missing or has no entry for the requested window/chain. |

`snapshot` refuses by default to pin a sweep containing reverting points, because an all-error sweep is what a *broken* harness looks like (dead RPC, pruned archive block, a stack address that lost its code) and pinning it yields a baseline that `assert` matches forever while measuring nothing. Pass `--allow-errors` when the reverts are genuinely the signal you want pinned. A fixture file that exists but does not parse is a hard error, never silently reinitialised — reinitialising would drop every other window's baseline, each of which can cost hours of archive RPC.

In all modes, a failing sweep is fatal: the driver exits with `2` and prints the last 50 lines of forge output. It treats both a non-zero forge exit (RPC error, compile failure) **and** a `[FAIL`/`Suite result: FAILED` line in the output as a failure, because `forge test` can exit `0` with a failing test.

---

## File map

| File | Role |
|---|---|
| `script/test/nav-backtest.ts` | Bun driver. Parses CLI, runs the Solidity test, parses `BACKTEST\|…` lines, dispatches by mode. Single file, zero npm dependencies. |
| `test/integration/NavBacktest.fork.t.sol` | Foundry test. Loads the window, deploys NAV from source at `fromBlock`, `vm.rollFork`s forward, emits `BACKTEST\|…` lines. Reverts caught and recorded. |
| `test/integration/backtest-blocks.json` | Window definitions. `windows.<name>.chains.<chainId>` = `{ fromBlock, toBlock, blockStep, metrics, accounts }`. One window today: `w1-1d`. |
| `test/integration/nav-timeseries.json` | Fixture. `windows.<name>.chains.<chainId>` = `{ generatedAtCommit, accounts: { <addr>: { <metric>: Point[] } } }`. One entry today: `w1-1d` / chain `1` (50 points = 25 points/account × 2 accounts, 8,469 bytes). |
| `test/integration/IntegrationFromConfigBase.fork.sol` | Inherited base: chain config loader, `createSelectForkWithCadence(getAlchemyUrl(network), forkBlock)`. |
| `test/TestEnvConfigurator.sol` | `getAlchemyUrl` builds the URL from `ALCHEMY_API_KEY` as `https://<network>.g.alchemy.com/v2/<key>`, with chain-specific env var overrides. |

### Fixture schema (one account, one point)

`test/integration/nav-timeseries.json` is keyed by `windows.<name>.chains.<chainId>`, holding the commit that produced the entry and an `accounts` map. Each account has per-metric `Point[]`. A `Point` is either a successful value (`block`, `timestamp`, `value`) or a recorded revert (`block`, `timestamp`, `error`). The structural shape of a one-account, one-point entry:

```json
{
  "0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6": {
    "nav": [
      { "block": 25419715, "timestamp": 1782692615, "value": "21787867163" }
    ]
  }
}
```

The full fixture path is `test/integration/nav-timeseries.json`; the example above is structurally copied from the `w1-1d` / chain `1` entry. The shipped fixture has 50 points total (25 blocks × 2 accounts), all `value` form (no `error` points; the shipped window is clean).

`accounts.json` in the same directory is unrelated; it is the live integration test's account/forkBlock source.

---

## Caveats and performance

- **`rollFork` advances the same active fork; remote reads at the new block are cold.** `vm.rollFork(block)` re-targets the currently selected fork to a different block; the same persistent state is the active fork across the sweep. Foundry (this repo is pinned to forge 1.7.1) internally allocates a fresh per-block remote cache on each roll, so the local deploy of the NAV stack is merged in once at `fromBlock` and reused, but every historical contract read at the new block (balances, prices, slot pre-images) is fetched fresh from the RPC. There is no shared block-keyed remote cache between steps. The `FOUNDRY_PROFILE=slow` profile pins `threads = 1` (per-block sequential evaluation, no intra-sweep parallelism) and the driver uses `createSelectForkWithCadence` only for the initial fork selection; per-roll RPC throttling is up to Alchemy's rate limiter and the slot of the run, not the test harness. Cold historical reads dominate wall time. Expect the full `w1-1d` window to take a few minutes on a warm local state, considerably longer cold.
- **Canonical / slow mode is the only mode.** There is no "fast" / mocked / pre-recorded sweep. The whole point of the harness is to read live mainnet state at each pinned block. If you want a near-instant sanity check, use the lite smoke mode (below).
- **Lite smoke is a no-op for the canonical window.** When `BACKTEST_BLOCKS_FILE` is unset (or empty), `NavBacktest` runs a **2-point smoke sweep** at the chain's `accounts.json` forkBlock and `forkBlock - 300`. It evaluates every chain-enabled account (no per-window allowlist); on mainnet that is 9 accounts × 1 metric × 2 points = 18 emitted rows. The point is cheap CI coverage of the harness plumbing; it gives no speedup over a small canonical window and produces no fixture data. Run it directly with `forge test --match-contract NavBacktest` (no env vars); the driver always sets `BACKTEST_BLOCKS_FILE` and uses the canonical window.
- **Fixture size scales with `accounts × metrics × ((toBlock - fromBlock) / blockStep + 1)`.** The shipped `w1-1d` window is 25 points/account × 2 accounts = 50 points total (8,469 bytes on disk). Keep the step coarse for long windows; the metric is meant to spot drift, not to be a tick-level feed.
- **Stale oracle responses look like real data.** A stale or feedless asset is priced at `0` and summed as a zero-value leg (`src/prices/PriceFeedLib.sol`), so a feed breaching its heartbeat mid-window shows up as an ordinary NAV drop — `report` will print it as a large "max step jump" — with nothing in the `nav` metric marking it as an oracle event. Add the `nav-stale-assets` metric to a window's `metrics` to record `NAV.stalePriceAssets.length` alongside the value, and cross-check any unexpected step against the live integration test or Debank before snapshotting. The shipped `w1-1d` window pins `nav` only (adding a metric to it would require re-snapshotting the whole window).
- **A window must not predate its own dependencies.** The stack is deployed once at `fromBlock` with *today's* configured assets, feeds and adapters. Any configured dependency that had no code at `fromBlock` — e.g. the custom price feeds redeployed on 2026-07-25/27, or a newly governed meta-instance — reverts or reads garbage until the block where it appeared, which the harness records as a revert or a step jump rather than a configuration problem. Choose `fromBlock` at or after the deploy block of every configured dependency.
- **The sweep is one transaction, so gas caps the window.** A point costs ~25-31M gas (25.5M average in CI, 31.1M worst observed locally), so `[profile.slow]`'s `gas_limit` allows roughly 550-670 of them (less in practice: memory is never freed and expansion cost is quadratic). The harness now stops with `BacktestGasBudgetExhausted` while headroom remains rather than letting an out-of-gas revert be caught and recorded as an ordinary `ERROR:` point — which would cluster fabricated errors at the end of a long sweep and read exactly like the protocol destabilising. Shorten the window (coarser `blockStep`, fewer accounts/metrics) if you hit it.

---

## Extending the harness

### Adding a new window

Edit `test/integration/backtest-blocks.json`. Pick a name (kebab-case, prefixed with the chain: `w1-1d`, `w42161-7d`, …). Under `windows.<name>.chains.<chainId>` set `fromBlock`, `toBlock`, `blockStep`, `metrics`, and `accounts`. Constraints enforced by the driver:

- `toBlock > fromBlock`, `blockStep > 0`, `metrics` is a non-empty string array if present, and `accounts` is a non-empty array of unique hex addresses.
- `fromBlock` must be non-zero (`0` is the base class's "fork block unset" sentinel), `toBlock > fromBlock`, `blockStep > 0`, `metrics` a non-empty string array if present, and `accounts` a non-empty array of unique hex addresses. The driver validates only the window it is about to run, so an unrelated malformed window cannot break other invocations.
- Every configured address must be chain-enabled in `accounts.json`; the Solidity test reverts with `BacktestConfiguredAccountUnavailable(account, chainId)` — naming the offending address — and with `BacktestDuplicateConfiguredAccount(account)` on a repeated entry. Direct Forge smoke mode remains the only all-enabled-account path; a window with no `accounts` key works under Forge but is rejected by the driver, which needs the expected set for its completeness check.

Then snapshot:

```bash
bun script/test/nav-backtest.ts --window <name> --chain <id> --mode snapshot
```

### Adding or changing accounts within a window

`backtest-blocks.json` only allows **subsetting** the chain-enabled set; the account universe is `accounts.json`. To add a new account, edit `test/integration/accounts.json` first, then list the new address in the window's `accounts` array. To remove an account from a window, drop it from the window's `accounts` (the live integration test will still cover it via `accounts.json`). See [`refresh-integration-test-blocks.md`](refresh-integration-test-blocks.md) for the full account JSON workflow.

### Adding a new metric

Two metrics ship today: `nav` (the raw `uint256` NAV value) and `nav-stale-assets` (`NAV.stalePriceAssets.length`, so a value drop caused by a stale feed is distinguishable from a real one). The metric registry lives in `NavBacktest.fork.t.sol`. To expose a new probe:

1. Add a `METRIC_<NAME>` constant: `bytes32 internal constant METRIC_<NAME> = keccak256("<name>");`.
2. Branch in `_evalMetric` (and add the hash to `_isKnownMetric` so unknown names fail fast in `setUp`).
3. List the name in the window's `metrics` array.

Nothing else changes: the driver picks it up automatically from the window config, the fixture stores it under `accounts.<addr>.<name>`, and `assert` deep-diffs it.

### Running on another chain

Set `BACKTEST_CHAIN` (driver: `--chain <id>`) to any chain registered in `test/integration/accounts.json` (Arbitrum, Base, Optimism, Gnosis today). The driver forwards the chain id to the test, which reads `chains.<id>.alchemyNetwork` and `chains.<id>.forkBlock` from `accounts.json`. The fixture will be written under `windows.<name>.chains.<id>`, keyed independently of the mainnet entry. RPC resolution: `ALCHEMY_API_KEY` works for all supported chains, or set the chain-specific env var (`ARBITRUM_URL`, `BASE_URL`, `OP_URL`, `GNOSIS_URL`) for a custom endpoint.

---

## Lint

The driver is plain TypeScript; it has no project-level lint config. The two linters we use elsewhere run cleanly on it:

```bash
bunx @biomejs/biome@2.2.4 lint script/test/nav-backtest.ts
bunx fallow@3.8.0 dead-code --format compact
```

`fallow` is the project-wide dead-code scan. It will flag any unused export in the driver; the script has no exports, so a clean run is expected.
