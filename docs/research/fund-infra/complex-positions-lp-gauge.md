# Complex positions: Uniswap V3 LP NFT and Curve 3pool + gauge

Slice B of `local://complex-modules-spec.md`, on the FundConfig POC (mainnet fork, block 26,500,000).
Files: `poc/fundconfig/modules/{UniswapV3LpModule,CurvePoolModule,CurveGaugeModule}.sol`,
`test/poc/fundconfig/FundConfigLpGauge.fork.t.sol`. Frozen core unchanged.

## Verdict

| Type | Expressible in current interface | Notes |
|---|---|---|
| Uniswap V3 LP NFT | Yes | Custom condition on `tokenId`; module is its own checker. Pool bound via `extra`. |
| Curve 3pool + gauge | Yes, as two positions | Accounting is single-valued (frozen), so one module per leg. Wallet-LP leg is invisible to NAV (upstream gap). |

## Uniswap V3 LP (`UniswapV3LpModule`, instance = pool)

- Leaves (Send): `approve(token0|token1, NPM)` pinned to NPM; `mint` (11-field tuple, token0/token1/fee EqualTo, recipient EqualToAvatar); `increaseLiquidity` and `decreaseLiquidity` with `tokenId` Custom; `collect` with `tokenId` Custom and recipient EqualToAvatar.
- Custom `compValue = abi.encodePacked(module, bytes12(uint96(uint160(pool))))`. Roles passes `extra = bytes12(uint96(uint160(pool)))`, which is only the low 96 bits of the pool. The checker recovers the full pool from `NPM.positions(tokenId)` and `factory.getPool(token0, token1, fee)`, then requires it to equal the bound pool. An undeclared pool, or a Safe-owned NFT from another pool, reverts.
- Gas (`execTransactionWithRole`, Custom check included, via `vm.lastCallGas().gasTotalUsed`): increaseLiquidity 130,972; decreaseLiquidity 129,693; collect 96,571. Custom check direct (approximate, includes external call overhead): 9,650. `mint` gas is not measured in this slice.
- Tests (all passing): `test_UNI_lifecycleAllowed`, `test_UNI_mintOtherPoolReverts`, `test_UNI_otherOwnerTokenIdReverts`, `test_UNI_safeOwnedUndeclaredPoolReverts`.

### Selector discrepancy
- `docs/research/fund-infra/zodiac-roles-v2.md` (Q4, ~line 63) lists the Custom checker selector as `0x57cf558b`.
- The deployed Roles mastercopy (`0x9646fDAD06d3e24444381f44362a3B0eB343D337`) calls the 7-argument form, selector `0xb0acb980`. The module implements the 7-argument form, which is what the deployed contract calls. The docs entry should be corrected.

## Curve 3pool + gauge (`CurvePoolModule`, `CurveGaugeModule`)

- `CurvePoolModule` (instance = pool, `CurvePoolsMeta`): `approve(coin_i, pool)`, `add_liquidity(uint256[N],uint256)`, `remove_liquidity(uint256,uint256[N])`. Unconstrained leaves use empty conditions (allow-function).
- `CurveGaugeModule` (instance = gauge, `CurveGaugesMeta`): `approve(lp, gauge)`, `deposit(uint256)`, `withdraw(uint256)`, and `mint(address)` on the CRV Minter with `Cond.t1(Cond.equalTo(gauge))`.
- Gas (`execTransactionWithRole`): add_liquidity 180,443; gauge deposit 484,502 (enter/exit test) or 491,002 (claim test, different state); gauge withdraw 147,939; remove_liquidity 135,612; Minter `mint(gauge)` 230,155.
- Tests: `test_CRV_enterExitBothLegsCounted` (NAV stays within 1% of pre-entry while LP is staked and after exit), `test_CRV_claimViaMinter`, `test_CRV_removalGuard`.

### CRV claim: gauge `claim_rewards()` does not exist on this gauge
- The 3pool gauge `0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A` reverts on `claim_rewards()` (921 gas, no subcall). The adapter and tests therefore use the Minter path: `CRV_MINTER.mint(gauge)` (`0xd061D61a4d941c39E5453435B6345Dc261C2fcE0`). It minted CRV to the Safe after a 1-day warp. The leaf sits on a different target, which the frozen `PositionLeaf` shape allows.
- Extra gauge reward tokens are not declared. `reward_tokens(0)` reverts on this legacy gauge, and `CurveGaugesMetaBalanceAdapter` handles that fail-open. Limitation: any non-CRV gauge reward would be unclaimable through this module.

### Wallet-LP gap (upstream, out of scope): removal guard does not cover 3pool LP
- `src/balances/MetaBalanceAdapters/curve/CurvePoolLib.sol` `getLpToken` falls through to "pool is the LP token" when `lp_token()` reverts. 3pool's `lp_token()` reverts, so the logic is wrong for classic 3pool.
- `CurvePoolsMetaBalanceAdapter._instancePositions` then returns `[]`. The wallet LP is invisible to NAV, and `FundConfig.removePosition` (which fails open on empty accounting) does not block removing the 3pool position while LP is held.
- `test_CRV_removalGuard` characterizes this gap: it asserts the wallet LP is positive and that `removePosition(curvePoolModuleId, THREE_POOL)` succeeds. The gauge leg is guarded (non-zero staked balance blocks removal).
- Options for Main: (a) fix `CurvePoolLib` in a separate upstream PR; (b) switch to a StableSwap-NG pool that exposes `lp_token()`. The spec keeps 3pool, so this is open.

### Single-Accounting limitation
- `Accounting` (frozen) is single-valued. A Curve position is therefore two positions (pool module and gauge module), each with its own coordinate and removal guard. A combined per-product guard is not expressible in the current interface.

## NAV staleness with CRV held (open finding, not resolved)

- `fundNav` returns `stale = true` whenever CRV is in the Safe (wallet after claim, or accrued rewards). Trace: `calculateValue([CRV], [1.1e12], USDC)` on NAV proxy `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214` returns `(0, true)`. The feed path resolves to Chainlink CRV/USD `0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f`, whose underlying round has `updatedAt = 1795702986`.
- The fork timestamp is about `1795703639`, so the feed is about 650 seconds old. The registered heartbeat is `86400` (`script/config/nav-config/assets-and-price-feeds/1.json` lines 369-374; `script/config/price-feeds-catalogue.json` line 183). By configuration, the feed should not be stale. The root cause of the `(0, true)` result is not determined from the trace; the pricing path is `ceaf249c` in the Prices implementation `0xaBCC2526a6ebCFE637EB2B660410adff60eCFB73`.
- Consequence for tests: the enter/exit test asserts NAV exactly, but has no warp, so no CRV accrues. The claim test has no NAV assertion. Do not reintroduce NAV assertions after a claim until the CRV pricing result is explained.

## Test status

- Command: `FOUNDRY_PROFILE=slow forge test --match-path test/poc/fundconfig/FundConfigLpGauge.fork.t.sol -vv`
- Result: 7 passed, 0 failed.
- Gas logs captured in the same run (values above).
