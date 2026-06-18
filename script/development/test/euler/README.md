# Euler V2 eVaults — `EulerVaultsMetaBalanceAdapter` verification

Evidence pack for the strict-equality fork test at
`test/balances/protocols/fork/EulerVaultsMeta.fork.t.sol` (augments, does not replace).

## Phase 0 — pre-test audit

**A. Adapter source (`src/balances/protocols/EulerVaultsMeta.sol`).**
- Class shape: `EulerVaultsMetaBalanceAdapter is MetaBalanceAdapter` (ADR 0010 meta pattern, mirrors
  `MorphoVaultsMetaBalanceAdapter`). Overrides only `_instancePositions`, `_instanceAssets`,
  `describePosition`. Everything else (the `…ForInstances` fan-out, ERC165, no-arg base methods returning
  empty, bad-instance isolation) is inherited from `MetaBalanceAdapter` and transitively covered by that
  base's tests + the Morpho-vaults suite.
- Math branches in `_instancePositions` (each is a test case):
  1. `assetFilter != 0 && assetFilter != asset` → empty array.
  2. asset not registered on NAV → empty array.
  3. `amount == 0` (no shares) → empty array.
  4. otherwise → one `PositionBalance`: `amount = convertToAssets(balanceOf(account))`,
     `isDebt = false`, `protocolId = euler-vaults`, `positionKind = Supplied`,
     `positionId = abi.encode(address(eVault))`.
- **Supply leg only.** Euler V2 EVK eVaults are ERC4626-compliant, so the supplied balance is exactly
  `convertToAssets(balanceOf)` — identical in shape to Morpho vaults. The adapter does NOT model Euler
  borrowing; it is wired only for accounts that supply/earn (deposit/withdraw/redeem), matching the KPK
  Zodiac policy which permits no borrow on Euler. No debt leg ⇒ nothing to net.
- Immutable args: `(protocolName, navCalculator)` via the `MetaBalanceAdapter` constructor.

**B. Chains.** Both kpk-curated eVaults are mainnet-only (chain 1). Euler V2 is also live on other chains,
but the KPK-held instances are on mainnet, so one chain is in scope. ERC4626 ABI is standard EVK across
chains — no per-chain ABI shim (unlike PancakeSwap V3's `feeProtocol`).

**C. Siblings / ADRs / identity.**
- Sibling: `MorphoVaultsMeta` (same base, same ERC4626 convert-to-assets math) — its fork + unit suites are
  the template here.
- ADR 0010 (meta balance adapters) governs the instance-set-on-NAV model.
- Identity: `ProtocolIds.EULER_VAULTS = keccak256("euler-vaults")`; `positionId = abi.encode(address vault)`
  (the `…/ GEARBOX_V3 / EULER_VAULTS / CAP / ERC4626 / …` vault-address group in `ProtocolIds`).

**D. Scope.** Math branches (4) × chains-with-divergence (1) ⇒ one fork case is sufficient, exercising all
four branches plus NAV routing, on-chain identity, and `describePosition`. The unit suite
(`test/balances/protocols/EulerVaultsMeta.t.sol`, 10 cases) covers the branches against mocks; the fork
suite (6 cases) re-checks them against the two real kpk eVaults + a real-redemption cross-check.

## The case — `case-kpk-eth-term.json`

| | |
|---|---|
| Holder | **KPK DAO Safe** `0x58e6c7ab55Aa9012eAccA16d1ED4c15795669E1C` |
| Why | Dominant holder of **KPK_ETH_Term** (`0xB6D6…Ff48`, WETH eVault) — 269.79 of 269.84 total shares (~99.98%). Realistic, material supply position. |
| Chain / block | mainnet (1) @ **25346929** (ts 1781815607) |
| Second instance | **kpk_RWA_USDC** (`0x2B47…e245`, USDC eVault). KPK DAO holds none at the block, so the test deposits 2,000 USDC on its behalf to exercise multi-instance aggregation (mirrors the Morpho-vaults pattern). |

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
