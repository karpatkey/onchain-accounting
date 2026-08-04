// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {INAVCalculator} from "../../src/nav/INAVCalculator.sol";
import {IPrices} from "../../src/prices/IPrices.sol";
import {IAssetKindRegistry} from "../../src/nav/IAssetKindRegistry.sol";
import {AccrualKind} from "../../src/utils/AssetKind.sol";
import {console2} from "forge-std/console2.sol";

/// @title RegisterAssets
/// @notice Registers each asset from `script/config/nav-config/assets-and-price-feeds/<id>.json` on NAVCalculator, wiring ALL of the asset's
///         configured price feeds: the first via `registerAsset`, any additional via `addPriceFeed` (ADR 0009
///         multi-feed redundancy). Generates a Safe tx batch and (when the signer is MANAGER) can broadcast.
/// @dev
///   - Asset list per chain comes from `assets.json` keys (no hardcoded list).
///   - Each asset's `priceFeeds[]` drives the feeds. `Custom` feeds resolve their on-chain address from the
///     deployments file (`deployments/<id>.json .customPriceFeeds.<name>`), so 03_DeployPriceFeeds must run first.
///   - Idempotent: feeds already present on-chain are skipped, so an asset already registered with all its
///     configured feeds is a no-op, while any new trailing feeds are topped up via addPriceFeed (ADR-0009
///     redundancy). A pre-registered asset with no feed (the NATIVE_ADDRESS sentinel from initialize) gets its
///     first feed via addPriceFeed too (registerAsset is used only for an unregistered asset's primary feed).
///   - Requires --rpc-url so the script can check on-chain registration state.
contract RegisterAssets is BaseDeployScript {
    using ConfigReader for *;

    address private constant NATIVE_SENTINEL = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @notice `AssetKindRegistry` for this chain, resolved once in {run}. An asset's PRIMARY registration is routed
    ///         through it so the asset is registered, classified and labelled in ONE transaction.
    /// @dev Zero when `08_DeployAssetKindRegistry` has not run. That is a hard stop for any asset that still needs
    ///      registering — see {AssetKindRegistryNotDeployed}.
    address private assetKindRegistry;

    /// @notice No `AssetKindRegistry` is recorded for this chain, but at least one asset still needs its primary
    ///         registration.
    /// @dev **This is an ordering error, not a config error: run `08_DeployAssetKindRegistry` first.** Labels can be
    ///      written ONLY by `AssetKindRegistry.registerAsset`, and only at registration — an asset registered directly
    ///      on the NAV can never be labelled afterwards. Falling back to `NAVCalculator.registerAsset` would therefore
    ///      "succeed" while permanently costing every asset in this run its labels, which is exactly the silent
    ///      degradation this repo's fail-closed guards exist to prevent.
    error AssetKindRegistryNotDeployed(uint256 chainId);

    /// @notice The NAV does not point back at the recorded `AssetKindRegistry`.
    /// @dev **An ordering error like {AssetKindRegistryNotDeployed}, but a subtler one: the registry EXISTS and the
    ///      write direction may be wired, while the READ direction is not.** `08` sets this pointer; if that
    ///      transaction alone failed, registration here would still succeed and every `getAssetInfo` call would revert
    ///      forever afterwards.
    ///
    ///      Stopping here is not this script's own need — it can register perfectly well through a registry the NAV
    ///      cannot read. It stops because this is the NEXT step after `08`, so it is the earliest place a missed
    ///      pointer becomes loud instead of silent, in the same way a dead facade now blocks at the first asset.
    ///
    ///      Not a guard for an unreachable state: `08` writes the pointer, but `08` is four sequential broadcast
    ///      transactions and any of them can fail alone. This is reachable exactly when one did.
    error NavNotPointedAtAssetKindRegistry(address nav, address pointsAt, address expected);

    /// @notice An asset's `accrualKind` is missing or unrecognised in config.
    /// @dev Registration now carries the classification, so a bad kind stops the batch here rather than being
    ///      discovered later by `08`. There is deliberately no default — see `ConfigReader.accrualKindFromString`.
    error AssetAccrualKindMissingOrInvalid(string symbol);

    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        // Resolved BEFORE planning: `_planFeedActs` encodes a primary registration against this address, so it has to
        // exist by the time the first action is built. `08_DeployAssetKindRegistry` writes the record.
        assetKindRegistry = readDeployedAddress("AssetKindRegistry");
        // Both directions of the link are checked before planning, because both are required for the result to be
        // usable and only one of them is required for this script to SUCCEED. Registration would work against a NAV
        // that cannot read the registry; the deploy would then be complete, green, and dead on the read side.
        if (assetKindRegistry != address(0)) {
            address pointsAt = address(NAVCalculator(navProxy).assetKindRegistry());
            if (pointsAt != assetKindRegistry) {
                revert NavNotPointedAtAssetKindRegistry(navProxy, pointsAt, assetKindRegistry);
            }
        }
        string[] memory symbols = ConfigReader.getAssetSymbols(vm, currentChainId);

        console2.log("\n=== Register Assets (from assets.json) ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("Assets in config:", symbols.length);
        console2.log("NAVCalculator proxy:", navProxy);

        if (symbols.length == 0) {
            console2.log("No assets configured for this chain.");
            return;
        }
        if (navProxy == address(0)) {
            console2.log("NAVCalculator not deployed for this chain. Deploy it first, then re-run.");
            return;
        }
        if (navProxy.code.length == 0) {
            console2.log("Run with --rpc-url so the script can verify on-chain registration state.");
            return;
        }

        // Pass 1: count actions (registerAsset + addPriceFeed) across all assets.
        uint256 total;
        for (uint256 i = 0; i < symbols.length; i++) {
            total += _planAsset(symbols[i], navProxy).length;
        }
        console2.log("Planned actions:", total);
        if (total == 0) {
            console2.log("Nothing to register or wire. Exiting.");
            return;
        }

        // Pass 2: build the Safe tx batch.
        SafeTxBuilder.Transaction[] memory batch = new SafeTxBuilder.Transaction[](total);
        uint256 j;
        for (uint256 i = 0; i < symbols.length; i++) {
            bytes[] memory acts = _planAsset(symbols[i], navProxy);
            if (acts.length > 0) console2.log("  wiring", symbols[i], acts.length);
            for (uint256 k = 0; k < acts.length; k++) {
                batch[j++] = SafeTxBuilder.call(_targetFor(acts[k], navProxy), 0, acts[k]);
            }
        }

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-register-assets.json"));
        writeSafeTx(
            filename,
            "Register assets in NAVCalculator",
            string(abi.encodePacked("Register/wire ", vm.toString(j), " feed(s) from assets.json")),
            batch
        );

        console2.log("MultiSend calldata (for a MANAGER caller):");
        console2.log(vm.toString(_buildMultiSendCallData(batch)));

        _broadcastManagerMultiSend(batch);
        console2.log(string(abi.encodePacked("Safe transaction written to safe-transactions/", filename)));
    }

    /// @notice Returns the ordered calldata actions to fully wire one asset's feeds, or an empty array to skip it.
    function _planAsset(string memory symbol, address navProxy) internal view returns (bytes[] memory acts) {
        acts = new bytes[](0);

        string memory addrStr = ConfigReader.readAssetAddress(vm, currentChainId, symbol);
        if (bytes(addrStr).length == 0) return acts;
        address asset = vm.parseAddress(addrStr);
        if (asset == address(0)) return acts;

        uint256 feedCount = ConfigReader.assetFeedCount(vm, currentChainId, symbol);
        if (feedCount == 0) return acts; // no configured feed → nothing to register

        // On-chain state.
        (bool ok, bytes memory data) =
            navProxy.staticcall(abi.encodeWithSelector(INAVCalculator.isAssetRegistered.selector, asset));
        bool registered = ok && data.length > 0 && abi.decode(data, (bool));
        if (!registered && _hasNoCode(asset)) return acts; // not a contract and not pre-registered

        uint256 onChainFeeds;
        if (registered) {
            (bool okc, bytes memory cd) =
                navProxy.staticcall(abi.encodeWithSelector(IPrices.getPriceFeedCount.selector, asset));
            // If the on-chain feed count can't be read, skip rather than risk re-adding existing feeds (a duplicate
            // addPriceFeed reverts and would abort the whole batch).
            if (!(okc && cd.length == 32)) return acts;
            onChainFeeds = abi.decode(cd, (uint256));
        }

        // An unregistered asset's PRIMARY oracle must be its first configured feed (priceFeeds[0]). If feed[0] is not
        // resolvable yet (e.g. a Custom feed not deployed), skip the whole asset rather than silently promote a
        // fallback feed to primary — deploy the primary feed first (03_DeployPriceFeeds), then re-run.
        if (!registered && !_feedResolvable(symbol, 0)) {
            console2.log("  [skip] primary feed unresolved (deploy it first):", symbol);
            return acts;
        }

        // Pricing feeds and monitor/tolerance actions are each built in their own frame, then concatenated — this
        // keeps _planAsset under the via_ir stack limit.
        bytes[] memory feedActs = _planFeedActs(symbol, asset, registered, onChainFeeds, feedCount);
        bytes[] memory monActs = _planMonitorActs(symbol, asset, registered, navProxy);
        acts = _concat(feedActs, monActs);
    }

    /// @notice Plans an asset's pricing-feed actions (registerAsset for the primary; addPriceFeed for trailing new
    ///         feeds). The first `onChainFeeds` resolvable feeds are already present (feeds are appended, never
    ///         reordered) and skipped.
    function _planFeedActs(
        string memory symbol,
        address asset,
        bool registered,
        uint256 onChainFeeds,
        uint256 feedCount
    ) private view returns (bytes[] memory acts) {
        bytes[] memory tmp = new bytes[](feedCount);
        uint256 n;
        uint256 resolvableIdx;
        for (uint256 i = 0; i < feedCount; i++) {
            (IPrices.PriceType pt, bool validType) = _feedType(symbol, i);
            if (!validType) continue;
            string memory faddr = ConfigReader.readAssetFeedAddress(vm, currentChainId, symbol, i);
            if (bytes(faddr).length == 0) continue; // unresolved (e.g. Custom feed not deployed yet)
            address feed = vm.parseAddress(faddr);
            if (feed == address(0)) continue;

            if (!registered && resolvableIdx == 0) {
                // Primary = first resolvable feed; we verified above that feed[0] resolves, so this IS config feed[0].
                //
                // ⚠️ **Routed through `AssetKindRegistry`, NOT `NAVCalculator`, and that is load-bearing.** The
                // registry forwards to `NAVCalculator.registerAsset` in the same transaction, so the asset is
                // registered, classified and LABELLED atomically. Registration is the only moment labels can ever be
                // written; an asset registered directly on the NAV is unlabellable for as long as it stays
                // registered. The batch is mixed-target by design — every other action below still points at the NAV.
                uint256 hb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, i));
                if (assetKindRegistry == address(0)) revert AssetKindRegistryNotDeployed(currentChainId);
                (AccrualKind accrual, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, currentChainId, symbol);
                if (!accrualValid) revert AssetAccrualKindMissingOrInvalid(symbol);
                tmp[n++] = abi.encodeCall(
                    IAssetKindRegistry.registerAsset,
                    (asset, feed, pt, hb, accrual, ConfigReader.readAssetLabels(vm, currentChainId, symbol))
                );
            } else if (registered && resolvableIdx < onChainFeeds) {
                // Already present on-chain (added in a prior run) — skip to avoid a duplicate addPriceFeed.
            } else {
                uint256 hb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, i));
                tmp[n++] = abi.encodeCall(NAVCalculator.addPriceFeed, (asset, feed, pt, hb));
            }
            resolvableIdx++;
        }
        acts = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            acts[i] = tmp[i];
        }
    }

    /// @notice Concatenates two calldata-action arrays.
    function _concat(bytes[] memory a, bytes[] memory b) private pure returns (bytes[] memory out) {
        out = new bytes[](a.length + b.length);
        uint256 w;
        for (uint256 i = 0; i < a.length; i++) {
            out[w++] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[w++] = b[i];
        }
    }

    /// @notice Plans an asset's divergence/peg tolerance setters + monitor-feed additions. setDivergenceTolerance
    ///         precedes any addMonitorFeed (required before a monitor can be added); both run after registerAsset in
    ///         the same batch. Idempotent: skips the first `onChainMonitors` resolvable monitors already present.
    function _planMonitorActs(string memory symbol, address asset, bool registered, address navProxy)
        private
        view
        returns (bytes[] memory acts)
    {
        uint256 monCount = ConfigReader.assetMonitorFeedCount(vm, currentChainId, symbol);
        uint256 divTolBps = ConfigReader.readAssetDivergenceToleranceBps(vm, currentChainId, symbol);
        uint256 pegTolBps = ConfigReader.readAssetPegToleranceBps(vm, currentChainId, symbol);

        // The heavy build loop runs in its own frame (_buildMonitorActs) and the fail-fast guard in this thin one,
        // so neither trips the via_ir stack limit.
        bool addsMonitor;
        (acts, addsMonitor) = _buildMonitorActs(symbol, asset, registered, navProxy, monCount, divTolBps, pegTolBps);

        // Fail fast on a config that would make this batch revert on-chain (tolerance ranges + monitor-without-
        // tolerance). `addsMonitor` — not the raw config monitor count — is the true signal: already-present
        // (idempotency-skipped) and unresolvable monitors emit no addMonitorFeed, so a re-run must not abort.
        _requireTolerancesPlannable(navProxy, asset, symbol, monCount, divTolBps, pegTolBps, addsMonitor);
    }

    /// @notice Builds the setDivergenceTolerance/setPegTolerance/addMonitorFeed calldata for an asset (no
    ///         validation — the caller does the fail-fast). Returns the acts plus whether any addMonitorFeed was
    ///         actually emitted (resolvable + not already on-chain). Own frame to stay under the via_ir stack limit.
    function _buildMonitorActs(
        string memory symbol,
        address asset,
        bool registered,
        address navProxy,
        uint256 monCount,
        uint256 divTolBps,
        uint256 pegTolBps
    ) private view returns (bytes[] memory acts, bool addsMonitor) {
        // Read the on-chain monitor SET (not just its count): addMonitorFeed reverts MonitorFeedAlreadyRegistered on
        // a duplicate, and removeMonitorFeed is swap-and-pop (reorders), so a positional "skip first N" check would
        // re-add a still-present feed after any out-of-band removal and abort the whole batch. Membership is robust.
        IPrices.PriceFeedConfig[] memory onChain;
        if (registered) {
            (bool okm, bytes memory md) =
                navProxy.staticcall(abi.encodeWithSelector(IPrices.getMonitorFeeds.selector, asset));
            if (okm && md.length >= 64) onChain = abi.decode(md, (IPrices.PriceFeedConfig[]));
        }

        bytes[] memory tmp = new bytes[](monCount + 2);
        uint256 n;
        if (monCount > 0 && divTolBps > 0) {
            tmp[n++] = abi.encodeCall(NAVCalculator.setDivergenceTolerance, (asset, uint32(divTolBps)));
        }
        if (pegTolBps > 0) {
            tmp[n++] = abi.encodeCall(NAVCalculator.setPegTolerance, (asset, uint32(pegTolBps)));
        }

        for (uint256 i = 0; i < monCount; i++) {
            (IPrices.PriceType pt, bool validType) =
                ConfigReader.readAssetMonitorFeedPriceType(vm, currentChainId, symbol, i);
            if (!validType) continue;
            string memory maddr = ConfigReader.readAssetMonitorFeedAddress(vm, currentChainId, symbol, i);
            if (bytes(maddr).length == 0) continue; // unresolved (e.g. Custom monitor not deployed yet)
            address feed = vm.parseAddress(maddr);
            if (feed == address(0) || _containsFeed(onChain, feed)) continue; // skip already-registered monitors

            uint256 hb = vm.parseUint(ConfigReader.readAssetMonitorFeedHeartbeat(vm, currentChainId, symbol, i));
            tmp[n++] = abi.encodeCall(NAVCalculator.addMonitorFeed, (asset, feed, pt, hb));
            addsMonitor = true;
        }

        acts = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            acts[i] = tmp[i];
        }
    }

    /// @notice True if `feed` is already present in the on-chain feed config array.
    function _containsFeed(IPrices.PriceFeedConfig[] memory feeds, address feed) private pure returns (bool) {
        for (uint256 i = 0; i < feeds.length; i++) {
            if (feeds[i].priceFeed == feed) return true;
        }
        return false;
    }

    /// @dev Maps a feed `type` string to the on-chain PriceType enum. validType=false → skip the feed.
    function _feedType(string memory symbol, uint256 i) private view returns (IPrices.PriceType pt, bool validType) {
        // Shared type→enum mapping (single source of truth in ConfigReader, also used by the integration harness).
        return ConfigReader.readAssetFeedPriceType(vm, currentChainId, symbol, i);
    }

    /// @notice Whether feed `i` of `symbol` is resolvable (recognized type + a non-zero address now available).
    function _feedResolvable(string memory symbol, uint256 i) private view returns (bool) {
        (, bool validType) = _feedType(symbol, i);
        if (!validType) return false;
        string memory faddr = ConfigReader.readAssetFeedAddress(vm, currentChainId, symbol, i);
        if (bytes(faddr).length == 0) return false;
        return vm.parseAddress(faddr) != address(0);
    }

    function _broadcastManagerMultiSend(SafeTxBuilder.Transaction[] memory batch) internal {
        vm.startBroadcast();
        for (uint256 i = 0; i < batch.length; i++) {
            // Honor the Transaction struct: forward value, and refuse a delegatecall — an EOA broadcast
            // executes a plain CALL and cannot faithfully simulate a Safe DELEGATECALL, so fail loud
            // rather than silently mis-execute. (This path currently only builds 0-value CALLs.)
            require(batch[i].operation == 0, "EOA broadcast is CALL-only (delegatecall not simulable)");
            (bool success, bytes memory data) = batch[i].to.call{value: batch[i].value}(batch[i].data);
            if (!success) {
                require(
                    false,
                    string(abi.encodePacked("registerAsset failed at index ", vm.toString(i), ": ", _revertMsg(data)))
                );
            }
        }
        vm.stopBroadcast();
        console2.log("[OK] Broadcast", batch.length, "tx(s); all feeds wired.");
    }

    /// @notice Which contract an action is addressed to. Every action goes to the NAV except a primary registration,
    ///         which goes to `AssetKindRegistry` so the asset is registered, classified and labelled in one call.
    /// @dev **The batch is mixed-target, and every layer it passes through carries the target PER TRANSACTION rather
    ///      than once for the batch** — verified rather than assumed, because until this change every action pointed
    ///      at the NAV and a batch-wide field would have been indistinguishable from a per-transaction one:
    ///        - the Safe-tx JSON: `SafeTxBuilder.writeSafeTx` emits `"to"` inside its per-transaction loop;
    ///        - the MultiSend encoding: `to` is packed as 20 bytes per transaction, per the MultiSend standard;
    ///        - the EOA broadcast: `_broadcastManagerMultiSend` calls `batch[i].to`, dispatching each individually.
    ///
    ///      Dispatching on the SELECTOR rather than on the planner's position keeps this correct if the plan order
    ///      ever changes: the two registration calls have different signatures — `registerAsset(address,address,
    ///      uint8,uint256)` on the NAV versus the registry's six-parameter form — so the selector is unambiguous.
    function _targetFor(bytes memory action, address navProxy) private view returns (address) {
        if (action.length < 4) return navProxy;
        bytes4 sel;
        // The first word of a `bytes` in memory is its length, so the payload starts at +32.
        assembly {
            sel := mload(add(action, 32))
        }
        return sel == IAssetKindRegistry.registerAsset.selector ? assetKindRegistry : navProxy;
    }

    function _hasNoCode(address asset) private view returns (bool) {
        if (asset == NATIVE_SENTINEL) return false;
        return asset.code.length == 0;
    }

    function _equals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _encodeMultiSend(SafeTxBuilder.Transaction[] memory txs) private pure returns (bytes memory encoded) {
        for (uint256 i = 0; i < txs.length; i++) {
            encoded = abi.encodePacked(
                encoded, bytes1(txs[i].operation), txs[i].to, txs[i].value, uint256(txs[i].data.length), txs[i].data
            );
        }
    }

    function _buildMultiSendCallData(SafeTxBuilder.Transaction[] memory txs) private pure returns (bytes memory) {
        return abi.encodeWithSignature("multiSend(bytes)", _encodeMultiSend(txs));
    }
}
