# Balance-adapter coverage roadmap

> **PR #47 (meta-adapter framework):** Coverage was expanded significantly. A family of immutable meta-adapters now covers every instance of the protocol families below (Morpho Vaults/Markets, Aave V3, Balancer V3/V2 pools+gauges, Uniswap V3/V2, PancakeSwap V3/V2, Gearbox, Compound V3, Fluid fTokens/Vaults, StakeWise V3, Curve pools+gauges, Convex, Euler V2 — 20 meta-adapter contracts in `src/balances/protocols/`). The active instance set for each is governed on NAVCalculator via `addMetaInstances`/`removeMetaInstances` instead of deploying a contract per instance.

Living document. Tracks protocols and protocol features whose positions are **not yet** captured by NAVCalculator's balance adapters, with the goal of growing NAV coverage one PR at a time.

The Stader withdrawal-queue adapter (`src/balances/protocols/StaderWithdrawalQueue.sol`) is the reference template for the **withdrawal-queue** family below: a single immutable adapter that enumerates an account's open requests on a protocol-specific manager and reports a single aggregated credit position in the underlying asset. Most LST queues fit that shape with cosmetic differences in enumeration (sequential ID vs. ERC721 NFT) and request struct layout.

When picking the next protocol to add, prioritise by **whether kpk actually parks value there** rather than by protocol prominence — the catch-all `ERC20DefaultBalanceAdapter` already covers wallet ERC20 holdings, so a new adapter only earns its keep when there is value parked outside the wallet (a queue, a vault wrapper, a debt position).

The system does not track deprecated protocols — once a protocol is no longer in active use, its adapter, config, and identity entries are deleted rather than left in a permanently-disabled state. Aave V2 was removed for this reason (as were Aura and Sky Savings in recent PRs).

---

## LST/LRT withdrawal queues

The point of these adapters is to track value that has left the LST as ERC20 but hasn't yet returned as ETH/native. While in the queue the position is invisible to `ERC20DefaultBalanceAdapter`.

| Protocol | Manager (mainnet) | Shape | Notes |
|---|---|---|---|
| **Stader (ETHx)** ✅ | `0x9F0491B32DBce587c50c4C43AB303b06478193A7` | Sequential `requestId`, `requestIdsByUserAddress(address, idx)` getter, `userWithdrawRequests(id)` returns `(owner, ethXAmount, ethExpected, ethFinalized, requestBlock)`. `nextRequestIdToFinalize` gates claimability. | Implemented in this repo. |
| **Lido (stETH)** ✅ | `WithdrawalQueueERC721` at `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1` | ERC721. Enumerate via `getWithdrawalRequests(address) → uint256[]`. Per-id status via `getWithdrawalStatus(uint256[]) → WithdrawalRequestStatus[]` returning `amountOfStETH, amountOfShares, owner, timestamp, isFinalized, isClaimed`. | Implemented in this repo (`LidoWithdrawalQueue.sol`): reports open (un-claimed) requests as **native ETH** (the asset Lido pays on claim; priced ETH/USD) — finalized requests use exact claimable ETH (`getClaimableEther`), not-yet-finalized use `amountOfStETH`. |
| **etherFi (eETH/weETH)** | `WithdrawRequestNFT` at `0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c` | ERC721. Enumerate via `IERC721Enumerable.tokenOfOwnerByIndex` (the contract is enumerable). Per-id `getRequest(uint256) → (amountOfEEth, shareOfEEth, isValid, feeGwei)`. | Reports eETH amount; convert via `LiquidityPool.amountForShare()` if needed. |
| **Frax (frxETH/sfrxETH)** | `FraxEtherRedemptionQueue` at `0x82bA8da44Cd5261762e629dd5c605b17715727bd` | ERC721. `nftInformation(uint256)` returns the redemption metadata. | Reports ETH owed at maturity; uses `maturity` block, not finalization batches. |
| **Renzo (ezETH)** | `WithdrawQueue` at `0xf2F305D14DCD8aaef887E0428B3c9534795D0d60` | ERC721 with explicit `withdrawRequests` mapping; sequential IDs per holder. | Newer queue; finalization tied to Renzo restaking unwinds. |
| **Kelp (rsETH)** ✅ | `LRTWithdrawalManager` at `0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16` | Per-supported-asset deques: `userAssociatedNonces(asset, user) → (begin, end)` and `getUserWithdrawalRequest(asset, user, i) → (rsETHAmount, expectedAssetAmount, withdrawalStartBlock, userNonce)`. Payout-asset set discovered via `lrtConfig().getSupportedAssetList()` (stETH, ETHx, native ETH at time of writing). | Implemented in this repo (`KelpWithdrawalQueue.sol`): single multi-asset adapter, one credit position per NAV-registered payout asset. |
| **Mantle (mETH)** | `Staking` contract; `unstakeRequest`/`claimUnstakeRequest` | Sequential `unstakeRequestId` per user; struct includes `mETHLocked`, `ethRequested`, `cumulativeETHRequested`, `blockNumber`. | Similar shape to Stader. |
| **StakeWise V3 exit queue** | per-Vault `enterExitQueue(shares)` returning a position id | `StakeWiseV3VaultsMeta.sol` covers active vault positions only (`Staking` shares + `Borrowed` osToken legs); it does **not** read the exit queue. Shares that have entered the exit queue are not yet tracked end-to-end. | Not covered — needs a dedicated adapter or an added leg. |
| **Rocket Pool (rETH)** — no adapter ✓ | n/a (rETH is a plain ERC20) | `RocketTokenRETH.burn()` pays ETH instantly from excess deposit-pool collateral, or **reverts** — there is no NFT / queue / pending-claim state for an adapter to read. | **No adapter needed (evaluated 2026-05).** rETH and RPL are registered, priced, and already wallet-covered by `ERC20DefaultBalanceAdapter` (rETH via `rETH_Price`, RPL via Chainlink; RPL rewards via `MerklRewards`), so nothing to add for token holdings. The only *non-tokenized* Rocket Pool positions are node-operator ones — staked RPL collateral, minipool bonded ETH, RPL rewards (`RocketNodeStaking` / minipools) — which the funds do not hold. Revisit only if a fund takes on RP node-operator exposure. |
| **Coinbase (cbETH)** | n/a (centralised) | Off-chain wrap/unwrap. | No on-chain queue position. |

