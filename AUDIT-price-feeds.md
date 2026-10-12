# Price-feed leaf audit — the 27 untouched per-asset feeds

> **PROVENANCE — EVERY COUNT BELOW IS HISTORICAL (as of the audit date), NOT CURRENT.**
> This document's census ("39 instances", "mainnet 24", "6 of the 39") was measured when it was
> written and nothing re-derives it, so it went stale the first time feeds were added. Measured
> 2026-08-27: `script/config/deployments/1.json` holds **30** non-empty `customPriceFeeds` on mainnet,
> not 24. Treat the totals as a snapshot of the reasoning, not as present-day inventory — re-derive
> from the deployment records before relying on any figure here. The individual FINDINGS still stand
> except where a note says otherwise (see the sDAI supersession below).


**Status:** findings report. Originally a report-only artefact; committed 2026-07-29 so the reasoning behind the fixes in PR #199 is auditable from the repo rather than living in one worktree.

**Branch:** `audit/price-feed-leaf-sweep` @ `53b2d2eb` (origin/main).
**Worktree:** `/home/sgzerbo/github-projects/onchain-accounting-price-feeds`
**Date:** 2026-07-29

## Method

Manual read. **No review gates were run** — so the "was the gate forced read-only" question does not apply; nothing was executed, and no gate debris exists. `git status --porcelain --untracked-files=all` was empty before this file was written; there is no `out/`.

Read in full:

- All 27 in-scope leaves under `src/prices/protocols/`.
- The 6 already-touched leaves (`ETHPlus`, `ankrETH`, `eETH`, `sDAI`, `weETH`, `wstETH`) for comparison.
- All four shared bases: `BaseCustomPriceFeed`, `TwoFeedChainlinkPriceFeed`, `ERC4626VaultRatePriceFeed`, `NavBaseUsdLib`.
- The consumer side: `Prices.sol`, and in `PriceFeedLib.sol` the paths `_selectFeedCore`, `buildPriceData`, `_readFeedPrice`, `_monitorDivergence`, `_divergenceFor`, `_scaleTo8`, `_buildPriceFeedCache`, `_enrichPosition`, `_priceConversion`, `_validateFeedSupportInternal`, `_resolveFeedDecimals`, `addFeed`, `addMonitorFeed`.
- `NAVCalculator.getPriceData` / `getPriceDataNoDivergence`.
- `ADR 0019` (NAV-sourced base price) and `ADR 0020` (governing-leg freshness).
- Both config trees for all chains: `contracts-deployment-config/custom-price-feeds/`, `nav-config/assets-and-price-feeds/`, and the deployed-address records in `deployments/`.
- `03_DeployPriceFeeds.s.sol`, `script/manage/RegisterAssets.s.sol`, `06_Configure.s.sol`, `preflight/reset_deployment_records.py`.

---

## Two call-outs first — these are decisions, not defects

### A. `osToken_CustomPriceFeed` — two bases, no guard. Both deployments are correct today.

`src/prices/protocols/osToken_CustomPriceFeed.sol:23-28`

This is the only contract in the repo deployed against **two different base assets** from one source file:

| Instance | Chain | `osTokenVaultController` | `baseAsset` | Correct? |
|---|---|---|---|---|
| `osETH` | mainnet | `0x2A261e60…` (ETH-denominated) | WETH `0xC02aaA39…` | **yes** |
| `osGNO` | Gnosis | `0x60B2053d…` (GNO-denominated) | GNO `0x9C58BAcC…` | **yes** |

`_rate()` is `OsTokenVaultController.convertToAssets(1e18)` — underlying-per-osToken. The base must be that same underlying. Nothing enforces it: the constructor inherits `BaseCustomPriceFeed`, whose only base check is `OracleArgumentChecks.assertERC20Address(baseAsset_)` (`BaseCustomPriceFeed.sol:47`), which merely probes `totalSupply()`.

**What a wrong base would produce: a silently wrong price, not a revert.** Two sub-cases:

- **Wrong base is a registered NAV asset** (the realistic confusion — every plausible mix-up here is between two assets that are both registered on that chain). `getPriceDataNoDivergence` returns a healthy price, `NavBaseUsdLib.baseUsd` returns `stale = false`, and `BaseCustomPriceFeed.sol:78` multiplies the rate by the wrong USD value. `getLatestPrice()` returns `stale = false`. Concretely: deploy `osGNO` on Gnosis with `baseAsset` = Gnosis WETH (`0x6A023CCd…`, registered with a live Chainlink feed) instead of GNO. osGNO is then priced at `(GNO per osGNO ≈ 1.0) × (ETH/USD ≈ $3,000)` instead of `× (GNO/USD ≈ $150)` — roughly a **20× over-report**, permanent, with `stale = false` and `irregular = false`.
- **Wrong base is not registered** — `getPriceDataNoDivergence` reverts `AssetNotRegistered`, `NavBaseUsdLib.baseUsd`'s `catch` (`NavBaseUsdLib.sol:56-58`) returns stale, the asset drops out of NAV at $0. Under-report, surfaced in `stalePriceAssets`. The safe direction, but only by luck of which asset you typo'd.

**Contrast with the ERC-4626 family, which self-protects:** `ERC4626VaultRatePriceFeed.sol:70-71` reads `IERC4626(vault_).asset()` and reverts `BaseAssetMismatch` in the constructor. A wrong base there fails the deploy loudly. That guard covers `sUSDe`, `sUSDS`, `sXDAI`, `syrupUSDC`, `RWIV`, `sGHO` — 6 of the 39 instances.

The absence applies to every non-4626 feed (all `BaseCustomPriceFeed` and `TwoFeedChainlinkPriceFeed` descendants, plus bespoke `ankrETH` and `sDAI`), but `osToken` is the one where the base is genuinely a **per-chain variable** rather than a constant repeated across deployments — so it is the one where a config error is plausible rather than theoretical.

**Priority: "add a guard for the future", not "something is wrong on a chain today."** Nothing is mispriced right now.

> **CORRECTION (2026-07-29) — finding #4's guard does NOT cover this.** It was suggested that the general
> `underlyingAssetSupported()` check would subsume this call-out, so no bespoke guard would be needed. It does not, and
> the two are orthogonal:
>
> - **#4's guard checks the *registration* axis:** is this feed registered for the asset it prices? It compares
>   `underlyingAssetSupported()` against the asset being registered.
> - **`osToken`'s exposure is on the *construction* axis:** was this feed built with a `baseAsset` matching its rate
>   source's denomination? A feed constructed as `(osGNO, gnosisController, nav, WETH)` still returns
>   `underlyingAssetSupported() == osGNO` and passes #4's guard **cleanly**, while pricing osGNO off ETH/USD.
>
> So #4 closes the wrong-asset hole and leaves the wrong-base hole open. This remains an open decision.
>
> A bespoke *constructor* guard may not be constructible: it would need the `OsTokenVaultController` to expose its
> underlying asset, and our `IOsTokenVaultController` interface declares only `convertToAssets`. Whether StakeWise's
> deployed controller has such a getter on either chain was not verified (it needs an on-chain read). If it does not,
> the only available guard is **deploy-time**: assert in `03_DeployPriceFeeds` or preflight that chain 1's `osETH`
> entry carries `baseAsset == WETH` and chain 100's `osGNO` entry carries `baseAsset == GNO`. That is tooling, not
> source, and therefore pin-neutral and outside this cycle's source scope.

### B. `cbETH_CustomPriceFeed`, `ETHPlus_CustomPriceFeed` — and `sDAI_CustomPriceFeed` — are deployed on no chain. Three, not two.

> **SUPERSEDED FOR `sDAI` (2026-08-27).** This finding was accurate when written and is now wrong on
> sDAI specifically. `sDAI_CustomPriceFeed` was revived as an `ERC4626VaultRatePriceFeed` subclass,
> deployed to mainnet at `0x84eDa44d3ab2982692804b153D4bE88A0AfD533C`, and sDAI IS a registered
> mainnet asset — so every claim below about sDAI having "no config entry on any chain", being
> "genuinely dead", and mainnet sDAI "not being a registered asset" no longer holds, and the
> suggestion to drop the contract must not be acted on. The contract is also no longer the chi-based
> implementation this document describes. `cbETH` and `ETHPlus` are unaffected and the finding stands
> for them. Left in place rather than rewritten so the reasoning stays legible.

