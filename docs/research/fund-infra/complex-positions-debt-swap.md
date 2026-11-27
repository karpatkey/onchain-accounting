# Complex positions, slice A: Aave V3 borrow and Uniswap V3 swap

Scope: the debt leg of Aave V3 (borrow and repay) and single-hop Uniswap V3 swaps, both as FundConfig modules
on a mainnet fork. Findings are per type: what Roles v2 can express fund-agnostically, what it cannot, the
measured gas, and the gaps that remain. The frozen interfaces (`IPositionModule`, `FundConfig`, `PermissionMerge`,
`vendor/RolesV2.sol`) were not changed.

Verification: `FOUNDRY_PROFILE=slow forge test --match-path test/poc/fundconfig/FundConfigDebtSwap.fork.t.sol -vv`
result: `Suite result: ok. 10 passed; 0 failed; 0 skipped`. Fork block 26,500,000, mainnet.

## Files

- `poc/fundconfig/modules/AaveV3BorrowModule.sol`: one module per Aave market, instance = reserve asset.
- `poc/fundconfig/modules/SwapModule.sol`: one module per router, instance = Uniswap V3 pool.
- `poc/fundconfig/modules/swap/NoPositionAdapter.sol`: balance adapter that reports no positions (a swap holds none).
- `test/poc/fundconfig/FundConfigDebtSwap.fork.t.sol`: the 10 tests below.

## Aave V3 borrow (debt leg)

Permissions, one leaf each, all `ExecutionOptions.Send`:

| Leaf | Conditions | Expressible? |
|---|---|---|
| `approve(asset, pool)` on the asset | spender EqualTo pool, amount Pass | Yes. Merges with the supply module's approve on the same asset. |
| `borrow(asset, amount, rateMode, referral, onBehalfOf)` on the pool | asset EqualTo, amount/rateMode/referral Pass, onBehalfOf EqualToAvatar | Yes, via a 5-argument calldata tree. |
| `repay(asset, amount, rateMode, onBehalfOf)` on the pool | asset EqualTo, amount/rateMode Pass, onBehalfOf EqualToAvatar | Yes. |

Accounting: `AaveV3InstancesMetaBalanceAdapter` with coordinate = data provider and asset filter = the reserve.
It emits one `Borrowed` leg with `isDebt = true`, summing variable and legacy stable debt. `fundNav` subtracts it,
so the debt counts negative against the collateral.

Can express fund-agnostically:
- Borrowing only the declared asset, only into the Safe (`onBehalfOf` EqualToAvatar), and only through the
  declared pool. The Roles v2 tree handles five arguments, one more than `Cond` builds directly.
- Repay under the same constraints.
- NAV tracks debt: the test checks that borrowed cash held by the fund leaves NAV unchanged, and that sweeping the
  cash out lowers NAV by the borrowed amount.

Cannot express, or chose not to:
- `interestRateMode` is Pass. Pinning it to variable (2) is expressible with `EqualTo`, but was left open so that
  legacy stable debt can still be repaid. The adapter values both modes, so NAV holds either way.
- Removal guard granularity. `Accounting.assetFilter` is per asset, not per leg. `removePosition` reverts while
  the asset has any balance on the market, including the supply leg of a co-declared `AaveV3Module` position for
  the same asset. This is conservative and fail-closed. Fixing it needs a per-leg filter in the frozen
  `IPositionModule`.
- Health factor. Roles v2 cannot read Aave's account health, so a borrow that makes the Safe liquidatable is not
  blocked at the permission layer. NAV shows the debt, but nothing prevents the borrow.
- Borrow caps and LTV limits. These are protocol checks, not Roles checks.

## Uniswap V3 swap

Instance encoding: the pool address, not the token. A per-token instance cannot express the constraint
tokenIn × tokenOut × fee: the pair and fee live in the pool, not in the token. The module reads `token0`, `token1`,
and `fee` from the pool and `validate` checks `factory.getPool(t0, t1, fee) == pool`, so a look-alike pool is
rejected at `addPosition`.

Permissions, four leaves for the pool's pair, all `ExecutionOptions.Send`:
- `approve(token0 → router)`, `approve(token1 → router)`, spender EqualTo router.
- `exactInputSingle((tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96))` for
  each direction. Tuple tree: Calldata root, Tuple node, seven field children. `tokenIn`/`tokenOut` EqualTo the
  pair, `fee` EqualTo the pool's fee (uint256-encoded), `recipient` EqualToAvatar, the other three Pass.

