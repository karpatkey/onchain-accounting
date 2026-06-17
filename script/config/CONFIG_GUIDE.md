# Per-Chain Configuration Guide

## Overview

The deployment system uses **per-chain JSON configuration files** that:
- ✅ Store chain-specific settings and addresses
- ✅ Define which adapters to deploy per chain
- ✅ Automatically update with deployed addresses
- ✅ Enable/disable adapters per chain

## File Structure

```
script/config/
├── assets.json            # Assets + price feeds + custom price feed adapters (keyed by chainId)
├── balance-adapters.json  # Balance adapter intent: enabled, constructor, instances (keyed by chainId)
├── chains/
│   ├── 1.json             # Mainnet metadata, addresses, bridge intent
│   ├── 42161.json         # Arbitrum metadata, addresses, bridge intent
│   ├── 10.json            # Optimism metadata, addresses, bridge intent
│   ├── 8453.json          # Base metadata, addresses, bridge intent
│   └── 100.json           # Gnosis metadata, addresses, bridge intent
├── deployments/
│   └── <chainId>.json     # State file: the ONLY place deployed addresses are written
├── chain-config.json      # Legacy (deprecated, will be removed)
└── dev-input.json         # Legacy (deprecated, will be removed)
```

## assets.json — Assets and price feeds

Asset definitions and custom price feed adapter configs live in **`script/config/assets.json`**, keyed by chainId, so chain files stay small as you add many assets.

- **assets** (per chain): every asset of interest, keyed by symbol, with its token `address` and an ordered `priceFeeds[]` list. The **first** feed in `priceFeeds[]` is used by `registerAsset`; any remaining feeds are added via `addPriceFeed` (ADR 0009 redundancy).
- **customPriceFeeds** (per chain): deployable custom price feed adapters (e.g. sDAI, wstETH), keyed by name, each with `enabled` and `constructor` params. A `Custom` feed entry on an asset references one of these by `"feed":"<name>"`.
- **Note:** deployed addresses are never stored here — they live in `script/config/deployments/<chainId>.json`.

Example structure (both sections live under each chainId):

```json
{
  "1": {
    "assets": {
      "WETH": {
        "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "priceFeeds": [
          {
            "type": "Chainlink",
            "address": "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419",
            "heartbeat": 3600
          }
        ]
      },
      "wstETH": {
        "address": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
        "priceFeeds": [
          {
            "type": "Custom",
            "feed": "WstEthToUsd",
            "heartbeat": 3600
          }
        ]
      }
    },
    "customPriceFeeds": {
      "WstEthToUsd": {
        "enabled": true,
        "constructor": {
          "wstEth": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
          "stEthToUsdChainlinkOracle": "0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8",
          "stEthToUsdChainlinkHeartbeat": "3600"
        }
      }
    }
  }
}
```

- **assets**: Asset list and price feeds per chain (see below). Add asset objects under `{chainId}.assets.{SYMBOL}`.
- **customPriceFeeds**: Deployable custom price feed adapters (e.g. sDAI, wstETH). Configured under `{chainId}.customPriceFeeds.{name}` with `enabled` and `constructor`. The deployed address is written to `deployments/{chainId}.json .customPriceFeeds.{name}`; an asset wires it in by referencing the name via a `"feed":"<name>"` entry in its `priceFeeds[]` (not an address).

### assets — Asset list and price feeds per chain

The **`assets`** section lists every asset of interest per chain with its price feed config. Each chain has an object keyed by symbol (e.g. `"WETH"`, `"wstETH"`). The **list of symbols to process** is derived from the `assets.json` keys via `ConfigReader.getAssetSymbols(vm, chainId)` — no hardcoded list; add a symbol by adding its object to this JSON.