### Implementation notes (apply across the queue family)

- **One aggregated position per payout asset.** Sum across all open requests for the account and emit one `PositionBalance` per underlying — same as `StaderWithdrawalQueue`. Splitting per request would inflate NAV row count without analytical gain. Single-asset queues (Stader, Lido, …) emit exactly one position; multi-asset queues that pay out in several underlyings (`KelpWithdrawalQueue`, which discovers stETH/ETHx/native-ETH at runtime) emit one position **per NAV-registered payout asset**, still aggregating all of that asset's requests into a single entry.
- **Claimed-entry handling.** Some managers `delete` storage on claim (Stader: `owner == address(0)` filter); ERC721-based ones burn the NFT (out of `tokenOfOwnerByIndex` automatically). Each adapter should explicitly skip claimed entries.
- **Bound the loop.** Even if enumeration is auto-exiting (revert-on-OOB or NFT enumeration), keep a hard `MAX_REQUESTS_PROBED` cap so a malicious/legit pathological account can't blow gas.
- **Underlying token configurable.** Let the constructor take `underlyingToken_` so each chain config picks WETH or `NATIVE_ADDRESS` (ERC-7528) based on what the rest of the system reports. Mirror `StakeWiseV3VaultsMeta` and the Stader queue.
- **Pre-finalization vs. finalized amount.** Use `ethFinalized` once set (post-finalization, exact). Before finalization, fall back to whatever rate-converted estimate the protocol stores at request time (`ethExpected` for Stader, `amountOfStETH` × stETH/ETH for Lido, etc.). Never invent a rate inside the adapter.

---

## Other position types not yet covered

These are not queues but represent value that lives outside the wallet and is not currently surfaced.

### Restaking / LRT primitives

- **EigenLayer**: native ETH and LST stake delegated to operators (`StrategyManager`, `DelegationManager`). Open queue: `withdrawalQueue` for delegated unstakes. Likely needed if any Alpha fund delegates to operators.
- **Symbiotic**: similar shape to EigenLayer; vaults + delegations.
- **Karak**: ditto.

### DEX LP / AMM positions

- **Balancer V3 pools + gauges**: ✅ covered — `BalancerV3PoolsMeta` + `BalancerV3GaugesMeta` (meta-adapters, ADR 0010).
- **Balancer V2 pools + gauges**: ✅ covered — `BalancerV2PoolsMeta` + `BalancerV2GaugesMeta` (meta-adapters, ADR 0010).
- **Uniswap V3**: ✅ covered — `UniswapV3PoolsMeta` (meta-adapter, ADR 0010).
- **Uniswap V2**: ✅ covered — `UniswapV2PoolsMeta` (meta-adapter, ADR 0010).
- **PancakeSwap V3**: ✅ covered — `PancakeSwapV3PoolsMeta` (meta-adapter, ADR 0010).
- **PancakeSwap V2**: ✅ covered — `PancakeSwapV2PoolsMeta` (meta-adapter, ADR 0010).
- **Curve pools + gauges**: ✅ covered — `CurvePoolsMeta` + `CurveGaugesMeta` (meta-adapters, ADR 0010).

