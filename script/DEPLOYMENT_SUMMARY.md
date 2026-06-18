# Deployment System Summary

> **⚠️ Deployment is now EOA-only.** A single **deployer EOA** runs every step (`forge script … --broadcast`); no Safe executes any deploy/config transaction. The deployer holds `DEFAULT_ADMIN_ROLE` + `MANAGER` through deploy/config, and the final step `07_TransferAdminToSecurityCouncil.s.sol` hands those roles to the **security-council Safe** (`addresses.securityCouncil`) and renounces the deployer's. The council Safe is the end-state admin and drives post-deploy **upgrades** via `script/upgrade/*` (which still emit Safe-TX batches). **`script/deploy/README.md` is the authoritative, up-to-date procedure** — the Safe-TX-bundle steps described in some sections below are historical and superseded for deployment/configuration (`SafeTxBuilder` is retained only for the council's governance/upgrade scripts).

> **⚠️ NAV v2 full redeploy in progress.** All prior deployment evidence has been wiped — NAVCalculator impl/proxy, BridgeEscrow impl/proxy, the UUPS placeholder, ERC20Default, every balance/meta adapter, every custom price-feed adapter, and every bridge adapter are being **redeployed from scratch (new bytecode)**. Treat every deployed address as **TBD**. Addresses are written to `script/config/deployments/{chainId}.json` as each contract lands (the only place addresses live; broadcast logs are not committed). The `PriceFeedLib` / `NavRegistryLib` library pins are build config and are unchanged.

## ✅ What Has Been Implemented

This deployment system uses an **EOA deployer** (`--broadcast`) with **CREATE2 deterministic addresses** across multiple chains, handing admin to a security-council Safe at the end (step 07).

### Core Infrastructure

#### 1. **Create2Deployer Library** (`src/deployment/Create2Deployer.sol`)
- Stateless CREATE2 deployment library for Safe delegatecall
- Enables deterministic proxy addresses across all chains
- Safe becomes the deployer (address squatting prevention)

#### 2. **Utility Contracts** (`script/utils/`)
- **BaseDeployScript.sol** - Base contract with common deployment utilities
- **SafeTxBuilder.sol** - Generates Safe transaction JSON files
- **ConfigReader.sol** - Reads chain-config.json and dev-input.json

#### 3. **UUPS Upgradeability**
- ✅ **NAVCalculator** - Already UUPS upgradeable
- ✅ **BridgeEscrow** - Added UUPS upgradeability with `_authorizeUpgrade` and storage gap

### Deployment Scripts (`script/deploy/`)

| Script | Purpose | Output |
|--------|---------|--------|
| `01_DeployImplementations.s.sol` (`01_2` = NAV only) | Deploy `PriceFeedLib` + `NavRegistryLib` libraries then NAVCalculator (and BridgeEscrow) **implementations** via EOA `--broadcast` (CREATE2, canonical deployer 0x4e59...). Same impl addresses on all chains; run once. | Saved impl/library addresses |
| `02_DeployProxies.s.sol` (`02_2` = NAV only) | Deploy placeholder + NAV + Bridge **proxies** and **initialize** them via EOA (canonical CREATE2). Default: one atomic tx via `AtomicProxyDeployer`, granting DEFAULT_ADMIN + MANAGER to `admin`/`manager` (= deployer EOA). `USE_LEGACY_DEPLOY=1` for legacy multi-tx. Run **per chain**. | Proxy addresses (same on all chains); saved to config |
| `03_DeployPriceFeeds.s.sol` | Deploy custom price feed adapters; register assets/feeds (per-chain, config-driven) | Adapter addresses in config |
| `04_DeployBalanceAdapters.s.sol` | Deploy balance adapter adapters incl. meta-adapters (per-chain, config-driven) | Adapter addresses in config |
| `05_DeployBridgeAdapters.s.sol` | Deploy bridge adapters (CCIP, Across, Stargate, CCTP, Superchain; per-chain) | Adapter addresses in config |
| `06_Configure.s.sol` | **EOA broadcast** (deployer holds admin+MANAGER): `addBalanceAdapters` for each deployed adapter + `addMetaInstances`/`removeMetaInstances` for meta-adapters + authorize bridge adapters. Idempotent / re-runnable. | On-chain config txs |
| `07_TransferAdminToSecurityCouncil.s.sol` | **EOA broadcast, run LAST**: grant DEFAULT_ADMIN + MANAGER to `addresses.securityCouncil` (Safe) on both proxies, revoke/renounce the deployer's roles. | On-chain role handoff |

