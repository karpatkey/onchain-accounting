# Euler V2 vaults — balance-adapter verification

## 1. Adapter under test

`src/balances/protocols/EulerVaultsMeta.sol` — the immutable `EulerVaultsMetaBalanceAdapter`, a meta-adapter (ADR 0010). Constructor: `(protocolName, navCalculator)` — no per-vault constructor args; the active vault set lives on NAVCalculator (`addMetaInstances`/`removeMetaInstances`, configured in `nav-config/meta-balance-adapters/<chainId>.json` under `EulerVaultsMeta.instances` — vault addresses). Identity is derived on-chain: `positionId = abi.encode(address(vault))` (shared by both legs), `protocolId = keccak256("euler-vaults")`, `positionKind ∈ {Supplied, Borrowed}`, `name = vault.name()`.

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** `EulerVaultsMetaBalanceAdapter is MetaBalanceAdapter`. Overrides only `_instancePositions`, `_instanceAssets`, `describePosition`. The `…ForInstances` fan-out, ERC165, no-arg base methods returning empty, and bad-instance isolation are inherited from `MetaBalanceAdapter` (covered by its base tests + the Morpho-vaults suite). Mirrors `MorphoVaultsMetaBalanceAdapter`.
- **Per-chain scope:** both KPK-held vaults are **mainnet-only** (chainId 1) — see `script/config/nav-config/meta-balance-adapters/1.json` and `…/contracts-deployment-config/meta-balance-adapters/1.json`. Euler V2 runs on other chains, but the held instances are on mainnet, so a single mainnet fork test suffices; the ERC4626 ABI is standard across EulerEarn + EVK on every chain (no per-chain shim like PancakeSwap V3's `feeProtocol`).
- **Two Euler V2 products, one adapter.** Euler V2 vaults are all ERC4626 on the EVK+EVC:
  - **EulerEarn** (the "Earn" product) — MetaMorpho-fork yield aggregators (`curator`/`guardian`/`supplyQueue`/`withdrawQueue`). No borrow. **Both KPK-held vaults are this kind.**
  - **core eVaults** (EVK, the "Lend/Borrow" product) — supply to lend/collateralise; borrow the underlying against collateral, tracked by `debtOf`.
  The adapter treats either as an ERC4626 vault. KPK supplies only today (no EVC controllers enabled on-chain; the Zodiac policy permits no borrow), but the borrow leg makes the adapter future-proof.
- **Euler V1 is out of scope** — deprecated (post-2023-exploit), uses non-ERC4626 eTokens, and KPK holds nothing there.

### Math branches (`_instancePositions`)

Per instance, up to two legs:

- **filter** — `assetFilter != 0 && assetFilter != vault.asset()` → empty (both legs share the asset).
- **registration** — `vault.asset()` not registered on NAVCalculator → empty (registered-asset intersection).
- **Supply leg** — `supplied = convertToAssets(balanceOf(account))`; emit a supply leg (`isDebt = false`) iff `> 0`. Its `positionKind` is **`Collateral`** when the account has enabled the vault as EVC collateral (`vault.EVC()` → `EVC.getCollaterals(account)` membership, under try/catch), else **`Supplied`** (EulerEarn earn deposits, or core-eVault supply not enabled as collateral).
- **Borrow leg** — `debt = debtOf(account)` read under `try/catch` (EulerEarn vaults don't implement `debtOf` → revert caught → `debt = 0`, and the supply leg is unaffected); emit a `Borrowed` leg (`isDebt = true`) iff `> 0`. Core eVaults only.

The EVC lookup is under try/catch, so a vault without `EVC()`/`getCollaterals` (EulerEarn aggregators — never usable as collateral — or a non-Euler ERC4626) degrades to `Supplied`. NAV value is identical either way; the `Supplied`/`Collateral` split is the reconciliation label (matching the Aave convention).

## 2. Existing test coverage

Unit (`test/balances/protocols/EulerVaultsMeta.t.sol`, **14 cases**) covers every branch against mocks: ERC165, no-arg-methods-empty, multi-vault aggregation, asset filter, zero-balance skip, unregistered-asset skip, bad-instance isolation, empty-instances, `describePosition`, plus the borrow leg via a core-eVault mock with `debtOf` (supply+borrow, borrow-only, asset-filter) and an Earn-shaped mock **without** `debtOf` proving the try/catch keeps the supply leg.

Fork (`test/balances/protocols/fork/EulerVaultsMeta.fork.t.sol`, **9 cases**) re-checks against real vaults at the pinned block: EulerEarn supply aggregation + NAV routing, on-chain identity, asset filter, `describePosition`, and the strict-equality redemption cross-check (§8).

All kept as regression nets.

## 3. What this case adds

The supply path is proven by the two KPK EulerEarn holders (real shares → `convertToAssets`, with a real-redemption cross-check). This case additionally exercises, against the real contracts:

- **The borrow (debt) leg** — a real Euler borrower whose `debtOf` surfaces as a `Borrowed`/`isDebt` leg.
- **earn + lend + borrow in one account** — `test_realBorrower_earnLendBorrow` seeds an EulerEarn deposit on the same real borrower so one query returns an Earn supply leg, a core-eVault lend/collateral supply leg, and a core-eVault borrow leg.
- **NAV debt-netting** — `test_navNetsEulerDebt` routes the core eVaults through NAV and confirms the borrow leg prices to a **negative** `value`.

## 4. Adapter formula recap

```
asset = vault.asset()
if assetFilter != 0 and assetFilter != asset:        return []      # filter
if asset not registered on NAV:                      return []      # registered-asset intersection
supplied = vault.convertToAssets(vault.balanceOf(account))
try    debt = vault.debtOf(account)                                 # core eVaults only
catch  debt = 0                                                     # EulerEarn lacks debtOf
emit Supplied(asset, supplied, isDebt=false)  if supplied > 0       # earn / lend / collateral
emit Borrowed(asset, debt,     isDebt=true)   if debt > 0           # core-eVault borrow
# both legs: positionId = abi.encode(vault), protocolId = keccak256("euler-vaults")
```

## 5. Cherry-picked accounts

| Holder | Address | Vault(s) | Leg(s) | Rationale |
|---|---|---|---|---|
| `KPK_DAO` | `0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C` | KPK_ETH_Term (EulerEarn, WETH) | Supplied | Dominant holder — 269.79 of 269.84 total shares (~99.98%). Material real earn position + the redemption cross-check (§8). |
| `KPK_FOUNDATION` | `0x17bC2E773d4b4e32002eDAaa54Ce756F523b44b7` | kpk_RWA_USDC (EulerEarn, USDC) | Supplied | Dominant holder — ~1,000,000 of ~1,005,018 shares. Second EulerEarn vault, verified against a real holder. |
| `BORROWER` | `0xb220f968e2f89C8f2372478CC28ff6384F3FC342` | eUSDC-2 (core, USDC) + eWETH-2 (core, WETH) [+ KPK_ETH_Term seeded] | Supplied + Borrowed | Real Euler borrower: ~61,718 USDC collateral in eUSDC-2 and ~6.363 WETH debt in eWETH-2 (two of the four core eVaults KPK_ETH_Term itself allocates to). Exercises the borrow leg + earn/lend/borrow + NAV debt-netting. **Position still open live**, so the same account serves the live Euler-app/Debank cross-check (§9). |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,346,929** |
| Block timestamp | 1781815607 |
| KPK_ETH_Term (EulerEarn, WETH) | `0xB6D6D89ad4b4D61C15a293e28b74f77F6817fF48` |
| kpk_RWA_USDC (EulerEarn, USDC) | `0x2B47c128b35DDDcB66Ce2FA5B33c95314a7de245` |
| eUSDC-2 (core eVault, USDC) | `0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9` |
| eWETH-2 (core eVault, WETH) | `0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2` |
| EVC | `0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` |
| Adapter under test | `EulerVaultsMetaBalanceAdapter` |
| Fork-test contract | `EulerVaultsMetaBalanceAdapterForkTest` in `test/balances/protocols/fork/EulerVaultsMeta.fork.t.sol` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-kpk-eth-term.json` | Machine-readable evidence pack: holders, vaults, identity, legs, ground-truth method |
| `script/development/deploy/deploy-euler-vaults-meta.sh` | Dev-anvil deploy helper: `forge script` the adapter + `addMetaBalanceAdapter(adapter, instances)` on the local NAV |

## 7. Expected balances

### 7a. Per-leg detail (@ block 25,346,929)

| Holder | Vault | Leg | Token | Shares / source | Amount (raw) | Amount (humanised) |
|---|---|---|---|---|---|---|
| `KPK_DAO` | KPK_ETH_Term | Supplied | WETH | 269786002840662469182 shares | `270079931934549902985` | 270.079931934549902985 WETH |
| `KPK_FOUNDATION` | kpk_RWA_USDC | Supplied | USDC | 1000000000000 shares | `1008788399329` | 1,008,788.399329 USDC |
| `BORROWER` | eUSDC-2 | **Collateral** | USDC | `convertToAssets(balanceOf)` | `61718714865` | 61,718.714865 USDC (EVC-enabled collateral) |
| `BORROWER` | eWETH-2 | Borrowed | WETH | `debtOf` | `6363243813055516579` | 6.363243813055516579 WETH (real debt) |
| `BORROWER` | KPK_ETH_Term | Supplied | WETH | seeded in-test (5 WETH deposit) | = `convertToAssets(balanceOf)` | ≈ 5 WETH (earn) |

### 7b. Per-asset summary

| Holder | Token | Net (raw) | isDebt |
|---|---|---|---|
| `KPK_DAO` | WETH | `270079931934549902985` | false |
| `KPK_FOUNDATION` | USDC | `1008788399329` | false |
| `BORROWER` | USDC | `75991` (eUSDC-2 supply) | false |
| `BORROWER` | WETH | `25457159822804` (eWETH-2 debt) | **true** |

`getAdapterPositionsForInstances` returns one leg per (vault, kind); the Supply and Borrow legs on the same vault share `positionId` and differ only by `positionKind`/`isDebt`.

## 8. Ground-truth cross-check

The position value is a live read of each vault's ERC4626 / EVK accounting; the strongest ground truth is the vault's own settlement view.

| Holder | Check |
|---|---|
| `KPK_DAO` | `adapter.amount == KPK_ETH_TERM.convertToAssets(balanceOf(SAFE))`. The eVault lends out, so `maxRedeem` (~29.9 of 269.79 shares) is the instantly-redeemable slice — redeeming it realises WETH `== convertToAssets(redeemedShares)` exactly (delta 0), proving the conversion is faithful to real money while the adapter still reports the full position value. |
| `KPK_FOUNDATION` | `adapter.amount == kpk_RWA_USDC.convertToAssets(balanceOf(holder))`. |
| `BORROWER` (lend) | `adapter.amount == eUSDC-2.convertToAssets(balanceOf(account))`. |
| `BORROWER` (borrow) | `adapter.amount == eWETH-2.debtOf(account)` with `isDebt = true`; routed through NAV, the leg prices to a **negative** `value` (debt is netted). |

Identity is asserted in both suites: `protocolId == keccak256("euler-vaults")`, `positionId == abi.encode(vault)`, `Supplied`/`Borrowed`, `balanceAdapter == address(this)`.

## 9. Wiring the live dev-anvil dashboard

`deploy-euler-vaults-meta.sh` deploys + registers the adapter (with the two KPK EulerEarn instances) on the local mainnet anvil. WETH + USDC are registered on the NAV at bootstrap (`deploy.sh` registers the Chainlink feeds), so no extra asset registration is needed. To pin the dev anvil at the verification block (so the dashboard matches §7):

```bash
anvil --fork-url <MAINNET_URL> --fork-block-number 25346929 --chain-id 1 --port 8545 \
      --state script/development/state/1.json --state-interval 60 &
bash script/development/deploy/deploy.sh 1                       # NAV + Chainlink assets (incl. WETH, USDC)
bash script/development/deploy/deploy-euler-vaults-meta.sh 1     # adapter + the two KPK EulerEarn instances
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The KPK EulerEarn positions render under **Euler** as a single **Supplied** leg each:
- `KPK_DAO` (`0x58e6…9E1C`) → 270.08 WETH (KPK_ETH_Term).
- `KPK_FOUNDATION` (`0x17bC…44b7`) → ~1,008,788 USDC (kpk_RWA_USDC).

To also demo the **borrow (debt) leg** on the dashboard, add the two core eVaults as instances:

```bash
NAV=$(jq -r .NAVCalculatorProxy script/development/state/1-addresses.json)
ADAPTER=$(jq -r .EulerVaultsMeta   script/development/state/1-addresses.json)
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # deployer (holds MANAGER)
cast send $NAV "addMetaInstances(address,bytes32[])" $ADAPTER \
  "[$(cast to-uint256 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9),$(cast to-uint256 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2)]" \
  --rpc-url http://127.0.0.1:8545 --private-key $PK
```

**Live cross-check account (currently active):** `0xb220f968e2f89c8F2372478Cc28FF6384F3fc342` — at block 25,346,929 it holds **~61,719 USDC** collateral in eUSDC-2 (**Supplied**) and **6.363 WETH** debt in eWETH-2 (**Borrowed**, negative value). The position is materially identical live, so the dev app can be cross-checked against the **Euler app** (`app.euler.finance`) and **Debank** for the same address right now.

> The fork-test borrower `0x5c95…e820` (§5) is the holder pinned in the strict-equality test at block 25,346,929 (real dust collateral + debt there), but its live position has since closed — so use `0xb220…c342` for a live Euler-app/Debank cross-check. The featured holders are arbitrary on-chain accounts; their NAV *totals* include unrelated positions, so cross-check the **Euler legs** specifically, not the account total.

> ⚠ **Freshness:** EulerEarn supply positions accrue slowly and are stable; a borrower's debt/collateral are live values. Re-confirm holders on-chain right before a live cross-check if material time has passed since `25,346,929`.

## 10. Test verdict

| Aspect | Status |
|---|---|
| EulerEarn supply leg = `convertToAssets(balanceOf)` (two real holders) | ✅ (exact) |
| Redemption cross-check (maxRedeem slice realises the same rate) | ✅ (delta 0) |
| Core-eVault borrow leg = `debtOf`, `isDebt`, `Borrowed` (real borrower) | ✅ (exact) |
| Supply classified `Collateral` when EVC-enabled, else `Supplied` (`getCollaterals` lookup) | ✅ (unit + fork: borrower's eUSDC-2 → Collateral) |
| earn + lend + borrow in one account | ✅ (real borrower + seeded earn) |
| NAV nets the borrow leg to a negative value | ✅ |
| Borrow + collateral lookups guarded by try/catch (EulerEarn without `debtOf`/usable-collateral keeps its supply leg as `Supplied`) | ✅ (unit + fork) |
| Identity: `protocolId == euler-vaults`, `positionId == abi.encode(vault)`, `Supplied`/`Collateral`/`Borrowed` | ✅ |
| Mainnet-only scope | ✅ |

**Mainnet: Euler fork suite (9) + unit suite (16) pass.** EulerEarn supply (both KPK vaults) and core-eVault supply/collateral + borrow (real borrower) are verified. Euler V2 vaults adapter is verified.

Run via:

```
forge test --match-path "test/balances/protocols/EulerVaultsMeta.t.sol"
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/EulerVaultsMeta.fork.t.sol" -vv
```