Can express fund-agnostically:
- Swaps only between the declared pair, in either direction, only at the declared fee tier, only to the Safe.
- Tuple parameters (`ExactInputSingleParams`), which the earlier slices had not exercised.

Accounting: `NoPositionAdapter` (no position). Both pool tokens are `assets()`, so the Safe's balances of them count
in NAV. The swap output is therefore always a declared, accounted wallet asset: it cannot be produced into an
undeclared token. This is the wallet-coverage property from the spec, for tokens that enter the fund by swap.

Cannot express, or chose not to:
- Multi-hop. `exactInput(bytes path)` takes a dynamic packed path, which Roles v2 cannot constrain to a declared
  token sequence fund-agnostically. Not permitted. A multi-hop route needs its own design.
- Price and slippage. Roles v2 cannot read the pool price. `amountOutMinimum` and `sqrtPriceLimitX96` are Pass,
  so the caller sets the slippage bound. NAV values the output at spot; it does not check execution price.
- Approval amounts. `approve` amount is Pass. The spender is pinned to the router, but an unlimited approval
  to the router is permitted.
- Cross-instance approve merging. Two pool instances sharing a token each declare `approve(token → router)`.
  The leaves are identical and not yet tested in a merged set.

## Tests (all pass)

| Test | Checks |
|---|---|
| `test_borrow_navCountsDebtAgainstCollateral` | NAV unchanged with borrowed cash held; falls by the borrowed amount once swept |
| `test_borrow_removalBlockedWhileDebt_allowedAfterRepay` | removal reverts `PositionNotEmpty` while debt exists; allowed after repay-all |
| `test_borrow_onBehalfOfThirdParty_reverts` | borrow with a third-party `onBehalfOf` reverts |
| `test_borrow_undeclaredAsset_reverts` | borrow of an asset with no declared borrow position reverts |
| `test_swap_allowedPath_navCountsOutputToken` | allowed USDC → WETH swap; NAV stays flat within 0.1% |
| `test_swap_reverseDirectionAllowed` | WETH → USDC through the same pool |
| `test_swap_undeclaredOutputToken_reverts` | output token DAI (not the pool's) reverts |
| `test_swap_wrongFee_reverts` | fee tier 3000 (pool is 500) reverts |
| `test_swap_recipientNotSafe_reverts` | recipient ≠ Safe reverts |
| `test_addPosition_nonCanonicalPool_reverts` | a pool address the factory does not register is rejected at `addPosition` |

Two harness notes: `_aavePool()` and similar helpers make external calls, so any `vm.expectRevert` must be set
after they run. The first draft got this wrong in three tests. The removal test also needs a one-unit USDC top-up
before repay-all, because Aave's max-repay debt rounds up. The test does that top-up explicitly.

## Gas

Measured with `vm.lastCallGas().gasTotalUsed` on the fork, cold storage. Values are deterministic across the
tests that emit them. They are not comparable to the anvil numbers in the frozen gas harness.

| Type | Step | Gas |
|---|---|---|
| aave-v3-borrow | addPosition (validate, permissions, accounting) | 479,332 |
| aave-v3-borrow | borrow via Roles | 239,934 |
| aave-v3-borrow | repay via Roles (max) | 81,125 |
| aave-v3-borrow | removePosition (after repay) | 1,172,408 |
| uniswap-v3-swap | addPosition (validate, permissions) | 834,575 |
| uniswap-v3-swap | approve via Roles | 54,356 |
| uniswap-v3-swap | exactInputSingle via Roles | 183,523 |

The JSON is `docs/research/fund-infra/gas-complex-debt-swap.json`, a flat `[{type, step, gas}]` list.

## Remaining gaps

1. Borrow removal guard is per asset, so a co-declared supply leg of the same asset blocks removal of the borrow.
2. No health-factor or LTV check at the permission layer.
3. Swap valuation is spot. No execution-price or slippage bound beyond the caller's `amountOutMinimum`.
4. Multi-hop swaps are not permitted.
5. Approve merging across pool instances that share a token is not tested.
6. `removePosition` at 1.17M gas is high; likely the full adapter read of the market. Not profiled further.
