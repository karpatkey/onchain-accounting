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
///         (default w1-30d; BLOCKS_FILE unset/empty => 2-point smoke sweep near the
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
        string memory window = vm.envOr("BACKTEST_WINDOW", string("w1-30d"));
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

        // Optional per-window account allowlist. When present, only these
        // addresses are evaluated; all other chain-enabled accounts are skipped.
        // Smoke mode (no blocks file) always evaluates every chain-enabled account.
        string memory accountsKey = string.concat(base, ".accounts");
        if (vm.keyExists(json, accountsKey)) {
            string[] memory configured = json.readStringArray(accountsKey);
            require(configured.length > 0, "backtest: empty accounts array");
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
            unchecked { ++i; }
        }

        // When a window configures an account allowlist, filter to only those
        // addresses. Every configured address must appear in the final set
        // (duplicate, unknown, and chain-disabled entries are caught here).
        if (_configuredAccounts.length > 0) {
            address[] memory filtered = new address[](_backtestAccounts.length);
            uint256 count;
            for (uint256 a = 0; a < _backtestAccounts.length; a++) {
                if (_isConfiguredAccount(_backtestAccounts[a])) {
                    filtered[count] = _backtestAccounts[a];
                    count++;
                }
            }
            require(
                count == _configuredAccounts.length,
                "backtest: configured account missing or disabled"
            );
            // Compact in-place.
            assembly { mstore(filtered, count) }
            _backtestAccounts = filtered;
        }
        require(_backtestAccounts.length > 0, "backtest: no enabled accounts for chain");
    }

    function _isConfiguredAccount(address account) internal view returns (bool) {
        for (uint256 i = 0; i < _configuredAccounts.length; i++) {
            if (_configuredAccounts[i] == account) return true;
        }
        return false;
    }
}