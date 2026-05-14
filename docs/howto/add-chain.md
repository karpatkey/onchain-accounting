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
    "safeMultisig": "0x...",
    "admin":        "0x...",
    "manager":      "0x..."
  },

  "deployed": {
    "NAVCalculatorImplementation": "",
    "NAVCalculatorProxy": "",
    "BridgeEscrowImplementation": "",
    "BridgeEscrowProxy": ""
  },

  "balanceAdapters": {
    "ERC20Default": { "enabled": true, "constructor": { "navCalculator": "" } }
  },

  "bridgeAdapters": {}
}
```

Notes:

- **`chainlinkSequencerFeed`** is critical for L2s. Without it, the sequencer-uptime check is a no-op and you lose downtime protection. L1s leave it as zero.
- **Roles:** `safeMultisig` is the deploy authority. `admin` (DEFAULT_ADMIN_ROLE) and `manager` (MANAGER) are NAVCalculator roles. On most chains all three point to the same Safe (currently `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` on every live chain).
- **`deployed`** starts empty; deploy scripts write into it.
- **`balanceAdapters`** starts with just `ERC20Default`; add per-protocol entries as you onboard them on this chain (see [`./add-balance-adapter.md`](./add-balance-adapter.md)).

---

## 3. Configure assets and price feeds

Edit `script/config/assets.json` (single file, all chains):

1. Add tokens under `tokens.<newChainId>` for every asset you want priced on this chain. Each needs `address`, `type` (`Chainlink` / `Custom` / `None`), `oracle` (Chainlink aggregator or custom feed deployed on this chain), and optionally `heartbeat`.

```json
"tokens": {
  "<newChainId>": {
    "ETH": { "address": "0xEee...EEeE", "type": "Chainlink", "oracle": "0x...", "heartbeat": 3600 },
    "USDC": { "address": "0x...", "type": "Chainlink", "oracle": "0x...", "heartbeat": 86400 }
  }
}
```

2. For any custom price feed on this chain (sDAI, wstETH, etc.), add a `priceFeeds.<symbol>.<newChainId>` entry. Many will use the `_L2_Price` variant — see [`src/prices/PRICE_ADAPTERS.md`](../../src/prices/PRICE_ADAPTERS.md) §7 for the right contract.

3. Update `_symbolsForChain(<newChainId>)` in `script/manage/RegisterAssets.s.sol` to list the symbols this chain registers.

---

## 4. Run the deploy scripts in order

```bash
export CHAIN_ID=<newChainId>
export DEPLOYER_NAME=...

# 01 — implementations (deterministic; same address on every chain after this completes)
forge script script/deploy/01_DeployImplementations.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 02 — proxies + initializers (atomic; placeholder + proxy + upgrade in one tx)
forge script script/deploy/02_DeployProxies.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast

# 03 — deploy custom price feed adapters from assets.json.priceFeeds
forge script script/deploy/03_DeployPriceFeeds.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 04 — deploy enabled balance adapters from chain config
forge script script/deploy/04_DeployBalanceAdapters.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 05 — deploy bridge adapters (CCIP, Across, CCTP, Stargate, Superchain, Gnosis)
forge script script/deploy/05_DeployBridgeAdapters.s.sol --chain-id $CHAIN_ID --account $DEPLOYER_NAME --broadcast --verify

# 06 — emit Safe TX JSON to register assets, add balance oracles to NAV, authorize bridge adapters
forge script script/deploy/06_Configure.s.sol --chain-id $CHAIN_ID --sig 'run()'
# Owners on the chain's admin Safe sign and execute the resulting JSON.
```

Each script reads from and writes back to `script/config/chains/<chainId>.json`. Re-running is safe: already-deployed addresses are skipped.

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

- [ ] `script/config/chains/<newChainId>.json` exists, fully populated, and `deployed` block is filled in
- [ ] `script/config/assets.json` has tokens and price feeds for the new chain
- [ ] `script/manage/RegisterAssets.s.sol` `_symbolsForChain(<newChainId>)` lists the new chain's symbols
- [ ] `foundry.toml` has the new chain's RPC and Etherscan entries (the `[rpc_endpoints]` and `[etherscan]` sections)
- [ ] Verification done on the block explorer
- [ ] `forge build` clean
- [ ] PR description includes: chain name, chain ID, sequencer feed address (or "L1"), Safe address, list of assets and adapters enabled

If the chain has chain-specific quirks (e.g., a non-standard CREATE2 deployer, gas-token with unusual decimals, missing Chainlink coverage that requires unusual custom feeds), add an ADR under [`../decisions/`](../decisions/) explaining the workaround.
