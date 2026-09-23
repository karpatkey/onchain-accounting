// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title BackfillMetaInstanceClaimants
/// @author KPK
/// @notice Populates `_claimant` for every meta-instance coordinate a LIVE proxy already governs.
/// @dev **Why this is mandatory, not a nicety.** The claimant map is new storage, so on an upgraded proxy it
///      starts EMPTY while `_metaInstances` is full. Every pre-existing coordinate therefore reads as
///      unclaimed, and the guards built on the map — `_claim`'s dual-claim check and the inclusion gate —
///      pass for exactly the coordinates that are already governed. Until this runs, the upgraded
///      implementation is STRICTLY WEAKER on existing state than the O(adapters x instances) scan it
///      replaced: that scan read `_metaInstances` directly and so covered pre-existing coordinates, whereas
///      the map covers only what the new code itself wrote. Shipping the upgrade without running this is a
///      regression, and the runbook must order the two.
///
///      **Mechanism: existing selectors only, zero new bytecode.** `NAVCalculator` has 173 bytes of EIP-170
///      margin, which will not carry a backfill entry point, and an initializer-based migration could not be
///      chunked or resumed — one out-of-gas at 125 coordinates and the whole upgrade transaction fails.
///      `removeMetaInstances` followed by `addMetaInstances` round-trips each coordinate through `_release`
///      and `_claim`, which are the only writers of the map, so the backfill uses precisely the production
///      paths rather than a parallel one that could drift from them.
///
///      **The window between the two calls.** They are separate transactions; no atomicity is available here,
///      as in every other script in this family. Between them a coordinate that is a registered asset is
///      re-armed on the default adapter and then disarmed again — so it is reported by the default adapter
///      rather than by the meta adapter, a different reporter but never two. A coordinate that is NOT a
///      registered asset (Morpho market ids, Balancer pool ids) is reported by nobody for that window: an
///      under-report, the direction this repo licenses everywhere. Run with `--slow` so the pair lands in
///      order, and re-run after any halt — every step is gated on live state, so a partial run resumes.
///
///      **The precondition that is checked rather than assumed.** If two registered adapters already hold the
///      same coordinate in live state — the issue #335 double-count — then backfilling adapter-by-adapter
///      would let the first claim it and the second fail mid-batch, stranding that adapter with an EMPTY set
///      and losing its other coordinates. So the script scans for cross-adapter duplicates FIRST and stops,
///      naming the coordinate, rather than discovering it halfway through a broadcast. Measured across the 7
///      configured chains before this landed — 104 coordinates over 40 adapter entries, zero duplicates — so
///      the stop is expected never to fire; it exists because "expected never" is not "cannot".
contract BackfillMetaInstanceClaimants is Script {
    /// @dev Storage slot of `Balances._claimant`, per `script/upgrade/storage-layout/NAVCalculator.json`.
    ///      NOT trusted blind: {_assertSlotIsRight} proves it against live state before the slot is used to
    ///      decide anything, so a layout shift turns into a named revert rather than a silent no-op backfill.
    uint256 internal constant CLAIMANT_SLOT = 109;

    error NotManager(address who);
    error SignerNotManager(address signer);
    error SetLostAndUnrecoverable(address adapter, uint256 expected, uint256 onChain);
    error NothingToDo();
    error CoordinateHeldTwice(bytes32 coordinate, address first, address second);
    error ClaimantSlotWrong(bytes32 coordinate, address expected, address got);
    error BackfillIncomplete(address adapter, bytes32 coordinate);
    error InstanceCountChanged(address adapter, uint256 before_, uint256 after_);

    /// @dev Durable record of every adapter's instance set, written BEFORE the first broadcast.
    ///
    ///      Required for correctness, not convenience. The round-trip below is `removeMetaInstances` then
    ///      `addMetaInstances` — two separate transactions with no atomicity available. If the ADD does not
    ///      land (out of gas, RPC, nonce — this script family has precedent for a trailing transaction dying),
    ///      the adapter's on-chain set is now EMPTY. A re-run that reads only the chain then sees
    ///      `set.length == 0`, skips the adapter, computes `pending == 0`, passes a post-condition loop that
    ///      iterates nothing, and reverts `NothingToDo` — i.e. reports the backfill COMPLETE while every
    ///      position that adapter governed has silently vanished from NAV on a live chain.
    ///
    ///      An earlier version of this docstring claimed "every step is gated on live state, so a partial run
    ///      resumes". That was false in the one way that matters: the removal destroys the state the resume
    ///      reads. The snapshot is the state the resume reads instead.
    ///
    ///      TWO ORDERING RULES make the snapshot actually work, both of which a first attempt got wrong:
    ///
    ///      1. Recovery outranks `NothingToDo`. `pending` counts coordinates that are IN a set and unclaimed,
    ///         so a coordinate an interrupted run removed counts toward NOTHING. Computing `pending` first and
    ///         reverting on zero left the recovery block unreachable in exactly its own scenario.
    ///      2. The file is never deleted at the end of `run()`. Under `forge script` the body runs as LOCAL
    ///         SIMULATION and Foundry sends the recorded transactions only after `run()` returns — so a delete
    ///         there removes the recovery file before any transaction has been broadcast, and the
    ///         post-condition loop is checking simulated state. It is dropped at the TOP of a later run
    ///         instead, where the chain state is confirmed.
    function _snapshotPath(uint256 chainId) internal pure returns (string memory) {
        return string.concat("script/manage/.backfill-claimants-", vm.toString(chainId), ".json");
    }

    function _claimantOf(address nav, bytes32 coord) internal view returns (address) {
        return address(uint160(uint256(vm.load(nav, keccak256(abi.encode(coord, CLAIMANT_SLOT))))));
    }

    /// @dev Proves `CLAIMANT_SLOT` against a coordinate whose claimant is KNOWN, which is only possible after
    ///      at least one round-trip. A wrong slot would otherwise make every `_claimantOf` read zero, the
    ///      script would report "nothing claimed" forever, and a re-run would silently redo the whole backfill
    ///      while reporting success.
    function _assertSlotIsRight(address nav, address adapter, bytes32 coord) internal view {
        address got = _claimantOf(nav, coord);
        if (got != adapter) revert ClaimantSlotWrong(coord, adapter, got);
    }

    function run() external {
        uint256 chainId = block.chainid;
        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        address sender = ConfigReader.readChainConfig(vm, chainId).manager;
        if (!NAVCalculator(nav).hasRole(keccak256("MANAGER"), sender)) revert NotManager(sender);

        address[] memory adapters = NAVCalculator(nav).getAllAdapters();

        // --- precondition: no coordinate is already held by two adapters -------------------------------
        for (uint256 i; i < adapters.length; ++i) {
            bytes32[] memory a = NAVCalculator(nav).getMetaInstances(adapters[i]);
            for (uint256 x; x < a.length; ++x) {
                for (uint256 j = i + 1; j < adapters.length; ++j) {
                    bytes32[] memory b = NAVCalculator(nav).getMetaInstances(adapters[j]);
                    for (uint256 y; y < b.length; ++y) {
                        if (a[x] == b[y]) revert CoordinateHeldTwice(a[x], adapters[i], adapters[j]);
                    }
                }
            }
        }

        // --- the snapshot is read FIRST, because recovery must outrank `NothingToDo` ----------------------
        // `pending` counts coordinates that are IN a set and unclaimed. A coordinate an interrupted run
        // removed and failed to re-add is in NO set, so it counts toward nothing: computing `pending` first
        // and reverting `NothingToDo` on zero made the recovery block below UNREACHABLE in exactly the
        // situation it exists for, with a valid snapshot sitting on disk. Read, recover, then decide.
        string memory snapPath = _snapshotPath(chainId);
        bool haveSnap = vm.exists(snapPath);
        string memory snapJson = haveSnap ? vm.readFile(snapPath) : "";

        // How many coordinates a previous run lost, measured against the snapshot rather than the chain.
        uint256 lost;
        if (haveSnap) {
            for (uint256 i; i < adapters.length; ++i) {
                string memory k = string.concat('.sets["', vm.toString(adapters[i]), '"]');
                if (!vm.keyExistsJson(snapJson, k)) continue;
                uint256 want = vm.parseJsonBytes32Array(snapJson, k).length;
                uint256 have = NAVCalculator(nav).getMetaInstances(adapters[i]).length;
                if (want > have) lost += want - have;
            }
        }

        // --- what is left to do --------------------------------------------------------------------------
        uint256 pending;
        uint256 total;
        for (uint256 i; i < adapters.length; ++i) {
            bytes32[] memory set = NAVCalculator(nav).getMetaInstances(adapters[i]);
            total += set.length;
            for (uint256 x; x < set.length; ++x) {
                if (_claimantOf(nav, set[x]) != adapters[i]) ++pending;
            }
        }
        console2.log("=== backfilling meta-instance claimants ===");
        console2.log("chain            :", chainId);
        console2.log("nav              :", nav);
        console2.log("coordinates total:", total);
        console2.log("coordinates to do:", pending);
        console2.log("coordinates lost :", lost);

        // NOTHING TO DO means nothing pending AND nothing lost. This is also the ONLY place the snapshot may
        // be deleted: here the chain state is CONFIRMED — it is what a previous run's broadcast actually
        // landed — whereas anything after `startBroadcast()` in this function is still local simulation.
        if (pending == 0 && lost == 0) {
            if (haveSnap) {
                console2.log("every governed coordinate is claimed; dropping the recovery snapshot");
                vm.removeFile(snapPath);
            }
            revert NothingToDo();
        }

        // RECOVERY FIRST: any adapter whose snapshot set is longer than its on-chain set lost coordinates to
        // an interrupted run. Restore them before doing any new work, and do it OUTSIDE the round-trip so a
        // recovery run never removes anything.
        if (haveSnap) {
            for (uint256 i; i < adapters.length; ++i) {
                // Bracket notation: the key is an address literal, which is not a bare JSON-path identifier.
                string memory key = string.concat('.sets["', vm.toString(adapters[i]), '"]');
                if (!vm.keyExistsJson(snapJson, key)) continue;
                bytes32[] memory want = vm.parseJsonBytes32Array(snapJson, key);
                bytes32[] memory have = NAVCalculator(nav).getMetaInstances(adapters[i]);
                if (have.length >= want.length) continue;
                console2.log("RECOVERING lost instance set for", adapters[i]);
                bytes32[] memory missing = new bytes32[](want.length - have.length);
                uint256 m;
                for (uint256 x; x < want.length; ++x) {
                    bool present;
                    for (uint256 y; y < have.length; ++y) {
                        if (have[y] == want[x]) {
                            present = true;
                            break;
                        }
                    }
                    if (!present) missing[m++] = want[x];
                }
                if (m == 0) continue;
                assembly {
                    mstore(missing, m)
                }
                vm.broadcast();
                NAVCalculator(nav).addMetaInstances(adapters[i], missing);
                if (NAVCalculator(nav).getMetaInstances(adapters[i]).length != want.length) {
                    revert SetLostAndUnrecoverable(
                        adapters[i], want.length, NAVCalculator(nav).getMetaInstances(adapters[i]).length
                    );
                }
            }
        }

        // Snapshot the (now-restored) sets. Built by string concatenation rather than forge's serializeJson
        // helpers: those accumulate into a named object across calls, and the exact shape they emit for a
        // nested map of arrays is easy to get subtly wrong for a file whose only job is disaster recovery.
        string memory body = "";
        for (uint256 i; i < adapters.length; ++i) {
            bytes32[] memory set = NAVCalculator(nav).getMetaInstances(adapters[i]);
            if (set.length == 0) continue;
            string memory arr = "";
            for (uint256 x; x < set.length; ++x) {
                arr = string.concat(arr, x == 0 ? "" : ",", "\"", vm.toString(set[x]), "\"");
            }
            body = string.concat(
                body, bytes(body).length == 0 ? "" : ",", "\"", vm.toString(adapters[i]), "\":[", arr, "]"
            );
        }
        vm.writeFile(snapPath, string.concat("{\"chainId\":", vm.toString(chainId), ",\"sets\":{", body, "}}"));

        // --- round-trip each adapter's unclaimed coordinates ---------------------------------------------
        vm.startBroadcast();

        // The configured manager is not necessarily the signer — `startBroadcast()` takes no argument, so
        // forge uses whatever the CLI supplied. Check the real one before the first write, or a wrong
        // `--account` reverts partway through and leaves an adapter's set half round-tripped.
        (, address signer,) = vm.readCallers();
        if (!NAVCalculator(nav).hasRole(keccak256("MANAGER"), signer)) revert SignerNotManager(signer);

        for (uint256 i; i < adapters.length; ++i) {
            address adapter = adapters[i];
            bytes32[] memory set = NAVCalculator(nav).getMetaInstances(adapter);
            if (set.length == 0) continue;

            // Only the coordinates that still need it, so a resumed run does not churn finished ones.
            bytes32[] memory todo = new bytes32[](set.length);
            uint256 n;
            for (uint256 x; x < set.length; ++x) {
                if (_claimantOf(nav, set[x]) != adapter) todo[n++] = set[x];
            }
            if (n == 0) continue;
            assembly {
                mstore(todo, n)
            }

            NAVCalculator(nav).removeMetaInstances(adapter, todo);
            NAVCalculator(nav).addMetaInstances(adapter, todo);

            // The slot assumption is load-bearing for the resume logic — prove it the first time a
            // coordinate's claimant is known, and fail loudly rather than silently re-running forever.
            _assertSlotIsRight(nav, adapter, todo[0]);

            if (NAVCalculator(nav).getMetaInstances(adapter).length != set.length) {
                revert InstanceCountChanged(adapter, set.length, NAVCalculator(nav).getMetaInstances(adapter).length);
            }
        }
        vm.stopBroadcast();

        // --- post-condition: every coordinate now names its adapter --------------------------------------
        for (uint256 i; i < adapters.length; ++i) {
            bytes32[] memory set = NAVCalculator(nav).getMetaInstances(adapters[i]);
            for (uint256 x; x < set.length; ++x) {
                if (_claimantOf(nav, set[x]) != adapters[i]) revert BackfillIncomplete(adapters[i], set[x]);
            }
        }
        // THE SNAPSHOT IS DELIBERATELY KEPT. Deleting it here would run during local simulation: under
        // `forge script` the body executes first and Foundry only sends the recorded transactions after
        // `run()` returns. So the post-condition loop above is checking SIMULATED state, and a delete here
        // would remove the recovery file before a single transaction had been broadcast — precisely when a
        // partially-landed broadcast needs it. An earlier version did exactly that, which defeated the point
        // of taking a snapshot at all.
        //
        // The file is dropped instead at the TOP of a later run, where the chain state is confirmed: once
        // nothing is pending and nothing is lost, the backfill demonstrably landed and the snapshot is
        // redundant. Re-running is the completion check.
        console2.log("done (simulated). Re-run after the broadcast confirms: it clears the snapshot when");
        console2.log("every governed coordinate names its adapter, and restores anything the broadcast lost.");
    }
}
