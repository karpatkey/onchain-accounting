# Pending Production Deploys — NAV v2 full redeploy

**NAV v2 full redeploy pending — all contracts TBD.** The team is wiping all evidence of past deployments and redeploying NAV v2 from scratch (new bytecode). Every one of our deployed contracts — NAVCalculator impl/proxy, BridgeEscrow impl/proxy, the UUPS placeholder, ERC20Default, all balance/meta adapters, all custom price-feed adapters, and all bridge adapters — is being redeployed. Treat every deployed address below as **TBD** until the from-scratch redeploy completes. Everything below is wired in code (harness deploys ephemerally on the fork; production redeploy not yet run).

**Source of truth for state**: the deploy-intent files under `script/config/contracts-deployment-config/` — balance adapters in `balance-adapters/<chainId>.json` (plain) and `meta-balance-adapters/<chainId>.json` (meta), custom price feeds in `custom-price-feeds/<chainId>.json` — paired with the deployed-address state in `script/config/deployments/<chainId>.json`. There is no `deployed` field in the config files; deployed addresses live only in `deployments/<chainId>.json`. After the wipe, every `deployments/<chainId>.json` is empty (`{}`), meaning every enabled adapter/feed is "to be redeployed". This document is regenerated from that state — when in doubt, re-run the audit script in §6.

**Companion docs:** [`NAV_V2_DEPLOYMENT_RUNBOOK.md`](NAV_V2_DEPLOYMENT_RUNBOOK.md) (operational playbook), [`config/CONFIG_GUIDE.md`](config/CONFIG_GUIDE.md) (chain config schema). (Prior-production address records have been retired — for the NAV v2 redeploy there is no current production state to reference; deployed addresses are written to `deployments/<chainId>.json` as they land.)

