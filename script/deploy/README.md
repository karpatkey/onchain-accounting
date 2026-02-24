# Deploy Scripts

Deployment order: **01** (implementations, once) → **02** (proxies + init, per chain) → 03–06 as needed.

## RPC and environment

- Chain config uses `"rpc": "$ALCHEMY"` in `script/config/chains/{chainId}.json`.
- Scripts resolve that via **ConfigReader**: URL is built from **ALCHEMY_API_KEY** (or **ALCHEMY_APİ_KEY** if the first is unset).
- So you can run scripts **without** passing `--rpc-url` if you set one of those env vars and use chain config; otherwise pass `--rpc-url` explicitly.

Example (RPC from config):

```bash
# RPC taken from config ($ALCHEMY → ALCHEMY_API_KEY)
forge script script/deploy/02_DeployProxies.s.sol --chain-id 1 --broadcast --private-key $PRIVATE_KEY
```

Example (explicit RPC):

```bash
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 --broadcast --private-key $PRIVATE_KEY
```

---

## 02_DeployProxies.s.sol

Deploys NAVCalculator and BridgeEscrow **proxies** and **initializes** them in one go via an EOA using the **canonical CREATE2 deployer**, so proxy addresses are deterministic across chains.

### Design: proxy bytecode is chain-independent

Proxy **bytecode** uses a **placeholder** implementation (UUPSPlaceholder at a CREATE2 address that is the same on all chains). So proxy addresses do **not** depend on where NAV/Bridge implementations are deployed; the same proxy addresses are used on every chain. **02_DeployProxies** deploys the placeholder (if needed), deploys both proxies, then calls `upgradeToAndCall` on each proxy to set the real implementation and run initialization—all in one atomic transaction by default.

### Prerequisites

- **Implementations** must already be deployed (run **01_DeployImplementations.s.sol** first). 02 reads implementation addresses from chain config.
- Chain config must have `addresses.safeMultisig`, `addresses.admin`, `addresses.manager` and (after 01) `deployed.NAVCalculatorImplementation`, `deployed.BridgeEscrowImplementation`.

### How it works

- **Default (atomic):** One transaction via **AtomicProxyDeployer**: deploy placeholder (if not present), deploy both proxies (CREATE2), then upgrade each proxy to the real implementation and run `initialize(...)`. Grants MANAGER to the configured manager. No front-run window.
- **Legacy (multi-tx):** Set env `USE_LEGACY_DEPLOY=1` to use the legacy multi-transaction path instead.
- **Placeholder:** Deployed via CREATE2 with salt `ProxyPlaceholderImpl` version 2 (same address on all chains). Proxy constructor args are `(placeholder, "")`.
- **Deployer:** Canonical [deterministic deployment proxy](https://github.com/Arachnid/deterministic-deployment-proxy) at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
- **Addresses:** Same proxy (and placeholder) addresses on every chain. Written to `script/config/chains/{chainId}.json` under `deployed.NAVCalculatorProxy` and `deployed.BridgeEscrowProxy`.

### Commands (per chain)

```bash
# Mainnet (RPC from config if ALCHEMY_API_KEY is set)
forge script script/deploy/02_DeployProxies.s.sol --chain-id 1 --broadcast --private-key $PRIVATE_KEY

# Arbitrum
forge script script/deploy/02_DeployProxies.s.sol --chain-id 42161 --broadcast --private-key $PRIVATE_KEY

# Base
forge script script/deploy/02_DeployProxies.s.sol --chain-id 8453 --broadcast --private-key $PRIVATE_KEY

# Gnosis
forge script script/deploy/02_DeployProxies.s.sol --chain-id 100 --broadcast --private-key $PRIVATE_KEY
```

### After 02

Proxies are deployed and initialized. No separate init step. Next: deploy adapters (03–05) and run 06_Configure if needed to grant roles and authorize adapters via Safe.
