// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";

/// @title RealignHeartbeats
/// @author KPK
/// @notice Rewrites every registered price-feed heartbeat on this chain to the value the nav-config
///         declares, per ADR 0025.
/// @dev **Targets come from `script/config/nav-config/assets-and-price-feeds/<chainId>.json`, never from
///      arguments.** The config is the source of truth the guard checks and the next registration reads,
///      so driving the broadcast from anything else would let the chain and the repo disagree.
///
///      Both axes are now plain MANAGER calls. `addOrModifyPriceFeed` UPDATES the heartbeat of an
///      already-registered feed in place, so the helper contract this script used to deploy — plus its
///      MANAGER_ROLE grant, its self-renounce, and the four-transaction mirror swap it performed per
///      asset — are all gone. Monitor feeds never needed the dance either — their array has no last-feed
///      guard — and now that `addMonitorFeed` upserts too, they need no remove/add at all: one call each.
///      This commit is what deleted that remove/add; the sentence describing it was left behind.
///
///      Run with `--broadcast` from the account holding MANAGER_ROLE.
///
///      Dry-run first — it prints the exact plan and asserts every postcondition without `--broadcast`:
///        forge script script/manage/RealignHeartbeats.s.sol --rpc-url <rpc>
contract RealignHeartbeats is Script {
    address constant NAV = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;
    bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

    error NotManager(address who);
    error SignerNotManager(address signer);
    error NoNavDeployed(uint256 chainId);

    /// @notice {verify} found work still outstanding, i.e. the broadcast did not fully land.
    /// @dev The whole reason {verify} exists. Every `require` inside {run} runs during local SIMULATION —
    ///      `forge script` executes the body and only then sends the recorded transactions — so a run where
    ///      transaction 20 of 49 dies still prints `ok <sym>` for all 49 and exits 0.
    /// @notice Thrown by {verify} when the monitor planner could not resolve one or more configured feeds.
    /// @dev Distinct from {StillDrifted}: that one means "drift found", this one means "cannot tell". Both block
    ///      a green verification, because a verifier that cannot see a feed must not certify it.
    error VerifyIncomplete(uint256 skipped);

    error StillDrifted(uint256 assetsRemaining, uint256 monitorsRemaining);

    function run() external {
        uint256 chainId = block.chainid;
        if (NAV.code.length == 0) revert NoNavDeployed(chainId);

        (address[] memory assets, uint256[] memory heartbeats, string[] memory syms) = _plan(chainId);
        (
            address[] memory mAssets,
            address[] memory mFeeds,
            uint256[] memory mHeartbeats,
            string[] memory mSyms,
            uint256 mSkipped
        ) = _planMonitors(chainId);

        console2.log("=== ADR 0025 heartbeat realignment ===");
        console2.log("chain      :", chainId);
        console2.log("nav        :", NAV);
        console2.log("assets     :", assets.length);
        console2.log("monitors   :", mAssets.length);
        console2.log("skipped    :", mSkipped);
        if (assets.length == 0 && mAssets.length == 0) {
            // NOT "nothing to do" when feeds were skipped: a skipped monitor feed is one the planner could not
            // resolve, so it is unknown rather than aligned. Saying "already matches the config" there is the
            // same false certification `verify()` used to give, and `verify()` is what reverts on it.
            if (mSkipped != 0) {
                console2.log("WARNING: no work planned, but", mSkipped, "monitor feed(s) were SKIPPED as");
                console2.log("unresolvable - run `verify()`, which reverts VerifyIncomplete rather than pass.");
                return;
            }
            console2.log("nothing to do -- every registered heartbeat already matches the config");
            return;
        }
        for (uint256 i; i < mAssets.length; ++i) {
            console2.log(string.concat("  monitor ", mSyms[i], " -> ", vm.toString(mHeartbeats[i])));
        }

        // TWO checks, because they answer different questions and the config one alone was never enough.
        //
        // This first one reads the CONFIGURED manager, so it catches a STALE CONFIG — a chain whose
        // `addresses.manager` no longer holds the role. It says nothing about who will sign:
        // `vm.startBroadcast()` below takes no argument, so forge signs with whatever `--account` /
        // `--private-key` / `--sender` the CLI supplies. The real signer is checked against the role
        // immediately after the broadcast opens, via `vm.readCallers()` — see there. Before that second
        // check existed, running with any account other than `addresses.manager` passed here and then
        // reverted MID-SEQUENCE, after some heartbeats had already been written.
        //
        // MANAGER, not DEFAULT_ADMIN, on BOTH sides. Every call this script makes — `addOrModifyPriceFeed`,
        // `removeMonitorFeed`, `addMonitorFeed` — is MANAGER-gated; the admin wiring is left over from the
        // deleted `HeartbeatRealigner` helper, which needed admin only to `grantRole(MANAGER_ROLE, ...)`.
        // Changing the ROLE but still resolving `.admin` would ask whether the admin holds MANAGER, which
        // rejects a valid manager wherever the two are different accounts. `ClearDormantMetaInstances`
        // resolves the signer the same way.
        address sender = ConfigReader.readChainConfig(vm, chainId).manager;
        if (!NAVCalculator(NAV).hasRole(MANAGER_ROLE, sender)) revert NotManager(sender);

        // Snapshot before, so the post-broadcast report is measured rather than assumed.
        uint256[] memory priceBefore = new uint256[](assets.length);
        bool[] memory staleBefore = new bool[](assets.length);
        address[] memory feedBefore = new address[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            INAVCalculator.PriceFeedData memory pd = INAVCalculator(NAV).getPriceData(assets[i]);
            priceBefore[i] = uint256(pd.price);
            staleBefore[i] = pd.stale;
            feedBefore[i] = c.priceFeed;
            console2.log(
                string.concat(
                    "  ", syms[i], "  ", vm.toString(c.chainlinkHeartbeat), " -> ", vm.toString(heartbeats[i])
                )
            );
        }

        vm.startBroadcast();

        // The account that will ACTUALLY sign, which the config check above cannot see. `readCallers` returns
        // the broadcaster only once the broadcast is open, so this has to sit here rather than with the other
        // precondition — but it still runs before the first state-changing call, so a wrong `--account` now
        // stops the script with a named error instead of reverting partway through the rewrite.
        (, address signer,) = vm.readCallers();
        if (!NAVCalculator(NAV).hasRole(MANAGER_ROLE, signer)) revert SignerNotManager(signer);

        for (uint256 i; i < assets.length; ++i) {
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            // Same feed, same type — only the heartbeat moves. No helper contract, no role grant, and no
            // window in which an unaudited pass-through prices the asset. Re-reading index 0 here is safe
            // because `_plan` already asserted it equals the config-declared feed; without that assertion this
            // line would apply one feed's configured heartbeat to whichever feed a swap-and-pop left behind.
            NAVCalculator(NAV).addOrModifyPriceFeed(assets[i], c.priceFeed, c.priceType, heartbeats[i]);
        }
        for (uint256 i; i < mAssets.length; ++i) {
            IPrices.PriceFeedConfig[] memory mons = NAVCalculator(NAV).getMonitorFeeds(mAssets[i]);
            for (uint256 j; j < mons.length; ++j) {
                if (mons[j].priceFeed != mFeeds[i]) continue;
                // ONE transaction. `addMonitorFeed` upserts, so the remove-then-add pair this used to
                // broadcast is gone — with it the window where an interrupted run left the monitor removed
                // and divergence detection silently degraded.
                NAVCalculator(NAV).addMonitorFeed(mAssets[i], mFeeds[i], mons[j].priceType, mHeartbeats[i]);
                break;
            }
        }
        vm.stopBroadcast();

        // [SIMULATED] — and that word is load-bearing. Under `forge script` the body executes first and
        // Foundry sends the recorded transactions only after `run()` returns, so everything below reads the
        // SIMULATION, not the chain. It is still worth doing (it catches a plan that cannot succeed at all),
        // but it cannot witness a partially-landed broadcast: this script now sends one
        // `addOrModifyPriceFeed` per asset and one `addMonitorFeed` per monitor — ~49 independently-failable
        // transactions on mainnet, where the deleted `HeartbeatRealigner.realign()` was a single one. Run
        // `--sig "verify()"` afterwards; that reads confirmed state.
        console2.log("--- verification [SIMULATED, see verify()] ---");
        for (uint256 i; i < assets.length; ++i) {
            IPrices.PriceFeedConfig memory c = NAVCalculator(NAV).getPriceFeedAt(assets[i], 0);
            // NO `getPriceFeedCount == 1` here. That guard belonged to the deleted `HeartbeatRealigner`,
            // which refused multi-feed assets outright because its remove-then-add REORDERED the array. The
            // upsert mutates in place and reorders nothing, so a multi-feed asset is now safe — while the
            // leftover require aborted the whole chain's run for one, since `forge script` simulates end to
            // end before broadcasting. Same total-blockage class as the postcondition below.
            require(c.priceFeed == feedBefore[i], "FEED ADDRESS CHANGED");
            require(c.chainlinkHeartbeat == heartbeats[i], "heartbeat not applied");
            INAVCalculator.PriceFeedData memory d = INAVCalculator(NAV).getPriceData(assets[i]);
            // A stale asset prices 0 by design at declared + 0; only a CHANGED and still-fresh price is a fault.
            // Compare prices only when the asset was FRESH BEFORE. `_selectFeedCore` returns price 0 for an
            // asset whose every feed is past its heartbeat, so a currently-stale asset snapshots
            // `priceBefore == 0` — and widening its window is the script's whole purpose, after which it is
            // fresh with a real price. Testing `d.stale` (the AFTER state) scored that success as a fault:
            // `false || (99990000 == 0)` reverts, and since `forge script` simulates `run()` end to end
            // before broadcasting, NOT ONE asset on the chain would have been realigned. ADR 0025 widens
            // exactly the pegged feeds that go stale every cycle, so this was the common case, not the edge.
            // Compare ONLY when the asset was fresh before AND is fresh after. The previous form,
            // `staleBefore[i] || d.stale || price == priceBefore`, short-circuited on the first term — and
            // `staleBefore` is TRUE for exactly the pegged feeds ADR 0025 exists to widen, so the check was
            // vacuous for the common case. That replaced "aborts on its own success" with "asserts nothing";
            // this form does neither. A stale->fresh transition is the intended effect and is not compared,
            // because `_selectFeedCore` reports price 0 while stale so there is nothing to compare against.
            if (!staleBefore[i] && !d.stale) {
                require(uint256(d.price) == priceBefore[i], "price moved while fresh");
            }
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
        console2.log("done (SIMULATED): heartbeats realigned via addOrModifyPriceFeed, no helper contract");
        console2.log("NOW RUN: forge script ... --sig \"verify()\" --rpc-url $RPC   (reads confirmed state)");
    }

    /// @notice Confirms against CONFIRMED chain state that nothing is still drifted. Run after the broadcast.
    /// @dev Re-derives the plan from config instead of re-checking snapshotted values: if `_plan` and
    ///      `_planMonitors` both come back empty, every configured heartbeat already equals what is on chain,
    ///      which is exactly what a fully-landed run means. Cheap, read-only, and re-runnable — and unlike the
    ///      block inside {run} it cannot be fooled by a simulation that succeeded while a transaction did not.
    function verify() external view {
        uint256 chainId = block.chainid;
        (address[] memory assets,,) = _plan(chainId);
        (address[] memory mAssets,,,, uint256 skipped) = _planMonitors(chainId);
        console2.log("verify: assets still drifted  :", assets.length);
        console2.log("verify: monitors still drifted:", mAssets.length);
        console2.log("verify: monitor feeds skipped :", skipped);
        if (assets.length != 0 || mAssets.length != 0) revert StillDrifted(assets.length, mAssets.length);
        // ⚠️ **THE VERIFIER SHARES ITS EVIDENCE SOURCE WITH THE THING IT VERIFIES, so a skip must be fatal
        // here.** `verify()` calls the same `_planMonitors` that `run()` does, and that planner `continue`s
        // past a monitor feed whose config address is unresolvable or does not match the live feed — logging
        // "left as-is" and omitting it from the work list. An omitted feed is therefore indistinguishable from
        // an aligned one: `mAssets.length == 0` and `verify()` used to print "every configured heartbeat
        // matches chain state" while those feeds were never realigned at all. A wrong heartbeat accepts a stale
        // price, so certifying that falsely is a wrong-NAV path, not a reporting nicety.
        if (skipped != 0) revert VerifyIncomplete(skipped);
        console2.log("verify: OK - every configured heartbeat matches chain state");
    }

    /// @notice Builds the MONITOR work list: every monitor registration whose live heartbeat differs.
    /// @dev Monitor feeds were missed on the first pass — the script realigned price feeds only, so the
    ///      monitor half of the config change sat unexecuted across all seven broadcasts. They are
    ///      planned separately because they need no mirror (no last-feed guard on that array) and because
    ///      a wrong monitor heartbeat cannot zero an asset, only degrade its divergence check.
    function _planMonitors(uint256 chainId)
        internal
        view
        returns (
            address[] memory assets,
            address[] memory feeds,
            uint256[] memory heartbeats,
            string[] memory syms,
            uint256 skipped
        )
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
                // BOUND ON `.heartbeat`, AND RESOLVE THE ADDRESS THE WAY THE CONFIG ACTUALLY WRITES IT.
                //
                // This used to bound the scan on `.address` and `break` when that key was missing, treating
                // "this entry has no literal address" as "past the end of the array". 11 of the 47 configured
                // monitor feeds are Custom and name a deployed feed instead — `{"type":"Custom","feed":
                // "rETHCrossRate",...}` on chains 1, 42161 and 8453 — so each of those broke at k = 0 and was
                // dropped with no output. Worse, the `break` aborted the scan for the WHOLE asset: chain 1's
                // stETH lists a Custom monitor at index 0 and a Chainlink monitor WITH an address at index 1,
                // so the addressed one was never examined either. The script printed success having realigned
                // none of them.
                //
                // `ConfigReader.readAssetMonitorFeedAddress` resolves both forms — a literal `address`, and a
                // Custom `feed` name looked up in the deployment record — which is what the primary axis and
                // `RegisterAssets` already use. `.heartbeat` is present on every entry, so it is the honest
                // end-of-array sentinel, and an address that still will not resolve is skipped LOUDLY.
                bool matched;
                uint256 want;
                for (uint256 k;; ++k) {
                    string memory cand = string.concat(base, ".monitorFeeds[", vm.toString(k), "]");
                    if (!vm.keyExistsJson(json, string.concat(cand, ".heartbeat"))) break; // past the end
                    string memory candAddr = ConfigReader.readAssetMonitorFeedAddress(vm, chainId, keys[i], k);
                    if (bytes(candAddr).length == 0) {
                        console2.log(
                            string.concat(
                                "  [SKIP monitor] ", keys[i], " config index ", vm.toString(k), ": address unresolvable"
                            )
                        );
                        // NOT counted, and that is the fix rather than an omission. This branch is a per-CANDIDATE
                        // miss inside the `k` loop and it `continue`s, so a later candidate can still match and
                        // set `matched` — in which case the live feed WAS resolved and realigned. Counting here
                        // made `verify()` revert `VerifyIncomplete` on a chain where nothing was actually left
                        // undone, and inflated the count once per live feed `j`. The only state that means "this
                        // live registration is not described by config at all" is `!matched` below, so that is
                        // the one place a skip is counted.
                        continue;
                    }
                    if (vm.parseAddress(candAddr) != live[j].priceFeed) continue;
                    want = vm.parseJsonUint(json, string.concat(cand, ".heartbeat"));
                    matched = true;
                    break;
                }
                if (!matched) {
                    // THE one genuine "cannot tell" state: a live monitor registration that no config entry
                    // describes. `run()` cannot fix it — it is a CONFIG gap, not chain drift — so `verify()` will
                    // keep reverting `VerifyIncomplete` until the config is corrected. That is the intended
                    // remedy, not a dead end: add the missing `monitorFeeds` entry for this asset (or remove the
                    // stale live feed) and re-run. A verifier that passed here would be certifying a feed it
                    // could not see, which is the defect this counter exists to close.
                    console2.log(
                        string.concat("  [SKIP monitor] ", keys[i], ": live feed not found in config, left as-is")
                    );
                    ++skipped;
                    continue;
                }
                if (live[j].chainlinkHeartbeat == want) continue;

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
        uint256 skipped;

        for (uint256 i; i < keys.length; ++i) {
            string memory base = string.concat("$.", keys[i]);
            if (!vm.keyExistsJson(json, string.concat(base, ".priceFeeds[0].heartbeat"))) continue;
            address asset = vm.parseJsonAddress(json, string.concat(base, ".address"));
            if (!NAVCalculator(NAV).isAssetRegistered(asset)) continue;
            if (NAVCalculator(NAV).getPriceFeedCount(asset) == 0) continue;

            uint256 want = vm.parseJsonUint(json, string.concat(base, ".priceFeeds[0].heartbeat"));
            IPrices.PriceFeedConfig memory live = NAVCalculator(NAV).getPriceFeedAt(asset, 0);
            if (live.chainlinkHeartbeat == want) continue;

            // The heartbeat comes from config `priceFeeds[0]`, but it is APPLIED to whatever occupies live
            // index 0, and `_swapPopFeed` makes the on-chain array swap-and-pop ordered — so the two need not
            // be the same feed. Writing config feed A's heartbeat onto live feed B would pass every
            // postcondition here, because they check the heartbeat, the count and an unchanged price, never
            // the address. `_planMonitors` already matches by address; this is the primary axis catching up.
            //
            // `readAssetFeedAddress` resolves both forms — a literal `address`, and a Custom feed's `feed`
            // name looked up in `deployments.customPriceFeeds`. That second form means the authority for the
            // 24 Custom assets is the DEPLOYMENTS RECORD, not the config this contract's docstring names: a
            // record poisoned by a dry-run, or updated ahead of an unexecuted feed swap
            // (`SwapCustomPriceFeeds.s.sol`, `RedeployWarsFeed.s.sol` — wARS is one of the 24), resolves to an
            // address that is not live index 0.
            //
            // Both failures SKIP the asset LOUDLY rather than aborting the run. An earlier version reverted on
            // mismatch, which stopped all 48 other assets from being realigned over one asset's swap-pop
            // artifact — trading the exact pricing defect ADR 0025 exists to remove (a too-long window prices
            // a stale feed as fresh) against a narrower one. And an earlier version skipped the unresolvable
            // case SILENTLY, on the same statement form as the already-aligned skip, so an operator could not
            // tell "chain fully aligned" from "aligned except the feeds whose names did not resolve" — a
            // strict regression against the pre-guard code, which realigned those assets correctly.
            string memory cfgFeedStr = ConfigReader.readAssetFeedAddress(vm, chainId, keys[i], 0);
            if (bytes(cfgFeedStr).length == 0) {
                console2.log(
                    string.concat(
                        "  SKIP ", keys[i], " - config feed unresolvable (check deployments.customPriceFeeds)"
                    )
                );
                skipped++;
                continue;
            }
            // A malformed config address would revert `vm.parseAddress` inside `_plan`, BEFORE the SKIP
            // branches below can run — re-opening the whole-chain abort those branches exist to close, since
            // `forge script` simulates `run()` end to end. Shape-check first and skip loudly instead.
            if (bytes(cfgFeedStr).length != 42) {
                console2.log(string.concat("  SKIP ", keys[i], " - config feed address is malformed: ", cfgFeedStr));
                skipped++;
                continue;
            }
            address cfgFeed = vm.parseAddress(cfgFeedStr);
            if (cfgFeed != live.priceFeed) {
                console2.log(
                    string.concat(
                        "  SKIP ",
                        keys[i],
                        " - live index 0 is not the config feed; live=",
                        vm.toString(live.priceFeed),
                        " config=",
                        vm.toString(cfgFeed)
                    )
                );
                skipped++;
                continue;
            }

            aBuf[n] = asset;
            hBuf[n] = want;
            sBuf[n] = keys[i];
            ++n;
        }

        if (skipped != 0) {
            console2.log("  skipped (not realigned, see SKIP lines above):", skipped);
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