Confirmed from **both** independent sources, which agree:

- **Deployed-address records** (`script/config/deployments/<chainId>.json`, key `customPriceFeeds`) — populated across all 25 chain files, totalling exactly **39 instances**: mainnet 24, Arbitrum 8, Base 4, Gnosis 3, and empty on the other 21 chains. `cbETH`, `ETHPlus` and `sDAI` appear in **none** of them.
- **Intended config** (`contracts-deployment-config/custom-price-feeds/<chainId>.json` and `nav-config/assets-and-price-feeds/<chainId>.json`) — `ETHPlus` is present on mainnet but `"enabled": false` with a `$comment` explaining the 8-dec/18-dec `PriceFeedDecimalsMismatch`; ETH+ is instead priced by a direct Chainlink feed. `cbETH` and `sDAI` have no config entry on any chain at all, so `_isEnabled` returns false and `_deployCbEth()` / `_deploySdai()` never run.

The two files disagree with nothing. All three are **genuinely dead**: compiled, unit- and fork-tested, and deployed nowhere.

Note `sDAI_CustomPriceFeed` is one of the six feeds the ADR 0019 wave *did* touch — it was migrated to the NAV-sourced base and is still dead. Gnosis uses `sXDAI_CustomPriceFeed` instead; mainnet sDAI is not a registered asset.

`_deployCbEth()` at `03_DeployPriceFeeds.s.sol:525` and `_deploySdai()` at `:231` and `_deployEthPlus()` at `:701` are all reachable-but-never-taken branches. The redeploy is a good moment to drop all three contracts and their deploy paths rather than ship code nobody uses. `cbETH` on mainnet in particular is superseded by nothing — the asset simply isn't held; `cbETH_L2` on Base is the live one and is unaffected.

**Two clarifications, confirmed against the script (2026-07-29):**

1. **Dropping them changes the instance count by zero. The redeploy is 39 feeds, not 36.** These three were never
   among the 39 — they are absent from every chain's `customPriceFeeds` record and from every `nav-config` entry. Any
   arithmetic that subtracts them from 39 is wrong; there is nothing to subtract. Deleting the contracts removes
   compile surface and review surface only.
2. **The enablement gate sits UPSTREAM of the skip-if-deployed guard, so clearing the deployment records cannot
   expose them.** Each call in `_deployMainnetPriceAdapters` is wrapped as
   `if (ConfigReader.isAdapterEnabled(vm, currentChainId, "priceFeeds", "<name>")) { _deploy<Name>(); }` — verified for
   `sDAI` and `cbETH` at `03_DeployPriceFeeds.s.sol:98-99` and `:153-155`. `isAdapterEnabled` reads
   `contracts-deployment-config`, not `deployments`, and returns false for a missing key or `"enabled": false`. So the
   `_deploy*` body — and with it the skip-if-deployed early return — is never entered. My original wording called them
   "reachable-but-never-taken branches", which is true but attributes the block to the wrong gate: it is the
   enablement check, not the skip guard, that stops them. This matters because it means the reset-before-`03`
   ordering hazard (see the leftover sweep) does **not** also risk deploying dead feeds.

---

## Deployment inventory

39 instances, from the deployed-address records:

| Chain | Count | Instances |
|---|---|---|
| Mainnet (1) | 24 | `wstETH`, `stETH`, `lsETH`, `rETH`, `osETH`, `weETH`, `eETH`, `ezETH`, `rsETH`, `ETHx`, `sUSDe`, `sUSDS`, `syrupUSDC`, `RWIV`, `sGHO`, `OETH`, `LDO`, `ankrETH`, `NXM`, `wNXM`, `ezETHCrossRate`, `ETHxCrossRate`, `osETHCrossRate`, `rETHCrossRate` |
| Arbitrum (42161) | 8 | `wstETH_L2`, `weETH_L2`, `rsETH_L2`, `ezETH_L2`, `syrupUSDC_L2`, `weETHCrossRate`, `ezETHCrossRate`, `rsETHCrossRate` |
| Base (8453) | 4 | `wstETH_L2`, `weETH_L2`, `cbETH_L2`, `weETHCrossRate` |
| Gnosis (100) | 3 | `osGNO`, `sXDAI`, `wstETH_L2` |

Of these, **31 are primaries** and **8 are `monitorFeeds`** (divergence-only; never price the NAV).

**ADR 0019's circularity invariant holds everywhere.** Every `baseAsset` was checked against `nav-config/assets-and-price-feeds/`: WETH, USDC, USDe, USDS, GHO (mainnet); WETH, USDC (Arbitrum); WETH (Base); GNO, WXDAI, WETH (Gnosis). All are priced by direct Chainlink primaries. No feed reads a NAV-sourced base. No recursion is reachable.

---

## Ranked findings

Ranked by "would this produce a wrong NAV on a configured chain today".

### 1. stETH is priced at MARKET while wstETH and eETH are priced FUNDAMENTAL — same claim, two answers

**Files:** `src/prices/protocols/stETH_CustomPriceFeed.sol:13` (contract), `:19-21` (constructor) — against `src/prices/protocols/wstETH_CustomPriceFeed.sol:23-25` and `src/prices/protocols/eETH_CustomPriceFeed.sol:21-23`. Config: `script/config/contracts-deployment-config/custom-price-feeds/1.json` → `stETH.constructor.yToXFeed = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812`.

**What breaks.** stETH's primary is a `CrossRateCustomPriceFeed` over the Chainlink **market** stETH/ETH feed. wstETH's primary is `stEthPerToken() × ETH/USD` with stETH/ETH ≡ 1.0 held as a fundamental invariant. eETH — the exact structural analogue of stETH, a ~1:1 rebasing claim on staked ETH — is hardcoded to `1e18`. stETH is the only ETH-LST in the system whose primary is a market feed, and it is the direct sibling of the two feeds that most explicitly refuse to be.

**Failure scenario.** stETH trades at 0.94 ETH (June-2022 magnitude; the event the 250 bps tolerances exist for). A fund holding 1,000 stETH is valued at 940 ETH-equivalent. A fund holding the economically identical ~870 wstETH is valued at ~1,000. Inside a *single* portfolio the two legs stop netting: Aave wstETH collateral sitting against a Curve stETH/ETH LP, or a Lido withdrawal-queue leg (denominated in stETH) beside wstETH collateral, will show a ~6% phantom P&L with zero position change. This is the same class of error ADR 0019 was written to eliminate for the ETH/USD term — a term that fails to cancel because two legs source it differently — except here the term is stETH/ETH.

**Direction.** wstETH **over-reports** relative to stETH during a discount (and under-reports during a premium). Both are wrong relative to each other regardless of which convention is "right".

**Reachable.** Yes — mainnet, both configured and deployed today.

**Why it survived the wave.** `src/prices/PRICE_ADAPTERS.md:269` describes wstETH as `stEthPerToken × stETH/ETH × ETH/USD` — "*uses the real stETH/ETH rate, no 1:1 assumption*". That is flatly contradicted by `wstETH_CustomPriceFeed.sol:23-25`. Anyone auditing the pair for consistency from the doc would conclude they already agree. And `PRICE_ADAPTERS.md:266` records that stETH was converted to a CrossRate purely so "*ETH/USD cancels when NAV is quoted in ETH*" — the ADR 0019 reason. The market-vs-fundamental question was never asked. **This is the clearest single case of an assumption ADR 0019's migration only partially reached.**

**Triage note.** Whichever convention is chosen, the two must agree. The cheapest consistent option is to make stETH mirror eETH (`_rate() = 1e18`, i.e. a `BaseCustomPriceFeed` with a unit rate) and demote the market stETH/ETH cross-rate to a monitor — which is exactly the shape wstETH and weETH already have, and which stETH's existing Chainlink stETH/USD monitor already half-implements.

### 2. ezETH's only depeg detector is now itself a fundamental feed

**Files:** `src/prices/protocols/ezETH_CrossRateCustomPriceFeed.sol:9-12`. Config: `custom-price-feeds/1.json` → `ezETHCrossRate.constructor.yToXFeed = 0x701e83Bd1B84D02c10587f0De9Dfad5A22419DF7`; `nav-config/assets-and-price-feeds/1.json` → `ezETH.divergenceToleranceBps = 250`, `monitorFeeds = [ezETHCrossRate]`.

