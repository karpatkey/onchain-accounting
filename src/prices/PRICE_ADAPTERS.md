# Price Adapters: Architecture and Integration

This is the price-side counterpart to [`src/balances/BALANCE_ADAPTERS.md`](../balances/BALANCE_ADAPTERS.md). It describes the `Prices` abstract registry, the `IPriceFeedCustom` interface, the existing per-asset custom adapters, and how to add a new one.

---

## 1. Overview

The price system gives `NAVCalculator` a single price for any asset, in some "USD-like" unit. There are two kinds of feeds:

- **Chainlink**: `priceType = Chainlink`. Direct read of `AggregatorV3Interface.latestRoundData()`. Staleness = `block.timestamp - updatedAt > chainlinkHeartbeat`.
- **Custom**: `priceType = Custom`. A standalone contract implementing `IPriceFeedCustom` that derives a price (e.g., `sDAI` → `(DAI/USD) × (sDAI/DAI)`; `wstETH` → `(stETH-per-wstETH) × (stETH/USD)`). The contract is responsible for its own staleness logic (and typically piggy-backs on its underlying Chainlink feeds for it).

Both kinds register through the same path on `NAVCalculator`. Both are subject to the **L2 sequencer uptime** check when a sequencer feed is set on `Prices`.

So: **`Prices` is the registry; per-asset custom contracts are the building blocks.**

---

## 2. Price flow: from asset to price

```mermaid
flowchart LR
    A[asset address] --> P[Prices._latestPrice]
    P --> C{priceType}
    C -->|Chainlink| CL[AggregatorV3.latestRoundData]
    C -->|Custom| IF[IPriceFeedCustom.getLatestPrice]
    CL --> SCL[block.timestamp − updatedAt > heartbeat]
    IF --> SCU[propagate stale flag from adapter]
    SCL --> SQ[L2 sequencer uptime + grace]
    SCU --> SQ
    SQ --> R[(price, decimals, stale)]
```

Steps in code (`src/prices/Prices.sol`):

1. **Lookup** — `priceOracles[asset]` returns `PriceFeedConfig { priceFeed, decimals, chainlinkHeartbeat, priceType }`. Reverts if unset.
2. **Fetch** — Chainlink branch reads `latestRoundData()` for both price and `updatedAt`. Custom branch calls `getLatestPrice()` for both price and the stale flag.
3. **Freshness** — Chainlink: `stale = block.timestamp - updatedAt > chainlinkHeartbeat`. Custom: `stale` is the bool returned directly by `getLatestPrice()` — each adapter encodes its own per-feed heartbeat logic (see §5.1). A non-positive or zero price short-circuits to `(0, stale=true)` in both branches.
4. **L2 sequencer** — Top-level `latestPrice()` ORs in `checkL2SequencerUptime()`: stale if the sequencer is down, within `chainlinkL2SequencerGracePeriod` (default 1 hour) of recovery, or the uptime feed reports `startedAt == 0` (Chainlink documents this as an Arbitrum pre-initialization edge case). On L1, the sequencer feed is the zero address and this check is a no-op.
5. **Return** — `(int256 price, uint8 decimals, bool stale)`. Sign is positive in practice (Chainlink prices are positive; custom feeds cast from `uint256`).

---

## 3. Data structures

### 3.1 PriceFeedConfig (registered config)

Defined in `IPrices`.

| Field | Type | Description |
|---|---|---|
| `priceFeed` | `address` | Chainlink aggregator or custom contract (`IPriceFeedCustom`). |
| `decimals` | `uint8` | Decimals of the returned price. Pinned at registration from the feed itself. |
| `chainlinkHeartbeat` | `uint256` | Staleness window in seconds. Required non-zero for all feeds. For **Chainlink** feeds `Prices.sol` checks `block.timestamp − latestRoundData().updatedAt > heartbeat`. For **Custom** feeds it is stored for reference and external callers but is not used by `Prices.sol` — staleness is determined by `getLatestPrice().stale` (see §5.1). |
| `priceType` | `PriceType` | Enum `{ Chainlink, Custom }`. |

### 3.2 Custom feed return shape

`IPriceFeedCustom.getLatestPrice()` returns `(uint256 price, bool stale)`. **`Prices.sol` propagates `stale` directly** — it is the sole staleness signal for Custom feeds. The convention of returning `(0, true)` on any failure still applies: a zero price also short-circuits to stale in `Prices.sol`, so it is a reliable fallback signal even if the caller ignores the bool.

---

## 4. Prices contract (registry behavior)

`Prices` is an abstract contract used by NAVCalculator. It maintains:

