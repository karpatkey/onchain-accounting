# How to add a new price feed

End-to-end walkthrough for adding price support for a new asset — either via a Chainlink feed directly or a custom price oracle (`ICustomPriceFeed`).

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
  "accrualKind": "None",
  "priceFeeds": [
    {
      "type": "Chainlink",
      "address": "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c",
      "heartbeat": 3600
    }
  ]
}
```

> **`accrualKind` is REQUIRED on every asset, with no default** — exactly one of `"None"` | `"Rebasing"` |
> `"Appreciating"`, case-sensitive. An absent, empty or unrecognized value **aborts that chain's `08`
> deploy** rather than defaulting. Balance grows → `Rebasing`; exchange rate grows → `Appreciating`;
> neither → `None`. Most assets you add a feed for are `"None"`; a yield-bearing wrapper (sDAI, wstETH,
> sUSDe) is `"Appreciating"`.
>
> **There is deliberately NO `pegKind` key — do not add one.** The peg axis is *derived*, not stored: an
> asset is `Pegged` exactly when it carries a `pegToleranceBps > 0`. Nothing validates the field set, so a
> stray `pegKind` would be **silently ignored** rather than rejected.
>
> Full semantics live in [`script/config/CONFIG_GUIDE.md`](../../script/config/CONFIG_GUIDE.md). The key is
> consumed by `08_DeployAssetKindRegistry`; if you need to know whether a given checkout has that step, ask
> the checkout — `git ls-tree HEAD script/deploy/08_DeployAssetKindRegistry.s.sol`, which prints a line if
> present and nothing if absent (append `| grep -q .` if you want the exit code to carry the answer; bare
> `ls-tree` exits `0` either way) — rather than trusting a date written in this file.

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

No new contract to deploy. The `RegisterAssets.s.sol` script reads each chain's assets from `nav-config/assets-and-price-feeds/<chainId>.json` (`getAssetSymbols`) and routes the first feed through `AssetKindRegistry.registerAsset(token, feed, PriceType.Chainlink, heartbeat, accrualKind, labels)` — which forwards to `NAVCalculator.registerAsset` in the same transaction, so the asset is registered, classified and labelled atomically — then calls `NAVCalculator.addPriceFeed(...)` for the rest. `08_DeployAssetKindRegistry` must have run first: with no registry recorded for the chain the script reverts `AssetKindRegistryNotDeployed` rather than falling back to the NAV. Run it as part of the next deployment cycle or management TX.

To add a **second or third feed** for an already-registered asset (redundancy), call `NAVCalculator.addPriceFeed(asset, feed, PriceType.Chainlink, heartbeat)` via the MANAGER Safe. This appends the feed to the asset's array; both participate in the freshest-wins selection. See §C below.

### A.6 Verify

```bash
cast call $NAV_CALCULATOR "latestPrice(address)(int256,uint8,bool,bool)" $TOKEN_ADDRESS --rpc-url $RPC
```

Expect `(price > 0, 8, false, false)` — the fourth return is the `irregular` divergence/peg flag.

---

## B. Custom price feed (requires a new contract)

Use this path when there is no canonical Chainlink USD feed but the price is derivable on-chain — start with the decision check in §B.0.

### B.0 Decide whether you actually need a custom feed

You need a custom feed if **any** of these are true:

- The asset is a yield-bearing wrapper of another asset (e.g., sDAI, sUSDe, sUSDS) and the price is `(rate × underlying/USD)`.
- The asset is a (re)staking receipt token whose rate is exposed on-chain (cbETH, wstETH, weETH, rETH, rsETH, ezETH).
- There is no Chainlink USD feed for the asset, but you can derive the price from two existing feeds (use `CrossRateCustomPriceFeed`).

If a Chainlink USD feed exists and is canonical, use Chainlink directly. Don't roll a custom feed for no reason.

### B.1 Pick the recipe

| Pattern | Existing reference | When to use |
|---|---|---|
| `(rate × base/USD)`, base/USD read from the NAV | `src/prices/protocols/ankrETH_CustomPriceFeed.sol` (ETH/USD ÷ `ratio()`) | Wrappers with an on-chain `rate`/`ratio` field and no ERC-4626 surface |
| LST/LRT receipt token with `getExchangeRate`-style method (extends `BaseCustomPriceFeed`, implement only `_rate()`) | `src/prices/protocols/rETH_CustomPriceFeed.sol`, `cbETH_CustomPriceFeed.sol` | Liquid staking tokens whose redeem rate is exposed on-chain as an 18-decimal rate |
| L2 mirror of an L1 rate | `src/prices/protocols/wstETH_L2_CustomPriceFeed.sol`, `cbETH_L2_CustomPriceFeed.sol` | Same asset, but the canonical rate lives on L1; reads a Chainlink-secured rate feed on L2 instead |
| Chainlink `Y/X` rate feed × NAV-sourced `X/USD` | `src/prices/protocols/CrossRateCustomPriceFeed.sol` | Y/X × X/USD when there's no direct Y/USD feed |
| Basket / aggregator | `src/prices/protocols/ETHPlus_CustomPriceFeed.sol` | Reserve-style RTokens or other basket-derived prices |

Copy the closest match and rename. Don't deviate from the structure unless you need to — every feed in `src/prices/protocols/` follows the same shape.

### B.2 Write the contract

File: `src/prices/protocols/<Asset>_CustomPriceFeed.sol` (suffix `_L2_CustomPriceFeed` for L2-specific variants, e.g. `wstETH_L2_CustomPriceFeed.sol`).

For the common "18-decimal on-chain rate × NAV-sourced base/USD" case (wstETH, weETH, eETH, rETH, cbETH, ezETH, rsETH, ETHx, osToken), extend `src/prices/BaseCustomPriceFeed.sol` and implement only `_rate()` — the base/USD read (via `NavBaseUsdLib`), staleness gate, decimals, `latestRoundData`, `governingFeedFreshness`, and the `rate × base8 / 1e18` math live in the base. Feeds with an `asset/base` Chainlink **rate** leg (weETH_L2, cbETH_L2, wstETH_L2, rsETH_L2, and the generic cross-rate — use `TwoFeedChainlinkPriceFeed` / `CrossRateCustomPriceFeed`) or an ERC-4626 vault rate (use `ERC4626VaultRatePriceFeed`) get their surface from those bases; a basket (ETHPlus) or an inverted rate (ankrETH — its `ratio()` is ankrETH-per-ETH, so it enters as a denominator rather than as `BaseCustomPriceFeed`'s direct multiplier) stays bespoke and follows the self-contained skeleton below. **In every case the `base/USD` term comes from the NAV** (`NavBaseUsdLib.baseUsd(nav, baseAsset)`), never an embedded Chainlink oracle — see [ADR 0019](../decisions/0019-nav-sourced-base-price.md).

> **ERC-4626 manipulation-resistance check (before wiring a vault to `ERC4626VaultRatePriceFeed`):** the base reads live `convertToAssets()` on every read with no TWAP or bounds check, so it inherits the vault's share-price manipulation surface. Confirm the candidate vault's `totalAssets()` is **not naively `balanceOf(vault)`-based** — a raw balance-of vault can be donation/inflation-spiked within a single block, letting an attacker over-value shares (and therefore over-report NAV). The vaults wired today (sUSDe, sGHO, sUSDS, sXDAI, syrupUSDC, RWIV) use time-accrued exchange rates, not balance-of accounting; a new vault that does not must not use this base without a manipulation-resistant wrapper.

Skeleton (bespoke on-chain-rate pattern, à la `ankrETH_CustomPriceFeed.sol`; adjust for LST/LRT or cross-rate):

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {INavSourcedPriceFeed} from "src/prices/INavSourcedPriceFeed.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NavBaseUsdLib} from "src/prices/NavBaseUsdLib.sol";
import {AddressCheckLib} from "src/utils/AddressCheckLib.sol";
import {OracleArgumentChecks} from "src/utils/OracleArgumentChecks.sol";
import {NAV_DECIMALS} from "src/constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title <Asset> Custom Price Oracle
/// @notice Returns the USD price of <Asset> as `<rate> * base/USD`, base/USD read from the NAV (ADR 0019).
/// @author kpk
contract MyAsset_CustomPriceFeed is ICustomPriceFeed, INavSourcedPriceFeed {
    using Math for uint256;

    address public immutable MY_ASSET;
    address public immutable RATE_PROVIDER;
    /// @notice NAVCalculator (proxy) the base/USD price is read from via its selector.
    INAVCalculator public immutable NAV;
    /// @notice Base asset (e.g. WETH) whose NAV-selected USD price scales the rate. MUST be priced by DIRECT feeds,
    ///         never by a NAV-sourced custom feed (NavBaseUsdLib circularity invariant).
    address public immutable override BASE_ASSET;
    uint8 public constant RATIO_DECIMALS = 18; // adjust per protocol's rate precision
    uint8 private immutable _decimals;

    constructor(address myAsset_, address rateProvider_, address nav_, address baseAsset_) {
        MY_ASSET = OracleArgumentChecks.assertERC20Address(myAsset_);
        RATE_PROVIDER = OracleArgumentChecks.assertNonZeroAddress(rateProvider_);
        AddressCheckLib.requireContract(nav_, "NAVCalculator");
        NAV = INAVCalculator(nav_);
        BASE_ASSET = OracleArgumentChecks.assertERC20Address(baseAsset_);
        _decimals = NAV_DECIMALS;
    }

    function _compute()
        private
        view
        returns (uint256 price, bool stale, uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Base/USD from the NAV's selector (normalized to NAV_DECIMALS = 8). Stale on genuine base-feed staleness,
        // NOT on L2 sequencer-down alone (NavBaseUsdLib un-folds pd.sequencerDown — ADR 0019). roundId/startedAt/
        // answeredInRound have no meaning for a NAV read.
        uint256 base8;
        (base8, stale, updatedAt) = NavBaseUsdLib.baseUsd(NAV, BASE_ASSET);
        if (stale) return (0, true, 0, 0, updatedAt, 0);

        uint256 rate = _readRate(); // protocol-specific, 18-decimal base-token per 1 underlying
        if (rate == 0) return (0, true, 0, 0, updatedAt, 0);

        price = rate.mulDiv(base8, 10 ** RATIO_DECIMALS, Math.Rounding.Floor);
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

    /// @notice The governing Chainlink leg's (updatedAt, heartbeat) — here the NAV's base/USD leg (ADR 0020).
    function governingFeedFreshness() external view returns (uint256 updatedAt, uint256 heartbeat) {
        return NavBaseUsdLib.baseFreshness(NAV, BASE_ASSET);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function _readRate() internal view returns (uint256) {
        // Read the protocol's rate (e.g., RATE_PROVIDER.chi(), wstETH.stEthPerToken(), rETH.getExchangeRate()).
    }
}
```

