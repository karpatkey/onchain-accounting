# FundConfig POC

Status: T1–T7 pass on a mainnet fork at block 26,500,000. `FOUNDRY_PROFILE=slow forge test --match-path 'test/poc/fundconfig/**' -vv`: 12 passed, 0 failed (T1–T7 plus 5 profiling tests in `FundConfigGas.fork.t.sol`). Gas figures below come from `-vv` logs of that run and `gas-profile.json`.

## What it is

A per-fund `FundConfig` contract declares which positions a fund holds. From that single declaration it derives two things:

1. **Zodiac Roles v2 permissions.** `FundConfig` owns a Roles v2 clone attached to the fund's Safe. Each declared position contributes permission leaves (target, selector, parameter conditions, execution options). `FundConfig` merges them into Roles `allowFunction` / `scopeFunction` / `scopeTarget` calls.
2. **Fund accounting.** `fundNav(quoteAsset)` sums the declared positions through the existing balance adapters and `NAVCalculator`, plus the Safe's wallet balances of the declared assets.

Nothing else can write to the Roles clone. Its owner is `FundConfig`, and `FundConfig` exposes only the curator-gated position and manager API.

## Contracts (`poc/fundconfig/`)

| File | Role |
|---|---|
| `FundConfig.sol` | Declared positions, Roles sync, manager assignment, `fundNav`. |
| `IPositionModule.sol` | Module interface: `moduleId`, `validate`, `permissions`, `accounting`, `assets`. |
| `ModuleRegistry.sol` | Owner-registered module set, keyed by `moduleId`. |
| `PermissionMerge.sol` | Builds the Or-tree for a shared `(target, selector)` key. |
| `modules/MorphoVaultModule.sol` | Morpho vault: approve USDC to a declared vault, deposit/redeem/withdraw with receiver = Safe. |
| `modules/AaveV3Module.sol` | Aave V3 market: approve pool, supply/withdraw with `onBehalfOf` / `to` = Safe. |
| `modules/EtherFiAssistedModule.sol` | EtherFi withdrawal queue via the assistant, `DelegateCall` only. |
| `vendor/RolesV2.sol` | Minimal Roles v2 types and interfaces, vendored from `gnosisguild/zodiac-modifier-roles@f55d00de507428cd3841975e7d85310c900c7b09`. |

Fork tests: `test/poc/fundconfig/FundConfig.fork.t.sol` (T1–T7). Gas profiling and scaling: `test/poc/fundconfig/FundConfigGas.fork.t.sol`.

## Invariants

- **Closed permission set.** Roles v2 owner is `FundConfig`. No external caller can call Roles owner functions, and `FundConfig` exposes no raw permission passthrough (T7).
- **Declared-only targets.** A Roles target is scoped only while at least one active key targets it. Removing the last key revokes the target (T3, T4).
- **Shared keys merge.** Several positions that share a `(target, selector)` produce one Roles entry with an Or-tree of their conditions. Removing one position removes only its branch (T3).
- **Fail-closed options.** Leaves for one key must share the same `ExecutionOptions`. A mismatch reverts with `OptionsMismatch`.
- **Removal guard.** `removePosition` reverts `PositionNotEmpty` while any balance of the position is non-zero (T4).
- **Assisted completeness.** The EtherFi module permits only the assistant via `DelegateCall`. The direct LiquidityPool entrypoint is not permitted (T5).

## Tests

| Test | Proves |
|---|---|
| T1 | Allowed Morpho deposit and Aave supply through Roles; `fundNav` tracks the funded value within 0.1%. |
| T2 | Undeclared target, undeclared spender, and a receiver other than the Safe all revert. |
| T3 | Shared `approve(USDC)` serves both spenders; removing one leaves the other working. |
| T4 | `removePosition` reverts while value > 0 and succeeds after a full withdrawal. |
| T5 | The manager can delegatecall the assistant; the direct LiquidityPool call reverts. |
| T6 | Two identical funds: the second fund's `addPosition` calls cost less (dedupe). Gas is taken from `vm.lastCallGas()` and logged with `console2`. |
| T7 | Roles owner is `FundConfig`; owner-API calls from a curator or via low-level `call` to `FundConfig` fail; a manager cannot target the Safe. |

