# NAV Backtest Harness + Blacksmith CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate CI to Blacksmith runners with a persistent forge build cache, then build an on-demand historical backtest harness over a named, pinned 24-hour window: 25 hourly points for two explicit mainnet accounts.

**Architecture:** Part 1 persists CI compilation artifacts. Part 2 deploys the local NAV stack once, makes it persistent, then rolls a named block window whose config is `{fromBlock,toBlock,blockStep,metrics,accounts}`. `accounts` is validated against chain-enabled entries in `accounts.json`. The Bun driver snapshots, asserts, or reports emitted `BACKTEST|...` rows.

**Tech Stack:** GitHub Actions + Blacksmith, Foundry (forge, `slow` profile), Bun (single-file TypeScript driver, no package.json), Solidity ^0.8.

**Spec:** `.omo/specs/2026-07-22-nav-backtest-harness-design.md`

## Global Constraints

- Foundry version is pinned to `v1.7.1` in CI (`FOUNDRY_VERSION` env in `.github/workflows/foundry.yml`); do not change it.
- `via_ir = true`, `solc_version = "0.8.34"`, `evm_version = "cancun"` in `foundry.toml` must not change (CREATE2 library pins depend on them).
- Keep `build_info = true`, `ast = true`, `extra_output = ["storageLayout"]` in `foundry.toml` (openzeppelin-foundry-upgrades needs build_info).
- New Solidity files use `pragma solidity ^0.8;`.
- NAV casing: type-level names use `NAV`/`Backtest...`; mixedCase identifiers use `Nav` (e.g. `getAccountNav`).
- Fork tests run under `FOUNDRY_PROFILE=slow` (threads=1, 16 GiB gas/memory limits — the integration harness needs it).
- Backtest defaults (user-approved revision): chain 1, window `w1-1d`, blocks `25419715..25426915`, step 300, 25 inclusive hourly points, metric `nav`, and an explicit allowlist containing the first two mainnet-enabled accounts. On-demand only.
- The driver requires `bun` locally (`curl -fsSL https://bun.sh/install | bash`); it is NOT needed for `forge build`/`forge test` or any CI job in v1.
- The Blacksmith GitHub App must be installed on this repo before CI runs on `blacksmith-*` labels (manual prerequisite; jobs queue otherwise).
- `forge build` and `forge test` (unit) must pass before every push.

---

### Task 1: Blacksmith runner migration

**Files:**
- Modify: `.github/workflows/foundry.yml:27,54,76,100,123` (the five `runs-on: ubuntu-latest` lines)
- Modify: `.github/workflows/refresh-integration-snapshot.yml:35`

**Interfaces:**
- Produces: CI jobs running on Blacksmith runners; existing `foundry-toolchain` `cache: true` RPC caching transparently redirects to Blacksmith's colocated cache (no key changes).

- [x] **Step 1: Swap runs-on labels in foundry.yml**

Replace each `runs-on: ubuntu-latest` with the tier for that job:

| Job (line) | New value |
|---|---|
| `build` (27) | `runs-on: blacksmith-8vcpu-ubuntu-2404` |
| `unit` (54) | `runs-on: blacksmith-4vcpu-ubuntu-2404` |
| `fork` (76) | `runs-on: blacksmith-4vcpu-ubuntu-2404` |
| `integration` (100) | `runs-on: blacksmith-4vcpu-ubuntu-2404` |
| `lint` (123) | `runs-on: blacksmith-2vcpu-ubuntu-2404` |

Rationale: via_ir solc parallelizes across compilation units → 8vcpu for build; fork/integration are RPC-bound with `--threads 1` → 4vcpu; fmt check → 2vcpu.

- [x] **Step 2: Swap runs-on in refresh-integration-snapshot.yml**

Line 35: `runs-on: ubuntu-latest` → `runs-on: blacksmith-4vcpu-ubuntu-2404`.

- [x] **Step 3: Validate workflow syntax**

