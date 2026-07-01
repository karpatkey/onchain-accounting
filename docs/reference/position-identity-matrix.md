# Position-identity matrix — every leg every balance adapter can emit

Verified against `src/balances/` emission code on 2026-06-29 (includes the Nexus, Ethena cooldown, ether.fi and StakeWise V3 exit-queue adapters and the Gearbox V3 credit-accounts adapter; Aura and the ERC-4626 wrap adapter removed; reflects the 3-level `protocolBrand`/`protocolId`/`protocolSubId` taxonomy and the typed `positionInstanceId` field that replaced inline labels). Companion to [`docs/howto/position-identity-schema.md`](../howto/position-identity-schema.md), which defines the schema; this file enumerates the **actual value space** each adapter populates.

## How a position is identified

Identity is the tuple `(chainId, protocolSubId, positionId, balanceAsset.asset, positionKind)`. The identity-key protocol component is `protocolSubId` (the most specific per-product slug); the broader `protocolBrand` and `protocolId` fields are display/grouping only and are **not** part of the key. `isLocked` is **excluded** from the key: it is a mutable per-leg attribute — the withdrawal-queue / cooldown adapters split a holding into a claimable leg (`isLocked=false`) and a locked leg (`isLocked=true`) that share the same static `positionId`, and a leg flips `true→false` as its portion finalizes, so keying on it would split one economic position into two keys over its lifetime. The two legs therefore share one key and are **summed** in reconciliation (read `isLocked` per leg for the claimable-vs-locked split; see [ADR 0016](../decisions/0016-islocked-position-status.md)). `balanceAdapter` (provenance), `positionInstanceId` (the ephemeral per-item coordinate), and `isDebt` (the canonical NAV-sign signal per `PositionKind.sol` — read directly, not inferred from kind) are likewise excluded by design. `Position` adds only pricing fields (`quoteAsset`, `value`, `price`, `priceDecimals`, `stale`) on top of `PositionBalance` — none participate in identity, so this matrix covers both structs.

**The key identifies a position _group_, not necessarily a single leg.** Adapters that emit one leg per underlying item — the withdrawal queues (one leg per request) and the NFT-position adapters (Uniswap V3 / PancakeSwap V3 / Nexus Mutual, one leg per NFT — up to four for a V3 LP) — emit multiple legs sharing the same full key, told apart only by the typed `positionInstanceId` (request id / NFT id), which is **not** part of the key. Reconcile at the position level by **summing amounts across legs that share the key** (what NAV does); read `positionInstanceId` for per-item granularity.

**Kind assignment rule:** `positionKind` reflects the **outermost action family** — what the account does to enter/exit the position. A position exited via unstake is `Staking` regardless of what is wrapped inside (the inner exposure stays recoverable from `protocolId`/`positionId`); LP principal sitting unstaked in the wallet is `Supplied`.

## The matrix — one row per emitted leg

`isLocked` is `false` for every leg except the withdrawal-queue / cooldown legs and the staking-with-cooldown locked-stake legs (Aave SM, Umbrella) called out below; it is omitted from the rows where it is always `false`. Uniform rule: `isLocked = non-withdrawable` (active stake = locked).