### Upgrade Scripts (`script/upgrade/`)

| Script | Purpose |
|--------|---------|
| `UpgradeNAVCalculator.s.sol` | Upgrade NAVCalculator implementation |
| `UpgradeBridgeEscrow.s.sol` | Upgrade BridgeEscrow implementation |

### Management Scripts (`script/manage/`)

| Script | Purpose |
|--------|---------|
| `ManageAdapters.s.sol` | Add/remove/configure adapters via Safe |

### Verification Scripts (`script/verify/`)

| Script | Purpose |
|--------|---------|
| `VerifyEtherscan.s.sol` | Generate Etherscan verification commands |

### Configuration Files (`script/config/`)

| File / Path | Purpose |
|-------------|---------|
| `chains/{chainId}.json` | Per-chain config: RPC, explorer, Safe, roles, `addresses` block, adapter enable flags |
| `nav-config/assets-and-price-feeds/{chainId}.json` | Asset registry: each asset's `address` + `priceFeeds[]` (the assets to register on NAVCalculator) |
| `contracts-deployment-config/price-feeds/{chainId}.json` | Custom price-oracle adapters to deploy (`enabled` + `constructor` args) |
| `contracts-deployment-config/balance-adapters/{chainId}.json` | Balance + meta adapters to deploy (`enabled` + `constructor`) |
| `nav-config/balance-adapters/{chainId}.json` & `nav-config/meta-balance-adapters/{chainId}.json` | Adapters to register on NAVCalculator (plain vs. meta; meta entries carry `instances` / `instancesRaw`) |
| `script/config/deployments/{chainId}.json` | **Deployed-address state** — the *only* place deployed addresses are written. Populated by the deploy scripts as contracts land. Broadcast logs are no longer committed. For the NAV v2 from-scratch redeploy every field here starts **TBD** (empty). |
| (No separate `dev-input.json`, `assets.json`, or `balance-adapters.json`) | All user input lives in `chains/{chainId}.json` (`addresses` + adapter flags) plus the per-concern `contracts-deployment-config/` and `nav-config/` files above |

## Deployment Workflow

### Phase 1: No separate Create2Deployer

The project uses the **canonical CREATE2 deployer** at `0x4e59b44847b379578588920cA78FbF26c0B4956C` (same on all EVM chains). No `00_DeployCreate2Deployer` script is used.

### Phase 2: Core Contract Deployment

**Step 1 — Deploy implementations (once)**

Run `01_DeployImplementations.s.sol` **once**. Without `--broadcast`: generates `safe-transactions/{chainId}-deploy-implementations.json` (2 txs) for Safe UI. With `--broadcast --account`: deploys via EOA. Same implementation addresses on all chains.

```bash
# Generate Safe TX (no broadcast)
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
# Output: safe-transactions/1-deploy-implementations.json (2 txs). Execute in Safe UI once.

# Or deploy via EOA (broadcast)
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

**Step 2 — Deploy and initialize proxies (per chain, via EOA)**

For **each** chain, run `02_DeployProxies.s.sol` with `--broadcast`. It deploys placeholder + NAV + Bridge proxies (CREATE2) and upgrades them to the real implementations with chain-specific init (admin, sequencer feed, native symbol, chainId). Default: **one atomic transaction** via `AtomicProxyDeployer` (no front-run window). Set env `USE_LEGACY_DEPLOY=1` to use the legacy multi-tx path. Also grants MANAGER to the configured manager.

```bash
# Mainnet
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 --broadcast --account $DEPLOYER_NAME