- **address**: Token contract address.
- **priceFeeds**: Ordered array of feed entries. The first registers the asset (`registerAsset`); the rest are added via `addPriceFeed`. Each entry has:
  - **type**: `"Chainlink"` (direct Chainlink feed), `"Custom"` (custom price feed adapter), `"Redstone"` (Redstone Classic push feed), or `"API3"` (`Api3ReaderProxyV1` push feed).
  - **address**: Feed contract address (Chainlink aggregator, Redstone/API3 proxy). Used by all types **except** `Custom`.
  - **feed**: For `Custom` only — the name of a `customPriceFeeds` entry; its on-chain address is resolved post-deploy from `deployments/<chainId>.json .customPriceFeeds.<name>`.
  - **heartbeat**: Staleness heartbeat in seconds (e.g. 3600, 86400). Optional; defaults to 3600 in code.

Iterate assets via `ConfigReader.getAssetSymbols(vm, chainId)`, then read each feed with `assetFeedCount` + `readAssetFeedType` / `readAssetFeedAddress` / `readAssetFeedHeartbeat` / `readAssetFeedName`.

**Registering assets:** Use `script/manage/RegisterAssets.s.sol` to report which tokens are already registered, which are skipped (no oracle or missing address), and which should be registered. It writes a Safe transaction batch to `safe-transactions/{chainId}-register-assets.json`. Run with `--rpc-url` so already-registered assets are excluded from the batch.

---

## Configuration File Format

Each chain config file (`chains/{chainId}.json`) contains:

```json
{
  "chainId": 1,
  "name": "mainnet",
  "rpc": "$MAINNET_RPC_URL",
  "explorer": "https://etherscan.io",
  "explorerApiKey": "$ETHERSCAN_API_KEY",
  "chainlinkSequencerFeed": "0x0000000000000000000000000000000000000000",
  "nativeTokenSymbol": "ETH",
  
  "addresses": {
    "securityCouncil": "0xYourSafeAddress",
    "admin": "0xYourAdminAddress",
    "manager": "0xYourManagerAddress"
  },
  
  "bridgeAdapters": {}
}
```

The chain config carries only metadata, `addresses`, and `bridgeAdapters` **intent**. Deployed addresses (NAVCalculator/BridgeEscrow impl + proxy, custom price feeds, balance adapters, bridge adapters) live in `script/config/deployments/<chainId>.json`. Balance adapter config lives in `balance-adapters.json`; assets and price feeds live in `assets.json`.

## How It Works

### 1. Before Deployment

Set chain metadata and roles in `script/config/chains/{chainId}.json`:

```json
{
  "addresses": {
    "securityCouncil": "0xYourActualSafeAddress",
    "admin": "0xYourActualAdminAddress",
    "manager": "0xYourActualManagerAddress"
  }
}
```

Then define balance adapter intent in `script/config/balance-adapters.json` under the chainId:

```json
{
  "1": {
    "AaveV3_USDC": {
      "enabled": true,  // ← Set to true to deploy
      "constructor": {
        "poolAddress": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
        "asset": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      }
    },
    "CompoundV3_USDC": {
      "enabled": false,  // ← Set to false to skip
      "constructor": {
        "comet": "0xc3d688B66703497DAA19211EEdff47f25384cdc3"
      }
    }
  }
}
```

There is no `deployed` field here — deployed addresses are written to `deployments/{chainId}.json`.

### 2. Run Deployment

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --account $DEPLOYER_NAME \
  --broadcast
