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
///      Independent of the NAV stack: this touches neither `PriceFeedLib` nor `NAVRegistryLib`, so neither library pin
///      moves and this step does not gate — or get gated by — a NAV redeploy. Run it any time after the assets config
///      exists. Re-running is safe: the step is idempotent and re-classifies an existing registry rather than
///      deploying a second one.
///
///      **⚠️ OPEN: the registry has no admin-handoff path.** `07_TransferAdminToSecurityCouncil` enumerates the
///      NAV/Bridge proxies and the bridge adapters; it has no notion of `AssetKindRegistry`. So this contract joins the
///      system MANAGER-governed and mutable with `DEFAULT_ADMIN_ROLE` and `MANAGER` both on the deployer EOA — and on
///      chain 1 `admin` and `manager` are configured to the SAME EOA, so it is literally one key. Nothing consumes the
///      registry yet, which is why this ships; once something does, a compromised or careless deployer key can silently
///      re-classify assets and the only signal is `AssetKindSet`, which nothing watches. Either add this contract to
///      `07`'s target list or make the EOA-governed end state a deliberate, documented decision.
contract DeployAssetKindRegistry is BaseDeployScript {
    /// @notice Thrown when a configured asset has no valid `pegKind`/`accrualKind`. Aborts the deploy.
    error AssetKindMissingOrInvalid(string symbol, string field);

    /// @notice Thrown when a configured asset has no resolvable token address.
    error AssetAddressMissing(string symbol);

    /// @notice Thrown when a configured asset resolves to `address(0)`. Named separately from
    ///         {AssetAddressMissing} because the two are different config mistakes: an absent `address` key versus a
    ///         present-but-zero one.
    error AssetAddressZero(string symbol);

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
            // reject it, but from inside the broadcast and with a bare `InvalidArguments()` that names neither the
            // symbol nor the field — the least useful error in a script whose whole purpose is to name the offending
            // row. Rejecting it pre-broadcast also stops this script's correctness depending on `forge script`
            // simulating before it sends: under `--skip-simulation` the deploy tx would land and only the
            // classification would revert, leaving a deployed-but-unclassified registry.
            if (assets[i] == address(0)) revert AssetAddressZero(symbol);

            (PegKind peg, bool pegValid) = ConfigReader.readAssetPegKind(vm, chainId, symbol);
            if (!pegValid) revert AssetKindMissingOrInvalid(symbol, "pegKind");
            pegKinds[i] = peg;

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
        address existing = readDeployedAddress("AssetKindRegistry");

        vm.startBroadcast();

        AssetKindRegistry registry;
        if (existing != address(0)) {
            registry = AssetKindRegistry(existing);
            console2.log("AssetKindRegistry already deployed at:", existing);
        } else {
            // The deployer keeps MANAGER so the same deploy run — NOT the same transaction; under
            // `vm.startBroadcast()` the constructor and `setAssetKinds` are two separate txs — can classify. Admin
            // goes to the chain's configured admin. Matches the rest of the deploy flow, which is EOA-driven with a
            // later handoff. NOTE: `07_TransferAdminToSecurityCouncil` does not know this contract exists, so both
            // roles stay on the deployer EOA until that is addressed — see the docstring above.
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