# Arbitrum
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 --broadcast --account $DEPLOYER_NAME
```

Proxy addresses are **identical on every chain** (CREATE2 with placeholder bytecode).

---

## Step-by-step guide (do these in order)

Follow these steps **one by one**. Do not skip steps; later steps depend on earlier ones.

---

### Step 1 — Set up `.env`

In the **project root**, create or edit `.env` (copy from `.env.sample` if needed). Set:

- **`ALCHEMY_API_KEY`** — Used for RPC on all chains (chain config has `"rpc": "$ALCHEMY"`; scripts use `--rpc-url "https://{network}.g.alchemy.com/v2/$ALCHEMY_API_KEY"`).
- **`DEPLOYER_NAME`** — Foundry keystore account name for the deployer EOA. Import once with `cast wallet import $DEPLOYER_NAME --interactive`; key stored at `~/.foundry/keystores/$DEPLOYER_NAME`. Pass as `--account $DEPLOYER_NAME` to `forge script`.
- **Explorer API key** for verification (set the one(s) for your chain(s)):
  - Mainnet: `ETHERSCAN_API_KEY`
  - Arbitrum: `ARBISCAN_API_KEY`
  - Gnosis: `GNOSISSCAN_API_KEY`
  - Base: `BASESCAN_API_KEY`
  - Optimism: `OPTIMISM_ETHERSCAN_API_KEY`

Example `.env`:

```bash
ALCHEMY_API_KEY=your_alchemy_key
DEPLOYER_NAME=my-deployer
ETHERSCAN_API_KEY=...   # and/or ARBISCAN_API_KEY, GNOSISSCAN_API_KEY, etc.
```

**Check:** Run `echo $ALCHEMY_API_KEY` — it should not be empty.

---

### Step 2 — Pick a chain and open its config

Choose one chain for this run (e.g. Mainnet). Open the matching JSON:

- Mainnet: `script/config/chains/1.json`
- Arbitrum: `script/config/chains/42161.json`
- Gnosis: `script/config/chains/100.json`

Leave this file open; you’ll edit it in the next step.

---

### Step 3 — Fill in addresses in the chain config

In the chain JSON, find the **`addresses`** block. Replace the zero addresses with **real** addresses:

- **`securityCouncil`** — Your Safe multisig address (e.g. from [app.safe.global](https://app.safe.global)).
- **`admin`** — Address that will be the admin of NAVCalculator and BridgeEscrow (often the same Safe, or an EOA).
- **`manager`** — Manager role (e.g. Safe or EOA).

All three must be non-zero; the scripts will revert otherwise.

Optional for NAVCalculator (you can leave as-is):

- **`chainlinkSequencerFeed`** — On L2s (Arbitrum, Optimism, etc.) you can set the Chainlink sequencer feed; on Mainnet/Gnosis it can stay `0x0000...`.
- **`nativeTokenSymbol`** — Already set (e.g. `"ETH"`, `"xDAI"`).

Save the file.

**Check:** `addresses.securityCouncil`, `admin`, `manager` are all valid non-zero addresses.

---

### Step 4 — Deploy implementations (once)

Run **once**. Without `--broadcast`: generates **`safe-transactions/{chainId}-deploy-implementations.json`** (2 txs); execute in Safe UI once. With `--broadcast --account`: deploys via EOA. Same impl addresses on all chains.

```bash
# Generate Safe TX
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1

# Or deploy via EOA
forge script script/deploy/01_DeployImplementations.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

**Check:** Script prints and saves NAVCalculatorImplementation and BridgeEscrowImplementation addresses.

### Step 5 — Deploy and initialize proxies (per chain, via EOA)

Run **once per chain** with that chain's RPC and `--chain-id` and **`--broadcast --account`**. The script deploys placeholder + both proxies (CREATE2) and upgrades them to the real implementations with chain-specific init in one go (atomic by default; set `USE_LEGACY_DEPLOY=1` for legacy multi-tx).

