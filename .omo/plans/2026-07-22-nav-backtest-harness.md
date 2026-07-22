# NAV Backtest Harness + Blacksmith CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate CI to Blacksmith runners with a persistent forge build cache, then build an on-demand historical NAV backtest harness (hourly `getAccountNav` sweeps over a named, pinned 30-day block window, with snapshot/assert/report modes) so oracle/adapter changes can be tested against a fixed slice of chain history without any on-chain deployment.

**Architecture:** Part 1 swaps `runs-on` labels to Blacksmith tags and mounts a sticky disk over forge's `cache/` + `out/` so incremental compilation survives across CI runs. Part 2 reuses the existing `IntegrationFromConfigBase` fork harness: deploy the full NAV stack from local source once at the oldest block of a **named pinned window** (absolute from/to timestamps, hourly points), `vm.makePersistent` the stack, then `vm.rollFork` forward point-by-point emitting `BACKTEST|...` lines that a driver script turns into a committed per-window JSON fixture (snapshot), a regression check (assert), or a report. Multiple windows can coexist; adding/extending one is a generator run, not a code change.

**Tech Stack:** GitHub Actions + Blacksmith, Foundry (forge/cast, `slow` profile), bash + jq, Solidity ^0.8.

**Spec:** `.omo/specs/2026-07-22-nav-backtest-harness-design.md`

## Global Constraints

- Foundry version is pinned to `v1.7.1` in CI (`FOUNDRY_VERSION` env in `.github/workflows/foundry.yml`); do not change it.
- `via_ir = true`, `solc_version = "0.8.34"`, `evm_version = "cancun"` in `foundry.toml` must not change (CREATE2 library pins depend on them).
- Keep `build_info = true`, `ast = true`, `extra_output = ["storageLayout"]` in `foundry.toml` (openzeppelin-foundry-upgrades needs build_info).
- New Solidity files use `pragma solidity ^0.8;`.
- NAV casing: type-level names use `NAV`/`Backtest...`; mixedCase identifiers use `Nav` (e.g. `getAccountNav`).
- Fork tests run under `FOUNDRY_PROFILE=slow` (threads=1, 16 GiB gas/memory limits — the integration harness needs it).
- Backtest defaults (user-approved): chain 1 (mainnet), accounts from `test/integration/accounts.json`, one **fixed pinned 30-day window** named `w1-30d` (absolute from/to, hourly cadence → 721 points inclusive), on-demand only (no cron, no per-PR full sweep). More/longer windows may be added later as new named windows.
- The Blacksmith GitHub App must be installed on this repo before CI runs on `blacksmith-*` labels (manual prerequisite; jobs queue otherwise).
- `forge build` and `forge test` (unit) must pass before every push.

---

### Task 1: Blacksmith runner migration

**Files:**
- Modify: `.github/workflows/foundry.yml:27,54,76,100,123` (the five `runs-on: ubuntu-latest` lines)
- Modify: `.github/workflows/refresh-integration-snapshot.yml:35`

**Interfaces:**
- Produces: CI jobs running on Blacksmith runners; existing `foundry-toolchain` `cache: true` RPC caching transparently redirects to Blacksmith's colocated cache (no key changes).

- [ ] **Step 1: Swap runs-on labels in foundry.yml**

Replace each `runs-on: ubuntu-latest` with the tier for that job:

| Job (line) | New value |
|---|---|
| `build` (27) | `runs-on: blacksmith-8vcpu-ubuntu-2404` |
| `unit` (54) | `runs-on: blacksmith-4vcpu-ubuntu-2404` |
| `fork` (76) | `runs-on: blacksmith-4vcpu-ubuntu-2404` |
| `integration` (100) | `runs-on: blacksmith-4vcpu-ubuntu-2404` |
| `lint` (123) | `runs-on: blacksmith-2vcpu-ubuntu-2404` |

Rationale: via_ir solc parallelizes across compilation units → 8vcpu for build; fork/integration are RPC-bound with `--threads 1` → 4vcpu; fmt check → 2vcpu.

- [ ] **Step 2: Swap runs-on in refresh-integration-snapshot.yml**

Line 35: `runs-on: ubuntu-latest` → `runs-on: blacksmith-4vcpu-ubuntu-2404`.

- [ ] **Step 3: Validate workflow syntax**

