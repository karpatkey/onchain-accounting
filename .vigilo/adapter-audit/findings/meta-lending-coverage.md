# Meta-Lending Adapter Coverage Summary

Branch: audit/vigilo-fixes

## Per-Adapter Verdicts

| Adapter | Balance derivation (one line) | Verdict |
|---------|------------------------------|---------|
| **AaveV3InstancesMetaBalanceAdapter** | `dp.getUserReserveData(asset, account)` returns aToken balance (already in underlying units with accrued interest) and debt principal; up to 3 legs per reserve (Collateral/Supplied + variable Borrow + stable Borrow) | **CLEAN** |
| **CompoundV3CometsMetaBalanceAdapter** + CometLib | `principal * currentAccruedIndex / BASE_INDEX_SCALE` for base supply/borrow; raw `collateralBalanceOf` for collateral; reward accrual projected from tracking indices | **CLEAN** (known uint64 truncation → under-report, confirmed low) |
| **ConvexRewardsMetaBalanceAdapter** | `rewarder.balanceOf(account)` LP shares decomposed pro-rata via CurvePoolLib; CRV from `rewarder.earned()`; CVX derived from current-cliff formula; extra rewards from extra-rewarder `earned()` | **CLEAN** (M-7 CVX over-estimate corroborated as accepted upper bound; no new finding) |
| **EulerVaultsMetaBalanceAdapter** | `vault.convertToAssets(vault.balanceOf(account))` for supply; `IEulerEVault.debtOf(account)` for borrow (both try/catch wrapped); EVC collateral check for Collateral vs Supplied classification | **CLEAN** |
| **FluidFTokensMetaBalanceAdapter** | `fToken.convertToAssets(fToken.balanceOf(account))` — standard ERC4626 | **CLEAN** |
| **FluidVaultsMetaBalanceAdapter** + FluidVaultLib | VaultResolver `positionByNftId(nftId)` staticcall decoded via manual assembly; `aggregate()` sums supply/borrow across account's NFTs | **FINDING: M-01** — ABI byte offsets in `_readUserPositionPrefix` are off by 32 bytes (missing the ABI offset pointer word); `isLiquidated` reads `owner`, `supply` reads `beforeDustBorrow`, `borrow` reads actual `supply`; every real NFT (owner ≠ address(0)) is treated as liquidated and silently dropped |
| **GearboxMarketsMetaBalanceAdapter** | `market.convertToAssets(market.balanceOf(account))` — standard ERC4626 | **CLEAN** |
| **MorphoMarketsMetaBalanceAdapter** | `MORPHO.expectedMarketBalances(mp)` (projected, accrued to block.timestamp) for totalSupplyAssets/totalBorrowAssets; share→asset via `mulDiv` (supply: Floor, borrow: Ceil); collateral from `pos.collateral` (raw, no conversion) | **CLEAN** (ADR 0004 projected-vs-stored design accepted) |
| **MorphoVaultsMetaBalanceAdapter** | `vault.convertToAssets(vault.balanceOf(account))` — standard ERC4626 | **CLEAN** |
| **StakeWiseV3VaultsMetaBalanceAdapter** | `vault.convertToAssets(vault.getShares(account))` for Staking; `OS_TOKEN_VAULT_CONTROLLER.convertToAssets(vault.osTokenPositions(account))` for Borrowed (isDebt=true) | **CLEAN** |

## Corroborations / Refutations of Prior Findings

| Prior Finding | Adapter | Verdict |
|--------------|---------|---------|
| M-7: Convex CVX cliff over-report | ConvexRewardsMetaBalanceAdapter | **CORROBORATED** — `_cvxMintAmount` uses live `totalSupply` at read time; since more CVX may be minted between earned and claimed, `remaining` is lower at claim time than at read → reported CVX ≥ actual CVX. Bounded by `amtTillMax`. Accepted as upper-bound estimate per remediation doc. |
| Low: Compound uint64 tracking-accrued overflow drops instance | CompoundV3CometsMetaBalanceAdapter | **CORROBORATED** — `_updateTrackingAccrued` returns `uint64`; `SafeCast.toUint64()` reverts on overflow, propagates to instance drop via try/catch. Direction: under-report. |
| M-4: ERC4626 `convertToAssets` vs `previewRedeem` | FluidFTokens, GearboxMarkets, EulerVaults, MorphoVaults | **CORROBORATED** — all four use `convertToAssets`; `previewRedeem` would account for withdrawal fees. Deferred per remediation doc. |

## New Findings

| ID | Severity | Adapter | Title |
|----|----------|---------|-------|
| M-01 | Medium | FluidVaultsMetaBalanceAdapter / FluidVaultLib | ABI offset wrong — all real Fluid T1 vault positions silently dropped |