- **Per-asset feed config:** `mapping(address => PriceFeedConfig) public priceOracles`.
- **L2 sequencer state:** `chainlinkL2SequencerUptimeFeed` and `chainlinkL2SequencerGracePeriod` (default 1 hour). Set once via `__Prices_init` at NAV initialization.

Internal API (used by NAVCalculator):

- `_setPriceFeed(asset, priceFeed, chainlinkHeartbeat, priceType)` — checks support, reads decimals from the feed, stores `PriceFeedConfig`. Heartbeat must be non-zero for all feed types.
- `_unsetPriceFeed(asset)` — removes entry; subsequent `latestPrice` reverts with `PriceFeedNotSet`.
- `checkPriceOracleSupport(asset, priceFeed, priceType)` — public; ERC165 check for custom, sanity round-data fetch for Chainlink.

`NAVCalculator` exposes `registerAsset(asset, oracle, priceType, chainlinkHeartbeat)` (MANAGER) which combines `_setPriceFeed` with adding the asset to the Balances asset registry.

---

## 5. IPriceFeedCustom

Every custom feed must implement this interface (and ERC165).

| Method | Purpose |
|---|---|
| `getLatestPrice()` | Returns `(uint256 price, bool stale)`. Price is in `decimals()` precision. Return `(0, true)` on any failure or uncertainty. `Prices.sol`'s staleness gate for Custom feeds reads the `stale` flag directly; a zero price is **also** treated as stale by `Prices.sol` as a defence-in-depth signal. |
| `latestRoundData()` | Returns `(roundId, answer, startedAt, updatedAt, answeredInRound)` — same shape as Chainlink's `AggregatorV3Interface`. **`Prices.sol` does not read this** for staleness (it uses `getLatestPrice().stale` directly), but `NAVCalculator.getPriceData()` does call it to surface the underlying-oracle `updatedAt` to external callers (dashboards, monitoring tools) through the unified `PriceFeedData` struct. See §5.1 for what to return. |
| `decimals()` | Returns the number of decimals the price is expressed in. Pinned at construction. |
| `underlyingAssetSupported()` | Returns the asset address this feed prices. Single asset per feed (1:1 contract-to-asset). |
| `supportsInterface(bytes4)` | Must return `true` for `type(IPriceFeedCustom).interfaceId` and `IERC165`. |

Conventions:

