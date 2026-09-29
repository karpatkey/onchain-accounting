// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title ClearDormantMetaInstances
/// @author KPK
/// @notice Clears the dormant meta-instance set left on the superseded PolygonStakingMeta predecessor
///         `0x59039882…`, in the one order that never double-counts.
/// @dev **Status: a verified no-op, kept as a guarded record.** Its one target set is already empty, so every
///      run reverts `NothingToDo` before broadcasting anything. It is kept (not deleted) because CI and the
///      migration docs invoke it as that completion check, and its guards document the only safe manual order
///      on a pre-upgrade implementation. Post-upgrade no cleanup script is needed at all: re-registering any
///      deregistered adapter wipes its residue (`DormantInstanceCleanup.fork.t.sol`,
///      `test_postUpgrade_reRegisteringResidueNeverRevives`).
/// @dev **The residue, and why it still exists after the fix.** This PR makes BOTH removal paths clear
///      `metaInstances`, so no NEW residue can be created — but the clearing lives in the NAVCalculator
///      implementation, and the residue below was created by the PRE-UPGRADE implementation that is still
///      live on the proxy this script targets. The structural fix is present; it is simply not retroactive,
///      which is what this script is for. `removeBalanceAdapter` did not clear `metaInstances`, and
///      the 2026-08-26 swap predated the `removeMetaInstances` step now in `SwapMetaAdapter`. So the
///      deregistered predecessor advertised validator 192. **Measured 2026-09-24: this particular set is now
///      CLEARED (0 coordinates), so this script has nothing left to do on its hardcoded address and reverts
///      `NothingToDo`.** `residue_audit.py` found eleven OTHER deregistered adapters still carrying dormant
///      sets on mainnet, so the class is not gone — but this PR's registration wipe makes them unrevivable,
///      which is a better fix than cleaning them one hardcoded address at a time. It is inert while
///      deregistered — but
///      `addMetaBalanceAdapter` APPENDS and accepts an empty list, so a single re-registration of that
///      superseded address revives the coordinate alongside the live adapter and NAV sums both:
///      +$11,375.92 on ACCOUNT_11, with no health flag, because both readings are well-formed.
///
///      **Why five transactions.** The set cannot be cleared directly: `removeMetaInstances` reverts
///      `InvalidBalanceAdapter` for an unregistered adapter, so the adapter must be registered first —
///      which is the dangerous act. The ordering below is the only one where the two adapters are never
///      both reporting. Every intermediate state is SAFE, but they are not all under-reports.
///
///      **The step-2 state differs by implementation.** On the pre-upgrade implementation step 2 leaves the
///      residue as the ONLY reporter (the pre-upgrade tests in `DormantInstanceCleanup.fork.t.sol` pin that).
///      On this PR's implementation `addMetaBalanceAdapter` clears an adapter's set before seeding it, so
///      step 2 wipes the residue itself: step 3 finds nothing to remove and is skipped, and the window after
///      step 2 holds ZERO reporters — pinned on the upgraded fork by
///      `test_postUpgrade_reRegisteringResidueNeverRevives`. Zero reporters is an under-report, the licensed
///      direction, and every post-condition below still holds. Never two reporters at once is the invariant;
///      "always missing" is not, which is the direction this repo prefers everywhere. Registering the predecessor FIRST would
///      double-count, and that is revert-probed in `DormantInstanceCleanup.fork.t.sol`.
///
///      Rehearsed against mainnet state before broadcasting: the sequence never exceeds one reporter,
///      and the naive ordering was confirmed to produce two.
///
///      Run with `--slow` so the five transactions land in order.
contract ClearDormantMetaInstances is Script {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    address constant LIVE = 0x5144b5855e753Fa6E2BBac95Cc880A73e1eec187;
    address constant RESIDUE = 0x590398827f2a2709e80DF9BD5C7D02BD51FC51fD;
    bytes32 constant V192 = bytes32(uint256(uint160(0x97997023aAB1D6b9760538Eb621bF10cfCD84868)));

    error WrongChain(uint256 chainId);
    error NotManager(address who);
    error NothingToDo();

    /// @notice Post-condition failures. Custom errors rather than `require` strings, per the repo rule.
    error ResidueSetNotCleared();
    error LiveLostItsInstance();
    error LiveHoldsWrongCoordinate();
    error ResidueStillRegistered();
    error PreconditionLiveNotRegistered();
    error PreconditionResidueRegistered();
    error DoubleCount(uint256 reporters);

    function _one(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    function _addrs(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    /// @dev Whether `adapter` is registered AND currently advertises V192. Every step below is gated on this
    ///      rather than on the run's starting state, which is what makes re-running safe from any halt point.
    function _holds(address adapter) internal view returns (bool) {
        if (!NAVCalculator(NAV).isAdapterRegistered(adapter)) return false;
        bytes32[] memory inst = NAVCalculator(NAV).getMetaInstances(adapter);
        for (uint256 i; i < inst.length; ++i) {
            if (inst[i] == V192) return true;
        }
        return false;
    }

    /// @dev Residue's set is non-empty. Distinct from `_holds` because a residue set can outlive its
    ///      registration, which is the whole reason this script exists.
    function _residueHoldsCoord() internal view returns (bool) {
        return NAVCalculator(NAV).getMetaInstances(RESIDUE).length != 0;
    }

    function _reporters() internal view returns (uint256 n) {
        address[2] memory c = [LIVE, RESIDUE];
        for (uint256 i; i < 2; ++i) {
            if (!NAVCalculator(NAV).isAdapterRegistered(c[i])) continue;
            bytes32[] memory inst = NAVCalculator(NAV).getMetaInstances(c[i]);
            for (uint256 j; j < inst.length; ++j) {
                if (inst[j] == V192) ++n;
            }
        }
    }

    function run() external {
        if (block.chainid != 1) revert WrongChain(block.chainid);
        address sender = ConfigReader.readChainConfig(vm, 1).manager;
        if (!NAVCalculator(NAV).hasRole(keccak256("MANAGER"), sender)) revert NotManager(sender);

        // LIVE must exist; everything else is a state this script can resume from.
        if (!NAVCalculator(NAV).isAdapterRegistered(LIVE)) revert PreconditionLiveNotRegistered();

        // Already finished? Then there is nothing to do and saying so is not an error condition.
        if (!NAVCalculator(NAV).isAdapterRegistered(RESIDUE) && _holds(LIVE) && !_residueHoldsCoord()) {
            revert NothingToDo();
        }

        console2.log("=== clearing dormant meta-instance set ===");
        console2.log("residue      :", RESIDUE);
        console2.log("live         :", LIVE);
        console2.log("reporters now:", _reporters());

        // EVERY STEP IS CONDITIONAL, so an interrupted run is resumed by re-running rather than being
        // stranded. These are five independent broadcasts with no atomicity available — the repo has
        // precedent for a trailing transaction in this family dying out of gas — and the previous version
        // gated all five behind preconditions that accepted only the INITIAL state. A halt after step 1 then
        // failed to re-run because the live instance was already absent; after step 2 because RESIDUE was
        // registered; after step 4 with `NothingToDo`. Worse, a halt after step 2 leaves the SUPERSEDED
        // predecessor as sole reporter, and the natural manual repair — run step 5 alone — produces TWO
        // reporters, the +$11,375.92 double-count.
        //
        // The ordering invariant is unchanged and is what keeps every intermediate state safe: never two
        // reporters at once. Re-running from any point preserves it, because each step now asserts only its
        // own precondition.
        vm.startBroadcast();
        if (_holds(LIVE)) NAVCalculator(NAV).removeMetaInstances(LIVE, _one(V192)); // 1
        if (!NAVCalculator(NAV).isAdapterRegistered(RESIDUE)) {
            NAVCalculator(NAV).addMetaBalanceAdapter(RESIDUE, new bytes32[](0)); // 2
        }
        if (_holds(RESIDUE)) NAVCalculator(NAV).removeMetaInstances(RESIDUE, _one(V192)); // 3
        if (NAVCalculator(NAV).isAdapterRegistered(RESIDUE)) {
            NAVCalculator(NAV).removeBalanceAdapters(_addrs(RESIDUE)); // 4
        }
        if (!_holds(LIVE)) NAVCalculator(NAV).addMetaInstances(LIVE, _one(V192)); // 5
        vm.stopBroadcast();

        // [SIMULATED] — under `forge script` the body runs first and Foundry sends the recorded transactions
        // only after `run()` returns, so every check below reads the SIMULATION. With five independent
        // broadcasts and no atomicity available, a run where step 5 dies on chain still prints
        // "done. reporters: 1" while zero reporters are live. Worth keeping (it catches a sequence that cannot
        // succeed at all), but `verify()` is what witnesses the result.
        _assertFinalState();
        console2.log("done (SIMULATED). residue set cleared, live restored");
        console2.log("NOW RUN: forge script ... --sig \"verify()\" --rpc-url $RPC   (reads confirmed state)");
    }

    /// @notice Confirms the end state against CONFIRMED chain state. Run after the broadcast; re-runnable.
    /// @dev Same assertions as the tail of {run}, but read-only and outside any broadcast, so they witness what
    ///      actually landed rather than what the simulation predicted. This is the check that would have caught
    ///      a step-5 failure leaving the coordinate governed by nobody.
    function verify() external view {
        if (block.chainid != 1) revert WrongChain(block.chainid);
        _assertFinalState();
        console2.log("verify: OK - exactly one reporter, residue cleared and deregistered");
    }

    /// @dev The five post-conditions, shared by {run} (simulated) and {verify} (confirmed).
    function _assertFinalState() internal view {
        uint256 n = _reporters();
        if (n != 1) revert DoubleCount(n);
        if (NAVCalculator(NAV).getMetaInstances(RESIDUE).length != 0) revert ResidueSetNotCleared();
        // MEMBERSHIP, not cardinality, and not index 0 either. Both of the checks this replaces were brittle
        // for independent reasons:
        //   - `length != 1` hardcodes ONE instance, but `LIVE` is the Polygon staking meta-adapter and the
        //     2026-08-29 decision was to keep it GOVERNED — one instance per validator. Registering a second
        //     validator would make this read-only, advertised-as-re-runnable `verify()` revert on a chain whose
        //     residue is correctly cleared.
        //   - `[0] != V192` pins V192 to index 0, but `removeMetaInstances` removes by SWAP-AND-POP, so any
        //     unrelated add/remove around it can move V192 to another index with nothing wrong at all.
        // What actually matters is that the live adapter still holds V192 and that there is exactly one
        // reporter — the latter is already asserted above by `_reporters()`.
        bytes32[] memory live = NAVCalculator(NAV).getMetaInstances(LIVE);
        if (live.length == 0) revert LiveLostItsInstance();
        bool holdsV192;
        for (uint256 i; i < live.length; ++i) {
            if (live[i] == V192) {
                holdsV192 = true;
                break;
            }
        }
        if (!holdsV192) revert LiveHoldsWrongCoordinate();
        if (NAVCalculator(NAV).isAdapterRegistered(RESIDUE)) revert ResidueStillRegistered();
    }
}