**Mainnet (chain 1):**

```bash
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --account $DEPLOYER_NAME
```

**Arbitrum (42161):**

```bash
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 \
  --broadcast \
  --account $DEPLOYER_NAME
```

(Use the same pattern for Gnosis `100`, Base `8453`, Optimism `10`, etc.)

Proxy addresses are **the same on every chain** (CREATE2). Addresses are saved to chain config.

**Check:** On the block explorer, both proxy addresses have code and are initialized.

---
### Step 6 — Verify contracts (optional but recommended)

Verification needs the **explorer API key** for the chain (see below). The verify script reads the chain config and prints ready-to-run `forge verify-contract` commands.

1. **Set the explorer API key** for your chain in `.env`:
   - **Mainnet**: `ETHERSCAN_API_KEY`
   - **Arbitrum**: `ARBISCAN_API_KEY`
   - **Gnosis**: `GNOSISSCAN_API_KEY`
   - **Optimism**: `OPTIMISM_ETHERSCAN_API_KEY`
   - **Base**: `BASESCAN_API_KEY`

2. **Generate verification commands** (use the same chain you deployed to so addresses are correct):

   **Mainnet:**
   ```bash
   forge script script/verify/VerifyEtherscan.s.sol \
     --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
   ```

   **Arbitrum:** `--rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"`  
   **Gnosis:** `--rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"`  
   **Base:** `--rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"`

3. **Run the printed commands** — copy each `forge verify-contract ...` block, ensure the matching API key is in your env (e.g. `ETHERSCAN_API_KEY` for mainnet), then run the command. Run for implementations and proxies (Create2Deployer is not used; canonical deployer is pre-deployed).

---

### Step 7 — Repeat for other chains (if needed)

To deploy on another chain (e.g. Arbitrum after Mainnet):

1. Use that chain’s config: `script/config/chains/42161.json` (etc.).
2. Set **addresses** in that file (Safe and roles can be the same or different).
3. **Step 4** (implementations) is once for all chains; run **Step 5** (02_DeployProxies) per chain with that chain's RPC and `--broadcast --account`.
4. Run **Step 5** once (implementations Safe TX), then **Step 6** for that chain (proxies + init Safe TX; execute in Safe UI for that chain).

Adapter deployment (price feeds, balance adapters, bridge adapters) and configuration come **after** NAVCalculator and BridgeEscrow are deployed; see “Phase 3” and “Phase 4” in the deployment workflow above.

---

### Phase 3: Adapter Deployment

```bash
# Deploy price adapters. Use --rpc-url "https://{network}.g.alchemy.com/v2/$ALCHEMY_API_KEY" for your chain.
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME \
  --broadcast

# Deploy balance adapters
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME \
  --broadcast

# Deploy bridge adapters
forge script script/deploy/05_DeployBridgeAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME \
  --broadcast
```

### Phase 4: Configuration

```bash
# Authorize adapters via Safe
# Edit script/manage/ManageAdapters.s.sol to uncomment desired actions
forge script script/manage/ManageAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Execute generated Safe TX
```

### Phase 5: Verification

```bash
# Generate verification commands (use the Alchemy URL for the chain you deployed to)
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Copy and run the generated commands
```

## Key Features

### ✅ Security
- **Safe Multisig Control** - All deployments require Safe approval
- **Delegatecall Pattern** - Safe becomes deployer, preventing address squatting
- **Role-Based Access** - Admin, Manager, Asset Recoverer roles
- **Upgrade Authorization** - Only admin can authorize upgrades

### ✅ Deterministic Addresses (per chain)
- Same Safe + same salt + **same creation bytecode** = same proxy address on that chain
- Proxy addresses **differ across chains** because the proxy’s creation bytecode includes the **implementation address**, and the implementation is deployed separately on each chain (so it has a different address per chain). Thus CREATE2(deployer, salt, bytecode) yields a different proxy address per chain.
- Canonical CREATE2 deployer (0x4e59...) is the same on all chains; proxy bytecode uses a placeholder so proxy addresses are identical everywhere

