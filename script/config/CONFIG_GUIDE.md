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
├── assets.json         # Assets and price feed adapters (per chain)
├── chains/
│   ├── 1.json          # Mainnet configuration
│   ├── 42161.json      # Arbitrum configuration
│   ├── 10.json         # Optimism configuration
│   ├── 8453.json       # Base configuration
│   └── 100.json        # Gnosis configuration
├── chain-config.json   # Legacy (deprecated, will be removed)
└── dev-input.json      # Legacy (deprecated, will be removed)
```

## assets.json — Assets and price feeds

Asset definitions and price feed adapter configs live in **`script/config/assets.json`** so chain files stay small as you add many assets.

- **Defines** per-chain: which price feed adapters exist, `enabled`, and `constructor` params.
- **Note:** `priceFeeds` has been removed from the chain config schema. Deployed addresses should be stored elsewhere if needed.

Example structure (both sections live in the same file):

```json
{
  "description": "Assets and price feed adapters. Deployed adapter addresses go in chains/{chainId}.json.",
  "priceFeeds": {
    "sDAI": {
      "1": {
        "enabled": true,
        "constructor": {
          "sDai": "0x83F20F44975D03b1b09e64809B757c47f942BEeA",
          "dsrManager": "0x373238337Bfe1146fb49989fc222523f83081dDb",
          "daiToUsdChainlinkOracle": "0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9",
          "daiToUsdChainlinkHeartbeat": "3600"
        }
      }
    },
    "sXDAI": {
      "100": {
        "enabled": true,
        "constructor": {
          "sDai": "0xaf204776c7245bF4147c2612BF6e5972Ee483701",
          "xDaiToUsdChainlinkOracle": "0x678df3415fc31947dA4324eC63212874be5a82f8",
          "xDaiToUsdChainlinkHeartbeat": "3600"
        }
      }
    }
  },
  "tokens": {
    "1": {
      "ETH": {
        "address": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
        "type": "Chainlink",
        "pricefeed": "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419",
        "heartbeat": 3600
      }
    }
  }
}
```

- **priceFeeds**: [DEPRECATED in chain config] Deployable custom adapters (e.g. sDAI, LDO). Configuration lives in `assets.json` under `priceFeeds` with adapter name, then chain ID (`"1"`, `"100"`, etc.), then `enabled` and `constructor`. Deployed addresses are no longer stored in chain config files.
- **tokens**: Token list and oracles per chain (see below). Add token objects under `tokens.{chainId}.{SYMBOL}`.

### tokens — Token list and oracles per chain

The **`tokens`** section lists every token of interest per chain with its price oracle config. Each chain has an object keyed by symbol (e.g. `"ETH"`, `"WETH"`). The **list of symbols to process** is defined in `script/manage/RegisterAssets.s.sol` in `_symbolsForChain(chainId)` — add new tokens there and in this JSON.

- **address**: Token contract address.
- **type**: `"Chainlink"` (direct Chainlink feed), `"Custom"` (custom oracle contract), `"Redstone"` (Redstone Classic push feed), `"API3"` (`Api3ReaderProxyV1` push feed), or `"None"` (no oracle).
- **pricefeed**: Oracle contract address (Chainlink aggregator, Redstone/API3 proxy, or custom feed). Empty if type is `None` or TBD.
- **heartbeat**: Staleness heartbeat in seconds (e.g. 3600, 86400). Optional; defaults to 3600 in code.
- **note**: Optional human-readable note (e.g. "No oracle available", "Deploy custom …").

Only tokens with `type` Chainlink, Custom, Redstone, or API3 and non-empty `pricefeed` should be registered as having a price feed. Use `ConfigReader.hasTokenOracle(vm, chainId, symbol)` in scripts to check.

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
  
  "deployed": {
    "NAVCalculatorImplementation": "",
    "NAVCalculatorProxy": "",
    "BridgeEscrowImplementation": "",
    "BridgeEscrowProxy": ""
  },
  "comment_deployed": "Proxy addresses differ per chain: CREATE2 uses (deployer, salt, bytecode); the proxy bytecode includes the implementation address, which is different on each chain.",
  
  "balanceAdapters": {
    "AaveV3_USDC": {
      "enabled": true,
      "constructor": {
        "poolAddress": "0x...",
        "asset": "0x..."
      },
      "deployed": ""
    }
  },
  
  "bridgeAdapters": {}
}
```

## How It Works

### 1. Before Deployment

Edit `script/config/chains/{chainId}.json`:

