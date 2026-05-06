# How to add a new custom price feed

End-to-end walkthrough for adding a custom price oracle (a contract implementing `IPriceFeedCustom`). For Chainlink-only feeds, you do not need a custom contract — just register the asset directly with `priceType = Chainlink`.

Read [`src/prices/PRICE_ADAPTERS.md`](../../src/prices/PRICE_ADAPTERS.md) first if you have not — it's the framework reference; this is the recipe.

---

## 0. Decide whether you actually need a custom feed

You need a custom feed if **any** of these are true:

- The asset is a yield-bearing wrapper of another asset (e.g., sDAI, sUSDe, sUSDS) and the price is `(rate × underlying/USD)`.
- The asset is a (re)staking receipt token whose rate is exposed on-chain (cbETH, wstETH, weETH, rETH, rsETH, ezETH).
- There is no Chainlink USD feed for the asset, but you can derive the price from two existing feeds (use `CrossRate_Price`).

If a Chainlink USD feed exists and is canonical, use Chainlink directly. Don't roll a custom feed for no reason.

---

## 1. Pick the recipe

| Pattern | Existing reference | When to use |
|---|---|---|
| `(rate × USD)` from a single Chainlink feed | `src/prices/protocols/sDAI_Price.sol` (DAI/USD × DSR `chi`) | Yield-bearing wrappers with an on-chain `chi`/`rate` field |
| LST/LRT receipt token with `getExchangeRate`-style method | `src/prices/protocols/wstETH_Price.sol`, `rETH_Price.sol` | Liquid staking tokens whose redeem rate is exposed on-chain |
| L2 mirror of an L1 rate | `src/prices/protocols/wstETH_L2_Price.sol`, `cbETH_L2_Price.sol` | Same asset, but the canonical rate lives on L1; reads a Chainlink-secured rate feed on L2 instead |
| Two Chainlink feeds composed | `src/prices/protocols/CrossRate_Price.sol` | A/B × B/C when there's no direct A/USD feed |
| Basket / aggregator | `src/prices/protocols/ETHPlus_Price.sol` | Reserve-style RTokens or other basket-derived prices |

Copy the closest match and rename. Don't deviate from the structure unless you need to — every feed in `src/prices/protocols/` follows the same shape.

---

## 2. Write the contract

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

## 3. Tests

### 3.1 Unit test

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

### 3.2 Fork test

File: `test/prices/protocols/fork/<Asset>_Price.fork.t.sol`.

Cover, against the real Chainlink + rate provider at a pinned block:

- Deploy the feed, call `getLatestPrice`, assert price is in a reasonable range (e.g., $0.95–$1.05 for a USD-pegged asset, or compare to a hand-computed reference).
- `stale == false` at the pinned block.

Run with `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_Price*"`.

---

## 4. Wire chain config

File: `script/config/assets.json`. Add an entry under `priceFeeds.<assetSymbol>.<chainId>`:

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
      "oracle": "0x...(deployed-feed-address)",
      "heartbeat": 0
    }
  }
}
```

For Chainlink-only assets, set `"type": "Chainlink"` and point `oracle` at the Chainlink aggregator. Heartbeat applies to Chainlink; for custom feeds it's stored but unused by `Prices`.

Add the symbol to `_symbolsForChain(chainId)` in `script/manage/RegisterAssets.s.sol` so the registration script picks it up.

---

## 5. Deploy and register

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

## 6. Open the PR

PR checklist:

- [ ] `forge build` clean
- [ ] `forge test --match-path "test/prices/protocols/<Asset>_Price*"` clean
- [ ] `FOUNDRY_PROFILE=slow forge test --match-path "test/prices/protocols/fork/<Asset>_Price*"` clean
- [ ] `assets.json` updated for every chain where the feed applies
- [ ] `_symbolsForChain` updated in `script/manage/RegisterAssets.s.sol`
- [ ] PR description includes: which asset, which inputs (rate provider + Chainlink feed), expected price range at the test block, any L2-specific considerations