Run: `actionlint .github/workflows/foundry.yml .github/workflows/refresh-integration-snapshot.yml` (if actionlint is unavailable: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" .github/workflows/foundry.yml .github/workflows/refresh-integration-snapshot.yml`)
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/foundry.yml .github/workflows/refresh-integration-snapshot.yml
git commit -m "ci: migrate runners to Blacksmith"
```

- [ ] **Step 5: Verify on CI (after push, requires Blacksmith app installed)**

Run: `git push -u origin feat/nav-backtest-harness` then `gh run watch` on the triggered run.
Expected: all jobs picked up by Blacksmith runners (job logs show `blacksmith-*` runner names), all jobs green. If jobs queue >5 min, the Blacksmith GitHub App is not installed — stop and report to the user.

---

### Task 2: Sticky-disk forge build cache

**Files:**
- Modify: `.github/workflows/foundry.yml` (Build job steps, currently lines ~28–48)

**Interfaces:**
- Consumes: Blacksmith runners from Task 1 (sticky disks only work on Blacksmith).
- Produces: persistent `cache/` + `out/` across Build-job runs → forge incremental compilation on CI.

- [ ] **Step 1: Add stickydisk mounts to the Build job**

In the `build` job of `.github/workflows/foundry.yml`, insert immediately **after** the `actions/checkout` step and **before** `foundry-rs/foundry-toolchain` (checkout would wipe the workdir if mounted paths lived inside files checkout touches — `cache/` and `out/` are gitignored, but mounting after checkout is the documented-safe order):

```yaml
      - name: Mount forge compilation cache
        uses: useblacksmith/stickydisk@v1
        with:
          key: ${{ github.repository }}-forge-cache
          path: ./cache

      - name: Mount forge build output
        uses: useblacksmith/stickydisk@v1
        with:
          key: ${{ github.repository }}-forge-out
          path: ./out
```

Leave the existing `Upload build artifacts` step unchanged — downstream jobs in the same run still consume `out/` + `cache/` via artifacts.

- [ ] **Step 2: Validate workflow syntax**

Run: same validation command as Task 1 Step 3.
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/foundry.yml
git commit -m "ci: persist forge cache/ and out/ across runs via Blacksmith sticky disks"
```

- [ ] **Step 4: Verify on CI**

Push; let the first run complete (cold — still ~15 min compile, it seeds the disk). Trigger a second run (`git commit --allow-empty -m "ci: warm-cache probe" && git push`).
Expected: second run's Build step log shows forge compiling only changed files (`No files changed, compilation skipped` or a small file count), Build job wall time ≤ ~4 min. Then drop the probe commit: `git reset --hard HEAD~1 && git push --force-with-lease` (probe commit only — verify `git log -1` first).

---

### Task 3: Enable dynamic test linking

**Files:**
- Modify: `foundry.toml` (in `[profile.default]`, after the `via_ir = true` line ~line 17)

**Interfaces:**
- Produces: test-only edits no longer recompile `src/` locally or on CI.

- [ ] **Step 1: Add the flag**

In `[profile.default]` add:

```toml
# Test-only edits don't recompile src/ (foundry >=1.1). Tests are linked
# dynamically; src bytecode (and therefore CREATE2 library pins) is unaffected.
dynamic_test_linking = true
```

- [ ] **Step 2: Verify pins are unaffected and build works**

Run: `forge build && forge test --no-match-path "*fork*" --match-path "test/LibraryPinConsistency.t.sol" -vv`
Expected: build succeeds; `LibraryPinConsistency` passes (proves library bytecode/pins unchanged).

- [ ] **Step 3: Verify incremental behavior**

Foundry hashes content, so `touch` alone won't trigger a rebuild — make a real edit and revert it:

```bash
printf '\n// recompile probe\n' >> test/Constants.t.sol
forge build 2>&1 | tail -3
git checkout -- test/Constants.t.sol
```

Expected: the build output shows a small "Compiling N files" count (only the edited test's compilation unit, not 509).

- [ ] **Step 4: Commit**

```bash
git add foundry.toml
git commit -m "build: enable dynamic_test_linking for faster test-only rebuilds"
```

---

### Task 4: Hourly block-list generator

**Files:**
- Create: `script/test/generate-backtest-blocks.sh`
- Create (generated, committed): `test/integration/backtest-blocks.json`

**Interfaces:**
- Consumes: `test/integration/accounts.json` (`.chains.<id>.alchemyNetwork` for RPC resolution), env `ALCHEMY_API_KEY` or `MAINNET_URL` (same resolution order as `refresh-integration-snapshot.sh`).
- Produces: `test/integration/backtest-blocks.json` with schema (named, pinned windows with **absolute** from/to — never relative to now):

```json
{
  "$comment": "Generated by script/test/generate-backtest-blocks.sh. Named pinned windows of hourly blocks for the NAV backtest.",
  "windows": {
    "w1-30d": {
      "chains": {
        "1": {
          "from": 1750550400,
          "to": 1753142400,
          "cadenceHours": 1,
          "generatedAt": 1753142400,
          "points": [ { "timestamp": 1750550400, "block": 25161201 } ]
        }
      }
    }
  }
}
```

`points` is ascending by timestamp, inclusive of both endpoints (`(to-from)/3600h + 1` points; 30d hourly = 721). Consumed by Task 5 (forge test reads `.windows.<name>.chains.<id>.points[*]`) and Task 6 (driver).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Generate a named, pinned window of hourly block numbers for the NAV backtest harness.
# Usage: generate-backtest-blocks.sh --window w1-30d --from <unix_ts> --to <unix_ts> [--chain 1] [--hours 1]
# Windows are absolute (from/to timestamps), never relative to now — the window is picked once and pinned.
# RPC resolution: $MAINNET_URL (etc.) > Alchemy via $ALCHEMY_API_KEY + accounts.json alchemyNetwork.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

CHAIN=1; HOURS=1; WINDOW=""; FROM=""; TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --hours) HOURS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$WINDOW" && -n "$FROM" && -n "$TO" ]] || { echo "usage: $0 --window <name> --from <ts> --to <ts> [--chain 1] [--hours 1]" >&2; exit 1; }
(( TO > FROM )) || { echo "--to must be > --from" >&2; exit 1; }

ACCOUNTS_JSON="test/integration/accounts.json"
OUT_JSON="test/integration/backtest-blocks.json"

rpc_url() {
  local chain="$1"
  case "$chain" in
    1) echo "${MAINNET_URL:-}" ;;
    10) echo "${OP_URL:-}" ;;
    100) echo "${GNOSIS_URL:-}" ;;
    8453) echo "${BASE_URL:-}" ;;
    42161) echo "${ARBITRUM_URL:-}" ;;
  esac
}

