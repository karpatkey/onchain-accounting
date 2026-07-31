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
///      exists.
contract DeployAssetKindRegistry is BaseDeployScript {
    /// @notice Thrown when a configured asset has no valid `pegKind`/`accrualKind`. Aborts the deploy.
    error AssetKindMissingOrInvalid(string symbol, string field);

    /// @notice Thrown when a configured asset has no resolvable token address.
    error AssetAddressMissing(string symbol);

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

            (PegKind peg, bool pegValid) = ConfigReader.readAssetPegKind(vm, chainId, symbol);
            if (!pegValid) revert AssetKindMissingOrInvalid(symbol, "pegKind");
            pegKinds[i] = peg;

            (AccrualKind accrual, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, chainId, symbol);
            if (!accrualValid) revert AssetKindMissingOrInvalid(symbol, "accrualKind");
            accrualKinds[i] = accrual;
        }

        vm.startBroadcast();

        // The deployer keeps MANAGER so this same transaction can classify; admin goes to the chain's configured
        // admin. Matches the rest of the deploy flow, which is EOA-driven with a later handoff.
        AssetKindRegistry registry = new AssetKindRegistry(chain.admin, msg.sender);
        if (assets.length > 0) {
            registry.setAssetKinds(assets, pegKinds, accrualKinds);
        }

        vm.stopBroadcast();

        console2.log("AssetKindRegistry deployed:", address(registry));
        ConfigReader.writeDeployedAddress(vm, chainId, "AssetKindRegistry", address(registry));
    }
}
