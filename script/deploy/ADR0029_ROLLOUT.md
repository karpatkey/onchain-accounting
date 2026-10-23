# ADR 0029 rollout — ordering rules and pre-upgrade checks

What must hold when the best-available stale pricing ([ADR 0029](../../docs/decisions/0029-staleness-flags-never-changes-value.md))
goes live. This file holds the rules. The full per-chain command sequence and the Safe batches are added when the
rollout is prepared.

## Decisions (2026-10-22)

- **Deploy first, merge after.** The rollout runs from the PR branch, and PR #354 merges only once the live
  contracts match the tree, as PR #338 did. Merging earlier turns the bytecode-drift gate
  (`.github/workflows/bytecode-drift.yml`, which runs on every push to `main` that touches `src/**`) red on every
  live custom feed, `PriceFeedLib` and the NAV implementation.
  - **The window between deploy and merge:** the drift gate also runs nightly against `main`, but it audits only the
    addresses in `main`'s deployment records. Those keep pointing at the old contracts (still deployed, still
    reproduced by `main`'s tree) until the merge, so the nightly run stays green and does not watch the new
    contracts yet. A red nightly run in that window is a real finding. Audit the new contracts from the branch
    (`bytecode_audit.py <chainId>` on this tree) after each chain's deploy.
- **Redeploy all 50 custom feeds**, not only the 39 primaries. The 11 monitor feeds use the same changed classes
  (`TwoFeedChainlinkPriceFeed` cross-rate feeds), so leaving them in place would keep them permanently drifted.
  - Primaries (39): chain 1 (27) wstETH, eETH, weETH, rETH, ezETH, rsETH, ETHx, osETH, stETHFundamental, lsETH,
    sUSDe, sUSDS, syrupUSDC, spUSDC, spUSDT, spETH, sDAI, RWIV, sGHO, LDO, ankrETH, NXM, wNXM, wARS, LBTC,
    syrupUSDG, syrupUSDT; 100: osGNO, wstETH_L2, sXDAI; 42161: wstETH_L2, weETH_L2, rsETH_L2, ezETH_L2,
    syrupUSDC_L2; 8453: wstETH_L2, weETH_L2, cbETH_L2; 5042: wARS.
  - Monitors (11): chain 1 rETH, ezETH, ezETHMarket, ETHx, osETH and stETH cross-rate feeds plus
    LBTCCrossRateMarket; 42161: weETH, ezETH and rsETH cross-rate feeds; 8453: weETHCrossRate.
  - **Amended by issue #357: 48, not 50.** Two of the 11 monitors are dead and are NOT redeployed:
    `ezETHCrossRateMarket` (its RedStone Classic leg `0xF4a3e183…` has not updated since 2026-08-20) and
    `osETHCrossRate` (its RedStone osETH/ETH leg `0x66ac817f…` reverts). Both are `enabled: false` and absent from the
    ezETH/osETH `monitorFeeds`, so `03` skips them and `MigrateToMonitorFeeds` deregisters them on-chain. AFTER that
    deregistration, retire their recorded addresses with `retire_custom_feeds.py --keys
    ezETHCrossRateMarket,osETHCrossRate` (the drift gate exempts a retired feed only once the live NAV no longer uses
    it), and drop their two rows from `script/deploy/DEPLOYED_ADDRESSES.md` in the same commit — CI's "Published
    addresses match the deployment records" step fails on a published address that is no longer a live record.
    osETH has no market monitor until a market price source exists (issue #357).
  - **Amended again by issue #357 (2026-10-23): 44, not 48 — ezETH and EIGEN are removed from the NAV.** No
    production client holds either (all client Safes checked on-chain; only test/staging Safes hold ~$35 of ezETH).
    Not redeployed: mainnet `ezETH` (primary) and `ezETHCrossRate` (monitor); Arbitrum `ezETH_L2` (primary) and
    `ezETHCrossRate` (monitor). That leaves 37 primaries (chain 1: 26, 42161: 4) + 7 monitors (chain 1: rETH, ETHx,
    stETH cross-rates and LBTCCrossRateMarket; 42161: weETH and rsETH cross-rates; 8453: weETHCrossRate), plus the two
    new WBTC monitors. All four are `enabled: false`, as is the Renzo wallet-yield adapter
    `RenzoRestakedEthWalletMeta` (`0x9145A559108426e1eA429A2A6441e2A875f069ec` on 1 and 42161; its only instance is
    ezETH). See "Asset removal" below for the batch calls; retire `ezETH`, `ezETHCrossRate` and `ezETHCrossRateMarket`
    (1) and `ezETH_L2`, `ezETHCrossRate` (42161) only after they execute.
  - **Expected `MigrateToMonitorFeeds` removals on chain 1**, so the post-run census reads none as a surprise: cbBTC's
    Chainlink cbBTC/USD primary `0x2665…`; and the dead `osETHCrossRate` monitor `0x34c1…`. On 8453: cbBTC's cbBTC/USD
    primary `0x07DA…`. (EIGEN's dead RedStone monitor `0x2ee5…` and ezETH's monitors `0x632c…` / `0xa52d…` are NOT
    Migrate removals: they go with `unregisterAsset` — see "Asset removal".)
  - **Swap cbBTC's primary in the same batch as the implementation upgrade (or right before it), not days ahead.**
    Chainlink BTC/USD's hourly rounds overshoot 3600 s by up to ~60 s (~520 s a day past heartbeat, measured), and
    under the LIVE pre-ADR-0029 library a stale primary prices the asset at 0 — so cbBTC on BTC/USD before the upgrade
    would be zero-priced for those seconds instead of ~10 s a day today. After the upgrade the same seconds are only a
    `stalePriceAssets` flag. (Base improves either way.)
  - With issue #356 (stacked PR): two NEW mainnet monitors, `WBTCCrossRate` and `WBTCCrossRateRedstone`, deployed by
    `03` alongside the redeploy, and cbBTC's primary moves from Chainlink cbBTC/USD to Chainlink BTC/USD on 1 and 8453
    (a Chainlink-to-Chainlink swap, no ADR 0029 ordering hazard). `MigrateToMonitorFeeds` performs both: it adds the
    new primary/monitors and removes cbBTC/USD in the same run. WBTC's RedStone BTC monitor `0xAB7f…` is KEPT: it is
    the only WBTC monitor that does not read the Chainlink BTC/USD primary, so it is what still raises `irregular`
    when that primary freezes (both new monitors multiply by it and go stale with it).
  - **In one Safe batch, use `MigrateToMonitorFeeds` alone** (every asset has a single primary, so it performs the
    primary swaps too). Generating `SwapCustomPriceFeeds` and `MigrateToMonitorFeeds` from the same live state and
    concatenating them re-removes the swapped feeds, and `removePriceFeed` reverts on a missing feed, reverting the
    whole batch. When run as separate executed transactions instead: run `script/manage/SwapCustomPriceFeeds.s.sol`
    first (primaries), then `script/manage/MigrateToMonitorFeeds.s.sol` (monitors). The second also reconciles each asset's primary to the
    config (it adds `priceFeeds[0]` when absent and removes any other pricing feed), so after the first its primary
    half is a no-op; run in the other order, it performs the primary swap itself and `SwapCustomPriceFeeds` then
    reports nothing to swap. Both add before they remove. Either script skips an asset whose new feed does not
    resolve, leaving its old feed in place — which the Rule 1 census catches.
- **Retired feeds are exempt from the drift gate.** `retire_custom_feeds.py` moves each replaced address to
  `retiredCustomPriceFeeds`, and `bytecode_audit.evaluate_drift` reports a STALE retired entry without failing
  on it (an older generation can never match the tree). The exemption holds only while the live NAV no longer
  uses the feed: `check_retired_registration` reads the feed's asset and the NAV's primary and monitor feeds, and
  a retired address that is still registered (its swap never executed) fails as `RETIRED_BUT_REGISTERED`. Missing
  code, an RPC error, or an unverifiable registration on a retired address also fails.

## Rule 1 — swap the custom feeds before the implementation upgrade (or in the same batch)

Never upgrade the NAV implementation first on a chain that still has a pre-ADR-0029 NAV-sourced custom feed
registered as a primary.

- **Why:** every deployed custom feed has the old `NavBaseUsdLib` compiled in. It flags a stale base only when
  `pd.stale && !pd.sequencerDown`, which was safe only because the old library priced a stale base at 0. Under the
  new library a stale base keeps its price. So while an L2 sequencer is down, an old feed reports a stale base as
  **fresh**, and the derived asset disappears from `stalePriceAssets`. Proof of concept:
  `test/vigilo-poc/PR354_OldFeedSequencerDown.t.sol`.
- **The safe direction:** a new feed under the old library returns `(0, true)` on a stale base, exactly as today.
  So the feeds can go first, on their own.
- **How:** per chain, either execute the feed swap and confirm it on-chain before the upgrade, or put the feed
  swap and `upgradeToAndCall` in one Safe batch with the swaps first.
- **Where the hazard is real:** only on a chain whose NAV has an L2 sequencer uptime feed. In the configs that is
  Arbitrum (42161) and Base (8453) among the chains with custom feeds (Optimism has one but no custom feeds;
  Gnosis 100 and Arc 5042 have none). Elsewhere an old feed under the new library is merely unusable when its base
  is stale, as today. Read `chainlinkL2SequencerUptimeFeed()` from the live proxy, not the config: it can be set
  after deploy. Keep Rule 1 on every chain regardless.
- **Before the upgrade, run the census, `script/deploy/preflight/adr0029_census.py --chain <id>`:** it walks the live proxy's
  `getRegisteredAssets()` × `getPriceFeeds` / `getMonitorFeeds` and assert that every `PriceType.Custom` address
  is in the chain's NEW `deployments.customPriceFeeds` set. The swap scripts are config-driven, so an asset that is
  registered on-chain but missing from the config, or that a script skipped, is invisible to them;
  `bytecode_audit.check_retired_registration` only looks at addresses already marked retired. Any hit blocks the
  upgrade on that chain. (An old monitor under the new library cannot mis-flag a price, since divergence is
  suppressed while the sequencer is down, but it would keep the chain drifted.) It also fails a Custom feed whose
  address is in the PRE-ROLLOUT record (`--base`, default `origin/main`), since before `03` runs the record still
  holds the live addresses; it reports the live implementation and sequencer feed per chain, and checks Rule 2 in
  the same walk. `--live-only` lists Custom feeds for a chain with no record (Robinhood). After #354/#358 merge,
  `origin/main` holds the new addresses: pass `--base <the pre-rollout commit>` for any later run.

## Asset removal — ezETH (1, 42161) and EIGEN (1), issue #357

In the same Council batch, **before `upgradeToAndCall`** (with ezETH out of config no script touches its feeds, so
only these calls take Arbitrum's old `ezETH_L2` — a NAV-sourced feed with the Rule 1 sequencer hazard — off the NAV):

1. `NAVCalculator.removeBalanceAdapters([0x9145A559108426e1eA429A2A6441e2A875f069ec])` (`RenzoRestakedEthWalletMeta`)
   on 1 and 42161. It releases the adapter's ezETH claim; doing it first leaves no claim behind for an unregistered
   asset.
2. `AssetKindRegistry.unregisterAsset(ezETH)` on 1 (`0xbf5495Ef…`) and 42161 (`0x2416092f…`), and
   `AssetKindRegistry.unregisterAsset(EIGEN)` (`0xec53bF91…`) on 1. Through the registry (`0xf60467a8…CCD0`, which
   holds MANAGER on the NAV) so the asset's kind and labels are cleared too. It deletes every price feed and monitor
   (incl. EIGEN's dead `0x2ee5…`, ezETH's `0x632c…`/`0xa52d…`/Arbitrum `0xCEbB…`), the tolerances and the
   default-adapter inclusion, and reads no feed, so a dead feed cannot make it revert.

Pinned by `test/nav/fork/AssetRemoval.fork.t.sol`. A position in an unregistered asset is dropped from NAV without a
flag: every leg in that asset, debt included, is dropped, while debt in other assets borrowed against it still
counts. That is why the removal was preceded by an on-chain holdings check. The
calls do not depend on the redeploy or the upgrade: if the rollout cannot execute before EIGEN's Chainlink feed
stops (2026-10-28), they can be signed on their own first. On Robinhood (4663), check `getRegisteredAssets()` for
ezETH/EIGEN before building its batch.

## Building and rehearsing the Council batches

One Security Council batch per chain, executed directly by the Council Safe (5-of-8). Tools, all in
`script/deploy/preflight/`:

- `adr0029_batch.py removals` (always writes its part, empty when there is nothing to remove; `assemble` refuses a missing part or one whose transactions no longer match its checksum, and `removals` refuses a registered adapter that config neither enables nor disables) derives the removal calls from the live NAV against this tree's config and refuses
  unless they equal `--expect-assets` / `--expect-adapters` (1: ezETH + EIGEN + the Renzo adapter; 42161: ezETH +
  the Renzo adapter; every other chain: none). `adr0029_batch.py assemble` concatenates removals +
  `MigrateToMonitorFeeds`'s batch + `upgradeToAndCall(newImpl, "")` into one Transaction-Builder file for the
  Council.
- `rehearse_adr0029_fork.sh <chainId> [block]` runs the whole sequence on a local anvil fork: `01_2`, retire, `03`,
  census (every live Custom feed must show PRE-ROLLOUT), the batch built as above, executed through the REAL Council
  Safe as one MultiSend (`council_fork_exec.py`: impersonated owners `approveHash`, then one `execTransaction`),
  census again (0 ERRORs), then a snapshot diff. Forge steps run under `FOUNDRY_PROFILE=slow` (EVM caps only; the
  default caps MemoryOOG on mainnet's config).
- **Generate the real batches the same way, on a fresh fork at the latest block, after the EOA deploys:**
  `MigrateToMonitorFeeds` must be simulated with the Council as `--sender`, and on several L2s the Council Safe
  holds no native token, so forge refuses to simulate against the live chain. The fork funds it.
- `MigrateToMonitorFeeds` re-emits `setDivergenceTolerance` / `setPegTolerance` for every configured asset even
  when the live value already matches (seen on Optimism: 6 such no-op calls). Harmless; signers will see them.

Rehearsed 2026-10-23 (all PASS): mainnet (95 calls, 2.95M gas), Arbitrum (25 calls, 0.77M), Base (21 calls,
0.54M), Optimism impl-only (7 calls). Mainnet's diff showed only the planned changes (ezETH/EIGEN/Renzo removed,
WBTC +2 monitors, cbBTC on BTC/USD, osETH's dead monitor removed); the only account that moved was the test Safe ACCOUNT_3, by its 0.005 aEzETH (issue #357), and no production account moved.

## Rule 2 — sweep the heartbeats already on-chain

`PriceFeedLib.addFeed` rejects a primary heartbeat at or above `MAX_STALE_PRICE_AGE` (7 days), but only when a
heartbeat is written. A heartbeat already stored at or above 7 days (other than `type(uint256).max`) keeps the old
fresh-to-zero cliff after the upgrade.

- **Before the upgrade, check:** for every registered asset, `getPriceFeeds(asset)` returns no primary with
  `chainlinkHeartbeat >= 604800` other than `type(uint256).max`. The committed config's largest primary heartbeat
  is 90,000 s, so a hit means the chain has drifted from the config.
- A `type(uint256).max` primary is never stale by age, so the 7-day cap does not apply to it. Use it only for a
  feed that reports its own staleness.

## Rule 3 — the library pin and the deployment records

- The `PriceFeedLib` pin in `foundry.toml` and `script/utils/LibraryPins.sol` is the NEW address. The deployment
  records (`script/config/deployments/<chainId>.json`) keep the live address until the new library is
  CREATE2-deployed on that chain; update them then. Until they are updated, `script/deploy/preflight/verify_step.py`
  fails on that chain (it requires the recorded `PriceFeedLib` to equal the pin) — expected, not a finding.
- Update `script/deploy/DEPLOYED_ADDRESSES.md` in the same commit as the records: CI's "Published addresses match
  the deployment records" step ties the two. (`script/deploy/preflight/verify_pr338_chain.sh` hardcodes the old
  pin; it is a PR #338-only tool and is not used for this rollout.)
- Re-check the pin (CI `pin-canary` and a clean local build must agree) after any change to the library's
  sources.

## Robinhood (4663)

Robinhood runs the same NAV proxy address (`0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214`) but is not in this repo's
configs or deployment records (issue #352), and its admin is its own Safe (`0x2F0d561B9a8CD981e6E73069592BDeA4e48A8bec`,
2-of-5, no timelock). It gets the same upgrade, so every rule above applies, checked from the live chain because no
config exists to read:

- **Rule 1 census, live:** list every `PriceType.Custom` primary and monitor via the proxy. Its equity feeds come
  from an external kit (`RobinhoodEquityPriceFeed`); before upgrading, confirm what each does when its input is stale
  — a feed that returns `(0, true)` stays unusable under the new library (today's behaviour), and only a NAV-sourced
  feed built with the old `NavBaseUsdLib` carries the sequencer hazard. Read `chainlinkL2SequencerUptimeFeed()`.
- **Rule 2 sweep, live:** the equity feeds are recorded as using 518,400 s (six days); confirm every primary
  heartbeat is below 604,800 s.
- The Safe batch is built and stamped by hand for `0x2F0d…`; the library and implementation CREATE2 deploys use
  the canonical deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` directly.