| Adapter | `protocolSubId` slug | `positionId` schema | Leg | `PositionKind` | `isDebt` | `balanceAsset` |
|---|---|---|---|---|---|---|
| ERC20DefaultBalanceAdapter | `wallet` | `abi.encode(address asset)` | wallet balance | `Wallet` | false | the asset itself |
| AaveV3InstancesMeta | `aave-v3-lending` | `abi.encode(address pool)` | supply (collateral toggle off) | `Supplied` | false | reserve |
| | | | supply (collateral toggle on) | `Collateral` | false | reserve |
| | | | variable debt | `Borrowed` | true | reserve |
| SparkLend | `spark-lend` | `abi.encode(address pool)` | same 3 legs as Aave V3 | `Supplied`/`Collateral`/`Borrowed` | f/f/t | reserve |
| CompoundV3CometsMeta | `compound-v3-comets` | `abi.encode(address comet)` | base supply (net > 0) | `Supplied` | false | base token |
| | | | base borrow (net < 0) | `Borrowed` | true | base token |
| | | | collateral balance | `Collateral` | false | collateral asset |
| | | | accrued COMP | `Rewards` | false | COMP |
| MorphoMarketsMeta | `morpho-markets` | `abi.encode(bytes32 marketId)` | market collateral | `Collateral` | false | collateral token |
| | | | loan-side supply | `Supplied` | false | loan token |
| | | | borrow | `Borrowed` | true | loan token |
| MorphoVaultsMeta | `morpho-vaults` | `abi.encode(address vault)` | vault deposit (`convertToAssets`) | `Supplied` | false | `vault.asset()` |
| GearboxV3MarketsMeta | `gearbox-v3-markets` | `abi.encode(address market)` | passive-pool deposit | `Supplied` | false | `market.asset()` |
| GearboxV3CreditAccountsMeta | `gearbox-v3-credit-accounts` | `abi.encode(address creditAccount)` | credit-account collateral | `Collateral` | false | collateral token |
| | | | credit-account debt | `Borrowed` | true | pool underlying |
| FluidFTokensMeta | `fluid-ftokens` | `abi.encode(address fToken)` | lending deposit | `Supplied` | false | `fToken.asset()` |
| FluidVaultsMeta | `fluid-vaults` | `abi.encode(address vault)` | T1 vault collateral | `Collateral` | false | supply token |
| | | | T1 vault debt | `Borrowed` | true | borrow token |
| EulerVaultsMeta | `euler-vaults` | `abi.encode(address vault)` | supply (not EVC collateral) | `Supplied` | false | `vault.asset()` |
| | | | supply (EVC collateral on) | `Collateral` | false | `vault.asset()` |
| | | | core-eVault debt (`debtOf`) | `Borrowed` | true | `vault.asset()` |
| Cap | `cap` | `abi.encode(address cUSD)` | held cUSD (Stablecoin) | `Supplied` | false | USDC |
| | | `abi.encode(address stcUSD)` | staked stcUSD (Savings) | `Staking` | false | USDC |
| AaveV3SafetyModule | `aave-v3-safety-module` | `abi.encode(address stakeToken)` | locked staked principal (active stake + cooling/expired cooldown) — `isLocked=true` | `Staking` | false | staked token (AAVE/GHO/ABPT…) |
| | | `abi.encode(address stakeToken)` | unlocked staked principal (cooldown elapsed-and-in-window) — `isLocked=false` | `Staking` | false | staked token |
| | | `abi.encode(address stakeToken)` | claimable SM rewards | `Rewards` | false | AAVE |
| AaveUmbrella | `aave-v3-umbrella` | `abi.encode(address stakeToken)` | locked staked principal (active stake + cooling/expired cooldown) — `isLocked=true` | `Staking` | false | bare reserve |
| | | `abi.encode(address stakeToken)` | unlocked staked principal (cooldown elapsed-and-in-window) — `isLocked=false` | `Staking` | false | bare reserve |
| | | `abi.encode(address stakeToken)` | claimable rewards | `Rewards` | false | bare reserve of reward |
| StakeWiseV3VaultsMeta | `stakewise-v3-vaults` | `abi.encode(address vault)` | vault stake (shares → assets) | `Staking` | false | ETH (mainnet) / GNO (Gnosis) |
| | | | minted osToken debt | `Borrowed` | true | same underlying |
| UniswapV2PoolsMeta | `uniswap-v2` | `abi.encode(address pair)` | token0 pro-rata principal | `Supplied` | false | token0 |
| | | | token1 pro-rata principal | `Supplied` | false | token1 |
| PancakeSwapV2PoolsMeta | `pancakeswap-v2` | `abi.encode(address pair)` | same 2 legs as Uniswap V2 | `Supplied` | false | token0/token1 |
| UniswapV3PoolsMeta | `uniswap-v3` | `abi.encode(address pool)` (NFT id in `positionInstanceId`) | in-range principal, token0 | `Supplied` | false | token0 |
| | | | in-range principal, token1 | `Supplied` | false | token1 |
| | | | unclaimed fees, token0 | `Fees` | false | token0 |
| | | | unclaimed fees, token1 | `Fees` | false | token1 |
| PancakeSwapV3PoolsMeta | `pancakeswap-v3` | `abi.encode(address pool)` (NFT id in `positionInstanceId`) | same 4 legs as Uniswap V3 | `Supplied`/`Fees` | false | token0/token1 |
| BalancerV2PoolsMeta | `balancer-v2-pools` | `abi.encode(bytes32 poolId)` | per-token principal (wallet BPT) | `Supplied` | false | pool token |
| BalancerV3PoolsMeta | `balancer-v3-pools` | `abi.encode(address pool)` | per-token principal (wallet BPT) | `Supplied` | false | pool token |
| CurvePoolsMeta | `curve-pools` | `abi.encode(address pool)` | per-coin principal (wallet LP) | `Supplied` | false | pool coin |
| BalancerV2GaugesMeta | `balancer-v2-gauges` | `abi.encode(address gauge)` | staked per-token principal | `Staking` | false | pool token |
| | | | BAL from minter | `Rewards` | false | BAL |
| | | | extra reward tokens | `Rewards` | false | reward token |
| BalancerV3GaugesMeta | `balancer-v3-gauges` | `abi.encode(address gauge)` | same 3 legs as V2 gauges | `Staking`/`Rewards` | false | pool token / reward token |
| CurveGaugesMeta | `curve-gauges` | `abi.encode(address gauge)` | staked per-coin principal | `Staking` | false | pool coin |
| | | | CRV (lower bound) | `Rewards` | false | CRV |
| | | | extra reward tokens | `Rewards` | false | reward token |
| ConvexCurveLPStakingMeta | `convex-curve-lp-staking` | `abi.encode(address rewarder)` | staked per-coin principal | `Staking` | false | Curve pool coin |
| | | | earned CRV | `Rewards` | false | CRV |
| | | | derived CVX (cliff schedule) | `Rewards` | false | CVX |
| | | | extra reward tokens | `Rewards` | false | reward token |
| StaderWithdrawalQueue | `stader-withdrawal` | `abi.encode(address userWithdrawalManager)` (static) | **one leg per request** — finalized = claimable ETH (`isLocked=false`), pending = `isLocked=true`; request id in `positionInstanceId`, all legs share the positionId | `Supplied` | false | WETH |
| KelpWithdrawalQueue | `kelp-withdrawal` | `abi.encode(address withdrawalManager)` (static) | **one leg per request** (per supported asset) — claimable `isLocked=false`, pending `isLocked=true` (until cursor + delay pass); `userNonce` in `positionInstanceId`; payout asset in `balanceAsset` | `Supplied` | false | each supported asset |
| LidoWithdrawalQueue | `lido-withdrawal` | `abi.encode(address withdrawalQueue)` (static) | **one leg per request** — finalized = claimable ETH (`isLocked=false`), pending `isLocked=true`; request id in `positionInstanceId`, all legs share the positionId | `Supplied` | false | native ETH |
| EtherFiWithdrawalQueueAssisted | `etherfi-withdrawal` | `abi.encode(address withdrawRequestNFT)` (static) | **one leg per request** (cached NFT tokenId) — finalized `isLocked=false`, pending `isLocked=true`; tokenId in `positionInstanceId`, all legs share the positionId | `Supplied` | false | native ETH |
| StakeWiseV3ExitQueueAssisted | `stakewise-v3-exit` | `abi.encode(address vault)` (static, per vault) | **per request (positionTicket)** — up to two legs: exited assets (claimable, `isLocked=false`) + queued shares→assets (`isLocked=true`); `positionTicket` in `positionInstanceId`, legs share the per-vault positionId | `Supplied` | false | native ETH |
| EthenaCooldownBalanceAdapter | `ethena-cooldown` | `abi.encode(address sUSDe)` (static, single leg) | USDe cooling — `isLocked=true` until cooldown elapsed, then `false` | `Supplied` | false | USDe |
| NexusMutualStakingPoolsAssisted | `nexus-mutual-staking-pools` | `abi.encode(address stakingPool)` (NFT id in `positionInstanceId`) | active + expired staked NXM (per StakingNFT) | `Staking` | false | NXM |
| | | | claimable rewards (per StakingNFT) | `Rewards` | false | NXM |
| MerklRewardsAssisted | `merkl` | `abi.encode(address distributor)` | unclaimed rewards (one leg per reward token, distinguished by `balanceAsset`; split further per campaign via `positionInstanceId = keccak256(campaignId, subCampaignId)`) | `Rewards` | false | reward token |