URL="$(rpc_url "$CHAIN")"
if [[ -z "$URL" ]]; then
  NETWORK="$(jq -r ".chains.\"$CHAIN\".alchemyNetwork" "$ACCOUNTS_JSON")"
  [[ -n "${ALCHEMY_API_KEY:-}" ]] || { echo "set ALCHEMY_API_KEY or a chain URL env var" >&2; exit 1; }
  URL="https://${NETWORK}.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
fi

POINTS_N=$(( (TO - FROM) / (HOURS * 3600) ))

echo "Generating $((POINTS_N + 1)) points for window '$WINDOW' chain $CHAIN (every ${HOURS}h)..." >&2
points="[]"
for (( i=0; i<=POINTS_N; i++ )); do
  ts=$(( FROM + i * HOURS * 3600 ))
  block="$(cast find-block "$ts" --rpc-url "$URL")"
  points="$(jq -c --argjson ts "$ts" --argjson b "$block" '. + [{timestamp:$ts, block:$b}]' <<<"$points")"
  echo "  $i/$POINTS_N ts=$ts block=$block" >&2
done

[[ -f "$OUT_JSON" ]] || echo '{"$comment":"Generated by script/test/generate-backtest-blocks.sh. Named pinned windows of hourly blocks for the NAV backtest.","windows":{}}' > "$OUT_JSON"
jq --arg w "$WINDOW" --arg c "$CHAIN" --argjson from "$FROM" --argjson to "$TO" --argjson hours "$HOURS" --argjson now "$(date +%s)" --argjson pts "$points" \
  '.windows[$w].chains[$c] = {from:$from, to:$to, cadenceHours:$hours, generatedAt:$now, points:$pts}' \
  "$OUT_JSON" > "$OUT_JSON.tmp" && mv "$OUT_JSON.tmp" "$OUT_JSON"
