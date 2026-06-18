# Euler V2 vaults — `EulerVaultsMetaBalanceAdapter` verification

Evidence pack for the strict-equality fork test at
`test/balances/protocols/fork/EulerVaultsMeta.fork.t.sol` (augments, does not replace).

## Euler V2 product map (what the adapter covers)

Euler V2 has three products, all ERC4626 on the EVK+EVC:
- **Earn** — EulerEarn aggregator vaults (MetaMorpho fork: `curator`/`guardian`/`supplyQueue`/`withdrawQueue`).
  No borrow. **Both KPK-held vaults are this kind** (KPK_ETH_Term, KPK USDC Prime RWA).
- **Lend** — supplying to a core eVault (EVK Credit Vault). Same supply leg.
- **Borrow** — borrowing the underlying from a core eVault against collateral; tracked by `debtOf(account)`.

The adapter treats any of these as an ERC4626 vault and emits, **per instance**, up to two legs: a **Supply**
leg (`convertToAssets(balanceOf)`, for Earn deposits or Lend/collateral supply) and a **Borrow** leg
(`debtOf`, core eVaults only, read under try/catch since EulerEarn lacks it). KPK only supplies today
(no EVC controllers on-chain; policy permits no borrow), but the borrow leg makes the adapter future-proof.

## Phase 0 — pre-test audit

**A. Adapter source (`src/balances/protocols/EulerVaultsMeta.sol`).**
- Class shape: `EulerVaultsMetaBalanceAdapter is MetaBalanceAdapter` (ADR 0010 meta pattern, mirrors
  `MorphoVaultsMetaBalanceAdapter`). Overrides only `_instancePositions`, `_instanceAssets`,
  `describePosition`. Everything else (the `…ForInstances` fan-out, ERC165, no-arg base methods returning
  empty, bad-instance isolation) is inherited from `MetaBalanceAdapter` and transitively covered by that
  base's tests + the Morpho-vaults suite.
- Math branches in `_instancePositions` (each is a test case):
  1. `assetFilter != 0 && assetFilter != asset` → empty array (both legs share the asset).
  2. asset not registered on NAV → empty array.
  3. supply = `convertToAssets(balanceOf)`; emit a **Supplied** leg iff `> 0` (`isDebt=false`).
  4. debt = `debtOf(account)` under try/catch (EulerEarn reverts → 0); emit a **Borrowed** leg iff `> 0`
     (`isDebt=true`). 0/1/2 legs per instance; both legs share `positionId = abi.encode(address(vault))`
     and `protocolId = euler-vaults`, distinguished by `positionKind`.
- Supply enabled as EVC collateral is reported as **Supplied** (NAV value identical; the Supplied-vs-Collateral
  label is not distinguished — would need an EVC `getCollaterals` lookup).
- Immutable args: `(protocolName, navCalculator)` via the `MetaBalanceAdapter` constructor.

