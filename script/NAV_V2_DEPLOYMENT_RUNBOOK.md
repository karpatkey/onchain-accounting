# NAV v2 Deployment Runbook

Step-by-step guide to deploy the NAV v2 system: NAVCalculator, BridgeEscrow, price oracles, and balance oracles across all chains.

---

## Current State (as of 2026-04-16)

### Already deployed (all 5 chains)

| Component | Address | Chains |
|-----------|---------|--------|
| NAVCalculator Implementation | `0x149aE89A9C1EdE914df158C18Ee4DCEeb0283541` | Mainnet, Arbitrum, Base, Gnosis (Optimism uses `0xf141...`) |
| NAVCalculator Proxy | `0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6` | All 5 |
| BridgeEscrow Implementation | `0x50FE322E01eB7e537418D6C90ea586063260454D` | Mainnet, Arbitrum, Base, Gnosis (Optimism uses `0xB933...`) |
| BridgeEscrow Proxy | `0x1ECAEa1C69c5A0b12139d44E6b7345D71FE68A19` | All 5 |
| ERC20Default Balance Adapter | `0xc07C999644D8A3A5e57B835Aa460016b89eBA21C` | All 5 |
| Bridge Adapters (CCIP, Across, Stargate, CCTP) | Various | Arbitrum only |

### Not yet deployed

- Custom price feed adapters (sDAI, sUSDe, wstETH, rETH, cbETH, weETH, rsETH, eETH, ezETH, sUSDS, syrupUSDC, sXDAI, LDO, ETHPlus, + L2 variants)
- Balance adapters (AaveV3, CompoundV3, SparkLend, MorphoVault, GearboxMarket, Cap, Curve, Convex, BalancerV3, Aura, StakeWiseV3, AaveV3SafetyModule, DaiDsr, SkySavingsUsds)
- Asset registration on NAVCalculator (tokens + price feeds)
- Balance oracle registration on NAVCalculator

### Supported chains

| Chain | ID | Config file |
|-------|----|-------------|
| Ethereum Mainnet | 1 | `script/config/chains/1.json` |
| Arbitrum | 42161 | `script/config/chains/42161.json` |
| Base | 8453 | `script/config/chains/8453.json` |
| Optimism | 10 | `script/config/chains/10.json` |
| Gnosis | 100 | `script/config/chains/100.json` |

---

## Phase 0: Prerequisites

### 0.1 Merge oracle migration PRs

The oracle migration PRs have all merged to `main`:

