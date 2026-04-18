# NAV v2 Deployment Runbook

Step-by-step operational guide for deploying the NAV v2 system — NAVCalculator, BridgeEscrow, price oracles, balance oracles, bridge adapters — to any supported chain. This runbook is the source of truth for every NAV v2 deployment going forward, regardless of which fund (ETH Alpha, USD Alpha, kUSDprime, kREN, or any future fund) the deployment supports.

**Companion docs:**
- [`DEPLOYMENT_SUMMARY.md`](DEPLOYMENT_SUMMARY.md) — architectural overview (CREATE2, atomic proxy deploy, Safe multisig control). Read first if you're new to the system.
- [`ORACLE_MIGRATION_PLAN.md`](../ORACLE_MIGRATION_PLAN.md) — historical record of the v1 → v2 oracle migration, plus known follow-up improvements. Start here if you want to understand why a particular oracle looks the way it does.

**When you use this runbook:**
1. Deploying NAV v2 to a new chain for the first time.
2. Deploying additional price or balance oracles to an already-live chain.
3. Registering new assets on a live NAVCalculator.
4. Rotating MANAGER/DEFAULT_ADMIN roles.
5. Validating an existing deployment.

**Maintenance note:** keep this runbook current. Every time you change a deploy script, add a new adapter family, or hit a gotcha worth preserving, update the corresponding section and open a PR.

---

## System overview

NAV v2 is a single, chain-local system. Each supported chain has:

- **One NAVCalculator proxy** (UUPS) at the same canonical address on every chain (`0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6`). Any Safe can call `getAccountNav(safe, quoteAsset)` and get its NAV in USD or any registered quote asset.
- **One BridgeEscrow proxy** (UUPS) at `0x1ECAEa1C69c5A0b12139d44E6b7345D71FE68A19`. Tracks outbound/inbound bridge liquidity that would otherwise be invisible to the NAV.
- **One default ERC20 balance adapter** at `0xc07C999644D8A3A5e57B835Aa460016b89eBA21C` — reports plain wallet balances for every registered ERC20 + the native coin.
- **N custom price feed adapters** — one per Custom-priced asset. Implements `IPriceFeedCustom.getLatestPrice()`.
- **N custom balance adapters** — one per protocol position (Aave V3 Core, Morpho vault, Curve gauge, etc.). Implements `IBalanceOracleAdapter.getOraclePositions()` / `getOracleBalances()` / `getOracleBalanceForAsset()`.

The NAVCalculator routes price lookups through an embedded `Prices` contract (Chainlink or Custom per asset) and position lookups through the registered balance oracles. Both are pluggable by adding/removing adapters — the proxy never needs to be upgraded to add new protocols.

**Key invariant:** the Safe's NAV is the sum of signed `(amount * price / quote_price)` across every `PositionBalance` returned by every registered balance oracle, plus the inflight bridged-out escrow balance. No oracle can lie about another oracle's asset — positions are keyed on `(oracle, underlyingAsset)` tuples.

---

## Roles and governance

NAVCalculator and BridgeEscrow both use OpenZeppelin `AccessControlUpgradeable` with two roles:

| Role | Code (constant) | What it gates |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000…0000` | UUPS upgrades (`_authorizeUpgrade`), grant/revoke any role |
| `MANAGER` | `keccak256("MANAGER")` | `registerAsset`, `setPriceFeed`, `unsetPriceFeed`, `addBalanceOracle`, `removeBalanceOracle`, `unregisterAsset`, `excludeAssetFromDefaultOracle`, `includeAssetInDefaultOracle`, `setChainlinkL2SequencerUptimeFeed`, `setChainlinkL2SequencerGracePeriod` |

**How the roles actually get assigned (read `02_DeployProxies.s.sol` + `AtomicProxyDeployer.sol` for the source of truth):**

**Atomic deploy path (default).**

1. `02_DeployProxies.s.sol` constructs `new AtomicProxyDeployer(navImpl, bridgeImpl, sequencerFeed, nativeSymbol, chainConfig.admin)`.
2. Inside that constructor, the proxies are CREATE2-deployed and then `NAVCalculator.initialize(address(this), ...)` / `BridgeEscrow.initialize(address(this), ...)` are called — so `AtomicProxyDeployer` itself gets `DEFAULT_ADMIN_ROLE`.
3. Still inside the constructor: `grantRole(DEFAULT_ADMIN_ROLE, chainConfig.admin)` on both proxies.
4. Control returns to `02_DeployProxies.s.sol` line 179–183: `grantRole(MANAGER, chainConfig.manager)` called by the broadcast sender (the deployer EOA).

**Legacy path (`USE_LEGACY_DEPLOY=1`).** Same shape except initialization is `NAVCalculator.initialize(chainConfig.admin, ...)` directly — `chainConfig.admin` gets `DEFAULT_ADMIN_ROLE` and the broadcast sender remains the deployer EOA.

**The catch that matters at runtime.** In both paths, step 4's `grantRole(MANAGER, ...)` is executed from `msg.sender = deployer EOA`. `OpenZeppelin AccessControl.grantRole` requires the caller to already hold the admin role for the role being granted (which, for `MANAGER`, means `DEFAULT_ADMIN_ROLE`). The deployer EOA is **never** explicitly granted `DEFAULT_ADMIN_ROLE` by either script. So:

- If `chainConfig.admin` equals the deployer EOA at the time of deploy → step 4 succeeds (deployer has admin).
- If `chainConfig.admin` is a Safe and the deployer is a different EOA → **step 4 reverts** and the deploy transaction fails after the proxies are already deployed and initialized.

As of 2026-04-17, every chain config has `addresses.admin` set to a Safe address (e.g. Mainnet `0x00008bB2Ff12ca49eD157B21a0D955c63C9ab31F`) that is different from any plausible deployer EOA. So **running `02_DeployProxies.s.sol` against an as-merged chain config will revert at the MANAGER grant step.** This is a latent bug in the deploy scripts — tracked in `ORACLE_MIGRATION_PLAN.md` under "Aspects to improve".

**Two workable workflows until the scripts are fixed:**

1. **Temporarily set `chainConfig.admin` = deployer EOA** → run `02_DeployProxies.s.sol` → update `chainConfig.admin` back to the Safe → run a Safe TX that `grantRole(DEFAULT_ADMIN_ROLE, Safe)` + `revokeRole(DEFAULT_ADMIN_ROLE, deployer)` + `grantRole(MANAGER, manager)`.
2. **Skip the MANAGER grant in `02`** (comment out lines 179–183, or guard on `chainConfig.admin == msg.sender`) → run `02` → have the Safe grant MANAGER afterwards (either via `06_Configure.s.sol`'s Safe TX batch or a direct Safe TX).

Recommend (2) because it leaves the persistent `addresses.admin = Safe` pattern intact and doesn't require a config round-trip. The fix for `02_DeployProxies.s.sol` is to guard the grant or move it to `06_Configure.s.sol`.

**Important nuance.** After the atomic deploy, the `AtomicProxyDeployer` contract's address still shows `hasRole(DEFAULT_ADMIN_ROLE, ...) == true` in the proxies. The contract has no runtime code that can call anything (constructor-only, no external functions), so it's functionally dead. Still cosmetically undesirable — if you want it cleaned up, add a post-deploy Safe TX that revokes the orphaned role.

**Recommended steady-state convention.** Both `chainConfig.admin` and `chainConfig.manager` point to the **same per-chain Safe multisig** (the "OIV Safe"). Deployer EOA pays gas at deploy time and retains no ongoing NAV powers. This is what the current chain configs describe; the deploy-script bug above is what stops us from actually reaching that state in one run today.

**Why this matters (v1 precedent).** `karpatkey-tokenized-fund` ETH Alpha STAGE's NAVCalculator v1 ended up with MANAGER stuck on the deployer EOA and no `DEFAULT_ADMIN_ROLE` holder at all — leaving it upgrade-locked and requiring a full redeploy. NAV v2's access-control design is safer, but until the `02` MANAGER-grant bug is fixed, double-verify roles post-deploy with the commands below.

**Post-deploy role validation** (run for every chain, every time you deploy):

```bash
NAV_PROXY=0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6
SAFE=<chainConfig.admin / chainConfig.manager — expected holder>
DEPLOYER=<deployer EOA — expected non-holder>
MANAGER_ROLE=$(cast keccak "MANAGER")
RPC=<rpc url>

