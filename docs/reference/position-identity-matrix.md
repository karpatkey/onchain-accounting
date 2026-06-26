# Position-identity matrix — every leg every balance adapter can emit

Verified against `src/balances/` emission code on 2026-06-26 (includes the Nexus, Ethena cooldown, ether.fi and StakeWise V3 exit-queue adapters; Aura removed). Companion to [`docs/howto/position-identity-schema.md`](../howto/position-identity-schema.md), which defines the schema; this file enumerates the **actual value space** each adapter populates.

## How a position is identified

Identity is the tuple `(chainId, protocolId, positionId, balanceAsset.asset, positionKind)`. `balanceAdapter` (provenance) and `isDebt` (the canonical NAV-sign signal per `PositionKind.sol` — read directly, not inferred from kind) are excluded by design. `Position` adds only pricing fields (`quoteAsset`, `value`, `price`, `priceDecimals`, `stale`) on top of `PositionBalance` — none participate in identity, so this matrix covers both structs.

**Kind assignment rule:** `positionKind` reflects the **outermost action family** — what the account does to enter/exit the position. A position exited via unstake is `Staking` regardless of what is wrapped inside (the inner exposure stays recoverable from `protocolId`/`positionId`); LP principal sitting unstaked in the wallet is `Supplied`.

## The matrix — one row per emitted leg

| Adapter | `protocolId` slug | `positionId` schema | Leg | `PositionKind` | `isDebt` | `balanceAsset` |
|---|---|---|---|---|---|---|
| ERC20DefaultBalanceAdapter | `wallet` | `abi.encode(address asset)` | wallet balance | `Wallet` | false | the asset itself |
| AaveV3InstancesMeta | `aave-v3-lending` | `abi.encode(address pool, address reserve)` | supply (collateral toggle off) | `Supplied` | false | reserve |
| | | | supply (collateral toggle on) | `Collateral` | false | reserve |
| | | | variable debt | `Borrowed` | true | reserve |
| SparkLend | `spark-lend` | `abi.encode(address pool, address reserve)` | same 3 legs as Aave V3 | `Supplied`/`Collateral`/`Borrowed` | f/f/t | reserve |
| CompoundV3CometsMeta | `compound-v3` | `abi.encode(address comet)` | base supply (net > 0) | `Supplied` | false | base token |
| | | | base borrow (net < 0) | `Borrowed` | true | base token |
| | | | collateral balance | `Collateral` | false | collateral asset |
| | | | accrued COMP | `Rewards` | false | COMP |
| MorphoMarketsMeta | `morpho-markets` | `abi.encode(bytes32 marketId)` | market collateral | `Collateral` | false | collateral token |
| | | | loan-side supply | `Supplied` | false | loan token |
| | | | borrow | `Borrowed` | true | loan token |
| MorphoVaultsMeta | `morpho-vaults` | `abi.encode(address vault)` | vault deposit (`convertToAssets`) | `Supplied` | false | `vault.asset()` |
| GearboxMarketsMeta | `gearbox-v3` | `abi.encode(address market)` | passive-pool deposit | `Supplied` | false | `market.asset()` |
| FluidFTokensMeta | `fluid-ftokens` | `abi.encode(address fToken)` | lending deposit | `Supplied` | false | `fToken.asset()` |
| FluidVaultsMeta | `fluid-vaults` | `abi.encode(address vault)` | T1 vault collateral | `Collateral` | false | supply token |
| | | | T1 vault debt | `Borrowed` | true | borrow token |
| EulerVaultsMeta | `euler-vaults` | `abi.encode(address vault)` | supply (not EVC collateral) | `Supplied` | false | `vault.asset()` |
| | | | supply (EVC collateral on) | `Collateral` | false | `vault.asset()` |
| | | | core-eVault debt (`debtOf`) | `Borrowed` | true | `vault.asset()` |
| ERC4626Wrap | `erc4626` | `abi.encode(address wrapper)` | wrapper shares (`convertToAssets`) | `Supplied` | false | `wrapper.asset()` |
| Cap | `cap` | `abi.encode(address cUSD)` | cUSD + stcUSD combined | `Supplied` | false | USDC |
| AaveV3SafetyModule | `aave-v3-safety-module` | `abi.encode(address stakeToken)` | staked principal (per stake token) | `Staking` | false | staked token (AAVE/GHO/ABPT…) |
| | | | claimable SM rewards | `Rewards` | false | AAVE |
| AaveUmbrella | `aave-v3-umbrella` | `abi.encode(address stakeToken)` | staked principal | `Staking` | false | bare reserve |
| | | | claimable rewards | `Rewards` | false | bare reserve of reward |
| StakeWiseV3VaultsMeta | `stakewise-v3` | `abi.encode(address vault)` | vault stake (shares → assets) | `Staking` | false | ETH (mainnet) / GNO (Gnosis) |
| | | | minted osToken debt | `Borrowed` | true | same underlying |
| UniswapV2PoolsMeta | `uniswap-v2` | `abi.encode(address pair)` | token0 pro-rata principal | `Supplied` | false | token0 |
| | | | token1 pro-rata principal | `Supplied` | false | token1 |
| PancakeSwapV2PoolsMeta | `pancakeswap-v2` | `abi.encode(address pair)` | same 2 legs as Uniswap V2 | `Supplied` | false | token0/token1 |
| UniswapV3PoolsMeta | `uniswap-v3` | `abi.encode(address npm, uint256 tokenId)` | in-range principal, token0 | `Supplied` | false | token0 |
| | | | in-range principal, token1 | `Supplied` | false | token1 |
| | | | unclaimed fees, token0 | `Fees` | false | token0 |
| | | | unclaimed fees, token1 | `Fees` | false | token1 |
| PancakeSwapV3PoolsMeta | `pancakeswap-v3` | `abi.encode(address npm, uint256 tokenId)` | same 4 legs as Uniswap V3 | `Supplied`/`Fees` | false | token0/token1 |
| BalancerV2PoolsMeta | `balancer-v2-pool` | `abi.encode(bytes32 poolId)` | per-token principal (wallet BPT) | `Supplied` | false | pool token |
| BalancerV3PoolsMeta | `balancer-v3-pool` | `abi.encode(address pool)` | per-token principal (wallet BPT) | `Supplied` | false | pool token |
| CurvePoolsMeta | `curve-pool` | `abi.encode(address pool)` | per-coin principal (wallet LP) | `Supplied` | false | pool coin |
| BalancerV2GaugesMeta | `balancer-v2-gauge` | `abi.encode(address gauge)` | staked per-token principal | `Staking` | false | pool token |
| | | | BAL from minter | `Rewards` | false | BAL |
| | | | extra reward tokens | `Rewards` | false | reward token |
| BalancerV3GaugesMeta | `balancer-v3-gauge` | `abi.encode(address gauge)` | same 3 legs as V2 gauges | `Staking`/`Rewards` | false | pool token / reward token |
| CurveGaugesMeta | `curve-gauge` | `abi.encode(address gauge)` | staked per-coin principal | `Staking` | false | pool coin |
| | | | CRV (lower bound) | `Rewards` | false | CRV |
| | | | extra reward tokens | `Rewards` | false | reward token |
| ConvexRewardsMeta | `convex` | `abi.encode(address rewarder)` | staked per-coin principal | `Staking` | false | Curve pool coin |
| | | | earned CRV | `Rewards` | false | CRV |
| | | | derived CVX (cliff schedule) | `Rewards` | false | CVX |
| | | | extra reward tokens | `Rewards` | false | reward token |
| StaderWithdrawalQueue | `stader-withdrawal` | `""` (empty — account-global) | ETH owed from open requests | `Supplied` | false | WETH |
| KelpWithdrawalQueue | `kelp-withdrawal` | `""` (empty — account-global) | owed per payout asset | `Supplied` | false | each supported asset |
| LidoWithdrawalQueue | `lido-withdrawal` | `""` (empty — account-global) | claimable + pending ETH | `Supplied` | false | native ETH |
| EtherFiWithdrawals | `etherfi-withdrawal` | `""` (empty — account-global) | in-flight withdrawal-queue ETH | `Supplied` | false | native ETH |
| StakeWiseExitQueue | `stakewise-exit` | `""` (empty — account-global) | in-flight exit-queue assets | `Supplied` | false | native ETH |
| EthenaCooldownBalanceAdapter | `ethena-cooldown` | `""` (empty — account-global) | USDe in the sUSDe unstaking cooldown | `Supplied` | false | USDe |
| NexusMutualStakingPools | `nexus-mutual-staking` | `abi.encode(uint256 tokenId, uint256 poolId)` | active + expired staked NXM (per StakingNFT) | `Staking` | false | NXM |
| | | | claimable rewards (per StakingNFT) | `Rewards` | false | NXM |
| MerklRewards | `merkl` | `abi.encode(address rewardToken)` | unclaimed rewards per token | `Rewards` | false | reward token |

