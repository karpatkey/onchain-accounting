// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title PositionLabelsProbeCoverage
/// @author KPK
/// @notice Tripwire for the configuration-view probe convention: a NEW non-meta balance adapter must not become
///         registered on NAVCalculator without someone deciding what `positionLabels("")` should answer for it.
/// @dev The convention itself is asserted per adapter, in each adapter's own unit-test suite
///      (`test_positionLabels_emptyProbe_*`), of which there are twelve today. Hand-written copies enforce nothing
///      about the NEXT adapter: it would ship registered, answer the probe with whatever it happens to answer, and
///      `forge test` would stay green — the same silent drop-off from a configuration view they exist to prevent.
///
///      This test closes that by pinning the non-meta adapter set itself, against TWO sources:
///        - `script/config/deployments/` — what is actually DEPLOYED (the only place deployed addresses live);
///        - `script/config/contracts-deployment-config/balance-adapters/` — what is ENABLED to deploy next.
///      Enforcing at config rather than at the source tree is deliberate: it fires at the moment an adapter
///      actually becomes registered or scheduled to be, and therefore actually reaches a configuration view. (An
///      earlier revision gave a second reason — that `src/` is outside `fs_permissions` — which is simply false:
///      foundry.toml grants `{ access = "read", path = "src" }`. The first reason is the real one and stands alone.)
///
///      ⚠️ **Reading BOTH sources is what makes a green result mean something.** Keyed on the deployment record
///      alone, this test passed throughout the `Cap` -> `CapStablecoin`/`CapSavings` split purely because
///      `deployments/1.json` still held the pre-split `Cap` — green on a stale record, not on agreement with the
///      tree, and unable to accept the new names until `04` had run. The deploy-config arm fires at the moment the
///      author changes the config, which is the moment they are in a position to add the probe decision.
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
///          `positionIds()` lists them and its ERC-165 bit marks the `[]` as deliberate. The Cap leg adapters are
///          the worked example — see the `test_positionIds_*` cases in
///          `test/balances/BalanceAdapters/cap/CapStablecoinBalanceAdapter.t.sol`. (This used to point at
///          `CapBalanceAdapter.t.sol`, which no longer exists: the combined adapter was split one-per-leg.)
///
///      Only the second branch needs the extra interface, and it is a real decision either way — an adapter whose
///      shapes are discovered per ACCOUNT (a per-account coordinate cache) has no account-independent answer and
///      must implement neither. That is decided per adapter, not per family.
contract PositionLabelsProbeCoverageTest is Test {
    /// @dev Every non-meta adapter key that is DEPLOYED (present in a `script/config/deployments/<chainId>.json`)
    ///      or ENABLED to deploy (in a `contracts-deployment-config/balance-adapters/<chainId>.json`). Both, not
    ///      just the first — which is why `Cap` and its two successors all appear here at once during the split.
    ///      Keep sorted by family, then alphabetically, so a diff to this list is easy to read in review.
    function _expectedNonMetaAdapters() internal pure returns (string[] memory names) {
        names = new string[](15);
        // Plain (src/balances/BalanceAdapters/)
        names[0] = "AaveUmbrella";
        names[1] = "AaveV3SafetyModule";
        names[2] = "Cap"; // retired CONTRACT at a still-live ADDRESS; see {_configuredNonMetaAdapters}
        names[3] = "CapSavings";
        names[4] = "CapStablecoin";
        names[5] = "ERC20Default";
        names[6] = "EthenaCooldown";
        names[7] = "KelpWithdrawalQueue";
        names[8] = "LidoWithdrawalQueue";
        names[9] = "SparkLend";
        names[10] = "StaderWithdrawalQueue";
        // Assisted (src/balances/AssistedBalanceAdapters/)
        names[11] = "EtherFiWithdrawalQueueAssisted";
        names[12] = "NexusMutualStakingPoolsAssisted";
        names[13] = "StakeWiseV3ExitQueueAssisted";
        // Attested (src/balances/AttestedBalanceAdapters/)
        names[14] = "MerklRewards";
    }

    /// @notice Adapter keys that are ENABLED in the per-chain deploy config — what `04` is configured to deploy next.
    /// @dev **Direction 1b keys on this set, and direction 2 on the union of it and the deployment record. Together
    ///      that is what lets the expected list track a rename at the moment the RENAME happens rather than at the
    ///      moment the DEPLOY happens.**
    ///
    ///      Before this, the list could only be updated after `04` ran: adding `CapStablecoin`/`CapSavings` while
    ///      they existed solely in config failed direction 2 ("no longer deployed on any chain"), and removing
    ///      `Cap` failed direction 1, because `deployments/1.json` still holds the pre-split `Cap` at a live
    ///      address. So the test was green on a stale deployment record rather than on agreement with the tree —
    ///      passing for a reason unrelated to whether anyone had made a probe decision for the new adapters.
    ///
    ///      Keying on the union fixes that without weakening either direction: an adapter that is neither deployed
    ///      NOR configured still fails direction 2 as rot, and anything deployed still fails direction 1 if it has
    ///      no probe decision.
    ///
    ///      ⚠️ **This REDUCES the deploy-day chore; it does not retire it, and an earlier revision of this note
    ///      claimed it did.** The two ADDITIONS are now free — `CapStablecoin`/`CapSavings` are already accepted via
    ///      the configured arm, so `04` writing their addresses changes nothing here. The REMOVAL is not: `Cap` is
    ///      in the deployment record and in no deploy config, so the moment `04` drops it from the record it is in
    ///      neither set and direction 2 fails on it. Deleting the `Cap` line at that point is correct and is the
    ///      whole remaining chore. It cannot be pre-empted — removing it now fails direction 1, because `Cap` is
    ///      still deployed today.
    function _configuredNonMetaAdapters() internal view returns (string[] memory) {
        string memory dir =
            string.concat(vm.projectRoot(), "/script/config/contracts-deployment-config/balance-adapters");
        VmSafe.DirEntry[] memory entries = vm.readDir(dir);

        string[] memory acc = new string[](64);
        uint256 n;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir) continue;
            if (!_endsWith(entries[i].path, ".json")) continue;
            // Same readDir/readFile race as the deployments walk below — sibling tests write synthetic
            // per-chain config files here and delete them. See the long note at that call site.
            if (!vm.exists(entries[i].path)) continue;
            string memory json = vm.readFile(entries[i].path);
            string[] memory keys = vm.parseJsonKeys(json, "$");
            for (uint256 k; k < keys.length; ++k) {
                // `$`-prefixed keys are comments, not adapters. Every other reader of these files filters them —
                // `ConfigReader._filterDollar`, `deployer_balances.py`, `preflight_config.py`, `chainlib.py` — and
                // without it the FIRST top-level `$comment` added to a balance-adapter config makes
                // `vm.parseJsonBool(".$comment.enabled")` revert this whole suite with an opaque cheatcode error.
                if (bytes(keys[k]).length != 0 && bytes(keys[k])[0] == "$") continue;
                // ⚠️ NOT `_contains(key, "Meta")`. That is the routing convention for the DEPLOYMENT RECORD, where
                // meta adapters live under the same `balanceAdapters` object as plain ones and the substring is the
                // only discriminator. Here the FILE already tells us: this directory is the plain-adapter deploy
                // config, and `meta-balance-adapters/` is a sibling. Reusing the substring test silently exempted
                // `StakeWiseV3Vault_MetaVault` — a PLAIN adapter whose key happens to contain "Meta" — from the
                // very arm this function feeds. It was `enabled: false` (since removed from config),
                // so the gap was latent, not live.
                if (_has3(acc, n, keys[k])) continue;
                // Only ENABLED entries: a disabled stub is not "configured to deploy".
                if (!vm.parseJsonBool(json, string.concat(".", keys[k], ".enabled"))) continue;
                require(n < acc.length, "PositionLabelsProbeCoverage: configured accumulator overflow");
                acc[n++] = keys[k];
            }
        }
        string[] memory out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = acc[i];
        }
        return out;
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

        // Direction 1b: nothing CONFIGURED to deploy is missing from the list either. Direction 1 alone only sees
        // the deployment record, so a renamed adapter would go unnoticed until `04` ran — which is exactly how the
        // pre-split `Cap` -> `CapStablecoin`/`CapSavings` rename could have reached deploy day with no probe
        // decision. This arm fires at the moment the CONFIG changes, which is the moment the author is looking.
        string[] memory configuredNow = _configuredNonMetaAdapters();
        for (uint256 i; i < configuredNow.length; ++i) {
            assertTrue(
                _has(expected, configuredNow[i]),
                string.concat(
                    "Balance adapter '",
                    configuredNow[i],
                    "' is enabled in a balance-adapter deploy config but is not in PositionLabelsProbeCoverage. "
                    "Add a test_positionLabels_emptyProbe_* case to its own test suite deciding what "
                    'positionLabels("") must answer, then add it here.'
                )
            );
        }

        // Direction 2: the list has not rotted past adapters that are neither DEPLOYED nor CONFIGURED to deploy.
        // The union is load-bearing — see {_configuredNonMetaAdapters}. Keying on `found` alone made this test
        // green on a stale deployment record and forced the expected list to lag every rename until deploy day.
        string[] memory configured = _configuredNonMetaAdapters();
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(
                _has(found, expected[i]) || _has(configured, expected[i]),
                string.concat(
                    "Balance adapter '",
                    expected[i],
                    "' is listed in PositionLabelsProbeCoverage but is neither deployed on any chain NOR enabled "
                    "in any chain's balance-adapter deploy config. "
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
            // ⚠️ **RE-CHECK EXISTENCE: `readDir` and `readFile` are not atomic, and sibling tests write here.**
            // `AssetKindRegistryGuards` and `AssetKindRegistryWiring` create and then delete
            // `deployments/9876543xx.json` for synthetic chain ids — debris this repo documents by name — so a
            // full-suite run could list an entry that no longer exists by the time it is read, and
            // `vm.readFile` then reverts with a bare "No such file or directory". That failure looked exactly
            // like a real coverage gap, passed in isolation, and cost a diagnosis. Skipping a vanished entry is
            // safe here: this function computes a UNION over chains to check against an allowlist, and a file
            // that exists for microseconds inside another test's fixture is not a deployment record.
            if (!vm.exists(entries[i].path)) continue;

            string memory json = vm.readFile(entries[i].path);
            // A chain that has not been configured yet has no `balanceAdapters` object at all.
            if (!vm.keyExistsJson(json, ".balanceAdapters")) continue;

            string[] memory keys = vm.parseJsonKeys(json, ".balanceAdapters");
            for (uint256 k; k < keys.length; ++k) {
                if (_contains(keys[k], "Meta")) continue;
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