## Gas

Measured by `vm.lastCallGas().gasTotalUsed` around each `addPosition` call. Two identical funds (same Safe setup, same two positions: Morpho vault and Aave USDC). Both positions write the shared `approve(USDC)` key, so the second position merges into an existing Or-tree. "Before" is the committed `poc/fundconfig/FundConfig.sol` (HEAD `f57a7c8b`); "after" is the optimized contract. Raw data and commands are in `gas-profile.json`.

| Call | Fund A before | Fund A after | Fund B before | Fund B after |
|---|---|---|---|---|
| `addPosition(morpho vault)` | 879,382 | 556,112 | 816,076 | 492,806 |
| `addPosition(aave USDC)` | 852,462 | 576,570 | 763,568 | 487,676 |
| Total | 1,731,844 | 1,132,682 | 1,579,644 | 980,482 |

The optimization saves 599,162 gas per T6 run in each fund (−34.6% for fund A, −37.9% for fund B). Fund B is 152,200 lower than fund A, both before and after. The control runs in `FundConfigGas.fork.t.sol` split that gap into three parts: dedupe with all shared addresses cold, 132,200; warm access on fund B, 39,700; and an all-cooled first call costing 19,700 more than the normal run. Most of the cross-fund saving is Roles blob reuse. `approve(USDC)` `scopeFunction` costs about 116k on fund A, including a CREATE2 blob deploy (about 40k), and about 65k on fund B, with no deploy.

What changed in `poc/fundconfig/FundConfig.sol`: `permissions()` is computed once per add or remove, not once per leaf. `_keyActive` and `_keysOnTarget` are removed, since the declared leaves determine them. `Declared` drops its module slot and resolves the module through the write-once registry.

Scaling (N positions on one shared key, mock vaults): the marginal cost per added position falls from about 245–255k to about 110–112k for N≥3. Total at N=8 is 2,473,051 before and 1,262,800 after.

## Complex position types

Detail and per-call gas: [complex-positions-debt-swap.md](complex-positions-debt-swap.md) and [complex-positions-lp-gauge.md](complex-positions-lp-gauge.md). The core (`FundConfig`, `IPositionModule`, `PermissionMerge`) was frozen while these were written, so they also test whether the interface holds.

|Type|Expressible fund-agnostically?|What it stressed|Gap found|
|---|---|---|---|
|Aave V3 borrow|Yes: asset `EqualTo`, `onBehalfOf` `EqualToAvatar`|Debt leg (`isDebt`) in `fundNav`; approve merged with the supply module|No health-factor/LTV bound in Roles; removal guard is per asset, so a co-declared supply of the same asset blocks removing the borrow; `removePosition` 1.17M gas, unprofiled|
|Uniswap V3 swap|Yes: `exactInputSingle` tuple, tokens pinned to the declared pool's pair, recipient `EqualToAvatar`|Tuple conditions; every swap output is a declared, accounted token|Single-hop only; slippage bound is only the caller's `amountOutMinimum`|
|Uniswap V3 LP NFT|Yes, with a `Custom` condition: the module itself checks the Safe owns `tokenId` and it belongs to the declared pool|Permission logic living in the shared module; `Custom` ≈9.7k gas|`mint` gas unmeasured|
|Curve pool + gauge|Yes, as two declared positions|Multi-target product under a single-`Accounting` interface|Legacy pools like 3pool report no wallet LP through `CurvePoolsMeta` (latent in `src/`, no legacy pool registered today); see [findings-curve-crv.md](findings-curve-crv.md)|

Interface lessons: a per-leg accounting filter (`Accounting[]` or a leg selector) would fix both the borrow removal guard and the pool+gauge split.

## Deviations from the spec

