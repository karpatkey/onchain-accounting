// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {HeartbeatRealigner} from "script/manage/HeartbeatRealigner.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title RealignHeartbeats
/// @author KPK
/// @notice Rewrites every registered price-feed heartbeat on this chain to the value the nav-config
///         declares, per ADR 0025.
/// @dev **Targets come from `script/config/nav-config/assets-and-price-feeds/<chainId>.json`, never from
///      arguments.** The config is the source of truth the guard checks and the next registration reads,
///      so driving the broadcast from anything else would let the chain and the repo disagree.
///
///      The work happens inside `HeartbeatRealigner` because a registered heartbeat cannot be changed
///      through the NAVCalculator API — see that contract for why, and why the swap must be atomic.
///      This script only: deploys the realigner, grants it MANAGER_ROLE, calls it, and revokes.
///
///      The role is granted in one transaction and RENOUNCED BY THE REALIGNER ITSELF at the end of the
///      call that uses it, so it cannot outlive that transaction. The realigner is additionally pinned to
///      this script's sender, so even the gap between the grant and the call is inert to anyone else.
///      Run with `--broadcast` from the account holding DEFAULT_ADMIN_ROLE.
///
///      Dry-run first — it prints the exact plan and asserts every postcondition without `--broadcast`:
///        forge script script/manage/RealignHeartbeats.s.sol --rpc-url <rpc>
contract RealignHeartbeats is Script {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

    error NotAdmin(address who);
    error NoNavDeployed(uint256 chainId);

    function run() external {
        uint256 chainId = block.chainid;
        if (NAV.code.length == 0) revert NoNavDeployed(chainId);

        (address[] memory assets, uint256[] memory heartbeats, string[] memory syms) = _plan(chainId);
        (address[] memory mAssets, address[] memory mFeeds, uint256[] memory mHeartbeats, string[] memory mSyms) =
            _planMonitors(chainId);

        console2.log("=== ADR 0025 heartbeat realignment ===");
        console2.log("chain      :", chainId);
        console2.log("nav        :", NAV);
        console2.log("assets     :", assets.length);
        console2.log("monitors   :", mAssets.length);
        if (assets.length == 0 && mAssets.length == 0) {
            console2.log("nothing to do -- every registered heartbeat already matches the config");
            return;
        }
        for (uint256 i; i < mAssets.length; ++i) {
            console2.log(string.concat("  monitor ", mSyms[i], " -> ", vm.toString(mHeartbeats[i])));
        }

        // The address that will actually SIGN, not `msg.sender`. Under `forge script` the two need not be
        // equal, so checking msg.sender can fail a valid run before broadcasting — or pass one whose real
        // signer lacks the role, leaving the revert to land mid-sequence. `10_MigrateAdaptersToCreate2.s.sol`
        // pins the intended broadcaster the same way. It is also the OPERATOR the realigner is bound to, so
        // getting it wrong here would make every realign call revert NotOperator.
        address sender = ConfigReader.readChainConfig(vm, chainId).admin;
        if (!NAVCalculator(NAV).hasRole(0x00, sender)) revert NotAdmin(sender);

        // Snapshot before, so the post-broadcast report is measured rather than assumed.
        uint256[] memory priceBefore = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            priceBefore[i] = uint256(INAVCalculator(NAV).getPriceData(assets[i]).price);
            console2.log(
                string.concat(
                    "  ", syms[i], "  ", vm.toString(c.chainlinkHeartbeat), " -> ", vm.toString(heartbeats[i])
                )
            );
        }

        vm.startBroadcast();
        HeartbeatRealigner realigner = new HeartbeatRealigner(NAV, sender);
        NAVCalculator(NAV).grantRole(MANAGER_ROLE, address(realigner));
        // No trailing revokeRole: `realign` renounces the role itself, in the same transaction that uses
        // it. The trailing revoke is what failed on Polygon (out of gas), stranding the role on a
        // then-ungated contract for 107 blocks. One less transaction is one less thing to fail open.
        if (assets.length > 0) realigner.realign(assets, heartbeats);
        if (mAssets.length > 0) {
            // realign() renounces on completion, so the role must be re-granted for a second call.
            if (!NAVCalculator(NAV).hasRole(MANAGER_ROLE, address(realigner))) {
                NAVCalculator(NAV).grantRole(MANAGER_ROLE, address(realigner));
            }
            realigner.realignMonitors(mAssets, mFeeds, mHeartbeats);
        }
        vm.stopBroadcast();

        console2.log("--- verification ---");
        for (uint256 i; i < assets.length; ++i) {
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            require(NAVCalculator(NAV).getPriceFeedCount(assets[i]) == 1, "feed count");
            require(c.chainlinkHeartbeat == heartbeats[i], "heartbeat not applied");
            INAVCalculator.PriceFeedData memory d = INAVCalculator(NAV).getPriceData(assets[i]);
            // A stale asset prices 0 by design at declared + 0; only a CHANGED and still-fresh price is a fault.
            require(d.stale || uint256(d.price) == priceBefore[i], "price moved while fresh");
            console2.log(
                string.concat("  ok ", syms[i], "  hb=", vm.toString(c.chainlinkHeartbeat), d.stale ? "  [STALE]" : "")
            );
        }
        for (uint256 i; i < mAssets.length; ++i) {
            IPrices.PriceFeedConfig[] memory mons = NAVCalculator(NAV).getMonitorFeeds(mAssets[i]);
            bool ok;
            for (uint256 j; j < mons.length; ++j) {
                if (mons[j].priceFeed == mFeeds[i] && mons[j].chainlinkHeartbeat == mHeartbeats[i]) ok = true;
            }
            require(ok, "monitor heartbeat not applied");
            console2.log(string.concat("  ok monitor ", mSyms[i], "  hb=", vm.toString(mHeartbeats[i])));
        }
        require(!NAVCalculator(NAV).hasRole(MANAGER_ROLE, address(realigner)), "role survived");
        console2.log("realigner (role revoked):", address(realigner));
    }

    /// @notice Builds the MONITOR work list: every monitor registration whose live heartbeat differs.
    /// @dev Monitor feeds were missed on the first pass — the script realigned price feeds only, so the
    ///      monitor half of the config change sat unexecuted across all seven broadcasts. They are
    ///      planned separately because they need no mirror (no last-feed guard on that array) and because
    ///      a wrong monitor heartbeat cannot zero an asset, only degrade its divergence check.
    function _planMonitors(uint256 chainId)
        internal
        view
        returns (address[] memory assets, address[] memory feeds, uint256[] memory heartbeats, string[] memory syms)
    {
        string memory json = vm.readFile(
            string.concat("script/config/nav-config/assets-and-price-feeds/", vm.toString(chainId), ".json")
        );
        string[] memory keys = vm.parseJsonKeys(json, "$");

        address[] memory aBuf = new address[](keys.length * 4);
        address[] memory fBuf = new address[](keys.length * 4);
        uint256[] memory hBuf = new uint256[](keys.length * 4);
        string[] memory sBuf = new string[](keys.length * 4);
        uint256 n;

        for (uint256 i; i < keys.length; ++i) {
            string memory base = string.concat("$.", keys[i]);
            if (!vm.keyExistsJson(json, string.concat(base, ".monitorFeeds"))) continue;
            if (!vm.keyExistsJson(json, string.concat(base, ".address"))) continue;
            address asset = vm.parseJsonAddress(json, string.concat(base, ".address"));
            if (!NAVCalculator(NAV).isAssetRegistered(asset)) continue;

            IPrices.PriceFeedConfig[] memory live = NAVCalculator(NAV).getMonitorFeeds(asset);
            for (uint256 j; j < live.length; ++j) {
                string memory leg = string.concat(base, ".monitorFeeds[", vm.toString(j), "]");
                if (!vm.keyExistsJson(json, string.concat(leg, ".heartbeat"))) continue;
                // Match by ADDRESS, not index: getMonitorFeeds is swap-and-pop ordered, so live[j] is not
                // necessarily config monitorFeeds[j].
                // Bounded by the CONFIG array, not by `live.length`. Those lengths are unrelated: a config
                // listing [A, B, C] against a single live registration C would only ever examine config
                // index 0, conclude C is unmatched, and silently drop it from the rollout.
                bool matched;
                uint256 want;
                for (uint256 k;; ++k) {
                    string memory cand = string.concat(base, ".monitorFeeds[", vm.toString(k), "]");
                    if (!vm.keyExistsJson(json, string.concat(cand, ".address"))) break; // past the end
                    if (vm.parseJsonAddress(json, string.concat(cand, ".address")) != live[j].priceFeed) continue;
                    if (!vm.keyExistsJson(json, string.concat(cand, ".heartbeat"))) break;
                    want = vm.parseJsonUint(json, string.concat(cand, ".heartbeat"));
                    matched = true;
                    break;
                }
                if (!matched || live[j].chainlinkHeartbeat == want) continue;

                aBuf[n] = asset;
                fBuf[n] = live[j].priceFeed;
                hBuf[n] = want;
                sBuf[n] = keys[i];
                ++n;
            }
        }

        assets = new address[](n);
        feeds = new address[](n);
        heartbeats = new uint256[](n);
        syms = new string[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = aBuf[i];
            feeds[i] = fBuf[i];
            heartbeats[i] = hBuf[i];
            syms[i] = sBuf[i];
        }
    }

    /// @notice Builds the work list: every asset whose LIVE primary heartbeat differs from the config.
    /// @dev Skips assets that are not registered on-chain and assets already at the configured value, so
    ///      the script is idempotent — a second run after a successful one finds nothing to do rather
    ///      than reverting `NothingToRealign` from inside the batch.
    function _plan(uint256 chainId)
        internal
        view
        returns (address[] memory assets, uint256[] memory heartbeats, string[] memory syms)
    {
        string memory json = vm.readFile(
            string.concat("script/config/nav-config/assets-and-price-feeds/", vm.toString(chainId), ".json")
        );
        string[] memory keys = vm.parseJsonKeys(json, "$");

        address[] memory aBuf = new address[](keys.length);
        uint256[] memory hBuf = new uint256[](keys.length);
        string[] memory sBuf = new string[](keys.length);
        uint256 n;

        for (uint256 i; i < keys.length; ++i) {
            string memory base = string.concat("$.", keys[i]);
            if (!vm.keyExistsJson(json, string.concat(base, ".priceFeeds[0].heartbeat"))) continue;
            address asset = vm.parseJsonAddress(json, string.concat(base, ".address"));
            if (!NAVCalculator(NAV).isAssetRegistered(asset)) continue;
            if (NAVCalculator(NAV).getPriceFeedCount(asset) == 0) continue;

            uint256 want = vm.parseJsonUint(json, string.concat(base, ".priceFeeds[0].heartbeat"));
            if (NAVCalculator(NAV).getPriceFeedAt(asset, 0).chainlinkHeartbeat == want) continue;

            aBuf[n] = asset;
            hBuf[n] = want;
            sBuf[n] = keys[i];
            ++n;
        }

        assets = new address[](n);
        heartbeats = new uint256[](n);
        syms = new string[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = aBuf[i];
            heartbeats[i] = hBuf[i];
            syms[i] = sBuf[i];
        }
    }
}
