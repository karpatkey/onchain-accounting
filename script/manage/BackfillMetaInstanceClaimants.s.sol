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
    error NothingToDo();
    error CoordinateHeldTwice(bytes32 coordinate, address first, address second);
    error ClaimantSlotWrong(bytes32 coordinate, address expected, address got);
    error BackfillIncomplete(address adapter, bytes32 coordinate);
    error InstanceCountChanged(address adapter, uint256 before_, uint256 after_);

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
        if (pending == 0) revert NothingToDo();

        // --- round-trip each adapter's unclaimed coordinates ---------------------------------------------
        vm.startBroadcast();
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
        console2.log("done. every governed coordinate now names its adapter.");
    }
}
