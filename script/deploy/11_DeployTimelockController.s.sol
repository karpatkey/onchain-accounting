// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/constants.sol";

/// @title 11_DeployTimelockController
/// @author KPK
/// @notice CREATE2-deploys the governance {TimelockController} and emits the Safe batch that moves
///         `DEFAULT_ADMIN_ROLE` + `MANAGER` on the NAV from the deployer EOA onto it.
/// @dev **Two phases, two signers, and they are deliberately not merged.** The deploy is an EOA broadcast (it
///      needs no privileges at all — a `TimelockController` grants its own roles in its constructor). The role
///      handover is a Safe batch, because by the time it runs the security-council Safe is the admin and the
///      deployer is being removed. Running only the first half is safe and idempotent; running only the second
///      half is impossible, since it names the deployed address.
///
///      ⚠️ **RUN THIS LAST, after every migration step that needs deployer privileges.** It is the same rule
///      `07_TransferAdminToSecurityCouncil` lives under, for the same reason: it revokes the deployer's
///      `MANAGER` and `DEFAULT_ADMIN_ROLE`. Anything still needing them — `RealignHeartbeats`, the claimant
///      backfill, `RegisterAssets`, `08` — must have completed on this chain first. Unlike `07`, this step does
///      NOT touch the bridge adapters or `BridgeEscrow`; it governs the NAV only.
///
///      ### The role design, and why it is the constructor's default rather than a subclass
///
///      OpenZeppelin 5.5.0's constructor is
///      `(uint256 minDelay, address[] proposers, address[] executors, address admin)` and it grants
///      `DEFAULT_ADMIN_ROLE` to `address(this)`, then `PROPOSER_ROLE` **and `CANCELLER_ROLE`** to every
///      `proposers` entry, then `EXECUTOR_ROLE` to every `executors` entry. So "the only proposer and canceller
///      is the security-council Safe, and anyone may execute" is expressible exactly:
///
///        - `minDelay  = 0`                  — see the warning below
///        - `proposers = [securityCouncil]`  — one entry, which lands BOTH proposer and canceller
///        - `executors = [address(0)]`       — `onlyRoleOrOpenRole` short-circuits when the role is held by
///                                            `address(0)`, so execution is permissionless
///        - `admin     = address(0)`         — no optional admin; the timelock administers itself
///
///      No subclass, no wrapper, no custom roles. The OZ contract is used verbatim, which is the point: this is
///      the most-reviewed timelock in existence and a bespoke variant would forfeit that for nothing.
///
///      ### ⚠️ `minDelay = 0` — what it does and does NOT buy
///
///      **At zero delay this timelock provides no timing protection and its canceller is decorative.** Stated
///      plainly because it is easy to read the word "timelock" as a guarantee it is not yet providing:
///
///        - `_schedule` sets `_timestamps[id] = block.timestamp + delay`, and `getOperationState` returns
///          `Waiting` only while `timestamp > block.timestamp`. At delay 0 an operation is `Ready` in the SAME
///          block, so the Safe can `scheduleBatch` and `executeBatch` in one transaction.
///        - and because `EXECUTOR_ROLE` is open, a scheduled-but-unexecuted operation can be executed by anyone
///          immediately — so cancelling is a race, not a veto.
///
///      What it DOES buy, today: one canonical admin address fleet-wide instead of a hot EOA, and the option to
///      raise the delay later without moving any role again. This is a deliberate starting posture ("start with
///      0 so we can adjust anything"), not an oversight.
///
///      **Raising it later is a self-call.** `updateDelay` reverts `TimelockUnauthorizedCaller` unless
///      `msg.sender == address(this)`, so the Safe must `schedule` a call to `timelock.updateDelay(newDelay)`
///      and then execute it. Frictionless while the delay is 0 — which is the one-way door to be aware of: the
///      first raise is easy, and every subsequent governance change must then wait out the new delay.
///
///      ### The consequence that costs real work
///
///      Once `MANAGER` lives only here, **every config operation must be wrapped as `scheduleBatch` +
///      `executeBatch`.** `script/manage/RealignHeartbeats.s.sol` and `ClearDormantMetaInstances.s.sol` are
///      EOA-broadcast only — no `writeSafeTx` path at all — and will stop working. Do not run this step until
///      either those scripts have a timelock emitter or you accept that the affected operations are unavailable.
///      `executeBatch` is atomic (one reverting call reverts the batch), so it is a STRONGER atomicity primitive
///      than the Safe UI's implicit MultiSend once it is in place.
///
///      ### Post-broadcast verification is mandatory and this script cannot do it
///
///      Every read below runs during LOCAL SIMULATION — `vm.startBroadcast` only RECORDS transactions; Foundry
///      sends them after `run()` returns. So an assertion here observes simulated state and would be dead code
///      that reads as protection, which is the mistake `08_DeployAssetKindRegistry` documents at length. The
///      checks are therefore logged as a checklist, not asserted. Confirm on-chain, after the Safe batch
///      executes:
///        - on the NAV: `hasRole(0x00, timelock)` and `hasRole(MANAGER, timelock)` are true;
///          `hasRole(0x00, deployer)` and `hasRole(MANAGER, deployer)` are false; `getRoleMemberCount(0x00) >= 1`
///        - on the timelock: `getMinDelay() == 0`, `hasRole(PROPOSER_ROLE, safe)`,
///          `hasRole(CANCELLER_ROLE, safe)`, `hasRole(EXECUTOR_ROLE, address(0))`,
///          `hasRole(DEFAULT_ADMIN_ROLE, deployer) == false`
///        - **and rehearse one full `scheduleBatch` -> `executeBatch` round trip on ONE chain before declaring
///          the migration done.** A timelock that cannot execute is a bricked NAV, and nothing above detects it.
contract DeployTimelockController is BaseDeployScript {
    /// @notice Canonical CREATE2 deployer (Arachnid). Calldata is `salt || init_code`.
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @notice Thrown when the chain has no recorded `NAVCalculatorProxy` — there would be nothing to govern.
    error NavCalculatorNotDeployed(uint256 chainId);

    /// @notice Thrown when `chainConfig.securityCouncil` is unset. It is the sole proposer and canceller, so a
    ///         zero value would deploy a timelock **nobody can ever propose to** — permanently inert, and
    ///         permanently holding the NAV's admin role if the batch were then executed.
    error SecurityCouncilNotSet(uint256 chainId);

    /// @notice Thrown when the predicted CREATE2 address already holds code that is not a timelock configured
    ///         the way this script intends.
    /// @dev An address collision is not the realistic cause; a changed `securityCouncil`, a changed OZ version,
    ///      or a hand-deployed timelock are. Adopting such a contract silently and then handing it the NAV's
    ///      admin role is the failure this refuses.
    error ExistingTimelockMisconfigured(address timelock, string what);

    /// @notice Thrown when the CREATE2 call returned success but the predicted address still has no code.
    /// @dev The realistic cause is the canonical factory `0x4e59b448…` being absent on a newly added chain. It is
    ///      present on every chain already brought up through `01`/`02`, so this guards the next chain, not today's.
    error Create2DeployProducedNoCode(address predicted);

    /// @notice Thrown when the address that will EXECUTE the emitted batch does not hold `DEFAULT_ADMIN_ROLE`.
    /// @dev Not a formality, and the subject matters: EVERY entry in the emitted batch executes as the SAFE, so
    ///      the Safe is what must hold admin. Without this the batch reverts at its first `grantRole`, after
    ///      signatures have been collected. (An earlier revision carried this docstring on the deployer-side
    ///      check below, describing a subject it did not guard.)
    error BatchExecutorNotAdmin(address safe);

    /// @notice Thrown when the deployer EOA resolved from env does not currently hold `DEFAULT_ADMIN_ROLE`.
    error DeployerNotAdmin(address deployer);

    function run() public override {
        setUp();

        address nav = readDeployedAddress("NAVCalculatorProxy");
        if (nav == address(0)) revert NavCalculatorNotDeployed(currentChainId);

        address safe = chainConfig.securityCouncil;
        if (safe == address(0)) revert SecurityCouncilNotSet(currentChainId);

        address deployer = vm.envAddress("DEPLOYER_EOA");
        require(deployer != address(0), "Set DEPLOYER_EOA env var to the deployer EOA address.");
        require(deployer != safe, "securityCouncil must differ from the deployer EOA.");

        // Whether the council Safe ALSO keeps the roles directly, alongside the timelock.
        //
        // ⚠️ **This is a governance decision, not a tuning knob, and the default is the meaningful one.**
        // Default `false`: the Safe's own roles are revoked, so the timelock is the only path to admin and
        // MANAGER. Set `SAFE_RETAINS_ROLES=true` and the Safe can still act directly and immediately — which
        // means raising `minDelay` later would achieve NOTHING, because the delay would be bypassable by the
        // very signer it exists to delay. Retaining is a reasonable transitional choice while the ops scripts
        // lack a timelock emitter; it is not a reasonable end state.
        bool safeRetains = vm.envOr("SAFE_RETAINS_ROLES", false);

        console2.log("\n=== Deploy governance TimelockController ===");
        console2.log("NAV proxy            :", nav);
        console2.log("Security council Safe:", safe);
        console2.log("Deployer EOA (losing):", deployer);
        console2.log("minDelay             : 0");
        console2.log("Safe retains roles   :", safeRetains);

        // --- phase 1: CREATE2 deploy, EOA broadcast, no privileges needed -------------------------------
        //
        // Args assembled BEFORE the broadcast so the predicted address is computed from exactly the init code
        // that will be deployed. `proposers` carries one entry and yields BOTH proposer and canceller;
        // `executors = [address(0)]` is what makes execution permissionless.
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        bytes memory initCode = abi.encodePacked(
            type(TimelockController).creationCode, abi.encode(uint256(0), proposers, executors, address(0))
        );
        bytes32 salt = generateSalt("TimelockController", DeploySalts.TIMELOCK_CONTROLLER);
        address predicted = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, salt, initCode);

        vm.startBroadcast();

        if (predicted.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
            require(ok, "TimelockController CREATE2 deploy failed");
            // ⚠️ **`ok` DOES NOT MEAN DEPLOYED, and on this script that distinction bricks the NAV.** A
            // low-level call to an address holding NO CODE returns `true` and does nothing. If the Arachnid
            // factory is absent on this chain, `require(ok)` passes, `saveDeployedAddress` records `predicted`,
            // and the batch below grants the NAV's `DEFAULT_ADMIN_ROLE` + `MANAGER` to a CODELESS address and
            // then revokes both from the deployer EOA and (by default) from the Safe. End state: no admin, no
            // MANAGER, no upgrade, no registration, no recovery.
            //
            // This check costs one EXTCODESIZE and fails during local simulation, before anything is broadcast.
            // The sibling CREATE2 sites (`01_DeployImplementations`, `04_DeployBalanceAdapters`,
            // `AtomicNAVProxyDeployer`) share the gap; it is fixed HERE because this is the only one whose
            // follow-on step is irreversible.
            if (predicted.code.length == 0) revert Create2DeployProducedNoCode(predicted);
            console2.log("[OK] TimelockController deployed at:", predicted);
        } else {
            // Idempotent re-run, or a chain reached twice. Adopt it only after proving it is OURS and
            // configured as intended — an address with code is not evidence of the right contract, and this one
            // is about to be handed the NAV's admin role.
            //
            // These four reads are STATICCALLs against state that already exists on-chain (the constructor ran
            // in a previous, confirmed transaction), so unlike the post-condition checks this script declines to
            // make, they are NOT observing simulated state and are safe to assert on.
            TimelockController existing = TimelockController(payable(predicted));
            if (existing.getMinDelay() != 0) revert ExistingTimelockMisconfigured(predicted, "minDelay != 0");
            if (!existing.hasRole(existing.PROPOSER_ROLE(), safe)) {
                revert ExistingTimelockMisconfigured(predicted, "council lacks PROPOSER_ROLE");
            }
            if (!existing.hasRole(existing.CANCELLER_ROLE(), safe)) {
                revert ExistingTimelockMisconfigured(predicted, "council lacks CANCELLER_ROLE");
            }
            if (!existing.hasRole(existing.EXECUTOR_ROLE(), address(0))) {
                revert ExistingTimelockMisconfigured(predicted, "EXECUTOR_ROLE is not open");
            }
            console2.log("[SKIP] TimelockController already at:", predicted);
        }

        vm.stopBroadcast();

        saveDeployedAddress("TimelockController", predicted);

        // --- phase 2: the role-handover Safe batch ------------------------------------------------------
        //
        // Checked here rather than assumed, because a batch emitted against the wrong role holder wastes a
        // signing round: if the deployer is not admin, the revokes are no-ops and the grants may not be
        // executable by the Safe at all.
        // ⚠️ **The SAFE is what executes every entry below, so the Safe is what must hold admin.** An earlier
        // revision checked only the DEPLOYER, whose `DeployerNotAdmin` docstring claimed to prevent "the emitted
        // batch would revert on execution, after signatures had been collected" — the exact failure it could not
        // see. In the fleet's CURRENT state that guard passes and the batch reverts at `batch[0]`: `admin ==
        // manager == the deployer EOA` on every chain, because the council handover (`07` steps 2-3) was a
        // recorded decision NOT to run. Phase 1 of the runbook grants the Safe both roles first; this is the
        // check that the operator actually did it.
        if (!IAccessControl(nav).hasRole(DEFAULT_ADMIN_ROLE, safe)) revert BatchExecutorNotAdmin(safe);
        // The deployer is checked too, but for a different reason: it is the subject of the revokes, and if it
        // holds nothing then either this already ran or the wrong EOA was passed.
        if (!IAccessControl(nav).hasRole(DEFAULT_ADMIN_ROLE, deployer)) revert DeployerNotAdmin(deployer);

        // ORDER IS LOAD-BEARING AND THE WHOLE BATCH MUST BE ATOMIC.
        //
        //   1-2. Grant both roles to the timelock FIRST, while the Safe still holds admin. A timelock with
        //        admin but not MANAGER cannot do meta-adapter work; with MANAGER but not admin it cannot
        //        upgrade. Splitting the pair leaves a half-empowered governor.
        //   3-4. Revoke the deployer. Grants strictly before revokes — the same rule
        //        `07_TransferAdminToSecurityCouncil:83-102` follows, though that script executes it as one
        //        `startBroadcast`/`stopBroadcast` pair PER TARGET and so is not atomic. One Safe batch is
        //        strictly better and is why this is emitted rather than broadcast.
        //   5-6. Revoke the Safe LAST, and only in this same batch. `revokeRole`, not `renounceRole`: the Safe
        //        is the caller here, and `07` uses renounce only because the EOA calls it on itself.
        //
        // ⚠️ If entries 5-6 were ever split into a later batch and 1-2 had failed, the chain would be left with
        // no admin at all. That is why they are one batch and why the revoke is last within it.
        //
        // ⚠️ **And the atomicity comes from the Safe Transaction Builder app, NOT from anything in this repo.**
        // `SafeTxBuilder.writeSafeTx` emits a FLAT LIST; the app is what wraps a multi-transaction import into
        // `multiSend` at signing time. (`writeSafeTxViaMultiSend` exists but has no call sites and the repo holds
        // no MultiSend address constant to give it.) **Execute this batch only through the Transaction Builder.**
        // Dispatched as individual transactions, a failure at entries 1-2 after 5-6 land is exactly the
        // no-admin brick named above — so "MUST be atomic" is a requirement on the OPERATOR here, not a
        // property the emitter can guarantee.
        uint256 n = safeRetains ? 4 : 6;
        SafeTxBuilder.Transaction[] memory batch = new SafeTxBuilder.Transaction[](n);

        batch[0] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.grantRole, (DEFAULT_ADMIN_ROLE, predicted)));
        batch[1] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.grantRole, (MANAGER, predicted)));
        batch[2] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (MANAGER, deployer)));
        batch[3] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (DEFAULT_ADMIN_ROLE, deployer)));
        if (!safeRetains) {
            batch[4] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (MANAGER, safe)));
            batch[5] = SafeTxBuilder.call(nav, 0, abi.encodeCall(IAccessControl.revokeRole, (DEFAULT_ADMIN_ROLE, safe)));
        }

        writeSafeTx(
            string.concat(vm.toString(currentChainId), "-install-timelock.json"),
            "Install TimelockController as NAV governor",
            string.concat(
                "Grants DEFAULT_ADMIN_ROLE + MANAGER on the NAVCalculator to the TimelockController at ",
                vm.toString(predicted),
                ", then revokes both from the deployer EOA",
                safeRetains
                    ? " (the Safe RETAINS its own roles - the timelock is bypassable until they are revoked)."
                    : ", then from this Safe itself. MUST execute atomically and in this order: the Safe's own"
                    " revoke is last, and if the grants were to fail while it landed the NAV would have no admin.",
                " Execute this only after every step needing deployer privileges has completed on this chain."
            ),
            batch
        );

        console2.log("\n--- verify ON-CHAIN after the batch executes (this script CANNOT) ---");
        console2.log("NAV      hasRole(DEFAULT_ADMIN, timelock) == true, hasRole(MANAGER, timelock) == true");
        console2.log("NAV      hasRole(DEFAULT_ADMIN, deployer) == false, hasRole(MANAGER, deployer) == false");
        console2.log("timelock getMinDelay() == 0, PROPOSER+CANCELLER == safe, EXECUTOR == address(0)");
        console2.log("then     rehearse one scheduleBatch -> executeBatch round trip before declaring done");
    }
}