**What breaks.** ezETH's primary is Renzo's on-chain `calculateTVLs() / totalSupply` (`ezETH_CustomPriceFeed.sol:33-41`) — fundamental. Its **sole** monitor is `ezETHCrossRate`, whose rate leg was migrated on 2026-07-22 to **RedStone's `ezETH_FUNDAMENTAL` feed**. The config `$comment` records the swap and argues independence ("*RedStone's rate vs Renzo's*") — true of the *source*, false of the *methodology*. Two fundamental sources agreeing tells you nothing about market price.

Compounding it: post-ADR-0019 both legs read base/USD from the same NAV via `NavBaseUsdLib`, so the ETH/USD term cancels **exactly** in `_monitorDivergence` (`PriceFeedLib.sol:322-330`). The comparison reduces to `|rate_renzo − rate_redstone| / rate_renzo` with no residual signal from the base at all.

**Failure scenario.** ezETH trades at 0.95 ETH on secondary markets while Renzo's TVL/supply and RedStone's fundamental feed both still report 1.02. `divergenceBps ≈ 0`, so `irregular` stays false and `ezETH` never appears in `nav.irregularPriceAssets`. The 250 bps tolerance cannot fire on the one event it exists to catch.

**Direction.** **Over-reports** a depegged ezETH, silently, with no `irregular` flag.

**Reachable.** Mainnet only. Arbitrum's `ezETHCrossRate` still uses the Chainlink ezETH/ETH **market** feed (`0x11E1836b…`) and is fine — which is what makes the mainnet case look like an oversight rather than a policy.

**Also stale here.** The docstring at `ezETH_CrossRateCustomPriceFeed.sol:11-12` still says "*Redstone Classic Push **market** feed*" and "*gives `Prices`'s freshest-wins selector a genuinely separate source to **fall back** to*". Both wrong now: the feed is fundamental, and it is a monitor that never prices the NAV.

### 3. 16 of 31 primary instances have no divergence or peg check at all

**Files:** `script/config/nav-config/assets-and-price-feeds/{1,100,42161}.json`.

| Chain | Primaries with no monitor and no `divergenceToleranceBps` |
|---|---|
| Mainnet (12 of 20) | `lsETH`, `eETH`, `rsETH`, `sUSDS`, `syrupUSDC`, `RWIV`, `sGHO`, `OETH`, `LDO`, `ankrETH`, `NXM`, `wNXM` |
| Gnosis (3 of 3) | `osGNO`, `sDAI` (`sXDAI`), `wstETH` (`wstETH_L2`) |
| Arbitrum (1 of 5) | `syrupUSDC` |
| Base (0 of 3) | — all three have monitors |

**Failure scenario.** `rsETH` on mainnet is priced solely off `RsETHRateProvider.getLatestRate()` (`rsETH_CustomPriceFeed.sol:30`). If Kelp's rate provider is misconfigured, or its upstream reporter posts a bad rate, the NAV takes it verbatim: no monitor, no tolerance, no `irregular`, and `stale = false` because the freshness gate reads the *base* feed's `updatedAt`, not the rate's. Same structure for `ankrETH` on `ratio()`, `NXM`/`wNXM` on `RAMM.getInternalPrice()`, and the five ERC-4626 feeds on `convertToAssets` — none of which bound the per-share rate (`ERC4626VaultRatePriceFeed.sol:97-98`).

Worth noting on the 4626 side: `sUSDe`'s `totalAssets` is inflatable by a direct USDe transfer to the vault (it bypasses the `transferInRewards` vesting accounting). `sUSDe` is the **one** ERC-4626 feed here that has monitors and would flag it; `sUSDS`, `syrupUSDC`, `RWIV`, `sGHO` and `sXDAI` do not. The attack is not economically rational against a NAV read (the donation costs the attacker what it inflates), but the detector is absent either way.

**Direction.** Either — an unverified rate can move in both directions.

**Reachable.** Yes, three chains. This is a config gap, and cheap to close for the ones with an available independent USD feed (`rsETH`, `ankrETH`, `LDO`, `OETH` all have market feeds; `lsETH` has a Redstone feed).

### 4. Nothing verifies a custom feed prices the asset it is registered for

**File:** `src/prices/PriceFeedLib.sol:1649-1650`.

`_validateFeedSupportInternal` checks only `priceFeed.supportsInterface(type(ICustomPriceFeed).interfaceId)`. **`underlyingAssetSupported()` is implemented by all 27 leaves and read by nothing.** Grepping `src/`, `script/` and the preflight Python returns only the implementations themselves plus prose in `PRICE_ADAPTERS.md:146` and `docs/howto/add-price-feed.md:223`. It is dead surface.

**Failure scenario.** `script/manage/RegisterAssets.s.sol:151-158` resolves `nav-config[asset].priceFeeds[].feed` — a **string key** — against `deployments.customPriceFeeds[<name>]`. Mainnet carries near-identical name pairs: `ezETH`/`ezETHCrossRate`, `osETH`/`osETHCrossRate`, `ETHx`/`ETHxCrossRate`, `rETH`/`rETHCrossRate`, `NXM`/`wNXM`; Arbitrum has `weETH_L2`/`weETHCrossRate`. Register `wstETH`'s asset entry against the `weETHCrossRate` address and the NAV prices every wstETH position at weETH's price, permanently. Registration succeeds (`supportsInterface` passes, decimals match at 8), the price is plausible, `stale = false`, and nothing on-chain or in tooling objects.

**Direction.** Arbitrary — depends entirely on which two feeds got crossed.

**Reachable.** Only via a deploy/config mistake, not chain state. But the imminent redeploy **re-registers all 39 instances by string key across 4 chains**, which is precisely when this guard earns its cost. A single line in `_validateFeedSupportInternal` — `if (ICustomPriceFeed(priceFeed).underlyingAssetSupported() != token) revert …` — closes it for `registerAsset`, `addOrModifyPriceFeed` and `addMonitorFeed` at once, and it also subsumes call-out A above for every non-4626 feed.

### 5. Rate-feed *pair identity* is asserted nowhere, and the fork tests are tautological

**Files:** `src/prices/TwoFeedChainlinkPriceFeed.sol:66` (`OracleArgumentChecks.assertChainlinkOracle`) and `:72` (`_rateUnit`). `src/utils/OracleArgumentChecks.sol:53-61`.

16 of the 39 instances are `TwoFeedChainlinkPriceFeed`/`CrossRateCustomPriceFeed` descendants taking a hand-entered rate-feed address. The constructor confirms the address is *an* AggregatorV3 (it probes `latestRoundData()`); it never confirms *which pair*. `description()` appears nowhere in `test/` or `script/` — only in `test/mocks/price_oracles.sol:74`, one JSON `$comment`, and one runbook line.

