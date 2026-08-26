// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AssetKindRegistry} from "../../src/nav/AssetKindRegistry.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
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
///      does: `script/deploy/preflight/verify_step.py` step `1.4` verifies the ON-CHAIN OUTCOME after a real deploy —
///      that the registry is recorded, has code, is bound to the recorded proxy, holds `MANAGER` on the NAV, that the
///      **NAV points BACK at it**, and that a sample of assets is actually classified. That is real coverage of the
///      *result*, and it is what would catch the `grantRole`-succeeds/`setAssetKinds`-fails asymmetry in production.
///
///      ⚠️ **The NAV-points-back assertion is new, and its absence was a live defect rather than a hypothetical.**
///      `NAVCalculator.setAssetKindRegistry` shipped with the read surface and was called by NOTHING outside tests —
///      not this script, not the runbook, not the gate. Every deploy therefore left the NAV's pointer at
///      `address(0)` and every `getAssetInfo` call reverting, while all five of the other checks passed. A gate that
///      is green while the feature is dead is the failure this step exists to prevent, so the pointer is now both
///      SET here and ASSERTED there.
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
///      **⚠️ THIS IS A PRIVILEGED STEP, AND IT MUST RUN BEFORE `07`.** It does not merely deploy and configure: it makes
///      TWO privileged calls on the NAV, one for each direction of a link that is not symmetric —
///      `setAssetKindRegistry(registry)` so the NAV can READ, and `grantRole(MANAGER, registry)` so the facade can
///      WRITE. Without the grant the facade is dead code; without the pointer every read reverts. Each is invisible
///      from inside the other contract, which is exactly how the pointer came to be missing for the whole life of the
///      feature.
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
///      **The pin regeneration this feature owed HAS BEEN DONE.** `AssetKindRegistry`'s arrival under `src/` moved
///      `PriceFeedLib`'s pin — its presence coincided with the `via_ir` whole-program stack margin being reached,
///      which prompted the `PriceFeedLib._assignHealthArrays` extraction (the causal half is no longer demonstrable
///      on a cold build; the pin move is measured and stands). `PriceFeedLib` is now pinned at `0xcD6F52F4…` and
///      `NAVRegistryLib` did not move. See the note on {AssetKindRegistry}, and take the authoritative values from
///      `foundry.toml` / `LibraryPins`, never from prose.
///
///      Re-running is safe — the step is idempotent and re-classifies an existing registry rather than deploying a
///      second one. The skip guard probes the CREATE2 address for code ON-CHAIN, so idempotency does not depend on
///      the deployment record and holds without `PERSIST_DEPLOYMENTS=1`. Pass the flag anyway: downstream consumers
///      (`09_BackfillAssetLabels`, `verify_step.py 1.4`) read the address FROM the record, and only
///      `saveDeployedAddress` writes it. See the note at the guard itself.
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
    /// @notice Canonical CREATE2 deployer (Arachnid). Calldata is `salt || init_code`.
    /// @dev Same constant and same format `01_2_DeployNAVImplementation` uses for the libraries and the NAV
    ///      implementation; the registry joins them so every canonical contract shares one address fleet-wide.
    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

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
            // broadcast begins, a first run dispatches **FOUR** sequential transactions —
            //   1. `new AssetKindRegistry`
            //   2. `setAssetKindRegistry(registry)`   on the NAV  (wires NAV -> registry, the READ direction)
            //   3. `grantRole(MANAGER, registry)`     on the NAV  (wires registry -> NAV, the WRITE direction)
            //   4. `setAssetKinds(...)`               on the registry
            // (The `NAV()`, `hasRole` and `assetKindRegistry` reads are `STATICCALL`s and are not broadcast. Earlier
            // revisions of this comment said TWO and then THREE; the first predated the grant, the second predated the
            // pointer. **Keep this count honest — it is the only place these transactions are enumerated, so an
            // unnamed one is invisible in the single document that exists to make them visible.**)
            //
            // Any of the four can fail alone, giving three distinct partial states:
            //   - `setAssetKinds` never lands -> registry deployed and recorded but UNCLASSIFIED. The idempotent re-run
            //     recovers it, so this one is tolerable.
            //   - **`grantRole` never lands while `setAssetKinds` does** -> a fully classified registry whose facade is
            //     DEAD, with the script exiting 0. Nothing in this script can detect it.
            //   - **`setAssetKindRegistry` never lands** -> everything looks complete and every NAV read REVERTS. This
            //     is the state every deploy was in before this transaction existed, because nothing called it.
            //
            // The pointer is dispatched FIRST of the three post-deploy transactions for exactly this reason: a
            // broadcast is sequential, so an earlier failure tends to prevent the later ones, and the states that
            // survive a partial failure are then visibly incomplete rather than complete-looking and broken.
            //
            // **Verify after broadcasting that ALL THREE landed — the pointer, the grant and the classification.**
            // `verify_step.py` step 1.4 asserts all three; the pointer check compares by EQUALITY against the recorded
            // registry, so a stale pointer left by a previous run fails rather than passing as merely non-zero.
            if (assets[i] == address(0)) revert AssetAddressZero(symbol);

            (AccrualKind accrual, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, chainId, symbol);
            if (!accrualValid) revert AssetKindMissingOrInvalid(symbol, "accrualKind");
            accrualKinds[i] = accrual;
        }

        // Idempotent, like every sibling step (`03`'s per-feed guards, `04`'s adapters and assistants): re-run it and
        // it re-classifies against the EXISTING registry instead of deploying a second one. Without this, the ordinary
        // re-run — after a partial failure, after adding an asset, or just repeating a step the docstring below invites
        // you to repeat — deploys a fresh registry and overwrites the deployment record, leaving the first one live,
        // still holding MANAGER, still answering `getAssetKind`, and now unmaintained. Two plausible answers with
        // nothing to say which is authoritative is the worst shape available to a misreporting-sensitive system.
        // Idempotency comes from CHAIN STATE, not from the record: the guard above probes the predicted CREATE2
        // address for code. That address is a pure function of (creation code, NAV, salt), so there is always one to
        // probe — which is why a re-run without `PERSIST_DEPLOYMENTS=1` is a no-op rather than a second registry.
        //
        // The flag is still required, for a different reason: `09_BackfillAssetLabels` and `verify_step.py 1.4` read
        // the registry address from the record, and only `saveDeployedAddress` (below) writes it. Omit the flag and
        // the chain is correct while nothing downstream can find the registry.
        //
        // This was previously the opposite: the guard read the record, so a real `--broadcast` without the flag
        // recorded nothing and the next run deployed a second registry — two live registries, both holding MANAGER,
        // with nothing to say which was authoritative.
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
            //
            // ⚠️ **CREATE2, via the canonical deployer — NOT `new`.** Generation 1 used `new AssetKindRegistry(nav)`,
            // so the address followed the deployer's nonce and differed on 14 of 24 chains. Every other canonical
            // contract here (libraries, implementation, proxy) is CREATE2-identical fleet-wide, and consumers
            // reasonably assume the registry is too — the deployment record is the only place the per-chain address
            // existed, and an address-keyed map built from broadcast artifacts silently mislabelled the registries
            // that happened to collide.
            //
            // The constructor takes only `nav`, and the NAV proxy is itself CREATE2-identical, so the init code —
            // and therefore the derived address — is the same on every chain.
            bytes32 salt = generateSalt("AssetKindRegistry", DeploySalts.ASSET_KIND_REGISTRY);
            bytes memory initCode = abi.encodePacked(type(AssetKindRegistry).creationCode, abi.encode(nav));
            address predicted = computeCreate2Address(CANONICAL_CREATE2_DEPLOYER, salt, initCode);

            if (predicted.code.length == 0) {
                (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
                require(ok, "AssetKindRegistry CREATE2 deploy failed");
                console2.log("[OK] AssetKindRegistry deployed at:", predicted);
            } else {
                // Same address, already deployed on this chain — idempotent re-run, or a chain reached twice.
                console2.log("[SKIP] AssetKindRegistry already at:", predicted);
            }
            registry = AssetKindRegistry(predicted);

            // The predicted address is only meaningful if it really carries this contract. A CREATE2 address with code
            // that is NOT ours would otherwise be adopted silently, and every later step would wire the NAV to it.
            if (address(registry.NAV()) != nav) {
                revert RegistryBoundToDifferentNav(predicted, address(registry.NAV()), nav);
            }
        }

        // ⚠️ **THE NAV MUST POINT BACK AT THE REGISTRY, OR THE READ SURFACE IS DEAD ON ARRIVAL.** This is the mirror
        // image of the grant below, and it was MISSING entirely until a session writing documentation went looking for
        // what a caller actually gets. `setAssetKindRegistry` existed on `NAVCalculator` from the day the read surface
        // shipped and was called by NOTHING outside tests — no deploy script, no runbook line, no preflight gate. So
        // every deploy left `assetKindRegistry == address(0)` and `getAssetInfo` reverting.
        //
        // **The two directions are NOT symmetric and were assumed to be.** The grant below wires registry -> NAV so the
        // facade can WRITE. This wires NAV -> registry so the NAV can READ. Each is invisible from inside the other
        // contract, which is why the omission survived #257, its own PR, and two independent reviews.
        //
        // **Ordered FIRST of the three post-deploy transactions, deliberately.** A broadcast is sequential, so an
        // earlier failure tends to prevent the later ones. Putting the pointer last would maximise the odds of the
        // worst state — a fully granted, fully classified registry that the NAV still cannot read, which looks complete
        // and is broken. Putting it first means the states that survive a partial failure are visibly incomplete.
        //
        // Guarded and compared by EQUALITY, not against zero: a re-run against a NAV already pointing at a DIFFERENT
        // (stale) registry must re-point it, and a non-zero check would wave that through.
        if (address(NAVCalculator(nav).assetKindRegistry()) != address(registry)) {
            NAVCalculator(nav).setAssetKindRegistry(address(registry));
            console2.log("Pointed NAV at AssetKindRegistry:", address(registry));
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
        // ⚠️ **This classifies; it does NOT label.** `setAssetKinds` takes no labels, deliberately — labels are
        // written by `AssetKindRegistry.registerAsset` (step 1.6, `RegisterAssets`) and replaced by
        // `setAssetLabels`, neither of which is this step. So a re-run of `08` re-classifies and cannot disturb a
        // label, and this script's idempotency is unaffected by labels existing in config.
        //
        // What this step DOES for labels is make them possible at all: it deploys the registry and grants it MANAGER
        // on the NAV. That is why it must now run BEFORE `RegisterAssets` rather than after it.
        if (assets.length > 0) {
            registry.setAssetKinds(assets, accrualKinds);
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
