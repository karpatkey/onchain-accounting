// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {IMetaBalanceAdapter} from "../../src/balances/IMetaBalanceAdapter.sol";
import {console2} from "forge-std/console2.sol";

interface IMetaAdapterAssets {
    function underlyingAssetsSupportedForInstances(bytes32[] calldata instances)
        external
        view
        returns (address[] memory);
}

interface INavAdmin {
    function addMetaBalanceAdapter(address adapter, bytes32[] calldata instances) external;
    function removeMetaInstances(address adapter, bytes32[] calldata instances) external;
    function removeBalanceAdapters(address[] calldata adapters) external;
    function getMetaInstances(address adapter) external view returns (bytes32[] memory);
    function isAdapterRegistered(address adapter) external view returns (bool);
}

interface IHasProtocolName {
    function protocolName() external view returns (string memory);
}

interface IPinnedToNav {
    function NAV_CALCULATOR() external view returns (address);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title SwapMetaAdapter
/// @author kpk
/// @notice Replaces an already-registered META balance adapter with its redeployed successor, carrying the
///         instance set across, in the one order that is safe.
/// @dev **Why this exists.** A meta-adapter is immutable, so any change to its code — including something as small
///      as the display string `protocolName()` returns, which resolves through the inlined `ProtocolNames` library —
///      means deploying a new contract and swapping it in. `06_Configure` cannot do it: its deregistration pass
///      reads the `navBalanceAdapters` namespace and so covers PLAIN adapters only, and it has no notion of
///      superseding a meta adapter at all. Doing it by hand is where the danger is.
///
///      **The order is the whole point: REMOVE, then ADD.** Both adapters registered at once means both report the
///      same positions, and NAV double-counts them. That is a silent over-report — the read succeeds, every leg
///      looks well-formed, and the only symptom is a number that is too large. Adding first and removing second
///      leaves that window open for as long as the two transactions are apart; removing first leaves the opposite
///      window, where the position is briefly missing, which is an under-report and the direction this repo
///      prefers everywhere else.
///
///      **⚠️ SUPERSEDED — `removeBalanceAdapters` now CLEARS the instance set itself (issue #335).** This file
///      previously stated in bold that it does not, quoting a `Balances.sol` comment that has since been
///      deleted and asserting that `NAVRegistryLib.removeBalanceAdapter` takes no `_metaInstances`
///      reference — it now does, in both the singular and plural variants. That claim was true when written
///      and was verified on mainnet at the time; it is left visible here rather than deleted so a reader who
///      remembers the old behaviour can see exactly what changed and when.
///
///      Consequence for this script: the explicit clear-before-remove step below is now REDUNDANT rather
///      than load-bearing. It remains harmless — `removeMetaInstances` on a still-registered adapter is
///      valid, and clearing an already-empty set is a no-op — so it is kept as belt-and-braces until this
///      script is next exercised against a live swap. The five-transaction ordering described below is no
///      longer required for NEW removals.
///
///      **Why the residue is not merely untidy.** `addMetaBalanceAdapter` APPENDS
///      (`NAVRegistryLib._appendInstances`) and never clears, and `removeMetaInstances` reverts
///      `InvalidBalanceAdapter` for an unregistered adapter — so a dormant set cannot be cleaned without first
///      re-registering its adapter, and re-registering that adapter with an EMPTY instance list (which
///      `addMetaBalanceAdapter` permits) silently revives the dormant coordinates alongside the live successor.
///      That is a DOUBLE-COUNT — the over-report this script exists to prevent, reintroduced by the cleanup path.
///      Clearing the set while the predecessor is still registered closes it at the source.
///
///      The script then asserts the count round-trips onto the successor AND that the predecessor is left with an
///      empty set, so a swap that silently dropped instances or left residue fails loudly.
///
///      **KNOWN RESIDUE FROM THE FIRST SWAP THIS SCRIPT PERFORMED (2026-08-26), ACCEPTED, NOT CLEANED.**
///      `_metaInstances[0x590398827f2a2709e80DF9BD5C7D02BD51FC51fD]` on mainnet still holds validator 192's
///      coordinate, because that swap ran before the `removeMetaInstances` step above existed. It is INERT: the
///      predecessor is deregistered, so nothing queries it, and `script/config/deployments/1.json` now names the
///      successor — so `06_Configure` iterates config keys, resolves the successor, finds it already registered,
///      and never touches the predecessor. Reviving it takes a deliberate manual re-registration of a superseded
///      address.
///
///      Cleaning it is possible but costs five mainnet transactions and is NOT free of risk, which is why it was
///      weighed rather than done. The only ordering that never double-counts is:
///        1. `removeMetaInstances(successor, [v192])`   — successor keeps registration, reports nothing
///        2. `addMetaBalanceAdapter(predecessor, [])`   — dormant set revives, but it is now the ONLY reporter
///        3. `removeMetaInstances(predecessor, [v192])` — the residue is finally reachable
///        4. `removeBalanceAdapters([predecessor])`     — deregistered, set now genuinely empty
///        5. `addMetaInstances(successor, [v192])`      — restored
///      Steps 1–5 pass through an under-report window and never an over-report one. Re-registering the
///      predecessor FIRST would double-count, which is the trap this whole file exists to avoid.
///
///      Usage — both addresses are passed explicitly rather than derived, because during a swap the deployment
///      record names exactly one of them and which one depends on whether `04` has already run:
///
///      ```
///      OLD_ADAPTER=0x... NEW_ADAPTER=0x... \
///        FOUNDRY_PROFILE=slow forge script script/manage/SwapMetaAdapter.s.sol \
///          --rpc-url $RPC --broadcast --account my-deployer --password-file $PW --slow
///      ```
///
///      MANAGER-gated on the NAV, like every other registration path.
contract SwapMetaAdapter is BaseDeployScript {
    /// @notice Thrown when either address argument is missing.
    error AdapterNotProvided();

    /// @notice Thrown when the outgoing adapter is not actually registered — nothing to swap, and proceeding
    ///         would register the successor alongside whatever else is live.
    error PredecessorNotRegistered(address old);

    /// @notice Thrown when the successor has no code at the given address.
    error SuccessorHasNoCode(address newAdapter);

    /// @notice Thrown when the instance set did not survive the swap.
    error InstanceSetLost(address newAdapter, uint256 expected, uint256 got);

    /// @notice Thrown when the predecessor is left holding a dormant instance set — the revival double-count path.
    error PredecessorResidue(address old, uint256 remaining);

    /// @notice Thrown by `verify()` when BOTH adapters are registered — the double-count state.
    error BothRegistered(address old, address newAdapter);

    /// @notice Thrown by `verify()` when the predecessor survived the swap.
    error PredecessorStillRegistered(address old);

    /// @notice Thrown by `verify()` when the successor never registered.
    error SuccessorNotRegistered(address newAdapter);

    /// @notice Thrown when the successor is not a meta-adapter, so its instance set would never be read.
    error SuccessorNotMetaAdapter(address newAdapter);

    /// @notice The predecessor is registered, but not as a META adapter.
    /// @dev `isAdapterRegistered` answers for BOTH namespaces. Without this, pointing OLD_ADAPTER at a plain
    ///      adapter passes that check, skips the instance-compatibility block (its meta set is empty), and the
    ///      script happily DEREGISTERS an unrelated plain adapter while registering the successor with no
    ///      instances — a silent under-report of everything the plain adapter reported.
    error PredecessorNotMetaAdapter(address old);

    /// @notice The asset comparison could not distinguish the two adapters, so nothing was verified.
    /// @dev Raised for the wallet-yield family, whose `_instanceAssets` returns the coordinate itself.
    ///      Re-run with `SWAP_IDENTITY_CONFIRMED=true` after checking the two protocol names by eye.
    error IdentityCheckVacuous(address oldAdapter, address newAdapter);

    /// @notice Thrown when predecessor and successor do not report the same underlying assets for the carried
    ///         instance set — i.e. they are not the same protocol, and the addresses were probably transposed.
    error AdapterMismatch(address old, address newAdapter);

    /// @notice Thrown when the successor is pinned to a different NAVCalculator than the one being registered on.
    /// @dev It would read `getMetaInstances(address(this))` from the WRONG contract and silently report nothing.
    ///      The MetaBalanceAdapter constructor probe does not cover this — it only checks the NAV answers at all.
    error SuccessorPinnedToDifferentNav(address newAdapter, address pinned, address expected);

    function run() public override {
        uint256 chainId = block.chainid;
        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        INavAdmin navAdmin = INavAdmin(nav);

        address old = vm.envOr("OLD_ADAPTER", address(0));
        address newAdapter = vm.envOr("NEW_ADAPTER", address(0));
        if (old == address(0) || newAdapter == address(0)) revert AdapterNotProvided();
        if (newAdapter.code.length == 0) revert SuccessorHasNoCode(newAdapter);
        if (!navAdmin.isAdapterRegistered(old)) revert PredecessorNotRegistered(old);
        // Registered is not enough: `isAdapterRegistered` answers for the plain namespace too.
        // Fail CLOSED if the predecessor cannot prove it is a meta adapter — a predecessor whose
        // `supportsInterface` reverts or is absent stops the script rather than being swapped blind.
        if (!_isMetaAdapter(old)) revert PredecessorNotMetaAdapter(old);
        // A non-meta successor would leave the carried instances unread. Compute the id, never hardcode it.
        if (!IPinnedToNav(newAdapter).supportsInterface(type(IMetaBalanceAdapter).interfaceId)) {
            revert SuccessorNotMetaAdapter(newAdapter);
        }
        address pinned = IPinnedToNav(newAdapter).NAV_CALCULATOR();
        if (pinned != nav) revert SuccessorPinnedToDifferentNav(newAdapter, pinned, nav);

        // Read the set before touching it; the clear below consumes exactly these coordinates.
        bytes32[] memory instances = navAdmin.getMetaInstances(old);

        // Predecessor and successor must be the same protocol. `isAdapterRegistered(old)` is true for ANY
        // registered adapter, and `protocolName()` cannot be compared — a RENAME is a legitimate reason to swap,
        // and this script's first real use was exactly that. Comparing the underlying assets each reports for the
        // carried coordinates catches a transposed address (say SymbioticVaultsMeta pasted as OLD_ADAPTER) without
        // forbidding a rename: a different protocol answers with different assets, or reverts and is caught below.
        if (instances.length > 0) {
            address[] memory oldAssets = IMetaAdapterAssets(old).underlyingAssetsSupportedForInstances(instances);
            address[] memory newAssets = IMetaAdapterAssets(newAdapter).underlyingAssetsSupportedForInstances(instances);
            if (oldAssets.length != newAssets.length) revert AdapterMismatch(old, newAdapter);
            for (uint256 i = 0; i < oldAssets.length; i++) {
                if (oldAssets[i] != newAssets[i]) revert AdapterMismatch(old, newAdapter);
            }

            // THE CHECK ABOVE IS VACUOUS FOR A WHOLE FAMILY, so say so rather than appear to have verified.
            // The wallet-yield adapters' `_instanceAssets` returns the INSTANCE ITSELF — the coordinate is the
            // token — so every one of the 17 answers `[coordinate]` for any coordinate, and comparing their
            // answers cannot distinguish Lido from Sky. A transposed NEW_ADAPTER inside that family passes
            // silently and re-labels the holding's protocol identity: not a value error, but exactly the
            // misattribution this guard exists to catch, and it is the guard's blind spot rather than its
            // verdict.
            //
            // Detected structurally instead of by naming the family: if the reported assets ARE the
            // coordinates, nothing was verified. `protocolName()` cannot substitute — a RENAME is a
            // legitimate reason to swap, and this script's first real use was one — so the operator confirms
            // instead, with both names logged above for comparison.
            bool vacuous = true;
            for (uint256 i = 0; i < instances.length; i++) {
                if (bytes32(uint256(uint160(oldAssets[i]))) != instances[i]) {
                    vacuous = false;
                    break;
                }
            }
            if (vacuous && !vm.envOr("SWAP_IDENTITY_CONFIRMED", false)) {
                console2.log("The asset comparison cannot tell these two adapters apart:");
                console2.log("  outgoing:", IHasProtocolName(old).protocolName());
                console2.log("  incoming:", IHasProtocolName(newAdapter).protocolName());
                console2.log("Confirm the protocols match, then re-run with SWAP_IDENTITY_CONFIRMED=true.");
                revert IdentityCheckVacuous(old, newAdapter);
            }
        }

        console2.log("NAV:", nav);
        console2.log("  outgoing:", old, IHasProtocolName(old).protocolName());
        console2.log("  incoming:", newAdapter, IHasProtocolName(newAdapter).protocolName());
        console2.log("  instances carried:", instances.length);

        vm.startBroadcast();

        // Clear the predecessor's set FIRST, while it is still registered — `removeMetaInstances` reverts for an
        // unregistered adapter, so after the removal below this is no longer reachable.
        if (instances.length > 0) {
            navAdmin.removeMetaInstances(old, instances);
        }

        address[] memory one = new address[](1);
        one[0] = old;
        navAdmin.removeBalanceAdapters(one);

        navAdmin.addMetaBalanceAdapter(newAdapter, instances);

        vm.stopBroadcast();

        uint256 got = navAdmin.getMetaInstances(newAdapter).length;
        if (got != instances.length) revert InstanceSetLost(newAdapter, instances.length, got);
        if (navAdmin.isAdapterRegistered(old)) revert PredecessorNotRegistered(old);
        uint256 residue = navAdmin.getMetaInstances(old).length;
        if (residue != 0) revert PredecessorResidue(old, residue);

        // Persist the successor to the deployment record, so `04` stops skipping on the predecessor and `06`
        // stops resolving it. Optional because the record may already name the successor (it does when `04`
        // deployed it, which is the common path); mirrors what 10_MigrateAdaptersToCreate2 does after its swap.
        // The deployment record is NOT written here. This block runs during Forge's local simulation, BEFORE
        // the recorded transactions are submitted, so writing here would leave the git-tracked record naming the
        // successor even if a broadcast reverted and the live NAV still held the predecessor — the record
        // asserting a state that never happened. It is written by `verify()` instead, after the on-chain
        // assertions pass, which is the only point at which the successor is a fact rather than an intention.
        console2.log("  deployment record NOT yet updated - verify() writes it once the chain agrees");

        console2.log("[SIMULATED OK] instance count round-tripped:", got);
        console2.log("  NOW RUN THE VERIFY STEP against the chain:");
        console2.log("  OLD_ADAPTER=... NEW_ADAPTER=... forge script script/manage/SwapMetaAdapter.s.sol \\");
        console2.log("    --sig 'verify()' --rpc-url $RPC");
    }

    /// @notice Post-broadcast verification. Run this AFTER the swap, as a separate invocation.
    /// @dev **Why the asserts in `run()` are not enough, and why this is not paranoia.** `forge script` executes
    ///      `run()` end-to-end in a local EVM and only *records* the broadcast calls, submitting them afterwards.
    ///      Every check after `vm.stopBroadcast()` therefore reads SIMULATED state in which both calls already
    ///      applied — it can never observe what actually landed. Two partial-failure states are reachable and both
    ///      would print a success line:
    ///        - the remove drops but the add lands  → BOTH adapters registered → NAV double-counts;
    ///        - the remove lands but the add drops  → the position vanishes (under-report, the safe direction).
    ///      This entry point does no broadcasting and reads only live state, so it can distinguish them.
    /// @dev Fail-closed `IMetaBalanceAdapter` probe. A revert, a missing function, or a `false` all mean
    ///      "cannot prove it is a meta adapter", which is the answer that stops the script.
    function _isMetaAdapter(address adapter) internal view returns (bool) {
        if (adapter.code.length == 0) return false;
        try IPinnedToNav(adapter).supportsInterface(type(IMetaBalanceAdapter).interfaceId) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function verify() public {
        uint256 chainId = block.chainid;
        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        INavAdmin navAdmin = INavAdmin(nav);

        address old = vm.envOr("OLD_ADAPTER", address(0));
        address newAdapter = vm.envOr("NEW_ADAPTER", address(0));
        if (old == address(0) || newAdapter == address(0)) revert AdapterNotProvided();

        bool oldReg = navAdmin.isAdapterRegistered(old);
        bool newReg = navAdmin.isAdapterRegistered(newAdapter);
        uint256 residue = navAdmin.getMetaInstances(old).length;
        uint256 carried = navAdmin.getMetaInstances(newAdapter).length;

        console2.log("  predecessor registered:", oldReg, "  residual instances:", residue);
        console2.log("  successor   registered:", newReg, "  instances:", carried);

        // The over-report state first: it is the one that is silent on every other surface.
        if (oldReg && newReg) revert BothRegistered(old, newAdapter);
        if (oldReg) revert PredecessorStillRegistered(old);
        if (!newReg) revert SuccessorNotRegistered(newAdapter);
        if (residue != 0) revert PredecessorResidue(old, residue);
        // EXPECTED_INSTANCES is the count `run()` printed as round-tripped. Supplying it makes this an exact
        // comparison; without it the check can only say "not zero", which both misses a partial carry and
        // wrongly fails a legitimate zero-instance swap (the registration API permits one). An earlier revision
        // hardcoded `InstanceSetLost(newAdapter, 1, 0)`, which asserted a count of 1 for every adapter.
        uint256 expected = vm.envOr("EXPECTED_INSTANCES", type(uint256).max);
        if (expected != type(uint256).max) {
            if (carried != expected) revert InstanceSetLost(newAdapter, expected, carried);
        } else if (carried == 0) {
            console2.log("  WARNING: successor carries ZERO instances and EXPECTED_INSTANCES was not set.");
            console2.log("  If the swap was meant to carry instances, this is an INSTANCE SET LOST condition.");
            console2.log("  Re-run with EXPECTED_INSTANCES=<count> to make this an assertion instead of a warning.");
        }

        console2.log("[VERIFIED ON CHAIN] swap is complete and leaves no residue");

        // Only NOW is the successor a fact rather than an intention, so this is where the record moves.
        string memory adapterKey = vm.envOr("ADAPTER_KEY", string(""));
        if (bytes(adapterKey).length > 0) {
            ConfigReader.writeAdapterAddress(vm, chainId, "balanceAdapters", adapterKey, newAdapter);
            console2.log("  deployment record updated:", adapterKey, newAdapter);
        } else {
            console2.log("  ADAPTER_KEY unset - deployment record NOT updated; set it and re-run verify()");
        }
    }
}
