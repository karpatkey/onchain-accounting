# Quick Start Guide

## Prerequisites
- Foundry installed (`foundryup`)
- Safe multisig deployed on target chains
- RPC endpoints and API keys ready

## Step 1: Configure Environment

Create `.env` file:
```bash
# RPC URLs
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY

# API Keys
ETHERSCAN_API_KEY=YOUR_KEY
ARBISCAN_API_KEY=YOUR_KEY

# Deployer Key (only for implementations)
PRIVATE_KEY=0x...
```

Load it:
```bash
source .env
```

## Step 2: Edit Configuration

Edit `script/config/dev-input.json`:
```json
{
  "global": {
    "safeMultisigAddress": "0xYourSafeAddress",
    "admin": "0xYourSafeAddress",
    "assetRecoverer": "0x...",
    "manager": "0x..."
  }
}
```

## Step 3: Deploy Create2Deployer (One-time)

```bash
# Mainnet
forge script script/deploy/00_DeployCreate2Deployer.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Arbitrum
forge script script/deploy/00_DeployCreate2Deployer.s.sol \
  --rpc-url $ARBITRUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Update `script/config/chain-config.json` with the deployed addresses.

## Step 4: Deploy Core Contracts

```bash
# Deploy NAVCalculator on mainnet
forge script script/deploy/01_DeployNAVCalculator.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# This generates: safe-transactions/1-deploy-navcalc-proxy.json
```

**Execute via Safe UI:**
1. Go to https://app.safe.global
2. Import `safe-transactions/1-deploy-navcalc-proxy.json`
3. Sign and execute

Repeat for BridgeEscrow:
```bash
forge script script/deploy/02_DeployBridgeEscrow.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Step 5: Deploy on Other Chains

Repeat steps 3-4 on each chain. **Proxy addresses will be identical!**

```bash
# Arbitrum
forge script script/deploy/01_DeployNAVCalculator.s.sol \
  --rpc-url $ARBITRUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

forge script script/deploy/02_DeployBridgeEscrow.s.sol \
  --rpc-url $ARBITRUM_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Step 6: Deploy Adapters (Optional)

Edit scripts to uncomment needed adapters, then:

```bash
# Price adapters
forge script script/deploy/03_DeployPriceAdapters.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Balance adapters
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Step 7: Verify Contracts

```bash
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url $MAINNET_RPC_URL

# Copy and run the generated commands
```

## Need Help?

- **Full guide**: See `script/DEPLOYMENT_README.md`
- **Architecture**: See `script/DEPLOYMENT_PLAN.md`
- **Summary**: See `script/DEPLOYMENT_SUMMARY.md`
