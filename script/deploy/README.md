# Deploy Scripts

Deployment order: **01** (implementations, once) → **02a** (proxies, per chain) → **02b** (initialize, per chain) → 03–06 as needed.

## RPC and environment

- Chain config uses `"rpc": "$ALCHEMY"` in `script/config/chains/{chainId}.json`.
- Scripts resolve that via **ConfigReader**: URL is built from **ALCHEMY_API_KEY** (or **ALCHEMY_APİ_KEY** if the first is unset).
- So you can run scripts **without** passing `--rpc-url` if you set one of those env vars and use chain config; otherwise pass `--rpc-url` explicitly.

Example (RPC from config):

```bash
# RPC taken from config ($ALCHEMY → ALCHEMY_API_KEY)
forge script script/deploy/02a_DeployProxies.s.sol --chain-id 1 --broadcast --private-key $PRIVATE_KEY
```

Example (explicit RPC):

```bash
forge script script/deploy/02a_DeployProxies.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 --broadcast --private-key $PRIVATE_KEY
```

---

## 02a_DeployProxies.s.sol

Deploys NAVCalculator and BridgeEscrow **proxies** via an EOA using the **canonical CREATE2 deployer** so addresses are deterministic across chains and EOAs.

### Design: proxy bytecode is chain-independent

Proxy **bytecode** uses a **placeholder** implementation (Empty contract at a CREATE2 address that is the same on all chains). So proxy addresses do **not** depend on where NAV/Bridge implementations are deployed; the same proxy addresses are used on every chain. **02b_InitializeProxies** then generates Safe transactions that call `ProxyAdmin.upgradeAndCall(proxy, realImpl, initData)` to point each proxy at the real implementation and run initialization.

### Prerequisites

- No need for implementations to exist when running 02a. 02a deploys a **placeholder** (Empty) first, then both proxies. Implementations are only required when you run **02b** (which reads them from config for the upgradeAndCall transactions).

### How it works

- **Placeholder:** Deployed via CREATE2 with salt `ProxyPlaceholderImpl` (same address on all chains). Proxy constructor args are `(placeholder, safeMultisig, "")`.
- **Deployer:** [Arachnid deterministic deployment proxy](https://github.com/Arachnid/deterministic-deployment-proxy) at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
- **Calldata:** The deployer expects **raw** calldata = `salt` (32 bytes) `||` `init_code`. Scripts call it with `abi.encodePacked(salt, bytecode)`.
- **Addresses:** Same proxy (and placeholder) addresses on every chain. Stored in `script/config/chains/{chainId}.json` under `deployed.NAVCalculatorProxy` and `deployed.BridgeEscrowProxy`.

### Commands (per chain)

```bash
# Mainnet (RPC from config if ALCHEMY_API_KEY is set)
forge script script/deploy/02a_DeployProxies.s.sol --chain-id 1 --broadcast --private-key $PRIVATE_KEY

# Arbitrum
forge script script/deploy/02a_DeployProxies.s.sol --chain-id 42161 --broadcast --private-key $PRIVATE_KEY

# Base
forge script script/deploy/02a_DeployProxies.s.sol --chain-id 8453 --broadcast --private-key $PRIVATE_KEY

# Gnosis
forge script script/deploy/02a_DeployProxies.s.sol --chain-id 100 --broadcast --private-key $PRIVATE_KEY
```

### After 02a

Run **02b_InitializeProxies.s.sol** per chain to generate Safe transactions that initialize the proxies; execute those in the Safe UI.
