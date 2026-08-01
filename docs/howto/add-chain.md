# How to add a new chain

End-to-end walkthrough for bringing the full stack up on a new EVM chain. The reference deploy doc is [`../../script/deploy/README.md`](../../script/deploy/README.md); this is the recipe.

Chain configs live in `script/config/chains/<chainId>.json` — one file per supported chain; see that directory for the current set. The pattern below assumes you're adding a similar EVM L1/L2.

---

## 1. Prerequisites

Before you write a line of config:

- [ ] An RPC endpoint for the chain (Alchemy, Infura, or a self-hosted node). Set `ALCHEMY_API_KEY` (or your provider's equivalent) in your environment. To keep `"rpc": "$ALCHEMY"` in the chain config, the new chainId must also be mapped to its Alchemy network slug in the `_alchemyNetworkForChainId` map in `script/utils/ConfigReader.sol` (which maps the production chainIds — see the function for the current set); otherwise point `rpc` at a plain `$YOUR_ENV_VAR` holding the full URL — `ConfigReader` expands any `$NAME` token from the environment (e.g. chains not served by Alchemy use a dedicated endpoint var such as `$QUICKNODE_HEMI` / `$QUICKNODE_0G`).
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
  }
}
```

> The chain config is now meta + `addresses` only — there is **no** `bridgeAdapters` block here. Bridge-adapter config lives in `script/config/contracts-deployment-config/bridge-adapters/<newChainId>.json` (see §3). Deploy scripts write deployed addresses to `script/config/deployments/<newChainId>.json`, not into this file.

Notes:

- **`chainlinkSequencerFeed`** is critical for L2s. Without it, the sequencer-uptime check is a no-op and you lose downtime protection. L1s leave it as zero. The default grace period is 1 hour (Chainlink's recommended minimum); `setChainlinkL2SequencerGracePeriod` enforces a floor of `>= 1 hours` — you cannot set it lower.
- **Roles (EOA deploy flow):** `admin` (DEFAULT_ADMIN_ROLE) and `manager` (MANAGER) must be the **deployer EOA** — it holds both through deploy/config so it can run 03–06. `securityCouncil` is the end-state admin (the council Safe); step `07_TransferAdminToSecurityCouncil.s.sol` grants it both roles on the NAV + Bridge proxies and renounces the deployer's. No Safe executes any deploy/config transaction.
- **Deployed addresses are not stored here;** deploy scripts write them to `script/config/deployments/<newChainId>.json`.

---

## 3. Create the per-concern config files

The repo no longer keeps a single `assets.json` or `balance-adapters.json` keyed by chainId. Each concern is split into its own folder, and within each folder there's one file **per chain** (`<newChainId>.json`) whose **top-level keys are the entries** — the filename is the chain, so there is no chainId wrapper inside the JSON. Adding a chain means creating a file in each of the eight folders below (plus the `chains/<id>.json` and `deployments/<id>.json` already covered):

| File | Contents | Read by |
|---|---|---|
| `script/config/contracts-deployment-config/custom-price-feeds/<newChainId>.json` | `{ "<feedName>": { "enabled", "constructor": {…} } }` — custom price feeds to **deploy** | `03_DeployPriceFeeds.s.sol` |
| `script/config/contracts-deployment-config/balance-adapters/<newChainId>.json` | `{ "<AdapterName>": { "enabled", "constructor": {…} } }` — **plain** adapters to **deploy** (no instances here) | `04_DeployBalanceAdapters.s.sol` |
| `script/config/contracts-deployment-config/meta-balance-adapters/<newChainId>.json` | `{ "<AdapterName>": { "enabled", "constructor": {…} } }` — **meta** adapters to **deploy** (no instances here) | `04_DeployBalanceAdapters.s.sol` |
| `script/config/contracts-deployment-config/bridge-adapters/<newChainId>.json` | `{ "<AdapterName>": { "enabled", "initialize": {…} } }` — bridge adapters to **deploy** | `05_DeployBridgeAdapters.s.sol` |
| `script/config/contracts-deployment-config/bridge-escrow/<newChainId>.json` | `{ "accounts": [ … ], "assets": { "<SYMBOL>": "0x…" } }` — accounts to authorize + assets to register on `BridgeEscrow` | `06_Configure.s.sol` → `authorizeAccount` + `registerAsset` |
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

For any custom price feed on this chain (sDAI, wstETH, etc.), add the deploy config under `script/config/contracts-deployment-config/custom-price-feeds/<newChainId>.json` keyed by feed name with `{ "enabled", "constructor" }`, then reference it from the asset via a `{ "type": "Custom", "feed": "<name>", "heartbeat": ... }` entry in that asset's `priceFeeds`. The feed's on-chain address is resolved post-deploy from `script/config/deployments/<newChainId>.json` (`.customPriceFeeds.<name>`). Many will use the `_L2_Price` variant — see [`src/prices/PRICE_ADAPTERS.md`](../../src/prices/PRICE_ADAPTERS.md) §8 for the right contract.

No symbol list to edit: `RegisterAssets.s.sol` reads the symbols from the keys of `nav-config/assets-and-price-feeds/<newChainId>.json` via `getAssetSymbols`. Adding the asset there is enough.

### 3.2 Balance adapters

The `ERC20Default` adapter (wallet/native coverage) is deployed and registered automatically inside `NAVCalculator.initialize()` during step 02 — you do **not** add it to any config file here. Add only the per-protocol entries as you onboard them on this chain (see [`./add-balance-adapter.md`](./add-balance-adapter.md)):

- Deploy config (constructor args) → `script/config/contracts-deployment-config/balance-adapters/<newChainId>.json` (plain adapters) or `script/config/contracts-deployment-config/meta-balance-adapters/<newChainId>.json` (meta adapters).
- Registration on NAV → `script/config/nav-config/balance-adapters/<newChainId>.json` (plain adapters) or `script/config/nav-config/meta-balance-adapters/<newChainId>.json` (meta adapters, with `instances`/`instancesRaw`).

### 3.3 Bridge adapters

For any bridge adapters this chain should support (CCIP, CCTP, Across, Stargate, Superchain, Gnosis), add the deploy config under `script/config/contracts-deployment-config/bridge-adapters/<newChainId>.json`, keyed by adapter name. Each entry has `enabled`, the adapter's `initialize` args (admin, bridgeEscrow, protocol contracts, version), and a **`remoteChains`** array of the standard chain ids it bridges to/from. (CCTP chain↔domain mappings are pinned in the adapter via `_setChainDomain`, **not** an `initialize` arg — a `cctpDomain` key here is ignored.) Read by `05_DeployBridgeAdapters.s.sol` (canonical CREATE2, same address every chain). There is no `callbackSelector`: per [ADR 0012](../decisions/0012-bridge-provable-release-rearchitecture.md) the escrow has no callback dispatcher; adapters authenticate inbound messages directly. **Don't forget `remoteChains`** — `06_Configure.s.sol` reads it to wire each adapter's trusted source senders via `setTrustedRemoteAdapter(remoteChainId, remoteAdapter)` (keyed by the remote's standard chain id); without it, provenance is unconfigured and inbound messages from that chain are rejected.

```json
{
  "CCIP": {
    "enabled": true,
    "initialize": { "admin": "0x...", "bridgeEscrow": "0x...", "router": "0x...", "feeToken": "0x...", "version": "1.0.0" }
  },
  "CCTP": {
    "enabled": true,
    "initialize": { "admin": "0x...", "bridgeEscrow": "0x...", "version": "1.0.0" }
  }
}
```

### 3.4 Bridge escrow accounts + assets

Create `script/config/contracts-deployment-config/bridge-escrow/<newChainId>.json`. This is what makes the escrow usable: `06_Configure.s.sol` reads it and calls `authorizeAccount` for every `.accounts` entry and `registerAsset` for every `.assets` entry. Without it the escrow ships with no authorized accounts and no registered assets, so `depositAndBridge` reverts (`NotAuthorized`, then the symbol lookup fails) even though the adapters are wired. Both calls run before `07`, while the deployer still holds `DEFAULT_ADMIN_ROLE` (accounts) and `MANAGER_ROLE` (assets).

- `accounts` — addresses allowed to call `depositAndBridge` / receive releases. An account must be authorized on **both** ends of every lane it uses, at the same address on each chain. Leave `[]` and fill per deployment (the deployer EOA for a smoke test, the fund Safes for production).
- `assets` — **logical bridge symbol → local token address**. The symbol is part of the cross-chain invoice identity, so both ends of a lane must register the **same** logical symbol mapped to each chain's local token (keys are logical, ≤ 6 chars — e.g. keep `"USDC"` consistent across chains even where the local token is `USDC.e`).

```json
{
  "accounts": [],
  "assets": { "USDC": "0x...", "WETH": "0x..." }
}
```

---

## 4. Run the deploy scripts in order

`PERSIST_DEPLOYMENTS=1` gates the impl/proxy/library address writes in `01`/`02` (via `saveDeployedAddress`, including the `ERC20Default` write in `02`): without it those are only logged, not written to `script/config/deployments/<chainId>.json`. The per-feed/per-adapter writes in `03`/`04`/`05` (via `writeAdapterAddress`) are **not** gated — they write on every run. Set `PERSIST_DEPLOYMENTS=1` on each command below once you're ready to record the real impl/proxy addresses.

```bash
export CHAIN_ID=<newChainId>
export DEPLOYER_NAME=...
export PERSIST_DEPLOYMENTS=1   # persist impl/proxy addresses from 01/02 to deployments/<chainId>.json (omit for a dry run)

