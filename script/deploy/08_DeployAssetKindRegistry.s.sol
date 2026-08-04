// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AssetKindRegistry} from "../../src/nav/AssetKindRegistry.sol";
import {AccrualKind} from "../../src/utils/AssetKind.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "../../src/constants.sol";

/// @title 08_DeployAssetKindRegistry
/// @author KPK
/// @notice Deploys the per-chain {AssetKindRegistry} and classifies every asset in
///         `nav-config/assets-and-price-feeds/<chainId>.json` in a single batch call.
/// @dev ⚠️ **NO FAILURE BRANCH IN THIS SCRIPT IS EXERCISED BY ANY TEST.** Not this step's config guards, not the
///      registry-binding check, not the code-length check: nothing in `test/` or `script/test/` instantiates this script
///      or calls `run()`, so no input that should trip a guard is ever fed to one.
///
///      **That is a claim about branch coverage, and it is NOT a claim that nobody checks `08`.** The preflight gate
///      does: `script/deploy/preflight/verify_step.py` step `1.8` verifies the ON-CHAIN OUTCOME after a real deploy —
///      that the registry is recorded, has code, is bound to the recorded proxy, holds `MANAGER` on the NAV, and that a
///      sample of assets is actually classified. That is real coverage of the *result*, and it is what would catch the
///      `grantRole`-succeeds/`setAssetKinds`-fails asymmetry in production.
///
///      The gap is narrower and specific: **verifying an outcome after the fact is not the same as executing a failure
///      branch.** Every guard below is a branch that was reasoned about and never run, and on the PR that added them two
///      of four had wrong failure paths for precisely that reason. **Treat every guard in this file as unverified**, and
///      prefer documenting a hazard here over adding a fifth unexercised
///      check. Branch coverage for `08` is tracked as a follow-up.
///
///      **Fail-closed at deploy time, deliberately.** Every configured asset MUST carry a valid `accrualKind` string.
///      (There is no `pegKind` in config: the peg axis is DERIVED on read from the NAV's `pegToleranceBps`, so it cannot
///      be configured, cannot disagree with the pricing layer, and needs no cross-check here. An earlier revision of
///      this script asserted `Pegged` ⇔ `pegToleranceBps > 0`; that guard is deleted rather than kept "just in case",
///      because a guard against an unrepresentable state is dead code that reads as protection.) An absent or unrecognized value ABORTS the deploy — it is not defaulted, not skipped and
///      not warned about. The reasoning is the same as the pre-deploy rate-feed guard's: a default classification is
///      indistinguishable from a real one once it is on-chain, so the only safe place to notice the gap is before the
///      transaction. This script reverting is the guard working.
///
///      Strings rather than integers in the config for the matching reason: a stale integer silently re-maps if an
///      enum ever gains a member, while an unknown string cannot be mistaken for a valid one. The string -> enum
///      mapping lives in {ConfigReader} so production and any harness share one source of truth.
///
///      **⚠️ THIS IS A PRIVILEGED STEP, AND IT MUST RUN BEFORE `07`.** It does not merely deploy and configure: it
///      calls `NAV.grantRole(MANAGER, registry)`, because the facade forwards to `NAV.registerAsset` and the NAV gates
///      on ITS `msg.sender` — the registry contract, not the operator. Without that grant the facade is dead code.
///
///      **The ordering is a hard dependency, and here is the reason so nobody "tidies" it back:** `grantRole` requires
///      `DEFAULT_ADMIN` on the NAV, and `07_TransferAdminToSecurityCouncil` hands that to the security-council Safe and
///      revokes the deployer's `MANAGER` (`07:97`). Run `08` after `07` and it reverts: `setAssetKinds` always, for lack
///      of MANAGER, plus the grant itself on a FIRST run, for lack of admin. (On a re-run the registry already holds the
///      role, so the guarded grant is skipped and only `setAssetKinds` fails — "reverts twice over" was over-stated.) `08` is EOA-broadcast only; there is no Safe path. So the
///      rule is not "07 is last" but **"07 is the last step of the ROLE HANDOFF; every step needing deployer privileges,
///      `08` included, must precede it."** An earlier revision of this file and seven other doc sites claimed `08` was
///      order-independent. It is not.
///
///      Independent of the NAV *stack*: this script references neither `PriceFeedLib` nor `NAVRegistryLib`, so it does
///      not gate — or get gated by — a NAV redeploy. Run it any time after the assets config exists and before `07`.
///
///      **But do not read that as "no pin regeneration is owed".** The FEATURE moves `PriceFeedLib`'s pin
///      (`0xfc6AE534…` → `0x49C18627665562F4bEbae5208BA6eF7428039614`): `AssetKindRegistry`'s presence under `src/`
///      coincided with the `via_ir` whole-program stack margin being reached, which prompted the
///      `PriceFeedLib._assignHealthArrays` extraction (the causal half is no longer demonstrable on a cold build; the
///      pin move is measured and stands).
///      `NAVRegistryLib` is genuinely unchanged. See the note on {AssetKindRegistry}.
///
///      Re-running is safe — the step is idempotent and re-classifies an existing registry rather than deploying a
///      second one — **but only with `PERSIST_DEPLOYMENTS=1`**, since the skip guard reads the record that flag gates.
///      See the warning at the guard itself.
///
///      **The registry has NO roles, so there is nothing to hand over.** It holds no `AccessControl`, no admin and no
///      manager: every write gates on `NAV.hasRole(MANAGER, msg.sender)`, making authority exactly the NAV's MANAGER
///      set. That retires three things this step previously had to document — the procedural-vs-enforced role
///      separation, the EOA-ownership posture, and the manual council-handover procedure. `07` correctly does not know
///      this contract exists, and now there is no reason it should.
///
///      Registering an asset directly on the NAV remains possible for any MANAGER and is deliberately NOT blocked in
///      code. Whether the facade becomes the ONLY path is a deploy-time role decision (revoke `MANAGER` from humans on
///      the NAV), left to the operator so this step imposes no single point of failure on asset registration.
contract DeployAssetKindRegistry is BaseDeployScript {
    /// @notice Thrown when a configured asset has no valid `accrualKind`. Aborts the deploy.
    error AssetKindMissingOrInvalid(string symbol, string field);

    /// @notice Thrown when a configured asset has no resolvable token address.
    error AssetAddressMissing(string symbol);

    /// @notice Thrown when a configured asset resolves to `address(0)`. Named separately from
    ///         {AssetAddressMissing} because the two are different config mistakes: an absent `address` key versus a
    ///         present-but-zero one.
    error AssetAddressZero(string symbol);

    /// @notice Thrown when the deployment record names an `AssetKindRegistry` address that has no code.
    /// @dev Checked BEFORE the `NAV()` read, and that ordering is load-bearing: without it, reading `NAV()` off a
    ///      codeless address reverts with an EMPTY reason in the calling frame, so {RegistryBoundToDifferentNav} — a
    ///      correct guard — never gets to report anything and the operator sees no cause at all.
    ///
    ///      **No remedy is prescribed here, deliberately.** Two different situations reach this branch — a run whose
    ///      first transaction never landed while the cheatcode-written record did, and a non-forked dry run against a
    ///      chain whose registry is genuinely live (a fresh local EVM has no code at that address) — and this guard
    ///      cannot tell them apart. An earlier revision prescribed "clear the key and re-run", which is right for the
    ///      first and would DELETE A LIVE DEPLOYMENT RECORD in the second. A guard may only prescribe a remedy for a
    ///      cause it can actually identify; this one identifies a symptom. Diagnose the cause before acting.
    error RecordedRegistryHasNoCode(address recorded, uint256 chainId);

    /// @notice Thrown when the recorded `AssetKindRegistry` is bound to a different `NAVCalculator` than the one this
    ///         run resolved. Deploy a fresh registry against the new NAV rather than granting it a role it cannot use.
    error RegistryBoundToDifferentNav(address registry, address boundNav, address expectedNav);

    /// @notice Thrown when the chain has no recorded `NAVCalculatorProxy`. The registry takes the NAV address in its
    ///         constructor and derives ALL of its authority from it, so deploying against `address(0)` would produce a
    ///         registry nobody can write to — caught here rather than on-chain.
    error NavCalculatorNotDeployed(uint256 chainId);

    function run() public override {
        uint256 chainId = block.chainid;

        string[] memory symbols = ConfigReader.getAssetSymbols(vm, chainId);
        // ⚠️ **KNOWN HAZARD, NOT GUARDED HERE. Do not run `08` on a chain with no assets config.** `getAssetSymbols`
        // returns empty both for "no assets" and for "no config file at all" (`_readOrEmpty` yields `"{}"`), and 18 of
        // the 25 chains carrying a deployments record have no assets config. On those, this step deploys the registry,
        // GRANTS IT `MANAGER` ON THE NAV, records it, classifies nothing, and exits 0 — a privileged empty contract from
        // a step whose stated contract is fail-closed, because the per-asset guards below are vacuously satisfied by an
        // empty loop.
        //
        // An abort was written and then REMOVED rather than shipped: it would be a fifth guard in a file where no
        // failure branch is executed by any test, and two of the four already here had wrong failure paths for exactly
        // that reason. Escalated as a follow-up with the `08` branch-coverage work rather than papered over with an
        // unverified check.
        console2.log("AssetKindRegistry: classifying assets:", symbols.length);

        // Resolve and VALIDATE the whole set before deploying anything, so a config gap costs nothing but a revert.
        address[] memory assets = new address[](symbols.length);
        AccrualKind[] memory accrualKinds = new AccrualKind[](symbols.length);
        // Labels ride the SAME transaction as the classification rather than arriving in one of their own, and this
        // script is the reason. It already dispatches three sequential transactions whose silent divergence is the
        // hazard documented at length below; a fourth would add a "labels never landed" partial state to exactly the
        // step that cannot detect the three it already has. Atomic with the kind, or not at all.
        string[][] memory labels = new string[][](symbols.length);

        for (uint256 i; i < symbols.length; ++i) {
            string memory symbol = symbols[i];

            string memory addrStr = ConfigReader.readAssetAddress(vm, chainId, symbol);
            if (bytes(addrStr).length == 0) revert AssetAddressMissing(symbol);
            assets[i] = vm.parseAddress(addrStr);
            // `address(0)` must be rejected HERE, not left to `AssetKindRegistry._setAssetKind`. The registry does
            // reject it, but with a bare `InvalidArguments()` naming neither the symbol nor the field — the least
            // useful error in a script whose whole purpose is to name the offending row, and the only one of this
            // script's three failure modes that would not tell the operator which config entry to fix.
            //
            // To be precise about what this does NOT protect against, since an earlier version of this comment got it
            // wrong: it is NOT guarding a half-deploy. `vm.startBroadcast()` only RECORDS transactions — they are sent
            // after `run()` returns — so a revert anywhere in this body aborts before anything is broadcast, and that
            // holds under `--skip-simulation` too (which skips the on-chain simulation, not the local execution).
            // So no CONFIG error can produce a "deployed but unclassified" registry — this guard buys a named error and
            // a script correct on its own terms rather than by virtue of how `forge script` sequences work.
            //
            // That state IS still reachable one stage later, and precision matters more here than reassurance: once
            // broadcast begins, a first run dispatches **THREE** sequential transactions — `new AssetKindRegistry`,
            // `grantRole(MANAGER, registry)`, then `setAssetKinds`. (The `NAV()` and `hasRole` reads are `STATICCALL`s
            // and are not broadcast. An earlier revision of this comment said TWO; it predated the grant.) Any of the
            // three can fail alone, so there are two distinct partial states:
            //   - `setAssetKinds` never lands -> registry deployed and recorded but UNCLASSIFIED. The idempotent re-run
            //     recovers it, so this one is tolerable.
            //   - **`grantRole` never lands while `setAssetKinds` does** -> a fully classified registry whose facade is
            //     DEAD, with the script exiting 0. This is the worse state, it is the one the earlier comment omitted,
            //     and nothing in this script can detect it.
            // **Verify after broadcasting that BOTH the classification and the grant landed.**
            if (assets[i] == address(0)) revert AssetAddressZero(symbol);

            (AccrualKind accrual, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, chainId, symbol);
            if (!accrualValid) revert AssetKindMissingOrInvalid(symbol, "accrualKind");
            accrualKinds[i] = accrual;

            // No validity flag and no abort, unlike the line above: an absent `labels` key yields an empty array,
            // which the registry accepts as a legitimate "this asset has no labels". Bounds (count, per-label length,
            // non-emptiness) are enforced ON-CHAIN by `AssetKindRegistry`, so a bad row reverts the batch with a named
            // error rather than being re-checked here — a second copy of the rule in tooling is the #248 failure mode.
            labels[i] = ConfigReader.readAssetLabels(vm, chainId, symbol);
        }

        // Idempotent, like every sibling step (`03`'s per-feed guards, `04`'s adapters and assistants): re-run it and
        // it re-classifies against the EXISTING registry instead of deploying a second one. Without this, the ordinary
        // re-run — after a partial failure, after adding an asset, or just repeating a step the docstring below invites
        // you to repeat — deploys a fresh registry and overwrites the deployment record, leaving the first one live,
        // still holding MANAGER, still answering `getAssetKind`, and now unmaintained. Two plausible answers with
        // nothing to say which is authoritative is the worst shape available to a misreporting-sensitive system.
        // ⚠️ **This idempotency is only as good as the deployment record, so it REQUIRES `PERSIST_DEPLOYMENTS=1`.**
        // The two guards interact: `saveDeployedAddress` (below) writes only when `PERSIST_DEPLOYMENTS` is set, and this
        // guard reads what that wrote. So a real `--broadcast` WITHOUT `PERSIST_DEPLOYMENTS=1` deploys a live registry
        // and records nothing, and the next run deploys a second one — exactly the harm this guard exists to prevent.
        //
        // There is no fallback, and it is worth being exact about why, because the obvious explanation is wrong: it is
        // NOT simply "CREATE rather than CREATE2". `05` does probe a CREATE2 address for code, but `04` does not — its
        // adapters use plain `new` behind a deployment-record lookup, structurally identical to this. The real
        // difference is which writer is used: `03`/`04`'s adapters record through the UNGATED
        // `ConfigReader.writeAdapterAddress`, while this step (like `04`'s three assistants) records through the
        // `PERSIST_DEPLOYMENTS`-gated `saveDeployedAddress`. So `04`'s assistants share this exposure exactly.
        //
        // `saveDeployedAddress` does log "NOT persisted to config" in that case, but that is one line in a wall of
        // output, in a repo whose own rule is never to trust a deploy script's exit code. **Always run this step with
        // `PERSIST_DEPLOYMENTS=1`** (the README example does).
        address existing = readDeployedAddress("AssetKindRegistry");

        vm.startBroadcast();

        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        if (nav == address(0)) revert NavCalculatorNotDeployed(chainId);
        // ⚠️ NOT GUARDED, deliberately: `nav` comes from the SAME cheatcode-written record as the registry address, so
        // it too can name a codeless address, and `hasRole` returns a bool so the failure is the same empty-reason
        // revert. A `nav.code.length` check was written and then REMOVED rather than shipped — every guard added to this
        // file is a branch no test executes (see the coverage note on the contract), and on this PR two of four such
        // guards had wrong failure paths for exactly that reason. Documented instead of guarded, so the next person
        // decides with the cost visible.

        AssetKindRegistry registry;
        if (existing != address(0)) {
            registry = AssetKindRegistry(existing);
            // ⚠️ **The recorded registry must be bound to THIS NAV before it is handed that NAV's `MANAGER`.** The
            // registry's `NAV` is immutable, but the deployment record's `NAVCalculatorProxy` is not — a NAV redeploy
            // moves it while the `AssetKindRegistry` key stays put (this repo has redeployed the NAV before). Re-running
            // `08` then grants the NEW NAV's `MANAGER` to a registry still pointing at the OLD proxy, and the run
            // completes GREEN: `setAssetKinds` gates on the OLD NAV's roles, so it succeeds, the facade writes to the
            // wrong NAV, and the new NAV has given away `MANAGER` for nothing. The idempotency guard above is what
            // causes this — it reuses the recorded registry rather than deploying one bound to the new proxy.
            // ⚠️ **The code check MUST come before the `NAV()` read, and this ordering is the fix.** The deployment
            // record is written by a CHEATCODE during local execution (`saveDeployedAddress` -> `vm.writeJson`), so it
            // lands whether or not TX1 (`new AssetKindRegistry`) actually broadcasts — leaving the record able to name
            // an address with no code.
            //
            // Reading `NAV()` off such an address reverts with an EMPTY reason, in the calling frame, before any guard
            // below can speak. That OUTCOME is what makes the ordering load-bearing, and it is all this comment
            // asserts: an earlier revision explained it via an `extcodesize` precheck, which is backwards — since solc
            // 0.8.10 a call that expects return data SKIPS that check. Stating the outcome and not the codegen is
            // deliberate; the outcome is what the ordering depends on, and it is the part that was verified.
            if (existing.code.length == 0) revert RecordedRegistryHasNoCode(existing, chainId);
            address boundNav = address(registry.NAV());
            if (boundNav != nav) revert RegistryBoundToDifferentNav(existing, boundNav, nav);
            console2.log("AssetKindRegistry already deployed at:", existing);
        } else {
            // The registry takes only the NAV address: it keeps no roles of its OWN and gates every write on
            // `NAV.hasRole(MANAGER, msg.sender)`, so authority is exactly the NAV's MANAGER set. The deployer can
            // classify in this same run because it already holds that role.
            registry = new AssetKindRegistry(nav);
        }

        // ⚠️ **THE REGISTRY MUST HOLD `MANAGER` ON THE NAV, OR THE FACADE IS DEAD CODE.** `registerAsset` forwards to
        // `NAV.registerAsset`, and the NAV gates on ITS `msg.sender` — which on that hop is the registry contract, not
        // the operator. Without this grant every call to the atomic facade reverts `NotAuthorized()`, and review caught
        // exactly that: the facade shipped non-functional because the unit-test NAV mock had no role gate, so 28 green
        // tests could not see it. The mock now gates, and `test_facadeRevertsIfRegistryLacksNavManager` pins this.
        //
        // Idempotent: `grantRole` on an address that already holds the role is a no-op in OpenZeppelin
        // `AccessControl`, so a re-run costs one cheap call rather than reverting.
        if (!IAccessControl(nav).hasRole(MANAGER, address(registry))) {
            IAccessControl(nav).grantRole(MANAGER, address(registry));
            console2.log("Granted NAV MANAGER to AssetKindRegistry:", address(registry));
        }

        // Re-classification is permitted and event-emitting by design, so this runs on both paths.
        //
        // ⚠️ **Labels are WRITE-ONCE, so a re-run behaves differently for them than for the kinds — but it still
        // re-runs.** Re-running against an existing registry silently re-writes every `accrualKind`. Labels are
        // compared instead: identical content is a no-op, so the idempotent re-run this step advertises survives
        // labels reaching config. Supplying DIFFERENT labels for an asset that already has them REVERTS
        // `AssetLabelsAlreadySet`, and it takes the whole batch with it — there is no `try`/`catch` on this path.
        //
        // So: **editing a label in config and re-running `08` is not a repair, it is an abort.** Changing a label that
        // has already landed on-chain means REPLACING the registry — deploy a new one, re-classify into it, and point
        // the NAV at it with the MANAGER-gated `setAssetKindRegistry`. Adding labels to an asset that had none is
        // fine and is exactly what a re-run is for.
        if (assets.length > 0) {
            registry.setAssetKinds(assets, accrualKinds, labels);
        }

        // ⚠️ **VERIFY THE GRANT AFTER BROADCASTING. This script cannot do it for you, and an earlier revision wrongly
        // claimed otherwise.** That revision asserted `hasRole(MANAGER, registry)` here. The assertion was dead code
        // that read as protection, for two independent reasons:
        //   1. it ran during LOCAL execution, before any transaction was sent (see the note above — `vm.startBroadcast`
        //      only RECORDS), so it could not observe whether the grant LANDED on-chain, which is the failure it named;
        //   2. it was near-tautological anyway — 14 lines after `if (!hasRole) grantRole(...)`, `hasRole` is true unless
        //      OZ's `_grantRole` ran without setting the bit, which it cannot. A wrong role constant was invisible too,
        //      since the grant and the check read the same `MANAGER`.
        // It was removed rather than reworded, on this PR's own stated principle: a guard against a state the design
        // cannot express is dead code that reads as protection. That is exactly why `PegKindContradictsPegTolerance` was
        // deleted, and keeping this one would have been the same mistake with the opposite sign.
        //
        // The real protection is post-broadcast: read `hasRole(MANAGER, <registry>)` on the NAV and confirm it is true.
        // Until you do, a run that exits 0 has NOT demonstrated a working facade.

        vm.stopBroadcast();

        // `saveDeployedAddress`, not `ConfigReader.writeDeployedAddress`: the base-class helper gates the write on
        // `PERSIST_DEPLOYMENTS` so a dry run cannot persist a SIMULATED address into
        // `script/config/deployments/<chainId>.json` — the one place deployed addresses live, and the source the
        // preflight tooling and the published contract-delta both derive from. `08` was the only deploy script
        // bypassing that gate.
        if (existing == address(0)) saveDeployedAddress("AssetKindRegistry", address(registry));
    }
}
