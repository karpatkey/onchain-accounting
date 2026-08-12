// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title PositionLabelsProbeCoverage
/// @author KPK
/// @notice Tripwire for the configuration-view probe convention: a NEW non-meta balance adapter must not become
///         registered on NAVCalculator without someone deciding what `positionLabels("")` should answer for it.
/// @dev The convention itself is asserted per adapter, in each adapter's own unit-test suite
///      (`test_positionLabels_emptyProbe_*`). Twelve hand-written copies enforce nothing about a THIRTEENTH
///      adapter: it would ship registered, answer the probe with whatever it happens to answer, and `forge test`
///      would stay green — the same silent drop-off from a configuration view that those tests exist to prevent.
///
///      This test closes that by pinning the registered non-meta adapter set itself. It reads the deploy configs
///      under `script/config/deployments/` (the only place deployed addresses live) and asserts the union of
///      non-meta `balanceAdapters` keys across every chain is exactly the set below. Enforcing at the deployment
///      config — rather than at the source tree — is deliberate on two counts: it fires at the moment an adapter
///      actually becomes registered and therefore actually reaches a configuration view, and `script/` is already
///      inside `fs_permissions` (`src/` and `test/` are not, so a source-tree walk would need foundry.toml
///      widened repo-wide for one test).
///
///      Meta adapters are excluded: a configuration view enumerates them through
///      `getMetaInstances` + `positionLabels(instance)` and never needs the empty probe.
///
///      **When this test fails**, do not just append the new name. Add a `test_positionLabels_emptyProbe_*` case
///      to that adapter's own suite first, deciding which of the two answers is correct for it:
///        - breadcrumb is positionId-INDEPENDENT -> the probe returns the full constant breadcrumb, and that is
///          the whole answer: the shape is already reachable from a configuration view;
///        - breadcrumb is derived per positionId -> the probe returns `[]`, which on its own is indistinguishable
///          from a broken adapter. **Implement {IPositionEnumerable} as well** so the shapes are reachable: its
///          `positionIds()` lists them and its ERC-165 bit marks the `[]` as deliberate. `CapBalanceAdapter` is
///          the worked example — see its `test_positionIds_*` cases.
///
///      Only the second branch needs the extra interface, and it is a real decision either way — an adapter whose
///      shapes are discovered per ACCOUNT (a per-account coordinate cache) has no account-independent answer and
///      must implement neither. That is decided per adapter, not per family.
contract PositionLabelsProbeCoverageTest is Test {
    /// @dev Every non-meta adapter key that currently appears in any `script/config/deployments/<chainId>.json`.
    ///      Keep sorted by family, then alphabetically, so a diff to this list is easy to read in review.
    function _expectedNonMetaAdapters() internal pure returns (string[] memory names) {
        names = new string[](12);
        // Plain (src/balances/BalanceAdapters/)
        names[0] = "AaveUmbrella";
        names[1] = "AaveV3SafetyModule";
        names[2] = "Cap";
        names[3] = "ERC20Default";
        names[4] = "EthenaCooldown";
        names[5] = "KelpWithdrawalQueue";
        names[6] = "LidoWithdrawalQueue";
        names[7] = "SparkLend";
        names[8] = "StaderWithdrawalQueue";
        // Assisted (src/balances/AssistedBalanceAdapters/)
        names[9] = "EtherFiWithdrawalQueueAssisted";
        names[10] = "NexusMutualStakingPoolsAssisted";
        names[11] = "StakeWiseV3ExitQueueAssisted";
    }

    function test_everyRegisteredNonMetaAdapterHasAProbeDecision() public view {
        string[] memory found = _collectRegisteredNonMetaAdapters();
        string[] memory expected = _expectedNonMetaAdapters();

        // Direction 1: nothing registered on any chain is missing from the list above. This is the one that
        // catches adapter #13 — the whole point of the test.
        for (uint256 i; i < found.length; ++i) {
            assertTrue(
                _has(expected, found[i]),
                string.concat(
                    "Balance adapter '",
                    found[i],
                    "' is deployed but is not in PositionLabelsProbeCoverage. Add a "
                    "test_positionLabels_emptyProbe_* case to its own test suite deciding what "
                    'positionLabels("") must answer, then add it here. See this contract\'s NatSpec.'
                )
            );
        }

        // Direction 2: the list has not rotted past adapters that were removed from every chain's config.
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(
                _has(found, expected[i]),
                string.concat(
                    "Balance adapter '",
                    expected[i],
                    "' is listed in PositionLabelsProbeCoverage but is no longer deployed on any chain. "
                    "Remove it here (and retire its probe test) if the adapter is genuinely gone."
                )
            );
        }
    }

    /// @notice Union of non-meta `balanceAdapters` keys across every per-chain deployments file.
    /// @dev A key is treated as meta iff it contains "Meta" — the same convention `04_DeployBalanceAdapters` and
    ///      `06_Configure` use to route an adapter to `addMetaBalanceAdapter` rather than `addBalanceAdapters`.
    function _collectRegisteredNonMetaAdapters() internal view returns (string[] memory) {
        string memory dir = string.concat(vm.projectRoot(), "/script/config/deployments");
        VmSafe.DirEntry[] memory entries = vm.readDir(dir);

        string[] memory acc = new string[](64);
        uint256 n;

        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir) continue;
            if (!_endsWith(entries[i].path, ".json")) continue;

            string memory json = vm.readFile(entries[i].path);
            // A chain that has not been configured yet has no `balanceAdapters` object at all.
            if (!vm.keyExistsJson(json, ".balanceAdapters")) continue;

            string[] memory keys = vm.parseJsonKeys(json, ".balanceAdapters");
            for (uint256 k; k < keys.length; ++k) {
                if (_contains(keys[k], "Meta")) continue;
                // A key with a blank or placeholder VALUE is a slot reserved for an adapter that is not deployed
                // yet, not a registered adapter. `04_DeployBalanceAdapters` needs the key to pre-exist because
                // `ConfigReader.writeAdapterAddress` writes straight through `vm.writeJson` at a computed pointer
                // with no create-if-absent path — so reserving the slot is REQUIRED, and this tripwire must not
                // read the reservation as a registration. Asked through `ConfigReader._readAddrOrZero`, which is
                // the same code the deploy path uses, so "placeholder" has exactly one definition in this repo.
                if (ConfigReader._readAddrOrZero(vm, json, string.concat(".balanceAdapters.", keys[k])) == address(0)) {
                    continue;
                }
                if (_has3(acc, n, keys[k])) continue;
                require(n < acc.length, "PositionLabelsProbeCoverage: accumulator overflow");
                acc[n++] = keys[k];
            }
        }

        string[] memory out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = acc[i];
        }
        return out;
    }

    //
    // String helpers (Solidity has no native contains / endsWith)
    //

    function _has(string[] memory haystack, string memory needle) private pure returns (bool) {
        return _has3(haystack, haystack.length, needle);
    }

    function _has3(string[] memory haystack, uint256 len, string memory needle) private pure returns (bool) {
        bytes32 h = keccak256(bytes(needle));
        for (uint256 i; i < len; ++i) {
            if (keccak256(bytes(haystack[i])) == h) return true;
        }
        return false;
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function _endsWith(string memory s, string memory suffix) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory x = bytes(suffix);
        if (x.length > b.length) return false;
        for (uint256 i; i < x.length; ++i) {
            if (b[b.length - x.length + i] != x[i]) return false;
        }
        return true;
    }
}