**Failure scenario.** Configure Base `wstETH_L2` with the cbETH/ETH feed (`0x806b4Ac0…`) instead of wstETH/ETH (`0x43a5C292…`). Both are 18-decimal, both fresh, both pass `assertChainlinkOracle`, and `_rateUnit` adapts to either. Price becomes ≈ 1.07 × ETH/USD instead of ≈ 1.21 × ETH/USD — a silent **~12% under-report** across the entire wstETH book, permanent, with `stale = false` and `irregular = false` (Base wstETH's Redstone monitor at 250 bps would fire here, but the equivalent mistake on any of the 16 assets *without* a monitor, per finding #3, would not).

**The fork tests do not catch this.** `test/prices/protocols/fork/wstETH_L2_CustomPriceFeed.fork.t.sol:29-38` computes `expected` from the **same** `RATE_FEED.latestRoundData()` the contract reads:

```solidity
(, int256 rate,,,) = AggregatorV3Interface(RATE_FEED).latestRoundData();
uint256 rateDecimals = AggregatorV3Interface(RATE_FEED).decimals();
uint256 expected = (uint256(rate) * base8) / (10 ** rateDecimals);
assertEq(price, expected, ...);
```

That asserts the arithmetic, never the sanity — there is no plausibility bound on the resulting USD price and no `description()` check. The pattern repeats across the L2 and CrossRate fork tests. Worse, each test hardcodes `RATE_FEED` as a constant **independent of the deploy JSON**, so a config change does not propagate to the test at all. Three rate-feed addresses were changed by hand in the last week (RedStone sunsets, 2026-07-22 and 2026-07-27) with nothing in CI observing it.

**Direction.** Arbitrary, silent.

**Reachable.** Deploy-time only — but it is the highest-leverage cheap check available before a 39-instance redeploy. Two options, either sufficient: assert `description()` in the fork tests, or add a plausibility band (`0.9e8 ≤ price/base8 ≤ 1.5e8` for the ETH-LSTs) so a wrong-pair feed fails loudly.

**Secondary test-quality note.** `test_getLatestPriceStale` warps by `RATE_HEARTBEAT + 1`, which also pushes the NAV base past its heartbeat — so the test cannot distinguish which leg fired the staleness. It would pass even if the rate-leg gate were removed entirely.

### 6. Four configured contracts have zero tests

**Files:** `src/prices/protocols/lsETH_CustomPriceFeed.sol`, `ezETH_CrossRateCustomPriceFeed.sol`, `ETHx_CrossRateCustomPriceFeed.sol`, `osETH_CrossRateCustomPriceFeed.sol`.

No unit test, no fork test, no appearance in `test/integration/`. Grepping each contract name across `test/` returns only `script/`.

- `lsETH` is lsETH's **sole primary** on mainnet, and lsETH has no monitor (finding #3).
- The other three are the **sole monitor** for ezETH, ETHx and osETH respectively.

The parent `CrossRateCustomPriceFeed` *is* tested (`test/prices/protocols/CrossRateCustomPriceFeed.t.sol` + `.fork.t.sol`), so the arithmetic is covered. What is not covered is each instance's feed address, decimals and pair — which, per finding #5, is the uncovered half and the half that has been changing.

**Reachable.** All four are enabled and deployed on mainnet today.

### 7. `_compute()` runs twice per feed selection — and ADR 0019 made each run far more expensive

**Files:** `src/prices/BaseCustomPriceFeed.sol:106` (and the identical pattern in `TwoFeedChainlinkPriceFeed.sol:135`, `ERC4626VaultRatePriceFeed.sol:126`, `ankrETH_CustomPriceFeed.sol:105`, `sDAI_CustomPriceFeed.sol:120`) against `src/prices/PriceFeedLib.sol:105-124`.

`_selectFeedCore` calls `getLatestPrice()` **and then** `latestRoundData()` on each Custom feed. Both run the full `_compute()`. `_readFeedPrice` (`PriceFeedLib.sol:378-391`) does the same for Custom **monitor** feeds.

Pre-ADR-0019 the second run cost one extra Chainlink `staticcall`. Post-0019 it costs a full re-entry into the NAV proxy: `getPriceDataNoDivergence` → `_requireAssetExists` → `_requirePriceFeedExists` → `buildPriceData` → `_selectFeedCore(base)` + a second `latestRoundData()` on the base aggregator (`PriceFeedLib.sol:518`). On the `getPriceData` path there is a **third** re-entry, via `governingFeedFreshness()` → `NavBaseUsdLib.baseFreshness`.

**Failure scenario.** Worst case is `ezETH_CustomPriceFeed.sol:33-41`: Renzo's `RestakeManager.calculateTVLs()` iterates every operator delegator × collateral token and is executed **twice** per NAV read of ezETH. Against the ~30M gas complete-read budget, a starved `calculateTVLs()` runs out of gas, the `catch` at line 38 returns 0, `_rate() == 0` trips `BaseCustomPriceFeed.sol:76`, and ezETH is marked stale — its positions valued at **$0**.

**Direction.** **Under-report**, and surfaced in `nav.stalePriceAssets` — so it degrades safely rather than silently. That is why this ranks below the wrong-number findings despite being the most expensive item on the price path.

**Reachable.** Mainnet, gas-dependent. Worth **measuring** before the redeploy rather than fixing blind. If the number is bad, hoisting the double `_compute()` (cache within the call, or have `latestRoundData` reuse `getLatestPrice`'s work) is the obvious lever, and it lives in the shared bases rather than the leaves.

### 8. `sUSDS` is gated tighter than its own base

**File:** `script/config/nav-config/assets-and-price-feeds/1.json` — `sUSDS.priceFeeds[0].heartbeat = 82800` vs `USDS.priceFeeds[0].heartbeat = 86400`.

**What breaks.** Post-ADR-0019 a NAV-sourced feed's `latestRoundData().updatedAt` **is the base feed's** `updatedAt` (`ERC4626VaultRatePriceFeed.sol:93`, `BaseCustomPriceFeed.sol:73`). `_selectFeedCore` gates that timestamp against the *registered* heartbeat (`PriceFeedLib.sol:147`). So the 3,600-second window between 82,800s and 86,400s of USDS-feed age leaves **USDS priced and sUSDS stale**.

Every other pairing is consistent: `sUSDe` 82800/82800, `syrupUSDC` 82800/82800, `RWIV` 82800/82800, `sGHO` 86400/86400, and all the mainnet ETH derivatives 3600/3600 against WETH's 3600. `sUSDS` is the only mismatch.

The reverse direction is safe by construction: a *looser* derived heartbeat cannot over-report, because `NavBaseUsdLib.baseUsd` inherits the base's own staleness verdict regardless.

**Direction.** **Under-report** — sUSDS positions drop to $0 in that window, flagged stale.

**Reachable.** Mainnet, narrow window. One-character config fix.

### 9. Doc drift that actively misleads

- **`src/prices/PRICE_ADAPTERS.md:269`** — wstETH described as using "*the real stETH/ETH rate, no 1:1 assumption*". The code does the opposite (`wstETH_CustomPriceFeed.sol:23-25`). This is what hid finding #1.
- **`src/prices/PRICE_ADAPTERS.md:289`** — the three `*CrossRate` feeds described as registered "*alongside* their primary feed … giving the freshest-wins selector a genuinely separate fallback source", all sourced from "*Redstone Classic Push market*" feeds. All three are now `monitorFeeds` and never price the NAV; ETHx's rate leg is Chainlink; ezETH's is fundamental.
- **`ezETH_CrossRateCustomPriceFeed.sol:9-12`, `ETHx_CrossRateCustomPriceFeed.sol:9-12`, `osETH_CrossRateCustomPriceFeed.sol:9-12`** — same claim repeated in each docstring.
- **`script/deploy/03_DeployPriceFeeds.s.sol:609-610`** — "*The Y/ETH leg is a Redstone market feed … Registered as priceFeeds[1] (freshest-wins)*", directly contradicted by `_deployCrossRateMonitor`'s own docstring four lines below at `:612-615` ("*Wired as a Custom monitorFeed; never prices the NAV*").

---

## The ADR 0019 leftover sweep

Targeted pass for the class most likely to survive a per-file read and bite only at deploy time: leftover assumptions, stale comments that now misdescribe the code, and constructor parameters that are no longer meaningful.

### Constructor parameters — clean

Enumerated every `constructor` key across all seven `custom-price-feeds/*.json` files. Full set:

```
ankrEth, baseAsset, cbEth, cbEthToEthChainlink, cbEthToEthHeartbeat, eEth, ethPlus, ethx,
ezEth, ldo, ldoToEthChainlinkAddress, ldoToEthChainlinkHeartbeat, osToken,
osTokenVaultController, rEth, ramm, rateProvider, reserveProtocolHeartbeat, restakeManager,
rsEth, rsEthToEthChainlink, rsEthToEthHeartbeat, rwiv, sUsde, sUsds, sXdai, sgho,
stakePoolsManager, syrupUsdc, syrupUsdcToUsdcChainlink, syrupUsdcToUsdcHeartbeat, token,
underlyingAsset, weEth, weEthToEethChainlink, weEthToEethHeartbeat, wstEth,
wstEthToEthChainlink, wstEthToEthHeartbeat, xRenzoDeposit, yToXFeed, yToXHeartbeat
```

**Every key maps to a live constructor parameter.** No orphaned base-oracle address, no orphaned base heartbeat, nothing left over from the pre-0019 embedded-Chainlink shape. `reserveProtocolHeartbeat` belongs to `ETHPlus`, which is correctly outside 0019's scope (basket feed, no base oracle). The `*Heartbeat` keys all feed `RATE_HEARTBEAT`, which still gates the rate leg. The only cosmetic wart is inconsistent naming of the underlying (`underlyingAsset` for the CrossRate family, per-asset names like `wstEth`/`rEth` elsewhere).

### Reported heartbeat ≠ configured heartbeat — by design, but reconciliation tooling must know

`buildPriceData` (`PriceFeedLib.sol:503-514`) **overrides** `priceFeedData.chainlinkHeartbeat` for Custom feeds with `governingFeedFreshness()`'s value. So `getPriceData(wstETH).chainlinkHeartbeat` on mainnet returns **3600** (WETH's registered heartbeat, via `NavBaseUsdLib.baseFreshness`), not the **86400** that is configured for the wstETH feed. For `TwoFeedChainlinkPriceFeed` instances the reported value **oscillates block-to-block** between `RATE_HEARTBEAT` and the base's heartbeat, depending on which leg currently has the larger `age/heartbeat` ratio (`TwoFeedChainlinkPriceFeed.sol:164-181`).

This is **documented and intentional** — ADR 0020 §Decision, and it explicitly notes the pair is additive and does not affect `_selectFeedCore`'s gate. It is not a defect. It is recorded here because a post-redeploy reconciliation that diffs on-chain `chainlinkHeartbeat` against `nav-config` will show spurious drift on all 39 Custom entries, and "fixing" the config to match would silently retune the selection gate. Any verification script must compare against `getPriceFeedAt(asset, i).chainlinkHeartbeat` (the stored config), not `getPriceData(asset).chainlinkHeartbeat` (the governing leg).

### Deploy-time hazard: `03` is skip-if-deployed, and feeds hold an immutable NAV address

This is the sharpest deploy-time consequence of ADR 0019 and belongs on the redeploy checklist.

Every one of the 39 feeds pins `INAVCalculator public immutable NAV` in its constructor from `deployments.NAVCalculatorProxy`. The NAV proxy address has moved twice already (`0x42aC2659…` → `0xE745B83C…` → `0x80eD5cc6…`).

Every `_deploy*` function in `03_DeployPriceFeeds.s.sol` opens with a skip-if-deployed guard (e.g. `:394-398`, `:415-419`, `:436-440`) that **returns early and does not revert**. So if `customPriceFeeds` records survive from a previous NAV generation, `03` silently keeps the old feed addresses, and every one of them stays bound to the **previous NAV proxy**.

**What that produces:** `NavBaseUsdLib.baseUsd` calls `getPriceDataNoDivergence` on the old proxy. If that proxy still exists and still has WETH registered, it returns a stale-but-plausible price and the feeds keep working while reading a NAV nobody is maintaining. If it has been decommissioned, the call reverts, the `catch` at `NavBaseUsdLib.sol:56-58` returns stale, and **every custom-priced asset on that chain silently drops to $0** — under-report, flagged in `stalePriceAssets`, but that is 24 of the mainnet assets at once.

`preflight/reset_deployment_records.py:66` does cover this — `CLEAR_SECTIONS = ["balanceAdapters", "customPriceFeeds"]`. The hazard is purely one of **ordering**: the reset must run before `03`, on every chain, or `03` no-ops. Note that as of this commit the records are **populated** (all 39 present), so the reset has not yet been run for this redeploy. Combined with the known "`03` logs errors and still exits 0" behaviour, a green `03` run is not evidence that anything was deployed.

### Stale comments — see finding #9

Four sites, all listed above. The wstETH one (`PRICE_ADAPTERS.md:269`) is the consequential one: it does not merely lag the code, it describes the *opposite* behaviour, in the direction that conceals finding #1.

---

## Read clean — no findings

Each of the following was read in full and traced for rate orientation, decimal scaling, staleness path, and revert behaviour. Nothing was found beyond what is listed above.

`CrossRateCustomPriceFeed`, `ETHx`, `ETHx_CrossRate`, `LDO`, `NXM`, `OETH`, `RWIV`, `cbETH`, `cbETH_L2`, `ezETH_L2`, `lsETH`, `osETH_CrossRate`, `osToken`, `rETH`, `rsETH`, `rsETH_L2`, `sGHO`, `sUSDS`, `sUSDe`, `sXDAI`, `syrupUSDC`, `syrupUSDC_L2`, `weETH_L2`, `wstETH_L2`.

(`stETH`, `ezETH` and `ezETH_CrossRate` were also read in full; their findings are #1, #7 and #2.)

Specific verifications, so the next reader knows the sweep was complete rather than sampled:

- **Rate orientation against `BaseCustomPriceFeed.sol:78`** (`price = rate · base8 / 1e18`). Every `_rate()` returns *base-token units per 1 UNDERLYING* in 18 decimals, the orientation the multiply expects: `ETHx.getExchangeRate()` (ETH per ETHx — corroborated by the config's own on-chain check, 1.093906e18 against a Chainlink ETHx/ETH of 1.093319e18), `cbETH.exchangeRate()`, `rETH.getExchangeRate()`, `RsETHRateProvider.getLatestRate()`, `OsTokenVaultController.convertToAssets(1e18)`, `xRenzoDeposit.getRate()`, `RAMM.getInternalPrice()` (ETH per NXM), `weETH.getRate()` (eETH per weETH), `wstETH.stEthPerToken()`, and `eETH`'s constant `1e18`. No feed has an inverted or mis-scaled rate.
- **`ankrETH`'s inversion ordering.** `ankrETH_CustomPriceFeed.sol:78` is `base8.mulDiv(1e18, ratio, Floor)` — the division is kept **last**. The contract is deliberately *not* a `BaseCustomPriceFeed` subclass, and `:21-27` documents why: `ratio()` is ankrETH-per-ETH, so it must enter as a denominator; expressing it as a pre-inverted `_rate() = 1e36 / ratio` would floor twice and shift the result. The zero-guard at `:76` is present. Magnitudes checked for overflow: `base8 ≈ 3e11`, `× 1e18 = 3e29`, well inside `mulDiv`'s 512-bit intermediate.
- **`ERC4626VaultRatePriceFeed` divides by `_assetUnit`, not `_shareUnit`** (`:97-98`). `convertToAssets(10**shareDecimals)` returns assets in the **underlying's** decimals, so the divisor must be `10**assetDecimals`. Verified correct for both the no-offset case (`sUSDe`, `sUSDS`, `sXDAI`, `sGHO` — 18-dec shares over 18-dec underlying) and the offset case (`syrupUSDC`, `RWIV` — over 6-dec USDC). The asset decimals cancel to leave `NAV_DECIMALS`.
- **`ERC4626VaultRatePriceFeed` enforces `baseAsset == IERC4626(vault).asset()`** in the constructor (`:70-71`, reverting `BaseAssetMismatch`). This makes the entire 6-instance 4626 family self-protecting against the misconfiguration described in call-out A — a wrong base fails the *deploy*, not a *read*.
- **`_rateUnit` absorbs non-8-decimal rate feeds.** `TwoFeedChainlinkPriceFeed.sol:72` captures `10 ** rateFeed.decimals()` once in the constructor, and `:107` divides by it, so the rate feed's decimals cancel into `NAV_DECIMALS` regardless of value. Verified this correctly handles the **18-decimal Chainlink ETHx/ETH** feed adopted on 2026-07-27 (no config change was needed, and none was made) and the **18-decimal weETH/eETH** exchange-rate feeds on Arbitrum and Base. The one residual risk — a proxy whose backing aggregator changes decimals after construction — is not reachable in practice (Chainlink and RedStone ship a new proxy instead), and a pathological `decimals()` would overflow `10 ** decimals` and revert the constructor, i.e. fail at deploy.
- **`_governingLeg`'s overflow handling** (`TwoFeedChainlinkPriceFeed.sol:164-181`). The ratio comparison cross-multiplies `ageA · hB` vs `ageB · hA` to avoid division, which can exceed `uint256` when a leg carries the documented `type(uint256).max` "disable the staleness gate" sentinel heartbeat. `Math.tryMul` detects it and the fallback is correct in both directions: `!okA` means `hB` is astronomically large, so leg B's ratio is ≈ 0 and leg A governs, and symmetrically for `!okB`. Zero heartbeats are short-circuited at `:169-170`. A direct caller of `governingFeedFreshness()` cannot be made to revert.
- **The `int256` cast is bounded at `PriceFeedLib.sol:112`** (`if (customPrice > uint256(type(int256).max)) continue;`), with the same guard in the monitor path at `:385`. So the `answer = stale ? int256(0) : int256(price)` cast in every leaf's `latestRoundData()` cannot be reached with a value that would wrap negative — a pathological feed is skipped before the cast rather than silently sign-flipped.
- **Revert paths degrade to stale, in every case.** A reverting rate source propagates out of `_rate()`/`_compute()` and is caught by `_selectFeedCore`'s outer `try` (`:105-110`), which `continue`s — the asset goes stale, never wrong. Checked the one place this could have gone differently: `ezETH_CustomPriceFeed.sol:34-40` wraps `calculateTVLs()` in `try`, but `IERC20(UNDERLYING).totalSupply()` sits inside the *success* block where the local `catch` does not reach it. Traced it anyway: a `totalSupply()` revert propagates to the outer `try` and produces stale, not a wrong number. The zero-supply guard at `:36` is present.
- **`mulDiv` magnitudes.** `TwoFeedChainlinkPriceFeed.sol:107` (`rate ≈ 1e18 × base8 ≈ 4e11 = 4e29`), `ERC4626VaultRatePriceFeed.sol:98`, `BaseCustomPriceFeed.sol:78` and `sDAI_CustomPriceFeed.sol:93` (`chi ≈ 1.1e27`) all sit far inside the 512-bit intermediate. No realistic overflow.
- **Monitor-feed decimals.** `addMonitorFeed` (`PriceFeedLib.sol:1580-1582`) requires monitors to report exactly `NAV_DECIMALS`, which is self-checking against the common error of wiring an 18-decimal ETH-denominated feed as a USD monitor — registration reverts `MonitorFeedDecimalsMismatch`. Spot-checked Base `cbETH`, whose monitor `0xd781827…` is the 8-dec cbETH/USD feed while the constructor's rate leg `0x806b4Ac0…` is the 18-dec cbETH/ETH feed; the two are correctly assigned.
- **L2 sequencer symmetry.** `NavBaseUsdLib.sol:44` computes `baseStale = pd.stale && !pd.sequencerDown`, un-folding the sequencer signal so custom-priced positions are not zeroed while direct-priced ones stay live. Verified this matches the pricing path: `_buildPriceFeedCache` (`PriceFeedLib.sol:1256-1268`) does **not** fold `sequencerDown` into the pricing `stale`, and `_enrichPosition` (`:1380-1410`) values positions off `priceFeed.price` regardless. Also traced the dangerous sub-case — a long outage where the base feed is *also* genuinely past its heartbeat, so `pd.stale && pd.sequencerDown` are both true and the un-folding yields `baseStale = false`. The `pd.price <= 0` check at `NavBaseUsdLib.sol:45` catches it, because `_selectFeedCore` returns `price = 0` when all feeds fail the gate. Correct as written.
- **`rateOnly` tiering is not perturbed by ADR 0019.** `_selectFeedCore:123` classifies a Custom feed as rate-only when `latestRoundData().updatedAt == 0`. Post-0019 that value is the base feed's `updatedAt`, which is non-zero for every configured base (all direct Chainlink). So no NAV-sourced feed is misclassified into the lower tier, and the `block.timestamp - 1` sentinel is never applied to one.
- **Peg tolerance does not clamp.** Confirmed `_monitorDivergence:335-341` only *flags* `irregular` on peg deviation and never alters the returned price. So there is no clamped-vs-unclamped asymmetry between a stablecoin base priced directly and the same base read through `NavBaseUsdLib` — ADR 0019's cancellation claim holds for the stablecoin-based feeds (`sUSDe`, `sUSDS`, `syrupUSDC`, `RWIV`, `sGHO`, `sXDAI`) as well as the ETH-based ones.
- **Custom-feed heartbeat pairings.** Every registered Custom heartbeat was checked against its base asset's registered heartbeat, since post-0019 the derived feed's freshness timestamp *is* the base's. All consistent except `sUSDS` (finding #8). The looser-than-base pairings (`wstETH`, `stETH`, `lsETH`, `weETH`, `eETH`, `OETH`, `LDO` at 86400 against WETH's 3600) are harmless: the base's own staleness verdict is inherited through `NavBaseUsdLib` regardless of the derived feed's gate, so a looser derived heartbeat cannot over-report.

## Known-stale, low priority

34 test files (39 sites under `test/prices/`) hardcode `NAV = 0x42aC265991163Af2b0B9E59a222d31d201E39f91` — a NAV proxy two generations behind the current `0x80eD5cc6…` in `deployments/*.json`. They still pass because `_useNewNavImpl` hot-swaps the implementation and the old proxy still has WETH registered at the pinned fork blocks, so the arithmetic is exercised correctly. But they read an asset/feed set that is no longer production, and after the redeploy that drift widens. Test maintenance, not NAV correctness.

---

# Reachability split — live today vs latent

Added after the initial sweep. The axis: reachable with the **currently deployed 39 instances and today's configuration**, versus requiring a config change, a new instance, or a deploy error.

## Bucket A — live today. No human action required to reach.

| # | Finding | Manifests as | Trigger needed |
|---|---|---|---|
| 1 | stETH MARKET vs wstETH/eETH FUNDAMENTAL | **Wrong number, continuously** | None — wrong right now, magnitude = today's stETH/ETH deviation from 1.0 |
| 3 | 16 of 31 primaries with no divergence/peg check | **Detector permanently absent** | None — absent right now |
| 2 | ezETH's sole monitor is itself fundamental | Detector present but structurally unable to fire | An ezETH depeg |
| 8 | `sUSDS` gated at 82800 vs USDS's 86400 | sUSDS drops to $0, flagged stale | USDS/USD feed age in [82800, 86400) — **see re-rank below** |
| 7 | `_compute()` twice per selection; ezETH `calculateTVLs` ×2 | Gas cost paid on every read now; OOG → ezETH stale at $0 | Gas pressure for the failure; the cost itself is unconditional |

## Bucket B — latent. Needs a config change, a new instance, or a deploy error.

| # | Finding | Status today |
|---|---|---|
| 4 | No `underlyingAssetSupported()` cross-check at registration | **Verified clean.** All 39 feed→asset mappings cross-checked against `nav-config` + `contracts-deployment-config` + `deployments`: 0 mismatches, no deployed-but-unreferenced instances, no referenced-but-undeployed. Armed by the redeploy's 39 re-registrations, not by anything live. |
| 5 | Rate-feed *pair identity* asserted nowhere | Guard absent — confirmed. **Current correctness of the 16 rate-feed addresses is not verifiable from the repo.** The only evidence they are the right pairs is prose in JSON `$comment` fields. This is the one finding whose today-status I cannot determine without on-chain `description()` reads. |

## Bucket C — not runtime. Modulates confidence in the others.

| # | Finding | Note |
|---|---|---|
| 6 | Four configured contracts with zero tests | `lsETH`, `ezETH_CrossRate`, `ETHx_CrossRate`, `osETH_CrossRate`. Coverage gap, not a defect — it is precisely why #5's status is unverifiable for those four. |
| 9 | Doc drift | `PRICE_ADAPTERS.md:269` is live in the sense that it actively misleads anyone doing this triage. |

---

## What an operator observes today — #1

Three checks, all runnable now, no market event needed.

**1. The size of the inconsistency, right now, in one read.** Read the Chainlink stETH/ETH feed (`0x86392dC19c0b719886221c78AB11eb8Cf5c52812`). Its deviation from `1e18` **is** the inconsistency, exactly. wstETH is priced with that ratio held at 1.0; stETH is priced with it as published. If the feed reads `0.9993e18`, then stETH and wstETH are 7 bps apart on identical underlying claims.

It will not read exactly `1e18`. It is a deviation-triggered feed (published on threshold breach plus a 24h heartbeat — our config carries `yToXHeartbeat: 86400`), so between publications the reported ratio sits off spot by up to its deviation threshold. Confirm the exact threshold on data.chain.link before sizing it; the mechanism holds regardless.

**2. The arithmetic identity that should hold and does not.** If the two conventions agreed:

```
getPriceData(wstETH).price  ==  getPriceData(stETH).price × wstETH.stEthPerToken() / 1e18
```

What is actually returned is that quantity divided by the market stETH/ETH ratio. The ratio of the two sides is exactly `1 / stETH_per_ETH_market` — a direct, non-statistical read of the defect.

**3. The tell that survives into a stress event.** wstETH's primary is fundamental and both its monitors (Redstone + Chainlink wstETH/USD) are market, so during a stETH discount wstETH's `divergenceBps` climbs and it appears in `nav.irregularPriceAssets` at 250 bps. stETH's primary *and* its monitor (Chainlink stETH/USD) are both market, so they agree and it flags nothing.

**During a depeg the irregular list will contain wstETH and weETH but not stETH** — while stETH is the asset actually tracking the depeg. That asymmetry is the observable signature of the two conventions coexisting, and an operator seeing it would reasonably conclude wstETH was the broken one. It is the opposite of the truth: wstETH is behaving as designed and stETH is the outlier.

## What an operator observes today — #3

For the 16 affected primaries the divergence machinery does not return a *measurement*. It returns a **constant**.

`_hasDivergenceChecks` (`PriceFeedLib.sol:360-366`) is `monitorFeeds[asset].length > 0 || pegToleranceBps > 0`. For these 16 both are zero, so `_divergenceFor` is never entered and `irregular` is hardcoded false at `buildPriceData:532` and `_buildPriceFeedCache:1262`.

Observable now, per asset:

```
getMonitorFeedCount(asset)            -> 0
getAssetPricing(asset).divergenceToleranceBps -> 0
getPriceDivergence(asset)             -> (price, 0, 0, false, 0, …)   monitorMedian=0, divergenceBps=0, irregular=false
```

Those last three values are structurally invariant. **These 16 assets cannot appear in `nav.irregularPriceAssets` under any chain state whatsoever** — not a depeg, not a bad rate provider, not a compromised reporter. A dashboard showing "0 bps divergence, no anomalies" for `rsETH`, `ankrETH`, `NXM`, `lsETH`, `OETH`, `sUSDS`, `syrupUSDC`, `RWIV`, `sGHO`, `LDO`, `eETH`, `wNXM` and all three Gnosis assets is not reporting health — it is reporting that nothing is being checked. The two states are indistinguishable from the outside.

Affected: mainnet `lsETH`, `eETH`, `rsETH`, `sUSDS`, `syrupUSDC`, `RWIV`, `sGHO`, `OETH`, `LDO`, `ankrETH`, `NXM`, `wNXM`; Gnosis `osGNO`, `sDAI`, `wstETH`; Arbitrum `syrupUSDC`.

---

## Re-rank: #8 is more reachable than filed

The finding and its direction were right; my reachability estimate was too conservative.

sUSDS goes stale whenever `block.timestamp − USDS_updatedAt >= 82800` — the final 3,600 seconds before USDS/USD's own 86,400 s gate. That window is not an edge case for a **heartbeat-riding** feed. A stablecoin/USD feed that rarely breaches its deviation threshold publishes on the heartbeat and therefore spends its life *approaching* 86,400 s of age. If USDS/USD behaves that way, sUSDS is unpriced for roughly `3600/86400 ≈ 4.2%` of all blocks — about **one hour in every twenty-four, every day**, not a rare stall.

If USDS/USD is deviation-active it essentially never happens. Which regime applies is checkable immediately: sample `latestRoundData().updatedAt` on `0xfF30586cD0F29eD462364C7e81375FC0C71219b1` a few times and see whether the age regularly approaches 86,400.

Given it is a one-character config change (82800 → 86400, matching every other base/derived pairing in the system), this should be treated as a candidate for the pre-freeze config batch regardless of which regime turns out to apply.

---

## What this implies for the freeze

Only three findings could require a `src/` change, and therefore gate the pin regeneration:

- **#4** — the `underlyingAssetSupported()` guard lands in `PriceFeedLib._validateFeedSupportInternal`, which is unambiguously inside PriceFeedLib's own compilation closure. This one moves that pin.
- **#7** — hoisting the double `_compute()` touches the shared bases (`BaseCustomPriceFeed` etc.), which PriceFeedLib does not import. Likely pin-neutral, but that is the pin session's call against the closure table, not mine.
- **#1** — if fixed in source (a unit-rate `stETH_CustomPriceFeed`), it touches only a leaf, which nothing in either library's closure imports. Also likely pin-neutral.

Worth noting on #1: it can be fixed **without any source change at all**. `eETH_CustomPriceFeed`'s constructor is `(token, nav, baseAsset)` and its `UNDERLYING` is whatever is passed — so deploying that existing contract against stETH, and demoting the CrossRate instance to a monitor, produces exactly the intended convention using already-reviewed bytecode. Uglier by name, but it keeps the tree still.

Everything else — **#2, #3, #8** (config), **#5, #6** (tests and tooling), **#9** (docs) — touches no `src/` file and can land in any order relative to the pin regen.

So the pre-freeze source decision reduces to a single question: **does the `underlyingAssetSupported()` guard go in before the pins are computed, or not at all this cycle?** It is the only finding here that both requires a source change and is armed by the redeploy itself.

---

# Cycle scope: what was implemented, specified, and deferred

## #4 — IMPLEMENTED (source change)

`src/prices/IPrices.sol` — new error:

```solidity
error CustomFeedAssetMismatch(address asset, address feed, address feedAsset);
```

`src/prices/PriceFeedLib.sol` — `_validateFeedSupportInternal`, inside the `PriceType.Custom` branch, after the
`supportsInterface` check:

```solidity
address feedAsset = ICustomPriceFeed(priceFeed).underlyingAssetSupported();
if (feedAsset != token) revert IPrices.CustomFeedAssetMismatch(token, priceFeed, feedAsset);
```

Covers all three registration entry points at once, since they share the validator: `registerAsset`, `addOrModifyPriceFeed`,
`addMonitorFeed` — plus the read-only `checkPriceOracleSupport`, so tooling can pre-flight without a transaction.

**Deliberately a direct high-level call, not `try`/`catch`.** A feed that claims `ICustomPriceFeed` via
`supportsInterface` but cannot answer `underlyingAssetSupported()` is broken, and failing the registration is the safe
direction — the only outcome that must be prevented is a registration *succeeding* with a mismatch. This also matches
the AggregatorV3 branch immediately below, which likewise lets a malformed feed revert rather than swallowing it. It
avoids relying on `try`/`catch` for robustness, which this repo has already established does not catch return-data
decode failures.

**Pin impact:** moves the `PriceFeedLib` CREATE2 pin. Expected and already accounted for — PR #185 regenerates both
library pins against the final tree, and `PriceFeedLib`'s pinned value was already stale after #187 edited that file.

**Test-mock fallout (4 mocks, 5 call sites).** Three mocks hardcoded `address(0)` or a dummy as their underlying and
were being registered for real assets — exactly the pattern the guard now rejects:

- `test/nav/NAVCalculator.errors.t.sol` — `Mock_RevertingPriceOracle` and `Mock_MalformedPriceOracle` took no
  constructor arg and returned `address(0)`. Both now take the asset; the three call sites construct the token first.
- `test/prices/Prices.t.sol` — `Mock_CustomPriceFeedZeroUpdatedAt` hardcoded `address(0x1234)` while being registered
  for `buidl`. Now takes the asset.

This is a strictly better mock in each case: a real feed that misbehaves at *read* time still reports its own
underlying correctly, which is what these tests actually model. `Mock_CustomPriceFeed` already took the underlying as a
constructor arg, so every other call site (including all of `DivergenceMonitor.t.sol`) already complied.

**Tests added.** Five in `test/prices/Prices.t.sol` (primary + view-validator path: wrong asset, zero underlying, a
positive control that a matching feed still registers, and a control that Chainlink feeds remain non-asset-bound) and
one in `test/prices/DivergenceMonitor.t.sol` (monitor path — the likelier crossing in practice, since every
`*CrossRate` instance is a monitor and their config keys sit adjacent to the primaries').

## #1 — IMPLEMENTED in this PR (via Route A below). My original "config-only" claim was wrong.

**Shipped as commits `b50218e2` (config) + `bbd2b490` (the `03` change Route A requires).** The text below is the original specification, kept because it records why Route A was chosen and what it costs; read it as the rationale for what landed, not as pending work.

I said this was config-only with no tree movement. That was too strong: **it needs a small `03_DeployPriceFeeds.s.sol`
change either way**, because there is no existing deploy path that produces a unit-rate feed for a second asset. Since
`03` is deploy-session territory, the route is their call. Both routes are pin-neutral (`script/` is not in either
library's compilation closure).

### Route A — reuse `eETH_CustomPriceFeed` (recommended)

`eETH_CustomPriceFeed` is already exactly the contract wanted: `_rate()` returns `1e18`, so its price is
`1.0 × base/USD`. Its constructor is `(token, nav, baseAsset)` and `UNDERLYING` is whatever is passed.

Script change — parameterise `_deployEEth` by config key, following the **existing precedent** of `_deployNxm(string)`
and `_deployOsToken(string)`, which already deploy one contract as two named instances:

```solidity
-   function _deployEEth() internal {
-       address deployed = _readAdapterDeployed("priceFeeds", "eETH");
+   function _deployEEth(string memory name) internal {
+       address deployed = _readAdapterDeployed("priceFeeds", name);
        ...
-       // (replace every literal "eETH" config lookup with `name`)
+       // (config lookups keyed on `name`; the token param key stays "eEth")
```

then call it twice: `_deployEEth("eETH")` and `_deployEEth("stETHFundamental")`.

Cost: the mainnet stETH primary shows on Etherscan as `eETH_CustomPriceFeed`. Ugly by name, clean by bytecode —
already reviewed, already fork-tested, no new contract enters the audit surface.

### Route B — rewrite `stETH_CustomPriceFeed` as a unit-rate `BaseCustomPriceFeed`

~10 lines, one leaf file, honest contract name. Still needs the `03` edit, because the constructor arity drops from 5
args to 3 and `_deployStEth()` passes 5. Do **not** keep the rate-feed parameter as a no-op to avoid the script edit —
a dead constructor parameter is precisely the anti-pattern flagged in the leftover sweep above.

### Config diff — identical under both routes

**`script/config/contracts-deployment-config/custom-price-feeds/1.json`**

Rename the existing `"stETH"` key to `"stETHCrossRate"`, leaving its constructor block **byte-for-byte unchanged**. Its
key shape is already `{underlyingAsset, yToXFeed, yToXHeartbeat, baseAsset}` — exactly what the existing generic
`_deployCrossRateMonitor(string)` reads (it already serves `rETHCrossRate`). So the monitor needs **no new script
logic at all**; just add `_deployCrossRateMonitor("stETHCrossRate")` alongside the existing
`_deployCrossRateMonitor("rETHCrossRate")` call. A side effect worth noting: the named `stETH_CustomPriceFeed` contract
then becomes unused and joins the dead-contract list, which is tidier than it sounds.

Then add the new primary's entry:

```json
  "stETHFundamental": {
    "enabled": true,
    "$comment": "stETH primary, pure fundamental: stETH/ETH is held at 1.0 (Lido's redemption invariant), matching how wstETH (stEthPerToken x ETH/USD) and eETH (1.0 x ETH/USD) are priced. Replaces the market stETH/ETH CrossRate primary, which is demoted to a monitor as stETHCrossRate. Deployed from eETH_CustomPriceFeed (unit-rate BaseCustomPriceFeed) - contract name reads eETH, priced asset is stETH.",
    "constructor": {
      "eEth": "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
      "baseAsset": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    }
  }
```

(Under route B the token key is `"underlyingAsset"` instead of `"eEth"`, matching `_deployStEth`'s existing lookup.)

**`script/config/nav-config/assets-and-price-feeds/1.json`** — the `stETH` entry:

```diff
   "stETH": {
     "address": "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
     "divergenceToleranceBps": 250,
     "priceFeeds": [
-      { "type": "Custom", "feed": "stETH",  "heartbeat": 86400 }
+      { "type": "Custom", "feed": "stETHFundamental", "heartbeat": 86400 }
     ],
     "monitorFeeds": [
+      { "type": "Custom", "feed": "stETHCrossRate", "heartbeat": 86400 },
       { "type": "Chainlink", "address": "0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8", "heartbeat": 86400 }
     ]
   }
```

**Notes on the specific values.**

- **Primary heartbeat stays 86400**, matching `wstETH`, `weETH` and `eETH` — the three pure-fundamental feeds stETH is
  being aligned with. It is looser than WETH's registered 3600, which is safe: `NavBaseUsdLib` inherits the base's own
  staleness verdict regardless, so a looser derived heartbeat cannot over-report (established in the clean list above).
  Do not "tighten" it to 3600 for symmetry with the base; that would only add a needless blackout window, the #8 defect.
- **The market cross-rate becomes the second monitor, not a replacement for the Chainlink stETH/USD monitor.** Keeping
  both gives stETH two independent market views against a fundamental primary — the same shape wstETH has, and it makes
  `divergenceBps` meaningful for stETH for the first time.
- **`divergenceToleranceBps` stays 250**, matching wstETH/weETH.
- **No other chain is affected.** stETH is registered on mainnet only; Arbitrum, Base and Gnosis carry no stETH entry.
- **Net instance count is unchanged at 39**: one primary replaced, one former primary re-roled as a monitor. It does not
  become 40, because `stETH` and `stETHCrossRate` are the same deployed instance under a new key — unless route B is
  taken, in which case the new fundamental feed is a genuinely new deploy and mainnet goes 24 → 25, total 39 → 40.
  **Route A also goes to 40** (the new unit-rate instance is a separate deploy from `eETH`'s). Either way: **40, not
  39**, once #1 lands. Flagging explicitly so the count does not silently drift again.

## #7 — judgement: gas cost, not a correctness risk. Do not touch the shared bases this cycle.

**Is the doubling a correctness risk on the NAV path? No.**

Both calls (`getLatestPrice()` then `latestRoundData()`) execute in the same transaction against identical state, and
every `_rate()` source is `view` and block-deterministic. There is no skew between the price taken from the first call
and the timestamp taken from the second.

The one edge worth tracing is the second call failing where the first succeeded — gas exhaustion between them.
`latestRoundData()` is wrapped in a `try` with an **empty catch** (`PriceFeedLib.sol:115-119`), so on failure
`lrdUpdatedAt` stays 0, `rateOnly` becomes true, and `updatedAt` gets the `block.timestamp - 1` sentinel — which
**clears the outer heartbeat gate unconditionally**. That sounds bad, and it is worth writing down, but it is benign
here:

- The *price* is still the correct current price, taken from the successful first call.
- Base-feed staleness is already gated **inside** the feed: `NavBaseUsdLib` marks stale and `getLatestPrice()` returns
  `stale = true`, which is skipped at `_selectFeedCore:111` before the timestamp is ever consulted. The
  `latestRoundData` timestamp only drives the outer gate and the freshest-wins ranking.
- Losing the ranking tier changes nothing under the intended production configuration of **exactly one primary feed per
  asset** (documented at `Prices.sol:31-34`), which is what all 39 instances use.

So it degrades to "correct price, redundant gate bypassed" — and it is pre-existing, not caused by ADR 0019.

**Is it worth touching the shared bases this cycle? No.** Four reasons:

1. **Blast radius.** The bases feed all 39 instances. Changing them in the same cycle as a full redeploy means every
   instance on all four chains gets new bytecode from a freshly-edited shared base, with no incremental rollout.
2. **The failure it prevents is the safe direction.** The consequential gas failure is the *first* call OOGing —
   ezETH's `calculateTVLs` — which yields `catch` → `continue` → asset stale at $0, under-reported and surfaced in
   `nav.stalePriceAssets`. That is the class this wave has consistently accepted.
3. **There is no cheap correct fix.** Caching inside one `_compute()` does not help: the doubling is across two
   separate external calls from the consumer, not within one. Feeds are immutable and stateless by design, so no
   storage cache is available. The real fix is restructuring `ICustomPriceFeed` so the read path makes one call instead
   of two — which touches `_selectFeedCore`, `_readFeedPrice`, all 33 feed contracts and every price test, moves the
   `PriceFeedLib` pin, and is far outside a bounded fix.
4. **It should be measured first, and the targeted fix is a leaf.** If ezETH alone is a multi-million-gas line item,
   fix `ezETH_CustomPriceFeed` — a leaf, pin-neutral, one instance — rather than the bases: bound the `calculateTVLs`
   read, or move the mainnet ezETH primary off a rate source that is O(operator delegators).

**Recommended pre-freeze action:** measurement only. Compare `getAccountNav` gas with and without ezETH in the asset
set, and `getPriceData(ezETH)` against `getPriceData(rETH)` as a cheap control. That is a test-only addition, so it is
pin-neutral and can land at any point. Decide on the leaf fix from the number, not from the shape.