- **Always favor an existing Chainlink feed for the dollar leg** of the price (e.g., DAI/USD, stETH/USD, USDC/USD). Don't roll your own dollar oracle.
- **Read on-chain rates directly** (sDAI's `chi`, wstETH's `stEthPerToken`, rETH's `getExchangeRate`, etc.) rather than going through an off-chain oracle when the rate is canonical and cheap.
- **Return `(0, true)` on any failure or staleness path.** Don't revert.
- **All inputs are immutable, including heartbeats.** Pin every Chainlink heartbeat in the constructor as an immutable. New feed = redeploy. No setter, no MANAGER call needed after deployment.

### 5.1 Staleness design for custom feeds

#### Why `getLatestPrice().stale` — not `latestRoundData()` — is the staleness signal

`Prices.sol` propagates the `bool stale` returned by `getLatestPrice()` directly. `latestRoundData()` is not called by `Prices.sol` at all for custom feeds.

The key reason: **multi-feed adapters have multiple Chainlink feeds, each with its own heartbeat.** The correct staleness condition is:

```
stale = block.timestamp − u1 > H1  OR  block.timestamp − u2 > H2
```

`Prices.sol` stores only a single `chainlinkHeartbeat` per asset. There is no single threshold `H` such that `block.timestamp − min(u1, u2) > H` is exactly equivalent to the OR above when `H1 ≠ H2`:

- `H = max(H1, H2)` — misses the faster feed going stale (false negative).
- `H = min(H1, H2)` — flags the slower feed as stale too early (false positive).

Encoding the check inside each adapter's `getLatestPrice()` is the only approach that works correctly for all heartbeat combinations. Each adapter has both heartbeats as immutables and does the OR check directly.

Single-Chainlink-feed adapters (e.g. `wstETH_Price`, `rETH_Price`, `sDAI_Price`) benefit from the same pattern: the on-chain exchange rate (wstETH ratio, DSR chi, rETH exchange rate) has no heartbeat of its own — it updates from protocol interactions. The single Chainlink feed is the only staleness source, and checking it in `getLatestPrice()` is natural.

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

`latestRoundData()` is implemented on all custom feeds for two consumers: external tools (dashboards, monitoring) that prefer the standard Chainlink interface, and `NAVCalculator.getPriceData()`, which calls it to populate the `updatedAt` field of `PriceFeedData` so callers see a unified freshness timestamp for Chainlink and Custom alike. `Prices.sol`'s staleness gate does not read it — staleness still comes from `getLatestPrice().stale`.

| Feed type | `updatedAt` | `answer` |
|---|---|---|
| Single Chainlink feed + on-chain rate | Pass through the Chainlink feed's `updatedAt` directly. The on-chain rate (exchange ratio, DSR chi, etc.) has no heartbeat — it updates with protocol interactions and is never the staleness bottleneck. | Computed price from `getLatestPrice()`. |
| Multiple Chainlink feeds | `min(updatedAt_1, updatedAt_2, …)` — the oldest timestamp across all constituent feeds. This reflects worst-case freshness. | Computed price from `getLatestPrice()`. |
| Indirect oracle (e.g. ETHPlus via Reserve Protocol) | `min(IAsset.lastSave())` across prime basket components — the Reserve Protocol equivalent of `updatedAt`. | Computed price from `getLatestPrice()`. |
| No trackable oracle dependency | `0` (return `(0, 0, 0, 0, 0)`). | — |

**Threshold for external callers of multi-feed adapters**: an external caller checking `block.timestamp − updatedAt > H` should use `H = min(H1, H2, …)` — the smallest heartbeat among constituent feeds. Using a larger value can silently miss the faster feed going stale.

**`answer` field**: always the current computed price, even when stale. This follows Chainlink convention — callers use `updatedAt` to decide freshness, not a zero `answer`. The only time `answer = 0` is when the underlying prices are invalid (non-positive), which signals "do not use this price" independently of staleness.

#### The registered `chainlinkHeartbeat` for custom feeds

`_setPriceFeed()` requires a non-zero heartbeat for all feed types. For custom feeds this value is not used by `Prices.sol` but it:
- documents the expected update cadence of the adapter,
- can be used by external callers as the threshold for `latestRoundData().updatedAt` checks (use `min(individual heartbeats)` for multi-feed adapters).

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

All in `src/prices/protocols/`. Pattern is one file per asset; L2-specific variants get a `_L2_` infix.

### Yield-bearing stable wrappers (rate × USD-feed)

| Feed | Asset | Underlying inputs |
|---|---|---|
| `sDAI_Price` | sDAI | DAI/USD Chainlink × DSR `pot.chi()` (RAY-scaled) |
| `sUSDS_Price` | sUSDS | USDS/USD Chainlink × Sky savings rate |
| `sUSDe_Price` | sUSDe | USDe/USD Chainlink × Ethena vault share rate |
| `sXDAI_Price` | sXDAI | xDAI/USD Chainlink × Gnosis savings rate (Gnosis Chain only) |
| `syrupUSDC_Price`, `syrupUSDC_L2_Price` | syrupUSDC | USDC/USD Chainlink × Maple syrup rate |

### Liquid (re)staking tokens

| Feed | Asset | Underlying inputs |
|---|---|---|
| `cbETH_Price`, `cbETH_L2_Price` | cbETH | cbETH-per-ETH rate × ETH/USD |
| `wstETH_Price`, `wstETH_L2_Price` | wstETH | `stEthPerToken` × stETH/USD |
| `rETH_Price` | rETH | `getExchangeRate` × ETH/USD |
| `rsETH_Price`, `rsETH_L2_Price` | rsETH | rsETH-per-ETH rate × ETH/USD |
| `eETH_Price` | eETH | eETH-per-ETH × ETH/USD |
| `weETH_Price`, `weETH_L2_Price` | weETH | weETH-per-eETH × eETH/USD chain |
| `ezETH_Price`, `ezETH_L2_Price` | ezETH | Renzo reporter rate × ETH/USD |
| `ETHx_Price` | ETHx | Stader `StakePoolsManager.getExchangeRate` × ETH/USD |

### Other derived

| Feed | Asset | Notes |
|---|---|---|
| `LDO_Price` | LDO | Composite (cross-rate) |
| `ETHPlus_Price` | ETH+ | Reserve Protocol RToken. Price = (basketsNeeded / totalSupply) × basketPrice(low). Returns stale if `IBasketHandler.status() != SOUND` (catches IFFY — lagging oracle — as well as DISABLED) or if `block.timestamp − min(IAsset.lastSave()) > RESERVE_PROTOCOL_HEARTBEAT`. `latestRoundData()` returns `updatedAt = min(IAsset.lastSave())` across prime basket components for external observability. |
| `CrossRate_Price` | generic | Generic helper: A/B × B/C from two Chainlink feeds (used when no direct A/USD feed exists) |

`_L2_` variants exist for assets where the canonical rate lives on L1. They typically read a Chainlink-secured rate feed on the L2 (rather than calling the L1 rate-provider directly) and inherit the L2 sequencer check via `Prices`.

---

## 8. How to create a new custom price feed

Detailed walkthrough lives at [`docs/howto/add-price-feed.md`](../../docs/howto/add-price-feed.md). Quick checklist:

### 8.1 Contract layout

1. Create `src/prices/protocols/<Asset>_Price.sol` (suffix `_L2_Price` for L2-specific variants).
2. Implement `IPriceFeedCustom` and `IERC165`.
3. Pin every input as `immutable` in the constructor: token address, dollar-leg Chainlink feed, rate provider, heartbeats.
4. Use `OracleArgumentChecks` (`src/utils/OracleArgumentChecks.sol`) for constructor validation: `assertERC20Address`, `assertChainlinkOracle`, `assertNotZeroNumber`, `assertNonZeroAddress`.
5. In `getLatestPrice`:
   - Read Chainlink leg first; bail out with `(0, true)` if `price <= 0`.
   - Apply heartbeat: if `block.timestamp - updatedAt > heartbeat`, set `stale = true`.
   - Read on-chain rate. If non-positive or out-of-range, return `(0, true)`.
   - Combine and rescale to the target decimals (use `RATIO_DECIMALS` constants when the rate has its own scale).
6. Implement `latestRoundData()` — see §5.1 for what to return. `Prices.sol` does not call this; it exists for external observability. For a single Chainlink dependency: pass through that feed's round data, substituting `answer` with the computed price. For multiple Chainlink feeds: return the tuple with the lowest `updatedAt`, again substituting `answer`. Don't skip it; it's required by `IPriceFeedCustom`.
7. `decimals()` returns the pinned decimals (typically the Chainlink feed's decimals).
8. `underlyingAssetSupported()` returns the token address.

### 8.2 Tests

- Unit test under `test/prices/protocols/<Asset>_Price.t.sol` with mocked Chainlink + rate provider:
  - Happy path: known inputs → expected output.
  - Negative Chainlink price → `(0, true)`.
  - Stale heartbeat → `stale = true` but `price` still reflects the last value.
  - Zero or negative rate → `(0, true)`.
- Fork test under `test/prices/protocols/fork/<Asset>_Price.fork.t.sol` against the real feed at a pinned block — assert the price is within a reasonable range and not stale.

### 8.3 Registration

Once deployed, register via `NAVCalculator.registerAsset(asset, customFeed, PriceType.Custom, 0)` (MANAGER role). The chain config under `script/config/chains/<chainId>.json` should hold the asset entry; `script/deploy/03_RegisterAssets.s.sol` reads it and calls `registerAsset`.

---

## 9. Configuration and use

### 9.1 Asset registration

Per-chain config lives at `script/config/chains/<chainId>.json` under the `assets` and `priceFeeds` blocks (see [`script/config/CONFIG_GUIDE.md`](../../script/config/CONFIG_GUIDE.md) for the schema). For a custom feed, the entry typically looks like:

```json
{
  "address": "0x...sDAI",
  "symbol": "sDAI",
  "priceFeed": "0x...sDAI_PriceOracle",
  "priceType": "Custom",
  "chainlinkHeartbeat": 0
}
```

`03_RegisterAssets.s.sol` reads these and calls `NAVCalculator.registerAsset`.

### 9.2 Adding the same asset on multiple chains

Each chain has its own `priceFeed` deployment. L2 variants use `*_L2_Price` so the L1 rate provider isn't called from the wrong chain. Pick the right variant based on where the rate canonically lives.

### 9.3 Updating a feed

Custom feeds are immutable. To change inputs (e.g., new Chainlink feed address), redeploy and call `NAVCalculator.setPriceFeed(asset, newFeed, ...)`. Old feed stays on-chain; nothing references it after the switch.

---

## 10. Quick reference

- **Interface:** `src/prices/IPriceFeedCustom.sol`
- **Registry:** `src/prices/Prices.sol` and `src/prices/IPrices.sol`
- **Config:** `priceOracles[asset]` → `PriceFeedConfig`
- **Existing feeds:** `src/prices/protocols/`
- **Walkthrough:** [`docs/howto/add-price-feed.md`](../../docs/howto/add-price-feed.md)
- **Cross-reference:** [`src/balances/BALANCE_ADAPTERS.md`](../balances/BALANCE_ADAPTERS.md) (balance side of the same architecture)
