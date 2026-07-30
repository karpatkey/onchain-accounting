// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Vm} from "forge-std/Vm.sol";

/// @title UndispatchedAdapterGuard
/// @author KPK
/// @notice Fails the integration harness when a balance adapter that is `enabled: true` in deploy config is not
///         resolved by `IntegrationFromConfigBase._deployBalanceAdapter`, unless the omission is DECLARED with a
///         reason in `test/integration/undispatched-adapters.json`.
/// @dev **The hole this closes.** The harness resolves adapter names through a hand-maintained
///      `_equals(name, …)` chain whose fall-through is `return address(0)`. An enabled adapter that falls off
///      that chain was skipped with a `console2.log` line and nothing else — not deployed, not registered on
///      NAVCalculator, and never reached by `_configureMetaInstances` (it iterates DEPLOYED adapters, which is
///      why a skipped meta-adapter does not trip the deliberately un-`try`/`catch`'d `addMetaInstances` call).
///      The same file's asset price-feed path already fails CLOSED on an unrecognised feed type; only the
///      balance-adapter path failed open. Seven adapters were sitting in that state when this was written.
/// @dev **Why it is worse than a missing test.** An adapter that reports 0 because it was never deployed is
///      indistinguishable from an account that holds nothing. So `refresh-integration-snapshot.sh` regenerates
///      `expected.<chainId>.navUsd8dp` from a computation that omits those positions and **pins the
///      under-report as the expected value** — after which every later run agrees with the wrong number. The
///      omission is only harmless while the omitted positions are worth 0; for the assisted family that ends
///      the moment its coordinate caches are fed.
/// @dev **Both directions are enforced**, which is what keeps the declaration honest rather than decorative:
///      an undeclared skip fails ({UndispatchedAdapterNotDeclared}), a declaration with an empty reason fails
///      ({UndispatchedAdapterReasonMissing}), and a declaration that no longer corresponds to a real skip also
///      fails ({UndispatchedAdapterDeclarationStale}) — so adding a dispatch entry forces deleting its
///      declaration in the same change and a stale exemption cannot quietly accumulate. Mandatory-reason
///      shape mirrors `RateFeedGuard`'s `$UNVERIFIABLE` + `descriptionUnverifiableReason` pair: a deliberate
///      gap is declared and reviewable instead of being inferred from silence.
library UndispatchedAdapterGuard {
    /// @notice Declaration file: `{ "chains": { "<chainId>": { "<AdapterName>": "<reason>" } } }`. Keys
    ///         beginning with `$` are prose, not adapter names, and are ignored (same convention as
    ///         `ConfigReader`). The `chains` wrapper and the leading-dot path form mirror `accounts.json`
    ///         (`.chains.<id>.forkBlock`), which is the JSON-path shape already proven against forge here.
    string internal constant DECLARATION_PATH = "test/integration/undispatched-adapters.json";

    /// @notice An enabled adapter fell off the dispatch chain and is not declared. Either add its dispatch
    ///         branch, or declare it with a reason.
    error UndispatchedAdapterNotDeclared(uint256 chainId, string name);

    /// @notice Declared, but with an empty reason — which would make a deliberate omission indistinguishable
    ///         from someone silencing the guard.
    error UndispatchedAdapterReasonMissing(uint256 chainId, string name);

    /// @notice Declared but not actually skipped: the dispatch entry now exists, or the adapter was disabled in
    ///         config. Delete the declaration.
    error UndispatchedAdapterDeclarationStale(uint256 chainId, string name);

    /// @notice Validates `skipped` against the on-disk declaration for `chainId`.
    /// @param skipped The names `_deployBalanceAdapter` returned `address(0)` for, in config order.
    function check(Vm vm, uint256 chainId, string[] memory skipped) internal view {
        checkAgainst(vm, vm.readFile(DECLARATION_PATH), chainId, skipped);
    }

    /// @notice {check} against declaration JSON supplied directly, so the mechanism is testable without
    ///         mutating the tracked file.
    function checkAgainst(Vm vm, string memory json, uint256 chainId, string[] memory skipped) internal view {
        string memory chainPath = string.concat(".chains.", vm.toString(chainId));
        string[] memory declared =
            vm.keyExists(json, chainPath) ? _withoutDollarKeys(vm.parseJsonKeys(json, chainPath)) : new string[](0);

        // 1. Every skip must be declared, and declared WITH a reason.
        for (uint256 i; i < skipped.length; ++i) {
            if (!_contains(declared, skipped[i])) revert UndispatchedAdapterNotDeclared(chainId, skipped[i]);
            string memory reason = vm.parseJsonString(json, string.concat(chainPath, ".", skipped[i]));
            if (bytes(reason).length == 0) revert UndispatchedAdapterReasonMissing(chainId, skipped[i]);
        }

        // 2. Every declaration must correspond to a real skip, so the list cannot go stale silently.
        for (uint256 i; i < declared.length; ++i) {
            if (!_contains(skipped, declared[i])) revert UndispatchedAdapterDeclarationStale(chainId, declared[i]);
        }
    }

    function _contains(string[] memory haystack, string memory needle) private pure returns (bool) {
        bytes32 h = keccak256(bytes(needle));
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(bytes(haystack[i])) == h) return true;
        }
        return false;
    }

    /// @dev Drops `$`-prefixed prose keys so a per-chain `$comment` can never be mistaken for an adapter.
    function _withoutDollarKeys(string[] memory keys) private pure returns (string[] memory out) {
        uint256 n;
        for (uint256 i; i < keys.length; ++i) {
            if (!_startsWithDollar(keys[i])) ++n;
        }
        out = new string[](n);
        uint256 k;
        for (uint256 i; i < keys.length; ++i) {
            if (!_startsWithDollar(keys[i])) out[k++] = keys[i];
        }
    }

    function _startsWithDollar(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        return b.length != 0 && b[0] == bytes1("$");
    }
}