### ✅ Upgradeability
- **UUPS pattern** for NAVCalculator and BridgeEscrow
- **Swappable adapters** (not upgradeable, but replaceable)
- Storage gaps for future expansion

### ✅ Multi-Chain Support
- Pre-configured for: Mainnet, Arbitrum, Optimism, Base, Gnosis
- Chain-specific adapter deployments
- Easy to add new chains

### ✅ Safe Transaction Integration
- Generates Safe-compatible JSON files
- Import directly into Safe UI
- Batch transactions for efficiency

## Adapter Types

### Price Adapters (Custom Price Feeds)
- `sDAI_PriceOracle` - Savings DAI price
- `LDO_PriceOracle` - Lido DAO token price
- `sUSDS_PriceOracle` - Sky Savings USDS price
- `CrossRatePriceAdapter` - Cross-rate calculations

### Balance Adapters (Protocol Integrations)
- `ERC20DefaultAdapter` - Wallet ERC20 + native, auto-registered at NAV initialization
- `AaveV3InstancesMetaBalanceAdapter` - Aave V3 lending positions
- `AaveV3SafetyModuleBalanceAdapter` - Aave V3 Safety Module (stkGHO etc.)
- `AaveV2InstancesMetaBalanceAdapter` - Aave V2 aTokens (legacy)
- `AaveUmbrellaBalanceAdapter` - Aave Umbrella stake tokens
- `CompoundV3Comet` - Compound V3 (Comet) base + collateral + rewards
- `MorphoMarketsMetaBalanceAdapter` - Morpho direct market positions
- `MorphoVaultsMetaBalanceAdapter` - MetaMorpho vault positions
- `SparkLendBalanceAdapter` - Spark Lend positions
- `BalancerV3PoolsMetaBalanceAdapter`, `BalancerV3GaugesMetaBalanceAdapter` - Balancer V3 LPs + gauges
- `Aura` - Aura vault/LP positions
- `CurvePoolsMetaBalanceAdapter`, `CurveGaugesMetaBalanceAdapter` - Curve LPs + gauges
- `ConvexRewardsMetaBalanceAdapter` - Convex staking
- `CapBalanceAdapter` - Cap (cUSD + stcUSD aggregated → USDC)
- `DaiDsrBalanceAdapter` - DAI Savings Rate
- `SkySavingsUsdsBalanceAdapter` - Sky USDS savings (sUSDS)
- `FluidFTokensMetaBalanceAdapter`, `FluidVaultsMetaBalanceAdapter` - Fluid lending + vaults
- `GearboxMarketsMetaBalanceAdapter` - Gearbox kpk-curated markets
- `StakeWiseV3VaultsMetaBalanceAdapter` - StakeWise V3 Genesis Vault (osETH/osGNO themselves are Custom-priced ERC20s via `osToken_PriceOracle`, not balance adapters)
- `StaderWithdrawalQueueBalanceAdapter` - Stader pending unstake requests
- `KelpWithdrawalQueueBalanceAdapter` - Kelp DAO rsETH exit queue (multi-asset; payout assets discovered via `lrtConfig().getSupportedAssetList()`)
- `LidoWithdrawalQueueBalanceAdapter` - Lido stETH withdrawal queue (`WithdrawalQueueERC721`; sums open requests, reported as native ETH — the asset paid on claim)
- `UniswapV2PoolsMetaBalanceAdapter`, `UniswapV3PoolsMetaBalanceAdapter` - Uni V2 pairs / V3 pools
- `PancakeSwapV2PoolsMetaBalanceAdapter`, `PancakeSwapV3PoolsMetaBalanceAdapter` - PancakeSwap variants
- `MerklRewardsBalanceAdapter` - Merkl unclaimed rewards (proof-verified mutable cache, ADR 0007)