echo "Wrote $OUT_JSON (window $WINDOW, chain $CHAIN, $((POINTS_N + 1)) points)" >&2
```

`chmod +x script/test/generate-backtest-blocks.sh`.

- [ ] **Step 2: Smoke-test with a tiny window**

Run (any recent 24h range, e.g. yesterday):

```bash
FROM=$(date -v-2d +%s 2>/dev/null || date -d '2 days ago' +%s)
./script/test/generate-backtest-blocks.sh --window smoke --from "$FROM" --to $((FROM + 86400)) --chain 1 --hours 12
```

Expected: `jq '.windows.smoke.chains."1".points | length' test/integration/backtest-blocks.json` prints `3`; blocks strictly ascending. Remove the smoke window afterwards: `jq 'del(.windows.smoke)' test/integration/backtest-blocks.json > t && mv t test/integration/backtest-blocks.json`.

- [ ] **Step 3: Generate the pinned 30-day window and commit**

Pick the window ONCE: `TO` = the most recent whole hour, `FROM = TO - 30*86400`. Name it `w1-30d`.

```bash
TO=$(( $(date +%s) / 3600 * 3600 ))
./script/test/generate-backtest-blocks.sh --window w1-30d --from $((TO - 30*86400)) --to "$TO" --chain 1 --hours 1
```

Expected: 721 points. The from/to values are now frozen in the committed JSON — future runs assert against this exact window; new/longer windows are added later as new names (e.g. `w2-90d`), not by regenerating `w1-30d`.

```bash
git add script/test/generate-backtest-blocks.sh test/integration/backtest-blocks.json
git commit -m "feat(backtest): named pinned-window block-list generator + w1-30d mainnet window"
```

---

### Task 5: NavBacktest fork test

**Files:**
- Modify: `test/integration/IntegrationFromConfigBase.fork.sol` (track deployed price-feed addresses in an array; add `_makeStackPersistent()`)
- Create: `test/integration/NavBacktest.fork.t.sol`

**Interfaces:**
- Consumes: `IntegrationFromConfigBase._setupAndDeploy()`, `_readUsdNav(address) returns (INAVCalculator.NAV memory)`, `_deployedBalanceAdapters` (address[]), `_forkBlock`, `fork` (uint256 fork id), `QUOTE_USD`; `test/integration/backtest-blocks.json` from Task 4; `LibraryPins.PRICE_FEED_LIB` / `LibraryPins.NAV_REGISTRY_LIB`.
- Produces: stdout lines `BACKTEST|<chainId>|<block>|<timestamp>|<account>|<navUsd8dp or ERROR:reason>` consumed by Task 6's driver; internal helper `_makeStackPersistent()` on the base; new base array `address[] internal _deployedPriceFeedAddresses`.
- Env contract: `BACKTEST_CHAIN` (uint, default 1), `BACKTEST_BLOCKS_FILE` (string; when unset/empty a 2-point smoke sweep runs instead), `BACKTEST_WINDOW` (string, default `w1-30d`; window name inside the blocks file).

- [ ] **Step 1: Track price-feed addresses in the base**

In `IntegrationFromConfigBase.fork.sol`, next to `_deployedBalanceAdapters` (~line 134) add:

```solidity
    /// @notice Every ephemerally-deployed price feed address (parallel purpose to
    ///         _ephemeralPriceFeeds, which is a name-keyed mapping and thus not iterable).
    ///         Used by the backtest harness to vm.makePersistent the whole stack.
    address[] internal _deployedPriceFeedAddresses;
```

In `_tryDeployPriceFeed` (line 258), after `_ephemeralPriceFeeds[name] = addr;` add:

```solidity
        _deployedPriceFeedAddresses.push(addr);
```

- [ ] **Step 2: Add `_makeStackPersistent()` to the base**

At the end of the "NAV reading" section of `IntegrationFromConfigBase.fork.sol`:

```solidity
    /// @notice Marks the entire locally-deployed NAV stack persistent so it survives
    ///         vm.rollFork sweeps (backtest harness). Covers proxy, etched libraries,
    ///         every balance adapter, and every ephemeral price feed.
    function _makeStackPersistent() internal {
        vm.makePersistent(address(nav));
        vm.makePersistent(Upgrades.getImplementationAddress(address(nav)));
        vm.makePersistent(nav.erc20DefaultBalanceAdapter()); // deployed inside initialize, not in _deployedBalanceAdapters
        vm.makePersistent(LibraryPins.PRICE_FEED_LIB);
        vm.makePersistent(LibraryPins.NAV_REGISTRY_LIB);
        for (uint256 i = 0; i < _deployedBalanceAdapters.length; i++) {
            vm.makePersistent(_deployedBalanceAdapters[i]);
        }
        for (uint256 i = 0; i < _deployedPriceFeedAddresses.length; i++) {
            vm.makePersistent(_deployedPriceFeedAddresses[i]);
        }
    }