```json
{
  "addresses": {
    "securityCouncil": "0xYourActualSafeAddress",
    "admin": "0xYourActualAdminAddress",
    "manager": "0xYourActualManagerAddress"
  },
  
  "balanceAdapters": {
    "AaveV3_USDC": {
      "enabled": true,  // ← Set to true to deploy
      "constructor": {
        "poolAddress": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
        "asset": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      },
      "deployed": ""  // ← Empty before deployment
    },
    "CompoundV3_USDC": {
      "enabled": false,  // ← Set to false to skip
      "constructor": {
        "comet": "0xc3d688B66703497DAA19211EEdff47f25384cdc3"
      },
      "deployed": ""
    }
  }
}
```

### 2. Run Deployment

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --account $DEPLOYER_NAME \
  --broadcast
```

The script will:
- ✅ Read the chain config
- ✅ Deploy only adapters where `enabled: true`
- ✅ Use constructor args from config
- ✅ **Automatically save** deployed addresses back to config

### 3. After Deployment

The config file is automatically updated:

```json
{
  "balanceAdapters": {
    "AaveV3_USDC": {
      "enabled": true,
      "constructor": {
        "poolAddress": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
        "asset": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      },
      "deployed": "0xActualDeployedAddress"  // ← Automatically filled!
    }
  }
}
```

## Benefits

### ✅ Per-Chain Configuration
Each chain has its own config file with chain-specific:
- Protocol addresses (Aave pool, Compound comet, etc.)
- Enabled/disabled adapters
- Safe multisig address
- Admin/manager addresses

### ✅ Automatic Updates
Deployment scripts automatically write back deployed addresses:
```solidity
ConfigReader.writeAdapterAddress(vm, chainId, "balanceAdapters", "AaveV3_USDC", deployedAddress);
```

### ✅ Selective Deployment
Enable/disable adapters per chain:
```json
// On Mainnet - enable DAI DSR
"DaiDsr": {
  "enabled": true
}

// On Arbitrum - disable DAI DSR (doesn't exist there)
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

1. **Edit** `script/config/chains/100.json`:

```json
{
  "chainId": 100,
  "name": "gnosis",
  "addresses": {
    "securityCouncil": "0xYourGnosisChainSafe",
    "admin": "0xYourGnosisChainSafe",
    "manager": "0xYourManagerOnGnosis"
  },
  "balanceAdapters": {
    "AaveV3_USDC": {
      "enabled": true,
      "constructor": {
        "poolAddress": "0xGnosisAavePoolAddress",
        "asset": "0xGnosisUSDCAddress"
      },
      "deployed": ""
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

3. **Verify** the config was updated:

```bash
cat script/config/chains/100.json
```

You should see the `deployed` field filled in!

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
| `manager` | address | MANAGER role (register assets, add oracles, addMetaInstances/removeMetaInstances). In the EOA flow, the **deployer EOA**. |

### Adapter Configuration
| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | `true` to deploy, `false` to skip |
| `constructor` | object | Constructor parameters (chain-specific addresses) |
| `deployed` | string | Deployed address (auto-filled by scripts) |
| `metaInstances` | string[] | **Meta-adapters only.** Array of instance addresses (checksummed `address`) to register on NAVCalculator via `addMetaInstances`/`removeMetaInstances`. Read by `06_Configure.s.sol`. |
| `metaInstancesRaw` | string[] | **Meta-adapters only.** Array of raw `bytes32` values for adapters whose instance key is not an address (e.g. Morpho market IDs). Mutually exclusive with `metaInstances`. |

#### Meta-adapter instance configuration

Meta-adapters cover every instance of a protocol with a single deployed contract; the active instance set is pushed to NAVCalculator by `06_Configure.s.sol` via `addMetaInstances`/`removeMetaInstances`. Use `metaInstances` for address-typed instance keys and `metaInstancesRaw` for `bytes32`-typed keys.

Example — address-keyed meta-adapter (`CompoundV3CometsMeta`):

```json
"CompoundV3CometsMeta": {
  "enabled": true,
  "constructor": { "compoundRewards": "0x...", "rewardToken": "0x...", "protocol": "Compound V3" },
  "metaInstances": ["0xcomet1", "0xcomet2"],
  "deployed": ""
}
```

Example — bytes32-keyed meta-adapter (`MorphoMarketsMeta`):

```json
"MorphoMarketsMeta": {
  "enabled": true,
  "constructor": { "morpho": "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb" },
  "metaInstancesRaw": ["0xmarketId1bytes32", "0xmarketId2bytes32"],
  "deployed": ""
}
```

`06_Configure.s.sol` reads both fields and calls `NAVCalculator.addMetaInstances(adapter, instances)` for each meta-adapter that has a non-empty list.

## Adding a New Chain

1. Create `script/config/chains/{newChainId}.json`
2. Copy an existing chain config as template
3. Update all fields with chain-specific values
4. Set `enabled: true` for desired adapters
5. Run deployment scripts

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

The new system is much more flexible and maintains deployment state!
