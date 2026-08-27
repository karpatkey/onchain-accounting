# Balance-adapter coverage roadmap

> **PR #47 (meta-adapter framework):** Coverage was expanded significantly. A family of immutable meta-adapters now covers every instance of the protocol families below (Morpho Vaults/Markets, Aave V3, Balancer V3/V2 pools+gauges, Uniswap V2/V3, PancakeSwap V2/V3, Gearbox V3 markets, Compound V3, Fluid fTokens/Vaults, StakeWise V3, Curve pools+gauges, Convex, Euler V2 — the meta-adapter contracts live in `src/balances/MetaBalanceAdapters/`). The active instance set for each is governed on NAVCalculator via `addMetaInstances`/`removeMetaInstances` instead of deploying a contract per instance. Uniswap V3 and PancakeSwap V3 are **also** meta-adapters — their `NonfungiblePositionManager` is `ERC721Enumerable`, so an account's LP NFTs are enumerable on-chain (no off-chain assistant); see the DEX LP section below.

Living document. Tracks protocols and protocol features whose positions are **not yet** captured by NAVCalculator's balance adapters, with the goal of growing NAV coverage one PR at a time.

The Stader withdrawal-queue adapter (`src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol`) is the reference template for the **withdrawal-queue** family below: a single immutable adapter that enumerates an account's open requests on a protocol-specific manager and reports credit positions in the underlying asset under a static positionId, one leg per open request with `isLocked` set per request (ADR 0016). Most LST queues fit that shape with cosmetic differences in enumeration (sequential ID vs. ERC721 NFT) and request struct layout.

When picking the next protocol to add, prioritise by **whether kpk actually parks value there** rather than by protocol prominence — the catch-all `ERC20DefaultBalanceAdapter` already covers wallet ERC20 holdings, so a new adapter only earns its keep when there is value parked outside the wallet (a queue, a vault wrapper, a debt position).

The system does not track deprecated protocols — once a protocol is no longer in active use, its adapter, config, and identity entries are deleted rather than left in a permanently-disabled state. Aave V2 was removed for this reason (as were Aura and Sky Savings in recent PRs).

---

## LST/LRT withdrawal queues

The point of these adapters is to track value that has left the LST as ERC20 but hasn't yet returned as ETH/native. While in the queue the position is invisible to `ERC20DefaultBalanceAdapter`.