Conventions:

- **Pin every input as `immutable`** in the constructor. No setters.
- **Use `OracleArgumentChecks` / `AddressCheckLib`** for argument validation. Don't roll your own zero-checks.
- **Return `(0, true)` on any failure path**, never revert. Stale prices propagate into NAV via `NAV.stalePriceAssets`.
- **Implement `latestRoundData()` and `governingFeedFreshness()`** as well as `getLatestPrice()`. `ICustomPriceFeed` requires all three; `Prices.sol` reads price/staleness from `getLatestPrice()`, while `latestRoundData()` exists for callers inspecting freshness (return the worst-case `updatedAt`, or `(0, 0, 0, 0, 0)` for feeds with no trackable timestamp) and `governingFeedFreshness()` returns the matched `(updatedAt, heartbeat)` pair of whichever Chainlink leg has the largest age-to-heartbeat ratio, or `(0, 0)` when there is none ([ADR 0020](../decisions/0020-custom-feed-governing-leg-freshness.md)). Computing price and staleness from one private `_compute()` helper, as above, keeps them consistent.
- **`decimals()`** returns `NAV_DECIMALS` (8) — `NavBaseUsdLib` normalizes the base/USD to 8 dp, so the feed's output is always 8 dp.
- **Base/USD comes from the NAV** (`NavBaseUsdLib.baseUsd(NAV, BASE_ASSET)`), never an embedded Chainlink oracle ([ADR 0019](../decisions/0019-nav-sourced-base-price.md)). Its staleness (all-base-feeds-stale) is inherited for free; L2 **sequencer-down alone does not** zero the feed. `BASE_ASSET` MUST be a direct-feed asset (circularity invariant) — expose it as an immutable `BASE_ASSET()` (`INavSourcedPriceFeed`), since registration rejects a `Custom` feed that cannot answer (`CustomFeedBaseUnreadable`) or that answers with the very asset being registered (`CustomFeedBaseCircular`); a feed with no NAV dependency answers `address(0)`. Any `asset/base` Chainlink **rate** leg you read yourself (e.g. weETH/eETH) keeps its own heartbeat check; if the rate goes negative or zero, treat as stale.
- **One asset per contract.** Even if two assets share the same recipe, deploy two contracts.