| PR | Branch | Content | Status |
|----|--------|---------|--------|
| [#10](https://github.com/karpatkey/onchain-accounting/pull/10) | `feat/pr1-surgical-changes` | Base infrastructure changes | Merged 2026-04-17 (`f97f264`) |
| [#11](https://github.com/karpatkey/onchain-accounting/pull/11) | `feat/pr2-price-oracles` | 16 custom price oracles + L2 deploy wiring | Merged 2026-04-17 (`369efd0`) |
| [#12](https://github.com/karpatkey/onchain-accounting/pull/12) | `feat/pr3-balance-oracles` | 5 new balance oracle adapters (MorphoVault, GearboxMarket, Cap, Curve, Convex) + per-instance deploy wiring | Merged 2026-04-17 (`f32d560`) |

### 0.2 Environment setup

Create or update `.env` in the project root:

```bash
# RPC (used by all chain configs via "$ALCHEMY" placeholder)
ALCHEMY_API_KEY=your_alchemy_key

# Deployer private key (used for scripts 03 and 04)
PRIVATE_KEY=0x...

# Explorer API keys (for contract verification)
ETHERSCAN_API_KEY=...
ARBISCAN_API_KEY=...
BASESCAN_API_KEY=...
OPTIMISM_ETHERSCAN_API_KEY=...
GNOSISSCAN_API_KEY=...
```

### 0.3 Run all tests

```bash
# Unit tests
forge test --no-match-path 'test/**/fork/*.sol'

# Fork tests (requires ALCHEMY_API_KEY)
forge test --match-path 'test/**/fork/*.sol'
```

Expected: all tests green. As of post-merge on `main` (2026-04-17): **716 unit + 271 fork**. Re-run locally to confirm counts haven't drifted.

### 0.4 Review chain configs

Verify that `addresses.safeMultisig`, `addresses.admin`, and `addresses.manager` are correct in each chain config file. These control who owns and manages the deployed contracts.

---

## Phase 1: Configure Price Feed Adapters

Price feed adapter configuration lives in `script/config/assets.json` under the `priceFeeds` section.

### 1.1 Add `priceFeeds` section to `assets.json`

The `priceFeeds` section must be added to `assets.json` with constructor parameters for each custom price adapter, organized by adapter name and chain ID. The deploy script (`03_DeployPriceFeeds.s.sol`) reads from this config.

> **Also pre-seed chain configs.** `ConfigReader.writeAdapterAddress(...)` writes deployed price-feed addresses to `script/config/chains/{chainId}.json` at `.priceFeeds.{adapter}.deployed`. Foundry `vm.writeJson` will not create a missing parent object, so each chain config must have a `"priceFeeds": {}` key (with per-adapter sub-objects for anything you want to deploy) before `03_DeployPriceFeeds.s.sol` runs. A stale comment in `ConfigReader.readAdapterParam` says "priceFeeds has been removed from chain config schema" — that comment is wrong; the script still writes there.

Structure:

```json
{
  "priceFeeds": {
    "<AdapterName>": {
      "<chainId>": {
        "enabled": true,
        "constructor": {
          "param1": "0x...",
          "param2": "3600"
        }
      }
    }
  }
}
```

### 1.2 Mainnet price feed adapters to configure

| Adapter | Config key | Constructor params needed |
|---------|-----------|-------------------------|
| sDAI | `sDAI` | `sDai`, `dsrManager`, `daiToUsdChainlinkOracle`, `daiToUsdChainlinkHeartbeat` |
| LDO | `LDO` | `ldo`, `ldoToEthChainlinkAddress`, `ethToUsdChainlinkAddress`, `ldoToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |
| sUSDS | `sUSDS` | `sUsds`, `usdsToUsdChainlinkAddress`, `usdsToUsdChainlinkHeartbeat` |
| sUSDe | `sUSDe` | `sUsde`, `usdeToUsdChainlinkAddress`, `usdeToUsdChainlinkHeartbeat` |
| syrupUSDC | `syrupUSDC` | `syrupUsdc`, `usdcToUsdChainlinkAddress`, `usdcToUsdChainlinkHeartbeat` |
| wstETH | `wstETH` | `wstEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| rETH | `rETH` | `rEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| cbETH | `cbETH` | `cbEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| weETH | `weETH` | `weEth`, `weEthToEthChainlinkOracle`, `ethToUsdChainlinkOracle`, `weEthToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |
| rsETH | `rsETH` | `rsEth`, `rateProvider`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| eETH | `eETH` | `eEth`, `weEth`, `weEthToEthChainlinkOracle`, `ethToUsdChainlinkOracle`, `weEthToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |

### 1.3 Gnosis price feed adapters

| Adapter | Config key | Constructor params needed |
|---------|-----------|-------------------------|
| sXDAI | `sXDAI` | `sXdai`, `xDaiToUsdChainlinkOracle`, `xDaiToUsdChainlinkHeartbeat` |

### 1.4 L2 price feed adapters

The following L2 price oracle contracts are implemented in `src/prices/protocols/` and wired into `03_DeployPriceFeeds.s.sol` per-chain, with `priceFeeds` entries in `assets.json`:

| Oracle | Chains | Source file |
|--------|--------|-------------|
| wstETH_L2 | Arbitrum, Base, Optimism | `wstETH_L2_Price.sol` |
| cbETH_L2 | Base | `cbETH_L2_Price.sol` |
| weETH_L2 | Arbitrum, Base | `weETH_L2_Price.sol` |
| rsETH_L2 | Arbitrum | `rsETH_L2_Price.sol` |
| ezETH_L2 | Arbitrum | `ezETH_L2_Price.sol` |
| syrupUSDC_L2 | (TBD) | `syrupUSDC_L2_Price.sol` |
| ETHPlus | Mainnet | `ETHPlus_Price.sol` |
| ezETH | Mainnet | `ezETH_Price.sol` |

> **Note:** Some of these (wstETH, weETH, cbETH, rsETH, ezETH) are already in `assets.json` under `tokens` with `type: "Custom"` and pre-filled `pricefeed` addresses. These might be L2 variants already deployed externally. Verify whether these addresses point to the oracles from this repo or to third-party deployments before deciding whether to deploy our own.

---

## Phase 2: Configure Balance Adapters

Balance adapter configuration lives in each chain's config file under `balanceAdapters`.

### 2.1 Add adapter entries to chain configs

> **Starting state:** every chain config currently contains **only `ERC20Default`** under `balanceAdapters`. Every other adapter you want deployed must be added by hand before running `04_DeployBalanceAdapters.s.sol`, otherwise the script has nothing to iterate.

For each adapter you want to deploy on a given chain, add an entry to `script/config/chains/{chainId}.json` under `balanceAdapters`:

```json
"balanceAdapters": {
  "AaveV3_USDC": {
    "enabled": true,
    "constructor": {
      "dataProvider": "0x...",
      "protocol": "Aave V3"
    },
    "deployed": ""
  }
}
```

### 2.2 Balance adapters available for deployment

The deploy script (`04_DeployBalanceAdapters.s.sol`) supports these adapters:

| Adapter prefix | Constructor params | Applicable chains |
|---------------|-------------------|-------------------|
| `AaveV3_*` | `dataProvider`, `protocol` | Mainnet, Arbitrum, Base, Optimism, Gnosis |
| `CompoundV3_*` | `compoundRewards`, `comet`, `rewardToken`, `protocol` | Mainnet |
| `SparkLend_*` | `dataProvider`, `protocol` | Mainnet |
| `MorphoBlue_*` | `morpho`, `marketId`, `protocol` | Mainnet |
| `MorphoVault_*` | `vault`, `protocol`, `positionDetail` | Mainnet |
| `GearboxMarket_*` | `market`, `protocol`, `positionDetail` | Mainnet |
| `Cap` | `cUsd`, `stcUsd`, `usdc`, `protocol`, `positionDetail` | Mainnet |
| `Curve_*` | `gauge`, `protocol`, `positionDetail` | Mainnet |
| `Convex_*` | `rewarder`, `lpToken`, `protocol`, `positionDetail` | Mainnet |
| `AaveV3SafetyModule_*` | `stakeToken`, `protocol`, `positionDetail` | Mainnet |
| `BalancerV3_*` | `pool`, `gauge`, `balancerMinter`, `protocol` | Mainnet |
| `Aura_*` | `pool`, `gauge`, `booster`, `pid`, `auraToken`, `protocol`, `positionDetail` | Mainnet |
| `StakeWiseV3Vault_*` | `underlyingToken`, `vault`, `protocol`, `positionDetail` | Mainnet |
| `StakeWiseV3OsToken_*` | `osToken`, `underlyingToken`, `osTokenVaultController`, `protocol`, `positionDetail` | Mainnet |
| `DaiDsr` | `dai`, `dsrManager`, `protocol`, `positionDetail` | Mainnet |
| `SkySavingsUsds` | `savingsUsds`, `protocol`, `positionDetail` | Mainnet |

### 2.3 Specific adapters currently wired in the deploy script

The `run()` function in `04_DeployBalanceAdapters.s.sol` calls `_deployIfEnabled` for these specific names:

```
AaveV3_USDC, AaveV3_WETH
CompoundV3_USDC, CompoundV3_WETH
SparkLend_USDC
DaiDsr, SkySavingsUsds
MorphoVault_kpkUSDC_V1, MorphoVault_kpkUSDC_V2
GearboxMarket_kpkWETH, GearboxMarket_kpkwstETH
Cap
Curve_weETH_WETH
Convex_crvUSD_USDT
AaveV3SafetyModule_stkAAVE, AaveV3SafetyModule_stkGHO
BalancerV3_weETH_WETH
Aura_weETH_WETH
StakeWiseV3Vault_WETH
StakeWiseV3OsToken_WETH
```

To deploy additional instances (e.g., a new Curve gauge, or AaveV3 on a different chain), add a new `_deployIfEnabled("Curve_newPool")` call to the `run()` function and a corresponding config entry.

---

## Phase 3: Deploy Price Feed Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

> **RPC shortcut:** `--rpc-url` is optional when `ALCHEMY_API_KEY` is set — each chain config has `"rpc": "$ALCHEMY"` which `ConfigReader` resolves using `ALCHEMY_API_KEY` and the chain's Alchemy network. See `script/deploy/README.md`. The commands below include `--rpc-url` explicitly for clarity.

### 3.1 Mainnet

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 3.2 Gnosis

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 100 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 3.3 L2 chains (Arbitrum, Base, Optimism)

```bash
# Arbitrum
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 \
  --broadcast \
  --private-key $PRIVATE_KEY

# Base
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 8453 \
  --broadcast \
  --private-key $PRIVATE_KEY

# Optimism
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 10 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 3.4 Verify

Deployed addresses are auto-saved to `assets.json` (or chain config) by the script. Check the console output for each deployed adapter address.

**Re-run safety:** If the script is interrupted, re-running will skip already-deployed adapters (checks `deployed` field in config).

---

## Phase 4: Deploy Balance Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

### 4.1 Mainnet

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 4.2 Other chains

Same pattern — replace RPC URL and chain ID:

```bash
# Arbitrum
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 --broadcast --private-key $PRIVATE_KEY

# Base
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 8453 --broadcast --private-key $PRIVATE_KEY

# Optimism
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 10 --broadcast --private-key $PRIVATE_KEY

# Gnosis
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 100 --broadcast --private-key $PRIVATE_KEY
```

### 4.3 Verify

Deployed addresses are auto-saved to `script/config/chains/{chainId}.json` under `balanceAdapters.{name}.deployed`.

**Re-run safety:** Same as price feeds — already-deployed adapters are skipped.

---

## Phase 5: Register Assets on NAVCalculator

Assets (tokens) must be registered on NAVCalculator with their price feed (Chainlink or Custom oracle address). This is done via `RegisterAssets.s.sol`.

### 5.1 Review token list

Token definitions live in `script/config/assets.json` under `tokens.{chainId}`. Each token has:

- `address` — token contract address
- `type` — `"Chainlink"`, `"Custom"`, or `"None"`
- `pricefeed` — oracle address (Chainlink feed or custom price adapter)
- `heartbeat` — staleness threshold in seconds

Tokens with `type: "None"` or empty `pricefeed` are skipped.

The list of symbols to register per chain is hardcoded in `RegisterAssets.s.sol` function `_symbolsForChain()`. Add new symbols there if needed.

### 5.2 Dry run (report only)

Run without `--broadcast` and without `--rpc-url` to see what would be registered:

```bash
forge script script/manage/RegisterAssets.s.sol --chain-id 1
```

### 5.3 Generate Safe TX batch + broadcast

Run with `--rpc-url` to verify on-chain state and generate Safe TX JSON. With `--broadcast --private-key`, the script also calls `registerAsset()` directly (sender must have MANAGER role):

```bash
# Mainnet
forge script script/manage/RegisterAssets.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Output: `safe-transactions/{chainId}-register-assets.json`

If broadcasting directly (sender has MANAGER), assets are registered immediately. Otherwise, import the Safe TX JSON into Safe UI and execute via multisig.

### 5.4 Repeat for all chains

Run the same script for each chain (42161, 8453, 10, 100).

---

## Phase 6: Add Balance Oracles to NAVCalculator

After balance adapters are deployed, they must be registered on NAVCalculator via `addBalanceOracle()`. This requires the MANAGER role.

### Option A: Use `06_Configure.s.sol` (Safe TX batch)

```bash
forge script script/deploy/06_Configure.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

Output: `safe-transactions/{chainId}-configure.json` — import into Safe UI.

### Option B: Use `ManageAdapters.s.sol` (individual Safe TXs)

Edit `ManageAdapters.s.sol` and uncomment `_addBalanceOracle(adapterAddress)` calls:

```solidity
function run() public override {
    setUp();
    validateAddresses();
    _addBalanceOracle(0x...); // adapter address from config
}
```

Then run:

```bash
forge script script/manage/ManageAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

### Option C: Direct broadcast (if sender has MANAGER)

Call `addBalanceOracle()` directly on the NAVCalculator proxy using `cast`:

```bash
cast send 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "addBalanceOracle(address)" <adapter_address> \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --private-key $PRIVATE_KEY
```

---

## Phase 7: Set Custom Price Feeds on NAVCalculator

Custom price feed adapters (deployed in Phase 3) must be linked to their assets on NAVCalculator via `setPriceFeed()`. This is separate from asset registration — `registerAsset()` sets the initial price feed, but `setPriceFeed()` can update it later.

If you registered assets in Phase 5 with the correct Custom oracle addresses in `assets.json`, the price feeds are already set. Only use this phase if you need to update or add price feeds after initial registration.

### Using ManageAdapters.s.sol

```solidity
_setPriceFeed(
    0x...,  // asset address
    0x...,  // custom price adapter address (from Phase 3)
    IPrices.PriceType.Custom,
    3600    // heartbeat
);
```

### Using cast

```bash
cast send 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "setPriceFeed(address,address,uint8,uint256)" \
  <asset> <priceFeed> 1 3600 \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --private-key $PRIVATE_KEY
```

(PriceType: 0 = Chainlink, 1 = Custom)

---

## Phase 8: Contract Verification

### 8.1 Generate verification commands

```bash
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
```

### 8.2 Run the printed commands

The script outputs ready-to-run `forge verify-contract` commands. Copy and run each one. Make sure the corresponding explorer API key is set in your environment.

### 8.3 Repeat for all chains

```bash
# Arbitrum
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Base
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Optimism
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Gnosis
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
```

---

## Phase 9: Post-Deployment Validation

### 9.1 Verify on-chain state

For each chain, check:

```bash
# Check whether a specific asset is registered
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "isAssetRegistered(address)(bool)" <asset_address> \
  --rpc-url <RPC_URL>

# List all registered assets (returns Asset[] — address, symbol, price type, etc.)
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "getRegisteredAssets()" \
  --rpc-url <RPC_URL>

# Get detailed price feed data for an asset
# Returns PriceFeedData: (address priceFeed, uint8 priceType, int256 price, uint8 decimals,
#                        uint256 chainlinkHeartbeat, uint256 updatedAt, bool stale, bool sequencerDown)
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "getPriceData(address)" <asset_address> \
  --rpc-url <RPC_URL>
```

> **Note:** NAVCalculator does not expose a `getBalanceOracles()` getter. To verify a specific balance oracle is registered, call `balanceOf` on the adapter directly (Phase 9.3) — a non-registered oracle would be uncallable via NAV anyway.

### 9.2 Test NAV calculation

```bash
# Get total NAV for a Safe in a given quote asset.
# Returns NAV struct: (int256 value, Asset quoteAsset, uint64 timestamp,
#                     Asset[] stalePriceAssets, bool sequencerDown)
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "getAccountNav(address,address)" <safe_address> <quote_asset_address> \
  --rpc-url <RPC_URL>
```

### 9.3 Verify each balance oracle returns data

```bash
# For each balance adapter, call balanceOf with the Safe address
cast call <adapter_address> \
  "balanceOf(address,address)(int256)" <underlying_asset> <safe_address> \
  --rpc-url <RPC_URL>
```

---

## Known Gaps to Address Before Deployment

> **Gaps 1–3 closed** by PRs [#11](https://github.com/karpatkey/onchain-accounting/pull/11) and [#12](https://github.com/karpatkey/onchain-accounting/pull/12) (merged 2026-04-17). The remaining gaps 4 and 5 do not block Alpha fund launch. Scope is limited to what the **ETH Alpha Fund** and **USD Alpha Fund** actually use — stale or unused v1 entries are intentionally excluded.

### 1. L2 price feed deploy functions — CLOSED

Closed in PR #11 (commits [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f) and [`2a9c0d7`](https://github.com/karpatkey/onchain-accounting/commit/2a9c0d7)). L2 deploy functions (`_deployWstEthL2`, `_deployWeEthL2`, `_deployRsEthL2`, `_deployEzEthL2`, `_deployCbEthL2`, `_deploySyrupUsdcL2`) are implemented and wired into `_deployArbitrumPriceAdapters`, `_deployBasePriceAdapters`, and `_deployGnosisPriceAdapters`. `_deploySxdai` added to Gnosis in the same PR.

### 2. `assets.json` `priceFeeds` section — CLOSED

Closed in PR #11 (commit [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f)). Every Custom price adapter used by ETH Alpha or USD Alpha has a `priceFeeds.{adapter}.{chainId}` entry with `enabled` and `constructor` params. Chain configs were pre-seeded with matching `priceFeeds` scaffolds so `ConfigReader.writeAdapterAddress` can persist deployed addresses.

### 3. `06_Configure.s.sol` and `04_DeployBalanceAdapters.s.sol` alignment — CLOSED

Closed in PR #12 (commit [`2a75423`](https://github.com/karpatkey/onchain-accounting/commit/2a75423)). `06_Configure.s.sol` was rewritten around a shared `_balanceAdapterNames()` helper that matches the 43 adapter names deployed by `04`. No more MorphoBlue_USDC ghost reference; all 10 new adapters from PR #12 are included.

### 4. Bridge adapters on non-Arbitrum chains

Bridge adapters are only deployed on Arbitrum. Mainnet, Base, Optimism, and Gnosis bridge adapter configs have `enabled: false` or empty `deployed` fields. Deploy these when ready using `05_DeployBridgeAdapters.s.sol`. Does not block Alpha fund launch (Alpha funds use ETH/native on source chains, bridge inbound via CCIP/Across/Stargate/CCTP on Arbitrum).

### 5. Native xDAI coverage on Gnosis — deferred

`ERC20Default` is registered on Gnosis with the xDAI sentinel address (`NATIVE_ADDRESS`) pre-inserted at NAVCalculator init, but no fork test confirms that `getOracleBalanceForAsset(NATIVE_ADDRESS, safe)` returns the correct native balance. USD Alpha Fund uses native xDAI on Gnosis. Verify with a fork test against a Safe holding xDAI before the Gnosis deployment goes live. Not blocking pre-deployment.

---

## Quick Reference: Deployment Order

```
Phase 0: Prerequisites (merge PRs, env setup, run tests)
    |
Phase 1: Configure price feed params in assets.json
Phase 2: Configure balance adapter params in chain configs
    |   (these two can be done in parallel)
    v
Phase 3: Deploy price feed adapters (03_DeployPriceFeeds.s.sol) -- per chain
Phase 4: Deploy balance adapters (04_DeployBalanceAdapters.s.sol) -- per chain
    |   (these two can be done in parallel per chain)
    v
Phase 5: Register assets on NAVCalculator (RegisterAssets.s.sol) -- per chain
Phase 6: Add balance oracles to NAVCalculator (06_Configure / ManageAdapters) -- per chain
    |   (5 and 6 can be batched into one Safe TX if using Safe)
    v
Phase 7: Set custom price feeds (if not done in Phase 5) -- per chain
    |
Phase 8: Verify contracts on block explorers -- per chain
Phase 9: Post-deployment validation -- per chain
```

---

## Rollback

- **Price feeds and balance adapters are NOT upgradeable** — they're standalone contracts. To "rollback", deploy a corrected version and update the NAVCalculator to point to the new one via `setPriceFeed()` / `removeBalanceOracle()` + `addBalanceOracle()`.
- **NAVCalculator and BridgeEscrow ARE upgradeable** (UUPS). Use `script/upgrade/UpgradeNAVCalculator.s.sol` or `UpgradeBridgeEscrow.s.sol`. Requires admin role.