# Expected: true, true, false, false
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" 0x0 $SAFE --rpc-url $RPC
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $SAFE --rpc-url $RPC
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" 0x0 $DEPLOYER --rpc-url $RPC
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $DEPLOYER --rpc-url $RPC
```

If any of these return the wrong result, **stop and fix** before proceeding. See "Troubleshooting — Role misconfiguration" at the bottom.

---

## Canonical addresses (post-merge, verified 2026-04-17)

| Component | Address | Chains |
|-----------|---------|--------|
| NAVCalculator Implementation | `0x149aE89A9C1EdE914df158C18Ee4DCEeb0283541` | Mainnet, Arbitrum, Base, Gnosis. Optimism uses `0xf141150092f88f3c3516D825E2FD3CeF57283442`. |
| NAVCalculator Proxy (CREATE2) | `0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6` | All 5 |
| BridgeEscrow Implementation | `0x50FE322E01eB7e537418D6C90ea586063260454D` | Mainnet, Arbitrum, Base, Gnosis. Optimism uses `0xB9330561EA35a7643A95b68D8A70fA6D6c004773`. |
| BridgeEscrow Proxy (CREATE2) | `0x1ECAEa1C69c5A0b12139d44E6b7345D71FE68A19` | All 5 |
| ERC20Default Balance Adapter | `0xc07C999644D8A3A5e57B835Aa460016b89eBA21C` | All 5 (auto-deployed in `NAVCalculator.initialize`) |

> **Source of truth for per-chain deployed addresses:** `script/config/chains/<chainId>.json.deployed`. Never rely on abbreviated addresses — always copy the full value from the per-chain config for any chain-specific implementation exception (currently only Optimism).

All deployed adapter addresses are persisted in the per-chain config:
- Bridge adapters → `chains/<id>.json.bridgeAdapters.<name>.deployed`
- Price feed adapters → `chains/<id>.json.priceFeeds.<name>.deployed`
- Balance adapters → `chains/<id>.json.balanceAdapters.<name>.deployed`

`assets.json.priceFeeds` holds constructor/config inputs only — it does **not** store deployed addresses. `ConfigReader.writeAdapterAddress` always writes to `chains/<chainId>.json`, regardless of adapter type.

> **Querying current deploy state.** To see what's actually deployed on each chain at any point: look at the `deployed` field of every adapter entry in `chains/<id>.json`. Empty string = not yet deployed. This runbook is the process; the configs are the source of truth for state.

## Supported chains

| Chain | ID | Config file |
|-------|----|-------------|
| Ethereum Mainnet | 1 | `script/config/chains/1.json` |
| Arbitrum | 42161 | `script/config/chains/42161.json` |
| Base | 8453 | `script/config/chains/8453.json` |
| Optimism | 10 | `script/config/chains/10.json` |
| Gnosis | 100 | `script/config/chains/100.json` |

---

## Phase 0: Prerequisites

### 0.1 Merge oracle migration PRs

The oracle migration PRs have all merged to `main`:

| PR | Branch | Content | Status |
|----|--------|---------|--------|
| [#10](https://github.com/karpatkey/onchain-accounting/pull/10) | `feat/pr1-surgical-changes` | Base infrastructure changes | Merged 2026-04-17 (`f97f264`) |
| [#11](https://github.com/karpatkey/onchain-accounting/pull/11) | `feat/pr2-price-oracles` | 16 custom price oracles + L2 deploy wiring | Merged 2026-04-17 (`369efd0`) |
| [#12](https://github.com/karpatkey/onchain-accounting/pull/12) | `feat/pr3-balance-oracles` | 5 new balance oracle adapters (MorphoVault, GearboxMarket, Cap, Curve, Convex) + per-instance deploy wiring | Merged 2026-04-17 (`f32d560`) |

### 0.2 Environment setup

Create or update `.env` in the project root:

```bash
# RPC (used by all chain configs via "$ALCHEMY" placeholder)
ALCHEMY_API_KEY=your_alchemy_key

# Deployer private key (used for scripts 03 and 04)
PRIVATE_KEY=0x...

# Explorer API keys (for contract verification)
ETHERSCAN_API_KEY=...
ARBISCAN_API_KEY=...
BASESCAN_API_KEY=...
OPTIMISM_ETHERSCAN_API_KEY=...
GNOSISSCAN_API_KEY=...
```

### 0.3 Run all tests

```bash
# Unit tests
forge test --no-match-path 'test/**/fork/*.sol'

