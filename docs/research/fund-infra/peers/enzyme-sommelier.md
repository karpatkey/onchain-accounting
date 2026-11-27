# OnchainNavPeers: Enzyme and Sommelier deep-dive

Scope: survey sections 1.1 (Enzyme) and 1.2 (Sommelier) of `docs/research/fund-infra/state-of-art.md`. Read-only. No builds, tests, or measurements were run.

Pinned sources (`gh api`, raw):
- Enzyme `enzymefinance/protocol` @ `7200e4d3cb76603af2e52aca97f15088853af532` (paths below relative to `contracts/release/`)
- Sommelier `PeggyJV/cellar-contracts` @ `64cc7c72419134a4276d51b4200d240db67cf521` (paths relative to `src/`)
- Audit PDFs/pages: ChainSecurity gmx-v2 (Sulu XVIII, 2025-02-06) from the Enzyme repo `audits/`; 0xMacro reports from the Sommelier repo `audits/` and https://0xmacro.com/library/audits/sommelier-16a.html

Legend: `[V]` verified in primary source this session. `[INFERENCE]` my conclusion from code structure. `[UNVERIFIED]` not read from a primary source.

---

## 1. Enzyme

### 1.1 Position declaration
- Positions are two kinds: tracked assets (`VaultLib.trackedAssets`) and active external positions (`VaultLib.activeExternalPositions`). Both are added via `__addTrackedAsset` / `__addExternalPosition`. [V] `core/fund/vault/VaultLib.sol` L456, L468.
- External positions are typed. `ExternalPositionManager.__createExternalPosition` requires a registered parser for the `typeId` (L128). [V] `extensions/external-position-manager/ExternalPositionManager.sol`.
- Per-fund limit: `POSITIONS_LIMIT` is an immutable set in the vault constructor (`VaultLib.sol` L50, L83). `__validatePositionsLimit` requires `trackedAssets.length + activeExternalPositions.length < limit` (L542-546). [V] Production value: not in repo, and the deployment scripts are absent from this tree. [UNVERIFIED]
- Tracked-asset limit and external-position limit share one counter. [V]

### 1.2 NAV computation and timing
- `ComptrollerLib.calcGav()` (L485-511) is `public` and **non-view**. It sums:
  1. `ERC20.balanceOf(vault)` for each tracked asset, valued by `ValueInterpreter.calcCanonicalAssetsTotalValue`.
  2. For each active external position: `getManagedAssets()` valued, minus `getDebtAssets()` valued (`__calcExternalPositionValue`, L524-542). [V]
- Valuation is live, on-chain, and pull-based. No pushed NAV. [V]
- Timing: GAV is computed inside the buy and redeem txs, not at a settlement epoch. Buy path: `calcGav()` at `ComptrollerLib.sol` L628 (`__buyShares`), L272 (`buyBackProtocolFeeShares`), L740. `calcGrossShareValue()` (L516) also calls it. [V]
- Gas per read `[INFERENCE]`, not measured: linear in (tracked assets + external positions). Per tracked asset: one `balanceOf` STATICCALL plus one value-interpreter price call (Chainlink `latestRoundData` via `ChainlinkPriceFeedMixin`). Per external position: `getManagedAssets` + `getDebtAssets` + two valuation calls. Hard ceiling = `POSITIONS_LIMIT` (value unknown). Order of magnitude per position is an estimate only.
- Caps because of gas: none explicit beyond `POSITIONS_LIMIT`. [V]

### 1.3 Revert behavior (the isolation question)
- Price feed: `ChainlinkPriceFeedMixin` `__getLatestRateData` (L167-179) reverts on missing aggregator. `__validateRateIsNotStale` (L183-188) reverts `"__validateRateIsNotStale: Stale rate detected"` when `updatedAt < block.timestamp - STALE_RATE_THRESHOLD`. `__validateAggregator` (L246-248) requires `answer > 0`. [V] No fail-open in the price path.
- Value interpreter: `calcCanonicalAssetsTotalValue` requires supported quote asset (L62). `__calcAssetValue` (L111-131) reverts `"__calcAssetValue: Unsupported _baseAsset"` for unpriced tracked assets. [V]
- `calcGav` has **no try/catch** around per-asset or per-position valuation. A single reverting position or stale feed reverts the whole GAV. [V]
- Consequence, buy path: buy reverts, because `__buyShares` calls `calcGav()` directly. [V] Fail-closed for new money.
- Consequence, redeem path: in-kind redemption wraps `this.calcGav()` in `try/catch` only when auto protocol-fee buyback is enabled (`ComptrollerLib.sol` L806-809, emits `RedeemSharesInKindCalcGavFailed`). [V] So redemption-in-kind survives a GAV failure; the design explicitly protects exit. Note this is conditional on the buyback flag.
- Health flags: none. The `getManagedAssets` return has no health signal. [V]
- Verdict for isolation: no per-position isolation. Reverting position blocks GAV and therefore buys. Exit is protected only in the in-kind path.

