# Configuration Guide

This guide explains all configuration files needed for multi-chain deployments of NAVCalculator and BridgeEscrow.

## Table of Contents

1. [Configuration Files Overview](#configuration-files-overview)
2. [chain-config.json](#chain-configjson)
3. [dev-input.json](#dev-inputjson)
4. [salt-config.json](#salt-configjson)
5. [Deployment Output](#deployment-output)
6. [Environment Variables](#environment-variables)
7. [Role Management](#role-management)

---

## Configuration Files Overview

```
config/
├── chain-config.json          # Chain-specific parameters (RPC, explorers, protocol addresses)
├── dev-input.json             # User-provided deployment parameters (roles, initial config)
├── salt-config.json           # CREATE2 salts (auto-generated, version controlled)
└── README.md                  # This file

deployments/
├── 1-addresses.json           # Deployed contract addresses (Mainnet)
├── 42161-addresses.json       # Arbitrum
├── 10-addresses.json          # Optimism
└── ...                        # One file per chain

safe-transactions/
├── 1-deploy-implementations.json
├── 1-deploy-proxies-and-initialize.json   # Safe transaction JSONs for multisig execution
└── ...
```

---

## chain-config.json

Chain-specific infrastructure parameters. **Use environment variables for sensitive values.**

### Template

```json
{
  "chains": {
    "1": {
      "name": "mainnet",
      "rpc": "$MAINNET_RPC_URL",
      "explorer": {
        "url": "https://etherscan.io",
        "apiUrl": "https://api.etherscan.io/api",
        "apiKey": "$ETHERSCAN_API_KEY"
      },
      "sourcify": {
        "apiUrl": "https://sourcify.dev/server"
      },
      "create2DeployerAddress": "",
      "chainlinkSequencerFeed": "0x0000000000000000000000000000000000000000",
      "nativeTokenSymbol": "ETH",
      "nativeTokenAddress": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
      "protocols": {
        "aaveV3Pool": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
        "compoundCometUSDC": "0xc3d688B66703497DAA19211EEdff47f25384cdc3",
        "morphoBlue": "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
        "sparkPool": "0xC13e21B648A5Ee794902342038FF3aDAB66BE987",
        "ccipRouter": "0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D",
        "acrossSpokePool": "0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5"
      }
    },
    "42161": {
      "name": "arbitrum",
      "rpc": "$ARBITRUM_RPC_URL",
      "explorer": {
        "url": "https://arbiscan.io",
        "apiUrl": "https://api.arbiscan.io/api",
        "apiKey": "$ARBISCAN_API_KEY"
      },
      "sourcify": {
        "apiUrl": "https://sourcify.dev/server"
      },
      "create2DeployerAddress": "",
      "chainlinkSequencerFeed": "0xFdB631F5EE196F0ed6FAa767959853A9F217697D",
      "nativeTokenSymbol": "ETH",
      "nativeTokenAddress": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
      "protocols": {
        "aaveV3Pool": "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
        "compoundCometUSDC": "0xA5EDBDD9646f8dFF606d7448e414884C7d905dCA",
        "morphoBlue": "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
        "ccipRouter": "0x141fa059441E0ca23ce184B6A78bafD2A517DdE8",
        "acrossSpokePool": "0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A"
      }
    },
    "10": {
      "name": "optimism",
      "rpc": "$OPTIMISM_RPC_URL",
      "explorer": {
        "url": "https://optimistic.etherscan.io",
        "apiUrl": "https://api-optimistic.etherscan.io/api",
        "apiKey": "$OPTIMISM_ETHERSCAN_API_KEY"
      },
      "sourcify": {
        "apiUrl": "https://sourcify.dev/server"
      },
      "create2DeployerAddress": "",
      "chainlinkSequencerFeed": "0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389",
      "nativeTokenSymbol": "ETH",
      "nativeTokenAddress": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
      "protocols": {
        "aaveV3Pool": "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
        "ccipRouter": "0x3206695CaE29952f4b0c22a169725a865bc8Ce0f",
        "acrossSpokePool": "0x6f26Bf09B1C792e3228e5467807a900A503c0281",
        "superchainPortal": "0xbEb5Fc579115071764c7423A4f12eDde41f106Ed"
      }
    },
    "8453": {
      "name": "base",
      "rpc": "$BASE_RPC_URL",
      "explorer": {
        "url": "https://basescan.org",
        "apiUrl": "https://api.basescan.org/api",
        "apiKey": "$BASE_ETHERSCAN_API_KEY"
      },
      "sourcify": {
        "apiUrl": "https://sourcify.dev/server"
      },
      "create2DeployerAddress": "",
      "chainlinkSequencerFeed": "0xBCF85224fc0756B9Fa45aA7892530B47e10b6433",
      "nativeTokenSymbol": "ETH",
      "nativeTokenAddress": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
      "protocols": {
        "aaveV3Pool": "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5",
        "ccipRouter": "0x881e3A65B4d4a04dD529061dd0071cf975F58bCD",
        "acrossSpokePool": "0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64",
        "superchainPortal": "0x49048044D57e1C92A77f79988d21Fa8fAF74E97e"
      }
    },
    "100": {
      "name": "gnosis",
      "rpc": "$GNOSIS_RPC_URL",
      "explorer": {
        "url": "https://gnosisscan.io",
        "apiUrl": "https://api.gnosisscan.io/api",
        "apiKey": "$GNOSIS_ETHERSCAN_API_KEY"
      },
      "sourcify": {
        "apiUrl": "https://sourcify.dev/server"
      },
      "create2DeployerAddress": "",
      "chainlinkSequencerFeed": "0x0000000000000000000000000000000000000000",
      "nativeTokenSymbol": "xDAI",
      "nativeTokenAddress": "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
      "protocols": {
        "aaveV3Pool": "0xb50201558B00496A145fE76f7424749556E326D8",
        "gnosisAMB": "0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59",
        "acrossSpokePool": "0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5"
      }
    }
  }
}
```

### Field Descriptions

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Human-readable chain name |
| `rpc` | string | RPC URL (use env var placeholder like `$MAINNET_RPC_URL`) |
| `explorer.url` | string | Block explorer base URL |
| `explorer.apiUrl` | string | Block explorer API endpoint |
| `explorer.apiKey` | string | API key for verification (use env var) |
| `sourcify.apiUrl` | string | Sourcify API endpoint |
| `create2DeployerAddress` | string | Deployed Create2Deployer library address (filled after deployment) |
| `chainlinkSequencerFeed` | address | L2 sequencer uptime feed (use 0x0 for L1) |
| `nativeTokenSymbol` | string | Native token symbol (ETH, xDAI, etc.) |
| `nativeTokenAddress` | address | ERC-7528 convention address for native token |
| `protocols.*` | address | Protocol-specific contract addresses for adapters |

---

## dev-input.json

User-provided deployment parameters. **This is where you fill in your specific values.**

### Template

```json
{
  "meta": {
    "version": "1.0.0",
    "description": "Deployment configuration for onchain-accounting system"
  },
  "global": {
    "safeMultisigAddress": "",
    "admin": "",
    "assetRecoverer": "",
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
          "description": "Uses aaveV3Pool from chain-config.json"
        }
      },
      "CompoundV3": {
        "enabled": true,
        "chains": ["1", "42161"],
        "constructor": {
          "cometAddress": "$FROM_CHAIN_CONFIG",
          "navCalculator": "$DEPLOYED_NAV_ADDRESS",
          "description": "Uses compoundCometUSDC from chain-config.json"
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
        "callbackSelector": "0x97a657c9"
      },
      "Across": {
        "enabled": true,
        "chains": ["1", "42161", "10", "8453", "100"],
        "constructor": {
          "spokePoolAddress": "$FROM_CHAIN_CONFIG",
          "bridgeEscrow": "$DEPLOYED_BRIDGE_ADDRESS",
          "version": "1.0.0"
        },
        "callbackSelector": "0x371c4254"
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
        "callbackSelector": null
      }
    }
  }
}
```

### Field Descriptions

#### Global Section

| Field | Description | Example |
|-------|-------------|---------|
| `safeMultisigAddress` | Your Safe multisig address (same on all chains) | `0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5` |
| `admin` | Address with DEFAULT_ADMIN_ROLE (typically the Safe) | `0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5` |
| `assetRecoverer` | Address that can recover wrongly sent funds | `0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5` |
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
  - Use `$FROM_CHAIN_CONFIG` to reference `protocols.*` from chain-config.json
  - Use `$DEPLOYED_NAV_ADDRESS` or `$DEPLOYED_BRIDGE_ADDRESS` for deployed contracts
- `callbackSelector`: (Bridge adapters only) Function selector for protocol callbacks

**Special Values:**
- `$FROM_CHAIN_CONFIG`: Scripts will look up the value from chain-config's `protocols` section
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

After deployment, addresses are saved to `deployments/{chainId}-addresses.json`.

### Format

```json
{
  "chainId": 1,
  "chainName": "mainnet",
  "timestamp": "2024-01-15T10:30:00Z",
  "deployer": "0x1234...",
  "safeMultisig": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5",
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
    "AaveV3Instance": {
      "address": "0x222...",
      "constructor": {
        "poolAddress": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
        "navCalculator": "0xdef..."
      },
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
      "callbackSelector": "0x97a657c9",
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

Set these in your `.env` file (never commit to git!):

```bash
# RPC URLs
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

# Deployment Keys (for implementations and libraries, NOT core proxies)
DEPLOYER_PRIVATE_KEY=0x...  # Use with caution, or use --ledger

# Safe Transaction Service (optional, for API submission)
SAFE_TX_SERVICE_URL=https://safe-transaction-mainnet.safe.global
```

### Using Ledger (Recommended)

```bash
# Instead of private key, use Ledger for extra security
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --chain-id 1
# Then run 02_DeployProxiesAndInitialize.s.sol per chain; execute generated Safe TXs via Safe UI.
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
└─ Typically assigned to: Safe Multisig

MANAGER (keccak256("MANAGER"))
├─ NAVCalculator:
│  ├─ registerAsset()
│  ├─ unregisterAsset()
│  ├─ setPriceFeed()
│  ├─ unsetPriceFeed()
│  ├─ addBalanceOracle()
│  ├─ removeBalanceOracle()
│  ├─ includeAssetInDefaultOracle()
│  ├─ excludeAssetFromDefaultOracle()
│  ├─ setChainlinkL2SequencerUptimeFeed()
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
    assetRecoverer,
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

- [ ] Fill `dev-input.json` with Safe multisig address
- [ ] Fill admin, manager, assetRecoverer addresses
- [ ] Add initial assets for NAVCalculator with correct price feeds
- [ ] Add asset symbols for BridgeEscrow (with addresses per chain)
- [ ] Enable/disable adapters per chain
- [ ] Verify protocol addresses in `chain-config.json`
- [ ] Set environment variables in `.env`
- [ ] Test RPC URLs are working
- [ ] Verify block explorer API keys are valid

### Post-Deployment

- [ ] Verify all contracts on Etherscan and Sourcify
- [ ] Save deployment addresses to `deployments/{chainId}-addresses.json`
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

### Example 1: Mainnet + Arbitrum Setup

**dev-input.json (relevant sections):**

```json
{
  "global": {
    "safeMultisigAddress": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5",
    "admin": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5",
    "assetRecoverer": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5",
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
