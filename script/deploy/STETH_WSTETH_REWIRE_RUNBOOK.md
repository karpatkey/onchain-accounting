# stETH / wstETH price-feed rewire runbook (nav-v2-legacy)

## What & why

The ETH-denominated NAV of the ETH Alpha fund was volatile because **stETH** was priced via the raw
`STETH/USD` Chainlink feed: when NAV is quoted in ETH it divides each asset's USD price by `ETH/USD`, so
stETH became `STETH/USD ÷ ETH/USD` — two independent feeds whose should-be-flat ratio jitters. **wstETH**
had a related accuracy bug: it priced as `stEthPerToken × ETH/USD`, implicitly assuming `stETH = ETH` 1:1.

This change prices both off the **stETH/ETH** Chainlink feed so `ETH/USD` cancels in the ETH-denominated
NAV and the real depeg is reflected:

- **stETH** → `CrossRatePriceAdapter`: `stETH/USD = (ETH/USD) × (stETH/ETH)` (no new contract — reuses the
  generic adapter).
- **wstETH** → `wstETH_PriceOracle` (formula fixed): `wstETH/USD = stEthPerToken × (stETH/ETH) × (ETH/USD)`
  — same cross-rate pattern the L2 variant already uses.

Feeds (mainnet): `ETH/USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`, `stETH/ETH =
0x86392dC19c0b719886221c78AB11eb8Cf5c52812`.

This is the **nav-v2-legacy** (live-prod) track. Mirror onto `main` for the future NAV v2 (the PR #52
pattern) once landed here.

> **Status (2026-06-11):** team green-lit (Sisyphos + Ismael). The full deploy + rewire below was
> validated end-to-end on a mainnet anvil fork against the live NAV `0x07938ddD…` — both feeds deploy, the
> security-council Safe (holds `MANAGER`) executes both `setPriceFeed` calls, and the new feeds price
> correctly. Safe to execute on mainnet.

## Verified live state (mainnet, 2026-06-11)

Read directly from the live NAV `0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19`:

| Asset | Live registered feed | Type | Note |
|---|---|---|---|
| stETH | `0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8` (raw STETH/USD Chainlink) | Chainlink | the two-feed jitter source |
| wstETH | `0xAc8ef2dc1Ee81f30A3249fcAb6789ed85Fd189Cd` (the **v1** oracle) | Custom | see note below |

> **Pre-existing wstETH misregistration (not introduced here):** the live v2 NAV prices wstETH through the
> **v1** oracle `0xAc8ef2dc…`. The v2 oracle (`0xc3E04720338BC8AddC335764914b7602DD11e79f`, recorded in
> `chains/1.json` and the Notion oracle DB as the current v2 deployment) was deployed but **never wired into
> the live NAV**. This rewire replaces the live `0xAc8ef2dc…` directly with the corrected oracle, so it also
> resolves that drift — the never-wired `0xc3E0472…` is bypassed entirely.

## 1. Deploy prep (config)

`03_DeployPriceFeeds.s.sol` deploys a feed only if its `priceFeeds.<name>.deployed` is empty. So, before
deploying:

