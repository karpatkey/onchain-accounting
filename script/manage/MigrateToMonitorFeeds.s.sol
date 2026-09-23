// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {INAVCalculator} from "../../src/nav/INAVCalculator.sol";
import {IPrices} from "../../src/prices/IPrices.sol";
import {console2} from "forge-std/console2.sol";

/// @title MigrateToMonitorFeeds
/// @notice Reconciles the LIVE NAVCalculator to the fundamental-feed-selection target: every asset priced by its
///         single primary feed (`priceFeeds[0]` in config), with all redundancy feeds moved to `monitorFeeds`
///         (divergence-only) and the divergence/peg tolerances set. Run AFTER `03_DeployPriceFeeds` has
///         (re)deployed the new pure-fundamental primaries, so config `Custom` entries resolve to the NEW addresses
///         in `deployments/<id>.json`.
/// @dev Per asset, reconciled to the config target and emitted as ONE atomic batch in two global passes so no asset
///      is ever left without a valid pricing feed:
///        Pass A (adds/sets): addOrModifyPriceFeed(target primary, if absent on-chain); setDivergenceTolerance;
///                            setPegTolerance; addMonitorFeed(each target monitor not already present).
///        Pass B (removes):   removePriceFeed(each on-chain PRICING feed whose address != the target primary) —
///                            i.e. the old (swapped-out) primary and every redundancy feed now living in monitorFeeds;
///                            removeMonitorFeed(each on-chain MONITOR feed absent from the config's monitor set) —
///                            i.e. the superseded cross-rate monitors left behind when `03` re-deploys a Custom feed.
///      setDivergenceTolerance is emitted before any addMonitorFeed (a monitor cannot be added until the tolerance is
///      set). An asset whose target primary does not resolve (new feed not deployed yet) is SKIPPED WHOLESALE — a
///      missing deploy can never strand an asset. Idempotent, MANAGER-gated. Requires --rpc-url.
///      Simulate first by running WITHOUT --broadcast (executes the plan against live state locally, revealing reverts).
///      WARNING: this mutates live NAV pricing — fork-simulate on each chain before mainnet execution.
contract MigrateToMonitorFeeds is BaseDeployScript {
    struct Plan {
        address asset;
        string symbol;
        // Pass A — adds/sets
        address addPrimary; // address(0) => target primary already present on-chain
        IPrices.PriceType addPrimaryType;
        uint256 addPrimaryHb;
        bool setDivTol;
        uint32 divTolBps;
        bool setPegTol;
        uint32 pegTolBps;
        address[] addMonitors;
        IPrices.PriceType[] addMonitorTypes;
        uint256[] addMonitorHbs;
        // Pass B — removes
        address[] removePricing;
        address[] removeMonitors;
    }

    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        string[] memory symbols = ConfigReader.getAssetSymbols(vm, currentChainId);

        console2.log("\n=== Migrate to Monitor Feeds (fundamental feed selection) ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("NAVCalculator proxy:", navProxy);
        require(navProxy != address(0) && navProxy.code.length > 0, "NAV not live; run with --rpc-url");

        Plan[] memory plans = new Plan[](symbols.length);
        uint256 nA;
        uint256 nB;
        for (uint256 i = 0; i < symbols.length; i++) {
            plans[i] = _planAsset(symbols[i], navProxy);
            nA += _passACount(plans[i]);
            nB += plans[i].removePricing.length + plans[i].removeMonitors.length;
        }

        console2.log("Planned adds/sets:", nA);
        console2.log("Planned removes:", nB);
        if (nA + nB == 0) {
            console2.log("Nothing to migrate (already reconciled, or new feeds not deployed yet). Exiting.");
            return;
        }

        // One ordered batch: ALL adds/sets first (Pass A), then ALL removes (Pass B).
        SafeTxBuilder.Transaction[] memory batch = new SafeTxBuilder.Transaction[](nA + nB);
        uint256 j = _emitPassA(batch, 0, plans, navProxy);
        _emitPassB(batch, j, plans, navProxy);

        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-migrate-monitor-feeds.json"));
        writeSafeTx(
            filename,
            "Migrate to monitor feeds (fundamental feed selection)",
            string(abi.encodePacked("Adds/sets ", vm.toString(nA), " then removes ", vm.toString(nB))),
            batch
        );
        console2.log(string(abi.encodePacked("Safe tx written to safe-transactions/", filename)));

        // Broadcast from the deployer EOA while it still holds MANAGER (pre-handoff). Post-handoff, execute the Safe
        // file above instead. Runs even without --broadcast as a live simulation (use --sender <MANAGER>).
        _broadcastManagerMultiSend(batch);
    }

    // -------------------------------------------------------------------------
    // Planning
    // -------------------------------------------------------------------------

    /// @notice Builds the reconcile plan for one asset, or an empty plan (asset == address(0)) to skip it.
    function _planAsset(string memory symbol, address navProxy) internal view returns (Plan memory p) {
        p.symbol = symbol;

        address asset = _registeredAsset(symbol, navProxy);
        if (asset == address(0)) return p; // absent, unresolved, or not registered → skip

        (address prim, IPrices.PriceType primType, uint256 primHb, bool primOk) = _targetPrimary(symbol);
        if (!primOk) {
            console2.log("  [skip asset] target primary not deployed:", symbol);
            return p; // p.asset stays 0 → skip
        }

        p.asset = asset;

        IPrices.PriceFeedConfig[] memory pricing = IPrices(navProxy).getPriceFeeds(asset);
        // PRESENCE only, deliberately: a drifted HEARTBEAT on an already-present primary is NOT planned here.
        // `addOrModifyPriceFeed` upserts, so emitting it would realign the heartbeat too — which is why this
        // guard now reads like an oversight and did not before the rename. It is scope, not omission:
        // heartbeat realignment belongs to `RealignHeartbeats`, which plans against the same config and is
        // idempotent, and duplicating it here would give two scripts authority over one field.
        if (!_containsFeed(pricing, prim)) {
            p.addPrimary = prim;
            p.addPrimaryType = primType;
            p.addPrimaryHb = primHb;
        }
        p.removePricing = _pricingToRemove(pricing, prim);

        (p.addMonitors, p.addMonitorTypes, p.addMonitorHbs) = _monitorsToAdd(symbol, asset, navProxy);
        p.removeMonitors = _monitorsToRemove(symbol, asset, navProxy);

        uint256 monCount = ConfigReader.assetMonitorFeedCount(vm, currentChainId, symbol);
        uint256 divTol = ConfigReader.readAssetDivergenceToleranceBps(vm, currentChainId, symbol);
        uint256 pegTol = ConfigReader.readAssetPegToleranceBps(vm, currentChainId, symbol);
        // Fail fast on a config that would make Pass A revert on-chain (which would abort the whole migration
        // batch). `p.addMonitors.length > 0` is the true "a monitor is actually added" signal — `_monitorsToAdd`
        // already drops monitors present on-chain or unresolvable, so an idempotent re-run adds none and must not
        // abort.
        _requireTolerancesPlannable(navProxy, asset, symbol, monCount, divTol, pegTol, p.addMonitors.length > 0);
        // Set divergence tolerance whenever the target has monitors (required before addMonitorFeed); idempotent.
        if (divTol > 0 && monCount > 0) {
            p.setDivTol = true;
            p.divTolBps = uint32(divTol);
        }
        if (pegTol > 0) {
            p.setPegTol = true;
            p.pegTolBps = uint32(pegTol);
        }
    }

    /// @notice Resolves an asset's address iff it is configured, a contract, and already registered on-chain (this
    ///         script reconciles existing assets; brand-new assets are RegisterAssets' job). Returns 0 to skip.
    function _registeredAsset(string memory symbol, address navProxy) private view returns (address) {
        string memory addrStr = ConfigReader.readAssetAddress(vm, currentChainId, symbol);
        if (bytes(addrStr).length == 0) return address(0);
        address asset = vm.parseAddress(addrStr);
        if (asset == address(0)) return address(0);
        (bool ok, bytes memory data) =
            navProxy.staticcall(abi.encodeWithSelector(INAVCalculator.isAssetRegistered.selector, asset));
        if (!(ok && data.length > 0 && abi.decode(data, (bool)))) return address(0);
        return asset;
    }

    /// @notice Resolves the target primary (config `priceFeeds[0]`): its address, type, and heartbeat. ok=false if
    ///         the feed is unrecognized or not yet resolvable (e.g. a Custom feed not deployed).
    function _targetPrimary(string memory symbol)
        private
        view
        returns (address feed, IPrices.PriceType pt, uint256 hb, bool ok)
    {
        if (ConfigReader.assetFeedCount(vm, currentChainId, symbol) == 0) {
            return (address(0), IPrices.PriceType.Chainlink, 0, false);
        }
        bool validType;
        (pt, validType) = ConfigReader.readAssetFeedPriceType(vm, currentChainId, symbol, 0);
        if (!validType) return (address(0), IPrices.PriceType.Chainlink, 0, false);
        string memory faddr = ConfigReader.readAssetFeedAddress(vm, currentChainId, symbol, 0);
        if (bytes(faddr).length == 0) return (address(0), pt, 0, false);
        feed = vm.parseAddress(faddr);
        if (feed == address(0)) return (address(0), pt, 0, false);
        hb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, 0));
        ok = true;
    }

    /// @notice On-chain pricing feeds whose address != the target primary (to be removed from `_priceOracles`).
    function _pricingToRemove(IPrices.PriceFeedConfig[] memory pricing, address primary)
        private
        pure
        returns (address[] memory out)
    {
        address[] memory tmp = new address[](pricing.length);
        uint256 n;
        for (uint256 i = 0; i < pricing.length; i++) {
            if (pricing[i].priceFeed != primary) tmp[n++] = pricing[i].priceFeed;
        }
        out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
    }

    /// @notice Target monitor feeds not already registered on-chain (by address), with their type + heartbeat.
    function _monitorsToAdd(string memory symbol, address asset, address navProxy)
        private
        view
        returns (address[] memory feeds, IPrices.PriceType[] memory types, uint256[] memory hbs)
    {
        uint256 monCount = ConfigReader.assetMonitorFeedCount(vm, currentChainId, symbol);
        IPrices.PriceFeedConfig[] memory onChain = IPrices(navProxy).getMonitorFeeds(asset);

        address[] memory tf = new address[](monCount);
        IPrices.PriceType[] memory tt = new IPrices.PriceType[](monCount);
        uint256[] memory th = new uint256[](monCount);
        uint256 n;
        for (uint256 i = 0; i < monCount; i++) {
            (IPrices.PriceType pt, bool validType) =
                ConfigReader.readAssetMonitorFeedPriceType(vm, currentChainId, symbol, i);
            if (!validType) continue;
            string memory maddr = ConfigReader.readAssetMonitorFeedAddress(vm, currentChainId, symbol, i);
            if (bytes(maddr).length == 0) continue; // unresolved
            address feed = vm.parseAddress(maddr);
            if (feed == address(0) || _containsFeed(onChain, feed)) continue;
            tf[n] = feed;
            tt[n] = pt;
            th[n] = vm.parseUint(ConfigReader.readAssetMonitorFeedHeartbeat(vm, currentChainId, symbol, i));
            n++;
        }
        feeds = new address[](n);
        types = new IPrices.PriceType[](n);
        hbs = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            feeds[i] = tf[i];
            types[i] = tt[i];
            hbs[i] = th[i];
        }
    }

    /// @notice On-chain monitor feeds absent from the config's monitor set (to be removed from `_monitorFeeds`).
    /// @dev The case this exists for: `03_DeployPriceFeeds` re-deploys a Custom cross-rate feed, so the config now
    ///      names the NEW address while the superseded contract is still registered as a monitor — leaving both
    ///      would count the same source twice in the divergence check. Conservative: if ANY config monitor for the
    ///      asset is unresolvable (unknown type, blank address, not yet deployed), NO monitor is removed for that
    ///      asset — an incomplete target set must never be able to strip live monitoring. Pass A adds the missing
    ///      target monitors before Pass B removes anything, so the asset is never left unmonitored mid-batch.
    function _monitorsToRemove(string memory symbol, address asset, address navProxy)
        private
        view
        returns (address[] memory out)
    {
        uint256 monCount = ConfigReader.assetMonitorFeedCount(vm, currentChainId, symbol);
        address[] memory target = new address[](monCount);
        for (uint256 i = 0; i < monCount; i++) {
            (, bool validType) = ConfigReader.readAssetMonitorFeedPriceType(vm, currentChainId, symbol, i);
            string memory maddr =
                validType ? ConfigReader.readAssetMonitorFeedAddress(vm, currentChainId, symbol, i) : "";
            address feed = bytes(maddr).length == 0 ? address(0) : vm.parseAddress(maddr);
            if (feed == address(0)) {
                console2.log("  [skip monitor removals] target monitor unresolved:", symbol);
                return new address[](0);
            }
            target[i] = feed;
        }

        IPrices.PriceFeedConfig[] memory onChain = IPrices(navProxy).getMonitorFeeds(asset);
        address[] memory tmp = new address[](onChain.length);
        uint256 n;
        for (uint256 i = 0; i < onChain.length; i++) {
            if (!_contains(target, onChain[i].priceFeed)) tmp[n++] = onChain[i].priceFeed;
        }
        out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
    }

    function _passACount(Plan memory p) private pure returns (uint256 c) {
        if (p.asset == address(0)) return 0;
        if (p.addPrimary != address(0)) c++;
        if (p.setDivTol) c++;
        if (p.setPegTol) c++;
        c += p.addMonitors.length;
    }

    // -------------------------------------------------------------------------
    // Batch emission
    // -------------------------------------------------------------------------

    /// @notice Emits Pass A (adds/sets) for all plans, in the required order per asset (primary, divTol, pegTol,
    ///         monitors). Returns the next write index.
    function _emitPassA(SafeTxBuilder.Transaction[] memory batch, uint256 j, Plan[] memory plans, address navProxy)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < plans.length; i++) {
            Plan memory p = plans[i];
            if (p.asset == address(0)) continue;
            if (p.addPrimary != address(0)) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy,
                    0,
                    abi.encodeCall(
                        NAVCalculator.addOrModifyPriceFeed, (p.asset, p.addPrimary, p.addPrimaryType, p.addPrimaryHb)
                    )
                );
            }
            if (p.setDivTol) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy, 0, abi.encodeCall(NAVCalculator.setDivergenceTolerance, (p.asset, p.divTolBps))
                );
            }
            if (p.setPegTol) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy, 0, abi.encodeCall(NAVCalculator.setPegTolerance, (p.asset, p.pegTolBps))
                );
            }
            for (uint256 k = 0; k < p.addMonitors.length; k++) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy,
                    0,
                    abi.encodeCall(
                        NAVCalculator.addMonitorFeed,
                        (p.asset, p.addMonitors[k], p.addMonitorTypes[k], p.addMonitorHbs[k])
                    )
                );
            }
        }
        return j;
    }

    /// @notice Emits Pass B (removes) for all plans. Returns the next write index.
    function _emitPassB(SafeTxBuilder.Transaction[] memory batch, uint256 j, Plan[] memory plans, address navProxy)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < plans.length; i++) {
            Plan memory p = plans[i];
            for (uint256 k = 0; k < p.removePricing.length; k++) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy, 0, abi.encodeCall(NAVCalculator.removePriceFeed, (p.asset, p.removePricing[k]))
                );
            }
            for (uint256 k = 0; k < p.removeMonitors.length; k++) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy, 0, abi.encodeCall(NAVCalculator.removeMonitorFeed, (p.asset, p.removeMonitors[k]))
                );
            }
        }
        return j;
    }

    function _containsFeed(IPrices.PriceFeedConfig[] memory feeds, address feed) private pure returns (bool) {
        for (uint256 i = 0; i < feeds.length; i++) {
            if (feeds[i].priceFeed == feed) return true;
        }
        return false;
    }

    function _contains(address[] memory addrs, address addr) private pure returns (bool) {
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == addr) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Broadcast (mirrors SwapCustomPriceFeeds / RegisterAssets)
    // -------------------------------------------------------------------------

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
                    false, string(abi.encodePacked("migrate failed at index ", vm.toString(i), ": ", _revertMsg(data)))
                );
            }
        }
        vm.stopBroadcast();
        console2.log("[OK] Broadcast", batch.length, "tx(s) from the deployer EOA.");
    }
}