```

The script will:
- ✅ Read `balance-adapters.json` for the chain
- ✅ Deploy only adapters where `enabled: true`
- ✅ Use constructor args from config
- ✅ **Automatically save** deployed addresses to `deployments/{chainId}.json`

### 3. After Deployment

The state file `deployments/{chainId}.json` is automatically updated:

```json
{
  "balanceAdapters": {
    "AaveV3_USDC": "0xActualDeployedAddress"
  }
}
```

The intent file `balance-adapters.json` is left untouched.

## Benefits

### ✅ Per-Chain Configuration
Each chain has its own config file with chain-specific:
- Protocol addresses (Aave pool, Compound comet, etc.)
- Enabled/disabled adapters
- Safe multisig address
- Admin/manager addresses

### ✅ Automatic Updates
Deployment scripts automatically write deployed addresses into `deployments/{chainId}.json`:
```solidity
ConfigReader.writeAdapterAddress(vm, chainId, "balanceAdapters", "AaveV3_USDC", deployedAddress);
```

### ✅ Selective Deployment
Enable/disable adapters per chain in `balance-adapters.json`:
```json
// On Mainnet (chainId "1") - enable DAI DSR
"DaiDsr": {
  "enabled": true
}

// On Arbitrum (chainId "42161") - disable DAI DSR (doesn't exist there)
"DaiDsr": {
  "enabled": false
}
```

### ✅ Re-run Safe
If deployment is interrupted, re-running the script will:
- Skip adapters that are already deployed
- Only deploy missing adapters
- Preserve existing deployed addresses

## Example: Deploying to Gnosis Chain

1. **Edit** `script/config/chains/100.json` (metadata + addresses only):

```json
{
  "chainId": 100,
  "name": "gnosis",
  "addresses": {
    "securityCouncil": "0xYourGnosisChainSafe",
    "admin": "0xYourGnosisChainSafe",
    "manager": "0xYourManagerOnGnosis"
  }
}
```

   Then add the adapter intent in `script/config/balance-adapters.json` under chainId `"100"`:

```json
{
  "100": {
    "AaveV3_USDC": {
      "enabled": true,
      "constructor": {
        "poolAddress": "0xGnosisAavePoolAddress",
        "asset": "0xGnosisUSDCAddress"
      }
    }
  }
}
```

2. **Deploy**:

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $GNOSIS_RPC_URL \
  --account $DEPLOYER_NAME \
  --broadcast
```

3. **Verify** the state file was updated:

```bash
cat script/config/deployments/100.json
```

You should see the deployed address under `balanceAdapters.AaveV3_USDC`!

## Configuration Fields

### Chain Settings
| Field | Type | Description |
|-------|------|-------------|
| `chainId` | number | Chain ID (1 for mainnet, 42161 for Arbitrum, etc.) |
| `name` | string | Human-readable chain name |
| `rpc` | string | RPC URL (use `$ENV_VAR` for env variables) |
| `explorer` | string | Block explorer URL |
| `explorerApiKey` | string | Explorer API key (use `$ENV_VAR`) |
| `chainlinkSequencerFeed` | address | L2 sequencer uptime feed (0x0 for L1s) |
| `nativeTokenSymbol` | string | Native token symbol (ETH, xDAI, etc.) |

### Addresses
| Field | Type | Description |
|-------|------|-------------|
| `securityCouncil` | address | Security-council Safe — the end-state admin (receives DEFAULT_ADMIN_ROLE in step 07). Does **not** execute deploy/config txs. |
| `admin` | address | DEFAULT_ADMIN_ROLE holder. In the EOA deploy flow set to the **deployer EOA** (upgrade, authorize adapters) until step 07 hands it to the council. |
| `manager` | address | MANAGER role (register assets, addBalanceAdapters/removeBalanceAdapters, addMetaInstances/removeMetaInstances). In the EOA flow, the **deployer EOA**. |

### Adapter Configuration
| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | `true` to deploy, `false` to skip |
| `constructor` | object | Constructor parameters (chain-specific addresses) |
| `instances` | string[] | **Meta-adapters only.** Array of instance addresses (checksummed `address`) to register on NAVCalculator via `addMetaInstances`/`removeMetaInstances`. Read by `06_Configure.s.sol`. |
| `instancesRaw` | string[] | **Meta-adapters only.** Array of raw `bytes32` values for adapters whose instance key is not an address (e.g. Morpho market IDs). Mutually exclusive with `instances`. |