| Protocol | Manager (mainnet) | Shape | Notes |
|---|---|---|---|
| **Stader (ETHx)** ✅ | `0x9F0491B32DBce587c50c4C43AB303b06478193A7` | Sequential `requestId`, `requestIdsByUserAddress(address, idx)` getter, `userWithdrawRequests(id)` returns `(owner, ethXAmount, ethExpected, ethFinalized, requestBlock)`. `nextRequestIdToFinalize` gates claimability. | Implemented in this repo. |
| **Lido (stETH)** ✅ | `WithdrawalQueueERC721` at `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1` | ERC721. Enumerate via `getWithdrawalRequests(address) → uint256[]`. Per-id status via `getWithdrawalStatus(uint256[]) → WithdrawalRequestStatus[]` returning `amountOfStETH, amountOfShares, owner, timestamp, isFinalized, isClaimed`. | Implemented in this repo (`LidoWithdrawalQueueBalanceAdapter.sol`): reports open (un-claimed) requests as **native ETH** (the asset Lido pays on claim; priced ETH/USD) — finalized requests use exact claimable ETH (`getClaimableEther`), not-yet-finalized use the conservative min of `amountOfStETH` and the live share value (`getPooledEthByShares(amountOfShares)`). |
| **Lido stVaults (V3)** ✅ | `VaultHub` at `0x1d201BE093d847f6446530Efb0E8Fb426d176709` | Per-owner isolated `StakingVault`s. All views keyed on the VAULT: `totalValue`, `liabilityShares` (stETH SHARES), `obligations() → (sharesToBurn, feesToSettle)`, `vaultConnection(vault).owner`. Ownership is **`vaultConnection(vault).owner`, never `vault.owner()`** — on connection the vault's `Ownable` owner is transferred to VaultHub itself. `vaultByIndex` is **1-indexed** (`vaultByIndex(0)` reverts). | Implemented (`LidoStVaultsMetaBalanceAdapter.sol`, meta family, `protocolSubId = lido-stvaults`): three gross legs — `Staking` (`totalValue`, ETH sentinel), `Borrowed` (`liabilityShares` converted through `stETH.getPooledEthByShares`) and `Fees` (`feesToSettle` + the Dashboard's `accruedFee()`). **The `Fees` leg is not optional:** `totalValue` is gross of unsettled fees — measured 2026-08-27, `totalValue − maxLockableValue == feesToSettle` on 24/24 connected vaults — so reporting `totalValue` alone over-reports. Shipped **disabled**: no tracked account owned a stVault at authoring time. |
| **etherFi (eETH/weETH)** ✅ | `WithdrawRequestNFT` at `0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c` | ERC721, but **not** `ERC721Enumerable` and no owner→tokenIds view, so positions cannot be discovered from a pure-view read. An assistant submits the account's `tokenId`s; values are read live on-chain and ownership is re-verified per read. | Implemented in this repo as an **assisted** adapter (`EtherFiWithdrawalQueueAssistedBalanceAdapter.sol`, permissionless assistant-fed; ADR 0015/0018): caches ids only (never amounts) via `submit`, emits one native-ETH `Supplied` leg per owned request under a static `positionId = abi.encode(WithdrawRequestNFT)`, each leg's `isLocked` set by request state (finalized → `false`, pending → `true`); the WithdrawRequestNFT id rides in the typed `positionInstanceId`, never in `positionId`. |
| **Frax (frxETH/sfrxETH)** | `FraxEtherRedemptionQueue` at `0x82bA8da44Cd5261762e629dd5c605b17715727bd` | ERC721. `nftInformation(uint256)` returns the redemption metadata. | Reports ETH owed at maturity; uses `maturity` block, not finalization batches. |
| **Renzo (ezETH)** | `WithdrawQueue` at `0xf2F305D14DCD8aaef887E0428B3c9534795D0d60` | ERC721 with explicit `withdrawRequests` mapping; sequential IDs per holder. | Newer queue; finalization tied to Renzo restaking unwinds. |
| **Kelp (rsETH)** ✅ | `LRTWithdrawalManager` at `0x62De59c08eB5dAE4b7E6F7a8cAd3006d6965ec16` | Per-supported-asset deques: `userAssociatedNonces(asset, user) → (begin, end)` and `getUserWithdrawalRequest(asset, user, i) → (rsETHAmount, expectedAssetAmount, withdrawalStartBlock, userNonce)`. Payout-asset set discovered via `lrtConfig().getSupportedAssetList()` (stETH, ETHx, native ETH at time of writing). | Implemented in this repo (`KelpWithdrawalQueueBalanceAdapter.sol`): single multi-asset adapter; a static positionId `abi.encode(address withdrawalManager)` (payout asset carried in `balanceAsset.asset`); per NAV-registered payout asset, one leg per open request sharing it, each leg's claimability carried in its own `isLocked` (ADR 0016). |
| **Mantle (mETH)** | `Staking` contract; `unstakeRequest`/`claimUnstakeRequest` | Sequential `unstakeRequestId` per user; struct includes `mETHLocked`, `ethRequested`, `cumulativeETHRequested`, `blockNumber`. | Similar shape to Stader. |
| **StakeWise V3 exit queue** ✅ | per-Vault `enterExitQueue(shares)` returning a position ticket | `StakeWiseV3VaultsMetaBalanceAdapter.sol` covers active vault positions (`Staking` shares + `Borrowed` osToken legs); the exit queue is covered separately by `StakeWiseV3ExitQueueAssistedBalanceAdapter.sol` (permissionless assistant-fed, ADR 0018). | Implemented in this repo: per-vault static positionId `abi.encode(address vault)`, split into claimable (`exitedAssets`) + locked (`convertToAssets(leftShares)`) legs via `isLocked`. |
| **Rocket Pool (rETH)** — no adapter ✓ | n/a (rETH is a plain ERC20) | `RocketTokenRETH.burn()` pays ETH instantly from excess deposit-pool collateral, or **reverts** — there is no NFT / queue / pending-claim state for an adapter to read. | **No adapter needed (evaluated 2026-05).** rETH and RPL are registered, priced, and already wallet-covered by `ERC20DefaultBalanceAdapter` (rETH via `rETH_CustomPriceFeed`, RPL via Chainlink; the Merkl RPL-rewards adapter is currently removed pending a rewrite — see ADR 0007), so nothing to add for token holdings. The only *non-tokenized* Rocket Pool positions are node-operator ones — staked RPL collateral, minipool bonded ETH, RPL rewards (`RocketNodeStaking` / minipools) — which the funds do not hold. Revisit only if a fund takes on RP node-operator exposure. |
| **Coinbase (cbETH)** | n/a (centralised) | Off-chain wrap/unwrap. | No on-chain queue position. |

