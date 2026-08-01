// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

import {AssetKindRegistry} from "../../src/nav/AssetKindRegistry.sol";
import {PegKind, AccrualKind} from "../../src/utils/AssetKind.sol";

/// @title 08_DeployAssetKindRegistry
/// @author KPK
/// @notice Deploys the per-chain {AssetKindRegistry} and classifies every asset in
///         `nav-config/assets-and-price-feeds/<chainId>.json` in a single batch call.
/// @dev **Fail-closed at deploy time, deliberately.** Every configured asset MUST carry a valid `pegKind` and
///      `accrualKind` string. An absent or unrecognized value ABORTS the deploy — it is not defaulted, not skipped and
///      not warned about. The reasoning is the same as the pre-deploy rate-feed guard's: a default classification is
///      indistinguishable from a real one once it is on-chain, so the only safe place to notice the gap is before the
///      transaction. This script reverting is the guard working.
///
///      Strings rather than integers in the config for the matching reason: a stale integer silently re-maps if an
///      enum ever gains a member, while an unknown string cannot be mistaken for a valid one. The string -> enum
///      mapping lives in {ConfigReader} so production and any harness share one source of truth.
///
///      Independent of the NAV stack: this SCRIPT references neither `PriceFeedLib` nor `NAVRegistryLib`, so it does not
///      gate — or get gated by — a NAV redeploy. Run it any time after the assets config exists.
///
///      **But do not read that as "no pin regeneration is owed".** The FEATURE moves `PriceFeedLib`'s pin
///      (`0xfc6AE534…` → `0x49C18627665562F4bEbae5208BA6eF7428039614`): `AssetKindRegistry`'s presence under `src/`
///      tipped the `via_ir` whole-program stack margin and forced the `PriceFeedLib._assignHealthArrays` extraction.
///      `NAVRegistryLib` is genuinely unchanged. See the note on {AssetKindRegistry}.
///
///      Re-running is safe — the step is idempotent and re-classifies an existing registry rather than deploying a
///      second one — **but only with `PERSIST_DEPLOYMENTS=1`**, since the skip guard reads the record that flag gates.
///      See the warning at the guard itself.
///
///      **The registry is EOA-owned deliberately FOR THIS DEPLOY, with a handover to the security-council Safe
///      PLANNED.** This is a considered choice, not a defect — do not "fix" it by adding a handoff to `07` or a new
///      numbered step. `DEFAULT_ADMIN_ROLE` and `MANAGER` both go to the deployer EOA: every chain config sets
///      `addresses.admin` and `addresses.manager` to the same EOA, so one key governs the registry on each chain.
///
///      The handover **is expected to happen**, riding with the same deferred step-07 Safe-handoff work that was
///      excluded from this wave — the registry is simply in the same position as the NAV and Bridge proxies. When it
///      happens it is a **documented MANUAL operational step performed after the deploy, outside any script** — see
///      "Handing the registry to the council (planned, manual)" in `script/deploy/README.md`. It is deliberately not
///      scripted, which is why `07` does not enumerate this contract and why there is no `09`.
///
///      Until then, stated so it is not rediscovered as a surprise: that one key can re-classify any asset, and the
///      only signal is the `AssetKindSet` event. Nothing consumes the registry today. Watch that event once something
///      does.
contract DeployAssetKindRegistry is BaseDeployScript {
    /// @notice Thrown when a configured asset has no valid `pegKind`/`accrualKind`. Aborts the deploy.
    error AssetKindMissingOrInvalid(string symbol, string field);

    /// @notice Thrown when a configured asset has no resolvable token address.
    error AssetAddressMissing(string symbol);

    /// @notice Thrown when a configured asset resolves to `address(0)`. Named separately from
    ///         {AssetAddressMissing} because the two are different config mistakes: an absent `address` key versus a
    ///         present-but-zero one.
    error AssetAddressZero(string symbol);

    /// @notice Thrown when an asset's `pegKind` disagrees with its `pegToleranceBps` about whether the asset is worth
    ///         $1. Carries both sides so the operator sees the disagreement, not just one half of it.
    /// @dev This repo has TWO authorities on peggedness and they must not silently diverge. `pegToleranceBps` enables
    ///      {PriceFeedLib}'s absolute peg guard and is documented there as set "only on assets whose fundamental value
    ///      is $1"; `pegKind` is the new classification. The invariant is `Pegged` ⇔ `pegToleranceBps > 0`.
    ///
    ///      This guard exists because the divergence was found BY HAND during review: the matrix originally called sDAI
    ///      `Pegged` while the pricing config gave it the wstETH treatment (`divergenceToleranceBps` + monitor feeds,
    ///      no `pegToleranceBps`). Two authorities disagreeing in silence is the failure mode; this makes them disagree
    ///      loudly, before the classification reaches a chain where it is indistinguishable from a correct one.
    error PegKindContradictsPegTolerance(string symbol, bool pegged, uint256 pegToleranceBps);

    function run() public override {
        uint256 chainId = block.chainid;
        ConfigReader.ChainConfig memory chain = ConfigReader.readChainConfig(vm, chainId);

        string[] memory symbols = ConfigReader.getAssetSymbols(vm, chainId);
        console2.log("AssetKindRegistry: classifying assets:", symbols.length);

        // Resolve and VALIDATE the whole set before deploying anything, so a config gap costs nothing but a revert.
        address[] memory assets = new address[](symbols.length);
        PegKind[] memory pegKinds = new PegKind[](symbols.length);
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
            // broadcast begins, `new AssetKindRegistry` and `setAssetKinds` are dispatched as two sequential txs, so if
            // the second never lands — gas, RPC failure, an operator interrupt, a reorg — the registry exists
            // unclassified and its address is already recorded. The idempotent re-run recovers it, which is why this is
            // tolerable rather than fatal. **Verify after broadcasting that classification actually landed;** do not
            // read this guard as making that check unnecessary.
            if (assets[i] == address(0)) revert AssetAddressZero(symbol);

            (PegKind peg, bool pegValid) = ConfigReader.readAssetPegKind(vm, chainId, symbol);
            if (!pegValid) revert AssetKindMissingOrInvalid(symbol, "pegKind");
            pegKinds[i] = peg;

            (AccrualKind accrual, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, chainId, symbol);
            if (!accrualValid) revert AssetKindMissingOrInvalid(symbol, "accrualKind");
            accrualKinds[i] = accrual;

            // Cross-check the two authorities on peggedness. See {PegKindContradictsPegTolerance}: `pegToleranceBps`
            // already gates PriceFeedLib's absolute-$1 guard, so `pegKind == Pegged` must agree with it in BOTH
            // directions. A `Pegged` asset with no peg tolerance is a classification the pricing layer contradicts; a
            // peg-guarded asset marked `Floating` is the same disagreement mirrored.
            //
            // **DO NOT RELAX THIS TO A WARNING, AND DO NOT DELETE IT AS REDUNDANT.** It looks redundant precisely when
            // it is working — the two authorities agree today (measured: 25 of 93 configured rows are `Pegged`, and
            // exactly those 25 carry `pegToleranceBps`, zero violations). This is the guard that makes them fail LOUDLY
            // rather than silently diverging, and that divergence is not hypothetical: it was already found once, by
            // hand during review, when the kind matrix called sDAI `Pegged` while the pricing config gave it the wstETH
            // treatment. A label that contradicts the live peg guard is indistinguishable from a correct one once it is
            // on-chain, which is why this must abort the deploy rather than log.
            //
            // Known tension in the FORWARD direction (`Pegged` ⇒ tolerance set), for whoever hits it first: it makes a
            // classification axis depend on an operational tolerance choice. A USD stablecoin priced off a fundamental
            // $1 feed, where a peg guard would be redundant, is definitionally `Pegged` yet would legitimately carry no
            // tolerance. No such asset exists across the seven configured chains today. If one appears, the right move
            // is to reconsider this invariant deliberately — NOT to mislabel the asset `Floating` to silence the abort.
            bool pegged = peg == PegKind.Pegged;
            uint256 pegToleranceBps = ConfigReader.readAssetPegToleranceBps(vm, chainId, symbol);
            if (pegged != (pegToleranceBps > 0)) {
                revert PegKindContradictsPegTolerance(symbol, pegged, pegToleranceBps);
            }
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

        AssetKindRegistry registry;
        if (existing != address(0)) {
            registry = AssetKindRegistry(existing);
            console2.log("AssetKindRegistry already deployed at:", existing);
        } else {
            // The deployer keeps MANAGER so the same deploy run — NOT the same transaction; under
            // `vm.startBroadcast()` the constructor and `setAssetKinds` are two separate txs — can classify. Admin goes
            // to the chain's configured admin, which is that same EOA on every chain. Both roles landing on the EOA is
            // deliberate FOR THIS DEPLOY, and a handover to the council IS EXPECTED LATER (it rides the deferred
            // step-07 Safe-handoff work). `07` deliberately does not know this contract exists, so that handover is a
            // documented MANUAL post-deploy step, not a scripted one — see the docstring above and README.
            registry = new AssetKindRegistry(chain.admin, msg.sender);
        }

        // Re-classification is permitted and event-emitting by design, so this runs on both paths.
        if (assets.length > 0) {
            registry.setAssetKinds(assets, pegKinds, accrualKinds);
        }

        vm.stopBroadcast();

        // `saveDeployedAddress`, not `ConfigReader.writeDeployedAddress`: the base-class helper gates the write on
        // `PERSIST_DEPLOYMENTS` so a dry run cannot persist a SIMULATED address into
        // `script/config/deployments/<chainId>.json` — the one place deployed addresses live, and the source the
        // preflight tooling and the published contract-delta both derive from. `08` was the only deploy script
        // bypassing that gate.
        if (existing == address(0)) saveDeployedAddress("AssetKindRegistry", address(registry));
    }
}
