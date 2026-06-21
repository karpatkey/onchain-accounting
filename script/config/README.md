# Configuration Guide

This guide explains all configuration files needed for multi-chain deployments of NAVCalculator and BridgeEscrow.

## Table of Contents

1. [Configuration Files Overview](#configuration-files-overview)
2. [chains/{chainId}.json](#chainschainidjson)
3. [contracts-deployment-config/custom-price-feeds/{chainId}.json](#contracts-deployment-configcustom-price-feedschainidjson)
4. [contracts-deployment-config/balance-adapters & meta-balance-adapters/{chainId}.json](#contracts-deployment-configbalance-adapters--meta-balance-adapterschainidjson)
   - [contracts-deployment-config/bridge-adapters/{chainId}.json](#contracts-deployment-configbridge-adapterschainidjson)
5. [nav-config/assets-and-price-feeds/{chainId}.json](#nav-configassets-and-price-feedschainidjson)
6. [nav-config/balance-adapters & meta-balance-adapters/{chainId}.json](#nav-configbalance-adapters--meta-balance-adapterschainidjson)
7. [deployments/{chainId}.json](#deploymentschainidjson)
8. [CREATE2 Salts](#create2-salts)
9. [Deployment Output](#deployment-output)
10. [Environment Variables](#environment-variables)
11. [Role Management](#role-management)

---

## Configuration Files Overview

The repo uses **per-concern, per-chain config files**. Each file is named `<chainId>.json` and its top-level keys are the entries (no chainId wrapper inside — the filename *is* the chain). Scripts read from these; there is no single `chain-config.json`, `dev-input.json`, `assets.json`, or `balance-adapters.json`.

Two concerns are separated:

- **`contracts-deployment-config/`** — *what to deploy* (+ constructor/initialize args). Read by `03_DeployPriceFeeds.s.sol` / `04_DeployBalanceAdapters.s.sol` / `05_DeployBridgeAdapters.s.sol`.
- **`nav-config/`** — *what to register/add on the NAVCalculator*. Read by `script/manage/RegisterAssets.s.sol` / `06_Configure.s.sol`.

```
script/config/
├── chains/
│   ├── 1.json                                     # Mainnet: RPC, explorer, metadata, role addresses (metadata + addresses only)
│   ├── 42161.json                                 # Arbitrum
│   ├── 10.json                                    # Optimism
│   ├── 8453.json                                  # Base
│   ├── 100.json                                   # Gnosis
│   └── ...                                         # One file per chain
├── contracts-deployment-config/
│   ├── custom-price-feeds/<chainId>.json          # Custom price feeds to deploy: { "<feedName>": { enabled, constructor } }
│   ├── balance-adapters/<chainId>.json            # PLAIN adapters to deploy: { "<AdapterName>": { enabled, constructor } }
│   ├── meta-balance-adapters/<chainId>.json       # META adapters to deploy: { "<AdapterName>": { enabled, constructor } }
│   └── bridge-adapters/<chainId>.json             # Bridge adapters to deploy: { "<AdapterName>": { enabled, initialize } } — read by 05
├── nav-config/
│   ├── assets-and-price-feeds/<chainId>.json      # Assets to register: { "<SYMBOL>": { address, priceFeeds[] } }
│   ├── balance-adapters/<chainId>.json            # PLAIN adapters to add on NAV: { "<AdapterName>": { enabled } }
│   └── meta-balance-adapters/<chainId>.json       # META adapters to add on NAV: { "<AdapterName>": { enabled, instances[] | instancesRaw[] } }
├── deployments/
│   ├── 1.json                                     # Deployed contract addresses (Mainnet) — the ONLY place addresses are written
│   ├── 42161.json                                 # Arbitrum
│   └── ...                                         # One file per chain
└── README.md                                      # This file
```

> CREATE2 salts are **not** stored in a JSON file — they are computed deterministically in code from the contract name + version (`ConfigReader.computeSalt(name, version)`, exposed as `BaseDeployScript.generateSalt`). See [CREATE2 Salts](#create2-salts) below.

Safe-transaction batches are written by the manage scripts to a `safe-transactions/` directory at the **repository root** (not under `script/config/`):

```
safe-transactions/
├── 1-deploy-nav-implementation.json
├── 1-register-assets.json                  # Safe transaction JSONs for multisig execution
└── ...
```

**Names are the join key** across the deploy files, the nav files, and `deployments/<chainId>.json` — an adapter or feed name must match exactly in each so addresses resolve at registration time.

---

## chains/{chainId}.json

One file per chain. Contains chain metadata and role addresses only — **no `bridgeAdapters` block** (bridge-adapter config now lives in `contracts-deployment-config/bridge-adapters/{chainId}.json`). Deployed addresses live in `deployments/{chainId}.json`; balance adapter deploy config lives in `contracts-deployment-config/balance-adapters/{chainId}.json` (plain) / `contracts-deployment-config/meta-balance-adapters/{chainId}.json` (meta) and NAV-registration config in `nav-config/balance-adapters/{chainId}.json` (plain) / `nav-config/meta-balance-adapters/{chainId}.json` (meta). **Use environment variables for RPC and explorer API keys (e.g. `$ALCHEMY`, `$ARBISCAN_API_KEY`).**

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

> Deployed implementation, proxy, and adapter addresses are written to `deployments/{chainId}.json` (not here). Balance adapter deploy config lives in `contracts-deployment-config/balance-adapters/{chainId}.json` (plain) / `contracts-deployment-config/meta-balance-adapters/{chainId}.json` (meta); bridge adapter deploy config lives in `contracts-deployment-config/bridge-adapters/{chainId}.json`.

---

## contracts-deployment-config/custom-price-feeds/{chainId}.json

**Custom price feed adapters to deploy on a chain.** Keyed by feed name, each with `enabled` and `constructor`. Read by `03_DeployPriceFeeds.s.sol`, which deploys every feed where `enabled: true` and writes the address to `deployments/{chainId}.json` under `customPriceFeeds`. Top-level keys are feed names — no chainId wrapper.

An asset wires in a deployed feed by name via a `"type":"Custom","feed":"<feedName>"` entry in its `priceFeeds[]` (in `nav-config/assets-and-price-feeds/{chainId}.json`); the on-chain address resolves post-deploy from `deployments/{chainId}.json .customPriceFeeds.<feedName>` (never an inline address here).

### Template

```json
{
  "sDAI": {
    "enabled": true,
    "$comment": "sDAI (Savings DAI) price adapter — derives sDAI/USD from the DSR rate + DAI/USD.",
    "constructor": {
      "sDai": "0x83F20F44975D03b1b09e64809B757c47f942BEeA",
      "dsrManager": "0x373238337Bfe1146fb49989fc222523f83081dDb",
      "daiToUsdChainlinkOracle": "0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9",
      "daiToUsdChainlinkHeartbeat": "3600"
    }
  },
  "wstETH": {
    "enabled": true,
    "constructor": {
      "wstEth": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
      "stEthToEthChainlinkOracle": "0x86392dC19c0b719886221c78AB11eb8Cf5c52812",
      "ethToUsdChainlinkOracle": "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419",
      "stEthToEthChainlinkHeartbeat": "86400",
      "ethToUsdChainlinkHeartbeat": "3600"
    }
  }
}
```

Each key under `constructor` must be an actual argument of the feed adapter's Solidity constructor — the
deploy script reads them **by name** (`03_DeployPriceFeeds.s.sol` calls `readPriceFeedParam(name, "<arg>")`
for each one), so the names must match exactly and an unrecognized key is silently ignored. There is **no**
`description` argument; for a human-readable note use the entry-level `$comment` field (ignored by the
reader), not a fake `constructor` key.

### Field descriptions

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Deploy this custom feed adapter? |
| `$comment` | string | Optional human note; ignored by the deploy script. |
| `constructor` | object | The feed adapter's actual constructor arguments, keyed by parameter name. |

---

## contracts-deployment-config/balance-adapters & meta-balance-adapters/{chainId}.json

**Balance adapters to deploy on a chain.** Plain adapters live in `balance-adapters/{chainId}.json`; meta adapters live in `meta-balance-adapters/{chainId}.json` (same plain-vs-meta classification as `nav-config/`). Keyed by adapter name, each with `enabled` and `constructor`. Read by `04_DeployBalanceAdapters.s.sol`, which deploys every adapter where `enabled: true` across **both** files (plain `new …`, CREATE) and writes the address to `deployments/{chainId}.json` under `balanceAdapters` (all deployed addresses, plain and meta, share that one block). Top-level keys are adapter names — no chainId wrapper.

A meta-adapter is a single deployed contract; its **instance set is NOT here** — it lives in `nav-config/meta-balance-adapters/{chainId}.json`. There is no `deployed` field here.

### Template — `balance-adapters/{chainId}.json` (plain)

```json
{
  "ERC20Default": {
    "enabled": true,
    "constructor": {}
  }
}
```

### Template — `meta-balance-adapters/{chainId}.json` (meta)

```json
{
  "AaveV3InstancesMeta": {
    "enabled": true,
    "constructor": { "protocol": "Aave V3" }
  },
  "MorphoMarketsMeta": {
    "enabled": true,
    "constructor": { "morpho": "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb", "protocol": "Morpho" }
  }
}
```

### Field descriptions

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Deploy this adapter on this chain? |
| `constructor` | object | Constructor parameters for the adapter, keyed by parameter name (e.g. `protocol`, plus any protocol-specific args like `morpho`). `navCalculator` is injected by the deploy script and is not listed here. |

---

## contracts-deployment-config/bridge-adapters/{chainId}.json

**Bridge adapters to deploy on a chain.** Keyed by adapter name (e.g. `CCIP`, `CCTP`, `Across`, `Stargate`, `Superchain`, `Gnosis`), each with `enabled` and the adapter's `initialize` args. Read by `05_DeployBridgeAdapters.s.sol`, which deploys every adapter where `enabled: true` and writes the address to `deployments/{chainId}.json` under `bridgeAdapters`. Top-level keys are adapter names — no chainId wrapper. (This config previously lived under a `bridgeAdapters` block in `chains/{chainId}.json`; it now lives here.)

As of [ADR 0012](../../docs/decisions/0012-bridge-provable-release-rearchitecture.md) the escrow has **no callback dispatcher**: adapters are the direct on-chain protocol receivers and authenticate inbound messages themselves. There is no `callbackSelector` config — the escrow `authorizeAdapterWithCallback` / selector-registration mechanism was removed. Source-sender authentication is configured per adapter via `setTrustedRemoteAdapter(sourceKey, remoteAdapter)` after deployment (admin), not through this file. (Some legacy per-chain JSONs may still carry a vestigial `callbackSelector` key; it is no longer consumed by the current escrow.)

### Template

```json
{
  "CCIP": {
    "enabled": true,
    "initialize": {
      "admin": "0x...",
      "bridgeEscrow": "0x...",
      "router": "0x...",
      "feeToken": "0x...",
      "version": "1.0.0"
    }
  },
  "CCTP": {
    "enabled": true,
    "initialize": {
      "admin": "0x...",
      "bridgeEscrow": "0x...",
      "tokenMessenger": "0xBd3fa81B58Ba92a82136038B25aDec7066af3155",
      "messageTransmitter": "0x0a992d191DEeC32aFe36203Ad87D7d289a738F81",
      "version": "1.0.0",
      "cctpDomain": 0
    }
  }
}
```

### Field descriptions

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Deploy this bridge adapter on this chain? |
| `initialize` | object | Initialize args for the adapter (admin, bridgeEscrow, protocol contracts, version; CCTP also `cctpDomain`) |

There is **no `callbackSelector` field** as of [ADR 0012](../../docs/decisions/0012-bridge-provable-release-rearchitecture.md): the escrow no longer dispatches callbacks. Each adapter is the direct protocol receiver and authenticates inbound messages; trusted source senders are set per adapter via `setTrustedRemoteAdapter` after deployment. (See "Bridge adapters: provenance" below.)

---

## nav-config/assets-and-price-feeds/{chainId}.json

**Assets to register on NAVCalculator.** Keyed by symbol; each has a token `address` and an ordered `priceFeeds[]` array. Read by `script/manage/RegisterAssets.s.sol`. The first feed becomes the asset's primary feed (`registerAsset`); subsequent feeds are added via `addPriceFeed` (see [ADR 0009](../../docs/decisions/0009-multi-feed-price-redundancy.md)). An asset with no oracle uses an empty `priceFeeds: []`. Top-level keys are symbols — no chainId wrapper.

### Template

```json
{
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
}
```

### Field descriptions

**Asset (`{symbol}`)**

| Field | Type | Description |
|-------|------|-------------|
| `address` | string | Token contract address on that chain |
| `priceFeeds` | array | Ordered list of feed entries (see below). First → `registerAsset`, rest → `addPriceFeed`. Empty `[]` for an asset with no oracle. |

**Feed entry (`priceFeeds[]`)**

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"Chainlink"`, `"Custom"`, `"Redstone"`, or `"API3"` |
| `address` | string | Feed address (non-Custom feeds) |
| `feed` | string | Custom feeds only: the `contracts-deployment-config/custom-price-feeds/{chainId}.json` key; address resolved post-deploy from `deployments/{chainId}.json .customPriceFeeds.<name>` |
| `heartbeat` | number | Oracle heartbeat in seconds |

---

## nav-config/balance-adapters & meta-balance-adapters/{chainId}.json

**Balance adapters to register on NAVCalculator.** Read by `06_Configure.s.sol`, which resolves each adapter's address from `deployments/{chainId}.json .balanceAdapters.<name>`. Meta-vs-plain is **explicit** by which file the entry lives in:

- **`nav-config/balance-adapters/{chainId}.json`** — PLAIN adapters. Keyed by adapter name, each just `{ "enabled": true }`. `06_Configure` calls `NAVCalculator.addBalanceAdapters(...)` for the enabled ones.
- **`nav-config/meta-balance-adapters/{chainId}.json`** — META adapters. Keyed by adapter name, each with `enabled` plus an instance list. `06_Configure` calls `addMetaBalanceAdapter` then reconciles the instance set via `addMetaInstances` / `removeMetaInstances` (diffed against `getMetaInstances`).

`instances` holds address-coordinate instances (widened to `bytes32` on-chain). `instancesRaw` holds raw `bytes32` coordinates (e.g. Morpho marketIds / Balancer V2 poolIds); the two are mutually exclusive. These replace the old `metaInstances` / `metaInstancesRaw` keys.

### Template — `nav-config/balance-adapters/{chainId}.json`

```json
{
  "ERC20Default": { "enabled": true },
  "SparkLend": { "enabled": true }
}
```

### Template — `nav-config/meta-balance-adapters/{chainId}.json`

```json
{
  "AaveV3InstancesMeta": {
    "enabled": true,
    "instances": [
      "0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3"
    ]
  },
  "MorphoMarketsMeta": {
    "enabled": true,
    "instancesRaw": [
      "0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc"
    ]
  }
}
```

### Field descriptions

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Register this adapter on NAVCalculator? |
| `instances` | array | Meta file only: address-coordinate instances (replaces old `metaInstances`) |
| `instancesRaw` | array | Meta file only: raw `bytes32` coordinate instances (replaces old `metaInstancesRaw`) |

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

- **`config/chains/{chainId}.json`** — Per chain: metadata + `addresses` (securityCouncil, admin, manager) only. Scripts read these for each chain.
- **`config/contracts-deployment-config/custom-price-feeds/{chainId}.json`** — Per chain: `{feedName}` (enabled + constructor) custom price feeds to deploy; see [contracts-deployment-config/custom-price-feeds/{chainId}.json](#contracts-deployment-configcustom-price-feedschainidjson).
- **`config/contracts-deployment-config/balance-adapters/{chainId}.json`** and **`config/contracts-deployment-config/meta-balance-adapters/{chainId}.json`** — Per chain: plain / meta `{adapter}` (enabled + constructor) balance adapters to deploy; see [contracts-deployment-config/balance-adapters & meta-balance-adapters/{chainId}.json](#contracts-deployment-configbalance-adapters--meta-balance-adapterschainidjson).
- **`config/contracts-deployment-config/bridge-adapters/{chainId}.json`** — Per chain: `{adapter}` (enabled + initialize args) bridge adapters to deploy; see [contracts-deployment-config/bridge-adapters/{chainId}.json](#contracts-deployment-configbridge-adapterschainidjson).
- **`config/nav-config/assets-and-price-feeds/{chainId}.json`** — Per chain: `{symbol}` (address + `priceFeeds[]`) assets to register on NAVCalculator; see [nav-config/assets-and-price-feeds/{chainId}.json](#nav-configassets-and-price-feedschainidjson).
- **`config/nav-config/balance-adapters/{chainId}.json`** and **`config/nav-config/meta-balance-adapters/{chainId}.json`** — Per chain: plain / meta adapters to register on NAVCalculator (meta entries carry `instances`/`instancesRaw`); see [nav-config/balance-adapters & meta-balance-adapters/{chainId}.json](#nav-configbalance-adapters--meta-balance-adapterschainidjson).
- **`config/deployments/{chainId}.json`** — The only place deployed addresses are written (proxies, impls, custom price feeds, balance adapters, bridge adapters); see [deployments/{chainId}.json](#deploymentschainidjson).

The long template below is **deprecated** (single global dev-input is not used). All bridge adapters are authorized with `authorizeAdapter` only — there is no callback-based authorization (see "Bridge adapters: provenance" in this file).

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
        }
      },
      "Across": {
        "enabled": true,
        "chains": ["1", "42161", "10", "8453", "100"],
        "constructor": {
          "spokePoolAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        }
      },
      "Superchain": {
        "enabled": true,
        "chains": ["10", "8453"],
        "constructor": {
          "portalAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        }
      },
      "Gnosis": {
        "enabled": true,
        "chains": ["1", "100"],
        "constructor": {
          "ambAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        }
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

**Bridge adapters: provenance**

As of [ADR 0012](../../docs/decisions/0012-bridge-provable-release-rearchitecture.md) the escrow has **no callback dispatcher** and no `authorizeAdapterWithCallback` / selector registration. Each adapter is the **direct on-chain protocol receiver** on the destination chain and authenticates the inbound message itself (genuine protocol contract as `msg.sender`, source chain, and source sender) before triggering the funded release. So **every** adapter — including CCIP, Across, Stargate, and Gnosis — is authorized with `authorizeAdapter(adapter)` only.

Source-sender authentication is configured per adapter via `setTrustedRemoteAdapter(sourceKey, remoteAdapter)` (admin) after deployment, where `sourceKey` is protocol-specific (chainId / CCIP selector / CCTP domain / LZ eid) and `remoteAdapter` is the sibling adapter's identity (equal to the adapter's own address under CREATE2 same-address deployment). The per-protocol authentic entry points and provenance checks are:

| Adapter    | Authentic destination entry          | Authenticated `msg.sender` | Source authentication |
|-----------|--------------------------------------|----------------------------|-----------------------|
| CCIP      | `ccipReceive(Any2EVMMessage)`        | `== router`                | source selector + `message.sender == trustedRemoteAdapter` |
| Across    | `handleV3AcrossMessage(...)` (V3)    | `== spokePool`             | token/amount bound to invoice + `trustedRemoteAdapter` |
| Stargate  | `lzCompose(...)` (V2)                | `== endpoint`              | `srcEid` + `composeFrom == trustedRemoteAdapter` |
| Gnosis    | `onTokenTransfer(address,uint256,bytes)` (ERC677) | `== omnibridge` | `amb.messageSender() == trustedRemoteAdapter` + source chain |
| CCTP      | manager `completeBridge` + Circle attestation | n/a (attestation) | message-body binding + nonce dedup |
| Superchain| L1→L2 messenger / L2→L1 portal proof | `== l2Messenger` (+ `xDomainMessageSender`) | xDomain sender; portal proof + real OP withdrawal hash |

See `src/bridge/BRIDGE_ADAPTERS.md` §7 for the full per-protocol detail.

**CCTP domain mapping:** The CCTP adapter maps chain IDs to Circle's CCTP domain IDs (used for `depositForBurn` and receive path). Each chain that has CCTP can include `cctpDomain` in the CCTP entry's `initialize` block (`CCTP.initialize`) for reference — that entry now lives in `contracts-deployment-config/bridge-adapters/{chainId}.json`, not the chain config. The on-chain mapping is set via `CctpBridgeAdapter.setDomainMapping(chainId, domain)` (admin); deploy scripts do not call this — configure it after deployment (e.g. manage script or Safe tx). Official domain IDs (see [Circle CCTP contract addresses](https://developers.circle.com/cctp/references/contract-addresses)): Ethereum = 0, OP Mainnet = 2, Arbitrum = 3, Base = 6.

The script `script/manage/AuthorizeBridgeAdapters.s.sol` authorizes each enabled adapter with `authorizeAdapter(adapter)` only (no callback variant). Trusted source senders are configured separately via `BridgeAdapter.setTrustedRemoteAdapter` (admin), not by the authorization script.

**Special Values:**
- `$FROM_CHAIN_CONFIG`: Scripts look up the value from the chain config for that chain
- `$DEPLOYED_NAV_ADDRESS`: Replaced with NAVCalculator proxy address after deployment
- `$DEPLOYED_BRIDGE_ADDRESS`: Replaced with BridgeEscrow proxy address after deployment

---

## CREATE2 Salts

CREATE2 salts for deterministic deployments are **computed in code** from the contract name + version — there is no salt JSON file to maintain. The impl/library layer (steps `01`/`02`) deploys via the canonical CREATE2 deployer using these salts; balance/price/bridge adapters use plain CREATE (see CLAUDE.md).

### Salt Generation Logic

```solidity
// ConfigReader.computeSalt(name, version) — exposed as BaseDeployScript.generateSalt(name, version)
bytes32 salt = keccak256(abi.encodePacked("NAVCalculatorProxy", uint256(1)));
```

**When to increment version:**
- You want a NEW deterministic address
- After upgrading, if you want to deploy a fresh proxy rather than upgrade existing one
- Keep version 1 to maintain same addresses across chains

---

## Deployment Output

After deployment, addresses are saved to `deployments/{chainId}.json`.

> **Note:** The current deploy scripts write the **flat** shape documented under [deployments/{chainId}.json](#deploymentschainidjson) — top-level proxy/impl address keys plus name→address maps under `customPriceFeeds` / `balanceAdapters` / `bridgeAdapters` (each value is just an address string). The richer example below (with `core`, `priceAdapters`, per-entry `constructor`/`verified` metadata) is illustrative and is **not** the format the scripts emit today.

### Format (illustrative — not emitted by current scripts)

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

When chain config has `"rpc": "$ALCHEMY"`, **ConfigReader** (used by deploy scripts) builds the URL from the **ALCHEMY_API_KEY** environment variable.

URL format: `https://{network}.g.alchemy.com/v2/{apiKey}` (network is derived from chain ID). So you can run scripts without passing `--rpc-url` if `ALCHEMY_API_KEY` is set. Fork tests use the same Alchemy fallback in **TestEnvConfigurator.getAlchemyUrl**, which first checks chain-specific overrides (`MAINNET_URL`, `ARBITRUM_URL`, etc.) before falling back to `ALCHEMY_API_KEY`.

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

### Running the deploy scripts (signer)

The deploy flow is EOA-driven. The canonical signer is a Foundry keystore account (`--account $DEPLOYER_NAME`, imported once via `cast wallet import`); swap in `--ledger` for hardware-wallet signing if preferred. See `script/deploy/README.md` for the full step order.

```bash
# Keystore account (recommended); add --ledger instead for a hardware wallet
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --chain-id 1 --broadcast --account $DEPLOYER_NAME
# Then run 02_DeployProxies.s.sol per chain (deploys and initializes proxies in one go).
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
// BridgeEscrow: Authorize adapter (no callback variant exists post-ADR 0012)
BridgeEscrow.authorizeAdapter(adapterAddress);

// BridgeAdapter: Configure the trusted sibling adapter per source chain
// (sourceKey is protocol-specific: chainId / CCIP selector / CCTP domain / LZ eid)
BridgeAdapter.setTrustedRemoteAdapter(sourceKey, remoteAdapterIdentity);

// BridgeAdapter: Grant MANAGER to operations address (gates completeBridge / recoverStuckAssets)
BridgeAdapter.grantRole(MANAGER, managerAddress);
```

---

## Configuration Checklist

### Pre-Deployment

- [ ] Fill `script/config/chains/{chainId}.json` with `addresses.securityCouncil`, `addresses.admin`, `addresses.manager` (per chain)
- [ ] Add assets to register on NAVCalculator with correct price feeds in `nav-config/assets-and-price-feeds/{chainId}.json`
- [ ] Add custom price feeds to deploy in `contracts-deployment-config/custom-price-feeds/{chainId}.json`
- [ ] Add asset symbols for BridgeEscrow (with addresses per chain)
- [ ] Enable/disable adapters to deploy per chain in `contracts-deployment-config/balance-adapters/{chainId}.json` (plain) and `contracts-deployment-config/meta-balance-adapters/{chainId}.json` (meta)
- [ ] List adapters to register on NAV in `nav-config/balance-adapters/{chainId}.json` (plain) and `nav-config/meta-balance-adapters/{chainId}.json` (meta)
- [ ] Verify protocol addresses in `chains/{chainId}.json`, `contracts-deployment-config/`, and `nav-config/`
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

> **Deprecated** — the examples below use the old single `dev-input.json` shape. Current scripts read the per-concern, per-chain files under `contracts-deployment-config/` and `nav-config/`, plus the per-chain `chains/{chainId}.json` files instead; deployed addresses are written to `deployments/{chainId}.json`. Kept for reference only.

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
- Verify you're using the same salt (computed in code from contract name + version — see [CREATE2 Salts](#create2-salts))
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
- [OpenZeppelin UUPS](https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable)
- [Chainlink Price Feeds](https://docs.chain.link/data-feeds/price-feeds/addresses)