```

Notes: `Upgrades.getImplementationAddress` (openzeppelin-foundry-upgrades, imported in the base at line 6) reads the EIP-1967 slot — persisting the implementation keeps the proxy functional across `rollFork`. `erc20DefaultBalanceAdapter` is the public address var on `Balances` (src/balances/Balances.sol:56) for the adapter deployed inside `initialize`, which is NOT in `_deployedBalanceAdapters` — it must be persisted explicitly or wallet-token positions would read empty code after rolls.

Also mark `test_emitSnapshots()` in the base as `virtual` (it is a plain `public` test function today) — Step 3's contract overrides it as a no-op so a NavBacktest run can never clobber the committed `nav-positions-<chainId>.json` fixtures.

- [ ] **Step 3: Write NavBacktest.fork.t.sol**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IntegrationFromConfigBase} from "test/integration/IntegrationFromConfigBase.fork.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Historical NAV backtest: deploys the full NAV stack from local source at the
///         OLDEST block of a pinned hourly block list, then vm.rollFork's forward reading
///         getAccountNav per account per block. Emits machine-readable BACKTEST| lines
///         consumed by script/test/run-nav-backtest.sh. Per-point reverts are recorded,
///         never fatal — a reverting block IS the stability-backtest signal.
///
///         Env: BACKTEST_CHAIN (default 1), BACKTEST_BLOCKS_FILE + BACKTEST_WINDOW
///         (default w1-30d; BLOCKS_FILE unset/empty => 2-point smoke sweep near the
///         accounts.json forkBlock, so CI exercises the harness cheaply).
contract NavBacktest is IntegrationFromConfigBase {
    using stdJson for string;

    uint256[] internal _blocks;
    uint256[] internal _timestamps;
    address[] internal _backtestAccounts;

    function setUp() public {
        _chainId = vm.envOr("BACKTEST_CHAIN", uint256(1));

        string memory accountsJson = vm.readFile(ACCOUNTS_JSON);
        _forkNetwork = accountsJson.readString(string.concat(".chains.", vm.toString(_chainId), ".alchemyNetwork"));

        _loadBlocks(accountsJson);
        _loadAccounts(accountsJson);

        _forkBlock = _blocks[0]; // oldest point: deploy here, roll forward
        _setupAndDeploy();
        _makeStackPersistent();
    }

    /// @dev No-op override: the inherited snapshot emitter writes nav-positions-<chainId>.json,
    ///      which must never be clobbered by a backtest run (different deploy block).
    function test_emitSnapshots() public override {}

    function test_backtestSweep() public {
        for (uint256 b = 0; b < _blocks.length; b++) {
            if (b > 0) vm.rollFork(_blocks[b]);
            for (uint256 a = 0; a < _backtestAccounts.length; a++) {
                _emitPoint(_blocks[b], _timestamps[b], _backtestAccounts[a]);
            }
        }
    }

    function _emitPoint(uint256 blockNum, uint256 ts, address account) internal {
        string memory result;
        try nav.getAccountNav(account, QUOTE_USD) returns (INAVCalculator.NAV memory n) {
            result = vm.toString(n.value);
        } catch Error(string memory reason) {
            result = string.concat("ERROR:", reason);
        } catch (bytes memory) {
            result = "ERROR:low-level revert";
        }
        console2.log(
            string.concat(
                "BACKTEST|",
                vm.toString(_chainId), "|",
                vm.toString(blockNum), "|",
                vm.toString(ts), "|",
                vm.toString(account), "|",
                result
            )
        );
    }

    /// @dev BACKTEST_BLOCKS_FILE unset/empty => smoke mode: two points — the accounts.json
    ///      forkBlock (RPC-cached by the normal integration run) and forkBlock - 300 (small
    ///      extra RPC cost, exercises the rollFork path).
    function _loadBlocks(string memory accountsJson) internal {
        string memory blocksFile = vm.envOr("BACKTEST_BLOCKS_FILE", string(""));
        if (bytes(blocksFile).length == 0) {
            uint256 pinned = accountsJson.readUint(string.concat(".chains.", vm.toString(_chainId), ".forkBlock"));
            _blocks.push(pinned - 300);
            _blocks.push(pinned);
            _timestamps.push(0);
            _timestamps.push(0);
            return;
        }
        string memory json = vm.readFile(blocksFile);
        string memory window = vm.envOr("BACKTEST_WINDOW", string("w1-30d"));
        string memory base =
            string.concat(".windows.", window, ".chains.", vm.toString(_chainId), ".points");
        uint256 i;
        while (true) {
            string memory p = string.concat(base, "[", vm.toString(i), "]");
            if (!vm.keyExists(json, p)) break;
            _blocks.push(json.readUint(string.concat(p, ".block")));
            _timestamps.push(json.readUint(string.concat(p, ".timestamp")));
            unchecked { ++i; }
        }
        require(_blocks.length > 0, "backtest: no points for window/chain in blocks file");
    }

    function _loadAccounts(string memory accountsJson) internal {
        uint256 i;
        while (true) {
            string memory base = string.concat(".accounts[", vm.toString(i), "]");
            if (!vm.keyExists(accountsJson, base)) break;
            string memory addrStr = accountsJson.readString(string.concat(base, ".address"));
            if (bytes(addrStr).length > 0) {
                uint256[] memory enabled = accountsJson.readUintArray(string.concat(base, ".enabledChains"));
                if (_contains(enabled, _chainId)) {
                    _backtestAccounts.push(vm.parseAddress(addrStr));
                }
            }
            unchecked { ++i; }
        }
        require(_backtestAccounts.length > 0, "backtest: no enabled accounts for chain");
    }
}
```

