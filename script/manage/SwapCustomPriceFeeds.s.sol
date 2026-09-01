// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {INAVCalculator} from "../../src/nav/INAVCalculator.sol";
import {IPrices} from "../../src/prices/IPrices.sol";
import {console2} from "forge-std/console2.sol";

/// @title SwapCustomPriceFeeds
/// @notice Replaces each asset's registered `Custom` price feed(s) on the LIVE NAVCalculator with the freshly
///         re-deployed NAV-sourced versions (ADR 0019). Run AFTER `03_DeployPriceFeeds` has re-deployed the new
///         feeds (so the config's `Custom` entries resolve to the NEW addresses in `deployments/<id>.json`).
/// @dev Per asset, in two GLOBAL passes so no asset is ever left without a valid feed:
///        Pass A (adds):    for each new Custom feed (from config) not already registered on-chain -> addPriceFeed.
///        Pass B (removes): for each on-chain `Custom` feed not in the new set                     -> removePriceFeed.
///      Old feed addresses are read LIVE from the NAV (`getPriceFeeds`), never from the JSON that 03 overwrote.
///      ONLY `PriceType.Custom` feeds are touched — direct Chainlink/API3/Redstone redundancy feeds are left intact.
///      An asset whose new Custom feed does not resolve (not deployed) is SKIPPED WHOLESALE (no add, no remove), so a
///      missing deploy can never strand an asset on direct feeds only. Idempotent, MANAGER-gated. Requires --rpc-url.
///      Simulate first by running WITHOUT --broadcast (executes the plan against live state locally and reveals reverts).
/// @dev Two execution paths, both from the same ordered batch (all adds, then all removes):
///        - **EOA broadcast** (with `--broadcast`) — works while the deployer EOA still holds `MANAGER` (pre-handoff).
///        - **Safe multiSend** — a `safe-transactions/<chainId>-swap-custom-price-feeds.json` file is always written
///          for execution by the security-council Safe once the NAV is handed off (`07_TransferAdminToSecurityCouncil`
///          revokes the EOA's MANAGER). Executed as one atomic multiSend, the add-then-remove ordering also removes any
///          half-migration risk (no asset is ever left with both the old and new Custom feed, or with none).
contract SwapCustomPriceFeeds is BaseDeployScript {
    struct Plan {
        address asset;
        string symbol;
        address[] addFeeds;
        uint256[] addHeartbeats;
        address[] removeFeeds;
    }

    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
        string[] memory symbols = ConfigReader.getAssetSymbols(vm, currentChainId);

        console2.log("\n=== Swap Custom Price Feeds (ADR 0019) ===");
        console2.log("Chain:", chainConfig.name);
        console2.log("NAVCalculator proxy:", navProxy);
        require(navProxy != address(0) && navProxy.code.length > 0, "NAV not live; run with --rpc-url");

        uint256 totalAdds;
        uint256 totalRemoves;
        Plan[] memory plans = new Plan[](symbols.length);
        for (uint256 i = 0; i < symbols.length; i++) {
            plans[i] = _planAsset(symbols[i], navProxy);
            totalAdds += plans[i].addFeeds.length;
            totalRemoves += plans[i].removeFeeds.length;
        }

        console2.log("Planned adds:", totalAdds);
        console2.log("Planned removes:", totalRemoves);
        _printPlan(plans);

        if (totalAdds == 0 && totalRemoves == 0) {
            console2.log("Nothing to swap (already migrated, or new feeds not deployed yet). Exiting.");
            return;
        }

        // One ordered batch: ALL adds first, then ALL removes — so no asset is ever left without a valid feed. Used
        // for BOTH the Safe multiSend file and the EOA broadcast below.
        SafeTxBuilder.Transaction[] memory batch = new SafeTxBuilder.Transaction[](totalAdds + totalRemoves);
        uint256 j;
        for (uint256 i = 0; i < plans.length; i++) {
            for (uint256 k = 0; k < plans[i].addFeeds.length; k++) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy,
                    0,
                    abi.encodeCall(
                        NAVCalculator.addOrModifyPriceFeed,
                        (plans[i].asset, plans[i].addFeeds[k], IPrices.PriceType.Custom, plans[i].addHeartbeats[k])
                    )
                );
                console2.log("  + add", plans[i].symbol, plans[i].addFeeds[k]);
            }
        }
        for (uint256 i = 0; i < plans.length; i++) {
            for (uint256 k = 0; k < plans[i].removeFeeds.length; k++) {
                batch[j++] = SafeTxBuilder.call(
                    navProxy,
                    0,
                    abi.encodeCall(NAVCalculator.removePriceFeed, (plans[i].asset, plans[i].removeFeeds[k]))
                );
                console2.log("  - remove", plans[i].symbol, plans[i].removeFeeds[k]);
            }
        }

        // Always write the Safe multiSend (for post-handoff execution by the security-council Safe).
        string memory filename = string(abi.encodePacked(vm.toString(currentChainId), "-swap-custom-price-feeds.json"));
        writeSafeTx(
            filename,
            "Swap custom price feeds to NAV-sourced versions (ADR 0019)",
            string(
                abi.encodePacked(
                    "Add ",
                    vm.toString(totalAdds),
                    " new Custom feed(s) then remove ",
                    vm.toString(totalRemoves),
                    " old"
                )
            ),
            batch
        );
        console2.log(string(abi.encodePacked("Safe tx written to safe-transactions/", filename)));

        // Broadcast from the deployer EOA while it still holds MANAGER (pre-handoff). Post-handoff, execute the Safe
        // file above instead. Runs even without --broadcast as a live simulation (use --sender <MANAGER>).
        _broadcastManagerMultiSend(batch);

        console2.log("[OK] Swapped custom feeds:", totalAdds, "added,");
        console2.log("     removed:", totalRemoves);
    }

    /// @notice Broadcasts each batch tx from the deployer EOA (MANAGER-gated), in order (all adds, then all removes).
    ///         Reverts with the first failing call's decoded reason. Mirrors `RegisterAssets`.
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
                    false, string(abi.encodePacked("swap failed at index ", vm.toString(i), ": ", _revertMsg(data)))
                );
            }
        }
        vm.stopBroadcast();
        console2.log("[OK] Broadcast", batch.length, "tx(s) from the deployer EOA.");
    }

    /// @notice Builds the add/remove plan for one asset, or an empty plan to skip it.
    function _planAsset(string memory symbol, address navProxy) internal view returns (Plan memory plan) {
        plan.symbol = symbol;

        string memory addrStr = ConfigReader.readAssetAddress(vm, currentChainId, symbol);
        if (bytes(addrStr).length == 0) return plan;
        address asset = vm.parseAddress(addrStr);
        if (asset == address(0)) return plan;
        plan.asset = asset;

        // Only registered assets can be swapped; a brand-new asset is RegisterAssets' job, not ours.
        (bool okReg, bytes memory regData) =
            navProxy.staticcall(abi.encodeWithSelector(INAVCalculator.isAssetRegistered.selector, asset));
        if (!(okReg && regData.length > 0 && abi.decode(regData, (bool)))) return plan;

        // New Custom feeds from config (resolve to the post-03 addresses). If ANY is unresolved, skip the asset
        // entirely — never remove an old feed we can't replace.
        uint256 feedCount = ConfigReader.assetFeedCount(vm, currentChainId, symbol);
        address[] memory newFeeds = new address[](feedCount);
        uint256[] memory newHbs = new uint256[](feedCount);
        uint256 nNew;
        for (uint256 i = 0; i < feedCount; i++) {
            (IPrices.PriceType pt, bool validType) = ConfigReader.readAssetFeedPriceType(vm, currentChainId, symbol, i);
            if (!validType || pt != IPrices.PriceType.Custom) continue;
            string memory faddr = ConfigReader.readAssetFeedAddress(vm, currentChainId, symbol, i);
            address feed = bytes(faddr).length == 0 ? address(0) : vm.parseAddress(faddr);
            if (feed == address(0)) {
                console2.log("  [skip asset] custom feed not deployed:", symbol);
                return plan; // unresolved -> skip whole asset (returns empty plan)
            }
            newFeeds[nNew] = feed;
            newHbs[nNew] = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, i));
            nNew++;
        }
        if (nNew == 0) return plan; // asset has no custom feed -> nothing to swap

        // On-chain current feeds.
        IPrices.PriceFeedConfig[] memory onChain = IPrices(navProxy).getPriceFeeds(asset);

        // Adds: new custom feed not currently present (any type/position).
        address[] memory adds = new address[](nNew);
        uint256[] memory addHbs = new uint256[](nNew);
        uint256 nAdd;
        for (uint256 a = 0; a < nNew; a++) {
            if (!_contains(onChain, newFeeds[a])) {
                adds[nAdd] = newFeeds[a];
                addHbs[nAdd] = newHbs[a];
                nAdd++;
            }
        }

        // Removes: on-chain Custom feed no longer in the new set.
        address[] memory removes = new address[](onChain.length);
        uint256 nRem;
        for (uint256 c = 0; c < onChain.length; c++) {
            if (onChain[c].priceType != IPrices.PriceType.Custom) continue;
            if (!_inList(newFeeds, nNew, onChain[c].priceFeed)) {
                removes[nRem++] = onChain[c].priceFeed;
            }
        }

        plan.addFeeds = _trim(adds, nAdd);
        plan.addHeartbeats = _trimU(addHbs, nAdd);
        plan.removeFeeds = _trim(removes, nRem);
    }

    function _contains(IPrices.PriceFeedConfig[] memory feeds, address feed) private pure returns (bool) {
        for (uint256 i = 0; i < feeds.length; i++) {
            if (feeds[i].priceFeed == feed) return true;
        }
        return false;
    }

    function _inList(address[] memory list, uint256 len, address feed) private pure returns (bool) {
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == feed) return true;
        }
        return false;
    }

    function _trim(address[] memory arr, uint256 len) private pure returns (address[] memory out) {
        out = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = arr[i];
        }
    }

    function _trimU(uint256[] memory arr, uint256 len) private pure returns (uint256[] memory out) {
        out = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = arr[i];
        }
    }

    function _printPlan(Plan[] memory plans) private pure {
        for (uint256 i = 0; i < plans.length; i++) {
            if (plans[i].addFeeds.length == 0 && plans[i].removeFeeds.length == 0) continue;
            console2.log("  asset", plans[i].symbol);
            console2.log("    adds:", plans[i].addFeeds.length);
            console2.log("    removes:", plans[i].removeFeeds.length);
        }
    }
}
