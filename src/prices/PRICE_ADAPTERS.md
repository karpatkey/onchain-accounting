# Price Adapters: Architecture and Integration

This is the price-side counterpart to [`src/balances/BALANCE_ADAPTERS.md`](../balances/BALANCE_ADAPTERS.md). It describes the `Prices` abstract registry, the `ICustomPriceFeed` interface, the existing per-asset custom adapters, and how to add a new one.

---

## 1. Overview

The price system gives `NAVCalculator` a price for any asset, in some "USD-like" unit. Each asset can have **multiple registered feeds** for redundancy; on every read, `Prices` picks the **freshest non-stale feed** (freshest-wins selector). Stale is only returned when every feed has failed.

Four `PriceType` variants are supported:

| `PriceType` | Read path | Notes |
|---|---|---|
| `Chainlink` | `AggregatorV3Interface.latestRoundData()` | On-chain push feed. |
| `Custom` | `ICustomPriceFeed.getLatestPrice()` for price + stale; `latestRoundData()` for freshness timestamp | Custom adapters encode per-feed heartbeat logic internally. |
| `Redstone` | `AggregatorV3Interface.latestRoundData()` | Redstone Classic Push; same read path as Chainlink. |
| `API3` | `AggregatorV3Interface.latestRoundData()` | `Api3ReaderProxyV1` implements `AggregatorV2V3Interface`; only `latestRoundData` is used. |

All are subject to the **L2 sequencer uptime** check when a sequencer feed is set on `Prices`.

**`Prices` is the registry; per-asset custom contracts are the building blocks.**

---

## 2. Price flow: from asset to price

On every `latestPrice(asset)` call, `Prices._selectFeed` iterates all registered feeds for the asset and selects the **freshest non-stale survivor**:

1. **Lookup** — `_priceOracles[asset]` is a `PriceFeedConfig[]` array. Reverts with `PriceFeedNotSet` if empty.
2. **Per-feed read** — non-Custom types call `AggregatorV3Interface.latestRoundData()`. Custom feeds call `ICustomPriceFeed.getLatestPrice()` for `(price, internalStale)` (skip if stale or price ≤ 0), then `latestRoundData()` for `updatedAt`. All calls are wrapped in try/catch; a reverting feed is skipped rather than propagating.
3. **Clock-skew normalisation** — `effectiveTime = min(updatedAt, block.timestamp)`. Any feed reporting a future timestamp is clamped to prevent it from systematically winning the freshness race.
4. **Staleness gate** — skip feed if `block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat`.
5. **Freshest-wins** — among survivors, select the one with the largest `effectiveTime`. Ties go to the feed at the lowest array index.
6. **All-stale fallback** — if no feed survives, return `(0, firstFeed.decimals, true)`.
7. **L2 sequencer** — top-level `latestPrice()` ORs in `checkL2SequencerUptime()`: stale if the sequencer is down or within the grace period.
8. **Return** — `(int256 price, uint8 decimals, bool stale)`.

Special case for Custom `updatedAt == 0`: treated as `block.timestamp - 1` (no trackable oracle — feed survives the staleness gate but yields to any feed with a real timestamp). See ADR 0009 for rationale.

### 2.1 `latestPrice(asset)` — top-level flow

```mermaid
flowchart TD
    A([latestPrice<br/>asset]) --> B{_priceOracles<br/>array empty?}
    B -- yes --> ERR1([revert<br/>PriceFeedNotSet])
    B -- no --> C[_selectFeed]
    C --> D{L2 sequencer<br/>uptime check}
    D -- sequencer down<br/>or in grace period --> SEQ[stale = true]
    SEQ --> RET
    D -- ok --> RET([return price, decimals, stale])
```

### 2.2 `_selectFeed` — per-feed iteration and freshest-wins selection

```mermaid
flowchart TD
    START([_selectFeed]) --> INIT[winnerIdx = none<br/>winnerTime = 0]
    INIT --> LOOP[for each feed i<br/>in _priceOracles]

    LOOP --> TRY{try read feed i}
    TRY -- revert --> SKIP[skip feed i]
    SKIP --> NEXT

    TRY -- ok --> CUSTOM{priceType<br/>== Custom?}

    CUSTOM -- yes --> CG[getLatestPrice<br/>→ price, internalStale]
    CG --> CK1{internalStale<br/>or price ≤ 0?}
    CK1 -- yes --> SKIP
    CK1 -- no --> CLR[latestRoundData<br/>→ updatedAt]
    CLR --> CLAMP

    CUSTOM -- no --> AV3[latestRoundData<br/>→ price, updatedAt]
    AV3 --> CLAMP

    CLAMP["effectiveTime =<br/>min(updatedAt, block.timestamp)"]
    CLAMP --> STALE_GATE{"block.timestamp −<br/>effectiveTime >= heartbeat?"}
    STALE_GATE -- yes --> SKIP
    STALE_GATE -- no --> FRESH{effectiveTime<br/>> winnerTime?}
    FRESH -- yes --> UPDATE[winnerIdx = i<br/>winnerTime = effectiveTime]
    UPDATE --> NEXT
    FRESH -- no --> NEXT[next feed]
    NEXT --> LOOP

    LOOP -- done --> WINNER{any winner?}
    WINNER -- no --> ALLSTALE([return price=0<br/>firstFeed.decimals<br/>stale=true])
    WINNER -- yes --> RETURN([return winner price<br/>winner decimals<br/>stale=false])
```

---

## 3. Data structures

### 3.1 PriceFeedConfig (registered config)