# 01 — implementations (deterministic; same address on every chain after this completes)
forge script script/deploy/01_DeployImplementations.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 02 — proxies + initializers (atomic; placeholder + proxy + upgrade in one tx)
forge script script/deploy/02_DeployProxies.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 03 — deploy custom price feed adapters from contracts-deployment-config/custom-price-feeds/<chainId>.json
forge script script/deploy/03_DeployPriceFeeds.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 03b — register assets + price feeds on NAVCalculator from nav-config/assets-and-price-feeds/<chainId>.json
#       (separate script; deployer-as-MANAGER broadcasts registerAsset/addPriceFeed directly)
forge script script/manage/RegisterAssets.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 04 — deploy enabled balance adapters from contracts-deployment-config/balance-adapters/<chainId>.json + meta-balance-adapters/<chainId>.json
forge script script/deploy/04_DeployBalanceAdapters.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 05 — deploy bridge adapters (CCIP, Across, CCTP, Stargate, Superchain, Gnosis)
forge script script/deploy/05_DeployBridgeAdapters.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 06 — register balance adapters + meta-instances + authorize bridge adapters (EOA broadcast; idempotent)
#      meta vs. plain is config-driven: plain adapters come from nav-config/balance-adapters/<id>.json (addBalanceAdapters),
#      meta from nav-config/meta-balance-adapters/<id>.json (addMetaBalanceAdapter + addMetaInstances). The contracts
#      still enforce the split on-chain (addBalanceAdapters reverts for a meta-adapter, and vice-versa).
forge script script/deploy/06_Configure.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 07 — last of the ROLE HANDOFF: hand DEFAULT_ADMIN + MANAGER to the security council Safe, renounce the deployer's roles
DEPLOYER_EOA=0xYourDeployerEOA \
forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 08 — asset-kind registry (order-independent; run before or after 07, but do not skip it).
# Fail-closed: aborts unless every configured asset carries a valid pegKind + accrualKind.
PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/08_DeployAssetKindRegistry.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast
```

Each script reads from `script/config/chains/<chainId>.json` plus the relevant per-concern, per-chain file — `03` reads `contracts-deployment-config/custom-price-feeds/<chainId>.json`, `04` reads `contracts-deployment-config/balance-adapters/<chainId>.json` + `contracts-deployment-config/meta-balance-adapters/<chainId>.json`, `05` reads `contracts-deployment-config/bridge-adapters/<chainId>.json`, `RegisterAssets` reads `nav-config/assets-and-price-feeds/<chainId>.json`, and `06` reads `nav-config/balance-adapters/<chainId>.json` + `nav-config/meta-balance-adapters/<chainId>.json` + `contracts-deployment-config/bridge-escrow/<chainId>.json` (accounts + assets) — and writes deployed addresses to `script/config/deployments/<chainId>.json` (the `03`/`04`/`05` per-feed/per-adapter writes happen on every run; the `01`/`02` impl/proxy writes require `PERSIST_DEPLOYMENTS=1` — **and so do `04`'s three `*Assistant` contracts and `08`'s registry, which are top-level keys written through the gated `saveDeployedAddress`, so run those steps with the flag or their addresses are not recorded and a re-run deploys duplicates**). Re-running is safe: already-deployed addresses are skipped.

For chains where some scripts are no-ops (e.g., a chain with no bridge adapters), the relevant deploys produce no actions and exit cleanly.

---

## 5. Verify the deployment

```bash
# Verify that assets are registered with prices (returns an array of Asset{address,symbol,decimals})
cast call $NAVCalculator "getRegisteredAssets()((address,string,uint8)[])" --rpc-url $RPC