**B. Chains.** Both kpk-held vaults are mainnet-only (chain 1). Euler V2 is also live on other chains, but the
KPK-held instances are on mainnet, so one chain is in scope. ERC4626 ABI is standard across EulerEarn + EVK
on every chain — no per-chain ABI shim (unlike PancakeSwap V3's `feeProtocol`).

**C. Siblings / ADRs / identity.**
- Sibling: `MorphoVaultsMeta` (same base, same ERC4626 convert-to-assets math) — its fork + unit suites are
  the template here.
- ADR 0010 (meta balance adapters) governs the instance-set-on-NAV model.
- Identity: `ProtocolIds.EULER_VAULTS = keccak256("euler-vaults")`; `positionId = abi.encode(address vault)`
  (the `…/ GEARBOX_V3 / EULER_VAULTS / CAP / ERC4626 / …` vault-address group in `ProtocolIds`).

**D. Scope.** Supply + borrow legs × filter/registration/zero branches, on one chain. The unit suite
(`test/balances/protocols/EulerVaultsMeta.t.sol`, **14 cases**) covers every branch against mocks — including a
core-eVault mock with `debtOf` for the supply+borrow and borrow-only legs, and an Earn-shaped mock without
`debtOf` to prove the try/catch keeps the supply leg. The fork suite (**9 cases**) re-checks against real
vaults: the two kpk EulerEarn vaults (supply + redemption cross-check) and a real core-eVault borrower
exercising earn+lend+borrow + NAV debt-netting.

## Case 1 — `case-kpk-eth-term.json` (EulerEarn supply, KPK DAO)

| | |
|---|---|
| Holder | **KPK DAO Safe** `0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C` |
| Why | Dominant holder of **KPK_ETH_Term** (`0xB6D6…Ff48`, WETH eVault) — 269.79 of 269.84 total shares (~99.98%). Realistic, material supply position. |
| Chain / block | mainnet (1) @ **25346929** (ts 1781815607) |
| Second instance | **kpk_RWA_USDC** (`0x2B47…e245`, USDC EulerEarn vault). KPK DAO holds none at the block, so the test deposits 2,000 USDC on its behalf to exercise multi-instance aggregation (mirrors the Morpho-vaults pattern). |

### Strict-equality verification

The eVault lends deposits out, so only `maxRedeem` (≈ 29.9 of 269.79 shares, ~30 WETH) is instantly
redeemable. The adapter correctly reports the **full** position value (`convertToAssets` of all shares — the
NAV value of the position, not the instantly-withdrawable slice). The test verifies both halves with `delta = 0`:

1. `adapter.amount == KPK_ETH_TERM.convertToAssets(balanceOf(SAFE))` — full position value.
2. redeem the `maxRedeem` portion and assert realized WETH `== convertToAssets(redeemedShares)` — proves the
   conversion is faithful to real money, not just a stored number.

| Quantity @ block 25346929 | Value |
|---|---|
| KPK_ETH_Term shares (SAFE) | 269786002840662469182 |
| `convertToAssets(shares)` (WETH) | 270079931934549902985 (≈ 270.0799 WETH) |
| Adapter reported `amount` (WETH) | 270079931934549902985 — **delta 0** |
| `maxRedeem` (shares) | 29916347505082562162 |
| Realized WETH on redeem vs `convertToAssets` | equal — **delta 0** |

## Case 2 — real earn + lend + borrow account (the debt leg)

| | |
|---|---|
| Account | **`0x5c950F946F02F3AcBa1F9e68A3CCDb7DD148e820`** — a real Euler V2 borrower at the fork block |
| Why | Exercises all three Euler shapes in one query, with the **borrow leg** against a real `debtOf`. |
| Legs | **earn**: EulerEarn `KPK_ETH_Term` (WETH) — seeded with a 5 WETH deposit in-test → `Supplied`. **lend**: real USDC collateral in core eVault **eUSDC-2** (`0x797D…48a9`) → `Supplied` (`convertToAssets(balanceOf)`). **borrow**: real WETH debt in core eVault **eWETH-2** (`0xD8b2…84C2`) → `Borrowed`/`isDebt` (`debtOf`). |
| Asserts | each leg strict-equal to its on-chain source; `test_navNetsEulerDebt` registers the core eVaults on NAV and confirms the borrow leg prices to a **negative** `value` (debt is netted). |

> eUSDC-2 / eWETH-2 are two of the four core eVaults that `KPK_ETH_Term` itself allocates to (its
> `withdrawQueue`), so the debt-leg test runs against the same real EVK vaults underpinning the kpk Earn vault.

## Reproduce

```
# fork test (strict equality)
FOUNDRY_PROFILE=slow forge test --match-path "test/balances/protocols/fork/EulerVaultsMeta.fork.t.sol"
# unit test (mocks)
forge test --match-path "test/balances/protocols/EulerVaultsMeta.t.sol"
# dev app at the same block (dashboard cross-check vs Debank + the Euler app):
script/development/anvil/start-forks.sh 1 && script/development/deploy/deploy.sh 1 \
  && script/development/deploy/deploy-euler-vaults-meta.sh 1 \
  && script/development/app/sync-app-env.sh 1
# then open http://localhost:3000 and enter 0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C
```
