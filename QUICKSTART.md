# Quick Start Guide

## Prerequisites
- Foundry installed (`foundryup`)
- Safe multisig deployed on target chains
- RPC and API keys ready

## Step 1: Configure Environment

Create `.env` file:
```bash
# RPC (chain config uses "rpc": "$ALCHEMY"; scripts build URL from this key)
ALCHEMY_API_KEY=your_alchemy_key

# Explorer API keys (for verification)
ETHERSCAN_API_KEY=YOUR_KEY
ARBISCAN_API_KEY=YOUR_KEY

# Deployer key (for implementations and 02_DeployProxies)
PRIVATE_KEY=0x...
```

Load it:
```bash
source .env
```

## Step 2: Edit Configuration

Edit the chain config for each chain you deploy to, e.g. `script/config/chains/1.json` for Mainnet:
```json
{
  "addresses": {
    "safeMultisig": "0xYourSafeAddress",
    "admin": "0xYourSafeAddress",
    "manager": "0x..."
  }
}
```

Set `addresses.safeMultisig`, `addresses.admin`, and `addresses.manager` (all non-zero). See `script/config/CONFIG_GUIDE.md` for the full schema.

## Step 3: Deploy Implementations (One-time)

**Note:** We use the canonical CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C) which is the same on all chains. No need to deploy a custom Create2Deployer.

Generate Safe transactions to deploy implementations (or deploy via EOA with `--broadcast --private-key`):

```bash
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
# Generates: safe-transactions/1-deploy-implementations.json (2 txs)
```

**Execute via Safe UI:** Import `safe-transactions/1-deploy-implementations.json` → sign and execute (once).

## Step 4: Deploy Core Contracts (Proxies + Init, per chain)

**4a. Deploy implementations (once)** — already done in Step 3.

**4b. Deploy proxies and initialize (per chain)** — run once per chain. This deploys placeholder + NAV + Bridge proxies and initializes them in one EOA transaction (deterministic addresses across chains):

```bash
# Mainnet
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --private-key "$PRIVATE_KEY"

# Other chains: same script with that chain's RPC and --chain-id (e.g. 42161, 10, 8453, 100)
```

Proxy addresses are identical on all chains. No separate Safe TX for init; 02 does deploy + init via EOA.

## Step 5: Deploy on Other Chains

Repeat Step 4b on each chain (run `02_DeployProxies.s.sol` with that chain’s RPC and `--chain-id`).

## Step 6: Deploy Adapters (Optional)

Edit chain config and scripts to enable needed adapters, then:

```bash
# Price feeds
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --private-key $PRIVATE_KEY \
  --broadcast

# Balance adapters
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Step 7: Verify Contracts

```bash
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Copy and run the generated commands
```

## Need Help?

- **Full deployment guide**: See `script/DEPLOYMENT_SUMMARY.md`
- **Config reference**: See `script/config/README.md` and `script/config/CONFIG_GUIDE.md`
- **Deploy script details**: See `script/deploy/README.md`