Note: `_contains(uint256[] memory, uint256)` already exists on the base at line 1129 (`internal pure`) — use it directly.

- [ ] **Step 4: Run the smoke sweep (2 points) to verify it fails/passes correctly**

First verify the test compiles and the harness deploys:

Run: `FOUNDRY_PROFILE=slow forge test --match-contract NavBacktest --match-test test_backtestSweep -vv 2>&1 | grep -E "BACKTEST\||\[PASS\]|\[FAIL\]"`
Expected: `[PASS] test_backtestSweep()` and `2 × N_accounts` BACKTEST lines (2 blocks × every mainnet-enabled account), each ending in a numeric NAV or `ERROR:...`. The two NAV values per account at adjacent blocks should be near-identical.

- [ ] **Step 5: Commit**

```bash
git add test/integration/IntegrationFromConfigBase.fork.sol test/integration/NavBacktest.fork.t.sol
git commit -m "feat(backtest): NavBacktest rollFork sweep over pinned hourly blocks"
```

---

### Task 6: Driver script + fixture (snapshot / assert / report modes)

**Files:**
- Create: `script/test/run-nav-backtest.sh`
- Create (generated in snapshot mode, committed): `test/integration/nav-timeseries.json`

**Interfaces:**
- Consumes: `BACKTEST|chainId|block|timestamp|account|navOrError` lines from Task 5; `test/integration/backtest-blocks.json` from Task 4.
- Produces: `test/integration/nav-timeseries.json` with schema:

```json
{
  "$comment": "NAV backtest fixture. Regenerate: script/test/run-nav-backtest.sh --mode snapshot",
  "windows": {
    "w1-30d": {
      "chains": {
        "1": {
          "generatedAtCommit": "abc1234",
          "accounts": {
            "0xabc...": [ { "block": 25161201, "timestamp": 1750550400, "nav": "21896078268" },
                          { "block": 25161500, "timestamp": 1750554000, "error": "ERROR:..." } ]
          }
        }
      }
    }
  }
}
```

Exit codes: 0 = success (assert: fixture matches; report/snapshot: sweep completed with no missing points); 1 = assert mismatch or missing points; 2 = usage/RPC error.

- [ ] **Step 1: Write the driver**