## PositionKind usage census

Emission-site counts across `src/balances/` (grep, 2026-06-26, post-assignment):

| `PositionKind` | Emission sites | Emitting adapters |
|---|---|---|
| `Wallet` | 1 | ERC20DefaultBalanceAdapter only |
| `Supplied` | 22 | lending supply, vaults, ERC-4626 wraps, unstaked LP, withdrawal/exit queues, Euler vaults |
| `Borrowed` | 8 | Aave V3 (×2 sites), Spark, Compound V3, Morpho Markets, Fluid Vaults, StakeWise V3, Euler vaults |
| `Collateral` | 6 | Aave V3, Spark, Compound V3, Morpho Markets, Fluid Vaults, Euler vaults |
| `Staking` | 8 | Safety Module, Umbrella, StakeWise V3, Nexus staked NXM, Balancer gauges ×2, Curve gauge, Convex |
| `Rewards` | 12 | SM, Umbrella, Nexus staked NXM, Compound V3, Balancer gauges ×2, Curve gauge, Convex, Merkl |
| `Fees` | 2 | Uniswap V3 (PancakeSwap V3 inherits) |

## Other observable invariants

- `isDebt == true` occurs **only** with `positionKind == Borrowed` at all 8 current emission sites. This correlation is observational: `isDebt` remains the canonical NAV-sign signal (per `PositionKind.sol`), so consumers should read it directly rather than infer sign from `positionKind`.
- `Collateral` and `Staking` are always `isDebt == false`.
- Empty `positionId` (`""`) marks account-global positions: the Ethena cooldown and the withdrawal/exit queues (Lido, Kelp, Stader, ether.fi, StakeWise V3). All other adapters encode at least one address (or `bytes32` poolId/marketId; Uniswap/PancakeSwap V3 add `uint256 tokenId`, and Nexus Mutual staking encodes `(uint256 tokenId, uint256 poolId)` per StakingNFT).
- One `protocolId` slug ⇒ exactly one `positionId` decode schema, as required by the slug rules — no adapter violates this.
- Multi-leg adapters reuse the **same** `positionId` across their legs; legs are distinguished by `positionKind` (and `balanceAsset` for per-token legs), which is exactly why `positionKind` must be identity-stable.
- The wallet-LP vs gauge-staked-LP pairing (Curve/Balancer pools metas vs gauges metas) is now distinguishable by kind alone: `Supplied` = liquid LP, `Staking` = behind an unstake.