# Fork tests (requires ALCHEMY_API_KEY)
forge test --match-path 'test/**/fork/*.sol'
```

Expected: all tests green. As of post-merge on `main` (2026-04-17): **716 unit + 271 fork**. Re-run locally to confirm counts haven't drifted.

### 0.4 Review chain configs

Open `script/config/chains/{chainId}.json` and confirm every field is correct for your target. Critical fields:

| Field | Meaning | Validation |
|---|---|---|
| `rpc` | RPC endpoint or `"$ALCHEMY"` placeholder | Resolve to a live endpoint; 429/timeout during scripts points to this |
| `explorer` + `explorerApiKey` | For Etherscan-family verification in Phase 8 | Must match chainId |
| `chainlinkSequencerFeed` | Chainlink L2 sequencer uptime feed; `address(0)` on L1s | Required on L2s — otherwise `getAccountNav` can't detect sequencer downtime |
| `nativeTokenSymbol` | `"ETH"`, `"xDAI"`, etc. | Shows up in NAV responses for the native sentinel |
| `addresses.safeMultisig` | The per-chain OIV Safe | Must be a Safe (verify via `cast call <addr> "getThreshold()(uint256)"`) |
| `addresses.admin` | Holds `DEFAULT_ADMIN_ROLE` post-deploy | Strongly recommended: same as `safeMultisig` |
| `addresses.manager` | Holds `MANAGER` post-deploy | Strongly recommended: same as `safeMultisig` |
| `deployed.*` | Canonical NAV/Bridge addresses already populated on all 5 chains | Do not modify unless you're deploying a new chain |

**Rule:** if you change any `addresses.*` value after `02_DeployProxies.s.sol` has run for a chain, you must re-grant roles explicitly via a Safe TX batch. You cannot re-run `02` idempotently for role changes.

### 0.5 Pre-flight checklist (do before any `--broadcast` invocation)

Tick every box below before you broadcast on any chain. Each one has burned a past deployment:

- [ ] Branch you're deploying from is `main` (or a documented release tag). `git rev-parse HEAD` matches the commit you expect.
- [ ] `forge build --profile local` passes clean.
- [ ] Non-fork tests pass: `forge test --no-match-path 'test/**/fork/*.sol'` → 716+ passing.
- [ ] Fork tests pass against your target chain: `FOUNDRY_PROFILE=slow forge test --match-path 'test/**/fork/*.sol'` → 271+ passing.
- [ ] `.env` has: `ALCHEMY_API_KEY`, `PRIVATE_KEY` (deployer EOA), `<CHAIN>_ETHERSCAN_API_KEY`.
- [ ] Deployer EOA has native gas on the target chain (check with `cast balance <EOA> --rpc-url ...`). Rule of thumb: 0.05 ETH on L1, 0.01 ETH-equivalent on L2s/Gnosis for a full Phase 3+4+5 run.
- [ ] Chain config `addresses.admin` and `addresses.manager` point to the correct per-chain Safe.
- [ ] For redeploys of a specific adapter: `deployed: ""` is cleared in the config (otherwise the script skips).
- [ ] You know which Safe's signers will execute the generated Safe TX JSONs in Phases 5/6, and those signers are available.
- [ ] You have a rollback plan: any pre-existing price feed or balance oracle you intend to replace is documented, and you know the `cast send` commands to revert.

---

## Phase 1: Configure Price Feed Adapters

Price feed adapter configuration lives in `script/config/assets.json` under the `priceFeeds` section.

### 1.1 Add `priceFeeds` section to `assets.json`

The `priceFeeds` section must be added to `assets.json` with constructor parameters for each custom price adapter, organized by adapter name and chain ID. The deploy script (`03_DeployPriceFeeds.s.sol`) reads from this config.

> **Looking up Chainlink heartbeats.** Every `*chainlinkHeartbeat` constructor parameter must match (or slightly exceed) the published heartbeat of the underlying Chainlink feed — otherwise every query returns `stale: true` between heartbeat writes. Chainlink's authoritative source is the JSON directory at `https://reference-data-directory.vercel.app/feeds-<network>.json` (e.g. `feeds-mainnet.json`, `feeds-ethereum-mainnet-arbitrum-1.json`). Each feed entry exposes `heartbeat` (seconds) and `threshold` (deviation %). Alternatively, [data.chain.link](https://data.chain.link) shows the same values per feed page. ETH/USD mainnet is 3600s; USD stablecoins are typically 86400s. If in doubt, round up (e.g. 3900s) to tolerate block-time jitter.

> **Also pre-seed chain configs.** `ConfigReader.writeAdapterAddress(...)` writes deployed price-feed addresses to `script/config/chains/{chainId}.json` at `.priceFeeds.{adapter}.deployed`. Foundry `vm.writeJson` will not create a missing parent object, so each chain config must have a `"priceFeeds": {}` key (with per-adapter sub-objects for anything you want to deploy) before `03_DeployPriceFeeds.s.sol` runs. `ConfigReader.readAdapterParam` documents this behaviour inline; use that as the authoritative reference if in doubt.

Structure:

```json
{
  "priceFeeds": {
    "<AdapterName>": {
      "<chainId>": {
        "enabled": true,
        "constructor": {
          "param1": "0x...",
          "param2": "3600"
        }
      }
    }
  }
}
```

### 1.2 Mainnet price feed adapters to configure

| Adapter | Config key | Constructor params needed |
|---------|-----------|-------------------------|
| sDAI | `sDAI` | `sDai`, `dsrManager`, `daiToUsdChainlinkOracle`, `daiToUsdChainlinkHeartbeat` |
| LDO | `LDO` | `ldo`, `ldoToEthChainlinkAddress`, `ethToUsdChainlinkAddress`, `ldoToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |
| sUSDS | `sUSDS` | `sUsds`, `usdsToUsdChainlinkAddress`, `usdsToUsdChainlinkHeartbeat` |
| sUSDe | `sUSDe` | `sUsde`, `usdeToUsdChainlinkAddress`, `usdeToUsdChainlinkHeartbeat` |
| syrupUSDC | `syrupUSDC` | `syrupUsdc`, `usdcToUsdChainlinkAddress`, `usdcToUsdChainlinkHeartbeat` |
| wstETH | `wstETH` | `wstEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| rETH | `rETH` | `rEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| cbETH | `cbETH` | `cbEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| weETH | `weETH` | `weEth`, `weEthToEthChainlinkOracle`, `ethToUsdChainlinkOracle`, `weEthToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |
| rsETH | `rsETH` | `rsEth`, `rateProvider`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| eETH | `eETH` | `eEth`, `weEth`, `weEthToEthChainlinkOracle`, `ethToUsdChainlinkOracle`, `weEthToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |

### 1.3 Gnosis price feed adapters

| Adapter | Config key | Constructor params needed |
|---------|-----------|-------------------------|
| sXDAI | `sXDAI` | `sXdai`, `xDaiToUsdChainlinkOracle`, `xDaiToUsdChainlinkHeartbeat` |

### 1.4 L2 and Mainnet custom price feed adapter dispatch