### 1.4 Permissions
- Entry point `ExternalPositionManager.receiveCallFromComptroller` requires `IVault(vaultProxy).canManageAssets(_caller)` (L97). [V] This is a fund-level manager role, not per position or per function.
- Per-action validation is inside the external-position library and parser (typed actions; e.g. GMX V2 supports `MarketIncrease`, `MarketDecrease`, `StopLossDecrease`, `LimitDecrease`, `CreateOrder`, `UpdateOrder`, `CancelOrder`, `ClaimFundingFees`, `ClaimCollateral`, `Sweep`). [V] audit §2 (ChainSecurity) L159-198.
- Granularity: per external-position type, per typed action, with argument decoding in the library. [V]
- Tracked-asset side: `DisallowedAdapterIncomingAssetsPolicy` (added in the Sulu extensions, ChainSecurity v2) checks incoming assets after integration calls against disallowed lists. [V] audit §2.2.1 L220-223. Who sets the list and how it binds to positions: [UNVERIFIED].

### 1.5 Link: one declaration, both permission and accounting?
- Partly. Declaration (typed external position, activated into `activeExternalPositions`) is the same object that GAV reads via `getManagedAssets`/`getDebtAssets`. [V] So a manager cannot open an external position of an unregistered type, and that type must implement valuation. [INFERENCE] Hence "cannot open an unvalued external position" holds for external positions.
- Gap: tracked assets are not a permission; an adapter can route any token into the vault, which is tracked on receipt and must then be priced. The incoming-assets policy is the mitigation. Auto-tracking path: [UNVERIFIED] (I did not read the IntegrationManager tracking code).

### 1.6 Debt and multi-leg
- `getDebtAssets()` per external position, valued and subtracted (`ComptrollerLib` L531-541). [V]
- Multi-leg: one external position returns multiple managed assets (e.g. GMX collateral, pending orders, claimable collateral). [V] GMX audit: claimable collateral double-count (6.2, Medium, fixed); execution fee hidden value (6.1, High, fixed); claimable-collateral `claimableCollateralKeys` duplicate push. [V]
- Readability: `getManagedAssets()` returns `(address[] assets, uint256[] amounts)` per position (ComptrollerLib L528). No leg kind, no protocol identity schema. [V] Per-position boundary exists; per-leg kind does not.

### 1.7 Governance and deployment
- Governance: fully trusted per ChainSecurity trust model (§2.2.2, L225-232). [V]
- Immutability: `POSITIONS_LIMIT` immutable per vault (`VaultLib.sol` L50). Position type registry (`updateExternalPositionTypesInfo`, `ExternalPositionManager.sol` L263) is governance-controlled. [V] Chainlink stale threshold set at feed construction (`ChainlinkPriceFeedMixin` constructor L40). [V]
- Per-fund deployment: vault/comptroller proxies deployed per fund via FundDeployer; the production FundDeployer wiring is outside this tree. [UNVERIFIED]

### 1.8 Incidents and audits
- ChainSecurity, Sulu Extensions XVIII, 2025-02-06 (Enzyme `audits/`). [V]
  - 6.1 ExecutionFee of Orders in `getManagedAssets` (High, Correctness): pending order execution fees excluded from valuation, so a fund could be temporarily undervalued and share purchases exploited. Fixed (code corrected). [V]
  - 6.2 Overestimation of claimable collateral (Medium): duplicate keys double-count. Fixed. [V]
  - 6.3 Callback stored per market not per router (Low). Fixed. [V]
  - Scope: GMX V2 external position plus `DisallowedAdapterIncomingAssetsPolicy`. [V]