### B.3 Tests

#### B.3.1 Unit test

File: `test/prices/protocols/<Asset>_CustomPriceFeed.t.sol`.

Cover, with a **mock NAV** (`Mock_NAVCalculator` — `setAssetPrice`/`setAssetStale`/`setSequencerDown`) as the base/USD source + a mocked rate provider:

- **Happy path**: known inputs → expected output (compute by hand).
- **Base stale** (`nav.setAssetStale(baseAsset, true)`) → returns `(0, true)`.
- **L2 sequencer-down alone** (`nav.setSequencerDown(baseAsset, true)`) → still returns the last price, **not** stale (base feed fresh) — the F1 behavior.
- **Zero or negative rate** → `(0, true)`.
- **Constructor zero-address guards** for every immutable (incl. `nav_` not-a-contract and `baseAsset_` not-an-ERC20).
- **`decimals()`** returns `NAV_DECIMALS` (8).
- **`underlyingAssetSupported()`** returns the asset address.
- **`latestRoundData()`** returns the round data (and `answer == 0` when stale).
- **`governingFeedFreshness()`** returns the governing leg's `(updatedAt, heartbeat)` — for a pure NAV-base feed, the base leg's pair; `(0, 0)` when there is no trackable Chainlink dependency.
- **`supportsInterface`** returns true for `ICustomPriceFeed` and `IERC165`.
- **(If you read an `asset/base` Chainlink rate leg yourself)** negative / stale rate feed → `(0, true)`.

