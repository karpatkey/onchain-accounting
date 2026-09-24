// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {SafeTxBuilder} from "script/utils/SafeTxBuilder.sol";

/// @title BackfillMetaInstanceClaimants
/// @author KPK
/// @notice Populates `_claimant` for every meta-instance coordinate a LIVE proxy already governs.
/// @dev **Why this is mandatory, though NOT because the upgrade regresses anything.** The claimant map is new
///      storage, so on an upgraded proxy it starts EMPTY while `_metaInstances` is full. Every pre-existing
///      coordinate therefore reads as unclaimed, and the guards built on the map — `_claim`'s dual-claim
///      check and the inclusion gate — pass for exactly the coordinates that are already governed.
///
///      An earlier version of this docstring called that state "STRICTLY WEAKER on existing state than the
///      O(adapters x instances) scan it replaced: that scan read `_metaInstances` directly and so covered
///      pre-existing coordinates". **That is false, and it was the stated justification for the whole
///      script.** The base implementation has no such scan: `_appendInstances`
///      (`git show 451e72ad:src/nav/NAVRegistryLib.sol:427-438`) iterates only the adapter's OWN set, which
///      is exactly what `_claim`'s own-set loop reproduces today. An un-backfilled coordinate is therefore
///      governed precisely as strongly as it is on the live chain right now — the upgrade is not a
///      regression, and shipping it before this script runs is not one either.
///
///      What the backfill actually buys is the CROSS-adapter guarantee, which neither base nor an
///      un-backfilled head has ever had: once the map is populated, `_claim` can refuse a coordinate another
///      adapter already holds, and the inclusion gate can refuse to arm the default adapter for a governed
///      token. That is why the runbook still orders the upgrade, then this, then any new meta-adapter
///      registration — see the ordering note on `plan()`.
///
///      **Mechanism: existing selectors only, zero new bytecode.** `NAVCalculator` has 65 bytes of EIP-170
///      margin, which will not carry a backfill entry point, and an initializer-based migration could not be
///      chunked or resumed — one out-of-gas at 125 coordinates and the whole upgrade transaction fails.
///      `removeMetaInstances` followed by `addMetaInstances` round-trips each coordinate through `_release`
///      and `_claim`, which are the only writers of the map, so the backfill uses precisely the production
///      paths rather than a parallel one that could drift from them.
///
///      **The window between the two calls — and why {plan} exists to delete it.** An earlier version of this
///      docstring said that between them "a coordinate that is a registered asset is re-armed on the default
///      adapter and then disarmed again — a different reporter but never two". **That is also wrong.** It is
///      not re-armed: `_release` gates on `claimant[instance] != adapter` and on an un-backfilled proxy
///      `holder == 0`, so it returns BEFORE reaching `_reincludeIfAsset`
///      (`src/nav/NAVRegistryLib.sol:522-526`, and the library's own comment at `:512-515` says so). The real
///      intermediate state is **zero reporters for every coordinate in the pair**, registered asset or not —
///      an under-report, the direction this repo licenses, but an unbounded one that lasts until the ADD
///      lands and is permanent if it never does.
///
///      That is why {plan} is the production path and {run} is the fallback. {plan} emits the remove and its
///      add as ADJACENT entries in one Safe Transaction Builder batch, which the Safe app wraps in MultiSend,
///      so the pair executes atomically and the window does not exist. {run} broadcasts them as two separate
///      EOA transactions and the window does; use it only where no Safe holds MANAGER, run it with `--slow`
///      so the pair lands in order, and re-run after any halt.
///
///      **The precondition that is checked rather than assumed.** If two registered adapters already hold the
///      same coordinate in live state — the issue #335 double-count — then backfilling adapter-by-adapter
///      would let the first claim it and the second fail mid-batch, stranding that adapter with an EMPTY set
///      and losing its other coordinates. So the script scans for cross-adapter duplicates FIRST and stops,
///      naming the coordinate, rather than discovering it halfway through a broadcast. No duplicate has been
///      observed on the 7 configured chains, so the stop is expected never to fire; it exists because
///      "expected never" is not "cannot".
///
///      An earlier revision quantified that as "104 coordinates over 40 adapter entries". **That figure is
///      dropped rather than restated, because it is not reproducible:** parsing
///      `nav-config/meta-balance-adapters/*.json` gives 154 or 163 governed coordinates depending on how
///      `enabled: false` entries are counted, and a live read gave 142. Three disagreeing numbers mean the
///      count is not something this docstring can assert. It does not bear on correctness — every scan here is
///      driven by live `getMetaInstances` reads, never by a count — which is why an unverifiable figure had no
///      business being stated as a measurement.
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

    /// @dev Membership, which is what every comparison in the recovery path actually needs. Sets here are at
    ///      most a few dozen coordinates, so the linear scan is irrelevant; using lengths as a proxy for it is
    ///      what made total loss invisible and made the recovery allocation panic.
    function _contains(bytes32[] memory hay, bytes32 needle) internal pure returns (bool) {
        for (uint256 i; i < hay.length; ++i) {
            if (hay[i] == needle) return true;
        }
        return false;
    }

    /// @notice The coordinates in `want` that are absent from `have` — the set an interrupted run must restore.
    /// @dev EXTRACTED AND PURE so it can be truth-tabled, which is the half of the hardening plan's S3 that did
    ///      not land the first time. Both of this function's predecessors were wrong in ways a table would have
    ///      caught immediately, and both were found by an audit instead:
    ///        - `lost` was computed as `want.length - have.length`, so a set refilled with DIFFERENT coordinates
    ///          (snapshot [c1,c2,c3] vs on-chain [c4,c5,c6]) reported ZERO lost, and the caller then deleted the
    ///          recovery snapshot while reporting success.
    ///        - the restore array was SIZED `want.length - have.length`, which equals `|want \ have|` only when
    ///          `have` is a subset of `want`; otherwise the fill ran past the end and panicked 0x32.
    ///      Sizing at `want.length` is the upper bound and cannot be short.
    /// @param want The snapshotted set, taken before any write.
    /// @param have The set currently on chain.
    /// @return missing Exactly the members of `want` not present in `have`, in `want` order.
    function missingFrom(bytes32[] memory want, bytes32[] memory have) public pure returns (bytes32[] memory missing) {
        bytes32[] memory buf = new bytes32[](want.length);
        uint256 m;
        for (uint256 x; x < want.length; ++x) {
            if (!_contains(have, want[x])) buf[m++] = want[x];
        }
        missing = new bytes32[](m);
        for (uint256 i; i < m; ++i) {
            missing[i] = buf[i];
        }
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

    /// @dev If two registered adapters already hold the same coordinate in live state — the issue #335
    ///      double-count — then backfilling adapter-by-adapter would let the first claim it and the second
    ///      fail, stranding that adapter with an EMPTY set and losing its other coordinates. So both entry
    ///      points scan for cross-adapter duplicates FIRST and stop, naming the coordinate, rather than
    ///      discovering it halfway through a broadcast or shipping it inside a signed Safe batch. See the
    ///      contract docstring for what has and has not been observed on the configured chains — deliberately
    ///      not restated here, so the two cannot drift.
    ///
    ///      SHARED by {plan} and {run} deliberately. Two copies of a precondition are two things to keep in
    ///      step, and the one that matters is whichever path is not being tested.
    ///      PREFETCHED, one `getMetaInstances` call per adapter. The obvious nesting re-reads the `j` side
    ///      inside the `x` loop, which is O(adapters^2 x instances) `eth_call`s — about 2,800 on chain 1's ~40
    ///      adapters against ~142 coordinates, versus ~40 here. This repo has recorded precedent for exactly
    ///      that shape OOM-ing a manage script (#318, `RegisterAssets`, where `ConfigReader` re-read the whole
    ///      per-chain JSON per field), and this function runs in BOTH entry points.
    function _assertNoDuplicateCoordinates(address nav, address[] memory adapters) internal view {
        bytes32[][] memory sets = new bytes32[][](adapters.length);
        for (uint256 i; i < adapters.length; ++i) {
            sets[i] = NAVCalculator(nav).getMetaInstances(adapters[i]);
        }
        for (uint256 i; i < adapters.length; ++i) {
            for (uint256 x; x < sets[i].length; ++x) {
                for (uint256 j = i + 1; j < adapters.length; ++j) {
                    for (uint256 y; y < sets[j].length; ++y) {
                        if (sets[i][x] == sets[j][y]) {
                            revert CoordinateHeldTwice(sets[i][x], adapters[i], adapters[j]);
                        }
                    }
                }
            }
        }
    }

    /// @notice The coordinates in `adapter`'s live set whose claimant is not yet `adapter`.
    /// @dev Shared by both entry points so a resumed run and a regenerated batch select the same work. Returns
    ///      an empty array when the adapter is finished, which both callers treat as "skip".
    function _todoFor(address nav, address adapter) internal view returns (bytes32[] memory todo) {
        bytes32[] memory set = NAVCalculator(nav).getMetaInstances(adapter);
        todo = new bytes32[](set.length);
        uint256 n;
        for (uint256 x; x < set.length; ++x) {
            if (_claimantOf(nav, set[x]) != adapter) todo[n++] = set[x];
        }
        assembly {
            mstore(todo, n)
        }
    }

    /// @notice Emits the backfill as ONE atomic Safe Transaction Builder batch. Broadcasts nothing.
    /// @dev **This is the production path; {run} is the EOA fallback.** Each adapter's `removeMetaInstances`
    ///      is followed IMMEDIATELY by its `addMetaInstances`, closing the zero-reporter window described in
    ///      the contract docstring — provided the batch really does execute as ONE transaction. That also
    ///      removes the reason the recovery snapshot exists: a dead trailing transaction cannot empty a set
    ///      when there is no trailing transaction. This function therefore writes no snapshot.
    ///
    ///      ⚠️ **The atomicity comes from the Safe Transaction Builder app, NOT from anything in this repo.**
    ///      `SafeTxBuilder.writeSafeTx` emits a FLAT LIST of transactions; the app is what wraps a
    ///      multi-transaction import into `multiSend` at signing time. A true single-transaction emitter does
    ///      exist here — `SafeTxBuilder.writeSafeTxViaMultiSend` — but it has no call sites and the repo holds
    ///      no MultiSend address constant, so it cannot be used without supplying one.
    ///
    ///      **So: execute this batch only through the Transaction Builder.** Dispatching the same JSON as
    ///      individual transactions reinstates the window in full, and the adjacency this function is built
    ///      around would then buy nothing. The snapshot being absent makes that failure mode WORSE than {run}'s,
    ///      because there would be no recovery record either.
    ///
    ///      **Ordering, which the batch cannot enforce on its own.** The upgrade may share this batch (put
    ///      `upgradeToAndCall` first — the proxy SLOADs the implementation slot on every call, so later
    ///      entries already run the new code). But any `addMetaBalanceAdapter` for the wallet-yield family
    ///      MUST come after every pair here. Before the map is populated `_claim` cannot see that a
    ///      pre-existing adapter already holds a coordinate, so registering a wallet adapter first can leave
    ///      two adapters emitting a well-formed leg for the same balance with no health flag. Backfilling
    ///      first turns that into a `MetaInstanceClaimedByAnotherAdapter` revert.
    ///
    ///      **The batch is generated against pre-upgrade state, and that is safe.** Everything read here is
    ///      upgrade-invariant: `getMetaInstances` is the same slot and the same getter, and `CLAIMANT_SLOT`
    ///      reads zero on every live proxy because it sits inside the never-written `__balancesGap`. So on an
    ///      un-upgraded chain `_todoFor` simply returns the adapter's whole set, which is the correct work.
    ///
    ///      **Regenerate immediately before signing.** `removeMetaInstances` reverts `MetaInstanceNotFound`
    ///      and `addMetaInstances` reverts `DuplicateMetaInstance`, so a batch that goes stale dies whole
    ///      rather than half-applying — safe, but wasted. Freeze MANAGER activity on the chain between
    ///      generation and execution.
    function plan() external {
        uint256 chainId = block.chainid;
        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        ConfigReader.ChainConfig memory cfg = ConfigReader.readChainConfig(vm, chainId);
        address safe = cfg.securityCouncil;

        address[] memory adapters = NAVCalculator(nav).getAllAdapters();
        _assertNoDuplicateCoordinates(nav, adapters);

        // Two entries per adapter that has work. Sized at the upper bound, then trimmed — the alternative is
        // a second pass over every adapter's set purely to count.
        SafeTxBuilder.Transaction[] memory batch = new SafeTxBuilder.Transaction[](adapters.length * 2);
        uint256 k;
        uint256 coords;
        for (uint256 i; i < adapters.length; ++i) {
            bytes32[] memory todo = _todoFor(nav, adapters[i]);
            if (todo.length == 0) continue;
            coords += todo.length;
            // ADJACENT, in this order. A split between them is the unbounded under-report.
            batch[k++] =
                SafeTxBuilder.call(nav, 0, abi.encodeCall(NAVCalculator.removeMetaInstances, (adapters[i], todo)));
            batch[k++] = SafeTxBuilder.call(nav, 0, abi.encodeCall(NAVCalculator.addMetaInstances, (adapters[i], todo)));
        }
        if (k == 0) revert NothingToDo();
        assembly {
            mstore(batch, k)
        }

        console2.log("=== backfill claimants: Safe batch ===");
        console2.log("chain            :", chainId);
        console2.log("nav              :", nav);
        console2.log("safe             :", safe);
        console2.log("coordinates      :", coords);
        console2.log("transactions     :", k);

        // Not a revert: at plan time the grant may not have happened yet (it is a separate, earlier step), and
        // refusing to emit the batch would make it impossible to prepare one in advance.
        if (!NAVCalculator(nav).hasRole(keccak256("MANAGER"), safe)) {
            console2.log("WARNING: the Safe does NOT hold MANAGER yet - grant it before executing this batch");
        }

        SafeTxBuilder.writeSafeTx(
            vm,
            chainId,
            string.concat(vm.toString(chainId), "-backfill-claimants.json"),
            "Backfill meta-instance claimants",
            "Round-trips every governed coordinate through removeMetaInstances + addMetaInstances to populate "
            "the new _claimant map. Each remove is IMMEDIATELY followed by its add; the pairs MUST stay "
            "adjacent and MUST execute atomically, because between a remove and its add the coordinate is "
            "reported by nobody. Execute BEFORE registering any wallet-yield meta adapter.",
            safe,
            batch
        );
    }

    function run() external {
        uint256 chainId = block.chainid;
        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        address sender = ConfigReader.readChainConfig(vm, chainId).manager;
        if (!NAVCalculator(nav).hasRole(keccak256("MANAGER"), sender)) revert NotManager(sender);

        address[] memory adapters = NAVCalculator(nav).getAllAdapters();

        // --- precondition: no coordinate is already held by two adapters -------------------------------
        _assertNoDuplicateCoordinates(nav, adapters);

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
                // MEMBERSHIP, not cardinality. Comparing lengths made total loss invisible whenever the set
                // had since been refilled with DIFFERENT coordinates: snapshot [c1,c2,c3] against an on-chain
                // [c4,c5,c6] gives want == have, so `lost` stayed 0, `pending` stayed 0, and the branch below
                // deleted the snapshot and reported "every governed coordinate is claimed" — with c1..c3 gone
                // from NAV for good and their only record destroyed by the script that exists to restore them.
                bytes32[] memory wantArr = vm.parseJsonBytes32Array(snapJson, k);
                bytes32[] memory haveArr = NAVCalculator(nav).getMetaInstances(adapters[i]);
                lost += missingFrom(wantArr, haveArr).length;
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

        // --- open the broadcast and validate the REAL signer BEFORE any privileged call ------------------
        // This has to sit above the recovery block, not below it. `vm.readCallers()` only reports the
        // broadcaster once a broadcast is open, so an earlier version opened it just before the round-trip —
        // which left the recovery block's own `addMetaInstances` as a privileged, state-changing call made
        // BEFORE the signer was ever checked. The configured manager is not necessarily the signer
        // (`startBroadcast()` takes no argument; forge uses whatever the CLI supplied), so that check has to
        // precede the first write of either phase.
        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        if (!NAVCalculator(nav).hasRole(keccak256("MANAGER"), signer)) revert SignerNotManager(signer);

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

                // NO LENGTH GATE, and `missing` is sized at the UPPER BOUND. Both were wrong for the same
                // reason: `|want \ have|` equals `want.length - have.length` only when `have` is a SUBSET of
                // `want`. It is not, as soon as a coordinate was re-added by hand or a legitimate config change
                // landed — and then the old allocation was short and the fill panicked 0x32, with no named
                // error and no way to recover short of hand-editing the snapshot. A `have.length >= want.length`
                // skip additionally hid the refilled-with-different-coordinates case entirely.
                // `m == 0` below is the real "nothing to do" test.
                bytes32[] memory missing = missingFrom(want, have);
                if (missing.length == 0) continue;
                console2.log("RECOVERING lost instance set for", adapters[i]);
                NAVCalculator(nav).addMetaInstances(adapters[i], missing);
                bytes32[] memory after_ = NAVCalculator(nav).getMetaInstances(adapters[i]);
                for (uint256 x; x < want.length; ++x) {
                    if (!_contains(after_, want[x])) {
                        revert SetLostAndUnrecoverable(adapters[i], want.length, after_.length);
                    }
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

        // --- round-trip each adapter's unclaimed coordinates (broadcast already open above) --------------
        for (uint256 i; i < adapters.length; ++i) {
            address adapter = adapters[i];
            bytes32[] memory set = NAVCalculator(nav).getMetaInstances(adapter);
            if (set.length == 0) continue;

            // Only the coordinates that still need it, so a resumed run does not churn finished ones. Shared
            // with {plan} so a regenerated batch and a resumed broadcast select identical work.
            bytes32[] memory todo = _todoFor(nav, adapter);
            if (todo.length == 0) continue;

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
