# Configuration Guide

This guide explains all configuration files needed for multi-chain deployments of NAVCalculator and BridgeEscrow.

## Table of Contents

1. [Configuration Files Overview](#configuration-files-overview)
2. [chains/{chainId}.json](#chainschainidjson)
3. [assets.json](#assetsjson)
4. [balance-adapters.json](#balance-adaptersjson)
5. [deployments/{chainId}.json](#deploymentschainidjson)
6. [salt-config.json](#salt-configjson)
7. [Deployment Output](#deployment-output)
8. [Environment Variables](#environment-variables)
9. [Role Management](#role-management)

---

## Configuration Files Overview

The repo uses **per-chain config files** and a **separate assets file**. Scripts read from these; there is no single `chain-config.json` or `dev-input.json`.

```
config/
├── chains/
│   ├── 1.json                 # Mainnet: RPC, explorer, metadata, role addresses, bridgeAdapters intent
│   ├── 42161.json             # Arbitrum
│   ├── 10.json                # Optimism
│   ├── 8453.json              # Base
│   ├── 100.json               # Gnosis
│   └── ...                    # One file per chain
├── assets.json                # Per chain: assets + priceFeeds[] arrays + customPriceFeeds
├── balance-adapters.json      # Per chain: balance adapter config (enabled, constructor, instances)
├── salt-config.json           # CREATE2 salts (auto-generated, version controlled)
└── README.md                  # This file

deployments/
├── 1.json                     # Deployed contract addresses (Mainnet)
├── 42161.json                 # Arbitrum
└── ...                        # One file per chain

safe-transactions/
├── 1-deploy-implementations.json
├── 1-deploy-proxies-and-initialize.json   # Safe transaction JSONs for multisig execution
└── ...
```

---

## chains/{chainId}.json

One file per chain. Contains chain metadata, role addresses, and bridge adapter intent. Deployed addresses live in `deployments/{chainId}.json`; balance adapters live in `balance-adapters.json`. **Use environment variables for RPC and explorer API keys (e.g. `$ALCHEMY`, `$ARBISCAN_API_KEY`).**

### Template (one chain)

```json
{
  "chainId": 42161,
  "name": "arbitrum",
  "rpc": "$ALCHEMY",
  "explorer": "https://arbiscan.io",
  "explorerApiKey": "$ARBISCAN_API_KEY",
  "chainlinkSequencerFeed": "0xFdB631F5EE196F0ed6FAa767959853A9F217697D",
  "nativeTokenSymbol": "ETH",
  "addresses": {
    "securityCouncil": "0x...",
    "admin": "0x...",
    "manager": "0x..."
  },
  "bridgeAdapters": {
    "CCIP": {
      "enabled": true,
      "initialize": {
        "admin": "0x...",
        "bridgeEscrow": "0x...",
        "router": "0x...",
        "feeToken": "0x...",
        "version": "1.0.0"
      }
    }
  }
}
```

### Field Descriptions

| Field | Type | Description |
|-------|------|-------------|
| `chainId` | number | Chain ID (e.g. 1, 42161, 10, 8453, 100) |
| `name` | string | Human-readable chain name |
| `rpc` | string | RPC URL (use env var e.g. `$ALCHEMY`) |
| `explorer` | string | Block explorer base URL |
| `explorerApiKey` | string | API key for verification (use env var) |
| `chainlinkSequencerFeed` | address | L2 sequencer uptime feed (use 0x0 for L1) |
| `nativeTokenSymbol` | string | Native token symbol (ETH, xDAI, etc.) |
| `addresses.securityCouncil` | address | Security-council Safe — end-state admin (step 07), not a deploy participant |
| `addresses.admin` | address | DEFAULT_ADMIN_ROLE — the deployer EOA during deploy (EOA flow) |
| `addresses.manager` | address | Manager role for NAV and bridge |
| `bridgeAdapters` | object | Bridge adapter config per adapter: `enabled`, `initialize` |

> Deployed implementation, proxy, and adapter addresses are written to `deployments/{chainId}.json` (not here). Balance adapter config lives in `balance-adapters.json`.

---

## assets.json

**Single file for all token and price-feed data per chain.** Scripts use it for NAVCalculator initial assets, BridgeEscrow asset registry, and price feed constructor params. Deployed price feed addresses are stored in `deployments/{chainId}.json` under `customPriceFeeds`, not here.

### Structure

Keyed by chainId. Each chain has two sections:

- **`{chainId}.assets.{symbol}`** — token `address` plus an ordered `priceFeeds[]` array. The first feed becomes the asset's primary feed (`registerAsset`); subsequent feeds are added via `addPriceFeed` (see [ADR 0009](../../docs/decisions/0009-multi-feed-assets.md)). An asset with no oracle uses an empty `priceFeeds: []`.
- **`{chainId}.customPriceFeeds.{name}`** — custom price feed adapter config: `enabled` and `constructor`. The deployed address is resolved post-deploy from `deployments/{chainId}.json` and referenced from feed entries by `"feed": "<name>"`.

### Template

```json
{
  "1": {
    "assets": {
      "ETH": {
        "address": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
        "priceFeeds": [
          { "type": "Chainlink", "address": "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419", "heartbeat": 3600 }
        ]
      },
      "USDC": {
        "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "priceFeeds": [
          { "type": "Chainlink", "address": "0x37be050e75C7F0a80F0E8abBFC2c4Ff826728cAa", "heartbeat": 86400 }
        ]
      },
      "sDAI": {
        "address": "0x83F20F44975D03b1b09e64809B757c47f942BEeA",
        "priceFeeds": [
          { "type": "Custom", "feed": "sDAI", "heartbeat": 86400 }
        ]
      }
    },
    "customPriceFeeds": {
      "sDAI": {
        "enabled": true,
        "constructor": { "description": "sDAI (Savings DAI) price adapter" }
      }
    }
  },
  "42161": {
    "assets": {
      "USDC": {
        "address": "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
        "priceFeeds": []
      }
    }
  }
}
```

### Field descriptions

**Asset (`{chainId}.assets.{symbol}`)**

| Field | Type | Description |
|-------|------|-------------|
| `address` | string | Token contract address on that chain |
| `priceFeeds` | array | Ordered list of feed entries (see below). First → `registerAsset`, rest → `addPriceFeed`. Empty `[]` for an asset with no oracle. |

**Feed entry (`priceFeeds[]`)**

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"Chainlink"`, `"Custom"`, `"Redstone"`, or `"API3"` |
| `address` | string | Feed address (non-Custom feeds) |
| `feed` | string | Custom feeds only: the `customPriceFeeds` key; address resolved post-deploy from `deployments/{chainId}.json` |
| `heartbeat` | number | Oracle heartbeat in seconds |

**Custom price feed (`{chainId}.customPriceFeeds.{name}`)**

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Deploy this custom feed adapter? |
| `constructor` | object | Constructor parameters for the custom feed adapter |

---

## balance-adapters.json

**Single file for all balance adapter config per chain.** Keyed by chainId, then by adapter key. Scripts deploy enabled adapters and register them on NAVCalculator. Deployed addresses are written to `deployments/{chainId}.json` (no `deployed` field here).

### Structure

- **`{chainId}.{AdapterKey}`** — `enabled`, `constructor`, plus optional `instances` / `instancesRaw` for meta-adapters.
- Meta-vs-plain is detected on-chain via ERC165 (no `meta` flag in config). For meta-adapters, the MANAGER applies the instance set via `addMetaInstances` / `removeMetaInstances`.
- `instances` is the old `metaInstances` (address-coordinate instances, widened to `bytes32` on-chain). `instancesRaw` is the old `metaInstancesRaw` (raw `bytes32` coordinates, e.g. Morpho marketIds / Balancer V2 poolIds).

### Template

```json
{
  "1": {
    "ERC20Default": {
      "enabled": true,
      "constructor": { "navCalculator": "0x..." }
    },
    "AaveV3InstancesMeta": {
      "enabled": true,
      "constructor": { "protocol": "Aave V3", "navCalculator": "0x..." },
      "instances": [
        "0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3"
      ]
    },
    "MorphoMarketsMeta": {
      "enabled": true,
      "constructor": { "navCalculator": "0x..." },
      "instancesRaw": [
        "0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc"
      ]
    }
  }
}
```

### Field descriptions

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Deploy and register this adapter on this chain? |
| `constructor` | object | Constructor parameters for the adapter |
| `instances` | array | Meta-adapters only: address-coordinate instances (old `metaInstances`) |
| `instancesRaw` | array | Meta-adapters only: raw `bytes32` coordinate instances (old `metaInstancesRaw`) |

---

## deployments/{chainId}.json

**The single source of truth for deployed addresses.** Written by deploy scripts; the only place addresses are persisted (note the filename is `{chainId}.json`, not `{chainId}-addresses.json`). Top-level proxy/impl keys plus maps for `customPriceFeeds`, `balanceAdapters`, and `bridgeAdapters`.

### Template

```json
{
  "chainId": 1,
  "NAVCalculatorImplementation": "0x...",
  "NAVCalculatorProxy": "0x...",
  "BridgeEscrowImplementation": "0x...",
  "BridgeEscrowProxy": "0x...",
  "customPriceFeeds": {
    "sDAI": "0x111..."
  },
  "balanceAdapters": {
    "ERC20Default": "0x...",
    "AaveV3InstancesMeta": "0x222..."
  },
  "bridgeAdapters": {
    "CCIP": "0x333..."
  }
}
```

---

## Where deployment parameters live

Deployment does **not** use a single `dev-input.json`. User-provided values live in:

- **`config/chains/{chainId}.json`** — Per chain: `addresses` (securityCouncil, admin, manager) and `bridgeAdapters` intent. Scripts read these for each chain.
- **`config/assets.json`** — Per chain: `{chainId}.assets.{symbol}` (address + `priceFeeds[]`) and `{chainId}.customPriceFeeds.{name}` (enabled + constructor). Used for NAVCalculator initial assets and BridgeEscrow asset registry; see [assets.json](#assetsjson).
- **`config/balance-adapters.json`** — Per chain: `{chainId}.{adapter}` (enabled, constructor, optional `instances`/`instancesRaw`); see [balance-adapters.json](#balance-adaptersjson).
- **`config/deployments/{chainId}.json`** — The only place deployed addresses are written (proxies, impls, custom price feeds, balance adapters, bridge adapters); see [deployments/{chainId}.json](#deploymentschainidjson).

The long template below is **deprecated** (single global dev-input is not used). For bridge adapter callbacks, see the table under "Bridge adapters: callbacks" in this file; CCTP and Superchain use `authorizeAdapter` only.

### Deprecated dev-input-style template (not used by current scripts)

```json
{
  "meta": {
    "version": "1.0.0",
    "description": "Deployment configuration for onchain-accounting system"
  },
  "global": {
    "securityCouncilAddress": "",
    "admin": "",
    "manager": ""
  },
  "navcalculator": {
    "initialAssets": [
      {
        "name": "USDC",
        "address": "",
        "priceFeed": "",
        "priceType": "Chainlink",
        "heartbeat": 86400
      },
      {
        "name": "WETH",
        "address": "",
        "priceFeed": "",
        "priceType": "Chainlink",
        "heartbeat": 3600
      }
    ]
  },
  "bridgeEscrow": {
    "initialAccounts": [],
    "initialAdapters": [],
    "assetSymbols": [
      {
        "symbol": "USDC  ",
        "name": "USD Coin",
        "addresses": {
          "1": "",
          "42161": "",
          "10": "",
          "8453": "",
          "100": ""
        }
      },
      {
        "symbol": "WETH  ",
        "name": "Wrapped Ether",
        "addresses": {
          "1": "",
          "42161": "",
          "10": "",
          "8453": "",
          "100": ""
        }
      },
      {
        "symbol": "ETH   ",
        "name": "Native Ether",
        "addresses": {
          "1": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
          "42161": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
          "10": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
          "8453": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"
        }
      }
    ]
  },
  "adapters": {
    "price": {
      "sDAI": {
        "enabled": true,
        "chains": ["1", "100"],
        "constructor": {
          "description": "sDAI (Savings DAI) price adapter"
        }
      },
      "LDO": {
        "enabled": true,
        "chains": ["1"],
        "constructor": {
          "ldoEthFeed": "",
          "ethUsdFeed": "",
          "description": "LDO cross-rate price adapter"
        }
      },
      "sXDAI": {
        "enabled": true,
        "chains": ["100"],
        "constructor": {
          "description": "sXDAI (Staked xDAI) price adapter"
        }
      }
    },
    "balance": {
      "AaveV3": {
        "enabled": true,
        "chains": ["1", "42161", "10", "8453", "100"],
        "constructor": {
          "poolAddress": "$FROM_CHAIN_CONFIG",
          "navCalculator": "$DEPLOYED_NAV_ADDRESS",
          "description": "Uses aaveV3Pool from chain config"
        }
      },
      "CompoundV3": {
        "enabled": true,
        "chains": ["1", "42161"],
        "constructor": {
          "cometAddress": "$FROM_CHAIN_CONFIG",
          "navCalculator": "$DEPLOYED_NAV_ADDRESS",
          "description": "Uses compoundCometUSDC from chain config"
        }
      },
      "MorphoBlue": {
        "enabled": true,
        "chains": ["1", "42161"],
        "constructor": {
          "morphoAddress": "$FROM_CHAIN_CONFIG",
          "navCalculator": "$DEPLOYED_NAV_ADDRESS",
          "marketId": ""
        }
      },
      "SparkLend": {
        "enabled": true,
        "chains": ["1"],
        "constructor": {
          "poolAddress": "$FROM_CHAIN_CONFIG",
          "navCalculator": "$DEPLOYED_NAV_ADDRESS"
        }
      },
      "BalancerV3": {
        "enabled": false,
        "chains": [],
        "constructor": {
          "vaultAddress": "",
          "navCalculator": "$DEPLOYED_NAV_ADDRESS"
        }
      }
    },
    "bridge": {
      "CCIP": {
        "enabled": true,
        "chains": ["1", "42161", "10", "8453"],
        "constructor": {
          "routerAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        },
        "callbackSelector": "0x85572ffb"
      },
      "Across": {
        "enabled": true,
        "chains": ["1", "42161", "10", "8453", "100"],
        "constructor": {
          "spokePoolAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        },
        "callbackSelector": "0x0ea1f938"
      },
      "Superchain": {
        "enabled": true,
        "chains": ["10", "8453"],
        "constructor": {
          "portalAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        },
        "callbackSelector": null
      },
      "Gnosis": {
        "enabled": true,
        "chains": ["1", "100"],
        "constructor": {
          "ambAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        },
        "callbackSelector": "0x0bad0c90"
      }
    }
  }
}
```

### Field Descriptions

#### Global Section

| Field | Description | Example |
|-------|-------------|---------|
| `securityCouncilAddress` | Your Safe multisig address (same on all chains) | `0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5` |
| `admin` | Address with DEFAULT_ADMIN_ROLE (typically the Safe) | `0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5` |
| `manager` | Address with MANAGER role for operations | `0x1234...` or Safe |

#### NAVCalculator Section

| Field | Type | Description |
|-------|------|-------------|
| `initialAssets` | array | Assets to register during deployment |
| `initialAssets[].name` | string | Human-readable asset name |
| `initialAssets[].address` | address | Token contract address (chain-specific) |
| `initialAssets[].priceFeed` | address | Chainlink feed or custom price adapter |
| `initialAssets[].priceType` | enum | "Chainlink" or "Custom" |
| `initialAssets[].heartbeat` | uint256 | Heartbeat in seconds (Chainlink only) |

**Common Heartbeats:**
- ETH/USD: 3600 (1 hour)
- Stablecoins: 86400 (24 hours)
- Volatile assets: 3600 or less

#### BridgeEscrow Section

| Field | Type | Description |
|-------|------|-------------|
| `initialAccounts` | address[] | Authorized accounts (Safes) that can bridge |
| `initialAdapters` | address[] | Initial bridge adapters (usually empty, added later) |
| `assetSymbols` | array | Asset symbols to register across chains |
| `assetSymbols[].symbol` | bytes6 | 6-byte symbol (right-padded with spaces) |
| `assetSymbols[].name` | string | Human-readable name |
| `assetSymbols[].addresses` | object | Address per chain ID |

**Symbol Format:**
- Must be exactly 6 bytes
- Right-pad with spaces: `"USDC  "`, `"WETH  "`, `"ETH   "`
- Used in invoice IDs for cross-chain matching

#### Adapters Section

Each adapter has:
- `enabled`: Deploy this adapter? (true/false)
- `chains`: Array of chain IDs where this adapter should be deployed
- `constructor`: Constructor parameters
  - Use `$FROM_CHAIN_CONFIG` to reference values from chain config (e.g. protocols in chains)
  - Use `$DEPLOYED_NAV_ADDRESS` or `$DEPLOYED_BRIDGE_ADDRESS` for deployed contracts
- `callbackSelector`: (Bridge adapters only) Function selector for protocol callbacks. See table below.

**Bridge adapters: callbacks**

Adapters that receive protocol callbacks (e.g. CCIP router, LayerZero endpoint) must be authorized with `authorizeAdapterWithCallback(adapter, selector)` so BridgeEscrow can forward the callback to the correct adapter. The following adapters require a callback selector; others (CCTP, Superchain) use `authorizeAdapter(adapter)` only.

| Adapter    | Callback function                    | Selector (bytes4) | Notes |
|-----------|--------------------------------------|-------------------|-------|
| CCIP      | `ccipReceive(Any2EVMMessage)`        | `0x85572ffb`      | Chainlink CCIP delivery |
| Across    | `handleAcrossMessage(...)`           | `0x0ea1f938`      | Across SpokePool fill |
| Stargate  | `lzReceive(uint16,bytes,uint64,bytes)` | `0x001d3567`    | LayerZero delivery |
| Gnosis    | `onTokenTransfer(address,bytes32,bytes)` | `0x0bad0c90`  | Omnibridge ERC677 callback |
| CCTP      | —                                    | none              | No callback; use `authorizeAdapter` |
| Superchain| —                                    | none              | No callback; use `authorizeAdapter` |

**CCTP domain mapping:** The CCTP adapter maps chain IDs to Circle’s CCTP domain IDs (used for `depositForBurn` and receive path). Each chain config that has CCTP can include `cctpDomain` in `bridgeAdapters.CCTP.initialize` for reference. The on-chain mapping is set via `CctpBridgeAdapter.setDomainMapping(chainId, domain)` (admin); deploy scripts do not call this—configure it after deployment (e.g. manage script or Safe tx). Official domain IDs (see [Circle CCTP contract addresses](https://developers.circle.com/cctp/references/contract-addresses)): Ethereum = 0, OP Mainnet = 2, Arbitrum = 3, Base = 6.

These bytes4 selectors are asserted in `test/bridge/BridgeAdapterCallbacks.t.sol` (`test_documentedCallbackSelectors_bytes4`). Keep this table in sync with that test.

The script `AuthorizeBridgeAdapters.s.sol` uses each adapter contract's `.selector` (e.g. `CcipBridgeAdapter.ccipReceive.selector`) so the correct bytes4 is always used.

**Special Values:**
- `$FROM_CHAIN_CONFIG`: Scripts look up the value from the chain config for that chain
- `$DEPLOYED_NAV_ADDRESS`: Replaced with NAVCalculator proxy address after deployment
- `$DEPLOYED_BRIDGE_ADDRESS`: Replaced with BridgeEscrow proxy address after deployment

---

## salt-config.json

CREATE2 salts for deterministic deployments. **Auto-generated by scripts.**

### Format

```json
{
  "version": "1.0.0",
  "salts": {
    "NAVCalculatorProxy": {
      "version": 1,
      "salt": "0x4e4156434c43554c41544f522d50524f58592d56312d0000000000000000000000",
      "description": "NAVCalculator proxy - version 1"
    },
    "BridgeEscrowProxy": {
      "version": 1,
      "salt": "0x4252494447452d4553435f524f572d50524f58592d563100000000000000000000",
      "description": "BridgeEscrow proxy - version 1"
    }
  }
}
```

### Salt Generation Logic

```solidity
// Deterministic salt from contract name + version
bytes32 salt = keccak256(abi.encodePacked("NAVCalculatorProxy", uint256(1)));
```

**When to increment version:**
- You want a NEW deterministic address
- After upgrading, if you want to deploy a fresh proxy rather than upgrade existing one
- Keep version 1 to maintain same addresses across chains

---

## Deployment Output

After deployment, addresses are saved to `deployments/{chainId}.json`.

### Format

```json
{
  "chainId": 1,
  "chainName": "mainnet",
  "timestamp": "2024-01-15T10:30:00Z",
  "deployer": "0x1234...",
  "securityCouncil": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5",
  "create2Deployer": "0xabcd...",
  "core": {
    "NAVCalculator": {
      "proxy": "0xdef...",
      "implementation": "0xabc...",
      "version": 1,
      "verified": {
        "etherscan": true,
        "sourcify": true
      }
    },
    "BridgeEscrow": {
      "proxy": "0x456...",
      "implementation": "0x789...",
      "version": 1,
      "verified": {
        "etherscan": true,
        "sourcify": false
      }
    }
  },
  "priceAdapters": {
    "sDAI": {
      "address": "0x111...",
      "verified": {
        "etherscan": true,
        "sourcify": true
      }
    }
  },
  "balanceAdapters": {
    "AaveV3InstancesMeta": {
      "address": "0x222...",
      "constructor": {
        "protocol": "Aave V3",
        "navCalculator": "0xdef..."
      },
      "instances": [
        "0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3"
      ],
      "verified": {
        "etherscan": true,
        "sourcify": true
      }
    }
  },
  "bridgeAdapters": {
    "CcipBridgeAdapter": {
      "address": "0x333...",
      "constructor": {
        "routerAddress": "0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D",
        "bridgeEscrow": "0x456...",
        "version": "1.0.0"
      },
      "callbackSelector": "0x85572ffb",
      "authorized": true,
      "verified": {
        "etherscan": true,
        "sourcify": true
      }
    }
  }
}
```

---

## Environment Variables

Set these in your `.env` file (never commit to git!).

### RPC via Alchemy (scripts)

When chain config has `"rpc": "$ALCHEMY"`, **ConfigReader** (used by deploy scripts) builds the URL from an Alchemy API key:

1. **ALCHEMY_API_KEY** — checked first.
2. **ALCHEMY_APİ_KEY** — used if `ALCHEMY_API_KEY` is unset (alternate name).

URL format: `https://{network}.g.alchemy.com/v2/{apiKey}` (network is derived from chain ID). So you can run scripts without passing `--rpc-url` if one of these is set. Same logic is used in **TestEnvConfigurator.getAlchemyUrl** for fork tests.

### RPC URLs (optional overrides)

```bash
# RPC URLs (optional; use when not using $ALCHEMY in chain config)
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
OPTIMISM_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
GNOSIS_RPC_URL=https://rpc.gnosischain.com

# Block Explorer API Keys (for verification)
ETHERSCAN_API_KEY=your_etherscan_api_key
ARBISCAN_API_KEY=your_arbiscan_api_key
OPTIMISM_ETHERSCAN_API_KEY=your_optimism_api_key
BASE_ETHERSCAN_API_KEY=your_base_api_key
GNOSIS_ETHERSCAN_API_KEY=your_gnosis_api_key

# Foundry keystore account name (import once: cast wallet import $DEPLOYER_NAME --interactive)
DEPLOYER_NAME=my-deployer

# Safe Transaction Service (optional, for API submission)
SAFE_TX_SERVICE_URL=https://safe-transaction-mainnet.safe.global
```

### Using Ledger (Recommended)

```bash
# Instead of private key, use Ledger for extra security
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --chain-id 1
# Then run 02_DeployProxies.s.sol per chain (EOA deployment; deploys and initializes proxies in one go).
```

---

## Role Management

### Role Hierarchy

```
DEFAULT_ADMIN_ROLE (0x00)
├─ Can upgrade NAVCalculator and BridgeEscrow (UUPS)
├─ Can grant/revoke all roles
├─ Can authorize/revoke bridge adapters
├─ Can pause/unpause BridgeEscrow
├─ Can emergency withdraw from BridgeEscrow
├─ setChainlinkL2SequencerUptimeFeed() (NAVCalculator)
└─ Typically assigned to: Safe Multisig

MANAGER (keccak256("MANAGER"))
├─ NAVCalculator:
│  ├─ registerAsset()
│  ├─ unregisterAsset()
│  ├─ addPriceFeed()
│  ├─ removePriceFeedAt()
│  ├─ removePriceFeed()
│  ├─ addBalanceAdapters()
│  ├─ removeBalanceAdapters()
│  ├─ addMetaInstances()
│  ├─ removeMetaInstances()
│  ├─ includeAssetInDefaultAdapter()
│  ├─ excludeAssetFromDefaultAdapter()
│  └─ setChainlinkL2SequencerGracePeriod()
│
├─ BridgeEscrow:
│  ├─ releaseByInvoiceId() (when not called by adapter)
│  ├─ cancelInvoice()
│  ├─ markInvoiceCompleted()
│  ├─ registerAsset()
│  └─ unregisterAsset()
│
└─ BridgeAdapter:
   ├─ completeBridge()
   └─ recoverStuckAssets()

Typically assigned to: Operations team or Safe Multisig
```

### Role Assignment Pattern

**Recommended Setup:**

1. **Safe Multisig** = DEFAULT_ADMIN_ROLE + MANAGER
   - Simplest: One Safe controls everything
   - All critical operations require multisig approval
   - Use Safe Transaction Builder for batch operations

2. **Separate Manager** (Optional)
   - If you want to separate upgrade authority from operational authority
   - Safe = DEFAULT_ADMIN_ROLE only
   - Manager EOA/Contract = MANAGER only
   - Manager can do day-to-day operations, Safe for upgrades

3. **Emergency Setup** (Advanced)
   - Safe = DEFAULT_ADMIN_ROLE
   - Manager = MANAGER
   - Emergency multisig = can call pause() via DEFAULT_ADMIN_ROLE

### Granting Roles

```solidity
// During initialization
NAVCalculator.initialize(
    admin,           // Gets DEFAULT_ADMIN_ROLE
    sequencerFeed,
    nativeSymbol
);

// After deployment, grant MANAGER role
// Via Safe transaction:
NAVCalculator.grantRole(MANAGER, managerAddress);

// Revoke if needed
NAVCalculator.revokeRole(MANAGER, oldManagerAddress);
```

### Bridge Adapter Authorization

```solidity
// BridgeEscrow: Authorize adapter without callback
BridgeEscrow.authorizeAdapter(adapterAddress);

// BridgeEscrow: Authorize adapter WITH callback
BridgeEscrow.authorizeAdapterWithCallback(
    adapterAddress,
    bytes4(keccak256("ccipReceive(...)"))  // Callback selector
);

// BridgeAdapter: Grant MANAGER to operations address
BridgeAdapter.grantRole(MANAGER, managerAddress);
```

---

## Configuration Checklist

### Pre-Deployment

- [ ] Fill `script/config/chains/{chainId}.json` with `addresses.securityCouncil`, `addresses.admin`, `addresses.manager` (per chain)
- [ ] Add initial assets for NAVCalculator with correct price feeds (e.g. in `assets.json`)
- [ ] Add asset symbols for BridgeEscrow (with addresses per chain)
- [ ] Enable/disable adapters per chain in `balance-adapters.json`
- [ ] Verify protocol addresses in `chains/{chainId}.json`, `assets.json`, and `balance-adapters.json`
- [ ] Set environment variables in `.env` (e.g. `ALCHEMY_API_KEY`, explorer API keys)
- [ ] Test RPC URLs are working
- [ ] Verify block explorer API keys are valid

### Post-Deployment

- [ ] Verify all contracts on Etherscan and Sourcify
- [ ] Save deployment addresses to `deployments/{chainId}.json`
- [ ] Verify proxy addresses match across chains
- [ ] Grant MANAGER role to appropriate addresses
- [ ] Authorize initial bridge adapters
- [ ] Authorize initial accounts in BridgeEscrow
- [ ] Register initial assets in NAVCalculator
- [ ] Register asset symbols in BridgeEscrow
- [ ] Test NAV calculation with mock positions
- [ ] Test bridge flow with small amounts
- [ ] Document any chain-specific quirks

---

## Examples

> **Deprecated** — the examples below use the old single `dev-input.json` shape. Current scripts read `assets.json`, `balance-adapters.json`, and the per-chain `chains/{chainId}.json` files instead; deployed addresses are written to `deployments/{chainId}.json`. Kept for reference only.

### Example 1: Mainnet + Arbitrum Setup

**dev-input.json (relevant sections):**

```json
{
  "global": {
    "securityCouncilAddress": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5",
    "admin": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5",
    "manager": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5"
  },
  "navcalculator": {
    "initialAssets": [
      {
        "name": "USDC",
        "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "priceFeed": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
        "priceType": "Chainlink",
        "heartbeat": 86400
      }
    ]
  },
  "bridgeEscrow": {
    "initialAccounts": ["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5"],
    "assetSymbols": [
      {
        "symbol": "USDC  ",
        "addresses": {
          "1": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "42161": "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
        }
      }
    ]
  },
  "adapters": {
    "bridge": {
      "CCIP": {
        "enabled": true,
        "chains": ["1", "42161"]
      }
    }
  }
}
```

### Example 2: Multi-Chain Asset Symbol Mapping

```json
{
  "bridgeEscrow": {
    "assetSymbols": [
      {
        "symbol": "USDC  ",
        "name": "USD Coin",
        "addresses": {
          "1": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "42161": "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
          "10": "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
          "8453": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
        }
      }
    ]
  }
}
```

This ensures the invoice system correctly matches USDC across chains using the `"USDC  "` symbol.

---

## Troubleshooting

### Issue: "Asset not registered" error

**Solution:** Register the asset first on NAVCalculator before trying to add price feeds or balance adapters.

### Issue: Different proxy addresses on different chains

**Solution:** 
- Verify Safe multisig has the SAME address on all chains
- Verify you're using the same salt (from salt-config.json)
- Verify proxy bytecode is identical (same implementation address structure)
- Verify Safe is doing delegatecall (operation: 1) not regular call

### Issue: Verification fails on Etherscan

**Solution:**
- Check constructor arguments match deployment
- For proxies, use ERC1967Proxy standard verification
- Try Sourcify as alternative
- Check API rate limits

### Issue: "Unauthorized" when calling adapter functions

**Solution:**
- Verify MANAGER role is granted to the caller
- For BridgeEscrow operations, verify adapter is authorized
- Check if contract is paused

---

## Additional Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [Safe Documentation](https://docs.safe.global/)
- [OpenZeppelin UUPS](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)
- [Chainlink Price Feeds](https://docs.chain.link/data-feeds/price-feeds/addresses)