#### B.3.2 Fork test

File: `test/prices/protocols/fork/<Asset>_CustomPriceFeed.fork.t.sol`.

Cover, against the real Chainlink + rate provider at a pinned block:

- Deploy the feed, call `getLatestPrice`, assert price is in a reasonable range (e.g., $0.95–$1.05 for a USD-pegged asset, or compare to a hand-computed reference).
- `stale == false` at the pinned block.

Run with `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_CustomPriceFeed*"`.

### B.4 Wire chain config

Two files. First, the custom-feed deploy config — `script/config/contracts-deployment-config/custom-price-feeds/<chainId>.json`, keyed by feed name (top-level; no chainId wrapper):

```json
{
  "myAsset": {
    "enabled": true,
    "constructor": {
      "myAsset": "0x...",
      "rateProvider": "0x...",
      "baseAsset": "0x..."
    }
  }
}
```

The `constructor` section carries the protocol-specific args + `baseAsset` (the base whose USD price scales the rate — WETH for ETH-based feeds, the stablecoin for vault feeds). It does **not** carry the NAV address or a base-oracle heartbeat: `03_DeployPriceFeeds` resolves the NAV proxy from `deployments/<chainId>.json` (`NAVCalculatorProxy`) and passes it in, and the base/USD staleness comes from the NAV. A feed with its own `asset/base` Chainlink **rate** leg additionally carries that leg's oracle + heartbeat (e.g. `weEthToEethChainlink` / `weEthToEethHeartbeat`).

Such a feed **also needs a `rateFeedGuard` block**, a sibling of `constructor` naming the rate-feed parameter plus the expected `description()` and a plausibility band:

```json
"rateFeedGuard": {
  "param": "weEthToEethChainlink",
  "description": "weETH / eETH Exchange Rate",
  "minRate1e18": "900000000000000000",
  "maxRate1e18": "1500000000000000000"
}
```

`03_DeployPriceFeeds` runs `RateFeedGuard.checkAll` before deploying anything, and it fails closed: an enabled instance whose constructor carries a rate-feed-shaped key (`yToXFeed`, or a key ending in `Chainlink`/`ChainlinkAddress`) with no `rateFeedGuard` reverts the whole script with `RateFeedGuardMissing`. Where the provider does not expose the pair (e.g. Redstone Classic Push, whose `description()` is a constant string), set `"description": "$UNVERIFIABLE"` and give a `descriptionUnverifiableReason` — the band is still enforced.