Defined in `IPrices`.

| Field | Type | Description |
|---|---|---|
| `priceFeed` | `address` | Chainlink aggregator, API3/Redstone feed address, or custom contract (`ICustomPriceFeed`). |
| `decimals` | `uint8` | Decimals of the returned price. Pinned at registration from the feed itself (for API3 feeds the 18-dec proxy is stored as `decimals = 8`; see §10.3). |
| `priceType` | `PriceType` | Enum `{ Chainlink, Redstone, API3, Custom }`. |
| `chainlinkHeartbeat` | `uint256` | Staleness window in seconds. Required non-zero for all feed types. For **Chainlink / Redstone / API3** feeds: `Prices.sol` checks `block.timestamp − effectiveUpdatedAt >= heartbeat`. For **Custom** feeds: `getLatestPrice().stale` is the primary gate; `latestRoundData().updatedAt` then applies the same heartbeat gate (`updatedAt == 0` is treated as `block.timestamp - 1` so rate-only feeds participate but yield to feeds with a real push timestamp). |

### 3.2 Custom feed return shape

`ICustomPriceFeed.getLatestPrice()` returns `(uint256 price, bool stale)`. `Prices.sol` uses the `stale` bool as the primary gate: if `internalStale = true` or `price == 0`, the feed is skipped entirely. Among surviving custom feeds, `latestRoundData().updatedAt` is also read for the heartbeat gate and freshness ranking in the freshest-wins selection (see §2). The convention of returning `(0, true)` on any failure still applies.

---

## 4. Prices contract (registry behavior)

`Prices` is an abstract contract used by NAVCalculator. It maintains:

- **Per-asset feed configs:** `mapping(address => PriceFeedConfig[]) internal _priceOracles`. Each asset has a dynamic array of feeds.
- **L2 sequencer state:** `chainlinkL2SequencerUptimeFeed` and `chainlinkL2SequencerGracePeriod` (default 1 hour, minimum 1 hour enforced on-chain). Set once via `__Prices_init` at NAV initialization; grace period adjustable by MANAGER via `setChainlinkL2SequencerGracePeriod` (floor: `>= 1 hours`).

Internal API (used by NAVCalculator):

- `_addPriceFeed(asset, priceFeed, heartbeat, priceType)` — checks support via `checkPriceOracleSupport`, reads decimals from the feed, appends `PriceFeedConfig` to the array. Rejects duplicates (`PriceFeedAlreadyRegistered`). Heartbeat must be non-zero.
- `_removePriceFeedAt(asset, index)` — swap-with-last + pop. Reverts with `CannotRemoveLastFeed` when only one feed remains.
- `_removePriceFeed(asset, priceFeed)` — locates feed by address, calls `_removePriceFeedAt`. Reverts with `PriceFeedNotFound` if not registered.
- `_removeAllPriceFeeds(asset)` — `delete _priceOracles[asset]`, used by `unregisterAsset` only.
- `_priceFeedCount(asset)` — returns array length.
- `checkPriceOracleSupport(asset, priceFeed, priceType)` — public; ERC165 check for Custom; for Chainlink/Redstone/API3: rejects `ICustomPriceFeed`-shaped feeds and calls `latestRoundData()` as a sanity check.

External view API:

- `getPriceFeedCount(asset)` — number of registered feeds.
- `getPriceFeedAt(asset, index)` — `PriceFeedConfig` at that index (reverts with `PriceFeedIndexOutOfBounds`).
- `getPriceFeeds(asset)` — full array.

`NAVCalculator` exposes `registerAsset(asset, oracle, priceType, heartbeat)` (MANAGER) which combines `_addPriceFeed` with adding the asset to the Balances asset registry. Additional feeds are registered via `addPriceFeed(asset, oracle, priceType, heartbeat)`.

---

## 5. ICustomPriceFeed

Every custom feed must implement this interface (and ERC165).

| Method | Purpose |
|---|---|
| `getLatestPrice()` | Returns `(uint256 price, bool stale)`. Price is in `decimals()` precision. Return `(0, true)` on any failure or uncertainty. |
| `latestRoundData()` | Returns `(roundId, answer, startedAt, updatedAt, answeredInRound)` — same shape as Chainlink's `AggregatorV3Interface`. **`Prices.sol` calls this** to obtain `updatedAt` for the heartbeat gate and freshness ranking among surviving Custom feeds. See §5.1 for what to return. |
| `decimals()` | Returns the number of decimals the price is expressed in. Pinned at construction. |
| `underlyingAssetSupported()` | Returns the asset address this feed prices. Single asset per feed (1:1 contract-to-asset). |
| `supportsInterface(bytes4)` | Must return `true` for `type(ICustomPriceFeed).interfaceId` and `IERC165`. |

### 5.0 `BaseCustomPriceFeed` — the "rate × NAV-base/USD" skeleton

Most liquid-staking feeds follow the same shape: read the base asset's USD price from the **NAV's own selector** (`NAVCalculator.getPriceData(baseAsset)` — typically ETH/USD via WETH), apply the staleness gate, multiply by an 18-decimal on-chain exchange rate, and return the result in `NAV_DECIMALS` (8). That boilerplate — the five `ICustomPriceFeed` thunks, the immutables, the constructor validation, and the read/staleness/normalize math — lives once in [`src/prices/BaseCustomPriceFeed.sol`](BaseCustomPriceFeed.sol) (introduced by [ADR 0011](../../docs/decisions/0011-nav-size-and-shared-abstractions.md)); the base/USD read goes through [`src/prices/NavBaseUsdLib.sol`](NavBaseUsdLib.sol).

