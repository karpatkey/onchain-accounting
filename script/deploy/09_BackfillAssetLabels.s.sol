// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {console2} from "forge-std/console2.sol";

import {AssetKindRegistry} from "../../src/nav/AssetKindRegistry.sol";

/// @title 09_BackfillAssetLabels
/// @author kpk
/// @notice Writes each configured asset's display labels onto the chain's `AssetKindRegistry`.
/// @dev **Why this step exists separately from `08`.** Labels are normally written by `RegisterAssets`, as an argument
///      of `AssetKindRegistry.registerAsset` — the atomic register-classify-label facade. That path is only available
///      while the asset is ABSENT from the NAV: `registerAsset` reverts `InvalidArguments` on an already-registered
///      asset, by design. So when a registry is REPLACED, its successor starts with an empty label map and there is no
///      way to refill it through the registration path, because every asset is already registered.
///
///      `setAssetLabels` is the supported route for exactly that case: it requires the asset to be PRESENT on the NAV
///      (reverting `AssetNotRegisteredForLabels` otherwise), which is precisely the post-replacement state.
///
///      **This is idempotent and safe to re-run.** `setAssetLabels` overwrites, so a partial run followed by a full one
///      converges. It writes nothing for an asset whose config carries no `labels` key — an empty list is a legitimate
///      state (`WETH` has none), not an absent one, so skipping and writing `[]` are indistinguishable on-chain and the
///      cheaper choice is taken.
///
///      **Ordering against the pointer flip — run this AFTER `08`, and accept the window.** An earlier version of
///      this note recommended backfilling while the NAV still pointed at the OLD registry and flipping afterwards.
///      That ordering is not reachable through the documented workflow: `08_DeployAssetKindRegistry` deploys the
///      registry AND calls `setAssetKindRegistry` in the same run (transactions 1 and 2 of four), so there is no
///      point at which the new registry exists and the pointer has not yet moved. `REDEPLOY_RUNBOOK.md` §1.4
///      accordingly sequences this step after `08`.
///
///      The consequence is a real but narrow window: between `08` completing and this step completing, the NAV
///      resolves against a registry that is fully CLASSIFIED but not yet LABELLED. That degrades a breadcrumb, not
///      a value — `getAssetInfo` still returns the peg and accrual kinds, only the label list comes back empty. No
///      NAV figure is affected. Keep the two steps adjacent to keep the window short.
///
///      **`setAssetLabels` is NAV-MANAGER-gated, and `07_TransferAdminToSecurityCouncil` revokes the deployer's
///      MANAGER.** So this EOA-broadcast script works only BEFORE that handoff, or on a chain where it has not run.
///      Once the security-council Safe is sole manager, a backfill has to be a Safe transaction batch (the pattern
///      `script/manage/RegisterAssets.s.sol` uses), not a `--broadcast` run — this script will revert
///      `NotAuthorized`. It was used pre-handoff for the 2026-08-19 registry migration, which is why it is
///      EOA-broadcast.
contract BackfillAssetLabels is BaseDeployScript {
    /// @notice Thrown when the target registry argument is unset. Refuses to guess which registry to write to.
    error RegistryNotProvided();

    /// @notice Thrown when the supplied registry has no code on this chain.
    error RegistryHasNoCode(address registry, uint256 chainId);

    /// @notice Thrown when the supplied registry is bound to a different NAV than the one recorded for this chain.
    /// @dev The registry pins its NAV in the constructor, so a mismatch means the wrong address was passed — writing
    ///      labels to it would silently populate a registry nothing reads.
    error RegistryBoundToDifferentNav(address registry, address boundNav, address expectedNav);

    function run() public override {
        uint256 chainId = block.chainid;

        // The registry to write to is passed explicitly rather than read from the deployment record, because during a
        // registry REPLACEMENT the record may still name the outgoing one. Being explicit removes that ambiguity.
        address registryAddr = vm.envOr("ASSET_KIND_REGISTRY", address(0));
        if (registryAddr == address(0)) revert RegistryNotProvided();
        if (registryAddr.code.length == 0) revert RegistryHasNoCode(registryAddr, chainId);

        address nav = ConfigReader.readDeployedAddress(vm, chainId, "NAVCalculatorProxy");
        AssetKindRegistry registry = AssetKindRegistry(registryAddr);
        address boundNav = address(registry.NAV());
        if (boundNav != nav) revert RegistryBoundToDifferentNav(registryAddr, boundNav, nav);

        string[] memory symbols = ConfigReader.getAssetSymbols(vm, chainId);
        console2.log("BackfillAssetLabels: registry", registryAddr);
        console2.log("BackfillAssetLabels: configured assets", symbols.length);

        uint256 written;
        uint256 skipped;

        vm.startBroadcast();
        for (uint256 i; i < symbols.length; ++i) {
            string memory symbol = symbols[i];
            string[] memory labels = ConfigReader.readAssetLabels(vm, chainId, symbol);
            if (labels.length == 0) {
                ++skipped;
                continue;
            }

            string memory addrStr = ConfigReader.readAssetAddress(vm, chainId, symbol);
            address asset = vm.parseAddress(addrStr);
            registry.setAssetLabels(asset, labels);
            ++written;
        }
        vm.stopBroadcast();

        console2.log("BackfillAssetLabels: labels written", written);
        console2.log("BackfillAssetLabels: assets with no labels (skipped)", skipped);
    }
}
