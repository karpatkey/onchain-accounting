# How to add a new price feed

End-to-end walkthrough for adding price support for a new asset — either via a Chainlink feed directly or a custom price oracle (`IPriceFeedCustom`).

Read [`src/prices/PRICE_ADAPTERS.md`](../../src/prices/PRICE_ADAPTERS.md) first if you have not — it's the framework reference; this is the recipe.

---

## A. Chainlink-only feed (no custom contract needed)

Use this path when a Chainlink USD feed for the asset already exists and is canonical (e.g., WBTC/USD, COMP/USD, GHO/USD).

### A.1 Find the feed and heartbeat

1. Go to [data.chain.link](https://data.chain.link) and search for the asset (e.g., "BTC / USD").
2. Select the correct network. Copy the proxy contract address (the one that survives aggregator upgrades) — not the underlying aggregator.
3. Note the **heartbeat** shown on the feed page (typically 3600 s for majors, 86400 s for less-liquid assets). Double-check with:
   ```bash
   cast call <feed_address> "description()(string)" --rpc-url $RPC
   cast call <feed_address> "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC
   ```
   Cross-reference the `updatedAt` timestamp against recent block times to confirm the heartbeat in practice.
4. Record the token's contract address on each chain you want to support.

### A.2 Add to `nav-config/assets-and-price-feeds/<chainId>.json`

Add a top-level entry keyed by `<SYMBOL>`:

```json
"WBTC": {
  "address": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
  "priceFeeds": [
    {
      "type": "Chainlink",
      "address": "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c",
      "heartbeat": 3600
    }
  ]
}
```

Rules:
- Each entry's `type` ∈ `{Chainlink, Custom, Redstone, API3}`.
- `address` is the feed's on-chain address — for Chainlink, the **proxy** (not the aggregator).
- `heartbeat` is in seconds. Use the value from the feed page.
- The **first** entry in `priceFeeds[]` is used for `registerAsset`; every additional entry is applied via `addPriceFeed` (see [ADR 0009](../decisions/0009-multi-feed-price-redundancy.md) and §C).

### A.3 No symbol list to edit

There is no `_symbolsForChain` list to update anymore. Both `script/manage/RegisterAssets.s.sol` and the integration harness `test/integration/IntegrationFromConfigBase.fork.sol` read symbols directly from `nav-config/assets-and-price-feeds/<chainId>.json` (via `getAssetSymbols`). Adding the asset as a top-level key there is sufficient.

### A.4 Add constant to `test/ChainlinkPriceFeeds.sol` (if not already present)

```solidity
function btcUsdEthMainnet() internal pure returns (address) {
    return 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
}
```

Check for an existing entry before adding. The constant is used in fork tests and the NAVCalculator harness — adding a duplicate will break compilation.

### A.5 Register via deploy script

No new contract to deploy. The `RegisterAssets.s.sol` script reads each chain's assets from `nav-config/assets-and-price-feeds/<chainId>.json` (`getAssetSymbols`) and calls `NAVCalculator.registerAsset(token, feed, PriceType.Chainlink, heartbeat)` for the first feed, then `NAVCalculator.addPriceFeed(...)` for the rest. Run it as part of the next deployment cycle or management TX.

To add a **second or third feed** for an already-registered asset (redundancy), call `NAVCalculator.addPriceFeed(asset, feed, PriceType.Chainlink, heartbeat)` via the MANAGER Safe. This appends the feed to the asset's array; both participate in the freshest-wins selection. See §C below.

### A.6 Verify

```bash
cast call $NAV_CALCULATOR "latestPrice(address)(int256,uint8,bool)" $TOKEN_ADDRESS --rpc-url $RPC
```

Expect `(price > 0, 8, false)`.

---

## B. Custom price feed (requires a new contract)

Use this path when there is no canonical Chainlink USD feed but the price is derivable on-chain — start with the decision check in §B.0.

---

## B.0 Decide whether you actually need a custom feed

You need a custom feed if **any** of these are true:

- The asset is a yield-bearing wrapper of another asset (e.g., sDAI, sUSDe, sUSDS) and the price is `(rate × underlying/USD)`.
- The asset is a (re)staking receipt token whose rate is exposed on-chain (cbETH, wstETH, weETH, rETH, rsETH, ezETH).
- There is no Chainlink USD feed for the asset, but you can derive the price from two existing feeds (use `CrossRate_Price`).

If a Chainlink USD feed exists and is canonical, use Chainlink directly. Don't roll a custom feed for no reason.

---

## B.1 Pick the recipe

| Pattern | Existing reference | When to use |
|---|---|---|
| `(rate × USD)` from a single Chainlink feed | `src/prices/protocols/sDAI_Price.sol` (DAI/USD × DSR `chi`) | Yield-bearing wrappers with an on-chain `chi`/`rate` field |
| LST/LRT receipt token with `getExchangeRate`-style method | `src/prices/protocols/wstETH_Price.sol`, `rETH_Price.sol` | Liquid staking tokens whose redeem rate is exposed on-chain |
| L2 mirror of an L1 rate | `src/prices/protocols/wstETH_L2_Price.sol`, `cbETH_L2_Price.sol` | Same asset, but the canonical rate lives on L1; reads a Chainlink-secured rate feed on L2 instead |
| Two Chainlink feeds composed | `src/prices/protocols/CrossRate_Price.sol` | A/B × B/C when there's no direct A/USD feed |
| Basket / aggregator | `src/prices/protocols/ETHPlus_Price.sol` | Reserve-style RTokens or other basket-derived prices |

Copy the closest match and rename. Don't deviate from the structure unless you need to — every feed in `src/prices/protocols/` follows the same shape.

---

## B.2 Write the contract

File: `src/prices/protocols/<Asset>_Price.sol` (suffix `_L2_Price` for L2-specific variants).

Skeleton (yield-bearing pattern; adjust for LST/LRT or cross-rate):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";

/// @title <Asset> Custom Price Oracle
/// @notice Returns the USD price of <Asset> as `<rate> * <underlying>/USD`.
/// @author kpk
contract MyAsset_PriceOracle is IPriceFeedCustom {
    AggregatorV3Interface public immutable USD_CHAINLINK_ORACLE;
    address public immutable RATE_PROVIDER;
    address public immutable MY_ASSET;
    uint256 public immutable USD_CHAINLINK_HEARTBEAT;
    uint8 public constant RATIO_DECIMALS = 18; // adjust per protocol's rate precision
    uint8 private immutable _decimals;

    constructor(
        address myAsset_,
        address rateProvider_,
        address usdChainlinkOracle_,
        uint256 usdChainlinkHeartbeat_
    ) {
        MY_ASSET = OracleArgumentChecks.assertERC20Address(myAsset_);
        RATE_PROVIDER = OracleArgumentChecks.assertNonZeroAddress(rateProvider_);
        USD_CHAINLINK_ORACLE = OracleArgumentChecks.assertChainlinkOracle(usdChainlinkOracle_);
        USD_CHAINLINK_HEARTBEAT = OracleArgumentChecks.assertNotZeroNumber(usdChainlinkHeartbeat_);
        _decimals = USD_CHAINLINK_ORACLE.decimals();
    }

    function _compute()
        private
        view
        returns (uint256 price, bool stale, uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        int256 usdPrice;
        (roundId, usdPrice, startedAt, updatedAt, answeredInRound) = USD_CHAINLINK_ORACLE.latestRoundData();
        if (usdPrice <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        uint256 effectiveUpdatedAt = updatedAt > block.timestamp ? block.timestamp : updatedAt;
        if (block.timestamp - effectiveUpdatedAt >= USD_CHAINLINK_HEARTBEAT) {
            return (0, true, roundId, startedAt, updatedAt, answeredInRound);
        }

        uint256 rate = _readRate(); // protocol-specific
        if (rate == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);

        price = uint256(usdPrice) * rate / (10 ** RATIO_DECIMALS);
    }

    function getLatestPrice() external view returns (uint256 price, bool stale) {
        (price, stale,,,,) = _compute();
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price;
        bool stale;
        (price, stale, roundId, startedAt, updatedAt, answeredInRound) = _compute();
        answer = stale ? int256(0) : int256(price);
    }

    function decimals() external view returns (uint8) { return _decimals; }
    function underlyingAssetSupported() external view returns (address) { return MY_ASSET; }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function _readRate() internal view returns (uint256) {
        // Read the protocol's rate (e.g., RATE_PROVIDER.chi(), wstETH.stEthPerToken(), rETH.getExchangeRate()).
    }
}
```

Conventions:

- **Pin every input as `immutable`** in the constructor. No setters.
- **Use `OracleArgumentChecks`** for argument validation. Don't roll your own zero-checks.
- **Return `(0, true)` on any failure path**, never revert. Stale prices propagate into NAV via `NAV.stalePriceAssets`.
- **Implement `latestRoundData()`** as well as `getLatestPrice()`. `IPriceFeedCustom` requires both; `Prices.sol` reads price/staleness from `getLatestPrice()`, while `latestRoundData()` exists for callers inspecting underlying-oracle freshness (return the worst-case `updatedAt`, or `(0, 0, 0, 0, 0)` for feeds with no trackable oracle). Computing both from one private `_compute()` helper, as above, keeps them consistent.
- **`decimals()`** returns the Chainlink feed's decimals (typically 8 for USD pairs). The custom feed's output must match this.
- **Heartbeat applies to the Chainlink leg only**; the rate provider is on-chain and trusted. If the rate goes negative or zero, treat as stale.
- **One asset per contract.** Even if two assets share the same recipe, deploy two contracts.

---

## B.3 Tests

### B.3.1 Unit test

File: `test/prices/protocols/<Asset>_Price.t.sol`.

Cover, with mocked Chainlink + mocked rate provider:

- **Happy path**: known inputs → expected output (compute by hand).
- **Negative Chainlink price** (`int256(-1)`) → returns `(0, true)`.
- **Stale heartbeat** (`updatedAt + heartbeat + 1`) → `(0, true)` — return zero price when stale.
- **Zero or negative rate** → `(0, true)`.
- **Constructor zero-address guards** for every immutable.
- **Constructor zero-heartbeat guard**.
- **`decimals()`** returns the Chainlink feed's decimals.
- **`underlyingAssetSupported()`** returns the asset address.
- **`latestRoundData()`** returns the underlying oracle's round data (and `answer == 0` when stale).
- **`supportsInterface`** returns true for `IPriceFeedCustom` and `IERC165`.

### B.3.2 Fork test

File: `test/prices/protocols/fork/<Asset>_Price.fork.t.sol`.

Cover, against the real Chainlink + rate provider at a pinned block:

- Deploy the feed, call `getLatestPrice`, assert price is in a reasonable range (e.g., $0.95–$1.05 for a USD-pegged asset, or compare to a hand-computed reference).
- `stale == false` at the pinned block.

Run with `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_Price*"`.

---

## B.4 Wire chain config

Two files. First, the custom-feed deploy config — `script/config/contracts-deployment-config/custom-price-feeds/<chainId>.json`, keyed by feed name (top-level; no chainId wrapper):

```json
{
  "myAsset": {
    "enabled": true,
    "constructor": {
      "myAsset": "0x...",
      "rateProvider": "0x...",
      "usdChainlinkOracle": "0x...",
      "usdChainlinkHeartbeat": "3600"
    }
  }
}
```

Second, the asset entry — `script/config/nav-config/assets-and-price-feeds/<chainId>.json`, with a `Custom` feed that references the custom feed by name:

```json
{
  "MYASSET": {
    "address": "0x...",
    "priceFeeds": [
      {
        "type": "Custom",
        "feed": "myAsset",
        "heartbeat": 3600
      }
    ]
  }
}
```

Note: a `Custom` feed entry references the deployed feed by `"feed": "<name>"` (the on-chain address is resolved post-deploy from `deployments/<chainId>.json .customPriceFeeds.<name>`), whereas `Chainlink`/`Redstone`/`API3` entries carry the feed `"address"` directly. For Chainlink-only assets (path A), use `type: "Chainlink"` with the proxy `address` — no `contracts-deployment-config/custom-price-feeds` entry needed at all.

There is no `_symbolsForChain` list to update — both `RegisterAssets.s.sol` and the integration harness read symbols from `nav-config/assets-and-price-feeds/<chainId>.json`, so adding the asset there is enough. In the integration harness `test/integration/IntegrationFromConfigBase.fork.sol`, also add `_tryDeployPriceFeed("myAsset", _deployMyAsset)` in `_deployAllPriceFeeds()` (under the branch for the chains where the feed applies), along with the corresponding `_deployMyAsset()` function that reads constructor params via `ConfigReader.readPriceFeedParam`. See the §B.6 checklist for the full set of wiring touchpoints.

---

## B.5 Deploy and register

Custom feeds are deployed by `script/deploy/03_DeployPriceFeeds.s.sol`. The script dispatches per chain (`_deployMainnetPriceAdapters`, `_deployArbitrumPriceAdapters`, etc.), and within each dispatch calls a hardcoded `_deploy<Asset>()` helper gated by `ConfigReader.isAdapterEnabled(vm, chainId, "priceFeeds", "<name>")` — so you must add a `_deploy<Asset>()` function and wire it into the relevant chain's dispatch block (and import the contract) before your entry from §B.4 is picked up. Each helper reads its constructor params via `ConfigReader.readPriceFeedParam` and writes the deployed feed address into `deployments/<chainId>.json .customPriceFeeds.<name>` via `ConfigReader.writeAdapterAddress`. The asset's `Custom` entry then references the feed by `feed: "<name>"`, and `RegisterAssets.s.sol` (below) resolves the on-chain address from the deployments file at registration time (no manual copy needed).

After deploy, register the asset on `NAVCalculator` via Safe TX (MANAGER-gated):

```bash
forge script script/manage/RegisterAssets.s.sol \
  --rpc-url <RPC> \
  --sig 'run()'
```

This emits a Safe TX bundle for `NAVCalculator.registerAsset(asset, customFeed, PriceType.Custom, heartbeat)` (first feed) or `NAVCalculator.addPriceFeed(asset, feed, priceType, heartbeat)` for pre-registered assets needing only a feed added. Owners sign and execute on the chain's admin Safe.

Verify:

```bash
cast call $NAV_CALCULATOR "latestPrice(address)(int256,uint8,bool)" $myAsset --rpc-url $RPC
```

Expect `(price > 0, decimals, false)` at a fresh block.

## B.6 Open the PR

PR checklist:

- [ ] `forge build` clean
- [ ] `forge test --match-path "test/prices/protocols/<Asset>_Price*"` clean
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_Price*"` clean
- [ ] `nav-config/assets-and-price-feeds/<chainId>.json` updated for every chain where the feed applies (assets with `priceFeeds` arrays) + `contracts-deployment-config/custom-price-feeds/<chainId>.json` constructor sections for any Custom feeds
- [ ] `_tryDeployPriceFeed` call and `_deploy<Asset>()` function added to `test/integration/IntegrationFromConfigBase.fork.sol`
- [ ] `_deploy<Asset>()` function and dispatch block added to `script/deploy/03_DeployPriceFeeds.s.sol`
- [ ] PR description includes: which asset, which inputs (rate provider + Chainlink feed), expected price range at the test block, any L2-specific considerations

---

## C. Adding a redundant feed to an existing asset

Use this path when an asset is already registered and you want to add a second (or third) feed for redundancy — e.g., adding a Redstone or API3 feed alongside an existing Chainlink feed.

### C.1 Find the feed

**Redstone Classic Push** — browse [app.redstone.finance/push-feeds](https://app.redstone.finance/push-feeds) for the asset and chain. Copy the proxy address and note the heartbeat.

**API3** — find the `Api3ReaderProxyV1` proxy address for the asset on [market.api3.org](https://market.api3.org).

### C.2 Add the feed via Safe TX

```solidity
NAVCalculator.addPriceFeed(asset, feedAddress, PriceType.Redstone /* or API3 */, heartbeat)
```

This appends the feed to the asset's array. On the next read, `Prices._selectFeed` picks the freshest non-stale survivor across all feeds.

### C.3 Verify

```bash
cast call $NAV_CALCULATOR "getPriceFeedCount(address)(uint256)" $ASSET --rpc-url $RPC
cast call $NAV_CALCULATOR "getPriceFeedAt(address,uint256)(address,uint8,uint8,uint256)" $ASSET 1 --rpc-url $RPC
```

### C.4 Remove a superseded feed

To remove an old feed: `NAVCalculator.removePriceFeed(asset, oldFeedAddress)` (MANAGER). Cannot remove the last remaining feed — add the replacement first.
