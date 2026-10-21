# 0019 — Custom price feeds source their base/USD from the NAV (one price source per base asset)

**Status:** accepted
**Amended by:** [0029](0029-staleness-flags-never-changes-value.md): a stale base no longer leaves the derived asset unpriced; the feed computes its price from the stale base and reports `stale = true`.

## Context

Custom price feeds price a derived asset as `rate × base/USD`, where the `base/USD` term is **ETH/USD** for the LSTs (wstETH, weETH, rETH, rsETH, cbETH, ezETH, osETH, ETHx, stETH, …) and a stablecoin/USD (USDC, USDe, GHO, USDS, DAI) for the ERC4626 vaults (sUSDe, sGHO, sUSDS, syrupUSDC, …). Historically every feed embedded that `base/USD` oracle as a **hardcoded Chainlink aggregator** (a constructor arg), read directly via `latestRoundData()`.

Meanwhile the NAV prices the base asset itself (e.g. WETH) through the **multi-feed selector** ([ADR 0009](0009-multi-feed-price-redundancy.md)): freshest-wins across all registered feeds (e.g. Chainlink **+** API3 for WETH). This creates a mixed-feed inconsistency: whenever API3 posts a WETH round more recently than Chainlink (~30 min after each API3 push), the NAV prices WETH position legs off **API3** while the LST collateral still embeds **Chainlink** ETH/USD. The two `ETH/USD` terms then fail to cancel in ETH-quoted NAV.

Observed on mainnet (2026-07-02, block 25444450): a 45.8 bps API3-vs-Chainlink spread produced a **−2.95% NAV crater** for an eth-alpha fund at ~7× leverage, with **zero position change**, for ~30 minutes — purely the feed flip. Error scales as `≈ −spread × grossLeverage`; at the 1% max divergence it reaches ±7%. A secondary case: if a Redstone/other fallback wins the WETH selection, there is *no* ETH/USD term to cancel at all. Reference analysis: https://hackmd.io/@ism/B1rLNvEXMe.

## Decision

**Every custom feed reads its `base/USD` term from the NAV's own selector** — `NAVCalculator.getPriceData(baseAsset)` — instead of a hardcoded Chainlink oracle. Because `getPriceData` and `computeNav` go through the **identical** `_selectFeedCore` in the same block (verified: `PriceFeedLib.buildPriceData` and `_buildPriceFeedCache` both call `_selectFeedCore`), the `base/USD` value a derived asset uses is *exactly* the one the base asset's own position legs are priced with. Cancellation becomes **structural**: for base-quoted NAV the derived-asset multiplication and the base-leg division use the same value, whichever feed won.

Concretely:

