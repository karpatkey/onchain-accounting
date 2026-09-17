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
///   - Idempotent on TOLERANCES too: `setDivergenceTolerance` / `setPegTolerance` are emitted only when the
///     configured value differs from what the NAV already holds. Before that check existed, registering ONE asset
///     planned 27 transactions — 24 of them rewriting tolerances that already equalled config. They changed no
///     state, but they were 24 needless transactions against a live NAV, and under `--slow` (a receipt awaited per
///     transaction) they turned a 3-transaction job into ~5 minutes.
///   - Requires --rpc-url so the script can check on-chain registration state.
///
///   - **RUN IT UNDER `FOUNDRY_PROFILE=slow` WHENEVER IT HAS REAL WORK TO DO.** Against mainnet's 44 assets the
///     default profile dies with a bare `EvmError: MemoryOOG` — no message, nothing naming the cause. Only
///     `profile.slow` raises `memory_limit` (and `gas_limit`) off forge's 32 MiB default; its own comment in
///     `foundry.toml` documents the same failure for the integration harness, so this is the designed mechanism
///     here rather than a workaround.
///
///     Measured, so the boundary is not guessed: a re-run with nothing to do plans 0 actions and completes fine on
///     the default profile — which is why this went unnoticed — while **ONE** action is already enough to OOM.
///     Confirmed at 1, 2, 4, 8, 12 and 17 actions, and against `origin/main`'s config with no XAUt in it, so this
///     predates the XAUt entry and is not caused by it.
///
///     Because ONE action is enough, the cause is NOT the batch size. The scan itself already sits just under the
///     32 MiB ceiling and any batch at all tips it over. The dominant cost is `ConfigReader`: field readers such as
///     `_readUintOrZero` call `_readOrEmpty(vm, _navAssetsPath(...))`, so the ENTIRE per-chain JSON (~28 KiB, 44
///     assets) is re-read and re-parsed for EVERY FIELD OF EVERY ASSET, and Solidity frees nothing. `SafeTxBuilder`
///     compounds it — `writeSafeTx` and `encodeMultiSend` both accumulate via `x = abi.encodePacked(x, ...)` inside
///     loops, which is quadratic in transaction count — but it is the straw, not the load. Fixing this properly
///     means caching the parsed config per run, which touches every deploy script, so it belongs in its own PR.
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
    /// @dev **This is an ordering error, not a config error: run `08_DeployAssetKindRegistry` first.** Only
    ///      `AssetKindRegistry.registerAsset` registers, classifies and labels atomically. Falling back to
    ///      `NAVCalculator.registerAsset` would "succeed" while leaving every asset in this run unclassified AND
    ///      unlabelled — exactly the silent degradation this repo's fail-closed guards exist to prevent.
    ///
    ///      Both halves are now recoverable after the fact (`setAssetKinds`, `setAssetLabels`), so the cost is a
    ///      batch of recovery transactions rather than the permanent loss an earlier revision of this note claimed.
    ///      **That does not weaken the guard.** What it refuses is a run that reports success while producing a
    ///      half-registered state nothing flags — and a reader tempted to relax it into a fallback should note that
    ///      it is what caught the real step-order divergence between this script and the runbook during the fork
    ///      rehearsal.
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

    /// @notice `getPriceFeedAt` could not be read while verifying a positional skip.
    error FeedPositionUnreadable(address asset, uint256 index);

    /// @notice The config declares a different `priceType` than the feed is registered with.
    /// @dev Caught at PLAN time. `addOrModifyPriceFeed` would reject it at execution, after the Safe batch
    ///      file has already been written and possibly signed.
    error FeedTypeMismatch(address asset, uint256 index, IPrices.PriceType onChainType, IPrices.PriceType configType);

    /// @notice The on-chain feed at this index is not the config feed — the append-only assumption is broken.
    /// @dev Loud on purpose. Since the heartbeat upsert, silently continuing would rewrite the WRONG feed's
    ///      staleness window instead of reverting the batch.
    error FeedOrderMismatch(address asset, uint256 index, address onChainFeed, address configFeed);

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
        bytes[] memory feedActs = _planFeedActs(symbol, asset, registered, onChainFeeds, feedCount, navProxy);
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
        uint256 feedCount,
        address navProxy
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
                // registered, classified and LABELLED atomically — one transaction rather than three, with no window
                // in which the NAV holds an asset the registry knows nothing about. The batch is mixed-target by
                // design — every other action below still points at the NAV.
                uint256 hb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, i));
                if (assetKindRegistry == address(0)) revert AssetKindRegistryNotDeployed(currentChainId);
                (AccrualKind accrual, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, currentChainId, symbol);
                if (!accrualValid) revert AssetAccrualKindMissingOrInvalid(symbol);
                tmp[n++] = abi.encodeCall(
                    IAssetKindRegistry.registerAsset,
                    (asset, feed, pt, hb, accrual, ConfigReader.readAssetLabels(vm, currentChainId, symbol))
                );
            } else if (registered && resolvableIdx < onChainFeeds) {
                // Already present on-chain (added in a prior run) — skip, but verify by ADDRESS first.
                //
                // This branch used to skip on POSITION alone, resting on "feeds are appended, never reordered"
                // with the revert from a duplicate `addPriceFeed` as the backstop if that assumption ever broke.
                // The upsert removed that backstop: `addOrModifyPriceFeed` now SUCCEEDS on an already-registered
                // feed whenever the heartbeat differs. So a config reordered from [A, B] to [B, A] against an
                // on-chain [A] would skip index 0 as "already present", then quietly rewrite A's staleness
                // window and never add B — where before it aborted the whole batch loudly.
                //
                // Reverting here restores that loudness. This runs during `forge script` simulation, so a
                // mismatch is caught before anything is broadcast.
                (bool okf, bytes memory fd) =
                    navProxy.staticcall(abi.encodeWithSelector(IPrices.getPriceFeedAt.selector, asset, resolvableIdx));
                if (!okf || fd.length == 0) revert FeedPositionUnreadable(asset, resolvableIdx);
                bytes memory act = _existingFeedAct(navProxy, asset, resolvableIdx, feed, pt, symbol, i);
                if (act.length != 0) tmp[n++] = act;
            } else {
                // Trailing feed (config lists more than the chain carries). Check MEMBERSHIP first: the upsert
                // replaced the duplicate-address revert that used to abort the batch loudly, so a duplicated
                // config address here would silently rewrite the incumbent feed staleness window instead.
                uint256 hb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, i));
                if (registered && _feedAlreadyRegistered(navProxy, asset, onChainFeeds, feed)) {
                    revert FeedOrderMismatch(asset, resolvableIdx, feed, feed);
                }
                tmp[n++] = abi.encodeCall(NAVCalculator.addOrModifyPriceFeed, (asset, feed, pt, hb));
            }
            resolvableIdx++;
        }
        acts = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            acts[i] = tmp[i];
        }
    }

    /// @notice Concatenates two calldata-action arrays.
    /// @notice For a feed already present on-chain: verify it is the config-declared one, and return an
    ///         `addOrModifyPriceFeed` action if its heartbeat has drifted from config. Empty when aligned.
    /// @dev Extracted so its locals do not live in `_planFeedActs`' frame, which was one stack slot over
    ///      solc's limit with them inlined.
    ///
    ///      Skipping on ADDRESS alone made this a silent no-op for a changed configured heartbeat — the one
    ///      operation `addOrModifyPriceFeed` was added to perform — and stranded TRAILING feeds entirely,
    ///      since `RealignHeartbeats` only ever touches index 0.
    /// @dev Whether `feed` is already registered for `asset` at any index below `count`.
    /// @dev Guards the trailing-feed branch. Pre-upsert, a duplicate address reverted
    ///      `PriceFeedAlreadyRegistered` and aborted the batch; now it would succeed and rewrite a live
    ///      staleness window, so the membership test has to be explicit.
    function _feedAlreadyRegistered(address navProxy, address asset, uint256 count, address feed)
        private
        view
        returns (bool)
    {
        for (uint256 k = 0; k < count; k++) {
            (bool ok, bytes memory d) =
                navProxy.staticcall(abi.encodeWithSelector(IPrices.getPriceFeedAt.selector, asset, k));
            if (!ok || d.length < 128) continue;
            if (abi.decode(d, (IPrices.PriceFeedConfig)).priceFeed == feed) return true;
        }
        return false;
    }

    function _existingFeedAct(
        address navProxy,
        address asset,
        uint256 idx,
        address feed,
        IPrices.PriceType pt,
        string memory symbol,
        uint256 i
    ) private view returns (bytes memory) {
        (bool okf, bytes memory fd) = navProxy.staticcall(
            abi.encodeWithSelector(IPrices.getPriceFeedAt.selector, asset, idx)
        );
        if (!okf || fd.length < 128) revert FeedPositionUnreadable(asset, idx);

        IPrices.PriceFeedConfig memory onChain = abi.decode(fd, (IPrices.PriceFeedConfig));
        if (onChain.priceFeed != feed) revert FeedOrderMismatch(asset, idx, onChain.priceFeed, feed);

        // A feed's TYPE is identity, and `addOrModifyPriceFeed` rejects a changed one
        // (`PriceFeedLib.PriceFeedTypeImmutable`). Compare it here, where the value is already decoded,
        // because this is the only failure in this script that would otherwise get PAST planning:
        // `FeedOrderMismatch` and `AssetKindRegistryNotDeployed` both abort before `writeSafeTx`, but a
        // `priceType` drift plans cleanly, the Safe batch is WRITTEN TO DISK (`vm.writeJson` is a filesystem
        // cheatcode, not rolled back by a later revert), and only then does execution die — leaving a
        // fully-formed, signable batch that the script itself already proved cannot execute, and taking the
        // whole chain's MultiSend with it. The sibling `RealignHeartbeats` passes the STORED type read back
        // from chain, so it is correct by construction; this is the only caller sourcing it from config for a
        // feed that is already registered.
        if (onChain.priceType != pt) revert FeedTypeMismatch(asset, idx, onChain.priceType, pt);

        uint256 cfgHb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, i));
        if (onChain.chainlinkHeartbeat == cfgHb) return "";
        return abi.encodeCall(NAVCalculator.addOrModifyPriceFeed, (asset, feed, pt, cfgHb));
    }

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
        // Current tolerances, so an unchanged one emits NOTHING. Without this the script re-sent every asset's
        // tolerances on every run: registering ONE asset planned 27 transactions, 24 of them rewriting values that
        // already equalled config. Harmless to state, but it is 24 needless transactions against a live NAV, and
        // with `--slow` (a receipt awaited per transaction) it turned a 3-transaction job into ~5 minutes.
        // Monitor feeds were already skipped when present; tolerances simply never learned the same trick.
        IPrices.AssetPricing memory live;
        if (registered) {
            (bool okm, bytes memory md) =
                navProxy.staticcall(abi.encodeWithSelector(IPrices.getMonitorFeeds.selector, asset));
            if (okm && md.length >= 64) onChain = abi.decode(md, (IPrices.PriceFeedConfig[]));

            (bool okp, bytes memory pd) =
                navProxy.staticcall(abi.encodeWithSelector(IPrices.getAssetPricing.selector, asset));
            if (okp && pd.length >= 64) live = abi.decode(pd, (IPrices.AssetPricing));
        }

        bytes[] memory tmp = new bytes[](monCount + 2);
        uint256 n;
        // An UNREGISTERED asset leaves `live` zeroed, so its setters are still emitted — which is what a new asset
        // needs. Note this only ever RAISES or CHANGES a tolerance to a non-zero config value: a config lowered to 0
        // still clears nothing, because the `> 0` guards below predate this change and are left as they were.
        if (monCount > 0 && divTolBps > 0 && live.divergenceToleranceBps != uint32(divTolBps)) {
            tmp[n++] = abi.encodeCall(NAVCalculator.setDivergenceTolerance, (asset, uint32(divTolBps)));
        }
        if (pegTolBps > 0 && live.pegToleranceBps != uint32(pegTolBps)) {
            tmp[n++] = abi.encodeCall(NAVCalculator.setPegTolerance, (asset, uint32(pegTolBps)));
        }

        for (uint256 i = 0; i < monCount; i++) {
            (IPrices.PriceType pt, bool validType) =
                ConfigReader.readAssetMonitorFeedPriceType(vm, currentChainId, symbol, i);
            if (!validType) continue;
            string memory maddr = ConfigReader.readAssetMonitorFeedAddress(vm, currentChainId, symbol, i);
            if (bytes(maddr).length == 0) continue; // unresolved (e.g. Custom monitor not deployed yet)
            address feed = vm.parseAddress(maddr);
            if (feed == address(0)) continue;
            // Already registered? Compare the HEARTBEAT before skipping. Skipping on address alone made this
            // a silent no-op for a changed monitor heartbeat — the identical defect fixed on the primary axis
            // in `_existingFeedAct`, left behind here. `addMonitorFeed` upserts now, so an edited heartbeat
            // has a path; without this, config and chain diverge with a green run and no signal.
            if (_containsFeed(onChain, feed)) {
                uint256 want = vm.parseUint(ConfigReader.readAssetMonitorFeedHeartbeat(vm, currentChainId, symbol, i));
                bool drifted;
                for (uint256 k = 0; k < onChain.length; k++) {
                    if (onChain[k].priceFeed == feed && onChain[k].chainlinkHeartbeat != want) drifted = true;
                }
                if (!drifted) continue;
            }

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
