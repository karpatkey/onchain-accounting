# Deployment System Summary

> **⚠️ Deployment is now EOA-only.** A single **deployer EOA** runs every step (`forge script … --broadcast`); no Safe executes any deploy/config transaction. The deployer holds `DEFAULT_ADMIN_ROLE` + `MANAGER` through deploy/config, and the final step `07_TransferAdminToSecurityCouncil.s.sol` hands those roles to the **security-council Safe** (`addresses.securityCouncil`) and renounces the deployer's. The council Safe is the end-state admin and drives post-deploy **upgrades** via `script/upgrade/*` (which still emit Safe-TX batches). **`script/deploy/README.md` is the authoritative, up-to-date procedure** — the Safe-TX-bundle steps described in some sections below are historical and superseded for deployment/configuration (`SafeTxBuilder` is retained only for the council's governance/upgrade scripts).

> **Status — deployed across 24 chains.** The Onchain Accounting System (NAV) is live: **5 chains fully configured** (custom price feeds + balance adapters) and **19 with the NAV implementation + proxy** only. Deployed addresses live in `script/config/deployments/{chainId}.json` (the only place addresses live; broadcast logs are not committed) and are mirrored in [`script/deploy/DEPLOYED_ADDRESSES.md`](deploy/DEPLOYED_ADDRESSES.md). The `PriceFeedLib` / `NAVRegistryLib` library pins are build config (not per-chain deployed addresses).
>
> **Chains (24):**
> - **Full** (feeds + adapters): Ethereum (1), Optimism (10), Arbitrum (42161), Base (8453), Gnosis (100).
> - **Implementation + proxy:** BSC (56), Polygon (137), Berachain (80094), HyperEVM (999), Ink (57073), Linea (59144), opBNB (204), Sonic (146), Unichain (130), Scroll (534352), X Layer (196), Celo (42220), Avalanche (43114), Mantle (5000), World Chain (480), Monad (143), Plasma (9745), Hemi (43111), 0G (16661).
> - Polygon zkEVM is intentionally **excluded** (the network is being sunset).

## ✅ What Has Been Implemented

This deployment system uses an **EOA deployer** (`--broadcast`) with **CREATE2 deterministic addresses** across multiple chains, handing admin to a security-council Safe at the end (step 07).

### Core Infrastructure

#### 1. **Create2Deployer** (`src/deployment/Create2Deployer.sol`)
- Stateless CREATE2 deployment contract for Safe delegatecall (when Safe delegatecalls it, `address(this)` = Safe, so Safe becomes the deployer)
- **Not used by the current EOA-only flow** — the impl/library/proxy layer (`01`/`02`) is deployed via the canonical CREATE2 deployer (`0x4e59...`) broadcast from the deployer EOA, while adapters (`03`–`05`) use plain `new ...` (CREATE). This contract is referenced only by tests and retained for Safe-delegatecall scenarios.

#### 2. **Utility Contracts** (`script/utils/`)
- **BaseDeployScript.sol** - Base contract with common deployment utilities
- **SafeTxBuilder.sol** - Generates Safe transaction JSON files
- **ConfigReader.sol** - Reads the per-chain `script/config/chains/{chainId}.json` plus the per-concern `contracts-deployment-config/` and `nav-config/` files

#### 3. **UUPS Upgradeability**
- ✅ **NAVCalculator** - Already UUPS upgradeable
- ✅ **BridgeEscrow** - Added UUPS upgradeability with `_authorizeUpgrade` and storage gap

### Deployment Scripts (`script/deploy/`)