Second, the asset entry — `script/config/nav-config/assets-and-price-feeds/<chainId>.json`, with a `Custom` feed that references the custom feed by name:

```json
{
  "MYASSET": {
    "address": "0x...",
    "accrualKind": "Appreciating",
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

### B.5 Deploy and register

Custom feeds are deployed by `script/deploy/03_DeployPriceFeeds.s.sol`. The script dispatches per chain (`_deployMainnetPriceAdapters`, `_deployArbitrumPriceAdapters`, etc.), and within each dispatch calls a hardcoded `_deploy<Asset>()` helper gated by `ConfigReader.isAdapterEnabled(vm, chainId, "priceFeeds", "<name>")` — so you must add a `_deploy<Asset>()` function and wire it into the relevant chain's dispatch block (and import the contract) before your entry from §B.4 is picked up. Each helper reads its constructor params via `ConfigReader.readPriceFeedParam` and writes the deployed feed address into `deployments/<chainId>.json .customPriceFeeds.<name>` via `ConfigReader.writeAdapterAddress`. The asset's `Custom` entry then references the feed by `feed: "<name>"`, and `RegisterAssets.s.sol` (below) resolves the on-chain address from the deployments file at registration time (no manual copy needed).

After deploy, register the asset on `NAVCalculator` (MANAGER-gated) by running `RegisterAssets.s.sol`:

```bash
forge script script/manage/RegisterAssets.s.sol --rpc-url <RPC>
```

This plans `AssetKindRegistry.registerAsset(asset, customFeed, PriceType.Custom, heartbeat, accrualKind, labels)` (first feed) plus `NAVCalculator.addPriceFeed(asset, feed, priceType, heartbeat)` for any additional feeds (or for a pre-registered asset that only needs a feed added), followed by `setDivergenceTolerance` / `setPegTolerance` / `addMonitorFeed` for the asset's `divergenceToleranceBps`, `pegToleranceBps` and `monitorFeeds` config. It writes a Safe-TX batch to `safe-transactions/<chainId>-register-assets.json`; during the initial deploy flow the deployer EOA (which still holds `MANAGER`) broadcasts it directly with `--broadcast`, while after handoff the same batch is signed and executed on the security-council Safe.

Verify:

```bash
cast call $NAV_CALCULATOR "latestPrice(address)(int256,uint8,bool,bool)" $myAsset --rpc-url $RPC
```

Expect `(price > 0, decimals, false, false)` at a fresh block.

### B.6 Open the PR

PR checklist:

- [ ] `forge build` clean
- [ ] `forge test --match-path "test/prices/protocols/<Asset>_CustomPriceFeed*"` clean
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_CustomPriceFeed*"` clean
- [ ] `nav-config/assets-and-price-feeds/<chainId>.json` updated for every chain where the feed applies (assets with `priceFeeds` arrays) + `contracts-deployment-config/custom-price-feeds/<chainId>.json` constructor sections for any Custom feeds (plus a `rateFeedGuard` block for any feed taking a Chainlink rate leg — `03` reverts without one)
- [ ] `_tryDeployPriceFeed` call and `_deploy<Asset>()` function added to `test/integration/IntegrationFromConfigBase.fork.sol`
- [ ] `_deploy<Asset>()` function and dispatch block added to `script/deploy/03_DeployPriceFeeds.s.sol`
- [ ] PR description includes: which asset, which inputs (rate provider + Chainlink feed), expected price range at the test block, any L2-specific considerations

---

## C. Adding a redundant feed to an existing asset

Use this path when an asset is already registered and you want to add a second (or third) feed for redundancy — e.g., adding a Redstone or API3 feed alongside an existing Chainlink feed.

> **Check first that you want a *pricing* feed at all.** The intended production configuration is exactly **one** primary feed per asset, with redundancy carried by **monitor feeds** instead: `addMonitorFeed(asset, feed, priceType, heartbeat)` (after `setDivergenceTolerance`, which must be non-zero first) registers a feed that never prices the NAV and is read only to flag divergence from the primary. Config side, that is the asset's `monitorFeeds[]` + `divergenceToleranceBps`, not a second entry in `priceFeeds[]`. A second `priceFeeds[]` entry still works — it participates in the freshest-wins selection below — but it changes the price the NAV reports, which is usually not what "redundancy" is meant to do here.

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
