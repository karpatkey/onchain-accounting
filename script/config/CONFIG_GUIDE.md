# Per-Chain Configuration Guide

## Overview

The deployment system uses **per-chain JSON configuration files** that:
- ✅ Store chain-specific settings and addresses
- ✅ Define which adapters to deploy per chain
- ✅ Automatically update with deployed addresses
- ✅ Enable/disable adapters per chain

## File Structure

The config is split by **concern**, then by **chain** — each file is named `<chainId>.json` and its top-level keys are the entries (there is **no** chainId wrapper inside the file, because the filename *is* the chain).

```
script/config/
├── chains/
│   ├── 1.json                                    # Mainnet metadata + role addresses (NO bridgeAdapters block)
│   ├── 42161.json                                # Arbitrum
│   ├── 10.json                                   # Optimism
│   ├── 8453.json                                 # Base
│   ├── 100.json                                  # Gnosis
│   ├── 137.json                                  # Polygon
│   └── 56.json                                   # BSC
├── deployments/
│   └── <chainId>.json                            # State file: the ONLY place deployed addresses are written
├── contracts-deployment-config/                  # WHAT TO DEPLOY (+ constructor args) — read by 03/04/05
│   ├── custom-price-feeds/<chainId>.json         #   { "<feedName>": { "enabled", "constructor": {…} } }
│   ├── balance-adapters/<chainId>.json           #   PLAIN adapters to deploy: { "<AdapterName>": { "enabled", "constructor": {…} } }
│   ├── meta-balance-adapters/<chainId>.json      #   META adapters to deploy: { "<AdapterName>": { "enabled", "constructor": {…} } }  (NO instances)
│   ├── bridge-adapters/<chainId>.json            #   { "<AdapterName>": { "enabled", "initialize": {…}, "remoteChains":[…] } } — read by 05/06
│   └── bridge-escrow/<chainId>.json              #   { "accounts":[…], "assets": { "<SYMBOL>": "0x…" } } — read by 06 (authorizeAccount + registerAsset)
└── nav-config/                                   # WHAT TO REGISTER/ADD ON NAV — read by RegisterAssets + 06_Configure
    ├── assets-and-price-feeds/<chainId>.json     #   { "<SYMBOL>": { "address", "pegKind", "accrualKind", "priceFeeds": [ {type, address|feed, heartbeat} ] } }
    ├── balance-adapters/<chainId>.json           #   PLAIN adapters to add: { "<AdapterName>": { "enabled" } }
    └── meta-balance-adapters/<chainId>.json      #   META adapters to add: { "<AdapterName>": { "enabled", "instances":[…] | "instancesRaw":[…] } }
```

Two concerns are kept separate:

- **`contracts-deployment-config/`** — *what contracts to deploy* and their constructor args. Consumed by `03_DeployPriceFeeds.s.sol` (reads `custom-price-feeds/<chainId>.json`) and `04_DeployBalanceAdapters.s.sol` (reads **both** `balance-adapters/<chainId>.json` and `meta-balance-adapters/<chainId>.json`). Plain and meta balance adapters live in those two separate files (a meta-adapter is still a single deployed contract — its **instance list is NOT here**).
- **`nav-config/`** — *what to register on the NAVCalculator*. Consumed by `script/manage/RegisterAssets.s.sol` (assets + price feeds) and `06_Configure.s.sol` (balance adapters). Meta-vs-plain is **explicit** here: plain adapters in `balance-adapters/<chainId>.json`, meta adapters (with their `instances`/`instancesRaw`) in `meta-balance-adapters/<chainId>.json`.

**Names are the join key.** A balance adapter's key (e.g. `AaveV3InstancesMeta`) is the same string in its `contracts-deployment-config/` deploy file (`balance-adapters/<id>.json` for plain, `meta-balance-adapters/<id>.json` for meta), in the matching `nav-config/` file, and in `deployments/<id>.json` — they must match exactly so the deploy address can be resolved at registration time. Likewise a custom feed name (e.g. `wstETH`) joins its `contracts-deployment-config/custom-price-feeds/<id>.json` entry, an asset's `"feed":"<name>"` reference, and `deployments/<id>.json .customPriceFeeds.<name>`.