**Base/USD comes from the NAV, not an embedded Chainlink oracle** ([ADR 0019](../../docs/decisions/0019-nav-sourced-base-price.md)). Sourcing the base term from the same selector the NAV prices the base asset's own position legs with makes it **cancel cleanly** when NAV is quoted in the base — fixing the mixed-feed error where an LST used Chainlink ETH/USD while WETH used API3. **Circularity invariant:** `baseAsset` must be priced by *direct* feeds (Chainlink/API3/Redstone), never by a NAV-sourced custom feed.

A concrete feed extends `BaseCustomPriceFeed`, passes `(underlying, nav, baseAsset)` to the constructor, and implements **only** `_rate()` — the protocol's exchange rate as 18-decimal base-token units per 1 underlying (e.g. ETH per rETH). The base computes `price = rate · base8 / 1e18` (`Math.Rounding.Floor`, `base8` = the NAV-selected base/USD normalized to 8 dp) and marks the price stale when the NAV reports the base **feed** stale (all-base-feeds-stale) or `_rate()` returns 0. L2 **sequencer-down alone does not** mark it stale: `NavBaseUsdLib` un-folds `pd.sequencerDown` so custom-priced positions keep their last price during an outage — matching how `computeNav` values direct positions (the top-level `nav.sequencerDown` flag is the sequencer signal). See [ADR 0019](../../docs/decisions/0019-nav-sourced-base-price.md).