Run: `actionlint .github/workflows/foundry.yml .github/workflows/refresh-integration-snapshot.yml` (if actionlint is unavailable: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" .github/workflows/foundry.yml .github/workflows/refresh-integration-snapshot.yml`)
Expected: no errors.

- [x] **Step 4: Commit**

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

- [x] **Step 1: Add stickydisk mounts to the Build job**

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

- [x] **Step 2: Validate workflow syntax**

Run: same validation command as Task 1 Step 3.
Expected: no errors.

- [x] **Step 3: Commit**

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

- [x] **Step 1: Add the flag**

In `[profile.default]` add:

```toml
# Test-only edits don't recompile src/ (foundry >=1.1). Tests are linked
# dynamically; src bytecode (and therefore CREATE2 library pins) is unaffected.
dynamic_test_linking = true
```

- [x] **Step 2: Verify pins are unaffected and build works**

Run: `forge build && forge test --no-match-path "*fork*" --match-path "test/LibraryPinConsistency.t.sol" -vv`
Expected: build succeeds; `LibraryPinConsistency` passes (proves library bytecode/pins unchanged).

- [x] **Step 3: Verify incremental behavior**

Foundry hashes content, so `touch` alone won't trigger a rebuild — make a real edit and revert it:

```bash
printf '\n// recompile probe\n' >> test/Constants.t.sol
forge build 2>&1 | tail -3
git checkout -- test/Constants.t.sol
```

Expected: the build output shows a small "Compiling N files" count (only the edited test's compilation unit, not 509).

- [x] **Step 4: Commit**

```bash
git add foundry.toml
git commit -m "build: enable dynamic_test_linking for faster test-only rebuilds"
```

---

### Task 4: Pinned block-window definition file

**Files:**
- Create: `test/integration/backtest-blocks.json`

**Interfaces:**
- Produces: `test/integration/backtest-blocks.json`. Windows are defined in blocks as `{fromBlock,toBlock,blockStep,metrics,accounts}`. `accounts` is an explicit stable allowlist validated against `accounts.json`.

```json
{
  "$comment": "Named pinned block windows. accounts must be enabled for the chain in accounts.json.",
  "windows": {
    "w1-1d": {
      "chains": {
        "1": {
          "fromBlock": 25419715,
          "toBlock": 25426915,
          "blockStep": 300,
          "metrics": ["nav"],
          "accounts": [
            "0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6",
            "0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b"
          ]
        }
      }
    }
  }
}
```

Point count = 25. Total rows = 25 blocks × 2 accounts × 1 metric = 50.

- [x] **Step 1: Replace diagnostic config with the pinned window**

Anchor `toBlock` to `.chains."1".forkBlock` (`25426915`). Set `fromBlock = toBlock - 7200`, `blockStep = 300`, and list the first two mainnet-enabled account addresses.

Write the JSON above to `test/integration/backtest-blocks.json` with those values.

- [x] **Step 2: Validate the arithmetic**

Run: `jq '.windows."w1-1d".chains."1" | [((.toBlock - .fromBlock) / .blockStep | floor) + 1, (.accounts | length)]' test/integration/backtest-blocks.json`
Expected: `[25,2]`.

- [x] **Step 3: Commit revised window**

```bash
git add test/integration/backtest-blocks.json
git commit -m "feat(backtest): pin one-day two-account window"
```

---

### Task 5: NavBacktest fork test

**Files:**
- Modify: `test/integration/IntegrationFromConfigBase.fork.sol` (track deployed price-feed addresses in an array; add `_makeStackPersistent()`)
- Create: `test/integration/NavBacktest.fork.t.sol`

**Interfaces:**
- Consumes: `IntegrationFromConfigBase._setupAndDeploy()`, `_readUsdNav(address) returns (INAVCalculator.NAV memory)`, `_deployedBalanceAdapters` (address[]), `_forkBlock`, `fork` (uint256 fork id), `QUOTE_USD`; `test/integration/backtest-blocks.json` from Task 4; `LibraryPins.PRICE_FEED_LIB` / `LibraryPins.NAV_REGISTRY_LIB`.
- Produces: stdout lines `BACKTEST|<chainId>|<block>|<timestamp>|<account>|<metric>|<value or ERROR:reason>` (timestamp = fork's `block.timestamp` at that point) consumed by Task 6's driver; internal helper `_makeStackPersistent()` on the base; new base array `address[] internal _deployedPriceFeedAddresses`; a **metric registry** in NavBacktest (`_evalMetric(bytes32 metricHash, address account) returns (string memory)` — v1 implements `"nav"`).
- Env contract: `BACKTEST_CHAIN` (uint, default 1), `BACKTEST_BLOCKS_FILE` (string; when unset/empty a 2-point smoke sweep runs instead), `BACKTEST_WINDOW` (string, default `w1-1d`; window name inside the blocks file).

- [x] **Step 1: Track price-feed addresses in the base**

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

- [x] **Step 2: Add `_makeStackPersistent()` to the base**

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

`test_emitSnapshots()` is already `virtual` from the completed base-harness work; keep the no-op override so NavBacktest cannot clobber `nav-positions-<chainId>.json`.

- [x] **Step 3: Write NavBacktest.fork.t.sol**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IntegrationFromConfigBase} from "test/integration/IntegrationFromConfigBase.fork.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Historical backtest: deploys the full NAV stack from local source at the
///         fromBlock of a pinned block window, then vm.rollFork's forward evaluating each
///         configured metric per account per block. Emits machine-readable BACKTEST| lines
///         consumed by script/test/nav-backtest.ts. Per-point reverts are recorded,
///         never fatal — a reverting block IS the stability-backtest signal.
///
///         Env: BACKTEST_CHAIN (default 1), BACKTEST_BLOCKS_FILE + BACKTEST_WINDOW
///         (default w1-1d; BLOCKS_FILE unset/empty => 2-point smoke sweep near the
///         accounts.json forkBlock, so CI exercises the harness cheaply).
contract NavBacktest is IntegrationFromConfigBase {
    using stdJson for string;

    bytes32 internal constant METRIC_NAV = keccak256("nav");

    uint256[] internal _blocks;
    string[] internal _metrics;
    address[] internal _backtestAccounts;
    address[] internal _configuredAccounts;

    function setUp() public {
        _chainId = vm.envOr("BACKTEST_CHAIN", uint256(1));

        string memory accountsJson = vm.readFile(ACCOUNTS_JSON);
        _forkNetwork = accountsJson.readString(string.concat(".chains.", vm.toString(_chainId), ".alchemyNetwork"));

        _loadWindow(accountsJson);
        _loadAccounts(accountsJson);

        // Fail fast on unknown metric names before paying for the fork.
        for (uint256 m = 0; m < _metrics.length; m++) {
            require(_isKnownMetric(keccak256(bytes(_metrics[m]))), string.concat("backtest: unknown metric ", _metrics[m]));
        }

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
                for (uint256 m = 0; m < _metrics.length; m++) {
                    _emitPoint(_blocks[b], _backtestAccounts[a], _metrics[m]);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Metric registry: to snapshot another function, add a METRIC_* hash,
    // a branch in _evalMetric + _isKnownMetric, and list the name in the
    // window's `metrics` array in backtest-blocks.json. No other changes.
    // -------------------------------------------------------------------

    function _isKnownMetric(bytes32 h) internal pure returns (bool) {
        return h == METRIC_NAV;
    }

    /// @dev Evaluates one metric for one account at the fork's current block.
    ///      Must only revert for truly unknown metrics (guarded in setUp);
    ///      on-chain failures are caught by the caller.
    function _evalMetric(bytes32 h, address account) internal view returns (string memory) {
        if (h == METRIC_NAV) {
            return vm.toString(nav.getAccountNav(account, QUOTE_USD).value);
        }
        revert("backtest: unknown metric");
    }

    function _emitPoint(uint256 blockNum, address account, string memory metric) internal {
        string memory result;
        try this.evalMetricExternal(keccak256(bytes(metric)), account) returns (string memory v) {
            result = v;
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
                vm.toString(block.timestamp), "|", // fork's timestamp at this point — free, no ts->block mapping
                vm.toString(account), "|",
                metric, "|",
                result
            )
        );
    }

    /// @dev External self-call wrapper so try/catch can catch reverts from any metric probe.
    function evalMetricExternal(bytes32 h, address account) external view returns (string memory) {
        return _evalMetric(h, account);
    }

    /// @dev BACKTEST_BLOCKS_FILE unset/empty => smoke mode: two points — the accounts.json
    ///      forkBlock (RPC-cached by the normal integration run) and forkBlock - 300 (small
    ///      extra RPC cost, exercises the rollFork path). Metrics default to ["nav"].
    function _loadWindow(string memory accountsJson) internal {
        _metrics.push("nav"); // default; overridden below if the window configures metrics
        string memory blocksFile = vm.envOr("BACKTEST_BLOCKS_FILE", string(""));
        if (bytes(blocksFile).length == 0) {
            uint256 pinned = accountsJson.readUint(string.concat(".chains.", vm.toString(_chainId), ".forkBlock"));
            _blocks.push(pinned - 300);
            _blocks.push(pinned);
            return;
        }
        string memory json = vm.readFile(blocksFile);
        string memory window = vm.envOr("BACKTEST_WINDOW", string("w1-1d"));
        string memory base = string.concat(".windows.", window, ".chains.", vm.toString(_chainId));
        require(vm.keyExists(json, base), "backtest: no window/chain in blocks file");

        uint256 fromBlock = json.readUint(string.concat(base, ".fromBlock"));
        uint256 toBlock = json.readUint(string.concat(base, ".toBlock"));
        uint256 step = json.readUint(string.concat(base, ".blockStep"));
        require(toBlock > fromBlock && step > 0, "backtest: bad window bounds");
        for (uint256 b = fromBlock; b < toBlock; b += step) {
            _blocks.push(b);
        }
        _blocks.push(toBlock); // toBlock always included as the final point

        if (vm.keyExists(json, string.concat(base, ".metrics"))) {
            delete _metrics;
            string[] memory configured = json.readStringArray(string.concat(base, ".metrics"));
            require(configured.length > 0, "backtest: empty metrics array");
            for (uint256 m = 0; m < configured.length; m++) {
                _metrics.push(configured[m]);
            }
        }
        if (vm.keyExists(json, string.concat(base, ".accounts"))) {
            address[] memory configuredAccounts = json.readAddressArray(string.concat(base, ".accounts"));
            require(configuredAccounts.length > 0, "backtest: empty accounts array");
            for (uint256 a = 0; a < configuredAccounts.length; a++) {
                _configuredAccounts.push(configuredAccounts[a]);
            }
        }
    }

    function _loadAccounts(string memory accountsJson) internal {
        uint256 i;
        while (true) {
            string memory base = string.concat(".accounts[", vm.toString(i), "]");
            if (!vm.keyExists(accountsJson, base)) break;
            string memory addrStr = accountsJson.readString(string.concat(base, ".address"));
            if (bytes(addrStr).length > 0) {
                uint256[] memory enabled = accountsJson.readUintArray(string.concat(base, ".enabledChains"));
                address account = vm.parseAddress(addrStr);
                if (_contains(enabled, _chainId) && _isConfiguredAccount(account)) {
                    _backtestAccounts.push(account);
                }
            }
            unchecked { ++i; }
        }
        require(_backtestAccounts.length > 0, "backtest: no enabled accounts for chain");
        require(
            _configuredAccounts.length == 0 || _backtestAccounts.length == _configuredAccounts.length,
            "backtest: configured account missing or disabled"
        );
    }

    function _isConfiguredAccount(address account) internal view returns (bool) {
        if (_configuredAccounts.length == 0) return true;
        for (uint256 i = 0; i < _configuredAccounts.length; i++) {
            if (_configuredAccounts[i] == account) return true;
        }
        return false;
    }
}
```

Note: `_contains(uint256[] memory, uint256)` already exists on the base (`internal pure`) — use it directly.

- [x] **Step 4: Run the smoke sweep (2 points) to verify it fails/passes correctly**

First verify the test compiles and the harness deploys:

Run: `FOUNDRY_PROFILE=slow forge test --match-contract NavBacktest --match-test test_backtestSweep -vv 2>&1 | grep -E "BACKTEST\||\[PASS\]|\[FAIL\]"`
Expected: `[PASS] test_backtestSweep()` and `2 × N_accounts` BACKTEST lines (2 blocks × every mainnet-enabled account × the default `nav` metric), each with 7 pipe-delimited fields ending in a numeric NAV or `ERROR:...`, and a real (nonzero) fork timestamp in field 4. The two NAV values per account at adjacent blocks should be near-identical.

- [x] **Step 5: Commit**

```bash
git add test/integration/IntegrationFromConfigBase.fork.sol test/integration/NavBacktest.fork.t.sol
git commit -m "feat(backtest): NavBacktest rollFork sweep with configurable metric registry"
```

- [x] **Step 6: Revise named windows to explicit account subsets**

RED proof against product code before this revision: after Task 4 writes `w1-1d`, run `bun script/test/nav-backtest.ts --window w1-1d --mode report`. Expected: 9 accounts instead of configured 2, proving current harness ignores allowlist.

Implement `_configuredAccounts`, `_isConfiguredAccount`, account loading, and default `w1-1d` exactly in the Step 3 code above.

For each malformed probe, write a temporary copy of `backtest-blocks.json`, run Forge with `BACKTEST_BLOCKS_FILE=<temp>` and `BACKTEST_WINDOW=w1-1d`, then restore/remove it:
- `"accounts": []` → `backtest: empty accounts array`.
- duplicate first address → `backtest: configured account missing or disabled`.
- unknown address → `backtest: configured account missing or disabled`.
- account enabled only on another chain → `backtest: configured account missing or disabled`.

GREEN verification:
```bash
set -a; source .env; set +a
test -n "$ALCHEMY_API_KEY"
FOUNDRY_PROFILE=slow forge test --match-contract NavBacktest --match-test test_backtestSweep -vv
bun script/test/nav-backtest.ts --window w1-1d --mode report
```
Expected: smoke mode emits 18 rows; named mode emits exactly 50 rows for the two configured accounts.

Commit:
```bash
git add test/integration/NavBacktest.fork.t.sol
git commit -m "feat(backtest): select accounts per pinned window"
```

---

### Task 6: Bun TS driver + fixture (snapshot / assert / report modes)

**Files:**
- Create: `script/test/nav-backtest.ts` (single-file Bun TypeScript, no package.json / node_modules)
- Create (generated in snapshot mode, committed): `test/integration/nav-timeseries.json`

**Interfaces:**
- Consumes: `BACKTEST|chainId|block|timestamp|account|metric|valueOrError` lines from Task 5; `test/integration/backtest-blocks.json` from Task 4. Requires `bun` on PATH.
- Produces: `test/integration/nav-timeseries.json` with schema:

```json
{
  "$comment": "Backtest fixture. Regenerate: bun script/test/nav-backtest.ts --mode snapshot",
  "windows": {
    "w1-1d": {
      "chains": {
        "1": {
          "generatedAtCommit": "abc1234",
          "accounts": {
            "0xa57F...": {
              "nav": [ { "block": 25419715, "timestamp": 1782692807, "value": "21896078268" },
                        { "block": 25420015, "timestamp": 1782696407, "error": "ERROR:..." } ]
            }
          }
        }
      }
    }
  }
}
```

Exit codes: 0 = success (assert: fixture matches; report/snapshot: sweep completed with no missing points); 1 = assert mismatch or missing points; 2 = usage/forge error.

- [x] **Step 1: Write the driver**

```typescript
#!/usr/bin/env bun
// NAV historical backtest driver (single-file, no dependencies — run with bun).
// Usage: bun script/test/nav-backtest.ts [--chain 1] [--window w1-1d] [--mode report|snapshot|assert]
//   report   (default) run sweep, print summary, do not touch the fixture
//   snapshot run sweep and (over)write the window's entry in test/integration/nav-timeseries.json
//   assert   run sweep and deep-diff against the fixture's window entry; exit 1 on any difference
import { parseArgs } from "node:util";
import { resolve, dirname } from "node:path";

const ROOT = resolve(dirname(Bun.main), "../..");
const BLOCKS_JSON = `${ROOT}/test/integration/backtest-blocks.json`;
const FIXTURE = `${ROOT}/test/integration/nav-timeseries.json`;

type WindowDef = { fromBlock: number; toBlock: number; blockStep: number; metrics?: string[]; accounts: string[] };
type BlocksFile = { windows: Record<string, { chains: Record<string, WindowDef> }> };
type Point = { block: number; timestamp: number; value?: string; error?: string };
type Series = Record<string, Record<string, Point[]>>; // account -> metric -> points
type Fixture = {
  $comment: string;
  windows: Record<string, { chains: Record<string, { generatedAtCommit: string; accounts: Series }> }>;
};

function fail(msg: string, code: 1 | 2): never {
  console.error(msg);
  process.exit(code);
}

const { values: args } = parseArgs({
  options: {
    chain: { type: "string", default: "1" },
    window: { type: "string", default: "w1-1d" },
    mode: { type: "string", default: "report" },
  },
});
const { chain, window: windowName, mode } = args as { chain: string; window: string; mode: string };
if (!["report", "snapshot", "assert"].includes(mode)) fail(`bad --mode: ${mode}`, 2);

const blocksFile: BlocksFile = await Bun.file(BLOCKS_JSON).json().catch(() => fail(`missing/invalid ${BLOCKS_JSON}`, 2));
const win = blocksFile.windows[windowName]?.chains[chain];
if (!win) fail(`no window ${windowName} / chain ${chain} in ${BLOCKS_JSON}`, 2);

const expectedBlocks = Math.floor((win.toBlock - win.fromBlock) / win.blockStep) + 1
  + ((win.toBlock - win.fromBlock) % win.blockStep === 0 ? 0 : 1);
const metrics = win.metrics ?? ["nav"];
const expectedAccounts = win.accounts ?? [];
console.error(`Running sweep (window ${windowName}, chain ${chain}, ${expectedBlocks} blocks, metrics: ${metrics.join(",")})...`);

const proc = Bun.spawn(
  ["forge", "test", "--match-contract", "NavBacktest", "--match-test", "test_backtestSweep", "-vv"],
  {
    cwd: ROOT,
    env: {
      ...process.env,
      BACKTEST_CHAIN: chain,
      BACKTEST_BLOCKS_FILE: "test/integration/backtest-blocks.json",
      BACKTEST_WINDOW: windowName,
      FOUNDRY_PROFILE: "slow",
    },
    stdout: "pipe",
    stderr: "pipe",
  },
);
const out = await new Response(proc.stdout).text();
const err = await new Response(proc.stderr).text();
if ((await proc.exited) !== 0) fail(`forge test failed:\n${(out + err).split("\n").slice(-50).join("\n")}`, 2);

// BACKTEST|chain|block|ts|account|metric|valueOrError -> account -> metric -> points
const results: Series = {};
for (const line of out.split("\n")) {
  const m = line.trim().match(/^BACKTEST\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(.*)$/);
  if (!m || m[1] !== chain) continue;
  const [, , block, ts, account, metric, val] = m;
  const point: Point = val.startsWith("ERROR:")
    ? { block: Number(block), timestamp: Number(ts), error: val }
    : { block: Number(block), timestamp: Number(ts), value: val };
  ((results[account] ??= {})[metric] ??= []).push(point);
}
if (Object.keys(results).length === 0) fail("no BACKTEST lines in forge output", 2);

// Completeness check: every account x metric must have every block.
let missing = false;
for (const [account, byMetric] of Object.entries(results)) {
  for (const metric of metrics) {
    const n = byMetric[metric]?.length ?? 0;
    if (n !== expectedBlocks) {
      console.error(`MISSING POINTS: ${account}/${metric} has ${n}/${expectedBlocks}`);
      missing = true;
    }
  }
}
if (expectedAccounts.length > 0) {
  const actual = new Set(Object.keys(results).map((account) => account.toLowerCase()));
  for (const account of expectedAccounts) {
    if (!actual.has(account.toLowerCase())) {
      console.error(`MISSING ACCOUNT: ${account}`);
      missing = true;
    }
  }
  if (actual.size !== expectedAccounts.length) {
    console.error(`ACCOUNT COUNT: got ${actual.size}, expected ${expectedAccounts.length}`);
    missing = true;
  }
}

// Report: reverting points + largest step-over-step jump per account x metric.
console.log(`== Backtest report (window ${windowName}, chain ${chain}) ==`);
for (const [account, byMetric] of Object.entries(results)) {
  for (const [metric, points] of Object.entries(byMetric)) {
    const errors = points.filter((p) => p.error).length;
    console.log(`${account}/${metric}: ${points.length} points, ${errors} reverting`);
    const vals = points.filter((p) => p.value);
    let worst: { block: number; pct: number } | undefined;
    for (let i = 1; i < vals.length; i++) {
      const prev = Number(vals[i - 1].value);
      const pct = ((Number(vals[i].value) - prev) / (prev === 0 ? 1 : prev)) * 100;
      if (!worst || Math.abs(pct) > Math.abs(worst.pct)) worst = { block: vals[i].block, pct };
    }
    if (worst) console.log(`  max step jump ${worst.pct.toFixed(1)}% at block ${worst.block}`);
  }
}

if (mode === "snapshot") {
  const fixture: Fixture = (await Bun.file(FIXTURE).json().catch(() => null)) ?? {
    $comment: "Backtest fixture. Regenerate: bun script/test/nav-backtest.ts --mode snapshot",
    windows: {},
  };
  const commit = (await new Response(Bun.spawn(["git", "rev-parse", "--short", "HEAD"], { cwd: ROOT }).stdout).text()).trim();
  ((fixture.windows[windowName] ??= { chains: {} }).chains[chain] = { generatedAtCommit: commit, accounts: results });
  await Bun.write(FIXTURE, JSON.stringify(fixture, null, 2) + "\n");
  console.log(`Wrote ${FIXTURE} (window ${windowName}, chain ${chain})`);
} else if (mode === "assert") {
  const fixture: Fixture | null = await Bun.file(FIXTURE).json().catch(() => null);
  const pinned = fixture?.windows[windowName]?.chains[chain]?.accounts;
  if (!pinned) fail(`no fixture entry for window ${windowName} / chain ${chain} — run --mode snapshot first`, 2);
  const a = JSON.stringify(sortKeys(pinned));
  const b = JSON.stringify(sortKeys(results));
  if (a === b) {
    console.log("ASSERT OK: sweep matches fixture exactly");
  } else {
    console.error("ASSERT FAIL: sweep differs from fixture");
    diffSeries(pinned, results);
    process.exit(1);
  }
}
process.exit(missing ? 1 : 0);

function sortKeys(o: unknown): unknown {
  if (Array.isArray(o)) return o.map(sortKeys);
  if (o && typeof o === "object") {
    return Object.fromEntries(Object.entries(o as Record<string, unknown>).sort(([x], [y]) => x.localeCompare(y)).map(([k, v]) => [k, sortKeys(v)]));
  }
  return o;
}

function diffSeries(pinned: Series, current: Series): void {
  let shown = 0;
  for (const account of new Set([...Object.keys(pinned), ...Object.keys(current)])) {
    for (const metric of new Set([...Object.keys(pinned[account] ?? {}), ...Object.keys(current[account] ?? {})])) {
      const p = pinned[account]?.[metric] ?? [];
      const c = current[account]?.[metric] ?? [];
      for (let i = 0; i < Math.max(p.length, c.length) && shown < 30; i++) {
        if (JSON.stringify(p[i]) !== JSON.stringify(c[i])) {
          console.error(`  ${account}/${metric} block ${(c[i] ?? p[i]).block}: pinned=${JSON.stringify(p[i])} got=${JSON.stringify(c[i])}`);
          shown++;
        }
      }
    }
  }
}
```

- [x] **Step 2: Smoke-test the pipeline with a tiny window**

Add a temporary 3-point smoke window (pure JSON edit — anchor to the integration pin): with `PIN` = `.chains."1".forkBlock` from `accounts.json`, add under `.windows.smoke.chains."1"`: `{ "fromBlock": PIN - 600, "toBlock": PIN, "blockStep": 300, "metrics": ["nav"] }`. Then:

```bash
bun script/test/nav-backtest.ts --window smoke --mode report
bun script/test/nav-backtest.ts --window smoke --mode snapshot
bun script/test/nav-backtest.ts --window smoke --mode assert
```

Expected: report prints per-account×metric point/revert counts and max step jump; snapshot writes the `smoke` window into `test/integration/nav-timeseries.json`; assert prints `ASSERT OK` and exits 0. Then corrupt one value in the fixture, rerun assert, expect `ASSERT FAIL` + per-point diff + exit 1. Finally remove the `smoke` window from both JSONs.

- [x] **Step 3: Revise driver defaults and account completeness**

RED proof against product code before this revision: with Task 4's `w1-1d` file, run `bun script/test/nav-backtest.ts --mode report`. Expected: stale product default selects `w1-30d`, so command fails before Forge.

Update `WindowDef` to require `accounts`, validate each entry as a unique EVM address, change the default window to `w1-1d`, and compare normalized emitted account addresses with the configured allowlist. Missing or extra accounts set `missing = true` and exit 1; missing, malformed, or duplicate configured addresses exit 2 before Forge starts. Keep the single file at or below 250 pure LOC and preserve Biome/Fallow gates.

Run:
```bash
bunx @biomejs/biome@2.2.4 lint script/test/nav-backtest.ts
bunx fallow@3.8.0 dead-code --format compact
awk '!/^[[:space:]]*$/ && !/^[[:space:]]*\/\//' script/test/nav-backtest.ts | wc -l
bun script/test/nav-backtest.ts --window w1-1d --mode report
```
Expected: lint gates exit 0, pure LOC ≤250, and report contains exactly two accounts with 25 points each.

Commit:
```bash
git add script/test/nav-backtest.ts
git commit -m "feat(backtest): validate configured account subsets"
```

- [x] **Step 4: Generate the real pinned w1-1d fixture and commit**

(Uses the 25-point/two-account `w1-1d` window committed in Task 4.)

```bash
set -a; source .env; set +a
test -n "$ALCHEMY_API_KEY"
bun script/test/nav-backtest.ts --window w1-1d --mode snapshot
git add test/integration/nav-timeseries.json
git commit -m "feat(backtest): add w1-1d two-account NAV fixture"
```

Expected fixture: exactly 2 accounts × 25 NAV points = 50 rows. `IntegrationFromConfigBase` resolves the chain's `alchemyNetwork` through `TestEnvConfigurator.getAlchemyUrl(ALCHEMY_API_KEY)`. Keep `FOUNDRY_PROFILE=slow`.

---

### Task 7: Documentation

**Files:**
- Create: `docs/howto/nav-backtest.md`
- Modify: `CLAUDE.md` ("Read this first by intent" table — one new row)

**Interfaces:**
- Consumes: everything above; no code interfaces.

- [x] **Step 1: Write the how-to**

`docs/howto/nav-backtest.md` must cover, in this order (write real prose, not stubs):
1. What it is: on-demand historical metric sweep (v1 metric: NAV) — deploy the local-source NAV stack once at a pinned window's `fromBlock` on a fork, `vm.rollFork` every `blockStep`, evaluate each configured metric per account; nothing is ever broadcast on-chain.
2. Prerequisites: `bun` (`curl -fsSL https://bun.sh/install | bash`) — only for the driver, not for forge builds/tests.
3. Quickstart: the exact commands from Task 6 Step 2 and Step 3 (`bun script/test/nav-backtest.ts --window w1-1d --mode snapshot`).
4. The oracle-change workflow: edit a feed/adapter → `bun script/test/nav-backtest.ts --window w1-1d --mode report` → diff against the committed fixture.
5. Modes table (report / snapshot / assert) with exit codes.
6. File map: `backtest-blocks.json` (windows + metrics config), `NavBacktest.fork.t.sol` (sweep + metric registry), `script/test/nav-backtest.ts` (driver), `nav-timeseries.json` (fixture).
7. Caveats: adapters/pools/feeds that didn't exist at the oldest blocks revert per-point and are recorded as `error`, not fatal; smoke mode (2 points) runs inside the normal integration suite so the harness can't rot; the full sweep is on-demand only. (If a Merkl rewards adapter returns to the repo, add its root-mismatch-reads-0 caveat here.)
8. Windows, accounts & metrics: windows are named pinned ranges (`{fromBlock,toBlock,blockStep,metrics,accounts}`); `w1-1d` is default. Selected accounts must remain enabled in `accounts.json`.
9. Extending to other chains: add the chain under the window in `backtest-blocks.json` + `--chain <id>` on the driver + rerun snapshot.

- [x] **Step 2: Verify the how-to content**

Run:

```bash
for s in "nav-backtest.ts" "--mode report" "--mode snapshot" "--mode assert" "w1-1d" "nav-timeseries.json" "backtest-blocks.json" "rollFork" "blockStep" "metrics" "accounts" "bun"; do
  grep -q -- "$s" docs/howto/nav-backtest.md || echo "MISSING: $s"
done
```

Expected: no `MISSING:` lines.

- [x] **Step 3: Add the CLAUDE.md index row**

In the "Read this first by intent" table add:

```markdown
| Run or refresh the historical NAV backtest (hourly NAV over a pinned window, oracle-change diffing) | `docs/howto/nav-backtest.md` |
```

Verify: `grep -q "nav-backtest.md" CLAUDE.md && echo OK`
Expected: `OK`.

- [x] **Step 4: Commit**

```bash
git add docs/howto/nav-backtest.md CLAUDE.md
git commit -m "docs: NAV backtest how-to + index entry"
```

---

### Task 8: Final verification

**Files:** none (verification only)

- [x] **Step 1: Full local gates**

Run: `forge build && forge test --no-match-path "*fork*"`
Expected: both pass.

- [x] **Step 2: Integration suite still green (includes the NavBacktest smoke sweep)**

Run: `FOUNDRY_PROFILE=slow forge test --match-path "test/integration/*" --threads 1 -vv 2>&1 | grep -E "\[PASS\]|\[FAIL\]|Suite"`
Expected: all `[PASS]`, including `NavBacktest::test_backtestSweep` in smoke mode.

- [ ] **Step 3: Push and watch CI**

Run: `git push && gh run watch`
Expected: all jobs green on Blacksmith runners; Build job warm-cache time ≤ ~4 min.
