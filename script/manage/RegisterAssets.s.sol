// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseDeployScript} from "../utils/BaseDeployScript.sol";
import {SafeTxBuilder} from "../utils/SafeTxBuilder.sol";
import {ConfigReader} from "../utils/ConfigReader.sol";
import {NAVCalculator} from "../../src/nav/NAVCalculator.sol";
import {INAVCalculator} from "../../src/nav/INAVCalculator.sol";
import {IPrices} from "../../src/prices/IPrices.sol";
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

    function run() public override {
        setUp();

        address navProxy = readDeployedAddress("NAVCalculatorProxy");
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
                batch[j++] = SafeTxBuilder.call(navProxy, 0, acts[k]);
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

        // Wire feeds in config order. The k-th *resolvable* configured feed corresponds to the k-th on-chain feed
        // (feeds are appended, never reordered), so for a registered asset the first `onChainFeeds` resolvable feeds
        // are already present and skipped; only trailing (new) feeds are added — which lets ADR-0009 redundancy feeds
        // be topped up on an already-live asset instead of being silently dropped.
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
                uint256 hb = vm.parseUint(ConfigReader.readAssetFeedHeartbeat(vm, currentChainId, symbol, i));
                tmp[n++] = abi.encodeCall(NAVCalculator.registerAsset, (asset, feed, pt, hb));
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
            (bool success, bytes memory data) = batch[i].to.call(batch[i].data);
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

    function _revertMsg(bytes memory data) internal pure returns (string memory) {
        if (data.length >= 68 && data[0] == 0x08 && data[1] == 0xc3 && data[2] == 0x79 && data[3] == 0xa0) {
            uint256 len;
            assembly {
                len := mload(add(add(data, 32), 36))
            }
            if (data.length >= 68 + 32 + len) {
                bytes memory msgBytes = new bytes(len);
                for (uint256 i = 0; i < len; i++) {
                    msgBytes[i] = data[i + 68 + 32];
                }
                return string(msgBytes);
            }
        }
        return "unknown";
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