| Script | Purpose | Output |
|--------|---------|--------|
| `01_DeployImplementations.s.sol` (`01_2` = NAV only) | Deploy `PriceFeedLib` + `NAVRegistryLib` libraries then NAVCalculator (and BridgeEscrow) **implementations** via EOA `--broadcast` (CREATE2, canonical deployer 0x4e59...). Same impl addresses on all chains; run once. | Saved impl/library addresses |
| `02_DeployProxies.s.sol` (`02_2` = NAV only) | Deploy placeholder + NAV + Bridge **proxies** and **initialize** them via EOA (canonical CREATE2). Default: one atomic tx via `AtomicProxyDeployer`, granting DEFAULT_ADMIN + MANAGER to `admin`/`manager` (= deployer EOA). `USE_LEGACY_DEPLOY=1` for legacy multi-tx. Run **per chain**. | Proxy addresses (same on all chains); saved to config |
| `03_DeployPriceFeeds.s.sol` | Deploy custom price feed adapters; register assets/feeds (per-chain, config-driven) | Adapter addresses in config |
| `04_DeployBalanceAdapters.s.sol` | Deploy balance adapters incl. meta-adapters (per-chain, config-driven) | Adapter addresses in config |
| `05_DeployBridgeAdapters.s.sol` | Deploy bridge adapters (CCIP, Across, Stargate, CCTP, Gnosis, Superchain; per-chain) | Adapter addresses in config |
| `06_Configure.s.sol` | **EOA broadcast** (deployer holds admin+MANAGER): `addBalanceAdapters` for each deployed plain adapter + `addMetaBalanceAdapter` then `addMetaInstances`/`removeMetaInstances` for meta-adapters + authorize bridge adapters. Idempotent / re-runnable. | On-chain config txs |
| `07_TransferAdminToSecurityCouncil.s.sol` | **EOA broadcast, run LAST**: grant DEFAULT_ADMIN + MANAGER to `addresses.securityCouncil` (Safe) on both proxies, revoke/renounce the deployer's roles. | On-chain role handoff |

### Upgrade Scripts (`script/upgrade/`)

| Script | Purpose |
|--------|---------|
| `UpgradeNAVCalculator.s.sol` | Upgrade NAVCalculator implementation |
| `UpgradeBridgeEscrow.s.sol` | Upgrade BridgeEscrow implementation |

### Management Scripts (`script/manage/`)

| Script | Purpose |
|--------|---------|
| `ManageAdapters.s.sol` | Add/remove/configure adapters via Safe (emits Safe-TX JSON) |
| `AuthorizeBridgeAdapters.s.sol` | Authorize enabled bridge adapters on BridgeEscrow (EOA admin broadcast) |
| `RegisterAssets.s.sol` | Register assets/price feeds via Safe (emits Safe-TX JSON) |
| `RegisterBridgeEscrow.s.sol` | Register the CCTP bridge adapter + USDC on BridgeEscrow via Safe (emits Safe-TX JSON) |

### Verification Scripts (`script/verify/`)

| Script | Purpose |
|--------|---------|
| `VerifyEtherscan.s.sol` | Generate Etherscan verification commands |

### Configuration Files (`script/config/`)

| File / Path | Purpose |
|-------------|---------|
| `chains/{chainId}.json` | Per-chain config: chain metadata (RPC, explorer, sequencer feed, native symbol) + role `addresses` block only (`securityCouncil`, `admin`, `manager`). Adapter enable flags now live under `contracts-deployment-config/`. |
| `nav-config/assets-and-price-feeds/{chainId}.json` | Asset registry: each asset's `address` + `priceFeeds[]` (the assets to register on NAVCalculator) |
| `contracts-deployment-config/custom-price-feeds/{chainId}.json` | Custom price-oracle adapters to deploy (`enabled` + `constructor` args) |
| `contracts-deployment-config/balance-adapters/{chainId}.json` & `contracts-deployment-config/meta-balance-adapters/{chainId}.json` | Plain / meta balance adapters to deploy (`enabled` + `constructor`) |
| `nav-config/balance-adapters/{chainId}.json` & `nav-config/meta-balance-adapters/{chainId}.json` | Adapters to register on NAVCalculator (plain vs. meta; meta entries carry `instances` / `instancesRaw`) |
| `script/config/deployments/{chainId}.json` | **Deployed-address state** — the *only* place deployed addresses are written. Populated by the deploy scripts as contracts land; now filled across all 24 deployed chains. Broadcast logs are no longer committed. |
| (No separate `dev-input.json`, `assets.json`, or `balance-adapters.json`) | All user input lives in `chains/{chainId}.json` (role `addresses`) plus the per-concern `contracts-deployment-config/` (with the `enabled` adapter flags) and `nav-config/` files above |