> **Addendum 2026-05-30 (re-run §6 to regenerate against the wiped config):**
> - **`KelpWithdrawalQueue`** (Mainnet, PR #44 merged) and **`LidoWithdrawalQueue`** (Mainnet, PR #45) are wired in `contracts-deployment-config/balance-adapters/1.json` with no `deployments/1.json` entry yet — TBD like everything else, pending `04_DeployBalanceAdapters` + `addBalanceAdapters` registration (both are already listed in `nav-config/balance-adapters/1.json`, read by `06_Configure.s.sol`).
> - **NAVCalculator implementation:** PR #44's `NAVCalculator.hasPositions` change (fail-open via the positions path) ships as part of the fresh NAV v2 implementation deployed in `01_DeployImplementations.s.sol` — no separate UUPS upgrade is needed because the impl is being deployed from scratch.

---

## 1. Inventory — what's pending across all chains

Audit run 2026-05-11 against branch `feat/integration-test-add-accounts-616-4f20` (PR #35, tip `42e436c`).

> **NAV v2 full-redeploy note:** the counts below reflect the *incremental* gap captured by the original audit (adapters/feeds that had never been deployed). For the NAV v2 from-scratch redeploy this no longer bounds the work — **every** balance adapter, price-feed adapter, bridge adapter, plus the core NAVCalculator/BridgeEscrow impls and proxies, is being redeployed (all TBD). Re-run §6 against the wiped config to get the full per-chain count. No chain is "already deployed".

| Chain | Pending price feeds (orig. gap) | Pending balance adapters (orig. gap) | Total |
|---|---:|---:|---:|
| Mainnet (1) | 1 | 25 | **26** |
| Optimism (10) | 0 | 3 | 3 |
| Gnosis (100) | 0 | 0 | **0 (orig. gap; now all TBD)** |
| Base (8453) | 0 | 9 | 9 |
| Arbitrum (42161) | 0 | 9 | 9 |
| **Total** | **1** | **46** | **47** |

> **Chains added since the original audit:** **Polygon (137)** and **BSC (56)** were not in scope on 2026-05-11 and so are absent from the gap table above. They now carry deploy config (`chains/{137,56}.json` plus the matching `contracts-deployment-config/` entries) and empty `deployments/{137,56}.json`, so they are TBD like every other chain — Polygon currently resolves to `FluidFTokensMeta` (its `Fluid_fToken_*` plain keys are `enabled: false`). The §6 audit script now iterates all seven chains; re-run it for the live count.

### 1.1 Pending price feeds

ETHx was the only custom feed in the *original incremental gap* (below). In the NAV v2 from-scratch redeploy **every** enabled custom feed is TBD — `03_DeployPriceFeeds.s.sol` deploys all entries with `enabled: true` in `contracts-deployment-config/custom-price-feeds/<chainId>.json` (17 on mainnet, plus 3 on Gnosis, 3 on Base, 5 on Arbitrum at the time of writing). Re-run §6 for the live count.

| Chain | Adapter key | Contract | Constructor params (in `contracts-deployment-config/custom-price-feeds/<chainId>.json` `<key>.constructor`) |
|---|---|---|---|
| 1 | `ETHx` | `src/prices/protocols/ETHx_CustomPriceFeed.sol` (`ETHx_CustomPriceFeed`) | `ethx`, `stakePoolsManager`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |

### 1.2 Pending balance adapters — Mainnet (chain 1)

> **⚠ Pre-ADR-0010 listing.** The per-instance keys in this section (`CompoundV3_USDC`, `Fluid_fToken_*`, `Fluid_Vault_*`, `MorphoMarket_*`, `MorphoVault_*`, `GearboxMarket_*`, `StakeWiseV3Vault_*`, `UniswapV3_*`) reflect the original audit. They are **disabled** (`enabled: false`) in the current `contracts-deployment-config/balance-adapters/1.json` — the live deploy set replaced them with **meta-adapters** per [ADR 0010](../docs/decisions/0010-meta-balance-adapters.md): `CompoundV3CometsMeta`, `FluidFTokensMeta`, `FluidVaultsMeta`, `MorphoMarketsMeta`, `MorphoVaultsMeta`, `GearboxMarketsMeta`, `StakeWiseV3VaultsMeta`, `UniswapV3PoolsMeta`, etc. (plus the still-plain `AaveUmbrella`, `AaveV3SafetyModule`, `Cap`, `SparkLend`, `*WithdrawalQueue`). The §6 audit script unions both deploy folders, so re-run it for the authoritative enabled set; the tables below are kept only as the family-level coverage map.

Sorted by family.

**Compound V3 (6)**

| Key | Notes |
|---|---|
| `CompoundV3_USDC` | Comet 0xc3d688B66703497DAA19211EEdff47f25384cdc3 |
| `CompoundV3_USDS` | |
| `CompoundV3_USDT` | |
| `CompoundV3_WBTC` | |
| `CompoundV3_WETH` | |
| `CompoundV3_wstETH` | |

**Fluid (9)**

| Key | Notes |
|---|---|
| `Fluid_fToken_USDC` | Lending |
| `Fluid_fToken_USDT` | |
| `Fluid_fToken_WETH` | |
| `Fluid_fToken_wstETH` | |
| `Fluid_fToken_GHO` | |
| `Fluid_fToken_sUSDe` | |
| `Fluid_Vault_wstETH_USDC` | Borrow vault |
| `Fluid_Vault_weETH_wstETH` | |
| `Fluid_Vault_sUSDe_USDC` | |

**Aave family (2)**

| Key | Notes |
|---|---|
| `AaveV3SafetyModule` | stkGHO. In the NAV v2 redeploy this is deployed fresh (TBD) under this key; there is no longer a separate production `AaveV3SafetyModule_stkGHO` to reconcile against (all prior deployment evidence is wiped). Confirm the config uses the single `AaveV3SafetyModule` key before broadcasting. |
| `AaveUmbrella` | Aave V4 Umbrella stake tokens (stkwaEthUSDC.v1, stkwaEthUSDT.v1, stkwaEthWETH.v1, stkGHO.v1). Discovers available stake tokens dynamically via `RewardsController.getAllAssets()`. |

**StakeWise V3 (3)**

| Key | Notes |
|---|---|
| `osETH` (Mainnet), `osGNO` (Gnosis) custom feeds | osETH/osGNO are Custom-priced ERC20s via `osToken_CustomPriceFeed` — `custom-price-feeds/<chainId>.json` entries (deploy with `03_DeployPriceFeeds`, register with `RegisterAssets`) |
| `StakeWiseV3Vault_Genesis` | Genesis Vault `0xAC0F906E433d58FA868F936E8A43230473652885` — closes ACCOUNT_10's $24.6M coverage gap |
| `StakeWiseV3Vault_MetaVault` | Meta Vault `0x15639e82d2072fa510e5d2b5f0db361c823bcad3` — adapter shipped in PR #35 (`fddcd46`); production deploy still pending |

**Morpho (1 vault, plus markets-per-vault TBD — see §5)**

| Key | Notes |
|---|---|
| `MorphoVault_kpkEURC_V1` | kpk EURC Yield V2 (vault `0xa877d5BB…`) — closes ACCOUNT_9's $2.59M coverage gap. ⚠ Despite the `_V1` suffix in the config key, this is the **V2** of the kpk EURC Yield vault per Morpho's catalog (`name = "kpk EURC Yield V2"`). Naming inconsistency to fix in a follow-up: rename to `MorphoVault_kpkEURCYield_V2` to match the convention used by `_kpkUSDCPrime_V1/_V2`, `_kpkETHPrime_V1/_V2`. |

**Other (3)**

| Key | Notes |
|---|---|
| `StaderWithdrawalQueue` | Stader UserWithdrawalManager pending unstake requests |
| `UniswapV3_WBTC_WETH_3000` | Mainnet Uni V3 WBTC/WETH 0.3% pool. No current test-account exposure. |

### 1.3 Pending balance adapters — L2 chains

> Same caveat as §1.2: these per-instance keys are **disabled** in the current L2 deploy configs (all plain adapters on chains 10/8453/42161/100 are `enabled: false`). The enabled L2 deploys are the meta-adapters — re-run §6 for the live set (e.g. Optimism currently resolves to `AaveV3InstancesMeta` + `CompoundV3CometsMeta`, not the three `CompoundV3_*` keys below).

**Optimism (chain 10) — 3**

| Key |
|---|
| `CompoundV3_USDC` |
| `CompoundV3_USDT` |
| `CompoundV3_WETH` |

**Base (chain 8453) — 9**

| Key |
|---|
| `CompoundV3_USDC`, `CompoundV3_USDS`, `CompoundV3_USDT`, `CompoundV3_USDbC`, `CompoundV3_AERO`, `CompoundV3_WETH` |
| `Fluid_fToken_USDC`, `Fluid_fToken_WETH`, `Fluid_fToken_wstETH`, `Fluid_fToken_GHO` |

**Arbitrum (chain 42161) — 9**

| Key |
|---|
| `CompoundV3_USDC`, `CompoundV3_USDCe`, `CompoundV3_USDT`, `CompoundV3_WETH` |
| `Fluid_fToken_USDC`, `Fluid_fToken_USDT`, `Fluid_fToken_WETH`, `Fluid_fToken_wstETH`, `Fluid_fToken_GHO` |

**Gnosis (chain 100) — no incremental gap from the original audit, but all adapters are TBD in the NAV v2 redeploy**

---

## 2. kpk Morpho Vault catalog cross-check

The user's authoritative kpk Morpho vault list (from the kpk catalog) cross-referenced against our current chain config. **All addresses verified against on-chain `symbol()` + `name()` calls.**

### 2.1 Mainnet (chain 1)

| # | Vault address | On-chain symbol | On-chain name | Asset | In our config? | Action |
|---|---|---|---|---|---|---|
| 1 | `0xe108fbc0…7A993aDd` | `kpk_USDC_Prime` | kpk USDC Prime | USDC | ✅ `MorphoVault_kpkUSDCPrime_V1` (TBD — redeploy) | **redeploy** |
| 2 | `0xd4e95092…896563b5` | `kpkUSDT` | USDT Yield | USDT | ❌ missing | **add config + deploy** |
| 3 | `0x0c6aec60…b398DC1` | `kpk_EURC_Yield` | kpk EURC Yield | EURC | ❌ missing | **add config + deploy** (note: needs EURC asset registered first — already in PR #35 via `9d3b7aa`) |
| 4 | `0xd564F765…5e8e7C8` | `kpk_ETH_Prime` | kpk ETH Prime | WETH | ✅ `MorphoVault_kpkETHPrime_V1` (TBD — redeploy) | **redeploy** |
| 5 | `0xc88eFFD6…E982A` | `kpk_ETH_Yield` | kpk ETH Yield | WETH | ❌ missing | **add config + deploy** |
| 6 | `0x9178eBE0…cc3509` | `kpk_USDC_Yield` | kpk USDC Yield | USDC | ❌ missing | **add config + deploy** |
| 7 | `0xdaD4e51d…712065` | `kpk_USDT_Prime` | kpk USDT Prime | USDT | ❌ missing | **add config + deploy** |
| 8 | `0x4Ef53d2c…962C9ee6` | `kpk_USDC_PrimeV2` | kpk USDC Prime V2 | USDC | ✅ `MorphoVault_kpkUSDCPrime_V2` (TBD — redeploy) | **redeploy** |
| 9 | `0xa877d5bb…1a275f` | `kpk_EURC_YieldV2` | kpk EURC Yield V2 | EURC | ⚠ `MorphoVault_kpkEURC_V1` (PR #35, **misnamed** — should be `_kpkEURCYield_V2`) | **rename + deploy** |
| 10 | `0xBb50A534…E65FF9` | `kpk_ETH_PrimeV2` | kpk ETH Prime V2 | WETH | ✅ `MorphoVault_kpkETHPrime_V2` (TBD — redeploy) | **redeploy** |
| 11 | `0xD5cCe260…AaeaA13` | `kpk_USDC_YieldV2` | kpk USDC Yield V2 | USDC | ❌ missing | **add config + deploy** |
| 12 | `0x5dbf760b…D77725` | `kpk_ETH_YieldV2` | kpk ETH Yield V2 | WETH | ❌ missing | **add config + deploy** |
| 13 | `0x65D217B4…43A8e1E` | `discarded` | discarded | USDT | ❌ missing | **DO NOT DEPLOY** — kpk team retired this vault on-chain (symbol/name set to literal "discarded"). The current USDT Prime V2 is #14 below. |
| 14 | `0x870F0BF2…F2C8A8` | `kpk_USDT_PrimeV2` | kpk USDT Prime V2 | USDT | ❌ missing | **add config + deploy** (this is the live V2 USDT Prime, replacing #13) |

**Net mainnet kpk-vault gap**: 8 vaults need to be added to `contracts-deployment-config/balance-adapters/1.json` (and `nav-config/balance-adapters/1.json`) and deployed (#2, #3, #5, #6, #7, #11, #12, #14). Plus rename #9.

### 2.2 Arbitrum (chain 42161)

| # | Vault address | On-chain symbol | On-chain name | Asset | In our config? | Action |
|---|---|---|---|---|---|---|
| 15 | `0x2C609d9C…9Ec53579d` | `kpk_USDC_Yield` | kpk USDC Yield | USDC.e (Arb native USDC) | ✅ `MorphoVault_kpkUSDCYieldV1` (TBD — redeploy) | **redeploy** |
| 16 | `0x5837e418…FF5e73` | `kpk_USDC_YieldV2` | kpk USDC Yield | USDC.e | ❌ missing | **add config + deploy** |

**Net Arbitrum kpk-vault gap**: 1 vault needs to be added (#16).

---

## 3. Morpho Markets per kpk Vault — TODO

The user requested the catalog to also include the underlying Morpho markets each kpk vault supplies into. Enumerating these on-chain requires `MetaMorpho.withdrawQueueLength()` + `withdrawQueue(uint256)` per vault, then `MorphoBlue.idToMarketParams(Id)` per market — multiple round-trips per vault. The audit script attempted this but the function selector was incorrect; markets-per-vault enumeration is **deferred**.

### 3.1 What we already have

Our current `contracts-deployment-config/balance-adapters/1.json` `MorphoMarket_*` entries cover 12 markets (all TBD — to be redeployed in the NAV v2 redeploy):

| MorphoMarket adapter | Loan | Collateral |
|---|---|---|
| `MorphoMarket_wstETH_USDC` | USDC | wstETH |
| `MorphoMarket_wstETH_WETH` | WETH | wstETH |
| `MorphoMarket_cbBTC_USDC` | USDC | cbBTC |
| `MorphoMarket_WBTC_USDC` | USDC | WBTC |
| `MorphoMarket_rsETH_WETH` | WETH | rsETH |
| `MorphoMarket_weETH_WETH` | WETH | weETH |
| `MorphoMarket_sUSDS_USDT` | USDT | sUSDS |
| `MorphoMarket_syrupUSDC_USDC` | USDC | syrupUSDC |
| `MorphoMarket_wstUSR_USDC` | USDC | wstUSR |
| `MorphoMarket_RLP_USDC` | USDC | RLP |
| `MorphoMarket_ETHPlus_USDC` | USDC | ETH+ |
| `MorphoMarket_ETHPlus_WETH` | WETH | ETH+ |

These are direct-supply / direct-borrow Market adapters — different from MetaMorpho Vault adapters. They're for accounts that go around the vault and supply into a market directly.

### 3.2 What we don't have

Markets used by the kpk vaults but NOT yet in our adapter set. To enumerate, run:

```bash
# For each kpk vault on chain 1:
QLEN=$(cast call $VAULT 'withdrawQueueLength()(uint256)' --rpc-url $MAINNET_URL)
for i in $(seq 0 $((QLEN-1))); do
  MID=$(cast call $VAULT "withdrawQueue(uint256)(bytes32)" $i --rpc-url $MAINNET_URL)
  cast call 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
    "idToMarketParams(bytes32)(address,address,address,address,uint256)" $MID \
    --rpc-url $MAINNET_URL
done
```

Deduplicate market IDs across the 13 vaults. Cross-reference against the `marketId` field in each existing `MorphoMarket_*` config block. Any market ID Morpho-Blue's `idToMarketParams` returns that isn't in our config → add as a new `MorphoMarket_<loan>_<collat>` config block.

**Estimated effort**: 30 min cast scripting + small PR adding the resulting market configs to `contracts-deployment-config/balance-adapters/1.json` (and `nav-config/balance-adapters/1.json`). The Vault adapter handles vault-mediated NAV, so adding the per-market adapters is for completeness (any account that supplies directly into one of these markets without going through a kpk vault).

---

## 4. Gearbox markets cross-check

> **Note (ADR 0010):** like the Morpho/Compound/Fluid families, the per-market `GearboxMarket_*` keys below are `enabled: false` in the current deploy config — the enabled deploy is the single `GearboxMarketsMeta` meta-adapter, which derives each market's identity on-chain from its `bytes32` market coordinate. The per-market keys remain (disabled) as the coverage map.

| # | Address | On-chain symbol | On-chain name | In our config? |
|---|---|---|---|---|
| 1 | `0x9396DCbf…699571EF` | `kpkWETH` | WETH Market | ✅ `GearboxMarket_kpkWETH` (TBD — redeploy) |
| 2 | `0xA9d17f6D…2e0AABa64` | `kpkwstETH` | wstETH v3 | ✅ `GearboxMarket_kpkwstETH` (TBD — redeploy) |

**Both configured but TBD** — to be redeployed in the from-scratch NAV v2 redeploy.

---

## 4.5 MorphoMarket — protocol name rewrite

> **Note (ADR 0010):** the per-pair `MorphoMarket_*` config blocks are `enabled: false` in the current deploy config; the enabled deploy is the single `MorphoMarketsMeta` meta-adapter, which derives each market's identity on-chain from its `bytes32` marketId. The per-pair keys below remain in the config (disabled) as the coverage map. The naming rewrite still applies — it is the meta-adapter's rendered protocol string that carries the `"Morpho - <pair>"` form — and the clearing snippet is harmless either way (disabled keys never land in `deployments/<id>.json`).

PR #35 changed the protocol display name from `"Morpho Blue - <pair>"` → `"Morpho - <pair>"` (CLAUDE.md naming convention; `feedback_morpho_naming` memory). In the NAV v2 full redeploy the Morpho coverage is redeployed from scratch (new bytecode, new address) under the updated `"Morpho - <pair>"` name, so there is no old/new bytecode distinction to manage — all entries are TBD.

Action: **redeploy** every `MorphoMarket_*` adapter; `04_DeployBalanceAdapters.s.sol` writes the new address to `deployments/<id>.json .balanceAdapters.<key>`.

**Affected adapters:** 12 on mainnet, 4 on Base, 2 on Arbitrum (per the `MorphoMarket_*` entries in `contracts-deployment-config/balance-adapters/<id>.json`). Use the standard `04_DeployBalanceAdapters.s.sol` flow. Because the whole NAV v2 redeploy starts from empty `deployments/<id>.json` files, the pre-redeploy clearing step below is part of the global wipe (shown here for completeness — addresses live only in `deployments/<id>.json`, never in the deploy-config files):

```bash
# Mainnet
python3 -c "
import json
path = 'script/config/deployments/1.json'
d = json.load(open(path))
adapters = d.get('balanceAdapters', {})
for k in list(adapters):
    if k.startswith('MorphoMarket_'):
        del adapters[k]
json.dump(d, open(path, 'w'), indent=2)
"
# Repeat for deployments/8453.json and deployments/42161.json.
```

Then run Phase A's `04_DeployBalanceAdapters.s.sol` per chain. Because there is no prior production deployment to migrate from (the NAV v2 redeploy starts from a clean NAVCalculator), `06_Configure.s.sol` only needs to call `addBalanceAdapters(<new>)` for each adapter — there is no `removeBalanceAdapters(<old>)` cutover step.

## 4.6 WBTC + AAVE asset registration on mainnet

PR #35 added WBTC and AAVE entries to `nav-config/assets-and-price-feeds/1.json`. Both `RegisterAssets.s.sol` and the integration harness now derive their symbol list from that file's top-level keys via `ConfigReader.getAssetSymbols(...)` — the old hardcoded `_symbolsForChain()` list in `RegisterAssets.s.sol` was deleted — so WBTC/AAVE are registered (and their wallet legs counted) as soon as they are present in that file. Production has not yet registered them.

Action: `RegisterAssets.s.sol` will emit `registerAsset(WBTC, ...)` and `registerAsset(AAVE, ...)` for the mainnet Phase C Safe TX bundle alongside the existing `registerAsset(EURC, ...)` call (and the `registerAsset(ETHx, ...)` call that points ETHx at its freshly deployed custom feed).

---

## 5. Deployment sequence (post-PR-#35-merge)

### Phase A — Code deploys (deployer EOA `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72`)

> **NAV v2 from-scratch:** every `deployments/<chainId>.json` starts empty (`{}`) — no `balanceAdapters`/`customPriceFeeds`/`bridgeAdapters` addresses, no core impl/proxy addresses. Phase A is the full sequence — core impls (`01`), proxies (`02`), price feeds (`03`), balance adapters (`04`), bridge adapters (`05`) — not just the adapter step. The snippet below shows the adapter/feed legs; run `01`/`02` (impls + proxies, per the workflow in `DEPLOYMENT_SUMMARY.md`) and `05` (bridge adapters) first. NAVCalculator impl/proxy, BridgeEscrow impl/proxy and the UUPS placeholder are all redeployed (TBD) here.

```bash
git checkout main && git pull
. ./.env

# Per-chain adapter deploys (existing 04 script iterates _deployIfEnabled).
# Each broadcast writes the new address back to deployments/<chainId>.json.
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $MAINNET_URL --account $DEPLOYER_NAME --broadcast --verify

forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $OP_URL --account $DEPLOYER_NAME --broadcast --verify

forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $BASE_URL --account $DEPLOYER_NAME --broadcast --verify

forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $ARBITRUM_URL --account $DEPLOYER_NAME --broadcast --verify

# Custom price feeds (per chain). 03's run() deploys every feed with `enabled: true`
# in contracts-deployment-config/custom-price-feeds/<chainId>.json — including ETHx on
# mainnet — and writes each address to deployments/<chainId>.json .customPriceFeeds.
forge script script/deploy/03_DeployPriceFeeds.s.sol \
    --rpc-url $MAINNET_URL --account $DEPLOYER_NAME --broadcast --verify
```

### Phase B — Address write-back PR

After Phase A, every chain's `deployments/<chainId>.json` has new address entries populated under `balanceAdapters.<name>` / `customPriceFeeds.<name>` / `bridgeAdapters.<name>` plus the core impl/proxy addresses (this is the only place addresses are written; broadcast logs are no longer committed). Open a PR with:

- `deployments/1.json` — core proxies/impls + every balance/price/bridge adapter address (the ETHx feed address also lands in `deployments/1.json .customPriceFeeds`, referenced by the ETHx `priceFeeds[]` entry in `nav-config/assets-and-price-feeds/1.json`)
- `deployments/10.json`, `deployments/8453.json`, `deployments/42161.json` — per-chain core + adapter addresses

This PR is config-only; it doesn't change behaviour.

### Phase C — Safe TX bundles (per chain)

After Phase B merges to main:

```bash
# Per chain, generate the asset + price-feed registration calldata.
# RegisterAssets emits registerAsset(...) for the first feed of each asset and
# addPriceFeed(...) for any additional feeds (ADR 0009).
forge script script/manage/RegisterAssets.s.sol --rpc-url $MAINNET_URL --sig 'run()'
forge script script/manage/RegisterAssets.s.sol --rpc-url $OP_URL --sig 'run()'
forge script script/manage/RegisterAssets.s.sol --rpc-url $BASE_URL --sig 'run()'
forge script script/manage/RegisterAssets.s.sol --rpc-url $ARBITRUM_URL --sig 'run()'
```

Mainnet asset/feed bundle (from `RegisterAssets.s.sol`) includes:
- `registerAsset(EURC, 0x1aBaEA1f…, Chainlink, 86400)` — register EURC token
- `registerAsset(WBTC, …, Chainlink, …)` — new in PR #35 (§4.6)
- `registerAsset(AAVE, …, Chainlink, …)` — new in PR #35 (§4.6)
- `registerAsset(ETHx, <ethxAdapter>, Custom, 3600)` — register ETHx against its freshly-deployed custom feed (resolved by `feed` name from `deployments/1.json .customPriceFeeds.ETHx`; heartbeat 3600 per `nav-config/assets-and-price-feeds/1.json`)

Balance-adapter registration is a separate step run by `06_Configure.s.sol`, which calls `addBalanceAdapters(<adapter>)` for **every** plain adapter and `addMetaBalanceAdapter(...)` + `addMetaInstances`/`removeMetaInstances` for **every** meta adapter in the mainnet config (not just the original-gap set) — the NAV v2 proxy starts with no adapters registered, so all are added fresh. No `removeBalanceAdapters(<old>)` calls are needed (nothing was previously registered).

Other chains: `06_Configure.s.sol` registers each chain's full adapter set the same way.

Owners on the per-chain Safe (`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` on every chain) sign and execute.

### Phase D — Verification

```bash
# Sanity-check on-chain state per chain
NAV_PROXY=TBD  # set to the redeployed NAV proxy address (CREATE2)

cast call $NAV_PROXY "isAssetRegistered(address)(bool)" 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c \
    --rpc-url $MAINNET_URL  # EURC

cast call $NAV_PROXY "latestPrice(address)(int256,uint8,bool)" \
    0xA35b1B31Ce002FBF2058D22F30f95D405200A15b --rpc-url $MAINNET_URL  # ETHx (external token addr)

cast call $NAV_PROXY "getAllAdapters()(address[])" --rpc-url $MAINNET_URL | wc -w
# Should equal (enabled plain + enabled meta adapters from the mainnet deploy config, i.e. the
# §6 count) PLUS 1 for ERC20Default. ERC20Default is NOT a config entry — it is auto-deployed and
# auto-registered in NAVCalculator.initialize() during 02 (not by 04), so it is not part of the
# §6 audit total. Everything else is registered from scratch on the new proxy.

# Re-run integration snapshot — production state should now match the harness
. ./.env
script/test/refresh-integration-snapshot.sh
```

Open a final PR with the regenerated snapshot if drifts are clean.

### Phase E — Catalog gap fill (separate PRs)

These were identified during the audit but aren't blocked on PR #35:

1. **kpk vault catalog expansion**: 8 mainnet vaults + 1 Arbitrum vault still need their config blocks added (§2). Plus rename `MorphoVault_kpkEURC_V1` → `_kpkEURCYield_V2`. Deploy via Phase A pattern.
2. **Markets-per-vault enumeration** (§3): enumerate `withdrawQueue` for each kpk vault, deduplicate market IDs, cross-reference vs existing `MorphoMarket_*` configs, add the gaps.
3. **`AaveV3SafetyModule` naming alignment**: the deploy config (`contracts-deployment-config/balance-adapters/1.json`) keys it as `AaveV3SafetyModule` (no suffix). With the from-scratch redeploy there is no prior production address under any other key — just confirm the single `AaveV3SafetyModule` key is the one deployed.
4. **MorphoMarket redeploys (§4.5)**: redeploy MorphoMarket on 3 chains under the updated protocol name as part of the NAV v2 redeploy. Just `addBalanceAdapters(<new>)` per chain — no `removeBalanceAdapters(<old>)` (nothing previously registered on the fresh proxy).

---

## 6. Audit script

To regenerate this inventory in the future:

```bash
PYTHONUTF8=1 python3 -c "
import json, os
base = 'script/config'
chains = [('1','mainnet'),('10','optimism'),('56','bsc'),('100','gnosis'),('137','polygon'),('8453','base'),('42161','arbitrum')]

def load(path):
    return json.load(open(path)) if os.path.exists(path) else {}

for cid, name in chains:
    feeds = load(f'{base}/contracts-deployment-config/custom-price-feeds/{cid}.json')
    plain = load(f'{base}/contracts-deployment-config/balance-adapters/{cid}.json')
    meta = load(f'{base}/contracts-deployment-config/meta-balance-adapters/{cid}.json')
    dep = load(f'{base}/deployments/{cid}.json')
    dep_feeds = dep.get('customPriceFeeds', {})
    dep_adapters = dep.get('balanceAdapters', {})
    # Pending = enabled in deploy config but no address yet in deployments/<cid>.json.
    pf_pending = sorted(k for k, v in feeds.items() if v.get('enabled') and not dep_feeds.get(k))
    a_pending = sorted(k for k, v in {**plain, **meta}.items() if v.get('enabled') and not dep_adapters.get(k))
    print(f'=== chain {cid} ({name}) ===')
    print(f'  priceFeeds pending: {len(pf_pending)}')
    for k in pf_pending: print(f'    {k}')
    print(f'  balanceAdapters pending: {len(a_pending)}')
    for k in a_pending: print(f'    {k}')
    print()
"
```

---

## 7. Risks / gotchas

1. **Gas budget on mainnet** — the full NAV v2 redeploy is dozens of contract deploys in one broadcast (re-run §6 for the live count), which is high gas. Check current gas prices and the deployer EOA's balance before triggering. Consider splitting into smaller broadcasts if any single tx looks expensive.

2. **Latent deploy-script bug — `03/04` dry-run writes** (per memory `latent_bugs.md` #4, still open as of `48f7f62`). Run without `--broadcast` first (forge simulates by default) to capture intended addresses without burning gas, then verify `deployments/<chainId>.json` didn't get polluted before the real broadcast. If the dry-run wrote to JSON, revert and broadcast cleanly.

3. **Etherscan/blockscan verify** — `--verify` can fail per-adapter on transient API issues. Have `forge verify-contract <address> <contract> --chain <id>` ready as a backup; the deploy proceeds even if individual verifications fail.

4. **Adapter addresses are NOT deterministic** — balance adapters are deployed with plain `new …` (CREATE) by `04_DeployBalanceAdapters.s.sol`, broadcast from the deployer EOA, so each address is chain- and run-specific (it depends on the deployer's nonce, not a CREATE2 salt). Do **not** expect cross-chain identical adapters to share an address. The CREATE2 canonical-deployer path is used only for the impl/proxy layer (`01`/`02`), not for adapters; the per-protocol factory pattern (ADR 0001) that would make adapter addresses deterministic is designed but not yet shipped. Always read the deployed address from `deployments/<chainId>.json .balanceAdapters.<name>`.

5. **Mode-bit + CRLF** on Windows checkouts (per memory `wsl_git_push.md`) — when committing the Phase B address write-backs, watch for `git diff` showing mode bit flips on shell scripts that aren't yours to commit.

6. **Safe TX bundle ordering** — the ETHx custom feed must exist (Phase A `03`) before `registerAsset(ETHx, <feed>, Custom, 3600)` runs, and that `registerAsset` must land before any consumer queries an ETHx price — avoid intermediate states where ETHx is referenced but its feed is unregistered.

7. **`AaveV3SafetyModule` key** (§5 Phase E #3) — since the NAV v2 redeploy starts from a clean NAVCalculator with no prior Safety Module adapter registered, just deploy under the single `AaveV3SafetyModule` config key and register it once. There is no prior production entry to fragment against.

---

## Maintenance

This document is regenerated at the start of every deploy session. After Phase D verification, archive (rename to `PENDING_DEPLOYS_2026-XX-XX.md`) and start fresh next time.
