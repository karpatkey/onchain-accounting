# Pending Production Deploys — post-PR-#35

Operational checklist for the deploy + Safe TX work that follows PR #35's merge. Everything below is wired in code (harness deploys ephemerally on the fork; production deploy not yet run).

**Source of truth for state**: every adapter and price feed entry in `script/config/chains/<chainId>.json`. An empty `deployed: ""` field means "wired but not yet on mainnet". This document is regenerated from that state — when in doubt, re-run the audit script in §6.

**Companion docs:** [`NAV_V2_DEPLOYMENT_RUNBOOK.md`](NAV_V2_DEPLOYMENT_RUNBOOK.md) (operational playbook), [`DEPLOYED_ADDRESSES.md`](DEPLOYED_ADDRESSES.md) (current production state), [`config/CONFIG_GUIDE.md`](config/CONFIG_GUIDE.md) (chain config schema).

> **Addendum 2026-05-30 (not yet in the dated tables below — re-run §6 to regenerate):**
> - **`KelpWithdrawalQueue`** (Mainnet, PR #44 merged) and **`LidoWithdrawalQueue`** (Mainnet, PR #45) are wired with `deployed: ""` — pending `04_DeployBalanceAdapters` + `addBalanceOracle` registration (both are already in the `_balanceAdapterNames()` lists in `06_Configure.s.sol` / `06_Configure.s.sol`). They bump the Mainnet pending balance-adapter count accordingly.
> - **Pending NAVCalculator implementation upgrade:** PR #44 changed `NAVCalculator.hasPositions` (fail-open via the positions path). Shipping it requires deploying a new NAVCalculator implementation and a UUPS upgrade (`UpgradeNAVCalculator.s.sol` + Safe TX) — a new pending item beyond the adapter deploys.

---

## 1. Inventory — what's pending across all chains

Audit run 2026-05-11 against branch `feat/integration-test-add-accounts-616-4f20` (PR #35, tip `42e436c`).

| Chain | Pending price feeds | Pending balance adapters | Total |
|---|---:|---:|---:|
| Mainnet (1) | 1 | 25 | **26** |
| Optimism (10) | 0 | 3 | 3 |
| Gnosis (100) | 0 | 0 | **0 ✓** |
| Base (8453) | 0 | 9 | 9 |
| Arbitrum (42161) | 0 | 9 | 9 |
| **Total** | **1** | **46** | **47** |

### 1.1 Pending price feeds

| Chain | Adapter key | Contract | Constructor params (in `assets.json.priceFeeds.<key>.<chainId>.constructor`) |
|---|---|---|---|
| 1 | `ETHx` | `src/prices/protocols/ETHx_Price.sol` (`ETHx_PriceOracle`) | `ethx`, `stakePoolsManager`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |

### 1.2 Pending balance adapters — Mainnet (chain 1)

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

**Aave family (3)**

| Key | Notes |
|---|---|
| `AaveV3SafetyModule` | stkGHO. ⚠ different from the existing production-deployed `AaveV3SafetyModule_stkGHO` recorded in DEPLOYED_ADDRESSES.md — verify whether this entry is a redeploy under the renamed key or an additional one before broadcasting. |
| `AaveUmbrella` | Aave V4 Umbrella stake tokens (stkwaEthUSDC.v1, stkwaEthUSDT.v1, stkwaEthWETH.v1, stkGHO.v1). Discovers available stake tokens dynamically via `RewardsController.getAllAssets()`. |
| `AaveV2_Mainnet` | aTokens only — V2 lending. `aave2` is now in `supportedDeBankProtocols` for chain 1 (DeBank reports stkAAVE under `aave2`); the comparison-report's `aave2` matcher pairs against both V2 lending and the Safety Module. Canonical `positionId` source: Pool address (not dataProvider). |

**StakeWise V3 (3)**

| Key | Notes |
|---|---|
| `priceFeeds.osETH` (Mainnet), `priceFeeds.osGNO` (Gnosis) | osETH/osGNO are Custom-priced ERC20s via `osToken_PriceOracle` (deploy with `03_DeployPriceFeeds`, register with `RegisterAssets`) |
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
| `ERC4626Wrap_waEthLidoGHO` | Aave V3 Prime stata-token wrap (`0xC71Ea051…`). Generic `ERC4626WrapBalanceOracle`. Underlying = GHO (must be registered first). Covers ACCOUNT_11's ~$233 wallet position previously invisible to `AaveV3_Prime.getUserReserveData`. |

### 1.3 Pending balance adapters — L2 chains

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

**Gnosis (chain 100) — fully deployed ✓**

---

## 2. kpk Morpho Vault catalog cross-check

The user's authoritative kpk Morpho vault list (from the kpk catalog) cross-referenced against our current chain config. **All addresses verified against on-chain `symbol()` + `name()` calls.**

### 2.1 Mainnet (chain 1)

| # | Vault address | On-chain symbol | On-chain name | Asset | In our config? | Action |
|---|---|---|---|---|---|---|
| 1 | `0xe108fbc0…7A993aDd` | `kpk_USDC_Prime` | kpk USDC Prime | USDC | ✅ `MorphoVault_kpkUSDCPrime_V1` (deployed) | none |
| 2 | `0xd4e95092…896563b5` | `kpkUSDT` | USDT Yield | USDT | ❌ missing | **add config + deploy** |
| 3 | `0x0c6aec60…b398DC1` | `kpk_EURC_Yield` | kpk EURC Yield | EURC | ❌ missing | **add config + deploy** (note: needs EURC asset registered first — already in PR #35 via `9d3b7aa`) |
| 4 | `0xd564F765…5e8e7C8` | `kpk_ETH_Prime` | kpk ETH Prime | WETH | ✅ `MorphoVault_kpkETHPrime_V1` (deployed) | none |
| 5 | `0xc88eFFD6…E982A` | `kpk_ETH_Yield` | kpk ETH Yield | WETH | ❌ missing | **add config + deploy** |
| 6 | `0x9178eBE0…cc3509` | `kpk_USDC_Yield` | kpk USDC Yield | USDC | ❌ missing | **add config + deploy** |
| 7 | `0xdaD4e51d…712065` | `kpk_USDT_Prime` | kpk USDT Prime | USDT | ❌ missing | **add config + deploy** |
| 8 | `0x4Ef53d2c…962C9ee6` | `kpk_USDC_PrimeV2` | kpk USDC Prime V2 | USDC | ✅ `MorphoVault_kpkUSDCPrime_V2` (deployed) | none |
| 9 | `0xa877d5bb…1a275f` | `kpk_EURC_YieldV2` | kpk EURC Yield V2 | EURC | ⚠ `MorphoVault_kpkEURC_V1` (PR #35, **misnamed** — should be `_kpkEURCYield_V2`) | **rename + deploy** |
| 10 | `0xBb50A534…E65FF9` | `kpk_ETH_PrimeV2` | kpk ETH Prime V2 | WETH | ✅ `MorphoVault_kpkETHPrime_V2` (deployed) | none |
| 11 | `0xD5cCe260…AaeaA13` | `kpk_USDC_YieldV2` | kpk USDC Yield V2 | USDC | ❌ missing | **add config + deploy** |
| 12 | `0x5dbf760b…D77725` | `kpk_ETH_YieldV2` | kpk ETH Yield V2 | WETH | ❌ missing | **add config + deploy** |
| 13 | `0x65D217B4…43A8e1E` | `discarded` | discarded | USDT | ❌ missing | **DO NOT DEPLOY** — kpk team retired this vault on-chain (symbol/name set to literal "discarded"). The current USDT Prime V2 is #14 below. |
| 14 | `0x870F0BF2…F2C8A8` | `kpk_USDT_PrimeV2` | kpk USDT Prime V2 | USDT | ❌ missing | **add config + deploy** (this is the live V2 USDT Prime, replacing #13) |

**Net mainnet kpk-vault gap**: 8 vaults need to be added to `chains/1.json.balanceAdapters` and deployed (#2, #3, #5, #6, #7, #11, #12, #14). Plus rename #9.

### 2.2 Arbitrum (chain 42161)

| # | Vault address | On-chain symbol | On-chain name | Asset | In our config? | Action |
|---|---|---|---|---|---|---|
| 15 | `0x2C609d9C…9Ec53579d` | `kpk_USDC_Yield` | kpk USDC Yield | USDC.e (Arb native USDC) | ✅ `MorphoVault_kpkUSDCYieldV1` (deployed) | none |
| 16 | `0x5837e418…FF5e73` | `kpk_USDC_YieldV2` | kpk USDC Yield | USDC.e | ❌ missing | **add config + deploy** |

**Net Arbitrum kpk-vault gap**: 1 vault needs to be added (#16).

---

## 3. Morpho Markets per kpk Vault — TODO

The user requested the catalog to also include the underlying Morpho markets each kpk vault supplies into. Enumerating these on-chain requires `MetaMorpho.withdrawQueueLength()` + `withdrawQueue(uint256)` per vault, then `MorphoBlue.idToMarketParams(Id)` per market — multiple round-trips per vault. The audit script attempted this but the function selector was incorrect; markets-per-vault enumeration is **deferred**.

### 3.1 What we already have

Our current `chains/1.json.balanceAdapters.MorphoMarket_*` covers 12 markets (all deployed at the time of PR #15):

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

**Estimated effort**: 30 min cast scripting + small PR adding the resulting market configs to `chains/1.json`. The Vault adapter handles vault-mediated NAV, so adding the per-market adapters is for completeness (any account that supplies directly into one of these markets without going through a kpk vault).

---

## 4. Gearbox markets cross-check

| # | Address | On-chain symbol | On-chain name | In our config? |
|---|---|---|---|---|
| 1 | `0x9396DCbf…699571EF` | `kpkWETH` | WETH Market | ✅ `GearboxMarket_kpkWETH` (deployed) |
| 2 | `0xA9d17f6D…2e0AABa64` | `kpkwstETH` | wstETH v3 | ✅ `GearboxMarket_kpkwstETH` (deployed) |

**Both already deployed.** No action needed.

---

## 4.5 MorphoMarket — protocol name rewrite

PR #35 changed the protocol display name from `"Morpho Blue - <pair>"` → `"Morpho - <pair>"` (CLAUDE.md naming convention; `feedback_morpho_naming` memory). The currently-deployed mainnet/Base/Arbitrum `MorphoMarket_*` adapters predate this change, so their bytecode AND CREATE2 address differ from any fresh deploy.

Action: **redeploy** every `MorphoMarket_*` adapter and update `chains/<id>.json.balanceAdapters.<key>.deployed`.

**Affected adapters:** 12 on mainnet, 2 on Base, 1 on Arbitrum (per `chains/<id>.json` entries). Use the standard `04_DeployBalanceAdapters.s.sol` flow — but **first wipe the existing `deployed` fields** so the script doesn't think they're already up. Pre-redeploy step:

```bash
# Mainnet
python3 -c "
import json
c = json.load(open('script/config/chains/1.json'))
for k, v in c['balanceAdapters'].items():
    if k.startswith('MorphoMarket_'):
        v['deployed'] = ''
json.dump(c, open('script/config/chains/1.json','w'), indent=2)
"
# Repeat for chains/8453.json and chains/42161.json.
```

Then run Phase A's `04_DeployBalanceAdapters.s.sol` per chain. The Safe TX bundle from `06_Configure.s.sol` will need to call `addBalanceOracle(<new>)` AND `removeBalanceOracle(<old>)` for each affected adapter — old + new addresses both kept in chain config until cutover.

## 4.6 WBTC + AAVE asset registration on mainnet

PR #35 added WBTC and AAVE to `script/manage/RegisterAssets.s.sol` (indices 29 and 30). They are also added to integration test `_symbolsForChain` (indices 31/32) — so the integration harness counts their wallet legs. Production has not yet registered them.

Action: include `registerAsset(WBTC, ...)` and `registerAsset(AAVE, ...)` in the mainnet Phase C Safe TX bundle alongside the existing `registerAsset(EURC, ...)` and `setPriceFeed(ETHx, ...)` calls.


---

## 5. Deployment sequence (post-PR-#35-merge)

### Phase A — Code deploys (deployer EOA `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72`)

```bash
git checkout main && git pull
. ./.env

# Per-chain adapter deploys (existing 04 script iterates _deployIfEnabled).
# Each broadcast writes the new address back to chains/<id>.json.balanceAdapters.<key>.deployed.
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $MAINNET_URL --account $DEPLOYER_NAME --broadcast --verify

forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $OP_URL --account $DEPLOYER_NAME --broadcast --verify

forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $BASE_URL --account $DEPLOYER_NAME --broadcast --verify

forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url $ARBITRUM_URL --account $DEPLOYER_NAME --broadcast --verify

# ETHx custom price feed (mainnet only).
forge script script/deploy/03_DeployPriceFeeds.s.sol \
    --rpc-url $MAINNET_URL --account $DEPLOYER_NAME --broadcast --verify \
    --sig 'deployFeed(string)' "ETHx"
```

### Phase B — Address write-back PR

After Phase A, every chain's JSON has new `deployed:` fields populated. Open a PR with:

- `chains/1.json` — 24 adapter addresses + ETHx feed address (the latter also copies into `assets.json.tokens.1.ETHx.pricefeed`)
- `chains/10.json`, `chains/8453.json`, `chains/42161.json` — per-chain adapter addresses

This PR is config-only, doesn't change behaviour.

### Phase C — Safe TX bundles (per chain)

After Phase B merges to main:

```bash
# Per chain, generate the calldata for register/setPriceFeed/addBalanceOracle calls.
forge script script/manage/RegisterAssets.s.sol --rpc-url $MAINNET_URL --sig 'run()'
forge script script/manage/RegisterAssets.s.sol --rpc-url $OP_URL --sig 'run()'
forge script script/manage/RegisterAssets.s.sol --rpc-url $BASE_URL --sig 'run()'
forge script script/manage/RegisterAssets.s.sol --rpc-url $ARBITRUM_URL --sig 'run()'
```

Mainnet bundle includes:
- `registerAsset(EURC, 0x1aBaEA1f…, Chainlink, 86400)` — register EURC token
- `registerAsset(WBTC, …, Chainlink, …)` — new in PR #35 (§4.6)
- `registerAsset(AAVE, …, Chainlink, …)` — new in PR #35 (§4.6)
- `setPriceFeed(ETHx, <ethxOracle>, Custom, 0)` — point ETHx at the freshly-deployed feed
- `addBalanceOracle(<adapter>)` × 25 — register every new balance adapter (24 from earlier scope + 1 ERC4626Wrap_waEthLidoGHO landed in PR #35)
- (if §4.5 migration bundled here) `addBalanceOracle(<new>) + removeBalanceOracle(<old>)` per redeployed MorphoMarket entry

Other chains: `addBalanceOracle(...)` × 3 (op), 9 (base), 9 (arb).

Owners on the per-chain Safe (`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` on every chain) sign and execute.

### Phase D — Verification

```bash
# Sanity-check on-chain state per chain
NAV_PROXY=0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19  # same on every chain (CREATE2)

cast call $NAV_PROXY "isAssetRegistered(address)(bool)" 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c \
    --rpc-url $MAINNET_URL  # EURC

cast call $NAV_PROXY "latestPrice(address)(int256,uint8,bool)" \
    0xA35b1B31Ce002FBF2058D22F30f95D405200A15b --rpc-url $MAINNET_URL  # ETHx

cast call $NAV_PROXY "getAllOracles()(address[])" --rpc-url $MAINNET_URL | wc -w
# Should equal: prior count + 24 + 1 (ERC20Default exists already)

# Re-run integration snapshot — production state should now match the harness
. ./.env
script/test/refresh-integration-snapshot.sh
```

Open a final PR with the regenerated snapshot if drifts are clean.

### Phase E — Catalog gap fill (separate PRs)

These were identified during the audit but aren't blocked on PR #35:

1. **kpk vault catalog expansion**: 8 mainnet vaults + 1 Arbitrum vault still need their config blocks added (§2). Plus rename `MorphoVault_kpkEURC_V1` → `_kpkEURCYield_V2`. Deploy via Phase A pattern.
2. **Markets-per-vault enumeration** (§3): enumerate `withdrawQueue` for each kpk vault, deduplicate market IDs, cross-reference vs existing `MorphoMarket_*` configs, add the gaps.
3. **`AaveV3SafetyModule` naming alignment**: chain config has `AaveV3SafetyModule` (no suffix), DEPLOYED_ADDRESSES.md mentions `AaveV3SafetyModule_stkGHO`. Reconcile before broadcasting (avoid double-deploy or accidental rename).
4. **MorphoMarket redeploys (§4.5)**: redeploy MorphoMarket on 3 chains under the updated protocol name. Bundle the `addBalanceOracle(new) + removeBalanceOracle(old)` per chain.

---

## 6. Audit script

To regenerate this inventory in the future:

```bash
PYTHONUTF8=1 python3 -c "
import json, os
chains = [('1','mainnet'),('10','optimism'),('100','gnosis'),('8453','base'),('42161','arbitrum')]
for cid, name in chains:
    path = f'script/config/chains/{cid}.json'
    if not os.path.exists(path): continue
    c = json.load(open(path))
    feeds = c.get('priceFeeds', {})
    adapters = c.get('balanceAdapters', {})
    pf_pending = sorted(k for k,v in feeds.items() if v.get('enabled', True) and not v.get('deployed'))
    a_pending = sorted(k for k,v in adapters.items() if v.get('enabled') and not v.get('deployed'))
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

1. **Gas budget on mainnet** — 24 deploys in one broadcast is high gas. Check current gas prices and the deployer EOA's balance before triggering. Consider splitting into smaller broadcasts if any single tx looks expensive.

2. **Latent deploy-script bug — `03/04` dry-run writes** (per memory `latent_bugs.md` #4, still open as of `48f7f62`). Run with `--broadcast=false` first to capture intended addresses without burning gas, then verify the chain config didn't get polluted before the real broadcast. If the dry-run wrote to JSON, revert and broadcast cleanly.

3. **Etherscan/blockscan verify** — `--verify` can fail per-adapter on transient API issues. Have `forge verify-contract <address> <contract> --chain <id>` ready as a backup; the deploy proceeds even if individual verifications fail.

4. **CREATE2 determinism** — every same-config adapter on every chain SHOULD land at a deterministic address per the factory pattern. Cross-chain identical adapters (same constructor, same protocol class) get the same address. If Mainnet's `CompoundV3_USDC` and Optimism's `CompoundV3_USDC` deploy to **different** addresses, something's off (different constructor params for chain-specific Comet markets is normal — same address only if the inputs are identical).

5. **Mode-bit + CRLF** on Windows checkouts (per memory `wsl_git_push.md`) — when committing the Phase B address write-backs, watch for `git diff` showing mode bit flips on shell scripts that aren't yours to commit.

6. **Safe TX bundle ordering** — `setPriceFeed(ETHx, ...)` must be in the same Safe TX as `registerAsset(EURC, ...)` (or sequenced) — avoid intermediate states where ETHx is registered but mispriced.

7. **`AaveV3SafetyModule` ambiguity** (§5 Phase E #3) — verify the existing production state before deploying the new entry under that name. If `AaveV3SafetyModule_stkGHO` from DEPLOYED_ADDRESSES.md is functionally equivalent and the proxy already references it, deploying a new one under a different config key wastes gas and could fragment Safety Module accounting.

---

## Maintenance

This document is regenerated at the start of every deploy session. After Phase D verification, archive (rename to `PENDING_DEPLOYS_2026-XX-XX.md`) and start fresh next time.