### Liquid staking / restaking aggregators

- **StakeWise V3 vaults**: ✅ covered — `StakeWiseV3VaultsMeta` (meta-adapter, ADR 0010).

### Yield aggregator rewards

- **Convex**: ✅ covered — `ConvexRewardsMeta` (meta-adapter, ADR 0010).

### Yield / structured products

- **Pendle PT/YT**: principal-token (PT) and yield-token (YT) positions in markets and SY vaults. Each Pendle market issues distinct PT and YT ERC20s; the underlying value is non-trivial (PT depends on time-to-maturity, YT depends on accrued yield since last redemption). One adapter per market or per-LP.
- **Yearn V3 vaults**: pure ERC4626; could reuse the `ERC4626Wrap` adapter or get a thin wrapper.
- **Beefy vaults**: ERC4626-shaped, same pattern.
- **Origin OETH/OUSD**: rebasing ERC20s — `ERC20DefaultBalanceAdapter` reports the current `balanceOf` correctly, but the rebasing semantic is worth a docs note.
- **Maple direct lending pools** (beyond syrupUSDC): pool tokens with withdrawal cooldowns.

### Money markets and credit

- **Morpho Vaults**: ✅ covered — `MorphoVaultsMeta` (meta-adapter, ADR 0010).
- **Morpho Markets**: ✅ covered — `MorphoMarketsMeta` (meta-adapter, ADR 0010).
- **Aave V3 (all instances)**: ✅ covered — `AaveV3InstancesMeta` (meta-adapter, ADR 0010).
- **Compound V3**: ✅ covered — `CompoundV3CometsMeta` (meta-adapter, ADR 0010).
- **Gearbox**: ✅ covered — `GearboxMarketsMeta` (meta-adapter, ADR 0010).
- **Fluid**: ✅ covered — `FluidFTokensMeta` (ERC4626 lending) + `FluidVaultsMeta` (T1 collateral/debt) meta-adapters (ADR 0010).
- **Euler V2**: ✅ covered — `EulerVaultsMeta` (meta-adapter, ADR 0010): one adapter for both EulerEarn aggregator vaults and core eVaults (EVK), reporting `Supplied`/`Collateral` and `Borrowed` legs.
- **Ajna**: pool-based lending; inflation-bearing buckets.

### RWA / off-chain backed

- **Centrifuge tranches** (CFG): senior/junior tranche tokens in pools.
- **Goldfinch / Backed / Maple direct**: per-pool ERC20s with withdrawal mechanics.
- **Ondo (OUSG, USDY)**: KYC-gated wrappers; if held by kpk, treat as straight ERC20 with a custom price feed.

### Perps / derivatives

- **GMX V2**: GM/GLP token positions + open perp positions (exposure, collateral, PnL). The original v1 GMX adapter was deleted as part of the v1→v2 oracle migration (see `docs/historical/oracle-migration-plan.md`); a v2 implementation would be a from-scratch design if a kpk vault ever holds GMX exposure.
- **Hyperliquid (EVM bridge side)**: bridged collateral on `HyperEVM` if used.
- **Synthetix V3**: collateral and debt positions per pool.

### Cross-chain / locked

- **Bridge in-flight balances**: assets in transit across CCIP/LayerZero/Across — already handled by `BridgeEscrow` accounting on the bridge side; double-check there's no gap when escrow + adapter views diverge.

---

## How to use this list

1. Pick a row whose protocol kpk **actually uses or imminently will**.
2. Confirm the contract addresses, struct layouts, and finalization semantics by reading the protocol's source on GitHub + Etherscan (don't trust this doc for live values — it ages).
3. Mirror `StaderWithdrawalQueue.sol` (queue family) or whichever existing adapter is closest in shape.
4. Each adapter ships in its own PR with: contract + unit tests + fork test against a real holder + deploy-config entry (`script/config/contracts-deployment-config/balance-adapters/<chainId>.json` for plain adapters, or `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` for meta-adapters) + dispatch wiring in `04_DeployBalanceAdapters.s.sol` + a NAV-registration entry in the chain's `script/config/nav-config/balance-adapters/<chainId>.json` (plain) or `script/config/nav-config/meta-balance-adapters/<chainId>.json` (meta), which `06_Configure.s.sol` reads to register the adapter.
5. Update this file: cross off the row or add caveats discovered during implementation.

When a row turns out to be irrelevant (e.g. RPL queue, Coinbase off-chain unwrap), strike it through with a one-line reason rather than deleting — future contributors should see it was considered.