Meta vs. plain adapters are not flagged in config — `06_Configure.s.sol` detects meta-adapters on-chain via ERC165. There is no `deployed` field here; deployed addresses live in `deployments/{chainId}.json`.

#### Meta-adapter instance configuration

Meta-adapters cover every instance of a protocol with a single deployed contract; the active instance set is pushed to NAVCalculator by `06_Configure.s.sol` via `addMetaInstances`/`removeMetaInstances`. Use `instances` for address-typed instance keys and `instancesRaw` for `bytes32`-typed keys. These entries live in `balance-adapters.json` under the chainId.

Example — address-keyed meta-adapter (`CompoundV3CometsMeta`):

```json
"CompoundV3CometsMeta": {
  "enabled": true,
  "constructor": { "compoundRewards": "0x...", "rewardToken": "0x...", "protocol": "Compound V3" },
  "instances": ["0xcomet1", "0xcomet2"]
}
```

Example — bytes32-keyed meta-adapter (`MorphoMarketsMeta`):

```json
"MorphoMarketsMeta": {
  "enabled": true,
  "constructor": { "morpho": "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb" },
  "instancesRaw": ["0xmarketId1bytes32", "0xmarketId2bytes32"]
}
```

`06_Configure.s.sol` reads both fields and reconciles each meta-adapter's on-chain set to config: it calls `NAVCalculator.removeMetaInstances(adapter, ...)` for coordinates no longer listed and `NAVCalculator.addMetaInstances(adapter, ...)` for newly-listed ones (diffed against `getMetaInstances`).

## Adding a New Chain

1. Create `script/config/chains/{newChainId}.json` — copy an existing chain config as a template; it carries only metadata, `addresses`, and `bridgeAdapters` intent.
2. Add a `"{newChainId}"` entry to `script/config/assets.json` with the chain's `assets` and any `customPriceFeeds`.
3. Add a `"{newChainId}"` entry to `script/config/balance-adapters.json`; set `enabled: true` for desired adapters.
4. Create an empty state file `script/config/deployments/{newChainId}.json` (deployed addresses are written here by the scripts).
5. Run deployment scripts.

Example for Polygon (chain ID 137):

```bash
cp script/config/chains/1.json script/config/chains/137.json
# Edit 137.json with Polygon-specific values
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --account $DEPLOYER_NAME \
  --broadcast
```

## Troubleshooting

### Config file not found
```
Error: File not found: script/config/chains/137.json
```
**Solution**: Create the chain config file first.

### Adapter already deployed
The script will skip re-deploying:
```
Deploying: AaveV3_USDC
  Already deployed at: 0x...
```
This is expected behavior when re-running.

### Wrong constructor args
If deployment fails, check that:
- Protocol addresses are correct for the chain
- Asset addresses match the chain
- All required fields are filled in

## Migration from Old Config

If you have the old `chain-config.json` and `dev-input.json`:

1. Create per-chain files in `script/config/chains/`
2. Copy chain settings from old `chain-config.json`
3. Copy adapter configs from old `dev-input.json`
4. Delete old files (they're deprecated)

If you have an older single-file-per-chain config (with inline `deployed`, `balanceAdapters`, and `tokens`/`priceFeeds`), migrate it to the two-file + state-file schema:

1. Move every `.deployed` value (NAVCalculator/BridgeEscrow impl + proxy, custom price feeds, balance/bridge adapters) into `script/config/deployments/<chainId>.json`.
2. Move `balanceAdapters` (without any `deployed` field) into `script/config/balance-adapters.json` under the chainId — renaming `metaInstances` → `instances` and `metaInstancesRaw` → `instancesRaw`.
3. Move the `tokens` and `priceFeeds` sections into `script/config/assets.json` under the chainId, as `assets` (with `priceFeeds[]`) and `customPriceFeeds`.

The new system is much more flexible and keeps intent and deployment state cleanly separated!