- **Instance coordinates.** Morpho instance = vault address (asset read from `vault.asset()`). Aave = one module per market, instance = underlying asset as `bytes32`. EtherFi instance = `bytes32(uint160(assistant))`.
- **`accounting(bytes32 instance) -> Accounting`** replaces the spec's `accounting() -> (adapter, isMeta)`, so a module can route per instance.
- **`permissionSet()` returns raw leaves**, not the keys written to Roles.
- **No FundFactory.** Optional in the spec; each fund is deployed directly in the test.
- **`assignManager(address manager, bool member)`** matches the spec and emits `ManagerAssigned` / `ManagerRevoked`.

## Limitations

- **Wallet-token coverage.** `fundNav` counts wallet balances only for tokens returned by `assets()` of declared modules. Tokens received from swaps or transfers that no module declares are not counted.
- **Roles v2 licensing.** The vendored types and the mastercopy are from `zodiac-modifier-roles` (LGPL-3.0). This POC stays on the Roles v2 mastercopy and does not fork it.
- **Per-fund NAV.** `fundNav` is per fund and does not replace the global `NAVCalculator`. It reuses the same adapters and pricing.
- **Integrity merge constraints.** Or-trees must satisfy Roles v2 `Integrity.enforce` (BFS order, non-empty children, empty `compValue` for Or/And/Pass). `PermissionMerge` builds them to satisfy this, but the constraints are real.
- **Safe-owner paths stay outside FundConfig.** Because `FundConfig` owns Roles, no other caller can write Roles permissions. The Safe's owners can still enable another module, set a guard, or disable the Roles module, and none of that goes through `FundConfig`. The CLAUDE.md residual risk is narrowed to that path, not closed; it still needs monitoring outside this repo.
- **Recompute cost.** Each add or remove calls `permissions()` once per declared position. That is O(N) external calls per add and O(N²) across N adds. The merged keys are rewritten in memory, and each touched key is written once. The remaining cost is dominated by Roles `scopeFunction` and FundConfig's storage writes (the storage share is inferred, not measured per SSTORE). `gas-profile.json` shows ~110k per added position at N≥3 with mock vaults.
- **Custom condition cost unmeasured.** Only Matches/EqualTo/EqualToAvatar-style conditions are exercised.

## Ideas to improve

Not implemented; expected effects are reasoning from the code, not measurements.

1. **Batch the price calls in `fundNav` so more positions fit in one transaction.** Today `fundNav` calls `NAV_CALCULATOR.calculateValue` once per position leg and once per wallet token (`_price`, `poc/fundconfig/FundConfig.sol:375`). Each call is an external call that reads the leg's asset feeds and, once per call, the quote asset's feed (`_getQuoteAssetInfo`, `src/prices/PriceFeedLib.sol:1029`). Instead: collect all legs and wallet balances first, sum amounts per asset (credits and debts separately, since `calculateValue` takes positive amounts only), then make two `calculateValue` calls, one for credits and one for debts. Asset price reads then scale with distinct assets instead of legs, and the quote-asset read and call overhead happen twice instead of once per leg. Funds with many positions in few assets (several USDC vaults, Aave supply + borrow of the same reserves) gain the most. This raises the position count that fits under the 16,777,216 per-tx cap ([nav-read-gas.md](nav-read-gas.md): ~137 zero-balance Morpho positions today, far fewer funded Aave ones); re-measure with `FundConfigNavGas.fork.t.sol` after the change.
2. **Resolve each position's module once per call.** `_moduleAt(i)` goes through `REGISTRY.moduleOf` on every pass; read it into memory once at the top of `fundNav`.
3. **Linear wallet-token dedupe.** `_walletTokens` is O(N²) over declared assets; dedupe with a sorted array or a per-call memory bitmap keyed by token index.
4. **Per-position failure isolation.** Call each adapter with a gas stipend and fail open with a health flag, as `NAVCalculator` does, so one reverting position cannot block a subscription that reads `fundNav`.
5. **Per-leg accounting filter.** Let a module return several accounting routes or a leg selector, so a pool + gauge product is one position and an Aave borrow's removal guard checks only the debt leg.
