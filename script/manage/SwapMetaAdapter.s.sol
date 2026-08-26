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
///      **The instance set is read first, then EXPLICITLY CLEARED, and only then is the adapter removed.** An
///      earlier version of this file claimed `removeBalanceAdapters` "wipes" the instance set. That is FALSE, and
///      the correction is the reason for the ordering below. `Balances.sol` says so outright: *"a removed
///      adapter's configured meta-instance set (if any) is left dormant … the stale set persists"*, and
///      `NAVRegistryLib.removeBalanceAdapter` takes no `_metaInstances` reference at all. Verified on mainnet
///      after the first swap this script performed: `getMetaInstances(<deregistered predecessor>)` still returned
///      the carried coordinate.
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
        string memory adapterKey = vm.envOr("ADAPTER_KEY", string(""));
        if (bytes(adapterKey).length > 0) {
            ConfigReader.writeAdapterAddress(vm, chainId, "balanceAdapters", adapterKey, newAdapter);
            console2.log("  deployment record updated:", adapterKey, newAdapter);
        } else {
            console2.log("  ADAPTER_KEY unset - deployment record NOT updated; confirm it names the successor");
        }

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
    function verify() public view {
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
        if (carried == 0) revert InstanceSetLost(newAdapter, 1, 0);

        console2.log("[VERIFIED ON CHAIN] swap is complete and leaves no residue");
    }
}
