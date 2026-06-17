# How to add a new chain

End-to-end walkthrough for bringing the full stack up on a new EVM chain. The reference deploy doc is [`../../script/deploy/README.md`](../../script/deploy/README.md); this is the recipe.

Five chains are configured today: `1` (Mainnet), `10` (Optimism), `100` (Gnosis), `42161` (Arbitrum), `8453` (Base). The pattern below assumes you're adding a similar EVM L2/L1.

---

## 1. Prerequisites

Before you write a line of config:

- [ ] An RPC endpoint for the chain (Alchemy, Infura, or a self-hosted node). Set `ALCHEMY_API_KEY` (or your provider's equivalent) in your environment.
- [ ] A funded deployer key (`$DEPLOYER_NAME` in Foundry's keystore).
- [ ] The block explorer's verifier endpoint and an API key (`ETHERSCAN_API_KEY` or chain-specific).
- [ ] The OIV Safe address on this chain (must already exist).
- [ ] The Chainlink **L2 sequencer uptime feed** address if it's an L2. L1s use `0x0000000000000000000000000000000000000000`.
- [ ] Confirmed that the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) exists on this chain — it does on every standard EVM chain, but check.

---

## 2. Create the chain config file

Copy an existing config as a starting point. Mainnet's is the most complete; Gnosis is a smaller L1 reference; Optimism is a good L2 reference (sequencer feed populated).

```bash
cp script/config/chains/1.json script/config/chains/<newChainId>.json
```

Edit the new file:

```json
{
  "chainId": <newChainId>,
  "name": "<chain-name>",
  "rpc": "$ALCHEMY",
  "explorer": "https://<explorer-url>",
  "explorerApiKey": "$ETHERSCAN_API_KEY",
  "chainlinkSequencerFeed": "0x...(or 0x0 for L1)",
  "nativeTokenSymbol": "ETH",

  "addresses": {
    "admin":           "0x...",
    "manager":         "0x...",
    "securityCouncil": "0x..."
  },

  "bridgeAdapters": {}
}
```

> Deploy scripts write deployed addresses to `script/config/deployments/<newChainId>.json`, not into this file.

Notes:

- **`chainlinkSequencerFeed`** is critical for L2s. Without it, the sequencer-uptime check is a no-op and you lose downtime protection. L1s leave it as zero. The default grace period is 1 hour (Chainlink's recommended minimum); `setChainlinkL2SequencerGracePeriod` enforces a floor of `>= 1 hours` — you cannot set it lower.
- **Roles (EOA deploy flow):** `admin` (DEFAULT_ADMIN_ROLE) and `manager` (MANAGER) must be the **deployer EOA** — it holds both through deploy/config so it can run 03–06. `securityCouncil` is the end-state admin (the council Safe); step `07_TransferAdminToSecurityCouncil.s.sol` grants it both roles on the NAV + Bridge proxies and renounces the deployer's. No Safe executes any deploy/config transaction.
- **Deployed addresses are not stored here;** deploy scripts write them to `script/config/deployments/<newChainId>.json`.

---

## 3. Create the per-concern config files

The repo no longer keeps a single `assets.json` or `balance-adapters.json` keyed by chainId. Each concern is split into its own folder, and within each folder there's one file **per chain** (`<newChainId>.json`) whose **top-level keys are the entries** — the filename is the chain, so there is no chainId wrapper inside the JSON. Adding a chain means creating a file in each of the five folders below (plus the `chains/<id>.json` and `deployments/<id>.json` already covered):

| File | Contents | Read by |
|---|---|---|
| `script/config/contracts-deployment-config/price-feeds/<newChainId>.json` | `{ "<feedName>": { "enabled", "constructor": {…} } }` — custom price feeds to **deploy** | `03_DeployPriceFeeds.s.sol` |
| `script/config/contracts-deployment-config/balance-adapters/<newChainId>.json` | `{ "<AdapterName>": { "enabled", "constructor": {…} } }` — balance + meta adapters to **deploy** (no instances here) | `04_DeployBalanceAdapters.s.sol` |
| `script/config/nav-config/assets-and-price-feeds/<newChainId>.json` | `{ "<SYMBOL>": { "address", "priceFeeds": [ … ] } }` — assets to **register** | `RegisterAssets.s.sol` |
| `script/config/nav-config/balance-adapters/<newChainId>.json` | `{ "<AdapterName>": { "enabled" } }` — **plain** adapters to add on NAV | `06_Configure.s.sol` → `addBalanceAdapters` |
| `script/config/nav-config/meta-balance-adapters/<newChainId>.json` | `{ "<AdapterName>": { "enabled", "instances": […] \| "instancesRaw": […] } }` — **meta** adapters to add on NAV | `06_Configure.s.sol` → `addMetaBalanceAdapter` + add/removeMetaInstances |

### 3.1 Assets and price feeds

Edit `script/config/nav-config/assets-and-price-feeds/<newChainId>.json`. Add a top-level entry for every asset you want priced on this chain. Each asset has an `address` and a `priceFeeds` array. Each feed entry has a `type` (`Chainlink` / `Custom` / `Redstone` / `API3`) and a `heartbeat`; Chainlink/Redstone/API3 feeds give an `address`, while a `Custom` feed references a deployed adapter by name (`"feed": "<name>"`). The **first** feed in the array registers the asset (`registerAsset`); any **additional** feeds are wired with `addPriceFeed`.

```json
{
  "ETH":  { "address": "0xEee...EEeE", "priceFeeds": [ { "type": "Chainlink", "address": "0x...", "heartbeat": 3600 } ] },
  "USDC": { "address": "0x...",         "priceFeeds": [ { "type": "Chainlink", "address": "0x...", "heartbeat": 86400 } ] }
}
```

For any custom price feed on this chain (sDAI, wstETH, etc.), add the deploy config under `script/config/contracts-deployment-config/price-feeds/<newChainId>.json` keyed by feed name with `{ "enabled", "constructor" }`, then reference it from the asset via a `{ "type": "Custom", "feed": "<name>", "heartbeat": ... }` entry in that asset's `priceFeeds`. The feed's on-chain address is resolved post-deploy from `script/config/deployments/<newChainId>.json` (`.customPriceFeeds.<name>`). Many will use the `_L2_Price` variant — see [`src/prices/PRICE_ADAPTERS.md`](../../src/prices/PRICE_ADAPTERS.md) §7 for the right contract.

No symbol list to edit: `RegisterAssets.s.sol` reads the symbols from the keys of `nav-config/assets-and-price-feeds/<newChainId>.json` via `getAssetSymbols`. Adding the asset there is enough.

### 3.2 Balance adapters

Add the `ERC20Default` coverage plus per-protocol entries as you onboard them on this chain (see [`./add-balance-adapter.md`](./add-balance-adapter.md)):

- Deploy config (constructor args) → `script/config/contracts-deployment-config/balance-adapters/<newChainId>.json`.
- Registration on NAV → `script/config/nav-config/balance-adapters/<newChainId>.json` (plain adapters) or `script/config/nav-config/meta-balance-adapters/<newChainId>.json` (meta adapters, with `instances`/`instancesRaw`).

---

## 4. Run the deploy scripts in order

```bash
export CHAIN_ID=<newChainId>
export DEPLOYER_NAME=...

# 01 — implementations (deterministic; same address on every chain after this completes)
forge script script/deploy/01_DeployImplementations.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 02 — proxies + initializers (atomic; placeholder + proxy + upgrade in one tx)
forge script script/deploy/02_DeployProxies.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 03 — deploy custom price feed adapters from contracts-deployment-config/price-feeds/<chainId>.json
forge script script/deploy/03_DeployPriceFeeds.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 04 — deploy enabled balance adapters from contracts-deployment-config/balance-adapters/<chainId>.json
forge script script/deploy/04_DeployBalanceAdapters.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 05 — deploy bridge adapters (CCIP, Across, CCTP, Stargate, Superchain, Gnosis)
forge script script/deploy/05_DeployBridgeAdapters.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 06 — register balance adapters + meta-instances + authorize bridge adapters (EOA broadcast; idempotent)
#      meta vs. plain is detected via ERC165 (no meta flag in config); meta adapters get their instances wired with addMetaInstances
forge script script/deploy/06_Configure.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 07 — LAST: hand DEFAULT_ADMIN + MANAGER to the security council Safe, renounce the deployer's roles
DEPLOYER_EOA=0xYourDeployerEOA \
forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast
```

Each script reads from `script/config/chains/<chainId>.json` plus the relevant per-concern, per-chain file — `03` reads `contracts-deployment-config/price-feeds/<chainId>.json`, `04` reads `contracts-deployment-config/balance-adapters/<chainId>.json`, `RegisterAssets` reads `nav-config/assets-and-price-feeds/<chainId>.json`, and `06` reads `nav-config/balance-adapters/<chainId>.json` + `nav-config/meta-balance-adapters/<chainId>.json` — and writes deployed addresses to `script/config/deployments/<chainId>.json`. Re-running is safe: already-deployed addresses are skipped.

For chains where some scripts are no-ops (e.g., a chain with no bridge adapters), the relevant deploys produce no actions and exit cleanly.

---

## 5. Verify the deployment

```bash
# Verify that assets are registered with prices
cast call $NAVCalculator "getRegisteredAssets()(address[])" --rpc-url $RPC

# Pull a price for a known asset (expect non-zero, not stale)
cast call $NAVCalculator "latestPrice(address)(int256,uint8,bool)" $WETH --rpc-url $RPC

# Pull NAV for the OIV Safe (sanity check; expect a number > 0 if the Safe holds anything)
cast call $NAVCalculator "getAccountNav(address,address)((int256,address,uint64,address[],bool))" \
  $SAFE 0x0000000000000000000000000000000000000000 --rpc-url $RPC
```

Then run the source-verify script to push contract verification to the block explorer:

```bash
script/verify/verify-all-v2.sh
```

---

## 6. Open the PR

PR checklist:

- [ ] `script/config/chains/<newChainId>.json` populated (chain meta, `addresses`, bridge intent)
- [ ] `script/config/deployments/<newChainId>.json` populated (deployed addresses written by the deploy scripts)
- [ ] `script/config/nav-config/assets-and-price-feeds/<newChainId>.json` populated (assets with `priceFeeds`)
- [ ] `script/config/contracts-deployment-config/price-feeds/<newChainId>.json` populated (custom feeds to deploy: `enabled` + `constructor`)
- [ ] `script/config/contracts-deployment-config/balance-adapters/<newChainId>.json` populated (adapters to deploy: `enabled` + `constructor`)
- [ ] `script/config/nav-config/balance-adapters/<newChainId>.json` populated (plain adapters to register)
- [ ] `script/config/nav-config/meta-balance-adapters/<newChainId>.json` populated (meta adapters + `instances`/`instancesRaw`)
- [ ] `foundry.toml` has the new chain's RPC and Etherscan entries (the `[rpc_endpoints]` and `[etherscan]` sections)
- [ ] Verification done on the block explorer
- [ ] `forge build` clean
- [ ] PR description includes: chain name, chain ID, sequencer feed address (or "L1"), Safe address, list of assets and adapters enabled

If the chain has chain-specific quirks (e.g., a non-standard CREATE2 deployer, gas-token with unusual decimals, missing Chainlink coverage that requires unusual custom feeds), add an ADR under [`../decisions/`](../decisions/) explaining the workaround.