## Deployment Workflow

### Phase 1: No separate Create2Deployer

The project uses the **canonical CREATE2 deployer** at `0x4e59b44847b379578588920cA78FbF26c0B4956C` (same on all EVM chains). No `00_DeployCreate2Deployer` script is used.

### Phase 2: Core Contract Deployment

**Step 1 — Deploy implementations (once)**

Run `01_DeployImplementations.s.sol` **once** with `--broadcast --account` to deploy the libraries and implementations via the deployer EOA (canonical CREATE2). Same implementation addresses on all chains.

```bash
# Deploy via EOA (broadcast)
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

- **`ALCHEMY_API_KEY`** — Used for RPC on the Alchemy-served chains (their chain config has `"rpc": "$ALCHEMY"`; scripts use `--rpc-url "https://{network}.g.alchemy.com/v2/$ALCHEMY_API_KEY"`). Two chains are **not** on Alchemy — Hemi (43111) and 0G (16661) — and instead resolve `"$QUICKNODE_HEMI"` / `"$QUICKNODE_0G"` from `.env` (see `_alchemyNetworkForChainId` in `script/utils/ConfigReader.sol`).
- **`DEPLOYER_NAME`** — Foundry keystore account name for the deployer EOA. Import once with `cast wallet import $DEPLOYER_NAME --interactive`; key stored at `~/.foundry/keystores/$DEPLOYER_NAME`. Pass as `--account $DEPLOYER_NAME` to `forge script`.
- **Explorer API key** for verification. `verify-all.sh` uses a single `ETHERSCAN_API_KEY` for all chains (Etherscan V2). The per-explorer keys below are only needed if you run `forge verify-contract` manually against a non-Etherscan explorer:
  - Mainnet: `ETHERSCAN_API_KEY`
  - Arbitrum: `ARBISCAN_API_KEY`
  - Gnosis: `GNOSISSCAN_API_KEY`
  - Base: `BASESCAN_API_KEY`
  - Optimism: `OPTIMISM_ETHERSCAN_API_KEY`
  - Polygon: `POLYGONSCAN_API_KEY`
  - BNB Chain: `BSCSCAN_API_KEY`

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

Run **once** with `--broadcast --account` to deploy via the deployer EOA. Same impl addresses on all chains.

```bash
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

Verification needs the **explorer API key** for the chain (see below). The verify script (`VerifyEtherscan.s.sol`) reads the deployed-address config and emits machine-readable `VERIFY|...` lines; the wrapper `script/verify/verify-all.sh` parses those lines, checks each contract against the explorer API, and runs `forge verify-contract` for the ones not yet verified.

1. **Set the explorer API key** in `.env`. `verify-all.sh` uses a single **`ETHERSCAN_API_KEY`** for every chain (Etherscan V2 unified key). If you run `forge verify-contract` manually against a non-Etherscan explorer, supply that explorer's key for the chain (e.g. `ARBISCAN_API_KEY`, `GNOSISSCAN_API_KEY`, `BASESCAN_API_KEY`, `POLYGONSCAN_API_KEY`, `BSCSCAN_API_KEY`).

2. **Emit the `VERIFY|...` lines** (use the same chain you deployed to so addresses are correct):

   **Mainnet:**
   ```bash
   forge script script/verify/VerifyEtherscan.s.sol \
     --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
   ```

   **Arbitrum:** `--rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"`  
   **Gnosis:** `--rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"`  
   **Base:** `--rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"`