### Bridge Adapters
- CCIP (Chainlink)
- Across Protocol
- Stargate
- Native L2 bridges (Optimism, Arbitrum, Base)

## Files Generated During Deployment

### Deployment Records (`script/config/deployments/`)

The per-chain `script/config/deployments/{chainId}.json` file is the **single source of truth for deployed addresses** — broadcast logs are no longer committed. For the NAV v2 full redeploy, every address in these files starts **TBD** (empty) and is written back as each contract is redeployed from scratch.

```
script/config/deployments/
├── 1.json          # Mainnet
├── 42161.json      # Arbitrum
├── 10.json         # Optimism
├── 8453.json       # Base
└── 100.json        # Gnosis
```

### Safe Transactions (`safe-transactions/`)
```
safe-transactions/
├── {chainId}-deploy-implementations.json   # From 01 (2 txs; optional if using EOA for impl)
├── {chainId}-configure.json                # From 06 (grant MANAGER, add adapters, authorize adapters)
├── 1-upgrade-navcalc.json                  # From upgrade scripts
└── ... (one per Safe transaction)
```
Note: Proxy deploy + init is done via EOA in 02_DeployProxies.s.sol (no Safe TX JSON).

## Prerequisites for Deployment

### Required
1. ✅ Safe multisig deployed on target chains
2. ✅ `ALCHEMY_API_KEY` in `.env` for RPC (chain config uses `"rpc": "$ALCHEMY"`); explorer API keys for verification
3. ✅ Etherscan (or chain explorer) API keys for verification
4. ✅ **Per-chain config** in `script/config/chains/{chainId}.json`: `addresses.securityCouncil`, `addresses.admin`, `addresses.manager` (all non-zero)
5. ✅ Foundry keystore account imported (`cast wallet import $DEPLOYER_NAME --interactive`) and `DEPLOYER_NAME` set in `.env`

### Recommended
1. ✅ Same Safe address across all chains (via Safe CREATE2 deployment)
2. ✅ Test on testnet first (Sepolia)
3. ✅ Review all generated Safe transactions before execution

## What Requires Manual Steps

