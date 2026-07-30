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

    /// @notice A window lists a metric name with no branch in `_evalMetric`.
    error BacktestUnknownMetric(string metric);
    /// @notice The blocks file has no entry for the requested window/chain pair.
    error BacktestWindowNotFound(string window, uint256 chainId);
    /// @notice `toBlock` must be strictly after `fromBlock` and the step must be non-zero.
    error BacktestBadWindowBounds(uint256 fromBlock, uint256 toBlock, uint256 blockStep);
    /// @notice The window declares a `metrics` key holding an empty array.
    error BacktestEmptyMetrics(string window);
    /// @notice The window declares an `accounts` key holding an empty array.
    error BacktestEmptyAccounts(string window);
    /// @notice A configured account is absent from accounts.json or disabled for this chain.
    error BacktestConfiguredAccountUnavailable(address account, uint256 chainId);
    /// @notice The window's `accounts` allowlist lists the same address twice.
    error BacktestDuplicateConfiguredAccount(address account);
    /// @notice accounts.json enables no account for the backtested chain.
    error BacktestNoEnabledAccounts(uint256 chainId);
    /// @notice `fromBlock` must be non-zero: 0 is the base class's "fork block unset" sentinel.
    error BacktestZeroFromBlock(string window, uint256 chainId);
    /// @notice A tracked stack address lost its code across `vm.rollFork` — the sweep would emit
    ///         fabricated `ERROR:` points that look like protocol instability. See `_makeStackPersistent`.
    error BacktestStackNotPersistent(address missing, uint256 blockNumber);
    /// @notice The single sweep transaction is close to exhausting its gas budget; the next point
    ///         would OOG and be recorded as a revert. Shorten the window or raise the profile limit.
    error BacktestGasBudgetExhausted(uint256 blockNumber, uint256 gasRemaining, uint256 worstPointGas);
    /// @notice Every point in the sweep failed. That is a broken harness, not an unstable protocol.
    error BacktestAllPointsFailed(uint256 points);

    bytes32 internal constant METRIC_NAV = keccak256("nav");
    bytes32 internal constant METRIC_NAV_STALE_ASSETS = keccak256("nav-stale-assets");

    /// @dev A point costs ~25-31M gas today (25.5M avg in CI, 31.1M worst observed locally). Stop
    ///      while at least this multiple of the worst observed point cost is still available, so the
    ///      guard fires before an OOG can be mistaken for data.
    uint256 internal constant GAS_HEADROOM_POINTS = 3;

    /// @dev Cap on a recorded revert reason, so one pathological string cannot dominate the output.
    uint256 internal constant MAX_REASON_BYTES = 120;

    uint256[] internal _blocks;
    string[] internal _metrics;
    address[] internal _backtestAccounts;
    address[] internal _configuredAccounts;

    /// @dev Sweep bookkeeping: emitted points and how many of them were `ERROR:` rows.
    uint256 internal _pointsEmitted;
    uint256 internal _pointsFailed;
    uint256 internal _worstPointGas;

    function setUp() public {
        _chainId = vm.envOr("BACKTEST_CHAIN", uint256(1));

        string memory accountsJson = vm.readFile(ACCOUNTS_JSON);
        _forkNetwork = accountsJson.readString(string.concat(".chains.", vm.toString(_chainId), ".alchemyNetwork"));

        _loadWindow(accountsJson);
        _loadAccounts(accountsJson);

        // Fail fast on unknown metric names before paying for the fork.
        for (uint256 m = 0; m < _metrics.length; m++) {
            if (!_isKnownMetric(keccak256(bytes(_metrics[m])))) revert BacktestUnknownMetric(_metrics[m]);
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
            if (b > 0) {
                vm.rollFork(_blocks[b]);
                // A stack address that lost its code would make every later point revert, and those
                // reverts are recorded as data. Assert liveness once per roll so a harness failure is
                // loud instead of masquerading as a reverting protocol.
                _assertStackPersistent(_blocks[b]);
            }
            for (uint256 a = 0; a < _backtestAccounts.length; a++) {
                for (uint256 m = 0; m < _metrics.length; m++) {
                    // The whole sweep is one transaction, so its gas budget caps the window. Stop
                    // deliberately while there is headroom: an OOG would otherwise land in the
                    // per-point catch and be emitted as an indistinguishable `ERROR:` row.
                    uint256 gasBefore = gasleft();
                    if (_worstPointGas != 0 && gasBefore < _worstPointGas * GAS_HEADROOM_POINTS) {
                        revert BacktestGasBudgetExhausted(_blocks[b], gasBefore, _worstPointGas);
                    }
                    _emitPoint(_blocks[b], _backtestAccounts[a], _metrics[m]);
                    uint256 used = gasBefore - gasleft();
                    if (used > _worstPointGas) _worstPointGas = used;
                }
            }
        }
        // Individual reverting points are the stability signal and must never fail the run. A sweep
        // in which EVERY point reverted carries no signal at all — it means the harness is broken
        // (missing persistence, wrong fork, dead RPC), so fail rather than hand the driver a
        // uniform wall of errors it would happily pin as a baseline.
        if (_pointsEmitted > 0 && _pointsFailed == _pointsEmitted) revert BacktestAllPointsFailed(_pointsEmitted);
    }

    /// @dev Every address `_makeStackPersistent` marked must still hold code after a roll.
    function _assertStackPersistent(uint256 blockNumber) internal view {
        address[] memory tracked = _persistentStackAddresses();
        for (uint256 i = 0; i < tracked.length; i++) {
            if (tracked[i].code.length == 0) revert BacktestStackNotPersistent(tracked[i], blockNumber);
        }
    }

    // -------------------------------------------------------------------
    // Metric registry: to snapshot another function, add a METRIC_* hash,
    // a branch in _evalMetric + _isKnownMetric, and list the name in the
    // window's `metrics` array in backtest-blocks.json. No other changes.
    // -------------------------------------------------------------------

    function _isKnownMetric(bytes32 h) internal pure returns (bool) {
        return h == METRIC_NAV || h == METRIC_NAV_STALE_ASSETS;
    }

    /// @dev Evaluates one metric for one account at the fork's current block.
    ///      Must only revert for truly unknown metrics (guarded in setUp);
    ///      on-chain failures are caught by the caller.
    ///
    ///      `nav` records NAV.value only. A stale or feedless asset is priced at 0 and summed as a
    ///      zero-value leg (src/prices/PriceFeedLib.sol), so a feed breaching its heartbeat shows up
    ///      as an ordinary value drop with nothing marking it as an oracle event. Pair `nav` with
    ///      `nav-stale-assets` in a window's `metrics` to record that count alongside the value.
    function _evalMetric(bytes32 h, address account) internal view returns (string memory) {
        if (h == METRIC_NAV) {
            return vm.toString(nav.getAccountNav(account, QUOTE_USD).value);
        }
        if (h == METRIC_NAV_STALE_ASSETS) {
            INAVCalculator.NAV memory n = nav.getAccountNav(account, QUOTE_USD);
            return vm.toString(n.stalePriceAssets.length);
        }
        revert BacktestUnknownMetric(vm.toString(h));
    }

    function _emitPoint(uint256 blockNum, address account, string memory metric) internal {
        string memory result;
        _pointsEmitted++;
        try this.evalMetricExternal(keccak256(bytes(metric)), account) returns (string memory v) {
            result = v;
        } catch Error(string memory reason) {
            // A plain-string revert. Sanitise it: `result` is emitted into a `|`-delimited,
            // newline-delimited channel, so an embedded newline would truncate the row and let a
            // crafted reason forge a following `BACKTEST|…` row the driver accepts as real data.
            result = string.concat("ERROR:revert:", _sanitise(reason));
            _pointsFailed++;
        } catch Panic(uint256 code) {
            result = string.concat("ERROR:panic:", vm.toString(code));
            _pointsFailed++;
        } catch (bytes memory raw) {
            // Distinguish the buckets that used to collapse into one string: a custom error (this
            // repo reverts with custom errors everywhere, so this is the common case) carries a
            // 4-byte selector, while out-of-gas and other EVM errors return nothing at all.
            result = raw.length >= 4
                ? string.concat("ERROR:custom:", vm.toString(bytes.concat(bytes4(raw))))
                : string.concat("ERROR:empty:", vm.toString(raw.length));
            _pointsFailed++;
        }
        console2.log(
            string.concat(
                "BACKTEST|",
                vm.toString(_chainId),
                "|",
                vm.toString(blockNum),
                "|",
                vm.toString(block.timestamp),
                "|", // fork's timestamp at this point — free, no ts->block mapping
                vm.toString(account),
                "|",
                metric,
                "|",
                result
            )
        );
    }

    /// @dev External self-call wrapper so try/catch can catch reverts from any metric probe.
    function evalMetricExternal(bytes32 h, address account) external view returns (string memory) {
        return _evalMetric(h, account);
    }

    /// @dev Makes a revert reason safe for the `|`-delimited, newline-delimited BACKTEST channel:
    ///      replaces the field separator and anything non-printable (crucially newlines, which would
    ///      truncate the row and let the remainder pose as a new BACKTEST row) and caps the length.
    function _sanitise(string memory reason) internal pure returns (string memory) {
        bytes memory raw = bytes(reason);
        uint256 len = raw.length > MAX_REASON_BYTES ? MAX_REASON_BYTES : raw.length;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            bytes1 c = raw[i];
            out[i] = (c < 0x20 || c > 0x7e || c == "|") ? bytes1("?") : c;
        }
        return string(out);
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
        if (!vm.keyExists(json, base)) revert BacktestWindowNotFound(window, _chainId);

        uint256 fromBlock = json.readUint(string.concat(base, ".fromBlock"));
        uint256 toBlock = json.readUint(string.concat(base, ".toBlock"));
        uint256 step = json.readUint(string.concat(base, ".blockStep"));
        if (toBlock <= fromBlock || step == 0) revert BacktestBadWindowBounds(fromBlock, toBlock, step);
        // 0 is the base class's "fork block unset" sentinel: it would silently fork at accounts.json's
        // pinned block, label the first point `0`, and then roll BACKWARDS to a block predating the
        // deploy — mislabelled data rather than an error.
        if (fromBlock == 0) revert BacktestZeroFromBlock(window, _chainId);
        for (uint256 b = fromBlock; b < toBlock; b += step) {
            _blocks.push(b);
        }
        _blocks.push(toBlock); // toBlock always included as the final point

        if (vm.keyExists(json, string.concat(base, ".metrics"))) {
            delete _metrics;
            string[] memory configured = json.readStringArray(string.concat(base, ".metrics"));
            if (configured.length == 0) revert BacktestEmptyMetrics(window);
            for (uint256 m = 0; m < configured.length; m++) {
                _metrics.push(configured[m]);
            }
        }

        // Optional per-window account allowlist. When present, only these
        // addresses are evaluated; all other chain-enabled accounts are skipped.
        // Smoke mode (no blocks file) always evaluates every chain-enabled account.
        string memory accountsKey = string.concat(base, ".accounts");
        if (vm.keyExists(json, accountsKey)) {
            string[] memory configured = json.readStringArray(accountsKey);
            if (configured.length == 0) revert BacktestEmptyAccounts(window);
            for (uint256 a = 0; a < configured.length; a++) {
                _configuredAccounts.push(vm.parseAddress(configured[a]));
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
                if (_contains(enabled, _chainId)) {
                    _backtestAccounts.push(vm.parseAddress(addrStr));
                }
            }
            unchecked {
                ++i;
            }
        }

        // When a window configures an account allowlist, evaluate exactly those addresses. Build the
        // set FROM the configured list and check each entry individually: comparing cardinalities
        // instead would let a duplicate in accounts.json (which mixes checksummed and lowercase
        // spellings) mask a configured address that is missing or disabled for this chain.
        if (_configuredAccounts.length > 0) {
            address[] memory filtered = new address[](_configuredAccounts.length);
            for (uint256 c = 0; c < _configuredAccounts.length; c++) {
                address configured = _configuredAccounts[c];
                if (!_isChainEnabledAccount(configured)) {
                    revert BacktestConfiguredAccountUnavailable(configured, _chainId);
                }
                for (uint256 seen = 0; seen < c; seen++) {
                    if (filtered[seen] == configured) revert BacktestDuplicateConfiguredAccount(configured);
                }
                filtered[c] = configured;
            }
            _backtestAccounts = filtered;
        }
        if (_backtestAccounts.length == 0) revert BacktestNoEnabledAccounts(_chainId);
    }

    /// @dev Is `account` present in accounts.json AND enabled for the backtested chain?
    function _isChainEnabledAccount(address account) internal view returns (bool) {
        for (uint256 i = 0; i < _backtestAccounts.length; i++) {
            if (_backtestAccounts[i] == account) return true;
        }
        return false;
    }
}