## PositionKind usage census

Emission-site counts across `src/balances/` (grep `PositionKind.<X>`, includes the claimable/locked
split legs of the withdrawal-queue / cooldown adapters, which each emit a `Supplied` leg per status):

| `PositionKind` | Emission sites | Emitting adapters |
|---|---|---|
| `Wallet` | 1 | ERC20DefaultBalanceAdapter |
| `Supplied` | 23 | lending supply, vaults, Cap cUSD, unstaked LP, withdrawal/exit queues (claimable + locked legs), Ethena cooldown, Euler vaults |
| `Borrowed` | 8 | Aave V3, Spark, Compound V3, Morpho Markets, Fluid Vaults, StakeWise V3, Euler vaults, Gearbox credit accounts |
| `Collateral` | 7 | Aave V3, Spark, Compound V3, Morpho Markets, Fluid Vaults, Euler vaults, Gearbox credit accounts |
| `Staking` | 11 | Safety Module (locked + unlocked stake), Umbrella (locked + unlocked stake), StakeWise V3, Cap stcUSD, Nexus staked NXM, Balancer gauges ×2, Curve gauge, Convex |
| `Rewards` | 12 | SM, Umbrella, Nexus staked NXM, Compound V3, Balancer gauges ×2, Curve gauge, Convex, Merkl |
| `Fees` | 2 | Uniswap V3 (PancakeSwap V3 inherits) |