# Pull a price for a known asset (expect non-zero, not stale)
cast call $NAVCalculator "latestPrice(address)(int256,uint8,bool)" $WETH --rpc-url $RPC

# Pull NAV for the OIV Safe (sanity check; expect a number > 0 if the Safe holds anything)
# NAV{value, quoteAsset, timestamp, stalePriceAssets, sequencerDown, quoteAssetStale}
cast call $NAVCalculator "getAccountNav(address,address)((int256,(address,string,uint8),uint64,(address,string,uint8)[],bool,bool))" \
  $SAFE 0x0000000000000000000000000000000000000000 --rpc-url $RPC
```

Then run the source-verify script to push contract verification to the block explorer:

```bash
script/verify/verify-all.sh
```

---

## 6. Open the PR

PR checklist:

- [ ] `script/config/chains/<newChainId>.json` populated (chain meta + `addresses` only — no `bridgeAdapters` block)
- [ ] `script/config/deployments/<newChainId>.json` populated (deployed addresses written by the deploy scripts)
- [ ] `script/config/contracts-deployment-config/custom-price-feeds/<newChainId>.json` populated (custom feeds to deploy: `enabled` + `constructor`)
- [ ] `script/config/contracts-deployment-config/balance-adapters/<newChainId>.json` populated (plain adapters to deploy: `enabled` + `constructor`)
- [ ] `script/config/contracts-deployment-config/meta-balance-adapters/<newChainId>.json` populated (meta adapters to deploy: `enabled` + `constructor`)
- [ ] `script/config/contracts-deployment-config/bridge-adapters/<newChainId>.json` populated (bridge adapters to deploy: `enabled` + `initialize`)
- [ ] `script/config/contracts-deployment-config/bridge-escrow/<newChainId>.json` populated (bridge accounts to authorize + assets to register; `accounts` may be `[]` and filled per deployment)
- [ ] `script/config/nav-config/assets-and-price-feeds/<newChainId>.json` populated (assets with `priceFeeds`)
- [ ] `script/config/nav-config/balance-adapters/<newChainId>.json` populated (plain adapters to register)
- [ ] `script/config/nav-config/meta-balance-adapters/<newChainId>.json` populated (meta adapters + `instances`/`instancesRaw`)
- [ ] RPC resolves for the new chain — the chain config's `"rpc": "$ALCHEMY"` is expanded by `ConfigReader` from `ALCHEMY_API_KEY`, but only for chainIds in `_alchemyNetworkForChainId` (`ConfigReader.sol`); add the new chainId there, or point `rpc` at a plain `$YOUR_ENV_VAR` with the full URL. Either way no `foundry.toml` `[rpc_endpoints]` entry is needed; just set the env var (or pass `--rpc-url`)
- [ ] Verification done on the block explorer
- [ ] `forge build` clean
- [ ] PR description includes: chain name, chain ID, sequencer feed address (or "L1"), Safe address, list of assets and adapters enabled

If the chain has chain-specific quirks (e.g., a non-standard CREATE2 deployer, gas-token with unusual decimals, missing Chainlink coverage that requires unusual custom feeds), add an ADR under [`../decisions/`](../decisions/) explaining the workaround.