### Implementation notes (apply across the queue family)

- **Static positionId, per-leg claimable/locked flag (ADR 0016).** Use a static, timeless `positionId` (the queue/manager) — never a per-request id, and not the payout asset either, which already rides in `balanceAsset.asset` — and emit **one `PositionBalance` leg per open request**, all sharing it, each leg's state told by its own `isLocked` (`false` = claimable, `true` = pending/locked; a mutable per-leg attribute, NOT part of the identity key — legs sharing a key are summed). Per-request ids stay out of identity (they're ephemeral) — they ride in the typed `positionInstanceId`; per-request detail lives in the app. Single-asset queues (Stader, Lido, …) emit one leg per request; multi-asset queues that pay out in several underlyings (`KelpWithdrawalQueue`, which discovers stETH/ETHx/native-ETH at runtime) emit those per-request legs **per NAV-registered payout asset**. The StakeWise V3 exit queue is the one genuine two-leg case: a single ticket can be part-exited, so it splits into a claimable leg (`exitedAssets`) plus a locked one.
- **Claimed-entry handling.** Some managers `delete` storage on claim (Stader: `owner == address(0)` filter); ERC721-based ones burn the NFT (out of `tokenOfOwnerByIndex` automatically). Each adapter should explicitly skip claimed entries.
- **Do NOT cap the loop.** Read the account's full request set — never a `MAX_REQUESTS_PROBED`-style cap. A cap that skips (returns 0) or truncates a pathological account silently *under-reports a real, claimable balance*, and under NAVCalculator's **fail-open** per-adapter try/catch (`PriceFeedLib._getAdapterPositions`) that wrong-but-successful value gets consumed by the shares layer — strictly worse than the alternative. Without a cap, a griefed/self-inflicted large list at worst makes *that one account's* NAV read expensive, which degrades to an omitted leg or a fail-safe revert **for that account only** (NAV reads are off-chain `eth_call`, ADR 0017 — no atomic on-chain consumer, so burning gas on a failed read costs nothing and no other account is affected). See [`docs/operations/stader-withdrawal-queue-griefing.md`](../operations/stader-withdrawal-queue-griefing.md). (Historical: Stader/Lido/Kelp shipped with a 256/1000 cap; removed once the fail-open semantics made clear the cap only sacrificed correctness.)
- **Underlying token configurable.** Let the constructor take `underlyingToken_` so each chain config picks WETH or `NATIVE_ADDRESS` (ERC-7528) based on what the rest of the system reports. Mirror `StakeWiseV3VaultsMeta` and the Stader queue.
- **Pre-finalization vs. finalized amount.** Use `ethFinalized` once set (post-finalization, exact). Before finalization, take the **conservative min** of the rate-converted estimate the protocol stores at request time and a live re-conversion of the burned shares — `min(ethExpected, previewWithdraw(ethXAmount))` for Stader, `min(amountOfStETH, getPooledEthByShares(amountOfShares))` for Lido — so a rate drop after the request cannot leave a frozen estimate overstating what will be paid. Never invent a rate inside the adapter.

---

## Other position types not yet covered

These are not queues but represent value that lives outside the wallet and is not currently surfaced.

### Restaking / LRT primitives