3. **Run `script/verify/verify-all.sh`** — it sources `.env`, parses the `VERIFY|...` lines, skips already-verified contracts, and runs `forge verify-contract` for the rest (implementations, proxies, and adapters). The canonical CREATE2 deployer (`0x4e59...`) is pre-deployed, so there is no Create2Deployer to verify.

---

### Step 7 — Repeat for other chains (if needed)

To deploy on another chain (e.g. Arbitrum after Mainnet):

1. Use that chain’s config: `script/config/chains/42161.json` (etc.).
2. Set **addresses** in that file (council Safe and roles can be the same or different).
3. **Step 4** (implementations) is once for all chains; run **Step 5** (`02_DeployProxies`) per chain with that chain's RPC and `--broadcast --account`, then **Step 6** (verify) for that chain.

Adapter deployment (price feeds, balance adapters, bridge adapters) and configuration come **after** NAVCalculator and BridgeEscrow are deployed; see “Phase 3” and “Phase 4” in the deployment workflow below.

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
# Register balance adapters + meta-instances and authorize bridge adapters.
# Broadcast from the deployer EOA (holds admin + MANAGER). Idempotent / re-runnable.
forge script script/deploy/06_Configure.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME \
  --broadcast
```

### Phase 5: Verification

```bash
# Emit VERIFY| lines for the chain you deployed to (use that chain's Alchemy URL)
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Or check + submit verification for all configured chains in one go
script/verify/verify-all.sh
```

## Key Features

### ✅ Security
- **EOA deploy, Safe end-state** - Deploy/config (`01`–`07`) run from the deployer EOA; `07` hands `DEFAULT_ADMIN_ROLE` + `MANAGER` to the security-council Safe and renounces the deployer's roles
- **Canonical CREATE2** - Deterministic addresses via the canonical deployer (`0x4e59...`); a placeholder impl keeps proxy addresses identical across chains
- **Role-Based Access** - `DEFAULT_ADMIN_ROLE` (admin) and `MANAGER` roles
- **Upgrade Authorization** - Only admin can authorize upgrades (post-handoff, the council Safe)

### ✅ Deterministic Addresses (same on every chain)
- Same canonical deployer + same salt + **same creation bytecode** = same address on every chain
- Proxy addresses are **identical across chains** because the proxy’s creation bytecode embeds a **chain-independent placeholder implementation** (deployed via CREATE2 at the same address everywhere), not the real implementation. `upgradeToAndCall` later points each proxy at the real impl. Thus CREATE2(deployer, salt, bytecode) yields the same proxy address per chain.
- Canonical CREATE2 deployer (0x4e59...) is the same on all chains; proxy bytecode uses a placeholder so proxy addresses are identical everywhere

### ✅ Upgradeability
- **UUPS pattern** for NAVCalculator and BridgeEscrow
- **Swappable adapters** (not upgradeable, but replaceable)
- Storage gaps for future expansion

### ✅ Multi-Chain Support
- Deployed on **24 chains** (see the Chains list at the top); fully configured on Ethereum, Optimism, Arbitrum, Base, Gnosis
- Chain-specific adapter deployments
- Easy to add new chains

### ✅ Safe Transaction Integration (governance only)
- The post-handoff scripts under `script/manage/` and `script/upgrade/` generate Safe-compatible JSON files
- Import directly into Safe UI; batch transactions for efficiency
- The deploy/config scripts (`01`–`07`) do **not** emit Safe TX JSON — they broadcast from the deployer EOA

## Adapter Types

### Price Adapters (Custom Price Feeds)
- `sDAI_CustomPriceFeed` - Savings DAI price
- `LDO_CustomPriceFeed` - Lido DAO token price
- `sUSDS_CustomPriceFeed` - Sky Savings USDS price
- `CrossRateCustomPriceFeed` - Cross-rate calculations

### Balance Adapters (Protocol Integrations)
- `ERC20DefaultBalanceAdapter` - Wallet ERC20 + native, auto-registered at NAV initialization
- `AaveV3InstancesMetaBalanceAdapter` - Aave V3 lending positions
- `AaveV3SafetyModuleBalanceAdapter` - Aave V3 Safety Module (stkGHO etc.)
- `AaveUmbrellaBalanceAdapter` - Aave Umbrella stake tokens
- `CompoundV3CometsMetaBalanceAdapter` - Compound V3 (Comet) base + collateral + rewards
- `MorphoMarketsMetaBalanceAdapter` - Morpho direct market positions
- `MorphoVaultsMetaBalanceAdapter` - MetaMorpho vault positions
- `EulerVaultsMetaBalanceAdapter` - Euler V2 vaults (EulerEarn aggregator + core eVault lend/borrow)
- `SparkLendBalanceAdapter` - Spark Lend positions
- `BalancerV2PoolsMetaBalanceAdapter`, `BalancerV2GaugesMetaBalanceAdapter` - Balancer V2 LPs + gauges
- `BalancerV3PoolsMetaBalanceAdapter`, `BalancerV3GaugesMetaBalanceAdapter` - Balancer V3 LPs + gauges
- `CurvePoolsMetaBalanceAdapter`, `CurveGaugesMetaBalanceAdapter` - Curve LPs + gauges
- `ConvexCurveLPStakingMetaBalanceAdapter` - Convex staking
- `CapBalanceAdapter` - Cap (cUSD + stcUSD aggregated → USDC)
- `FluidFTokensMetaBalanceAdapter`, `FluidVaultsMetaBalanceAdapter` - Fluid lending + vaults
- `GearboxV3MarketsMetaBalanceAdapter` - Gearbox kpk-curated markets
- `GearboxV3CreditAccountsMetaBalanceAdapter` - Gearbox credit accounts
- `StakeWiseV3VaultsMetaBalanceAdapter` - StakeWise V3 Genesis Vault (osETH/osGNO themselves are Custom-priced ERC20s via `osToken_CustomPriceFeed`, not balance adapters)
- `StaderWithdrawalQueueBalanceAdapter` - Stader pending unstake requests
- `KelpWithdrawalQueueBalanceAdapter` - Kelp DAO rsETH exit queue (multi-asset; payout assets discovered via `lrtConfig().getSupportedAssetList()`)
- `LidoWithdrawalQueueBalanceAdapter` - Lido stETH withdrawal queue (`WithdrawalQueueERC721`; sums open requests, reported as native ETH — the asset paid on claim)
- `UniswapV2PoolsMetaBalanceAdapter`, `UniswapV3PoolsMetaBalanceAdapter` - Uni V2 pairs / V3 pools (V3 NFTs enumerated on-chain)
- `PancakeSwapV2PoolsMetaBalanceAdapter`, `PancakeSwapV3PoolsMetaBalanceAdapter` - PancakeSwap variants

### Assisted Balance Adapters (externally-fed; ADR 0015/0018)

Permissionless assistant-fed adapters that cache position *coordinates only* (never amounts), value live on-chain, and re-verify ownership per read (under-report only). Each is paired with a delegatecall `…Assistant`.

- `NexusMutualStakingPoolsAssistedBalanceAdapter` - Nexus Mutual staking-pool NFT positions (per-account `tokenId` cache)
- `EtherFiWithdrawalQueueAssistedBalanceAdapter` - ether.fi withdrawal-queue requests
- `StakeWiseV3ExitQueueAssistedBalanceAdapter` - StakeWise V3 exit-queue tickets

### Bridge Adapters
- CCIP (Chainlink)
- Across Protocol
- Stargate
- CCTP (Circle)
- Gnosis (xDai bridge)
- Superchain (OP Stack)

## Files Generated During Deployment

### Deployment Records (`script/config/deployments/`)

The per-chain `script/config/deployments/{chainId}.json` file is the **single source of truth for deployed addresses** — broadcast logs are no longer committed. There is one file per deployed chain (24 total): the 5 fully-configured chains carry feeds + adapters, the other 19 carry the canonical layer only. (An empty `1101.json` stub is also present for Polygon zkEVM, which is intentionally excluded — a file's presence does not imply a deployment.)

```
script/config/deployments/
# Full (feeds + adapters):
├── 1.json          # Ethereum
├── 10.json         # Optimism
├── 42161.json      # Arbitrum
├── 8453.json       # Base
├── 100.json        # Gnosis
# Implementation + proxy:
├── 56.json   137.json   80094.json  999.json    57073.json
├── 59144.json 204.json  146.json    130.json    534352.json
├── 196.json   42220.json 43114.json 5000.json   480.json
└── 143.json   9745.json  43111.json 16661.json
```

### Safe Transactions (`safe-transactions/`)

The deploy/config scripts (`01`–`07`) all broadcast from the deployer EOA and do **not** emit Safe-TX JSON. Safe transactions are produced only by the post-handoff governance scripts under `script/manage/` and `script/upgrade/`, for the council Safe to execute:

```
safe-transactions/
├── {chainId}-add-balance-adapter.json     # From script/manage/ManageAdapters.s.sol
├── {chainId}-register-assets.json         # From script/manage/RegisterAssets.s.sol
├── {chainId}-register-bridge-escrow.json  # From script/manage/RegisterBridgeEscrow.s.sol
├── {chainId}-upgrade-navcalc.json         # From script/upgrade/UpgradeNAVCalculator.s.sol
├── {chainId}-upgrade-bridgeescrow.json    # From script/upgrade/UpgradeBridgeEscrow.s.sol
└── ... (one per Safe transaction)
```
Note: Proxy deploy + init is done via EOA in `02_DeployProxies.s.sol` (no Safe TX JSON).

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
2. **Enable adapters** by setting `"enabled": true` in the relevant `contracts-deployment-config/{custom-price-feeds,balance-adapters,meta-balance-adapters,bridge-adapters}/{chainId}.json` files as needed
3. **Execute Safe transactions** via Safe UI — only for **post-handoff governance** (`script/manage/`, `script/upgrade/`); deploy/config (`01`–`07`) is EOA broadcast, not Safe.
4. No Create2Deployer step; canonical deployer is used. Config is updated by scripts when addresses are saved (no separate “update” step).

### Manual Execution Required
1. Safe transaction execution for post-handoff governance/upgrades (multisig approval required)
2. Contract verification (run `VerifyEtherscan.s.sol` / `verify-all.sh`)
3. Adapter registration + bridge authorization — EOA via `06_Configure.s.sol` during deploy; post-handoff changes go through the council Safe (`script/manage/`)

## Next Steps to Deploy

1. **Configure** - Fill in `script/config/chains/{chainId}.json` with `addresses.securityCouncil`, `admin`, `manager` (and RPC/explorer vars in `.env` if using `$VAR`).
2. **Deploy implementations** - Run `01_DeployImplementations.s.sol` once with `--broadcast --account` to deploy via the deployer EOA.
3. **Deploy and initialize proxies** - Run `02_DeployProxies.s.sol` **per chain** with `--broadcast --account` (deploys placeholder + proxies and initializes them via EOA; atomic by default).
4. **Deploy adapters** - Run scripts 03–05 with adapters enabled in the `contracts-deployment-config/` files; broadcast to deploy adapter contracts.
5. **Configure adapters** - Run `06_Configure.s.sol` with `--broadcast --account` (deployer EOA holds admin+MANAGER): adds balance adapters, sets meta-instances, authorizes bridge adapters. Idempotent.
6. **Verify** - Run `VerifyEtherscan.s.sol` (or `script/verify/verify-all.sh`) to check and submit `forge verify-contract` for each deployed contract.
7. **Transfer admin** - Run `07_TransferAdminToSecurityCouncil.s.sol` last: hands DEFAULT_ADMIN + MANAGER to the council Safe and renounces the deployer's roles.

## What You Need to Do to Deploy NAVCalculator and BridgeEscrow

1. **Per chain (each chain where you deploy)**  
   - Have a Safe multisig and set in `script/config/chains/{chainId}.json`:  
     `addresses.securityCouncil`, `addresses.admin`, `addresses.manager` (all real addresses, not zero).  
   - Optional for NAVCalculator: set `chainlinkSequencerFeed` (L2 sequencer feed; can be zero on L1) and `nativeTokenSymbol` (e.g. `"ETH"`, `"xDAI"`).

2. **Env**  
   - `.env` with `ALCHEMY_API_KEY` (RPC for the Alchemy-served chains; Hemi/0G use `QUICKNODE_HEMI`/`QUICKNODE_0G` instead), `DEPLOYER_NAME`, and explorer API key(s) for verification.  
   - `DEPLOYER_NAME` is the Foundry keystore account name (import once with `cast wallet import $DEPLOYER_NAME --interactive`); used for implementations (01) and **02_DeployProxies** (proxies + init via EOA).

3. **Order of operations**  
   - **Implementations** (once):  
     Run `forge script script/deploy/01_DeployImplementations.s.sol --rpc-url <url> --chain-id <id> --broadcast --account $DEPLOYER_NAME`.  
     Deploys the libraries and implementations via the deployer EOA (canonical CREATE2). Same addresses on every chain, so run once.  
   - **Proxies + init** (per chain, via EOA):  
     Run `forge script script/deploy/02_DeployProxies.s.sol --rpc-url <url> --chain-id <id> --broadcast --account $DEPLOYER_NAME` for each chain.  
     Deploys placeholder + both proxies (CREATE2) and upgrades/initializes them in one atomic tx (or set `USE_LEGACY_DEPLOY=1` for legacy multi-tx). Saves addresses to config.

4. **After deployment**  
   - Proxy addresses are deterministic via CREATE2 (the same on all chains).  
   - Run `VerifyEtherscan.s.sol` (or `script/verify/verify-all.sh`) to verify implementations and proxies on the block explorer.


## What Is Missing or Easy to Miss

- **Config file names**: The repo uses **per-chain JSONs** at `script/config/chains/{chainId}.json`, not a single `chain-config.json` or `dev-input.json`.
- **Chain coverage**: `script/config/chains/` has a `{chainId}.json` for each of the 24 deployed chains (see the Chains list at the top), plus configs for networks intentionally left undeployed (e.g. `1101.json` for Polygon zkEVM, which is excluded) — presence of a config does not imply a deployment. To add another chain, create `{chainId}.json` (reuse the structure from an existing file) and add its Alchemy slug to `_alchemyNetworkForChainId` in `script/utils/ConfigReader.sol` — see `docs/howto/add-chain.md`.
- **Safe TX output path**: Generated Safe transaction files are written to **`safe-transactions/`** at the **project root** (see `SafeTxBuilder.sol`).
- **02 is EOA-only**: Proxy deploy and init are done in **02_DeployProxies.s.sol** via EOA (no separate Safe TX for init). Use atomic deploy (default) or `USE_LEGACY_DEPLOY=1` for legacy multi-tx.
- **Docs**: Detailed config reference is `script/config/README.md` and `script/config/CONFIG_GUIDE.md`. Deployment script details: `script/deploy/README.md`.

## Documentation

- **`script/config/README.md`** - Configuration reference and deployment checklist
- **`script/config/CONFIG_GUIDE.md`** - Config field reference
- **`script/DEPLOYMENT_SUMMARY.md`** - This file (what's implemented and how to deploy)

## Benefits of This System

✅ **Same addresses across chains** (easier integration)
✅ **Safe-controlled end state** (admin handed to the council Safe at step 07)
✅ **Deterministic addresses** (canonical CREATE2 + placeholder impl)
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