## Other observable invariants

- `isDebt == true` occurs **only** with `positionKind == Borrowed` at all current Borrowed emission sites. This correlation is observational: `isDebt` remains the canonical NAV-sign signal (per `PositionKind.sol`), so consumers should read it directly rather than infer sign from `positionKind`.
- `Collateral` and `Staking` are always `isDebt == false`.
- **Static positionId, ephemeral request id in `positionInstanceId`.** The withdrawal/exit queues (Lido, Kelp, Stader, ether.fi, StakeWise V3) and the Ethena cooldown encode a **static, timeless** coordinate — `abi.encode(address <queue/manager/vault/sUSDe>)` (StakeWise: per vault) — never a per-request id; the owed/payout asset is in `balanceAsset`. The four withdrawal queues now emit **one leg per open request** (StakeWise: up to two legs per `positionTicket` — claimable + still-queued — since a single exit can be partially processed), each leg's `isLocked` reflecting that request's own state, and the ephemeral request id (ERC721 request id / `userNonce` / cached tokenId / `positionTicket`) carried in the typed `positionInstanceId` (`bytes32(<id>)`), never in `positionId`. All legs of an account share the static positionId. (Ethena stays a single cooldown leg; the staking-with-cooldown adapters Aave SM & Umbrella keep their two staking legs — active=locked, in-window=unlocked — plus a reward leg, all sharing `abi.encode(address stakeToken)`, distinguished by `isLocked` + `positionKind`.) All other adapters encode at least one address (or `bytes32` poolId/marketId). Uniswap/PancakeSwap V3 and Nexus Mutual staking encode the **pool contract address** (the V3 pool / the staking pool) — a stable coordinate — and carry the ephemeral per-NFT id only in the typed `positionInstanceId`, never in `positionId`. No adapter emits an empty `positionId`.
- One `protocolSubId` slug ⇒ exactly one `positionId` decode schema, as required by the slug rules — no adapter violates this.
- Multi-leg adapters reuse the **same** `positionId` across their legs; legs are distinguished by `positionKind`, `balanceAsset` (for per-token legs), and `isLocked` (claimable vs locked legs). The per-request withdrawal-queue adapters and the per-NFT adapters go further — they emit **multiple legs that share the full key** and differ only in the typed `positionInstanceId` (request id / NFT id); those legs must be summed (not deduplicated) when reconciling by key.
- The wallet-LP vs gauge-staked-LP pairing (Curve/Balancer pools metas vs gauges metas) is now distinguishable by kind alone: `Supplied` = liquid LP, `Staking` = behind an unstake.