- **EigenLayer**: native ETH and LST stake delegated to operators (`StrategyManager`, `DelegationManager`). Open queue: `withdrawalQueue` for delegated unstakes. Likely needed if any Alpha fund delegates to operators.
- **Symbiotic**: the ERC-4626 vault shape is COVERED by `SymbioticVaultsMetaBalanceAdapter` (PR #308). Still open: Symbiotic **CORE** vaults, which are epoch-based (`activeBalanceOf` + a withdrawal queue) and are NOT valued by that adapter, plus delegations.
- **Karak**: ditto.

### DEX LP / AMM positions

- **Balancer V3 pools + gauges**: ✅ covered — `BalancerV3PoolsMeta` + `BalancerV3GaugesMeta` (meta-adapters, ADR 0010).
- **Balancer V2 pools + gauges**: ✅ covered — `BalancerV2PoolsMeta` + `BalancerV2GaugesMeta` (meta-adapters, ADR 0010).
- **Uniswap V3**: ✅ covered — `UniswapV3PoolsMeta` (meta-adapter, ADR 0010; on-chain NFT enumeration via the `ERC721Enumerable` NonfungiblePositionManager).
- **Uniswap V2**: ✅ covered — `UniswapV2PoolsMeta` (meta-adapter, ADR 0010).
- **PancakeSwap V3**: ✅ covered — `PancakeSwapV3PoolsMeta` (meta-adapter, ADR 0010; subclass of `UniswapV3PoolsMeta` overriding the `uint32 feeProtocol` `_slot0` decode).
- **PancakeSwap V2**: ✅ covered — `PancakeSwapV2PoolsMeta` (meta-adapter, ADR 0010).
- **Curve pools + gauges**: ✅ covered — `CurvePoolsMeta` + `CurveGaugesMeta` (meta-adapters, ADR 0010).

### Liquid staking / restaking aggregators

- **StakeWise V3 vaults**: ✅ covered — `StakeWiseV3VaultsMeta` (meta-adapter, ADR 0010).

### Yield aggregator rewards

- **Convex**: ✅ covered — `ConvexCurveLPStakingMeta` (meta-adapter, ADR 0010).

### Yield / structured products

- **Pendle PT/YT**: principal-token (PT) and yield-token (YT) positions in markets and SY vaults. Each Pendle market issues distinct PT and YT ERC20s; the underlying value is non-trivial (PT depends on time-to-maturity, YT depends on accrued yield since last redemption). One adapter per market or per-LP.
- **Yearn V3 vaults**: pure ERC4626; would need a thin meta-adapter (the underlying value is `convertToAssets(balanceOf)`).
- **Beefy vaults**: ERC4626-shaped, same pattern.
- **Origin OETH/OUSD**: rebasing ERC20s — `ERC20DefaultBalanceAdapter` reports the current `balanceOf` correctly, but the rebasing semantic is worth a docs note.
- **Maple direct lending pools** (beyond syrupUSDC): pool tokens with withdrawal cooldowns.

### Money markets and credit

- **Morpho Vaults**: ✅ covered — `MorphoVaultsMeta` (meta-adapter, ADR 0010).
- **Morpho Markets**: ✅ covered — `MorphoMarketsMeta` (meta-adapter, ADR 0010).
- **Aave V3 (all instances)**: ✅ covered — `AaveV3InstancesMeta` (meta-adapter, ADR 0010).
- **Compound V3**: ✅ covered — `CompoundV3CometsMeta` (meta-adapter, ADR 0010).
- **Gearbox**: ✅ supply side covered — `GearboxV3MarketsMeta` (meta-adapter, ADR 0010; the passive ERC4626 pool LPs). The borrow side (collateral basket + debt held in Credit Accounts) has a contract — `GearboxV3CreditAccountsMetaBalanceAdapter` (instance coordinate = credit-account address) — but it is not yet wired into the deploy config.
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
3. Mirror `StaderWithdrawalQueueBalanceAdapter.sol` (queue family) or whichever existing adapter is closest in shape.
4. Each adapter ships in its own PR with: contract + unit tests + fork test against a real holder + deploy-config entry (`script/config/contracts-deployment-config/balance-adapters/<chainId>.json` for plain adapters, or `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` for meta-adapters) + dispatch wiring in `04_DeployBalanceAdapters.s.sol` + a NAV-registration entry in the chain's `script/config/nav-config/balance-adapters/<chainId>.json` (plain) or `script/config/nav-config/meta-balance-adapters/<chainId>.json` (meta), which `06_Configure.s.sol` reads to register the adapter.
5. Update this file: cross off the row or add caveats discovered during implementation.

When a row turns out to be irrelevant (e.g. RPL queue, Coinbase off-chain unwrap), strike it through with a one-line reason rather than deleting — future contributors should see it was considered.
