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
├── chains/
│   ├── 1.json          # Mainnet configuration
│   ├── 42161.json      # Arbitrum configuration
│   ├── 10.json         # Optimism configuration
│   ├── 8453.json       # Base configuration
│   └── 100.json        # Gnosis configuration
├── chain-config.json   # Legacy (deprecated, will be removed)
└── dev-input.json      # Legacy (deprecated, will be removed)
```

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
    "safeMultisig": "0xYourSafeAddress",
    "admin": "0xYourAdminAddress",
    "manager": "0xYourManagerAddress",
    "assetRecoverer": "0xYourRecovererAddress"
  },
  
  "deployed": {
    "Create2Deployer": "",
    "NAVCalculatorImplementation": "",
    "NAVCalculatorProxy": "",
    "BridgeEscrowImplementation": "",
    "BridgeEscrowProxy": ""
  },
  
  "priceFeeds": {
    "sDAI": {
      "enabled": true,
      "deployed": ""
    }
  },
  
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
    "safeMultisig": "0xYourActualSafeAddress",
    "admin": "0xYourActualAdminAddress",
    "manager": "0xYourActualManagerAddress",
    "assetRecoverer": "0xYourActualRecovererAddress"
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
  --private-key $PRIVATE_KEY \
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
    "safeMultisig": "0xYourGnosisChainSafe",
    "admin": "0xYourGnosisChainSafe",
    "manager": "0xYourManagerOnGnosis",
    "assetRecoverer": "0xYourRecovererOnGnosis"
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
  --private-key $PRIVATE_KEY \
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
| `safeMultisig` | address | Safe multisig address (deploys proxies) |
| `admin` | address | Admin role (can upgrade, authorize adapters) |
| `manager` | address | Manager role (can register assets, add oracles) |
| `assetRecoverer` | address | Can recover wrongly sent funds |

### Adapter Configuration
| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | `true` to deploy, `false` to skip |
| `constructor` | object | Constructor parameters (chain-specific addresses) |
| `deployed` | string | Deployed address (auto-filled by scripts) |

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
  --private-key $PRIVATE_KEY \
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