- `chains/1.json` → add `"stETH": { "deployed": "" }` under `priceFeeds` (no entry exists yet).
- `chains/1.json` → clear `priceFeeds.wstETH.deployed` (currently records the v2 oracle
  `0xc3E04720338BC8AddC335764914b7602DD11e79f`) to force a fresh deploy of the corrected oracle. Note this is
  config bookkeeping — the **live** NAV feed being replaced is the v1 oracle `0xAc8ef2dc…` (see "Verified live
  state" above), not `0xc3E0472…`.

The constructor params are already in `assets.json` (`priceFeeds.stETH.1` and `priceFeeds.wstETH.1`).

## 2. Deploy the new feeds (deployer EOA — no role)

```bash
# from the deployer EOA (0xAa5A…4F72), against mainnet
forge script script/deploy/03_DeployPriceFeeds.s.sol:DeployPriceFeeds \
  --rpc-url "$MAINNET_URL" --private-key "$DEPLOYER_PK" --broadcast --verify
```

This deploys the stETH `CrossRatePriceAdapter` and the corrected `wstETH_PriceOracle`, writing both
addresses back into `chains/1.json` (`priceFeeds.stETH.deployed`, `priceFeeds.wstETH.deployed`). Record
them — call these `STETH_CROSSRATE` and `WSTETH_NEW`.

## 3. Verify the deployed feeds (read-only)

```bash
# stETH cross-rate ≈ ETH/USD × stETH/ETH (8 dp); should be ~ the live stETH USD price
cast call $STETH_CROSSRATE "getLatestPrice()(uint256,bool)" --rpc-url "$MAINNET_URL"
# wstETH new ≈ stEthPerToken × stETH/ETH × ETH/USD (8 dp); strictly below the old stEthPerToken×ETH/USD
cast call $WSTETH_NEW       "getLatestPrice()(uint256,bool)" --rpc-url "$MAINNET_URL"
cast call $STETH_CROSSRATE "underlyingAssetSupported()(address)" --rpc-url "$MAINNET_URL"  # == stETH
cast call $WSTETH_NEW       "underlyingAssetSupported()(address)" --rpc-url "$MAINNET_URL"  # == wstETH
```

> On live mainnet `getLatestPrice()` returns `stale=false` (Chainlink updates within the heartbeat). On a
> time-drifted anvil fork it can read `stale=true` purely because the fork froze the feed `updatedAt` while
> `block.timestamp` advanced past the heartbeat — a fork artifact, not a feed problem.

## 4. Rewire the live NAVCalculator (security-council Safe — holds MANAGER)

`setPriceFeed` overwrites an asset's registered feed in one call (this is the "remove current + wire new").
`PriceType.Custom = 1`. For Custom feeds the heartbeat param is unused (the adapter reports its own
staleness via the `stale` flag), so pass the `type(uint256).max` sentinel used by the other Custom assets.

NAVCalculator (live): `0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19`.

```
MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935

# stETH: raw STETH/USD Chainlink  ->  CrossRate Custom feed
setPriceFeed(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, STETH_CROSSRATE, 1 /*Custom*/, MAX_UINT)

# wstETH: live v1 oracle 0xAc8ef2dc (old formula)  ->  corrected Custom feed
setPriceFeed(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, WSTETH_NEW,      1 /*Custom*/, MAX_UINT)
```

(Encode as two Safe transactions to the NAVCalculator. The deploy flow is EOA-only for deploy; only the
registration/rewire goes through the Safe, which holds MANAGER.)

## 5. Post-rewire verification

```bash
# Each asset now resolves through the new feed; price returns fresh (stale=false).
cast call $NAV "getPrice(address)(uint256,bool)" 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 --rpc-url "$MAINNET_URL"
cast call $NAV "getPrice(address)(uint256,bool)" 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 --rpc-url "$MAINNET_URL"
# ETH-denominated NAV for the ETH Alpha fund safe should no longer jitter on the stETH leg.
cast call $NAV "getAccountNav(address,address)" 0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 --rpc-url "$MAINNET_URL"
```

Then update `assets.json` `tokens.1.stETH` to `type: "Custom"` (pricefeed = `STETH_CROSSRATE`, heartbeat =
MAX sentinel) so a future fresh redeploy registers it correctly, and commit the populated `chains/1.json`
addresses (same as the #49 stopgap did for its adapters).

## App-side (not this repo)

Ismael's analytics should consume the **native (ETH-quoted) NAV** returned by `getAccountNav(account, WETH)`
rather than converting USD→ETH app-side — the ETH/USD cancellation that removes the jitter happens *inside*
`_priceConversion`, so the fix only takes full effect when the division is done on-chain.

## Tests backing this change

- `test/prices/protocols/fork/wstETH_Price.fork.t.sol` — in-EVM ground truth + new price strictly below the
  old 1:1 value.
- `test/prices/protocols/fork/stETH_CrossRate_Price.fork.t.sol` — price == ETH/USD × stETH/ETH, the
  ETH-quote cancellation recovers the stETH/ETH feed exactly, and the raw-STETH/USD-implied ratio differs
  (the removed two-feed gap).
- `test/prices/protocols/wstETH_Price.t.sol` — constructor guards (5-arg).

## Out of scope / deferred

- **L2 wstETH** (`wstETH_L2_PriceOracle`) already uses `(wstETH/ETH feed) × (ETH/USD)` — the correct
  cross-rate pattern — so no change is needed there.
- **Track B** (`main`): re-apply this onto main's structure for the future NAV v2 redeploy.