- Other Enzyme audits listed in `audits/` (2024-08 wstETH feed, 2024-09 yneth/stader, 2025-02 price-feed-utils, 2025-03 single-asset-deposit-queue, 2025-04 myso-v3, 2025-05 stakewise-v3, 2025-08 gmx-v2-2-update): listed only. Not read. [UNVERIFIED]
- No known incident of NAV manipulation in production read this session. [UNVERIFIED]

---

## 2. Sommelier (Cellar)

### 2.1 Position declaration
- Positions are added by the strategist via `Cellar.addPosition` (`base/Cellar.sol`), which calls `registry.addPositionToCellar`. [V]
- Registry gate: `Registry.trustPosition` (L416, onlyOwner) hashes `(identifier, isDebt, adaptorData)` for uniqueness, checks `isAdaptorTrusted`, and requires `priceRouter.isSupported` for every `assetsUsed` (`Registry__PositionPricingNotSetUp`). [V] `addPositionToCellar` (L472, view) reverts if the position is untrusted. [V]
- Per-cellar limit: `MAX_POSITIONS = 32` (`Cellar.sol` L269), enforced separately on the credit array and the debt array (`Cellar__PositionArrayFull`). [V] Max ~64 positions total per cellar. [INFERENCE]
- Mismatch check: `addPosition` reverts when `isDebt != inDebtArray`. [V]

### 2.2 NAV computation and timing
- `totalAssets()` (`_calculateTotalAssetsOrTotalAssetsWithdrawable`, `Cellar.sol` L~983-1020) loops the credit and debt arrays, calls each position's `_balanceOf` / `_assetOf` through the adaptor, then `priceRouter.getValues` / `getValuesDelta`. [V] Live, on-chain, pull-based.
- Timing: computed in deposit/withdraw txs. `callOnAdaptor` snapshots `totalAssets` before and checks it after (see 2.5). [V]
- Gas per read `[INFERENCE]`, not measured: linear in positions (max 64). Per position: adaptor `balanceOf` (delegatecall into adaptor, which may call external protocols, e.g. Morpho `supplyShares`/`collateral`/`borrowShares` STATICCALLs, Uniswap V3 `positions`) plus pricing lookups. Heavier adaptors (Uniswap V3 LP, Curve, Balancer) cost more than plain ERC20 balance.
- Gas caps: `MAX_POSITIONS` only. [V]

### 2.3 Revert behavior
- No fail-open. `totalAssets` propagates any revert from `_balanceOf`, `_assetOf`, or `priceRouter.getValues`. [V] The code comment admits it does not satisfy ERC4626 "must not revert" (`Cellar.sol` ~L1035). [V]
- `PriceRouter._getValues` (`modules/price-router/PriceRouter.sol` L579-615) reverts `PriceRouter__UnsupportedAsset` for unpriced assets; skips zero amounts. [V] `_checkPriceFeed` (L744-758) reverts `AssetBelowMinPrice`, `AssetAboveMaxPrice`, `StalePrice` (heartbeat). [V]
- `totalAssets` reverts `REENTRANCY` when locked, and when paused via `_checkIfPaused`. [V]
- Consequence: one stale or unpriced position halts deposits, withdrawals, and `callOnAdaptor` for the whole cellar. [INFERENCE] Governance can `forcePositionOut` (L~408), which bypasses the balance check but reverts if the position is still trusted. [V]
- Health flags: none. [V]

### 2.4 Permissions
- Strategist (`onlyOwner` in Cellar) calls `callOnAdaptor`. Gated by `_isAuthorized`, `_whenNotShutdown`, `_checkIfPaused`, and sets `blockExternalReceiver = true`. [V] `Cellar.sol` L~1215-1260.
- `_makeAdaptorCalls` (L~1284-1294) checks only `adaptorCatalogue[adaptor]`, then `functionDelegateCall` for each `callData`. [V] Permission is **whole-adaptor**: any function in a trusted adaptor is reachable with any arguments. Granularity = adaptor. [V]
- Adaptor-level argument validation is ad hoc. Example: Macro A-11 M-2 (Fixed): `CollateralFTokenAdaptorV2.removeCollateral` did not verify `_fraxlendPair` was a cellar position; strategist could pass an arbitrary pair. Macro A-16a H-1 (Fixed, Critical impact): `MorphoBlueSupplyAdaptor.deposit` did not call `_validateMBMarket`, so a strategist could deposit into an untracked market. **Pinned source now calls `_validateMBMarket` at `MorphoBlueSupplyAdaptor.sol` L78** [V] (also L108, L182, L197). Fix confirmed in pinned commit.