### Manual Configuration Needed
1. **Edit `script/config/chains/{chainId}.json`** for each chain: set `addresses.securityCouncil`, `addresses.admin`, `addresses.manager` (and optionally `chainlinkSequencerFeed`, `nativeTokenSymbol` for NAVCalculator)
2. **Uncomment or enable adapters** in chain config and deployment scripts as needed
3. **Execute Safe transactions** via Safe UI after generation (multisig approval)
4. No Create2Deployer step; canonical deployer is used. Config is updated by scripts when addresses are saved (no separate “update” step

### Manual Execution Required
1. Safe transaction execution (multisig approval required)
2. Contract verification on Etherscan (commands generated)
3. Adapter authorization via Safe

## Next Steps to Deploy

1. **Configure** - Fill in `script/config/chains/{chainId}.json` with Safe, admin, manager (and RPC/explorer vars in `.env` if using `$VAR`).
2. **Deploy implementations** - Run `01_DeployImplementations.s.sol` once (generate Safe TX and execute in Safe, or use `--broadcast --account` to deploy via EOA).
3. **Deploy and initialize proxies** - Run `02_DeployProxies.s.sol` **per chain** with `--broadcast --account` (deploys placeholder + proxies and initializes them via EOA; atomic by default).
4. **Deploy adapters** - Run scripts 03–05 with adapters enabled in chain config; broadcast to deploy adapter contracts.
5. **Configure adapters** - Run `06_Configure.s.sol` with `--broadcast --account` (deployer EOA holds admin+MANAGER): adds balance adapters, sets meta-instances, authorizes bridge adapters. Idempotent.
6. **Verify** - Run verification script and run the printed `forge verify-contract` commands.
7. **Transfer admin** - Run `07_TransferAdminToSecurityCouncil.s.sol` last: hands DEFAULT_ADMIN + MANAGER to the council Safe and renounces the deployer's roles.

## What You Need to Do to Deploy NAVCalculator and BridgeEscrow

1. **Per chain (each chain where you deploy)**  
   - Have a Safe multisig and set in `script/config/chains/{chainId}.json`:  
     `addresses.securityCouncil`, `addresses.admin`, `addresses.manager` (all real addresses, not zero).  
   - Optional for NAVCalculator: set `chainlinkSequencerFeed` (L2 sequencer feed; can be zero on L1) and `nativeTokenSymbol` (e.g. `"ETH"`, `"xDAI"`).

2. **Env**  
   - `.env` with `ALCHEMY_API_KEY` (used for RPC on all chains), `DEPLOYER_NAME`, and explorer API key(s) for verification.  
   - `DEPLOYER_NAME` is the Foundry keystore account name (import once with `cast wallet import $DEPLOYER_NAME --interactive`); used for implementations (01, optional) and **02_DeployProxies** (proxies + init via EOA).

3. **Order of operations**  
   - **Implementations** (once):  
     Run `forge script script/deploy/01_DeployImplementations.s.sol --rpc-url <url> --chain-id <id>`.  
     Without `--broadcast`: writes `safe-transactions/{chainId}-deploy-implementations.json` (2 txs). Execute in Safe UI once. With `--broadcast --account $DEPLOYER_NAME`: deploys via EOA.  
   - **Proxies + init** (per chain, via EOA):  
     Run `forge script script/deploy/02_DeployProxies.s.sol --rpc-url <url> --chain-id <id> --broadcast --account $DEPLOYER_NAME` for each chain.  
     Deploys placeholder + both proxies (CREATE2) and upgrades/initializes them in one atomic tx (or set `USE_LEGACY_DEPLOY=1` for legacy multi-tx). Saves addresses to config.

4. **After deployment**  
   - Proxy addresses are deterministic (same on all chains). (they’re deterministic via CREATE2).  
   - Run the verification script and the printed `forge verify-contract` commands to verify implementations and proxies on the block explorer.


## What Is Missing or Easy to Miss

- **Config file names**: The repo uses **per-chain JSONs** at `script/config/chains/{chainId}.json`, not a single `chain-config.json` or `dev-input.json`.
- **Chain coverage**: Only `1.json`, `100.json`, and `42161.json` may exist under `script/config/chains/`. For Optimism (10) and Base (8453) add `10.json` and `8453.json` (or reuse structure from existing files).
- **Safe TX output path**: Generated Safe transaction files are written to **`safe-transactions/`** at the **project root** (see `SafeTxBuilder.sol`).
- **02 is EOA-only**: Proxy deploy and init are done in **02_DeployProxies.s.sol** via EOA (no separate Safe TX for init). Use atomic deploy (default) or `USE_LEGACY_DEPLOY=1` for legacy multi-tx.
- **Docs**: Detailed config reference is `script/config/README.md` and `script/config/CONFIG_GUIDE.md`. Deployment script details: `script/deploy/README.md`.

## Documentation

- **`script/config/README.md`** - Configuration reference and deployment checklist
- **`script/config/CONFIG_GUIDE.md`** - Config field reference
- **`DEPLOYMENT_SUMMARY.md`** - This file (what's implemented and how to deploy)

## Benefits of This System

✅ **Same addresses across chains** (easier integration)
✅ **Safe-controlled** (multisig security)
✅ **No address squatting** (only your Safe can deploy)
✅ **Upgradeable** (UUPS pattern for core contracts)
✅ **Modular** (separate scripts for each component)
✅ **Reproducible** (deterministic deployments)
✅ **Well-documented** (extensive comments and guides)

---

**All implementation is complete and ready for deployment!** 🚀

The system only requires manual input for:
1. Configuration values (Safe address, roles, adapter parameters)
2. Safe transaction execution (as intended for security)
3. Contract verification (commands are auto-generated)