```bash
#!/usr/bin/env bash
# NAV historical backtest driver.
# Usage: run-nav-backtest.sh [--chain 1] [--window w1-30d] [--mode report|snapshot|assert]
#   report   (default) run sweep, print summary, do not touch the fixture
#   snapshot run sweep and (over)write the window's entry in test/integration/nav-timeseries.json
#   assert   run sweep and diff against the fixture's window entry; exit 1 on any difference
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

CHAIN=1; MODE=report; WINDOW=w1-30d
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in report|snapshot|assert) ;; *) echo "bad --mode: $MODE" >&2; exit 2 ;; esac

BLOCKS_JSON="test/integration/backtest-blocks.json"
FIXTURE="test/integration/nav-timeseries.json"

[[ -f "$BLOCKS_JSON" ]] || { echo "missing $BLOCKS_JSON — run script/test/generate-backtest-blocks.sh first" >&2; exit 2; }
jq -e --arg w "$WINDOW" --arg c "$CHAIN" '.windows[$w].chains[$c].points | length > 0' "$BLOCKS_JSON" >/dev/null \
  || { echo "no points for window $WINDOW / chain $CHAIN in $BLOCKS_JSON" >&2; exit 2; }

LOG="$(mktemp)"
echo "Running sweep (window $WINDOW, chain $CHAIN, $(jq --arg w "$WINDOW" --arg c "$CHAIN" '.windows[$w].chains[$c].points|length' "$BLOCKS_JSON") points)..." >&2
BACKTEST_CHAIN="$CHAIN" BACKTEST_BLOCKS_FILE="$BLOCKS_JSON" BACKTEST_WINDOW="$WINDOW" FOUNDRY_PROFILE=slow \
  forge test --match-contract NavBacktest --match-test test_backtestSweep -vv > "$LOG" 2>&1 || { tail -50 "$LOG" >&2; echo "forge test failed" >&2; exit 2; }

# BACKTEST|chain|block|ts|account|navOrError  →  per-account arrays
RESULTS="$(grep -E '^\s*BACKTEST\|' "$LOG" | sed 's/^[[:space:]]*//' | awk -F'|' -v c="$CHAIN" '$2==c' \
  | jq -R -s -c 'split("\n") | map(select(length>0) | split("|") |
      {account: .[4], point: (if (.[5] | startswith("ERROR:"))
        then {block: (.[2]|tonumber), timestamp: (.[3]|tonumber), error: .[5]}
        else {block: (.[2]|tonumber), timestamp: (.[3]|tonumber), nav: .[5]} end)})
    | group_by(.account) | map({key: .[0].account, value: map(.point)}) | from_entries')"
[[ "$RESULTS" != "{}" && -n "$RESULTS" ]] || { echo "no BACKTEST lines in forge output — see $LOG" >&2; exit 2; }

EXPECTED_POINTS="$(jq --arg w "$WINDOW" --arg c "$CHAIN" '.windows[$w].chains[$c].points|length' "$BLOCKS_JSON")"
MISSING=0
for acct in $(jq -r 'keys[]' <<<"$RESULTS"); do
  n="$(jq --arg a "$acct" '.[$a]|length' <<<"$RESULTS")"
  [[ "$n" == "$EXPECTED_POINTS" ]] || { echo "MISSING POINTS: $acct has $n/$EXPECTED_POINTS" >&2; MISSING=1; }
done

# Report: reverting points + largest hour-over-hour jumps.
echo "== Backtest report (window $WINDOW, chain $CHAIN) =="
jq -r 'to_entries[] | .key as $a | (.value | map(select(.error)) | length) as $errs |
  "\($a): \(.value|length) points, \($errs) reverting"' <<<"$RESULTS"
jq -r 'to_entries[] | .key as $a | [.value[] | select(.nav)] |
  [range(1; length) as $i | {block: .[$i].block,
    jumpPct: ((((.[$i].nav|tonumber) - (.[$i-1].nav|tonumber)) / (if (.[$i-1].nav|tonumber)==0 then 1 else (.[$i-1].nav|tonumber) end)) * 100)}] |
  max_by(if .jumpPct < 0 then -.jumpPct else .jumpPct end) // empty | "\($a): max hourly jump \(.jumpPct|round)% at block \(.block)"' <<<"$RESULTS"

case "$MODE" in
  snapshot)
    COMMIT="$(git rev-parse --short HEAD)"
    [[ -f "$FIXTURE" ]] || echo '{"$comment":"NAV backtest fixture. Regenerate: script/test/run-nav-backtest.sh --mode snapshot","windows":{}}' > "$FIXTURE"
    jq --arg w "$WINDOW" --arg c "$CHAIN" --arg commit "$COMMIT" --argjson res "$RESULTS" \
      '.windows[$w].chains[$c] = {generatedAtCommit: $commit, accounts: $res}' "$FIXTURE" > "$FIXTURE.tmp" && mv "$FIXTURE.tmp" "$FIXTURE"
    echo "Wrote $FIXTURE (window $WINDOW, chain $CHAIN)"
    ;;
  assert)
    [[ -f "$FIXTURE" ]] || { echo "no fixture $FIXTURE — run --mode snapshot first" >&2; exit 2; }
    PINNED="$(jq -c --arg w "$WINDOW" --arg c "$CHAIN" '.windows[$w].chains[$c].accounts' "$FIXTURE")"
    if [[ "$(jq -c -S <<<"$RESULTS")" == "$(jq -c -S <<<"$PINNED")" ]]; then
      echo "ASSERT OK: sweep matches fixture exactly"
    else
      echo "ASSERT FAIL: sweep differs from fixture" >&2
      diff <(jq -S <<<"$PINNED") <(jq -S <<<"$RESULTS") | head -60 >&2 || true
      exit 1
    fi
    ;;
esac
exit "$MISSING"
```

`chmod +x script/test/run-nav-backtest.sh`.

- [ ] **Step 2: Smoke-test the pipeline with a tiny window**

Generate a 3-point smoke window, run all three modes against it:

```bash
FROM=$(date -v-2d +%s 2>/dev/null || date -d '2 days ago' +%s)
./script/test/generate-backtest-blocks.sh --window smoke --from "$FROM" --to $((FROM + 86400)) --chain 1 --hours 12
./script/test/run-nav-backtest.sh --window smoke --mode report
./script/test/run-nav-backtest.sh --window smoke --mode snapshot
./script/test/run-nav-backtest.sh --window smoke --mode assert
```