Authoritative source: the `_deploy<Chain>PriceAdapters` functions in `03_DeployPriceFeeds.s.sol`. Current wiring (post-PR #11 merge):

| Oracle | Deployed on | Source file | Notes |
|--------|-------------|-------------|-------|
| `wstETH_L2` | Arbitrum, Base, Gnosis | `wstETH_L2_Price.sol` | Gnosis uses an Aave ratio provider in place of a Chainlink feed, same interface |
| `cbETH_L2` | Base | `cbETH_L2_Price.sol` | |
| `weETH_L2` | Arbitrum, Base | `weETH_L2_Price.sol` | |
| `rsETH_L2` | Arbitrum | `rsETH_L2_Price.sol` | |
| `ezETH_L2` | Arbitrum | `ezETH_L2_Price.sol` | Uses `xRenzoDeposit.getRate()`, different from Mainnet `ezETH` |
| `syrupUSDC_L2` | Arbitrum | `syrupUSDC_L2_Price.sol` | |
| `sXDAI` | Gnosis | `sDAI_Price.sol` (aliased as `sXDAI_PriceOracle` — constructor is re-used) | |
| `ezETH` | Mainnet | `ezETH_Price.sol` | Uses `restakeManager.calculateTVLs()` |
| `ETHPlus` | **not deployed** | `ETHPlus_Price.sol` | The oracle contract exists and is unit + fork tested, but no `_deployIfEnabled("ETHPlus")` call is wired because ETH Alpha uses a Chainlink feed for ETHPlus on mainnet. Leave it that way unless a fund starts relying on the Custom path. |

**Optimism has no Custom price adapters.** Alpha funds on OP use Chainlink feeds exclusively (`wstethToUsdChainlink`, `usdcToUsdChainlink`, `usdtToUsdChainlink`). `_deployOptimismPriceAdapters()` is an intentional no-op; if a future fund needs a Custom adapter on OP, add it there.

> **Double-check before you add a new Custom adapter:** some assets on L2s already have `type: "Custom"` in `assets.json` with a third-party-deployed `pricefeed` address (e.g. an Aave-provided ratio feed). Confirm whether the existing address is ours or third-party before deploying a duplicate.

---

## Phase 2: Configure Balance Adapters

Balance adapter configuration lives in each chain's config file under `balanceAdapters`.

### 2.1 Add adapter entries to chain configs

> **Starting state:** chain configs already include many `balanceAdapters` entries beyond `ERC20Default` (pre-seeded during PR #12 — e.g. `AaveV3_Core`, `AaveV3_Prime`, `MorphoMarket_*`, `Aura_*`, etc.). Before editing `script/config/chains/{chainId}.json`, review what's already there and add only the adapters still missing for your deployment. `04_DeployBalanceAdapters.s.sol` deploys the intersection of (a) names in its `run()` list and (b) entries with `enabled: true` in the chain config.

For each new adapter you want to deploy on a given chain, add an entry to `script/config/chains/{chainId}.json` under `balanceAdapters`:

```json
"balanceAdapters": {
  "AaveV3_Core": {
    "enabled": true,
    "constructor": {
      "dataProvider": "0x...",
      "protocol": "Aave V3 Core"
    },
    "deployed": ""
  }
}
```

### 2.2 Balance adapters available for deployment

The deploy script (`04_DeployBalanceAdapters.s.sol`) supports these adapters:

| Adapter prefix | Constructor params | Applicable chains |
|---------------|-------------------|-------------------|
| `AaveV3_*` | `dataProvider`, `protocol` | Mainnet, Arbitrum, Base, Optimism, Gnosis |
| `CompoundV3_*` | `compoundRewards`, `comet`, `rewardToken`, `protocol` | Mainnet |
| `SparkLend`, `SparkLend_*` | `dataProvider`, `protocol` | Mainnet (current wiring uses the bare `SparkLend`; the `SparkLend_*` prefix is supported for future multi-market use) |
| `MorphoMarket_*` | `morpho`, `marketId`, `protocol` | Mainnet, Arbitrum, Base (per-chain via config `enabled` flag) |
| `MorphoVault_*` | `vault`, `protocol`, `positionDetail` | Mainnet |
| `GearboxMarket_*` | `market`, `protocol`, `positionDetail` | Mainnet |
| `Cap` | `cUsd`, `stcUsd`, `usdc`, `protocol`, `positionDetail` | Mainnet |
| `Curve_*` | `gauge`, `protocol`, `positionDetail` | Mainnet |
| `Convex_*` | `rewarder`, `lpToken`, `protocol`, `positionDetail` | Mainnet |
| `AaveV3SafetyModule_*` | `stakeToken`, `protocol`, `positionDetail` | Mainnet |
| `BalancerV3_*` | `pool`, `gauge`, `balancerMinter`, `protocol` | Mainnet |
| `Aura_*` | `pool`, `gauge`, `booster`, `pid`, `protocol`, `positionDetail` | Mainnet, Arbitrum, Base. AURA token resolved dynamically inside the adapter via `Booster.minter()` (+ `L2Coordinator.auraOFT()` staticcall on L2s) — do **not** add an `auraToken` config field, it's unused since PR #12 commit `62fcdee`. |
| `StakeWiseV3Vault_*` | `underlyingToken`, `vault`, `protocol`, `positionDetail` | Mainnet |
| `StakeWiseV3OsToken_*` | `osToken`, `underlyingToken`, `osTokenVaultController`, `protocol`, `positionDetail` | Mainnet |
| `DaiDsr` | `dai`, `dsrManager`, `protocol`, `positionDetail` | Mainnet |
| `SkySavingsUsds` | `savingsUsds`, `protocol`, `positionDetail` | Mainnet |

### 2.3 Specific adapters currently wired in the deploy script

`04_DeployBalanceAdapters.s.sol` has a single `run()` that holds the **union** of adapter names across every chain. There are no chain-specific dispatch functions — per-chain selection is controlled by the `enabled` flag in each chain config. The current inventory (43 instances across 5 chains) was scoped to what ETH Alpha Fund and USD Alpha Fund require. Source of truth: the `run()` list in `04_DeployBalanceAdapters.s.sol`.

To deploy additional instances (e.g., a new Curve gauge, or AaveV3 on a different chain):

1. Add a new `_deployIfEnabled("<AdapterName>")` call inside the `run()` function of `04_DeployBalanceAdapters.s.sol`.
2. Add a corresponding `balanceAdapters.<AdapterName>` entry to `script/config/chains/<chainId>.json` with `enabled: true` and constructor params for the target chain.
3. Run `04_DeployBalanceAdapters.s.sol` for that chain — adapters not enabled in that chain's config are skipped, and already-deployed adapters are skipped (idempotent).
4. Add the adapter address to NAVCalculator via Phase 6.

### 2.4 Adapter inventory (authoritative — `run()` list in `04_DeployBalanceAdapters.s.sol`)

`04_DeployBalanceAdapters.s.sol`'s `run()` calls `_deployIfEnabled(<name>)` for every adapter name below, on every chain. Each call fires only if `chains/<chainId>.json.balanceAdapters.<name>.enabled == true`. This means the `run()` list is the **union** across chains; per-chain selection happens through the config file.

The current `run()` list (check `04_DeployBalanceAdapters.s.sol` lines 45–109 for the authoritative source):

**Aave V3 (one instance per market):** `AaveV3_Core`, `AaveV3_Prime`, `AaveV3_Arbitrum`, `AaveV3_Base`, `AaveV3_Optimism`, `AaveV3_Gnosis`

**Single-instance protocols:** `SparkLend`, `AaveV3SafetyModule_stkGHO`, `Cap`

**Morpho Vaults:** `MorphoVault_kpkETHPrime_V1`, `MorphoVault_kpkETHPrime_V2`, `MorphoVault_kpkUSDCPrime_V1`, `MorphoVault_kpkUSDCPrime_V2`, `MorphoVault_kpkUSDCYieldV1`

**Morpho Markets (USD Alpha + Mainnet/Arbitrum):** `MorphoMarket_wstETH_USDC`, `MorphoMarket_cbBTC_USDC`, `MorphoMarket_wstUSR_USDC`, `MorphoMarket_ETHPlus_USDC`, `MorphoMarket_WBTC_USDC`, `MorphoMarket_RLP_USDC`, `MorphoMarket_syrupUSDC_USDC`, `MorphoMarket_sUSDS_USDT`, `MorphoMarket_sUSDS_USDC`

**Morpho Markets (ETH Alpha):** `MorphoMarket_ETHPlus_WETH`, `MorphoMarket_wstETH_WETH`, `MorphoMarket_weETH_WETH`, `MorphoMarket_rsETH_WETH`, `MorphoMarket_cbETH_USDC`

**Gearbox (Mainnet — ETH Alpha):** `GearboxMarket_kpkWETH`, `GearboxMarket_kpkwstETH`

**Balancer V3 (Mainnet — ETH Alpha):** `BalancerV3_rETH_WETH`

**Aura (one per pool):** `Aura_rETH_WETH` (Mainnet), `Aura_GHO_USDT_USDC` (Mainnet), `Aura_GHO_USDC_USDT` (Arbitrum), `Aura_GHO_USDC` (Base). Pool IDs: `rETH_WETH=271`, `GHO_USDC_USDT=99`, `GHO_USDC=19` (these go in the config's `pid` param).

**Curve (Mainnet):** `Curve_weETH_WETH`, `Curve_crvUSD_USDC`, `Curve_crvUSD_USDT`, `Curve_RLUSD_USDC`

**Convex (Mainnet):** `Convex_weETH_WETH`, `Convex_crvUSD_USDC`, `Convex_crvUSD_USDT`, `Convex_RLUSD_USDC`

**Explicitly not wired** (contracts exist in the repo but no Alpha fund needs them): `CompoundV3_*`, `DaiDsr`, `SkySavingsUsds`, `StakeWiseV3Vault_*`, `StakeWiseV3OsToken_*`, `AaveV3SafetyModule_stkAAVE`. If you need one later, add a `_deployIfEnabled("<Name>")` line to `run()`, add the config entry to `chains/<id>.json`, and add the name to `06_Configure.s.sol`'s `_balanceAdapterNames()` — otherwise the adapter deploys but never registers on NAVCalculator.

> **`ERC20Default` is special** — it's deployed inside `NAVCalculator.initialize()` (via `02_DeployProxies.s.sol`), not by `04_DeployBalanceAdapters.s.sol`. It auto-covers every asset registered on the NAVCalculator (wallet balances + native sentinel). Don't put it in the `run()` list.

> **Naming discipline matters.** The `_deployAdapter` dispatcher in `04_DeployBalanceAdapters.s.sol` routes by prefix (`_startsWith(adapterName, "AaveV3_")`). A new instance on Aave V3 must start with `AaveV3_`, a new Morpho Vault with `MorphoVault_`, and so on — otherwise the dispatcher falls through to `"Unknown adapter type"` and the deploy is a no-op.

**Invariant to check before each deploy run:** `chains/<id>.json.balanceAdapters.<Name>` exists ⇔ `04_DeployBalanceAdapters.s.sol` has `_deployIfEnabled("<Name>")` ⇔ `06_Configure.s.sol._balanceAdapterNames()` includes `"<Name>"`. All three or none.

---

## Phase 3: Deploy Price Feed Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

> **RPC shortcut:** `--rpc-url` is optional when `ALCHEMY_API_KEY` is set — each chain config has `"rpc": "$ALCHEMY"` which `ConfigReader` resolves using `ALCHEMY_API_KEY` and the chain's Alchemy network. See `script/deploy/README.md`. The commands below include `--rpc-url` explicitly for clarity.

### 3.1 Mainnet

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 3.2 Gnosis

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 100 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 3.3 L2 chains (Arbitrum, Base, Optimism)

```bash
# Arbitrum
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 \
  --broadcast \
  --private-key $PRIVATE_KEY

# Base
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 8453 \
  --broadcast \
  --private-key $PRIVATE_KEY

# Optimism
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 10 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 3.4 Verify

Deployed adapter addresses are auto-saved to `script/config/chains/<chainId>.json` under `.priceFeeds.<name>.deployed` via `ConfigReader.writeAdapterAddress(...)`. `assets.json` is only used for constructor inputs; it is not the authoritative record of deployed addresses. Check the console output for each deployed adapter address too — the `[OK] <Name> deployed at: 0x...` line is the fastest sanity check.

**Re-run safety:** If the script is interrupted, re-running will skip already-deployed adapters (checks the `deployed` field in the chain config).

---

## Phase 4: Deploy Balance Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

### 4.1 Mainnet

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 4.2 Other chains

Same pattern — replace RPC URL and chain ID:

```bash
# Arbitrum
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 --broadcast --private-key $PRIVATE_KEY

# Base
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 8453 --broadcast --private-key $PRIVATE_KEY

# Optimism
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 10 --broadcast --private-key $PRIVATE_KEY

# Gnosis
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 100 --broadcast --private-key $PRIVATE_KEY
```

### 4.3 Verify

Deployed addresses are auto-saved to `script/config/chains/{chainId}.json` under `balanceAdapters.{name}.deployed`.

**Re-run safety:** Same as price feeds — already-deployed adapters are skipped.

---

## Phase 5: Register Assets on NAVCalculator

Assets (tokens) must be registered on NAVCalculator with their price feed (Chainlink or Custom oracle address). This is done via `RegisterAssets.s.sol`.

### 5.1 Review token list

Token definitions live in `script/config/assets.json` under `tokens.{chainId}`. Each token has:

- `address` — token contract address
- `type` — `"Chainlink"`, `"Custom"`, or `"None"`
- `pricefeed` — oracle address (Chainlink feed or custom price adapter)
- `heartbeat` — staleness threshold in seconds

Tokens with `type: "None"` or empty `pricefeed` are skipped.

The list of symbols to register per chain is hardcoded in `RegisterAssets.s.sol` function `_symbolsForChain()`. Add new symbols there if needed.

### 5.2 Dry run (report only)

Run without `--broadcast` and without `--rpc-url` to see what would be registered:

```bash
forge script script/manage/RegisterAssets.s.sol --chain-id 1
```

### 5.3 Generate Safe TX batch + broadcast

Run with `--rpc-url` to verify on-chain state and generate Safe TX JSON. With `--broadcast --private-key`, the script also calls `registerAsset()` directly (sender must have MANAGER role):

```bash
# Mainnet
forge script script/manage/RegisterAssets.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Output: `safe-transactions/{chainId}-register-assets.json`

If broadcasting directly (sender has MANAGER), assets are registered immediately. Otherwise, import the Safe TX JSON into Safe UI and execute via multisig.

### 5.4 Safe UI Transaction Builder workflow

If you're executing the queued Safe TX JSON (not broadcasting directly), this is the exact flow:

1. Open the per-chain Safe in Safe UI: `https://app.safe.global/home?safe=<chain_shortname>:<safe_address>` (e.g. `eth:0x00008bB2Ff12ca49eD157B21a0D955c63C9ab31F` for Mainnet).
2. Apps → "Transaction Builder".
3. Click the JSON icon top-right → "Load batch" → select `safe-transactions/{chainId}-register-assets.json`.
4. The Builder parses each call. Review every row: contract address should be `0x5a0b…54C6` (NAVCalculator proxy), function should be `registerAsset(address,address,uint8,uint256)`, and the arguments should match `assets.json` for the chain. **Don't skip this step** — the JSON is generated but not cryptographically tied to the config.
5. "Create Batch" → "Send Batch" → collect threshold signatures → execute.
6. After execution, run the verification commands in Phase 9.1 to confirm every intended asset is registered.

Same flow applies to `safe-transactions/{chainId}-configure.json` in Phase 6 and any `ManageAdapters.s.sol` output in Phase 7.

### 5.5 Repeat for all chains

Run the same script for each chain (42161, 8453, 10, 100).

---

## Phase 6: Add Balance Oracles to NAVCalculator

After balance adapters are deployed, they must be registered on NAVCalculator via `addBalanceOracle()`. This requires the MANAGER role.

### Option A: Use `06_Configure.s.sol` (Safe TX batch)

```bash
forge script script/deploy/06_Configure.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

Output: `safe-transactions/{chainId}-configure.json` — import into Safe UI.

### Option B: Use `ManageAdapters.s.sol` (individual Safe TXs)

Edit `ManageAdapters.s.sol` and uncomment `_addBalanceOracle(adapterAddress)` calls:

```solidity
function run() public override {
    setUp();
    validateAddresses();
    _addBalanceOracle(0x...); // adapter address from config
}
```

Then run:

```bash
forge script script/manage/ManageAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

### Option C: Direct broadcast (if sender has MANAGER)

Call `addBalanceOracle()` directly on the NAVCalculator proxy using `cast`:

```bash
cast send 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "addBalanceOracle(address)" <adapter_address> \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --private-key $PRIVATE_KEY
```

---

## Phase 7: Set Custom Price Feeds on NAVCalculator

Custom price feed adapters (deployed in Phase 3) must be linked to their assets on NAVCalculator via `setPriceFeed()`. This is separate from asset registration — `registerAsset()` sets the initial price feed, but `setPriceFeed()` can update it later.

If you registered assets in Phase 5 with the correct Custom oracle addresses in `assets.json`, the price feeds are already set. Only use this phase if you need to update or add price feeds after initial registration.

### Using ManageAdapters.s.sol

```solidity
_setPriceFeed(
    0x...,  // asset address
    0x...,  // custom price adapter address (from Phase 3)
    IPrices.PriceType.Custom,
    3600    // heartbeat
);
```

### Using cast

```bash
cast send 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "setPriceFeed(address,address,uint8,uint256)" \
  <asset> <priceFeed> 1 3600 \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --private-key $PRIVATE_KEY
```

(PriceType: 0 = Chainlink, 1 = Custom)

---

## Phase 8: Contract Verification

### 8.1 Generate verification commands

```bash
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
```

### 8.2 Run the printed commands

The script outputs ready-to-run `forge verify-contract` commands. Copy and run each one. Make sure the corresponding explorer API key is set in your environment.

### 8.3 Repeat for all chains

```bash
# Arbitrum
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Base
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Optimism
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Gnosis
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
```

---

## Phase 9: Post-Deployment Validation

### 9.1 Verify on-chain state

For each chain, check:

```bash
# Check whether a specific asset is registered
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "isAssetRegistered(address)(bool)" <asset_address> \
  --rpc-url <RPC_URL>

# List all registered assets (returns Asset[] — address, symbol, price type, etc.)
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "getRegisteredAssets()" \
  --rpc-url <RPC_URL>

# Get detailed price feed data for an asset
# Returns PriceFeedData: (address priceFeed, uint8 priceType, int256 price, uint8 decimals,
#                        uint256 chainlinkHeartbeat, uint256 updatedAt, bool stale, bool sequencerDown)
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "getPriceData(address)" <asset_address> \
  --rpc-url <RPC_URL>
```

> **Note:** NAVCalculator inherits from `Balances`, which exposes balance-oracle registry getters. Use these for registration checks (all public, `view`):
>
> ```bash
> # All registered balance oracles
> cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 "getAllOracles()(address[])" --rpc-url <RPC>
>
> # Is a specific adapter registered?
> cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 "isOracleRegistered(address)(bool)" <adapter> --rpc-url <RPC>
>
> # Count of registered oracles
> cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 "getOracleCount()(uint256)" --rpc-url <RPC>
>
> # Which oracles report an asset
> cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 "getOraclesForAsset(address)(address[])" <asset> --rpc-url <RPC>
> ```
>
> Phase 9.3 below is for confirming a *registered* adapter returns plausible data, not for checking registration.

### 9.2 Test NAV calculation

```bash
# Get total NAV for a Safe in a given quote asset.
# Returns NAV struct: (int256 value, Asset quoteAsset, uint64 timestamp,
#                     Asset[] stalePriceAssets, bool sequencerDown)
cast call 0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6 \
  "getAccountNav(address,address)" <safe_address> <quote_asset_address> \
  --rpc-url <RPC_URL>
```

### 9.3 Verify each balance oracle returns data

```bash
# For each balance adapter, call the v2 interface (IBalanceOracleAdapter)
cast call <adapter_address> \
  "getOracleBalanceForAsset(address,address)(uint256,bool)" <safe_address> <underlying_asset> \
  --rpc-url <RPC_URL>

# Or enumerate every position the oracle reports for the Safe:
cast call <adapter_address> \
  "getOraclePositions(address,address)" <safe_address> 0x0000000000000000000000000000000000000000 \
  --rpc-url <RPC_URL>
```

---

## Known Gaps to Address Before Deployment

> **Gaps 1–3 closed** by PRs [#11](https://github.com/karpatkey/onchain-accounting/pull/11) and [#12](https://github.com/karpatkey/onchain-accounting/pull/12) (merged 2026-04-17). The remaining gaps 4 and 5 do not block Alpha fund launch. Scope is limited to what the **ETH Alpha Fund** and **USD Alpha Fund** actually use — stale or unused v1 entries are intentionally excluded.

### 1. L2 price feed deploy functions — CLOSED

Closed in PR #11 (commits [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f) and [`2a9c0d7`](https://github.com/karpatkey/onchain-accounting/commit/2a9c0d7)). L2 deploy functions (`_deployWstEthL2`, `_deployWeEthL2`, `_deployRsEthL2`, `_deployEzEthL2`, `_deployCbEthL2`, `_deploySyrupUsdcL2`) are implemented and wired into `_deployArbitrumPriceAdapters`, `_deployBasePriceAdapters`, and `_deployGnosisPriceAdapters`. `_deploySxdai` added to Gnosis in the same PR.

### 2. `assets.json` `priceFeeds` section — CLOSED

Closed in PR #11 (commit [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f)). Every Custom price adapter used by ETH Alpha or USD Alpha has a `priceFeeds.{adapter}.{chainId}` entry with `enabled` and `constructor` params. Chain configs were pre-seeded with matching `priceFeeds` scaffolds so `ConfigReader.writeAdapterAddress` can persist deployed addresses.

### 3. `06_Configure.s.sol` and `04_DeployBalanceAdapters.s.sol` alignment — CLOSED

Closed in PR #12 (commit [`2a75423`](https://github.com/karpatkey/onchain-accounting/commit/2a75423)). `06_Configure.s.sol` was rewritten around a shared `_balanceAdapterNames()` helper that matches the 43 adapter names deployed by `04`. No more MorphoBlue_USDC ghost reference; all 10 new adapters from PR #12 are included.

### 4. Bridge adapters — partial per-chain coverage

Current state per chain (verified 2026-04-17 from `chains/<id>.json.bridgeAdapters`):

| Chain | Enabled | Deployed |
|---|---|---|
| Mainnet (1) | CCIP, Across, Stargate, CCTP — all `enabled: false` | None |
| Arbitrum (42161) | CCIP, Across, Stargate, CCTP | All four deployed |
| Base (8453) | Superchain, Across, Stargate, CCTP | All four deployed |
| Optimism (10) | Superchain, CCTP | `enabled: true` but `deployed: ""` — **pending broadcast** |
| Gnosis (100) | Gnosis bridge — `enabled: false` | None |

Bridge adapters exist to account for funds in-flight between chains (outbound: bridged-out USDC sitting in a Safe on source chain + inbound ERC20 on destination chain pending claim). Without them, NAV under-reports during an inflight bridge. Each adapter implements `IBridgeAdapter` and is registered on `BridgeEscrow` via `AuthorizeBridgeAdapters.s.sol` (or Safe TX batch from `06_Configure.s.sol`).

**Does not block Alpha fund launch** — Alpha funds bridge inbound to Arbitrum and outbound from Base, both covered. Deploy on Optimism + Mainnet before using those chains as bridge sources. Gnosis doesn't have a cross-chain bridge product yet; its entry is a placeholder.

Use `05_DeployBridgeAdapters.s.sol` to deploy. Re-run safety is the same as `03`/`04` — already-deployed entries are skipped.

### 5. Native xDAI coverage on Gnosis — deferred

`ERC20Default` is registered on Gnosis with the xDAI sentinel address (`NATIVE_ADDRESS`) pre-inserted at NAVCalculator init, but no fork test confirms that `getOracleBalanceForAsset(NATIVE_ADDRESS, safe)` returns the correct native balance. USD Alpha Fund uses native xDAI on Gnosis. Verify with a fork test against a Safe holding xDAI before the Gnosis deployment goes live. Not blocking pre-deployment.

---

## Quick Reference: Deployment Order

```
Phase 0: Prerequisites (merge PRs, env setup, run tests)
    |
Phase 1: Configure price feed params in assets.json
Phase 2: Configure balance adapter params in chain configs
    |   (these two can be done in parallel)
    v
Phase 3: Deploy price feed adapters (03_DeployPriceFeeds.s.sol) -- per chain
Phase 4: Deploy balance adapters (04_DeployBalanceAdapters.s.sol) -- per chain
    |   (these two can be done in parallel per chain)
    v
Phase 5: Register assets on NAVCalculator (RegisterAssets.s.sol) -- per chain
Phase 6: Add balance oracles to NAVCalculator (06_Configure / ManageAdapters) -- per chain
    |   (5 and 6 can be batched into one Safe TX if using Safe)
    v
Phase 7: Set custom price feeds (if not done in Phase 5) -- per chain
    |
Phase 8: Verify contracts on block explorers -- per chain
Phase 9: Post-deployment validation -- per chain
```

---

## Rollback

- **Price feeds and balance adapters are NOT upgradeable** — they're standalone contracts. To "rollback", deploy a corrected version and update the NAVCalculator to point to the new one via `setPriceFeed()` / `removeBalanceOracle()` + `addBalanceOracle()`. Both are MANAGER-only.
- **NAVCalculator and BridgeEscrow ARE upgradeable** (UUPS). Use `script/upgrade/UpgradeNAVCalculator.s.sol` or `UpgradeBridgeEscrow.s.sol`. Requires DEFAULT_ADMIN_ROLE on the target proxy — i.e. the OIV Safe for each chain.
- **Partial deploys are re-runnable.** `03_DeployPriceFeeds.s.sol` and `04_DeployBalanceAdapters.s.sol` both read `.deployed` and skip any entry already populated. If a broadcast runs out of gas halfway, top up the EOA and re-run — the script will continue from where it stopped.

---

## Troubleshooting

### "Unknown adapter type" in the `04_DeployBalanceAdapters.s.sol` output

The dispatcher routes by prefix (e.g. `AaveV3_`, `MorphoVault_`) with exact-match fallbacks for the single-instance adapters `Cap`, `DaiDsr`, `SkySavingsUsds`, and `SparkLend`. If you see `Unknown adapter type: <Name>`, either your config entry name doesn't match a prefix or exact-match case — fix by adding the missing branch in `_deployAdapter`. When adding a new single-instance adapter, add an `_equals(adapterName, "<Name>")` branch alongside the existing prefix branch, following the `SparkLend` pattern:

```solidity
if (_equals(adapterName, "SparkLend") || _startsWith(adapterName, "SparkLend_")) {
    return _deploySparkLend(adapterName, navCalculator);
}
```

`_deployIfEnabled` silently treats a fall-through as a no-op (returns `address(0)` and skips the config write) — watch the console output for the `Unknown adapter type:` line.

### `PriceFeedNotSet(<asset>)` revert during `getAccountNav`

The asset is registered in NAVCalculator, but no price feed is linked. Happens when Phase 5 registered the asset with `type: "None"` or empty `pricefeed`. Fix: call `setPriceFeed(asset, priceFeed, priceType, heartbeat)` via Phase 7.

### Every asset flagged `stale: true`

Check `chainConfig.chainlinkSequencerFeed`. On L2s, `checkL2SequencerUptime()` ORs into every price's stale flag — if the sequencer uptime feed is misconfigured (wrong address or not set during `NAVCalculator.initialize`), every price reads stale. On L1 it should be `address(0)`.

### `getAccountNav` reverts with `AssetNotFound()`

A balance oracle returned a `PositionBalance` for an underlying asset that isn't registered on NAVCalculator. Either register the asset (Phase 5) or fix the oracle to stop returning it.

### Chainlink feed shows `answer <= 0`

NAV v2 returns `(0, decimals, true)` for any Chainlink answer ≤ 0 (`src/prices/Prices.sol:70-72`). The asset contributes 0 to NAV and is flagged stale. Usually indicates a broken feed or one that just reverted; check `latestRoundData()` directly and contact the oracle provider.

### `forge script` fails with `vm.writeJson: no such key`

Foundry's `vm.writeJson` requires the parent object to exist. Make sure `chains/<id>.json` has `"priceFeeds": {}` and `"balanceAdapters": {}` keys even if empty, and every specific adapter name you reference has its sub-object (with `"deployed": ""` at minimum). Missing parents are silent — the script succeeds but doesn't persist the address.

### Role misconfiguration

If `hasRole(DEFAULT_ADMIN_ROLE, <deployer EOA>) == true` after `02_DeployProxies.s.sol`, that's a red flag — the deployer should retain no ongoing roles. Investigate before running Phases 3-7. If `hasRole(MANAGER, <safe>) == false`, the `grantRole(MANAGER, ...)` step in `02_DeployProxies.s.sol` (or `06_Configure.s.sol`) didn't execute or hasn't been executed yet — re-run or generate a Safe TX.

### `forge verify-contract` fails with "Already verified"

Not actually a failure — Etherscan caches verified bytecode by hash. You can skip or pass `--watch` to just confirm.

---

## How to add a new Custom price oracle

Workflow for a brand-new oracle after the migration PRs are merged. Each step has a canonical reference file — mirror it.

1. **Write the oracle** under `src/prices/protocols/<Name>_Price.sol`. Inherit `IPriceFeedCustom` (8-decimal USD output, `(uint256 price, bool stale)` return). Reference: `sDAI_Price.sol` for a simple ERC4626-style feed, `weETH_Price.sol` for a two-hop Chainlink composition.
2. **Write the unit test** under `test/prices/protocols/<Name>_Price.t.sol`. Minimum: constructor revert coverage for every invalid-argument path.
3. **Write the fork test** under `test/prices/protocols/fork/<Name>_Price.fork.t.sol`. Pin a block, assert an exact price value, exercise the stale path by warping `block.timestamp` past the heartbeat.
4. **Register in `assets.json`** under `priceFeeds.<Name>.<chainId>` with `enabled: true` and all constructor params. Also make sure `chains/<chainId>.json.priceFeeds.<Name>` exists (even as `{"deployed": ""}`) so `ConfigReader.writeAdapterAddress` has a parent to write to.
5. **Wire into `03_DeployPriceFeeds.s.sol`**: add `import {...}` at top, add `_deployIfEnabled`-style dispatch inside the correct `_deploy<Chain>PriceAdapters()` function, add a `_deploy<Name>()` helper that reads constructor params via `ConfigReader.readPriceFeedParam` and writes back via `ConfigReader.writeAdapterAddress`. Reference: `_deploySdai` in the same file.
6. **Run tests locally**: `forge test --match-path "test/prices/protocols/<Name>*"` must pass before pushing.
7. **Register the asset with the new price feed**. If the asset is already registered on NAVCalculator with a Chainlink feed, call `setPriceFeed(asset, newFeed, PriceType.Custom, heartbeat)` (Phase 7) via Safe. Otherwise, register from scratch in Phase 5.
8. **Update `assets.json.tokens.<chainId>.<Symbol>.pricefeed`** to the newly-deployed adapter address, so future `RegisterAssets.s.sol` runs (if you unregister + re-register) use the right feed.

---

## How to add a new balance adapter

Workflow for adding a new protocol adapter or a new instance of an existing protocol.

**New instance of an existing protocol (e.g. a new Curve pool):**

1. Add a config entry to `chains/<chainId>.json.balanceAdapters.Curve_<pool>` with the constructor params (`gauge`, `protocol`, `positionDetail`) and `"deployed": ""`.
2. Add `_deployIfEnabled("Curve_<pool>")` inside `04_DeployBalanceAdapters.s.sol`'s `run()` function.
3. Add `"Curve_<pool>"` to `_balanceAdapterNames()` in `06_Configure.s.sol`.
4. Run `forge build` + `forge test` to confirm nothing regressed.
5. Deploy (Phase 4) and add to NAVCalculator (Phase 6).

**New protocol entirely (e.g. a new yield primitive):**

1. **Write the adapter** under `src/balances/protocols/<Protocol>.sol`. Inherit `IBalanceOracleAdapter` — must implement `getOraclePositions`, `getOracleBalances`, `getOracleBalanceForAsset`, `underlyingAssetsSupported`, and `supportsInterface`. Reference: `MorphoVault.sol` for a single-asset vault, `Convex.sol` for a multi-reward-token protocol.
2. **Write the unit test** under `test/balances/protocols/<Protocol>.t.sol`. Cover: constructor, `underlyingAssetsSupported`, zero balance, non-zero balance, asset filter.
3. **Write the fork test** under `test/balances/protocols/fork/<Protocol>.fork.t.sol`. Cover: real on-chain position, real reward accruals, asset filter at a pinned block.
4. **Add to `AdapterConsistency.t.sol`** if the protocol has non-trivial edge cases the existing cross-adapter invariants don't cover (zero balance handling, debt positions, asset filter).
5. **Import + dispatch in `04_DeployBalanceAdapters.s.sol`**: add `import`, add `_deployIfEnabled("<Protocol>_<Instance>")` to `run()`, add a `_startsWith(adapterName, "<Protocol>_")` branch in `_deployAdapter`, and a `_deploy<Protocol>()` helper that reads params.
6. **Add to `06_Configure.s.sol._balanceAdapterNames()`.**
7. **Add instance to chain config.**
8. **Run full test suite.** `forge test` non-fork + fork must both be green before pushing.
9. **Deploy + register on NAV** via Phases 4 and 6.

> **Naming rule:** new balance adapter files use PascalCase. Contract names use the same PascalCase + a `BalanceOracle` suffix where the convention exists (see `CurveBalanceOracle`, `MorphoVaultBalanceOracle`). The `balanceOf` parameter must be named `account` (enforced pattern, not `safe`).

---

## Maintaining this runbook

Every time you:
- Change anything in `02_DeployProxies.s.sol`, `03_DeployPriceFeeds.s.sol`, `04_DeployBalanceAdapters.s.sol`, `05_DeployBridgeAdapters.s.sol`, or `06_Configure.s.sol`,
- Add a new adapter family,
- Hit a gotcha that burned a deployment,
- Change the role-granting flow or `chainConfig.admin`/`manager`,

update the corresponding section here in the same PR. This runbook only stays trustworthy if it's kept in lockstep with the code it describes.