> Deployed addresses are **never** stored in any of these files — they live only in `script/config/deployments/<chainId>.json`. Bridge adapters are configured in `contracts-deployment-config/bridge-adapters/<chainId>.json` (keyed by adapter name → `enabled` + `initialize` args + a `remoteChains` array; read by `05_DeployBridgeAdapters.s.sol` for deploy and `06_Configure.s.sol` for the `trustedRemoteAdapter` wiring). BridgeEscrow's post-deploy state (which accounts may bridge, which assets are registered) is configured in `contracts-deployment-config/bridge-escrow/<chainId>.json` (`accounts[]` → `authorizeAccount`; `assets.<SYMBOL>` → `registerAsset`; both read by `06_Configure.s.sol`, required for a functioning deposit path since `02` initializes the escrow empty). The bridge adapters are deployed via the canonical CREATE2 deployer (ADR 0012, D7), so each adapter's address is **identical on every chain** — `05` asserts the deployed address equals the predicted deterministic address and reverts otherwise. `remoteChains` lists the remote chain ids (standard chain ids, NOT protocol selectors/domains/eids — the adapters translate internally) whose sibling adapter this adapter should trust; `06` calls `setTrustedRemoteAdapter(remoteChainId, bytes32(uint256(uint160(adapter))))` for each (the sibling shares this adapter's CREATE2 address). The legacy `callbackSelector` field is obsolete (ADR 0012 D1 removed the escrow fallback dispatcher); it is ignored if present.

## contracts-deployment-config/custom-price-feeds/<chainId>.json — Custom price feeds to deploy

Deployable custom price feed adapters (e.g. sUSDS, wstETH), keyed by feed name, each with `enabled` and `constructor` params. Read by `03_DeployPriceFeeds.s.sol`, which deploys every feed where `enabled: true` and writes the address to `deployments/<chainId>.json .customPriceFeeds.<feedName>`.

```json
{
  "wstETH": {
    "enabled": true,
    "constructor": {
      "wstEth": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
      "stEthToEthChainlinkOracle": "0x86392dC19c0b719886221c78AB11eb8Cf5c52812",
      "stEthToEthChainlinkHeartbeat": "86400",
      "baseAsset": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    }
  }
}
```

An asset references a deployed custom feed by name via a `"type":"Custom","feed":"<feedName>"` entry in its `priceFeeds[]` (see below); the on-chain address resolves post-deploy from `deployments/<chainId>.json .customPriceFeeds.<feedName>` (never an inline address).

## contracts-deployment-config/balance-adapters/<chainId>.json + meta-balance-adapters/<chainId>.json — Balance adapters to deploy

Balance adapter deploy intent, keyed by adapter name, each with `enabled` and `constructor`. **Plain** adapters go in `balance-adapters/<chainId>.json`; **meta** adapters go in `meta-balance-adapters/<chainId>.json` (same classification as `nav-config/`). Read by `04_DeployBalanceAdapters.s.sol`, which deploys every adapter where `enabled: true` across **both** files (plain `new …`, CREATE) and writes the address to `deployments/<chainId>.json .balanceAdapters.<name>`. A meta-adapter's instance set does NOT live here (that lives in `nav-config/meta-balance-adapters/<chainId>.json`).

There is no `deployed` field here — deployed addresses are written to `deployments/<chainId>.json`.

## nav-config/assets-and-price-feeds/<chainId>.json — Assets to register on NAV

Lists every asset of interest, keyed by symbol (e.g. `"WETH"`, `"wstETH"`), with its token `address`, its **required** `pegKind` + `accrualKind` classification, a **single-primary** `priceFeeds[]`, and (optionally) a `monitorFeeds[]` list plus divergence/peg tolerances. The **list of symbols to process** is derived from this file's keys via `ConfigReader.getAssetSymbols(vm, chainId)` — no hardcoded list; add a symbol by adding its object to this JSON.

The NAV **prices each asset off its single primary feed** (`priceFeeds[0]`, registered via `registerAsset`) — there is no pricing fallback. Any additional feeds go in `monitorFeeds[]`: they NEVER price the NAV, they are read only to detect divergence. When the primary diverges from **any single** healthy monitor by more than `divergenceToleranceBps` (worst-case, not an average), or (when `pegToleranceBps` is set) the primary deviates from $1 by more than that, NAVCalculator flags the asset `irregular` (a signal, not a revert). `getPriceDivergence` also exposes the monitor median and whether the primary sits above or below it. See the divergence design in `PriceFeedLib` / `INAVCalculator.PriceFeedData`.

Example structure (top-level keys are symbols — no chainId wrapper):

```json
{
  "wstETH": {
    "address": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
    "$kindComment": "Wrapped stETH; balance static, its stETH redemption rate grows.",
    "pegKind": "Floating",
    "accrualKind": "Appreciating",
    "divergenceToleranceBps": 250,
    "priceFeeds": [
      { "type": "Custom", "feed": "wstETH", "heartbeat": 86400 }
    ],
    "monitorFeeds": [
      { "type": "Redstone", "address": "0xe4aE88743c3834d0c492eAbC47384c84BcADC6a6", "heartbeat": 86400 }
    ]
  },
  "USDC": {
    "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "pegKind": "Pegged",
    "accrualKind": "None",
    "pegToleranceBps": 100,
    "divergenceToleranceBps": 50,
    "priceFeeds": [
      { "type": "Chainlink", "address": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6", "heartbeat": 82800 }
    ],
    "monitorFeeds": [
      { "type": "API3", "address": "0xD3C586Eec1C6C3eC41D276a23944dea080eDCf7f", "heartbeat": 86400 }
    ]
  }
}
```

- **address**: Token contract address.
- **pegKind** / **accrualKind**: **REQUIRED on every asset.** The two orthogonal classification axes. **Their consumer is NOT yet on `main`** — `08_DeployAssetKindRegistry`, `ConfigReader.readAssetPegKind` / `readAssetAccrualKind` and the `PegKind`/`AccrualKind` enums all land with the AssetKindRegistry change (#241); until that merges, these keys are read by nothing. Once it lands, parsing is **fail-closed with no default**: an absent, empty or unrecognized value aborts that chain's `08` deploy rather than defaulting, because a defaulted classification is indistinguishable from a real one once it is on-chain. **Add both keys whenever you add an asset here.**
  - `pegKind`: `"Pegged"` | `"Floating"`. `Pegged` means pegged to the NAV's **quote asset (USD)** — not "pegged to something". So `USDC`/`USDT`/`DAI`/`GHO` are `Pegged`, while **`wstETH` is `Floating`** (rigidly related to stETH, but its USD price moves with ETH). A EUR-pegged stablecoin is `Floating` under this rule. The axis correlates with an operational property, but **only where the registered primary prices a volatile quantity**: for a market-priced asset, a zero-heartbeat-margin staleness condition bites `Pegged` feeds harder than `Floating` ones, because a floating price keeps moving past the **oracle publisher's own deviation threshold** — an off-chain feed-configuration property of the Chainlink aggregator (there is no `deviationThreshold()` on the contract; it governs when the publisher pushes a fresh answer) — so a new answer lands before the heartbeat lapses, whereas a pegged asset can sit inside its deviation band until the heartbeat is the only thing left to refresh it. **That is the publisher's deviation threshold, NOT this repo's `divergenceToleranceBps`** — the divergence check above only raises the `irregular` flag, it never refreshes a feed and does not affect staleness.

  **Do NOT generalise this to `Floating` as a class — measured, it is false wherever the rate leg is a Chainlink oracle.** The hazard is scoped, so scope it precisely: of the 27 `Floating + Appreciating` rows today, **9 are priced off a Custom feed whose RATE leg is a Chainlink oracle** (`lsETH`; `wstETH` on 100/8453/42161; `weETH` on 8453/42161; `cbETH` on 8453; `rsETH` and `syrupUSDC` on 42161). The other 18 read their rate straight off the token (`getRate()`/`convertToAssets()`), which carries no publisher heartbeat at all. Only the first group is exposed here. An exchange-rate leg tracks a near-constant quantity, so it publishes on heartbeat rather than on deviation — and these legs are configured at exactly their publish cadence, i.e. **zero margin**. Measured 2026-08-01 over 7 consecutive rounds each: Base `weETH/eETH` leg `0x35e9D700…` (rounds …3362–…3369, configured `weEthToEethHeartbeat: 86400`) gaps ranged **86402–86430 s, 7 of 7 above 86400**; Gnosis `wstETH-ETH` leg `0x0064AC00…` ranged **86410–86430 s, 7 of 7 above**. `TwoFeedChainlinkPriceFeed._compute` returns `(0, true, …)` once `block.timestamp - effRate >= RATE_HEARTBEAT`, so such an asset is briefly priced 0 and listed in `stalePriceAssets` before each daily update. **Heartbeat margin is a property of the feed's publish cadence, not of `pegKind`** — size it per feed and never infer safety from `Floating`. Compounding it: **37 of the 68** `Floating` assets carry no `monitorFeeds` at all, so no divergence check exists for them under any chain state.
  - `accrualKind`: `"None"` | `"Rebasing"` | `"Appreciating"`. `Rebasing` = the **balance** grows (stETH, aTokens). `Appreciating` = the **exchange rate** grows while the balance is static (sDAI, wstETH, ERC-4626 shares). `None` = neither; value moves only with market price. A token whose yield accrues only through a separate wrapper is `None` (DAI vs sDAI, USDe vs sUSDe).
  - Values are **strings, not integers, deliberately**: a stale integer silently re-maps if an enum gains a member, whereas an unknown string cannot be mistaken for a valid one. The string→enum mapping will live in `ConfigReader` (with #241, see above) so production and tests share one source of truth.
- **$kindComment**: Optional justification for the pair above, used where the answer is non-obvious (any accrual, or a flagged judgement call). A separate key from `$comment` so a pre-existing comment is not clobbered. **Keep it true for THIS chain** — do not copy a mainnet justification onto an L2 entry whose pricing mechanism differs.
- **priceFeeds**: The **single** primary feed (array with exactly one entry), used by `registerAsset` to price the asset. An asset with no oracle uses an empty `priceFeeds: []`. Entry fields (`type` / `address` / `feed` / `heartbeat`) are as below.
- **monitorFeeds**: Optional ordered array of divergence-only feeds (same entry fields). Registered via `addMonitorFeed`; every entry must report 8 decimals (USD-comparable to the primary). Requires `divergenceToleranceBps` to be set. These are the former ADR-0009 redundancy feeds — they no longer price the NAV, they only feed the divergence check.
- **divergenceToleranceBps**: Basis-point threshold for the **worst-case** deviation between the primary and any single healthy monitor (not an average — a real split can't be masked). Required when `monitorFeeds` is non-empty (must be in `(0, 10000]`). Calibrate by comparison type: **fundamental-vs-market** (a Custom-feed primary watched by a market monitor, e.g. wstETH/weETH/ezETH) uses **250 bps** (real spread expected); **market-vs-market** (a Chainlink primary vs a second market feed, e.g. ETH/USDC/WBTC Chainlink-vs-API3/Redstone) uses **50 bps** (same quantity, ~30× calm-market noise).
- **pegToleranceBps**: Basis-point threshold for the absolute $1 peg guard. Set only on USD-$1 stablecoins; omit (or 0) to disable. Typical: 100. Independent of monitors. Note: this reads the *primary* — if the primary is a Chainlink feed with a `minAnswer` floor it can be blind to a real depeg, so the monitor-divergence check is the primary depeg signal; give stablecoins an independent monitor where a second USD feed exists.
- Feed entry fields:
  - **type**: `"Chainlink"`, `"Custom"`, `"Redstone"`, or `"API3"`.
  - **address**: Feed contract address. Used by all types **except** `Custom`.
  - **feed**: For `Custom` only — the name of a `contracts-deployment-config/custom-price-feeds/<chainId>.json` entry; resolved post-deploy from `deployments/<chainId>.json .customPriceFeeds.<name>`.
  - **heartbeat**: Staleness heartbeat in seconds. Optional; defaults to 3600 in code.

Iterate assets via `ConfigReader.getAssetSymbols(vm, chainId)`, then read the primary with `assetFeedCount` + `readAssetFeedType`/`readAssetFeedAddress`/`readAssetFeedHeartbeat`/`readAssetFeedName`, the monitors with `assetMonitorFeedCount` + `readAssetMonitorFeed*`, and tolerances with `readAssetDivergenceToleranceBps` / `readAssetPegToleranceBps`.

**Registering assets:** Use `script/manage/RegisterAssets.s.sol` to report which tokens are already registered, which are skipped (no oracle or missing address), and which should be registered. It writes a Safe transaction batch to `safe-transactions/{chainId}-register-assets.json`. Run with `--rpc-url` so already-registered assets are excluded from the batch.

## nav-config/balance-adapters/<chainId>.json — Plain adapters to add on NAV

The **plain** balance adapters to register on NAVCalculator, keyed by adapter name, each just `{ "enabled": true }`. Read by `06_Configure.s.sol`, which calls `NAVCalculator.addBalanceAdapters(...)` for the enabled ones (address resolved from `deployments/<chainId>.json .balanceAdapters.<name>`).

## nav-config/meta-balance-adapters/<chainId>.json — Meta adapters to add on NAV

The **meta** balance adapters to register on NAVCalculator, keyed by adapter name, each with `enabled` plus an instance list (`instances` for address-coordinate instances, or `instancesRaw` for raw `bytes32` coordinates — e.g. Morpho marketIds / Balancer V2 poolIds; mutually exclusive). Read by `06_Configure.s.sol`, which calls `addMetaBalanceAdapter` then reconciles the instance set via `addMetaInstances`/`removeMetaInstances`.

---

## Configuration File Format

Each chain config file (`chains/{chainId}.json`) contains:

```json
{
  "chainId": 1,
  "name": "mainnet",
  "rpc": "$MAINNET_RPC_URL",
  "explorer": "https://etherscan.io",
  "explorerApiKey": "$ETHERSCAN_API_KEY",
  "chainlinkSequencerFeed": "0x0000000000000000000000000000000000000000",
  "nativeTokenSymbol": "ETH",
  
  "addresses": {
    "securityCouncil": "0xYourSafeAddress",
    "admin": "0xYourAdminAddress",
    "manager": "0xYourManagerAddress"
  }
}
```

The chain config carries only metadata and `addresses`. Deployed addresses (NAVCalculator/BridgeEscrow impl + proxy, custom price feeds, balance adapters, bridge adapters) live in `script/config/deployments/<chainId>.json`. Bridge-adapter config lives in `contracts-deployment-config/bridge-adapters/<chainId>.json` (`enabled` + `initialize` args + a `remoteChains` array driving the `trustedRemoteAdapter` wiring; bridge adapters deploy via CREATE2 to the same address on every chain — ADR 0012 D7). Balance adapter deploy config lives in `contracts-deployment-config/balance-adapters/<chainId>.json` (plain) / `contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta) and its NAV-registration counterpart in `nav-config/balance-adapters/<chainId>.json` (plain) / `nav-config/meta-balance-adapters/<chainId>.json` (meta); assets and price feeds live in `nav-config/assets-and-price-feeds/<chainId>.json`, and custom price feed deploy config in `contracts-deployment-config/custom-price-feeds/<chainId>.json`.

## How It Works

### 1. Before Deployment

Set chain metadata and roles in `script/config/chains/{chainId}.json`:

```json
{
  "addresses": {
    "securityCouncil": "0xYourActualSafeAddress",
    "admin": "0xYourActualAdminAddress",
    "manager": "0xYourActualManagerAddress"
  }
}
```

Then define balance adapter **deploy** intent — plain adapters in `script/config/contracts-deployment-config/balance-adapters/{chainId}.json`, meta adapters in `script/config/contracts-deployment-config/meta-balance-adapters/{chainId}.json` (top-level keys are adapter names — no chainId wrapper):

```json
{
  "AaveV3_USDC": {
    "enabled": true,
    "constructor": {
      "poolAddress": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
      "asset": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    }
  },
  "CompoundV3_USDC": {
    "enabled": false,
    "constructor": {
      "comet": "0xc3d688B66703497DAA19211EEdff47f25384cdc3"
    }
  }
}
```

There is no `deployed` field here — deployed addresses are written to `deployments/{chainId}.json`.

Then list which of the deployed adapters to **register** on NAVCalculator. Plain adapters go in `script/config/nav-config/balance-adapters/{chainId}.json`:

```json
{
  "AaveV3_USDC": { "enabled": true }
}
```

Meta adapters (with their instance set) go in `script/config/nav-config/meta-balance-adapters/{chainId}.json` (see "Meta-adapter instance configuration" below).

### 2. Run Deployment

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --account $DEPLOYER_NAME \
  --broadcast
```

The script will:
- ✅ Read `contracts-deployment-config/balance-adapters/{chainId}.json` and `contracts-deployment-config/meta-balance-adapters/{chainId}.json` for the chain
- ✅ Deploy only adapters where `enabled: true`
- ✅ Use constructor args from config
- ✅ **Automatically save** deployed addresses to `deployments/{chainId}.json`

### 3. After Deployment

The state file `deployments/{chainId}.json` is automatically updated:

```json
{
  "balanceAdapters": {
    "AaveV3_USDC": "0xActualDeployedAddress"
  }
}
```

The deploy-config and nav-config files are left untouched.

## Benefits

### ✅ Per-Chain Configuration
Each chain has its own config file with chain-specific:
- Protocol addresses (Aave pool, Compound comet, etc.)
- Enabled/disabled adapters
- Safe multisig address
- Admin/manager addresses

### ✅ Automatic Updates
Deployment scripts automatically write deployed addresses into `deployments/{chainId}.json`:
```solidity
ConfigReader.writeAdapterAddress(vm, chainId, "balanceAdapters", "AaveV3_USDC", deployedAddress);
```

### ✅ Selective Deployment
Enable/disable adapters per chain in `contracts-deployment-config/balance-adapters/{chainId}.json`:
```jsonc
// In contracts-deployment-config/balance-adapters/1.json (Mainnet) - enable Cap
"Cap": {
  "enabled": true
}

// In contracts-deployment-config/balance-adapters/42161.json (Arbitrum) - disable Cap (doesn't exist there)
"Cap": {
  "enabled": false
}
```

### ✅ Safe to Re-run
If deployment is interrupted, re-running the script will:
- Skip adapters that are already deployed
- Only deploy missing adapters
- Preserve existing deployed addresses

## Example: Deploying to Gnosis Chain

1. **Edit** `script/config/chains/100.json` (metadata + addresses only):

```json
{
  "chainId": 100,
  "name": "gnosis",
  "addresses": {
    "securityCouncil": "0xYourGnosisChainSafe",
    "admin": "0xYourGnosisChainSafe",
    "manager": "0xYourManagerOnGnosis"
  }
}
```

   Then add the adapter deploy intent in `script/config/contracts-deployment-config/balance-adapters/100.json`:

```json
{
  "AaveV3_USDC": {
    "enabled": true,
    "constructor": {
      "poolAddress": "0xGnosisAavePoolAddress",
      "asset": "0xGnosisUSDCAddress"
    }
  }
}
```

   And register it on NAV in `script/config/nav-config/balance-adapters/100.json`:

```json
{
  "AaveV3_USDC": { "enabled": true }
}
```

2. **Deploy**:

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $GNOSIS_RPC_URL \
  --account $DEPLOYER_NAME \
  --broadcast
```

3. **Verify** the state file was updated:

```bash
cat script/config/deployments/100.json
```

You should see the deployed address under `balanceAdapters.AaveV3_USDC`!

## Configuration Fields

### Chain Settings
| Field | Type | Description |
|-------|------|-------------|
| `chainId` | number | Chain ID (1 for mainnet, 42161 for Arbitrum, etc.) |
| `name` | string | Human-readable chain name |
| `rpc` | string | RPC URL (use `$ENV_VAR` for env variables) |
| `explorer` | string | Block explorer URL |
| `explorerApiKey` | string | Explorer API key (use `$ENV_VAR`) |
| `chainlinkSequencerFeed` | address | L2 sequencer uptime feed (0x0 for L1s) |
| `nativeTokenSymbol` | string | Native token symbol (ETH, xDAI, etc.) |

### Addresses
| Field | Type | Description |
|-------|------|-------------|
| `securityCouncil` | address | Security-council Safe — the end-state admin (receives DEFAULT_ADMIN_ROLE in step 07). Does **not** execute deploy/config txs. |
| `admin` | address | DEFAULT_ADMIN_ROLE holder. In the EOA deploy flow set to the **deployer EOA** (upgrade, authorize adapters) until step 07 hands it to the council. |
| `manager` | address | MANAGER role (register assets, addBalanceAdapters/removeBalanceAdapters, addMetaInstances/removeMetaInstances). In the EOA flow, the **deployer EOA**. |

### Adapter Configuration

**Deploy config** — plain adapters (`contracts-deployment-config/balance-adapters/{chainId}.json`), meta adapters (`contracts-deployment-config/meta-balance-adapters/{chainId}.json`):

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | `true` to deploy, `false` to skip |
| `constructor` | object | Constructor parameters (chain-specific addresses) |

There is no `instances`/`instancesRaw` and no `deployed` field here — instance sets live in `nav-config/meta-balance-adapters/{chainId}.json`, deployed addresses in `deployments/{chainId}.json`.

**NAV-registration config** — plain adapters (`nav-config/balance-adapters/{chainId}.json`):

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | `true` to register on NAVCalculator via `addBalanceAdapters` |

**NAV-registration config** — meta adapters (`nav-config/meta-balance-adapters/{chainId}.json`):

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | `true` to register on NAVCalculator via `addMetaBalanceAdapter` |
| `instances` | string[] | Array of instance addresses (checksummed `address`) reconciled onto NAVCalculator via `addMetaInstances`/`removeMetaInstances`. Read by `06_Configure.s.sol`. |
| `instancesRaw` | string[] | Array of raw `bytes32` values for adapters whose instance key is not an address (e.g. Morpho market IDs, Balancer V2 poolIds). Mutually exclusive with `instances`. |

Meta vs. plain is **explicit** by which `nav-config` file the entry lives in: `06_Configure.s.sol` calls `addBalanceAdapters` for `nav-config/balance-adapters` entries and `addMetaBalanceAdapter` + `addMetaInstances`/`removeMetaInstances` for `nav-config/meta-balance-adapters` entries. There is no `deployed` field; deployed addresses live in `deployments/{chainId}.json`.

#### Meta-adapter instance configuration

Meta-adapters cover every instance of a protocol with a single deployed contract; the active instance set is pushed to NAVCalculator by `06_Configure.s.sol` via `addMetaInstances`/`removeMetaInstances`. Use `instances` for address-typed instance keys and `instancesRaw` for `bytes32`-typed keys (these replace the old `metaInstances`/`metaInstancesRaw` keys). These entries live in `nav-config/meta-balance-adapters/{chainId}.json` (the matching deploy config — `enabled` + `constructor` — is in `contracts-deployment-config/meta-balance-adapters/{chainId}.json`).

Example — address-keyed meta-adapter (`CompoundV3CometsMeta`), in `nav-config/meta-balance-adapters/{chainId}.json`:

```json
"CompoundV3CometsMeta": {
  "enabled": true,
  "instances": ["0xcomet1", "0xcomet2"]
}
```

Example — bytes32-keyed meta-adapter (`MorphoMarketsMeta`), in `nav-config/meta-balance-adapters/{chainId}.json`:

```json
"MorphoMarketsMeta": {
  "enabled": true,
  "instancesRaw": ["0xmarketId1bytes32", "0xmarketId2bytes32"]
}
```

`06_Configure.s.sol` reads both fields and reconciles each meta-adapter's on-chain set to config: it calls `NAVCalculator.removeMetaInstances(adapter, ...)` for coordinates no longer listed and `NAVCalculator.addMetaInstances(adapter, ...)` for newly-listed ones (diffed against `getMetaInstances`).

## Adding a New Chain

Add a per-chain `{newChainId}.json` file in **each** of the nine concern folders (plus the deployments state file):

1. Create `script/config/chains/{newChainId}.json` — copy an existing chain config as a template; it carries only metadata and `addresses`.
2. Create `script/config/contracts-deployment-config/custom-price-feeds/{newChainId}.json` with the chain's custom price feeds to deploy (`enabled` + `constructor`).
3. Create `script/config/contracts-deployment-config/balance-adapters/{newChainId}.json` (plain adapters to deploy) and `script/config/contracts-deployment-config/meta-balance-adapters/{newChainId}.json` (meta adapters to deploy), each with `enabled` + `constructor`; set `enabled: true` for desired adapters.
   Also create `script/config/contracts-deployment-config/bridge-adapters/{newChainId}.json` with the chain's bridge adapters to deploy (`enabled` + `initialize` args + a `remoteChains` array of the remote chain ids whose sibling adapter to trust; standard chain ids, not protocol selectors/domains/eids), and `script/config/contracts-deployment-config/bridge-escrow/{newChainId}.json` with the escrow's post-deploy config (`accounts[]` to authorize + `assets.<SYMBOL>` logical-symbol→local-token map to register).
4. Create `script/config/nav-config/assets-and-price-feeds/{newChainId}.json` with the chain's assets (`address` + `priceFeeds[]`).
5. Create `script/config/nav-config/balance-adapters/{newChainId}.json` (plain adapters to register) and `script/config/nav-config/meta-balance-adapters/{newChainId}.json` (meta adapters to register, with `instances`/`instancesRaw`).
6. Create an empty state file `script/config/deployments/{newChainId}.json` (deployed addresses are written here by the scripts).
7. Run deployment scripts.

Example for Linea (chain ID 59144):

```bash
cp script/config/chains/1.json script/config/chains/59144.json
# Edit 59144.json with Linea-specific values
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url $LINEA_RPC_URL \
  --account $DEPLOYER_NAME \
  --broadcast
```

## Troubleshooting

### Config file not found
```
Error: File not found: script/config/chains/59144.json
```
**Solution**: Create the chain config file first.

### Adapter already deployed
The script will skip re-deploying:
```
Deploying: AaveV3_USDC
  Already deployed at: 0x...
```
This is expected behavior when re-running.

### Wrong constructor args
If deployment fails, check that:
- Protocol addresses are correct for the chain
- Asset addresses match the chain
- All required fields are filled in

## Migration from Old Config

If you have the old `chain-config.json` and `dev-input.json`:

1. Create per-chain files in `script/config/chains/`
2. Copy chain settings from old `chain-config.json`
3. Copy adapter configs from old `dev-input.json`
4. Delete old files (they're deprecated)

If you have the older chainId-keyed `assets.json` and `balance-adapters.json` (a single file keyed by chainId), migrate each to the per-concern, per-chain layout (strip the chainId wrapper — the filename is now the chain):

1. Deployed addresses stay in `script/config/deployments/<chainId>.json` (unchanged).
2. From `assets.json` `<chainId>.assets` → `script/config/nav-config/assets-and-price-feeds/<chainId>.json` (top-level keys = symbols, each `address` + `priceFeeds[]`).
3. From `assets.json` `<chainId>.customPriceFeeds` → `script/config/contracts-deployment-config/custom-price-feeds/<chainId>.json` (`enabled` + `constructor`).
4. From `balance-adapters.json` `<chainId>.<adapter>` `enabled` + `constructor` → `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` (plain) / `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta).
5. Register the plain adapters in `script/config/nav-config/balance-adapters/<chainId>.json` (`{ "enabled": true }`).
6. Register the meta adapters in `script/config/nav-config/meta-balance-adapters/<chainId>.json`, renaming the old `metaInstances` → `instances` and `metaInstancesRaw` → `instancesRaw`.

The new system keeps "what to deploy" (`contracts-deployment-config/`) and "what to register on NAV" (`nav-config/`) cleanly separated, with deployment state isolated in `deployments/`.
