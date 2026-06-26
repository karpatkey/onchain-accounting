// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {IntegrationFromConfigBase} from "test/integration/IntegrationFromConfigBase.fork.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title RefreshIntegrationSnapshot
/// @notice For one chain (passed via env CHAIN_ID), fork at the per-chain `forkBlock`
///         already recorded in test/integration/accounts.json, replay the integration test
///         deploy pipeline (NAV + every enabled price feed + every enabled balance adapter),
///         read the NAV for every account whose `enabledChains` includes this chain, and
///         emit one structured `SNAPSHOT|...` log line per (account, chain) pair to stdout.
///         The shell wrapper (`script/test/refresh-integration-snapshot.sh`) parses those
///         lines and applies them to accounts.json via `jq`. This script does NOT mutate
///         the JSON itself — see ADR 0003 for why we route through stdout + jq instead of
///         using `vm.writeJson` directly.
/// @dev Invoked by `script/test/refresh-integration-snapshot.sh`. The shell script bumps
///      forkBlock with `cast block-number` *before* running this, so the script always sees
///      the latest block.
///
///      Inheriting `IntegrationFromConfigBase` reuses the entire deploy pipeline (~700 lines)
///      without duplication. The base contract extends `Test`; mixing `Script` + `Test` works
///      because both pull cheatcodes from the same forge-std Common module. The script simply
///      avoids using assertions (writes results unconditionally) and Test's auto-discovery of
///      `test_*` methods doesn't apply when invoked via `forge script`.
///
///      Usage:
///        CHAIN_ID=1 forge script script/test/RefreshIntegrationSnapshot.s.sol
contract RefreshIntegrationSnapshot is Script, IntegrationFromConfigBase {
    using stdJson for string;

    function run() public {
        // Resolve which chain to refresh from env (we don't broadcast; we just fork + read).
        string memory chainIdStr = vm.envString("CHAIN_ID");
        require(bytes(chainIdStr).length > 0, "set CHAIN_ID env var");
        _chainId = vm.parseUint(chainIdStr);

        // Resolve the alchemyNetwork string straight from accounts.json so the chain config
        // is the only place chain identity lives.
        string memory json = _readAccountsJson();
        string memory netKey = string.concat(".chains.", vm.toString(_chainId), ".alchemyNetwork");
        require(vm.keyExists(json, netKey), "accounts.json: chain not configured");
        _forkNetwork = json.readString(netKey);

        // _setupAndDeploy reads forkBlock from the same JSON; it forks + deploys + registers.
        _setupAndDeploy();

        _writeNavSnapshotsForCurrentChain();
        _writeNavPositionsForCurrentChain();
    }

    /// @dev Emits one structured line per (account, chain) snapshot. The shell wrapper greps
    ///      these lines and applies them to accounts.json via jq. We do NOT use vm.writeJson
    ///      because its JSONPath array-index handling rewrites the wrong keys in some Foundry
    ///      versions; the grep-then-jq pipeline is portable and unambiguous.
    ///
    ///      Format: SNAPSHOT|<chainId>|<accountIndex>|<accountAddress>|<navUsd8dp>|<sequencerDown>|<stalePriceAssetsCount>
    function _writeNavSnapshotsForCurrentChain() internal view {
        string memory json = _readAccountsJson();

        console2.log("=== Refreshing NAV snapshots for chain", _chainId, "===");
        console2.log("Fork block:", _forkBlock);

        uint256 written;
        uint256 i;
        while (true) {
            string memory base = string.concat(".accounts[", vm.toString(i), "]");
            if (!vm.keyExists(json, base)) break;

            address account = vm.parseAddress(json.readString(string.concat(base, ".address")));
            string memory label = json.readString(string.concat(base, ".label"));
            uint256[] memory enabled = json.readUintArray(string.concat(base, ".enabledChains"));

            if (_contains(enabled, _chainId)) {
                INAVCalculator.NAV memory n = _readUsdNav(account);
                console2.log(label, account);
                console2.log("  navUsd8dp:", n.value);
                console2.log("  stalePriceAssets:", n.stalePriceAssets.length);
                console2.log("  sequencerDown:", n.sequencerDown);
                console2.log(
                    string.concat(
                        "SNAPSHOT|",
                        vm.toString(_chainId),
                        "|",
                        vm.toString(i),
                        "|",
                        vm.toString(account),
                        "|",
                        vm.toString(n.value),
                        "|",
                        n.sequencerDown ? "true" : "false",
                        "|",
                        vm.toString(n.stalePriceAssets.length)
                    )
                );
                ++written;
            }
            unchecked {
                ++i;
            }
        }

        console2.log("Wrote", written, "snapshot line(s) to stdout (parsed by refresh-integration-snapshot.sh).");
    }

    /// @notice Writes per-account position details to test/integration/nav-positions-<chainId>.json.
    ///         The Python comparison report reads this file to show real NAV position breakdowns
    ///         alongside the DeBank data.
    function _writeNavPositionsForCurrentChain() internal {
        string memory outPath = string.concat("test/integration/nav-positions-", vm.toString(_chainId), ".json");
        string memory payload = string.concat(
            '{"chainId":',
            vm.toString(_chainId),
            ',"forkBlock":',
            vm.toString(_forkBlock),
            ',"accounts":',
            _buildPositionDetailsJson(),
            "}"
        );
        vm.writeFile(outPath, payload);
        console2.log("Written NAV positions to", outPath);
    }
}