### 2.5 Post-call accounting check (the nearest thing to "complete")
- `callOnAdaptor` re-checks `totalAssets` within `allowedRebalanceDeviation` (default `0.0003e18`, max `0.1e18`; `Cellar.sol` ~L1230 / ~L1179 per Sommelier response) and requires `totalSupply` unchanged. Errors `Cellar__TotalAssetDeviatedOutsideRange`, `Cellar__TotalSharesMustRemainConstant`. [V]
- Bounds loss per call, not per position. Macro A-4 H-2 (Addressed by design): strategist can swap into an untracked asset within the deviation, and LPs who redeem before detection lose value. Sommelier response: deliberate trade-off; relies on off-chain Steward to block suspect calls and on reduced default deviation. [V] Sommelier argues the design is intentional.

### 2.6 Debt / multi-leg
- Credit and debt arrays are separate. `debtPositions` valued via `_balanceOf` on debt adaptors (e.g. Morpho debt). Debt withdrawable is 0. [V] (`_withdrawableFrom` L~1400-1440)
- Multi-leg: a position is one (adaptor, adaptorData) pair; multi-leg = several positions (Morpho supply + collateral + debt, each separate). [V]
- Staleness on Morpho: `balanceOf` reads stored state without accrued interest (`_userSupplyBalance` `MorphoBlueHelperLogic.sol` L67-70 uses `supplyShares` × `market` totals; comment says call `accrueInterest` first). [V] Macro A-16a M-1 (Acknowledged, Low likelihood): share price can lag interest. Sommelier response: deliberate (gas, fees collection without share price drop, reliance on share-price oracles). [V]
- Readability: `balanceOf` per position via adaptor; no protocol identity schema. Position IDs per registry. [V] Grade 1.

### 2.7 Governance and deployment
- Registry: owner-set trust (`trustPosition` onlyOwner); Sommelier TMAAR: multisig approves adaptors and positions; governance approves strategist actions; Steward can pause; price-router ownership changes have `TRANSITION_PERIOD` timelock. [V] Macro A-16a TMAAR section and `PriceRouter` transition code.
- Adaptors are not upgradeable, but adaptor set is governance-curated (`adaptorCatalogue`). [V]
- Per-cellar deployment: `CellarFactory`-based; per-cellar deployment config not read. [UNVERIFIED]

### 2.8 Incidents and audits (Macro reports)
- **A-4** (2023-01-11, commit `760dc9c...`):
  - H-2: LP loss via strategist swap into untracked asset within deviation. Accepted trade-off (see 2.5). [V]
  - H-4: strategist-controlled `minHealthFactor` could make Aave accounts liquidatable. Fixed. [V]
  - H-5: liquidation sandwich via oracle update. Addressed. [V]
- **A-8** (2023-06-28): M-1 "Strategist can lower Morpho health factors to the liquidation threshold". Status not checked. [UNVERIFIED]
- **A-9** (2023): H-3 "Trusted positions can be forced out"; H-1 governance can set malicious oracle; H-2 unverified automationActions. Status not checked. [UNVERIFIED]
- **A-11** (2023): M-2 "Strategist can execute arbitrary code, potentially extracting value", Fixed. Missing position validation on Fraxlend `removeCollateral`. [V]
- **A-12** (2023): M-1 incorrect CurveEma price; M-2 share price oracles may not be initialized. Status not checked. [UNVERIFIED]
- **A-14** (2023): H-1 strategist steals via slippage; H-2 unverified underlying tokens; H-3 Curve pricing manipulation. Status not checked. [UNVERIFIED]
- **A-16a** (2024-01-22, commit `59e723a...` → final `731165d...`): H-1 untracked Morpho market deposit (Fixed; pinned code now validates). M-1 balances ignore accrued interest (Acknowledged). L-1 `Deposit` event breaks ERC4626 (Fixed). [V] Fetched from 0xmacro.com.
- No NAV-manipulation exploit in production was read this session. [UNVERIFIED]