- A shared library **`src/prices/NavBaseUsdLib.sol`** exposes `baseUsd(nav, baseAsset) → (price8, stale, updatedAt)`: `try getPriceData(baseAsset)`, normalize the selected price to `NAV_DECIMALS` (8), and mark the base stale on **genuine feed staleness** (`baseStale = pd.stale && !pd.sequencerDown`) or a non-positive price — **not** on L2 sequencer-down alone (see the sequencer note under *Negative / watch*). Fail-to-stale on revert — never reverts the calling feed.
- The three shared bases (`BaseCustomPriceFeed`, `TwoFeedChainlinkPriceFeed`, `ERC4626VaultRatePriceFeed`) and the four bespoke feeds (`wstETH`, `eETH`, `ankrETH`, `sDAI`) drop the embedded `base/USD` oracle + its heartbeat and take `(nav, baseAsset)` instead. The protocol exchange rate and any `asset/base` Chainlink **rate** leg are unchanged. Returned decimals stay `NAV_DECIMALS` (8), preserving the registration decimals-consistency invariant with co-registered feeds. The `ERC4626VaultRatePriceFeed` additionally enforces `baseAsset == IERC4626(vault).asset()` in the constructor (reverts `BaseAssetMismatch`) — the base/USD is read for `baseAsset`, so it must be the vault's own underlying — and divides `convertToAssets` by `10**assetDecimals` (the underlying's decimals), not the share decimals.
- Scope: **all** base-embedding feeds (ETH-based with `baseAsset = WETH`, GNO for `osToken` on Gnosis; stable-based with `baseAsset =` the vault's stablecoin). `ETHPlus` (basket, no base oracle) is unaffected.

## Consequences

**Positive**
- One price source per base asset. The feed-flip NAV error is eliminated: LST collateral and WETH debt/quote legs always use the same ETH/USD value. The Redstone-fallback "no term to cancel" case is likewise gone.
- Base-leg staleness is inherited from the NAV's own selector for free (all-base-feeds-stale marks the derived asset stale, no per-feed heartbeat to maintain).
- Redundancy (ADR 0009) is **retained**, not dropped: the base still benefits from multi-feed freshest-wins; the derived assets simply follow it instead of pinning one feed.

**Negative / watch**
- **Circularity invariant (must hold):** `baseAsset` MUST be priced by *direct* feeds (Chainlink/API3/Redstone), never by a NAV-sourced custom feed — otherwise `getPriceData(baseAsset)` recurses. WETH/GNO/stablecoins all use direct feeds. This is documented in `NavBaseUsdLib` and enforced by convention (never register a NAV-sourced feed *for* a base asset), not on-chain. (Added later: the **one-hop** case *is* now enforced on-chain — every custom feed must expose `INavSourcedPriceFeed.BASE_ASSET`, and registration reverts `IPrices.CustomFeedBaseUnreadable` when the feed cannot answer or `IPrices.CustomFeedBaseCircular` when that base is the asset being registered — see `PriceFeedLib._validateFeedNotCircular`. Longer cycles are still not checked on-chain: they stay a config property, guarded by `script/deploy/preflight/preflight_config.py`.)
- **L2 sequencer (per-position symmetry):** `computeNav` prices every *direct* position at its last value and surfaces sequencer downtime only through the top-level `nav.sequencerDown` flag — it does **not** zero individual positions during an outage. So `NavBaseUsdLib` must un-fold the raw `pd.sequencerDown` (`baseStale = pd.stale && !pd.sequencerDown`) and zero only on genuine base-feed staleness; otherwise a Base/Arbitrum sequencer outage would crater custom-priced positions to $0 while direct-priced ones stayed live — an internally inconsistent, understated NAV. The `nav.sequencerDown` flag remains the single sequencer signal for consumers. Only Base/Arbitrum have a sequencer feed configured; mainnet/Gnosis (`address(0)`) are a no-op.
- Each derived-asset price now also re-runs the base asset's selector (an extra `staticcall` into the NAV per read). Gas cost is minor; NAV reads are off-chain `eth_call`.
- **Deployment dependency:** the base asset must already be a registered NAV asset with feeds on that chain when the derived feed is read (it is; else `baseUsd` returns stale → derived asset unpriced, the safe direction).
- Constructor signatures change → `03_DeployPriceFeeds` + `contracts-deployment-config/custom-price-feeds/*.json` change; the deployed feeds must be redeployed and swapped on each live NAV (a separate migration).

## Alternatives considered

- **Return the base-denominated rate; let PriceFeedLib do one ETH→USD conversion** (the HackMD "Option 1", strictly the most structural). Rejected for now: it changes the `ICustomPriceFeed` semantics (return a rate, not USD) and the pricing-engine composition. Reading `getPriceData(baseAsset)` achieves the same single-source cancellation with a localized, per-feed change and no engine/interface change.
- **Config-only: drop API3 from WETH / Redstone from wstETH** (HackMD "Option 2"). Immediate one-tx stopgap, but trades away ADR 0009 redundancy (Chainlink stall → ETH-quoted NAV goes stale). Usable as an interim mitigation before this ships; not the durable fix.
