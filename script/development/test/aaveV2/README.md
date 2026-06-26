# Aave V2 — balance-adapter verification

## 1. Adapter under test

`src/balances/protocols/AaveV2InstancesMetaBalanceAdapter.sol` — the immutable `AaveV2InstancesMetaBalanceAdapter` meta-adapter (ADR 0010): one adapter serves every Aave V2 instance, with the active instance set seeded on NAVCalculator at registration via `addMetaBalanceAdapter(adapter, instances)` and adjusted incrementally via `addMetaInstances`/`removeMetaInstances`. Constructor: `(protocolName, navCalculator)`. Identity is derived on-chain (positionId = `abi.encode(LendingPool, reserve)`; label = `<reserve symbol> position (<market id>)`).

### Inheritance + per-chain scope (Phase 0)

- **Inheritance:** `AaveV2InstancesMetaBalanceAdapter is AaveV3InstancesMetaBalanceAdapter`. Aave V2's `AaveProtocolDataProvider` exposes the same `getAllReservesTokens()` / `getUserReserveData()` ABI as V3, so the subclass carries only **three overrides**:
  - `_poolOf(dp)` — resolves the instance pool via the V2 `LendingPoolAddressesProvider.getLendingPool()` instead of V3's `getPool()`. Feeds `positionId = abi.encode(pool, reserve)`. **This is the V2-specific correctness surface for identity.**
  - `_getProtocolId()` — returns `ProtocolIds.AAVE_V2_LENDING` (`keccak256("aave-v2-lending")`) instead of the parent's `aave-v3-lending`.
  - `_marketId(pool)` — resolves the display market id via the V2 `LendingPool.getAddressesProvider().getMarketId()` (V3 uses the pool's `ADDRESSES_PROVIDER()`). Returns "Aave genesis market".
  All other behaviour — reserve enumeration, the aToken/variable-debt math, `Collateral`/`Supplied`/`Borrowed` kind selection, NAV filtering — is the byte-for-byte same code path the Aave V3 instances meta exercises, **verified by inheritance**.
- **Per-chain scope:** Aave V2 (the "genesis market") is configured **only on Ethereum mainnet** — a single instance, ProtocolDataProvider `0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d`, LendingPool `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9`. `script/config/nav-config/meta-balance-adapters/1.json` is the only chain config with `AaveV2InstancesMeta`. No per-chain code branches; a single mainnet fork test is sufficient.
- **Math branches:** per reserve, `getUserReserveData` yields `(aTokenBalance, _, variableDebt, …, usageAsCollateral)`. The adapter emits up to two legs:
  - `aTokenBalance > 0` → `Collateral` if `usageAsCollateral` else `Supplied` (credit, `isDebt = false`).
  - `variableDebt > 0` → `Borrowed` (`isDebt = true`).
  - **Stable debt is intentionally NOT reported** (governance-disabled on Aave V2), matching the per-instance predecessor.

## 2. Existing fork test coverage

`test/balances/protocols/fork/AaveV2InstancesMeta.fork.t.sol` → `AaveV2InstancesMetaParityForkTest` previously had presence/identity smoke tests:
- `test_pureSupplier_hasPositions` / `test_supplyBorrow_hasPositions` — assert a non-zero total for each holder.
- `test_identityDerivedViaLendingPool` — asserts every `positionId` pool equals the LendingPool (the `getLendingPool` override).

All kept as regression nets.

## 3. What this case adds

- **Strict ground truth:** every emitted leg's amount must equal the canonical `aToken`/`variableDebtToken` `balanceOf` — an independent call path from the adapter's `getUserReserveData` (see §8).
- Assertion that `protocolId == aave-v2-lending` (the `_getProtocolId` override).
- Assertion of the correct `PositionKind` per leg (`Collateral` / `Borrowed`) cross-checked against the reserve's `usageAsCollateral` / debt.
- A **multi-leg holder** (stETH collateral + USDC variable debt) exercising `Collateral` + `Borrowed` across two reserves in one account.
- The `describePosition` label `"USDC position (Aave genesis market)"` (the `_marketId` override; see the naming note in §9).

## 4. Adapter formula recap

For each reserve enumerated via `getAllReservesTokens()` and registered on NAV:

```
(aTokenBalance, _stableDebt, variableDebt, ..., usageAsCollateral) = dp.getUserReserveData(reserve, account)
pool = LendingPoolAddressesProvider.getLendingPool()         # V2 override (V3: getPool())
pid  = abi.encode(pool, reserve)

if aTokenBalance > 0:
    kind = usageAsCollateral ? Collateral : Supplied
    emit PositionBalance(reserve, amount=aTokenBalance, isDebt=false, kind, pid)   # credit
if variableDebt > 0:
    emit PositionBalance(reserve, amount=variableDebt, isDebt=true, Borrowed, pid) # debt
# stable debt ignored (governance-disabled on V2)
```

The aToken balance already includes accrued interest (rebasing aToken), so it is the live supplied principal; the variable debt token balance is the live borrowed amount.

## 5. Cherry-picked accounts

| Holder | Address | Rationale |
|---|---|---|
| `PURE_USDC_SUPPLIER` | `0x32e8D4c9d1B711BC958d0Ce8D14b41F77Bb03a64` | Large USDC supply with `usageAsCollateral = true` → exercises the credit branch + `Collateral` kind selection. Single leg. |
| `STETH_SUPPLY_USDC_BORROW` | `0x434Dba149a4A2b9909A7FFeED08491Aed9d5b904` | stETH collateral + USDC **variable debt** (+ a USDC dust collateral leg) → exercises `Collateral` + `Borrowed` across two reserves in one account. |

### Setup

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (chainId 1) |
| Block | **25,281,400** |
| Block timestamp | 1781026523 (`0x6a284edb`) — **2026-06-09 17:35:23 UTC** |
| Instance ProtocolDataProvider | `0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d` |
| LendingPool (positionId pool) | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` |
| Market id (`getMarketId`) | `Aave genesis market` |
| Adapter under test | `AaveV2InstancesMetaBalanceAdapter` |
| Fork-test contract | `AaveV2InstancesMetaParityForkTest` in `test/balances/protocols/fork/AaveV2InstancesMeta.fork.t.sol` |

## 6. Case files in this folder

| File | Purpose |
|---|---|
| `case-supply-borrow-holders-mainnet.json` | Machine-readable evidence pack: holders, per-leg amounts, kinds, ground-truth, naming note |
| `query-live-balances.s.sol` | Forge script that deploys the adapter against a dev NAV and prints the per-leg breakdown — used for ad-hoc cross-checks against a portfolio tracker |
| `script/development/deploy/deploy-aave-instances-meta.sh` | Meta-based dev-anvil deploy helper: deploys + `addMetaBalanceAdapter(adapter, instances)` (atomic register + seed) for the Aave V3 (Core+Lido) and V2 metas (the ADR-0010 equivalent of the removed per-instance helpers) |

## 7. Expected balances

Captured at the fork block in §5. The test does **not** hardcode `EXPECTED_*` constants — it asserts each leg equals the canonical token `balanceOf` (§8); the amounts below are the captured reference (aToken/debt accrue per block).

### 7a. Per-leg detail (every emission the adapter makes)

| Holder | Reserve | Leg | Token | Amount (raw) | Amount (humanised) |
|---|---|---|---|---|---|
| PURE_USDC_SUPPLIER | USDC | Collateral | USDC | `47431086058` | 47,431.086058 USDC |
| STETH_SUPPLY_USDC_BORROW | stETH | Collateral | stETH | `6218252485770961` | 0.006218252485770961 stETH |
| STETH_SUPPLY_USDC_BORROW | USDC | Borrowed | USDC | `7319144` | 7.319144 USDC |
| STETH_SUPPLY_USDC_BORROW | USDC | Collateral | USDC | `1` | 0.000001 USDC (dust) |

### 7b. Per-asset summary (legs aggregated per token)

| Holder | Token | Total credit (raw) | Total debt (raw) | isDebt |
|---|---|---|---|---|
| PURE_USDC_SUPPLIER | USDC | `47431086058` | — | false |
| STETH_SUPPLY_USDC_BORROW | stETH | `6218252485770961` | — | false |
| STETH_SUPPLY_USDC_BORROW | USDC | `1` | `7319144` | credit + debt legs (net debt) |

## 8. Ground-truth cross-check

`test_groundTruth_collateralSupplier` / `test_groundTruth_supplyAndBorrow` / `test_supplyBorrow_exactLegs` assert the adapter's output equals the reserve token's own `balanceOf`:

| Leg | Compared against |
|---|---|
| credit (Collateral/Supplied) | `aToken.balanceOf(holder)` |
| debt (Borrowed) | `variableDebtToken.balanceOf(holder)` |

The aToken / variableDebtToken addresses are resolved via `ProtocolDataProvider.getReserveTokensAddresses(reserve)`. This is a **different call path** from the adapter's `getUserReserveData`, yielding the same canonical value at the same forked block — an in-EVM cross-check with zero derivation drift (same archive state, same EVM). The test also asserts `protocolId == AAVE_V2_LENDING`, the positionId pool == LendingPool, the per-leg `PositionKind`, and the `describePosition` label. **Why no Python here:** Aave's balance is a direct token `balanceOf` (no closed-form re-derivation needed, unlike the Uniswap V2 dilution math) — the canonical token balance is the strongest available ground truth.

## 9. Wiring the live dev-anvil dashboard

`script/development/deploy/deploy-aave-instances-meta.sh` deploys + registers the Aave V3 (Core + Lido) and V2 metas on the local mainnet anvil so the dashboard renders the holders' positions for a side-channel cross-check. Run after the dev anvil is up and the NAV proxy is deployed:

```bash
bash script/development/anvil/start-forks.sh 1
bash script/development/deploy/deploy.sh 1
bash script/development/deploy/deploy-aave-instances-meta.sh 1
bash script/development/app/sync-app-env.sh 1
# then start the Next.js dev server in app/
```

The deployed adapter addresses are recorded in `script/development/state/1-addresses.json`. The dashboard reads each adapter's `IPositionDescribable` layer, so positions render under **Aave V2** / **Aave V3** with the `<symbol> position (<market>)` label. Note: only Chainlink-priced reserves render (USDC, WETH, stETH, …); custom-priced reserves (wstETH, ezETH) are absent unless the custom price feeds are also registered (deferred).

### Naming enhancement (bundled)

`describePosition` now surfaces the market id: `"<reserve symbol> position (<market id>)"`. Aave V2 has a single market ("Aave genesis market"), so there is no Core/Prime distinction here. The multi-market disambiguation matters on **Aave V3**, where Core (`"Aave Ethereum Market"`) and Lido/Prime (`"Aave V3 Lido Ethereum"`) share reserve symbols — demonstrated in the dashboard on holder `0x408ea1bC71ec2562ABCB27520cf7077718403496` (positions in both). On-chain the label is the canonical `getMarketId()`; the "Core Market"/"Prime Market" UI branding is an app-side alias.

## 10. Test verdict

| Aspect | Status |
|---|---|
| Pure supplier: USDC `Collateral` leg == `aUSDC.balanceOf` | ✅ |
| Supply/borrow holder: stETH `Collateral` + USDC `Borrowed` legs == canonical `balanceOf` | ✅ |
| Identity: positionId pool == LendingPool (`getLendingPool` override); protocolId == `aave-v2-lending` | ✅ |
| PositionKind: Collateral (usageAsCollateral) / Borrowed | ✅ |
| Label: `describePosition` == `"USDC position (Aave genesis market)"` (`_marketId` override) | ✅ |
| Stable debt excluded | ✅ (governance-disabled on V2) |

**Mainnet: 8 / 8 fork tests pass.** Single mainnet instance → no cross-chain surface. Aave V2 is verified.

Run via:

```bash
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/AaveV2InstancesMeta.fork.t.sol" -vv
```