Eight feeds extend this base and collapse to ~10–25 LOC each — each supplies only an 18-decimal on-chain `_rate()`: `rETH_Price`, `cbETH_Price`, `ETHx_Price`, `rsETH_Price`, `ezETH_Price`, `ezETH_L2_Price`, `osToken_Price`, and `NXM_Price`. Two sibling skeletons cover the other common shapes: **`TwoFeedChainlinkPriceFeed`** ([`src/prices/TwoFeedChainlinkPriceFeed.sol`](TwoFeedChainlinkPriceFeed.sol)), for feeds whose rate comes from a Chainlink-ABI **rate feed** rather than an on-chain call — `asset/base` × the NAV's `base/USD` (`cbETH_L2_Price`, `rsETH_L2_Price`, `weETH_Price`, `weETH_L2_Price`, `wstETH_L2_Price`, `LDO_Price`, `syrupUSDC_L2_Price`, plus the generic `CrossRateCustomPriceFeed` and its named subclasses `stETH_Price` / `OETH_Price` / `lsETH_Price` and the `*CrossRate` redundancy feeds) — and **`ERC4626VaultRatePriceFeed`** ([`src/prices/ERC4626VaultRatePriceFeed.sol`](ERC4626VaultRatePriceFeed.sol)), for vault shares priced by `convertToAssets` × the NAV's `base/USD` (`sUSDe_Price`, `sUSDS_Price`, `sXDAI_Price`, `syrupUSDC_Price`, `RWIV_Price`, `sGHO_Price`). Feeds with no single rate leg (e.g. `ETHPlus_Price`), a derived two-feed rate (e.g. `eETH_Price`), an inverted rate (e.g. `ankrETH_Price`, whose `ratio()` is a denominator), a RAY-scaled DSR rate (e.g. `sDAI_Price`), or a non-standard `latestRoundData` shape (e.g. `wstETH_Price`'s two-Chainlink-leg `min(updatedAt)`) stay bespoke and implement the interface directly.

Conventions:

- **Always favor an existing Chainlink feed for the dollar leg** of the price (e.g., DAI/USD, ETH/USD, USDC/USD). Don't roll your own dollar oracle.
- **Read on-chain rates directly** (sDAI's `chi`, wstETH's `stEthPerToken`, rETH's `getExchangeRate`, etc.) rather than going through an off-chain oracle when the rate is canonical and cheap.
- **Return `(0, true)` on any failure or staleness path.** Don't revert.
- **All inputs are immutable, including heartbeats.** Pin every Chainlink heartbeat in the constructor as an immutable. New feed = redeploy. No setter, no MANAGER call needed after deployment.

### 5.1 Staleness design for custom feeds

#### How `Prices.sol` uses Custom feeds in the multi-feed model

`Prices.sol` uses the `bool stale` returned by `getLatestPrice()` as the **primary gate** — if `internalStale = true` or `price == 0`, the feed is skipped. For surviving custom feeds, `latestRoundData()` is then called to obtain `updatedAt`; the same heartbeat gate and freshest-wins logic that applies to Chainlink/Redstone/API3 feeds is applied (`effectiveTime = min(updatedAt, block.timestamp); skip if block.timestamp - effectiveTime >= heartbeat`). A custom feed returning `updatedAt == 0` is treated as `block.timestamp - 1` so it participates but yields to any feed with a real push timestamp (ADR 0009 §rationale).

#### Why `getLatestPrice().stale` is the primary staleness signal

**Multi-feed adapters have multiple Chainlink feeds, each with its own heartbeat.** The correct staleness condition is:

```
stale = block.timestamp − u1 > H1  OR  block.timestamp − u2 > H2
```

`Prices.sol` stores only a single `chainlinkHeartbeat` per asset. There is no single threshold `H` such that `block.timestamp − min(u1, u2) > H` is exactly equivalent to the OR above when `H1 ≠ H2`:

- `H = max(H1, H2)` — misses the faster feed going stale (false negative).
- `H = min(H1, H2)` — flags the slower feed as stale too early (false positive).

Encoding the check inside each adapter's `getLatestPrice()` is the only approach that works correctly for all heartbeat combinations. Each adapter pins its rate leg's heartbeat as an immutable and does the OR check directly, folding in the base/USD leg's staleness from the NAV's own selector (via `NavBaseUsdLib`) rather than pinning a second heartbeat.

Single-rate adapters (e.g. `rETH_Price`, `sDAI_Price`) benefit from the same pattern: the on-chain exchange rate (DSR chi, rETH exchange rate) has no heartbeat of its own — it updates from protocol interactions — so the only staleness source is the NAV-sourced base/USD leg, whose stale flag the adapter surfaces directly. Checking that in `getLatestPrice()` is natural.

`wstETH_Price` is a **two-feed** adapter: it combines `stEthPerToken` (no heartbeat) with the stETH/ETH Chainlink **rate** feed and the **NAV-sourced ETH/USD** base ([ADR 0019](../../docs/decisions/0019-nav-sourced-base-price.md)), so it does the OR check above internally (same as `CrossRateCustomPriceFeed`, used for stETH). Its `latestRoundData()` reports the **most-stale** of the two legs (lowest `updatedAt`), which for stETH/ETH is a ~daily cadence.

**Register a multi-feed Custom adapter with the slowest underlying leg's heartbeat.** Per the multi-feed model above, `Prices.sol` applies the single registered `chainlinkHeartbeat` to the adapter's `latestRoundData().updatedAt` as a *secondary* gate (after the primary `getLatestPrice().stale` gate). Since `latestRoundData()` surfaces the **slowest** leg's `updatedAt`, the registered heartbeat must be at least that leg's heartbeat — otherwise a tight scalar (e.g. 3600) falsely marks the asset stale whenever the slow leg hasn't ticked within the window (the exact failure a single threshold cannot avoid; see the false-positive/false-negative note above). For wstETH/stETH the slowest leg is stETH/ETH (86400), so they register `heartbeat = 86400`: the secondary gate then exactly mirrors the adapter's own stETH/ETH check (never false-trips), while the primary `getLatestPrice().stale` gate still independently covers the faster ETH/USD (3600) leg. Registering `type(uint256).max` is an equivalent alternative that disables the secondary gate entirely and delegates staleness fully to the adapter; the finite slowest-leg value is preferred here because it keeps a real NAV-level backstop and is consistent with the other Custom entries. (Note: on the legacy live NAV, whose `ICustomPriceFeed` has no `latestRoundData()`, the heartbeat param is ignored for Custom feeds and staleness is taken solely from `getLatestPrice()`.)

#### Heartbeat in `getLatestPrice()`

Every Chainlink heartbeat used in an adapter's staleness check is pinned as an immutable constructor argument and should match the official value published in the Chainlink registry. Look up heartbeat values at:
- https://data.chain.link/ (UI — search by feed name)
- JSON registry per chain (machine-readable; `heartbeat` field):

| Chain | ChainId | URL |
|---|---|---|
| Ethereum | 1 | https://reference-data-directory.vercel.app/feeds-mainnet.json |
| Arbitrum One | 42161 | https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json |
| Base | 8453 | https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json |
| Optimism | 10 | https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-optimism-1.json |
| Polygon | 137 | https://reference-data-directory.vercel.app/feeds-matic-mainnet.json |
| Gnosis | 100 | https://reference-data-directory.vercel.app/feeds-xdai-mainnet.json |
| BNB Chain | 56 | https://reference-data-directory.vercel.app/feeds-bsc-mainnet.json |

#### What `latestRoundData()` must return

`latestRoundData()` is called by `Prices.sol` for `updatedAt` (heartbeat gate + freshness ranking) and is also available to external monitoring tools via the standard Chainlink interface.

| Feed type | `updatedAt` | `answer` |
|---|---|---|
| Single Chainlink feed + on-chain rate | Pass through the Chainlink feed's `updatedAt` directly. The on-chain rate (exchange ratio, DSR chi, etc.) has no heartbeat — it updates with protocol interactions and is never the staleness bottleneck. | Computed price from `getLatestPrice()`. |
| Multiple Chainlink feeds | `min(updatedAt_1, updatedAt_2, …)` — the oldest timestamp across all constituent feeds. This reflects worst-case freshness. | Computed price from `getLatestPrice()`. |
| Indirect oracle (e.g. ETHPlus via Reserve Protocol) | `min(IAsset.lastSave())` across prime basket components — the Reserve Protocol equivalent of `updatedAt`. | Computed price from `getLatestPrice()`. |
| No trackable oracle dependency | `0` (return `(0, 0, 0, 0, 0)`). `Prices.sol` treats this as `block.timestamp - 1` so the feed participates but yields to any feed with a real timestamp. | — |

**Threshold for external callers of multi-feed adapters**: an external caller checking `block.timestamp − updatedAt > H` should use `H = min(H1, H2, …)` — the smallest heartbeat among constituent feeds. Using a larger value can silently miss the faster feed going stale.

**`answer` field**: returns the computed price when healthy, `0` when stale or when underlying prices are invalid (non-positive). Do not infer freshness from a non-zero `answer` alone — always check `updatedAt` or call `getLatestPrice()` directly.

#### The registered `chainlinkHeartbeat` for custom feeds

`_addPriceFeed()` requires a non-zero heartbeat for all feed types. For custom feeds this value is used by `Prices.sol` as the heartbeat gate on `latestRoundData().updatedAt` (after the primary `getLatestPrice().stale` gate). Set it to the slowest constituent Chainlink heartbeat for the adapter — i.e. `max(H1, H2, …)` — so the external heartbeat gate does not fire before the internal staleness check would.

For feeds backed by Reserve Protocol (ETHPlus): set this to the slowest Chainlink heartbeat among the basket's underlying feeds — 86 400 s for the current ETH+ basket. Re-evaluate if basket composition changes.

---

## 6. How NAVCalculator uses prices

For each `PositionBalance` returned by an oracle, NAVCalculator:

1. Calls `latestPrice(asset)` on the price registry.
2. Gets `(price, decimals, stale)`. If stale, the asset is added to `NAV.stalePriceAssets`; the position still contributes to NAV using the last-known price (consumers decide what to do with stale).
3. Computes `value = amount × price` (sign by `isDebt`).
4. If `quoteAsset != address(0)`, divides by `latestPrice(quoteAsset)` so NAV is denominated in the quote currency.

So custom feeds are **building blocks** for value computation. Their staleness flags propagate into `NAV.stalePriceAssets` so callers can decide the right policy.

---

## 7. Implemented custom feeds

All in `src/prices/protocols/`. Pattern is one file per asset; L2-specific variants get a `_L2_` infix. Feeds marked **(base)** below extend `BaseCustomPriceFeed` and implement only `_rate()` (see §5.0); the rest either extend a sibling skeleton (`TwoFeedChainlinkPriceFeed` or `ERC4626VaultRatePriceFeed`, also §5.0) or implement `ICustomPriceFeed` directly.

### Yield-bearing stable wrappers (rate × USD-feed)

| Feed | Asset | Underlying inputs |
|---|---|---|
| `sDAI_Price` | sDAI | DAI/USD (via NAV) × DSR `pot.chi()` (RAY-scaled) |
| `sUSDS_Price` | sUSDS | USDS/USD (via NAV) × Sky savings rate |
| `sUSDe_Price` | sUSDe | USDe/USD (via NAV) × Ethena vault share rate |
| `sGHO_Price` | sGHO | GHO/USD (via NAV) × Aave sGHO vault share rate (`convertToAssets`) |
| `sXDAI_Price` | sXDAI | xDAI/USD (via NAV) × Gnosis savings rate (Gnosis Chain only) |
| `syrupUSDC_Price`, `syrupUSDC_L2_Price` | syrupUSDC | USDC/USD (via NAV) × Maple syrup rate |
| `RWIV_Price` | RWIV | USDC/USD (via NAV) × Nexus RWI Vault share rate (`convertToAssets`) |

### Liquid (re)staking tokens

| Feed | Asset | Underlying inputs |
|---|---|---|
| `cbETH_Price` **(base)**, `cbETH_L2_Price` | cbETH | cbETH-per-ETH rate × ETH/USD |
| `stETH_Price` | stETH (Mainnet) | stETH/ETH (Chainlink) × ETH/USD — a thin `CrossRateCustomPriceFeed` subclass; replaces the raw STETH/USD Chainlink feed so ETH/USD cancels when NAV is quoted in ETH |
| `lsETH_Price` | lsETH (Mainnet) | lsETH/ETH (Chainlink) × ETH/USD — thin `CrossRateCustomPriceFeed` subclass |
| `wstETH_Price` | wstETH (Mainnet) | `stEthPerToken` × stETH/ETH × ETH/USD — ETH/USD cancels when NAV is quoted in ETH (uses the real stETH/ETH rate, no 1:1 assumption) |
| `wstETH_L2_Price` | wstETH (Arbitrum/Base/Gnosis) | wstETH/ETH rate × ETH/USD |
| `rETH_Price` **(base)** | rETH | `getExchangeRate` × ETH/USD |
| `rsETH_Price` **(base)**, `rsETH_L2_Price` | rsETH | rsETH-per-ETH rate × ETH/USD |
| `eETH_Price` | eETH | eETH-per-ETH × ETH/USD |
| `weETH_Price`, `weETH_L2_Price` | weETH | weETH/ETH (Mainnet) or weETH/eETH (L2, eETH ~1:1 ETH) Chainlink rate × ETH/USD |
| `ezETH_Price` **(base)**, `ezETH_L2_Price` **(base)** | ezETH | Renzo reporter rate × ETH/USD |
| `ETHx_Price` **(base)** | ETHx | Stader `StaderStakePoolsManager.getExchangeRate` × ETH/USD |
| `osToken_Price` **(base)** | osETH (Mainnet), osGNO (Gnosis) | StakeWise `OsTokenVaultController.convertToAssets(1e18)` × underlying/USD (ETH/USD for osETH, GNO/USD for osGNO). One generic contract per (osToken, controller, underlying/USD feed) — extensible to any future osToken. Held osTokens are wallet ERC20s reported by `ERC20DefaultBalanceAdapter`. |
| `ankrETH_Price` | ankrETH (Mainnet) | ETH/USD × 1e18 / `ratio()` (ankrETH's `ratio()` is ankrETH-per-ETH, so ETH-per-ankrETH = 1e18/ratio) |
| `OETH_Price` | OETH (Mainnet) | OETH/ETH (Chainlink) × ETH/USD — a thin `CrossRateCustomPriceFeed` subclass; Origin OETH rebases ~1:1 to ETH and is priced off the Chainlink OETH/ETH feed |

### Other derived

| Feed | Asset | Notes |
|---|---|---|
| `LDO_Price` | LDO | LDO/ETH (Chainlink) × ETH/USD (via NAV) — thin `TwoFeedChainlinkPriceFeed` subclass |
| `ETHPlus_Price` | ETH+ | Reserve Protocol RToken. Price = (basketsNeeded / totalSupply) × basketPrice(low). Returns stale if `IBasketHandler.status() != SOUND` (catches IFFY — lagging oracle — as well as DISABLED) or if `block.timestamp − min(IAsset.lastSave()) > RESERVE_PROTOCOL_HEARTBEAT`. `latestRoundData()` returns `updatedAt = min(IAsset.lastSave())` across prime basket components for external observability. |
| `CrossRate_Price` | generic | Generic helper: `asset/base × base/USD` from a Chainlink rate feed × the NAV's base/USD (used when no direct asset/USD feed exists, or to keep a shared feed cancelling — e.g. the stETH instance prices stETH as stETH/ETH × ETH/USD) |
| `NXM_Price` **(base)** | NXM, wNXM (Mainnet) | Nexus Mutual RAMM `getInternalPrice()` (ETH-per-NXM, manipulation-resistant TWAP) × ETH/USD. NXM has no external market oracle by design. One instance per priced token: NXM, and wNXM (the 1:1 wrapper a Nexus member can unwrap to NXM, so book value is realizable — matches how aggregators price wNXM). |

**Redundancy `*CrossRate` feeds.** `ETHx_CrossRate_Price`, `ezETH_CrossRate_Price`, and `osETH_CrossRate_Price` are thin `CrossRateCustomPriceFeed` subclasses registered *alongside* their primary feed (`ETHx_Price` / `ezETH_Price` / `osToken_Price`). Each sources the `asset/ETH` rate from an independent Redstone Classic Push market feed rather than the protocol's on-chain rate, giving the freshest-wins selector a genuinely separate fallback source.

`_L2_` variants exist for assets where the canonical rate lives on L1. They typically read a Chainlink-secured rate feed on the L2 (rather than calling the L1 rate-provider directly) and inherit the L2 sequencer check via `Prices`.

---

## 8. How to create a new custom price feed

Detailed walkthrough lives at [`docs/howto/add-price-feed.md`](../../docs/howto/add-price-feed.md). Quick checklist:

### 8.1 Contract layout

**If your feed is just `rate × base/USD` (the NAV-sourced base times an 18-decimal on-chain rate), extend `BaseCustomPriceFeed` instead** — pass `(underlying, nav, baseAsset)` to its constructor and implement only `_rate()`. The five interface methods, immutables, validation, and staleness/normalize math come for free (see §5.0; e.g. `rETH_Price`). If the rate comes from a Chainlink-ABI rate feed rather than an on-chain call, extend **`TwoFeedChainlinkPriceFeed`** (pass `(underlying, rateFeed, rateHeartbeat, nav, baseAsset)`; e.g. `weETH_Price`, or `CrossRateCustomPriceFeed` for a generic cross-rate); if it's an ERC-4626 vault share, extend **`ERC4626VaultRatePriceFeed`** (pass `(vault, nav, baseAsset)`; e.g. `sUSDe_Price`). The full checklist below applies to bespoke feeds that don't fit any of those shapes (derived multi-feed rates, no single rate leg, an inverted rate, or a non-standard `latestRoundData`).

1. Create `src/prices/protocols/<Asset>_CustomPriceFeed.sol` (suffix `_L2_Price` for L2-specific variants).
2. Implement `ICustomPriceFeed` and `IERC165`.
3. Pin every input as `immutable` in the constructor: token address, dollar-leg Chainlink feed, rate provider, heartbeats.
4. Use `OracleArgumentChecks` (`src/utils/OracleArgumentChecks.sol`) for constructor validation: `assertERC20Address`, `assertChainlinkOracle`, `assertNotZeroNumber`, `assertNonZeroAddress`.
5. In `getLatestPrice`:
   - Read Chainlink leg first; bail out with `(0, true)` if `price <= 0`.
   - Apply heartbeat: if `block.timestamp - updatedAt >= heartbeat`, set `stale = true`.
   - Read on-chain rate. If non-positive or out-of-range, return `(0, true)`.
   - Combine and rescale to the target decimals (use `RATIO_DECIMALS` constants when the rate has its own scale).
6. Implement `latestRoundData()` — see §5.1 for what to return. For a single Chainlink dependency: pass through that feed's round data, substituting `answer` with the computed price. For multiple Chainlink feeds: return the tuple with the lowest `updatedAt`, again substituting `answer`.
7. `decimals()` returns the pinned decimals (typically the Chainlink feed's decimals).
8. `underlyingAssetSupported()` returns the token address.

### 8.2 Tests

- Unit test under `test/prices/protocols/<Asset>_Price.t.sol` with mocked Chainlink + rate provider:
  - Happy path: known inputs → expected output.
  - Negative Chainlink price → `(0, true)`.
  - Stale heartbeat → `(0, true)` — return zero price when stale (security invariant I-1).
  - Zero or negative rate → `(0, true)`.
- Fork test under `test/prices/protocols/fork/<Asset>_Price.fork.t.sol` against the real feed at a pinned block — assert the price is within a reasonable range and not stale.

### 8.3 Registration

Once deployed, register via `NAVCalculator.registerAsset(asset, customFeed, PriceType.Custom, heartbeat)` (MANAGER role). The asset config under `script/config/nav-config/assets-and-price-feeds/<chainId>.json` should hold the asset entry; `script/manage/RegisterAssets.s.sol` reads it and calls `registerAsset` (the first feed) plus `addPriceFeed` (any additional feeds). The custom feed contract itself is deployed earlier by `script/deploy/03_DeployPriceFeeds.s.sol`.

---

## 9. Configuration and use

### 9.1 Asset registration

Per-chain asset registration config lives at `script/config/nav-config/assets-and-price-feeds/<chainId>.json`, keyed by asset symbol, each carrying the token `address` and an ordered `priceFeeds[]` array (see [`script/config/CONFIG_GUIDE.md`](../../script/config/CONFIG_GUIDE.md) for the full schema). Each feed entry has a `type` (`Chainlink` / `Redstone` / `API3` / `Custom`), a `heartbeat`, and either an `address` (all types except `Custom`) or a `feed` name (`Custom` only, resolved post-deploy from `script/config/deployments/<chainId>.json` `.customPriceFeeds.<name>`). The `chains/<chainId>.json` file carries only chain metadata and roles — not asset or feed config. For a custom feed, the entry typically looks like:

```json
{
  "wstETH": {
    "address": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
    "priceFeeds": [
      {
        "type": "Custom",
        "feed": "wstETH",
        "heartbeat": 86400
      }
    ]
  }
}
```

`script/manage/RegisterAssets.s.sol` reads these and calls `NAVCalculator.registerAsset` for the first feed (and `addPriceFeed` for any additional ones).

### 9.2 Adding the same asset on multiple chains

Each chain has its own `priceFeed` deployment. L2 variants use `*_L2_Price` so the L1 rate provider isn't called from the wrong chain. Pick the right variant based on where the rate canonically lives.

### 9.3 Updating a feed / adding redundancy

Custom feeds are immutable. To change inputs (e.g., new Chainlink feed address), redeploy the adapter, add it with `NAVCalculator.addPriceFeed(asset, newFeed, priceType, heartbeat)` (MANAGER), and remove the old one with `NAVCalculator.removePriceFeed(asset, oldFeed)`. Removal reverts if it would leave the asset with no feeds — add first, then remove.

To add a second (or third) feed for redundancy without removing the existing one, just call `addPriceFeed`. Both feeds participate in the freshest-wins selection from that point on.

---

## 10. Discovering and verifying feed addresses

All known feed addresses are catalogued in [`script/config/price-feeds-catalogue.json`](../../script/config/price-feeds-catalogue.json), organised by chain → token → provider. The sections below describe how to look up and verify addresses from each provider.

### 10.1 Chainlink

Chainlink maintains a public reference directory for all deployed AggregatorV3 feeds.

**Reference data directory (JSON API):**

```
# Ethereum Mainnet
https://reference-data-directory.vercel.app/feeds-mainnet.json

# Arbitrum
https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json

# Optimism
https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-optimism-1.json

# Base
https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json

# Polygon
https://reference-data-directory.vercel.app/feeds-matic-mainnet.json

# BNB Chain
https://reference-data-directory.vercel.app/feeds-bsc-mainnet.json

# Gnosis
https://reference-data-directory.vercel.app/feeds-xdai-mainnet.json
```

Each JSON entry contains `contractAddress`, `name` (e.g. `"ETH / USD"`), `decimals`, and `heartbeat`. The same addresses are browseable at [docs.chain.link/data-feeds/price-feeds/addresses](https://docs.chain.link/data-feeds/price-feeds/addresses).

**Decimals:** 8 for all USD-denominated feeds (standard). A handful of Chainlink feeds return 18 decimals (e.g. the ETH+/USD feed at `0x66Ab9003...`) — these cannot be registered directly as `PriceType.Chainlink` alongside 8-dec feeds because `PriceFeedLib.addFeed` enforces decimal consistency across all feeds for an asset (reverts `PriceFeedDecimalsMismatch`). Note: `PriceType.API3` feeds also return 18 decimals from the proxy but are normalised to 8-dec automatically by `PriceFeedLib` — see §10.3.

### 10.2 Redstone Classic Push

Redstone Classic Push feeds implement `AggregatorV3Interface` and are updated by Redstone's relayer on-chain (same model as Chainlink). The full list is browseable at [app.redstone.finance/push-feeds](https://app.redstone.finance/push-feeds) (requires JavaScript rendering).

**Deployment manifests:** The canonical source is the private `redstone-monorepo-priv` repository. If you need feeds not listed in the catalogue, contact Redstone via [Discord](https://discord.gg/redstone) or check the app.

**Verified addresses in the catalogue:**

| Feed | Chain | Address | Contract name |
|---|---|---|---|
| weETH/USD | 1 | `0x0c2c7ded01ccdfab16f04aff82af766b23d6be0a` | `MergedAdapterWithRoundsWeethV1` |
| ETHx/USD | 1 | `0x1ba0c3c2db83b34961dfa683038e11852f57920a` | `PriceFeedStaderEthxWithoutRoundsV3` |

**Decimals:** 8. **Heartbeat:** varies per feed.

**Adding new Redstone addresses:** Browse the app or ask Redstone directly, then add the entry under the relevant chain → token in `price-feeds-catalogue.json` with `"Redstone": { "address": "0x...", "pair": "...", "decimals": 8, "heartbeat": <seconds> }`.

### 10.3 API3 dAPI communal proxies

API3 dAPIs use a deterministic CREATE2 factory. The communal `Api3ReaderProxyV1` proxy address depends only on the dAPI name (`bytes32`) — it is the **same address on every chain** where the factory is deployed.

**Factory (same on all chains):** `0x1Fe170311Cb13e3bfB96DeC8FAadcf97BF843381`

**Compute an address:**

```js
// npm install @api3/contracts
const { computeCommunalApi3ReaderProxyV1Address } = require('@api3/contracts');

// Example — same result for chainId 1, 42161, 8453, 10, 56, 100, 137
const proxy = computeCommunalApi3ReaderProxyV1Address(1, 'ETH/USD');
// → 0x5b0cf2b36a65a6BB085D501B971e4c102B9Cd473
```

**Or call the factory on-chain:**

```solidity
IApi3ReaderProxyV1Factory(0x1Fe170311Cb13e3bfB96DeC8FAadcf97BF843381)
    .computeApi3ReaderProxyV1Address(
        bytes32("ETH/USD"),  // right-padded dAPI name
        1,                   // dappId = 1 for communal proxies
        ""                   // empty metadata
    );
```

**Critical caveat:** A computed address is where the proxy *would* be deployed. It must actually be deployed before `latestRoundData()` responds. Verify via the [API3 Market](https://market.api3.org) (select chain + dAPI → "Skip OEV Rewards") or call `latestRoundData()` on-chain and check for revert.

**Decimals:** All API3 communal proxies return **18 decimals** — this is a protocol-level invariant of the communal proxy factory, not a per-feed choice. `PriceFeedLib` handles the scaling automatically: at registration time it asserts `decimals() == 18` (reverts `InvalidPriceOracle` otherwise) and stores `decimals = 8` in `PriceFeedConfig`; at read time it divides the raw 18-dec answer by `1e10` before returning it. Callers always receive 8-decimal USD prices, consistent with Chainlink and Redstone feeds.

**Default heartbeat:** 86 400 s (24 h) for managed feeds with 1 % deviation threshold.

**Registering an API3 feed:**

```solidity
// priceType = PriceType.API3; heartbeat = 86400 (confirm on the Market page first)
nav.addPriceFeed(asset, proxyAddress, IPrices.PriceType.API3, 86400);
// The proxy must return 18 decimals; non-18-dec proxies revert with InvalidPriceOracle.
```

**Browse available dAPIs:** [market.api3.org](https://market.api3.org)

### 10.4 Verifying feed liveness

A computed API3 address (or any new feed address) must be verified as live before being added to the catalogue or registered on-chain. Use `cast call` from Foundry:

```bash
# Returns 5 values → feed is deployed and responding.
# Reverts with no output → proxy not deployed on this chain.
cast call --rpc-url $RPC_URL $PROXY_ADDRESS \
  "latestRoundData()(uint80,int256,uint256,uint256,uint80)"
```

**Example — ETH/USD on Ethereum mainnet:**

```bash
cast call \
  --rpc-url https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_KEY \
  0x5b0cf2b36a65a6BB085D501B971e4c102B9Cd473 \
  "latestRoundData()(uint80,int256,uint256,uint256,uint80)"
# 18446744073709557506 325032000000000000000 1747917359 1747917359 18446744073709557506
# ↑ Five values returned — proxy is live.
```

**Interpreting the result:**

| Result | Meaning |
|---|---|
| Five integers printed | Feed is deployed and responding — note `updatedAt` (4th value) to check recency. |
| `(no output)` / revert | Proxy not deployed on this chain — `"deployed": false` in the catalogue. |

**Check multiple chains in parallel** (replace `$RPC_*` with your RPC env vars):

```bash
ADDR=0x5b0cf2b36a65a6BB085D501B971e4c102B9Cd473
SIG="latestRoundData()(uint80,int256,uint256,uint256,uint80)"

for rpc in $RPC_MAINNET $RPC_ARBITRUM $RPC_BASE $RPC_OPTIMISM $RPC_GNOSIS $RPC_BSC $RPC_POLYGON; do
  echo -n "$rpc → "
  cast call --rpc-url $rpc $ADDR "$SIG" 2>&1 | head -1
done
```

**After checking, update the catalogue.** In `script/config/price-feeds-catalogue.json`, set `"deployed": true` or `"deployed": false` on each API3 entry. Update `_meta.api3_liveness_checked` to today's date. Re-run this check whenever:
- a new chain is added to the catalogue,
- a new dAPI name is added, or
- more than ~6 months have passed (API3 deploys proxies progressively and a previously undeployed address may have become live).

This same `cast call` pattern works for Chainlink and Redstone feeds — if the call reverts, the feed is not deployed on that chain.

---

## 11. Quick reference

- **Interface:** `src/prices/ICustomPriceFeed.sol`
- **Registry:** `src/prices/Prices.sol` and `src/prices/IPrices.sol`
- **Feed configs:** `_priceOracles[asset]` → `PriceFeedConfig[]` (use `getPriceFeedAt`, `getPriceFeedCount`, `getPriceFeeds` to read)
- **Existing feeds:** `src/prices/protocols/`
- **Feed address catalogue:** [`script/config/price-feeds-catalogue.json`](../../script/config/price-feeds-catalogue.json)
- **Walkthrough:** [`docs/howto/add-price-feed.md`](../../docs/howto/add-price-feed.md)
- **Design rationale:** [`docs/decisions/0009-multi-feed-price-redundancy.md`](../../docs/decisions/0009-multi-feed-price-redundancy.md)
- **Cross-reference:** [`src/balances/BALANCE_ADAPTERS.md`](../balances/BALANCE_ADAPTERS.md) (balance side of the same architecture)