---

## 3. Grades

Current values from `docs/research/fund-infra/architecture-comparison.json`. Columns: Enzyme (index 2), Sommelier (index 3).

| Dimension | Enzyme current → proposed | Sommelier current → proposed | Basis (sources) |
|---|---|---|---|
| declared | 2 → **2** | 2 → **2** | Enzyme: typed external positions + `POSITIONS_LIMIT` (VaultLib L50, L542-546). Sommelier: registry-trusted positions in 2 arrays capped at 32 (Cellar L269; Registry L416, L472). |
| nav | 2 → **2** | 2 → **2** | On-chain live: `calcGav` (ComptrollerLib L485-511); `totalAssets` (Cellar ~L983-1020). Neither is pushed. |
| granularity | 1 → **1** | 0 → **0** | Enzyme: fund-level `canManageAssets` (EPM L97) + typed actions in lib (ChainSecurity §2). Sommelier: `functionDelegateCall` after `adaptorCatalogue` check only (Cellar ~L1284-1294). |
| single | 1 → **1** | 1 → **1** | Enzyme: external-position type registry = lib (valuation) + parser (moves). Sommelier: same position id for permission and `balanceOf`, but adaptor-level permission. |
| complete | 1 → **2** (flag) | 1 → **1** | Enzyme: external positions must be registered types with `getManagedAssets`; GMX valuation gap 6.1 (High) fixed. Incoming-asset auto-tracking path [UNVERIFIED], mitigated by DisallowedAdapterIncomingAssetsPolicy. Sommelier: deviation band + `balanceOf` only; H-2 accepted trade-off; A-16a H-1 fixed. |
| debt | 2 → **2** | 2 → **2** | Enzyme: `getDebtAssets` (ComptrollerLib L531-541). Sommelier: debt array with `_balanceOf` (Cellar L~1400-1440); stale Morpho interest (A-16a M-1, acknowledged). |
| isolation | null → **0** (flag) | null → **0** (flag) | Enzyme: `calcGav` has no per-position catch; buys revert (ComptrollerLib L628); in-kind redeem survives only via try/catch when buyback enabled (L806-809). Sommelier: `totalAssets` propagates all reverts; no fail-open (Cellar ~L983-1035). |
| trust | 1 → **1** | 1 → **1** | Enzyme: governance fully trusted (ChainSecurity §2.2.2); type registry governance-mutable. Sommelier: multisig + governance + Steward (A-16a TMAAR); `TRANSITION_PERIOD` on price-router ownership. |
| readable | 2 → **1** (flag) | 1 → **1** | Enzyme: `getManagedAssets` returns `(address[], uint256[])` per position with no leg kind or identity schema (ComptrollerLib L528). Sommelier: per-position `balanceOf` with no identity schema. |

### Flagged changes vs current JSON
1. `isolation` Enzyme: null → 0.
2. `isolation` Sommelier: null → 0.
3. `readable` Enzyme: 2 → 1. Per-position boundary exists, but no per-leg kind or protocol identity.
4. `complete` Enzyme: 1 → 2. Only if the incoming-asset auto-track path is confirmed [UNVERIFIED]. Otherwise keep 1. Recommend keeping 1 until verified. **Decision for Main.**

No other cell changes.

---

## 4. Open items (not closed)
- Enzyme production `POSITIONS_LIMIT` value [UNVERIFIED].
- Enzyme IntegrationManager incoming-asset tracking path (determines `complete`).
- Enzyme `DisallowedAdapterIncomingAssetsPolicy` list ownership [UNVERIFIED].
- Enzyme audits not read: 2024-08 wstETH feed, 2024-09 yneth/stader, 2025-02 price-feed-utils, 2025-03 single-asset-deposit-queue, 2025-04 myso-v3, 2025-05 stakewise-v3, 2025-08 gmx-v2-2-update.
- Sommelier A-8, A-9, A-12, A-14 finding status [UNVERIFIED]. A-9 H-3 (forced-out positions) and A-14 H-2 (unverified underlying tokens) are the closest to this survey's permission-mismatch question.
- Gas numbers: none measured. All gas statements are `[INFERENCE]`. A measurement would need a fork harness, which the assignment excludes.