Expected: report prints per-account point/revert counts and max hourly jump; snapshot writes the `smoke` window into `test/integration/nav-timeseries.json`; assert prints `ASSERT OK` and exits 0. Then corrupt one nav value in the fixture (`jq` edit), rerun assert, expect `ASSERT FAIL` + exit 1. Finally remove the smoke window from both JSONs: `jq 'del(.windows.smoke)' <file> > t && mv t <file>` for each.

- [ ] **Step 3: Generate the real pinned w1-30d fixture and commit**

(Uses the `w1-30d` window committed in Task 4.)

```bash
./script/test/run-nav-backtest.sh --window w1-30d --mode snapshot
git add script/test/run-nav-backtest.sh test/integration/nav-timeseries.json
git commit -m "feat(backtest): driver with report/snapshot/assert modes + w1-30d hourly mainnet fixture"
```

Note: the first full sweep is the expensive one (721 blocks × all adapters' RPC reads — budget hours, run overnight or on a beefy connection). Every rerun over the same blocks is served from `~/.foundry/cache/rpc` — free.

---

### Task 7: Documentation

**Files:**
- Create: `docs/howto/nav-backtest.md`
- Modify: `CLAUDE.md` ("Read this first by intent" table — one new row)

**Interfaces:**
- Consumes: everything above; no code interfaces.

- [ ] **Step 1: Write the how-to**

`docs/howto/nav-backtest.md` must cover, in this order (write real prose, not stubs):
1. What it is: on-demand historical NAV sweep — deploy the local-source NAV stack once at the oldest pinned block on a fork, `vm.rollFork` hourly, record `getAccountNav` per account; nothing is ever broadcast on-chain.
2. Quickstart: the exact commands from Task 6 Step 2 (smoke window) and Step 3 (`run-nav-backtest.sh --window w1-30d --mode snapshot`) with expected runtimes (first run RPC-bound; reruns cached).
3. The oracle-change workflow: edit a feed/adapter → `run-nav-backtest.sh --window w1-30d --mode report` → diff against the committed fixture (or a baseline run from `main`); explain that this is how you test oracle changes against the pinned 30-day window without deploying.
4. Modes table (report / snapshot / assert) with exit codes.
5. File map: `generate-backtest-blocks.sh`, `backtest-blocks.json`, `NavBacktest.fork.t.sol`, `run-nav-backtest.sh`, `nav-timeseries.json`.
6. Caveats: adapters/pools/feeds that didn't exist at the oldest blocks revert per-point and are recorded as `error`, not fatal; smoke mode (2 points) runs inside the normal integration suite so the harness can't rot; the full sweep is on-demand only. (If a Merkl rewards adapter returns to the repo, add its root-mismatch-reads-0 caveat here.)
7. Windows: windows are named and pinned (absolute from/to); `w1-30d` is the default. Adding a longer/newer window = `generate-backtest-blocks.sh --window w2-... --from ... --to ...` + `run-nav-backtest.sh --window w2-... --mode snapshot`; never regenerate an existing window name.
8. Extending to other chains: `--chain <id>` on both scripts + rerun snapshot (structure is per-chain-ready).

- [ ] **Step 2: Verify the how-to content**

Run:

```bash
for s in "generate-backtest-blocks.sh" "run-nav-backtest.sh" "--mode report" "--mode snapshot" "--mode assert" "w1-30d" "nav-timeseries.json" "backtest-blocks.json" "rollFork"; do
  grep -q -- "$s" docs/howto/nav-backtest.md || echo "MISSING: $s"
done
```

Expected: no `MISSING:` lines.

- [ ] **Step 3: Add the CLAUDE.md index row**

In the "Read this first by intent" table add:

```markdown
| Run or refresh the historical NAV backtest (hourly NAV over a pinned window, oracle-change diffing) | `docs/howto/nav-backtest.md` |
```

Verify: `grep -q "nav-backtest.md" CLAUDE.md && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add docs/howto/nav-backtest.md CLAUDE.md
git commit -m "docs: NAV backtest how-to + index entry"
```

---

### Task 8: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full local gates**

Run: `forge build && forge test --no-match-path "*fork*"`
Expected: both pass.

- [ ] **Step 2: Integration suite still green (includes the NavBacktest smoke sweep)**

Run: `FOUNDRY_PROFILE=slow forge test --match-path "test/integration/*" --threads 1 -vv 2>&1 | grep -E "\[PASS\]|\[FAIL\]|Suite"`
Expected: all `[PASS]`, including `NavBacktest::test_backtestSweep` in smoke mode.

- [ ] **Step 3: Push and watch CI**

Run: `git push && gh run watch`
Expected: all jobs green on Blacksmith runners; Build job warm-cache time ≤ ~4 min.
