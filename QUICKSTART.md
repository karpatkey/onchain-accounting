# Quick Start Guide

## Prerequisites
- Foundry installed (`foundryup`)
- A funded **deployer EOA** (holds admin + manager through deploy/config; everything is broadcast from this key — no Safe executes deploy txs)
- The **security-council Safe** address on target chains (receives admin at the end, via step 07)
- RPC and API keys ready

## Step 1: Configure Environment

Create `.env` file:
```bash
# RPC (chain config uses "rpc": "$ALCHEMY"; scripts build URL from this key)
ALCHEMY_API_KEY=your_alchemy_key

# Explorer API keys (for verification)
ETHERSCAN_API_KEY=YOUR_KEY
ARBISCAN_API_KEY=YOUR_KEY

# Foundry keystore account name for the deployer EOA (see Step 1b)
DEPLOYER_NAME=my-deployer
```

Load it:
```bash
source .env
```

## Step 1b: Import Deployer Key into Foundry Keystore

Before deploying, import the deployer's private key into Foundry's encrypted keystore (one-time setup):

```bash
cast wallet import $DEPLOYER_NAME --interactive
```

You will be prompted for the private key and a password to encrypt it. The key is stored at:

```
~/.foundry/keystores/$DEPLOYER_NAME
```

The keystore persists until manually deleted (`rm ~/.foundry/keystores/$DEPLOYER_NAME`). The private key is never stored in `.env` or the repo.

## Step 2: Edit Configuration

Edit the chain config for each chain you deploy to, e.g. `script/config/chains/1.json` for Mainnet:
```json
{
  "addresses": {
    "admin": "0xYourDeployerEOA",
    "manager": "0xYourDeployerEOA",
    "securityCouncil": "0xYourCouncilSafe"
  }
}
```

Set `addresses.admin` and `addresses.manager` to the **deployer EOA** (they hold DEFAULT_ADMIN_ROLE + MANAGER through deploy/config), and `addresses.securityCouncil` to the **council Safe** that becomes the end-state admin in step 07. All non-zero. See `script/config/CONFIG_GUIDE.md` for the full schema.

## Step 3: Deploy Implementations (One-time)

**Note:** We use the canonical CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C) which is the same on all chains. No need to deploy a custom Create2Deployer.

Deploy the libraries + implementations directly from the deployer EOA (CREATE2, so the addresses are the same on every chain — but run it once on each chain you deploy to):

```bash
PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

`PERSIST_DEPLOYMENTS=1` is what writes the addresses to `script/config/deployments/<chainId>.json`; without it they are only logged, and the later steps that read them fail.

## Step 4: Deploy Core Contracts (Proxies + Init, per chain)

**4a. Deploy implementations (once per chain)** — already done in Step 3.

**4b. Deploy proxies and initialize (per chain)** — run once per chain. This deploys a placeholder impl + NAV + Bridge proxies and initializes them in one EOA transaction (deterministic addresses across chains):

```bash
# Mainnet
PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --account $DEPLOYER_NAME

# Other chains: same script with that chain's RPC and --chain-id (e.g. 42161, 10, 8453, 100)
```

Proxy addresses are identical on all chains. 02 does deploy + init + role-grant (to the deployer EOA) in one EOA transaction.

## Step 5: Deploy on Other Chains

Repeat Steps 3 and 4b on each chain (run `01_DeployImplementations.s.sol`, then `02_DeployProxies.s.sol`, with that chain's RPC and `--chain-id`). The addresses come out identical everywhere, but each chain still needs its own broadcast: `02` reads `NAVCalculatorImplementation` + `BridgeEscrowImplementation` out of that chain's deployments file and reverts with "Run 01_DeployImplementations.s.sol first." when they are missing.

## Step 5b: Deploy the AssetKindRegistry (before asset registration, and before Step 8)

Deploys the per-chain `AssetKindRegistry`, points the NAV at it, grants it `MANAGER` on the NAV, and classifies every asset in `script/config/nav-config/assets-and-price-feeds/<chainId>.json`:

```bash
PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/08_DeployAssetKindRegistry.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

It is numbered 08 but it is **not** the last step: the `grantRole` needs `DEFAULT_ADMIN_ROLE`, which Step 8 (`07_…`) hands away, so it must run before that. `RegisterAssets.s.sol` routes an asset's primary registration through this registry and reverts (`AssetKindRegistryNotDeployed`) if it has not run. It is fail-closed: every configured asset must carry a valid `accrualKind` string or the script aborts.

## Step 6: Deploy Adapters (Optional)

Enable the adapters/feeds you need in `script/config/contracts-deployment-config/{custom-price-feeds,balance-adapters,meta-balance-adapters,bridge-adapters}/<chainId>.json` (`.<name>.enabled`), then:

```bash
# Price feeds (deploys the custom feed contracts only — asset/feed
# registration on NAVCalculator is a separate step: script/manage/RegisterAssets.s.sol)
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME \
  --broadcast

# Balance adapters (PERSIST_DEPLOYMENTS=1: the three assistant contracts are
# recorded through the gated writer, so without it a re-run deploys duplicates)
PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME \
  --broadcast

# Bridge adapters (optional)
forge script script/deploy/05_DeployBridgeAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" --account $DEPLOYER_NAME --broadcast
```

## Step 7: Configure (register adapters, meta-instances, bridge adapters)

Run by the deployer EOA (holds admin + MANAGER). Idempotent / re-runnable:

```bash
forge script script/deploy/06_Configure.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" --chain-id 1 --account $DEPLOYER_NAME --broadcast
```

## Step 8: Transfer admin to the security council (run LAST)

Grants DEFAULT_ADMIN_ROLE + MANAGER to `addresses.securityCouncil` on both proxies (and each deployed bridge adapter) and renounces the deployer's roles:

```bash
DEPLOYER_EOA=0xYourDeployerEOA \
forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" --chain-id 1 --account $DEPLOYER_NAME --broadcast
```

## Step 9: Verify Contracts

```bash
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Then run the wrapper, which parses the emitted VERIFY|... lines,
# skips already-verified contracts, and runs forge verify-contract for the rest:
script/verify/verify-all.sh
```

## Need Help?

- **Full deployment guide**: See `script/DEPLOYMENT_SUMMARY.md`
- **Config reference**: See `script/config/README.md` and `script/config/CONFIG_GUIDE.md`
- **Deploy script details**: See `script/deploy/README.md`
