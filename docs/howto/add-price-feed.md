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

### A.2 Add to `assets.json`

Under `tokens.<chainId>.<SYMBOL>`:

```json
"WBTC": {
  "address": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
  "type": "Chainlink",
  "pricefeed": "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c",
  "heartbeat": 3600
}
```

Rules:
- `type` must be `"Chainlink"`.
- `pricefeed` is the Chainlink **proxy** address (not the aggregator).
- `heartbeat` is in seconds. Use the value from the feed page.

### A.3 Add to both `_symbolsForChain` lists

There are two independent `_symbolsForChain(chainId)` functions that must both be updated:

1. **`script/manage/RegisterAssets.s.sol`** — controls which assets get registered on-chain via the management TX.
2. **`test/integration/IntegrationFromConfigBase.fork.sol`** — controls which assets the integration test registers on the fork. Missing a symbol here means the price feed is never deployed in the test and the asset is silently unpriced.

In each, increase the array size by 1 and append the symbol:

```solidity
string[] memory s = new string[](30);
// ... existing entries ...
s[29] = "WBTC";
return s;
```

### A.4 Add constant to `test/ChainlinkPriceFeeds.sol` (if not already present)

```solidity
function btcUsdEthMainnet() internal pure returns (address) {
    return 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
}
```

Check for an existing entry before adding. The constant is used in fork tests and the NAVCalculator harness — adding a duplicate will break compilation.

### A.5 Register via deploy script

No new contract to deploy. The `RegisterAssets.s.sol` script reads `assets.json.tokens` and calls `NAVCalculator.registerAsset(token, feed, PriceType.Chainlink, heartbeat)` for each symbol returned by `_symbolsForChain`. Run it as part of the next deployment cycle or management TX.

### A.6 Verify

```bash
cast call $NAV_CALCULATOR "latestPrice(address)(int256,uint8,bool)" $TOKEN_ADDRESS --rpc-url $RPC
```

Expect `(price > 0, 8, false)`.

---

## B. Custom price feed (requires a new contract)

Use this path when **any** of these are true:

- The asset is a yield-bearing wrapper of another asset (e.g., sDAI, sUSDe, sUSDS) and the price is `(rate × underlying/USD)`.
- The asset is a (re)staking receipt token whose rate is exposed on-chain (cbETH, wstETH, weETH, rETH, rsETH, ezETH).
- There is no Chainlink USD feed for the asset, but you can derive the price from two existing feeds (use `CrossRate_Price`).

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
    uint8 private _decimals;

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

    function getLatestPrice() external view returns (uint256 price, bool stale) {
        (, int256 usdPrice,, uint256 updatedAt,) = USD_CHAINLINK_ORACLE.latestRoundData();
        if (usdPrice <= 0) return (0, true);
        if (block.timestamp - updatedAt > USD_CHAINLINK_HEARTBEAT) stale = true;

        uint256 rate = _readRate(); // protocol-specific
        if (rate == 0) return (0, true);

        price = uint256(usdPrice) * rate / (10 ** RATIO_DECIMALS);
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
- **Stale heartbeat** (`updatedAt + heartbeat + 1`) → `stale = true`, price still set.
- **Zero or negative rate** → `(0, true)`.
- **Constructor zero-address guards** for every immutable.
- **Constructor zero-heartbeat guard**.
- **`decimals()`** returns the Chainlink feed's decimals.
- **`underlyingAssetSupported()`** returns the asset address.
- **`supportsInterface`** returns true for `IPriceFeedCustom` and `IERC165`.

### B.3.2 Fork test

File: `test/prices/protocols/fork/<Asset>_Price.fork.t.sol`.

Cover, against the real Chainlink + rate provider at a pinned block:

- Deploy the feed, call `getLatestPrice`, assert price is in a reasonable range (e.g., $0.95–$1.05 for a USD-pegged asset, or compare to a hand-computed reference).
- `stale == false` at the pinned block.

Run with `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_Price*"`.

---

## B.4 Wire chain config

File: `script/config/assets.json`. Add an entry under `priceFeeds.<assetSymbol>.<chainId>` (for the custom price oracle constructor args):

```json
"priceFeeds": {
  "myAsset": {
    "1": {
      "enabled": true,
      "constructor": {
        "myAsset": "0x...",
        "rateProvider": "0x...",
        "usdChainlinkOracle": "0x...",
        "usdChainlinkHeartbeat": "3600"
      }
    }
  }
}
```

And add the token entry under `tokens.<chainId>.<symbol>`:

```json
"tokens": {
  "1": {
    "MYASSET": {
      "address": "0x...",
      "type": "Custom",
      "pricefeed": "0x...(deployed-feed-address)",
      "heartbeat": 3600
    }
  }
}
```

Note: the field is `pricefeed` (lowercase), not `oracle`. For Chainlink-only assets (path A), `type` is `"Chainlink"` and `pricefeed` is the Chainlink proxy address — no `priceFeeds` constructor entry needed at all.

Add the symbol to `_symbolsForChain(chainId)` in **both** `script/manage/RegisterAssets.s.sol` (production registration) and `test/integration/IntegrationFromConfigBase.fork.sol` (integration test). Also add `_tryDeployPriceFeed("myAsset", _deployMyAsset)` in `_deployAllPriceFeeds()` in the integration test, along with the corresponding `_deployMyAsset()` function that reads constructor params via `ConfigReader.readPriceFeedParam`. See §B.3.2 for where to slot these.

---

## B.5 Deploy and register

Custom feeds are deployed by `script/deploy/03_DeployPriceFeeds.s.sol`, which iterates `assets.json.priceFeeds` and calls `_deployIfEnabled` per entry — your new entry from §4 above will get picked up automatically. The deployed feed address is written back into `chains/<chainId>.json.priceFeeds.<adapterName>.deployed` and (on a Safe-TX-only flow) you copy it into `assets.json.tokens.<chainId>.<symbol>.pricefeed`.

After deploy, register the asset on `NAVCalculator` via Safe TX (MANAGER-gated):

```bash
forge script script/manage/RegisterAssets.s.sol \
  --rpc-url <RPC> \
  --sig 'run()'
```

This emits a Safe TX bundle for `NAVCalculator.registerAsset(asset, customFeed, PriceType.Custom, 0)` (or `setPriceFeed(asset, newFeed, ...)` for pre-registered assets needing only a feed swap). Owners sign and execute on the chain's admin Safe.

Verify:

```bash
cast call $NAVCalculator "latestPrice(address)(int256,uint8,bool)" $myAsset --rpc-url $RPC
```

Expect `(price > 0, decimals, false)` at a fresh block.

---

## B.6 Open the PR

PR checklist:

- [ ] `forge build` clean
- [ ] `forge test --match-path "test/prices/protocols/<Asset>_Price*"` clean
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_Price*"` clean
- [ ] `assets.json` updated for every chain where the feed applies (`tokens` + `priceFeeds` constructor sections)
- [ ] `_symbolsForChain` updated in **both** `script/manage/RegisterAssets.s.sol` and `test/integration/IntegrationFromConfigBase.fork.sol`
- [ ] `_tryDeployPriceFeed` call and `_deploy<Asset>()` function added to `IntegrationFromConfigBase.fork.sol`
- [ ] `_deploy<Asset>()` function and dispatch block added to `script/deploy/03_DeployPriceFeeds.s.sol`
- [ ] PR description includes: which asset, which inputs (rate provider + Chainlink feed), expected price range at the test block, any L2-specific considerations
