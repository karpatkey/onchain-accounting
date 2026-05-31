# Balance Adapters: Architecture and Integration

This document describes the balance oracle and adapter architecture: how NAV is computed from multiple balance sources, the data structures involved, existing adapters, and how to implement and register a new balance adapter.

---

## 1. Overview

The balance system powers **Net Asset Value (NAV)** calculation by aggregating positions from multiple **balance oracles**:

- **Balances (via NAVCalculator):** Holds a **global registry** of balance oracles and an **asset registry** (decimals, symbols). Assets are registered with a price feed so positions can be valued. Only registered assets contribute to NAV.
- **Balance adapters (oracles):** Contracts implementing `IBalanceOracleAdapter`. Each adapter reports **balance-only** positions (e.g. wallet ERC20/native, Compound supply/borrow, Aave positions) as `PositionBalance` structs—without pricing. One adapter is special: **ERC20DefaultOracle**, which is deployed and registered automatically at initialization and reports wallet ERC20 and native balances for all registered assets.
- **NAVCalculator:** Extends Prices and Balances. It iterates over all registered oracles, calls `getOraclePositions(account, assetFilter)` on each, filters positions by registered assets (and optional asset range), enriches them with prices (value = amount × price, with sign from `isDebt`), and aggregates into a single NAV.

So: **adapters only report balances; NAVCalculator adds prices and sums values.**

---

## 2. NAV flow: from account and quote asset to NAV

The diagram below shows how a call to `getAccountNav(account, quoteAsset)` (or the range-based variant) flows through oracles, filtering, and pricing to produce a single NAV value.

```mermaid
flowchart LR
    subgraph INPUT
        A[account]
        Q[quoteAsset]
    end

    subgraph NAV["NAVCalculator"]
        G[getAllOracles]
        L[Loop oracles]
        P[getOraclePositions(account, 0)]
        F[Filter: registered assets + range]
        E[Enrich: price × amount, isDebt sign]
        S[Sum → totalValue]
    end

    subgraph ORACLES["Balance oracles"]
        O1[ERC20Default]
        O2[CompoundV3]
        O3[Custom ...]
    end

    A --> G
    Q --> E
    G --> L
    L --> P
    P --> O1
    P --> O2
    P --> O3
    O1 --> |PositionBalance[]| F
    O2 --> |PositionBalance[]| F
    O3 --> |PositionBalance[]| F
    F --> E
    E --> S
    S --> NAV_OUT[NAV]
```

**Steps in code:**

1. **getAllOracles()** — Returns the global list of oracles (ERC20Default plus any custom oracles added via `addBalanceOracle`).
2. **For each oracle** — `adapter.getOraclePositions(account, address(0))` returns an array of `PositionBalance` (underlying asset, amount, isDebt, protocol, positionDetail). Unsupported oracles are skipped (try/catch).
3. **Filter** — Skip positions whose `underlyingAsset.asset` is not in the asset registry; for range-based APIs, keep only assets in the requested range.
4. **Enrich** — For each position: look up price (from Prices), compute USD value = amount × price (sign by `isDebt`: subtract for debt), then convert to quote asset if `quoteAsset != address(0)`.
5. **Aggregate** — Sum all position values → `totalValue`; build `NAV` (value, quoteAsset, timestamp, stale assets, sequencer down).

So balance adapters are **position sources**; they do not need to know about prices or quote assets.

---

## 3. Data structures

### 3.1 PositionBalance (balance-only, from oracles)

Defined in `INAVCalculator`. This is what every balance adapter returns.

| Field            | Type    | Description |
|------------------|--------|-------------|
| `underlyingAsset`| `Asset`| Asset (address, symbol, decimals). |
| `balanceOracle`  | `address` | The adapter that reported this position. |
| `amount`         | `uint256` | **Always positive.** Nominal amount in asset decimals. |
| `isDebt`         | `bool` | `true` = debt (subtract from NAV), `false` = credit (add to NAV). |
| `protocol`       | `string` | Stable top-level protocol name (e.g. `"wallet"`, `"Aave V3"`, `"Morpho"`). Pinned in the adapter's constructor as `_protocol`. |
| `positionDetail` | `string` | Fully-closed JSON object — required keys `protocol`, `product`; optional `type`, `token`. Adapters store a base string (no closing `}`) in `_positionDetail` and append the closing fragment at query time. Schema: [`docs/howto/position-detail-schema.md`](../../docs/howto/position-detail-schema.md). |
| `positionId`     | `string` | Stable hex identifier for this adapter instance — derived from the most-specific immutable address pinned by the constructor (vault, comet, gauge, marketId, …). Frontend uses it as a cross-block React key. |

**Credits-only oracles** (e.g. ERC20DefaultOracle, DaiDsr, AaveV3SafetyModule, StakeWiseV3OsToken, SkySavingsUsds) use `uint256` internally for balances and always report `isDebt: false`; they cast to `int256` only at the adapter interface boundary.

Pricing is **not** in this struct; NAVCalculator adds it when building full `Position` and NAV.

### 3.2 Asset

| Field     | Type     | Description |
|-----------|----------|-------------|
| `asset`   | `address`| Token address (or native convention, e.g. ERC-7528). |
| `symbol`  | `string` | Display symbol. |
| `decimals`| `uint8`  | Token decimals. |

Adapters should use the same `Asset` notion as the rest of the system; protocol adapters often take `NAVCalculator` in the constructor to resolve asset info (symbol, decimals) from the asset registry.

### 3.3 Position and NAV (enriched, from NAVCalculator)

- **Position:** Like `PositionBalance` plus `quoteAsset`, `value` (signed), `price`, `priceDecimals`, `stale`. This is the enriched form returned by NAVCalculator for per-position views.
- **NAV:** Total `value` in `quoteAsset`, `timestamp`, list of assets with stale prices, sequencer-down flag.

For building adapters, the only required output is **PositionBalance**; Position and NAV are computed by NAVCalculator.

---

## 4. Balances contract (oracle and asset registry)

`Balances` is an abstract contract used by NAVCalculator. It maintains:

- **Global oracle registry:** `_globalOracles[]`, `_oracleTypes[oracle]`, `_isOracleRegistered[oracle]`. All oracles are in one flat list (no per-asset mapping for registration).
- **Asset registry:** `_assetDecimals`, `_assetSymbols` (and enumeration). Set via `_registerAsset`; NAVCalculator exposes `registerAsset(asset, oracle, priceType, chainlinkHeartbeat)` (MANAGER) which registers the asset and sets the price feed.
- **ERC20DefaultOracle:** Set once in NAVCalculator’s `initialize()` via `_setErc20DefaultOracle(address)`. It is pushed into `_globalOracles` and marked `OracleType.Default`.

**Internal API (used by NAVCalculator):**

- `_addBalanceOracle(oracle)` — Checks `IBalanceOracleAdapter` via ERC165, pushes to `_globalOracles`, sets type `Custom`, prevents duplicates.
- `_removeBalanceOracle(oracle)` — Removes from global list (if present).
- `_registerAsset(asset, decimals)` — Adds to asset registry (decimals; symbol is set separately).
- `_setErc20DefaultOracle(defaultOracle)` — Sets and registers the default wallet oracle.

**Public / IBalances:** `getAllOracles()`, `getOracleCount()`, `isOracleRegistered()`, `getOracleType()`, `getOraclesForAsset(asset)` (oracles whose `underlyingAssetsSupported()` contains the asset), plus asset registry views: `isAssetRegistered`, `getAssets`, `getAssetCount`, `getAssetDecimals`, `getAssetSymbol`.

---

## 5. IBalanceOracleAdapter

Every balance oracle must implement this interface and ERC165.

| Method | Purpose |
|--------|--------|
| `getOraclePositions(account, assetFilter)` | Returns `PositionBalance[]` for the account. `assetFilter == address(0)` means all supported assets; otherwise only that asset (or empty). |
| `getOracleBalances(account)` | Returns `(assets[], amounts[], isDebt[])` — per-asset balance magnitudes and debt flags. Optional for NAV path but part of the interface. |
| `getOracleBalanceForAsset(account, asset)` | Net balance for one asset (gas-optimized). |
| `underlyingAssetsSupported()` | Returns `address[]` of underlying assets this oracle can report. Used by `getOraclesForAsset(asset)`. |
| `supportsInterface(interfaceId)` | Must return true for `IBalanceOracleAdapter.interfaceId` (and `IERC165.interfaceId`). |

**Semantics for NAV:**

- `amount` in `PositionBalance` is always **positive**; use `isDebt` to indicate whether it reduces NAV (debt) or adds to it (credit).
- Only positions whose `underlyingAsset.asset` is **registered** in the asset registry are included in NAV; adapters may still return unregistered assets (they will be filtered out).
- `balanceOracle` should be `address(this)` so NAVCalculator can attribute the position to the correct adapter.

---

## 6. How NAVCalculator uses oracles

- **getAccountNav(account, quoteAsset):** Resolves the full asset range, then calls `_readPositionsRangeWithQuote(account, 0, length-1, quoteAsset)`.
- **_readPositionsRangeWithQuote:**  
  - Builds the requested asset range from `getAssets()`.  
  - Calls `getAllOracles()`, then for each oracle: `getOraclePositions(account, address(0))` (with try/catch).  
  - Filters: keep only positions with `isAssetRegistered(asset)` and asset in the range.  
  - Fetches prices for all assets that appear in the filtered positions; marks stale.  
  - For each position: value = amount × price, sign by `isDebt`; sum to total USD then convert to quote asset if needed.  
  - Returns `(totalValue, stalePriceAssets, sequencerDown)` and NAV is built from that.

Other APIs (e.g. range NAV, positions for one asset) follow the same pattern: same oracle list, same `getOraclePositions`, with additional filtering (range or single asset).

### 6.1 Meta-adapters (multi-instance) — `IMetaBalanceOracleAdapter`

Most adapters pin a single instance (one vault, one pool, one market) in their constructor. A **meta-adapter** instead serves *every* instance of a protocol from one immutable contract, and the set of instances to actually query is held on **NAVCalculator** — not in the adapter. See [ADR 0010](../../docs/decisions/0010-meta-balance-adapters.md).

- **Interface:** `IMetaBalanceOracleAdapter` extends `IBalanceOracleAdapter` and adds `getOraclePositionsForInstances(account, bytes32[] instances, assetFilter)` and `underlyingAssetsSupportedForInstances(bytes32[])`. The instance coordinate is `bytes32` (an address widened to bytes32 for vault/pool/instance-address protocols; raw bytes32 for e.g. Morpho market ids).
- **Base:** `MetaBalanceOracle` (abstract) supplies ERC165, the per-instance fan-out (with per-instance revert isolation), and the registered-asset helper. Its `getOraclePositions(account, assetFilter)` reads the adapter's own NAV-configured set via `getMetaInstances(address(this))` and fans out. A concrete meta-adapter implements just `_instancePositions` and `_instanceAssets`.
- **Immutability preserved.** Meta-adapters have **no `Ownable`, no write functions** — they stay immutable like every other adapter. The mutable, governed instance set lives on NAVCalculator (UUPS-upgradeable, `MANAGER`-gated). No new mutable-adapter ADR is needed.
- **Identity is derived on-chain** per instance (e.g. `positionId` = vault address hex, `name` from `vault.name()`) — nothing instance-specific is stored in config.
- **NAVCalculator read path is unchanged.** NAV calls `getOraclePositions(account, assetFilter)` on every oracle uniformly; the meta-adapter pulls its own configured set inside that call, so there is no meta-specific branch in NAV (this also keeps `NAVCalculator` under the EIP-170 size limit).
- **Configuring the instance set:** `MANAGER` calls `setMetaInstances(oracle, bytes32[])` on NAVCalculator (full-list replace; the caller supplies a deduplicated, non-zero list). In deploy config, list the instances under `balanceAdapters.<name>.metaInstances` (address array, widened to bytes32 — for vault/pool-address adapters) or `metaInstancesRaw` (raw bytes32 — for marketId-keyed adapters like `MorphoMarketsMeta`); `06_Configure` and the integration harness emit the `setMetaInstances` Safe TX automatically from either.

---

## 7. Implemented adapters

| Adapter | Description | Protocol string / notes |
|---------|-------------|-------------------------|
| **ERC20DefaultOracle** | Wallet ERC20 and native balances for all registered assets. | `"wallet"`, positionDetail `"Holding"`. Auto-registered at init. |
| **AaveV2Instance** | Aave V2 lending positions (supply/collateral/borrow) for one market via V2 ProtocolDataProvider. Thin subclass of `AaveV3InstanceBalanceOracle`. | Protocol `"Aave V2"`, product `"Lending"`. Stable-debt positions not reported (governance-disabled). Mainnet only. |
| **AaveV3Instance** | Aave V3 lending positions (supply/collateral/borrow) for one market via V3 ProtocolDataProvider. Discovers all reserves dynamically; emits two legs per reserve (supply/collateral + borrow). | Protocol `"Aave V3"`, product `"Lending"`. `positionId` = Pool address. |
| **AaveV3SafetyModule** | Aave V3 Safety Module stake tokens (stkAAVE, stkABPT, stkABPTv2, stkGHO). Stake-token set hardcoded at construction; two legs per token (Staking + Rewards). | Protocol `"Aave V3"`, product `"Safety Module"`. DeBank reports stkAAVE under `aave2`, not `aave3`. |
| **AaveUmbrella** | Aave Umbrella stake tokens discovered dynamically via `RewardsController.getAllAssets()`. Two legs per token (Staking + Rewards) denominated in the bare reserve. | Protocol `"Aave V3"`, product `"Umbrella"`. Picks up new stake tokens via governance without redeploy. See `docs/decisions/0006-aave-umbrella-balance-oracle.md`. |
| **Aura** | Aura gauge staked LP + claimable BAL/AURA rewards. | |
| **BalancerV3PoolsMeta** | **Meta-adapter** (§6.1): one immutable contract for the **wallet-held (unstaked) LP** of *all* Balancer V3 pools. The instance coordinate is the **pool/BPT address**. Emits one `Supply` leg per underlying pool token (wallet BPT share). Identity derived on-chain (positionId = pool address, name = BPT `name()`). | Constructor: `(protocol, navCalculator)`. Chain config key: `BalancerV3PoolsMeta`; pools under `metaInstances`. Splits the legacy `BalancerV3` adapter. See ADR 0010. |
| **BalancerV3GaugesMeta** | **Meta-adapter** (§6.1): one immutable contract for the **gauge-staked LP + rewards** of *all* Balancer V3 gauges. The instance coordinate is the **gauge address**. Emits one `Staking` leg per underlying pool token (staked BPT share) plus `Rewards` legs (BAL via the minter + extra gauge reward tokens). Identity derived on-chain (positionId = gauge address, name = the gauge's `lp_token()` BPT `name()`). | Constructor: `(balancerMinter, protocol, navCalculator)`. Chain config key: `BalancerV3GaugesMeta`; gauges under `metaInstances`. Splits the legacy `BalancerV3` adapter. See ADR 0010. |
| **BalancerV3** | _Superseded by `BalancerV3PoolsMeta` + `BalancerV3GaugesMeta` (ADR 0010); per-pool deploys disabled in chain config._ Balancer V3 pool LP. Emits two legs per asset: `Supply` (unstaked wallet LP) and `Staking` (gauge-staked LP + gauge rewards). | |
| **Cap** | Cap protocol cUSD + stcUSD balances, aggregated and reported as USDC. | |
| **CompoundV3Comet** | Compound V3 Comet: base supply/borrow, collaterals, COMP rewards. | Constructor: protocol string (e.g. `"Compound v3 USDC"`). Uses NAVCalculator for asset metadata. |
| **Convex** | Convex staking rewards (CRV, CVX, extras) for one gauge. | |
| **Curve** | Curve gauge LP. Emits two legs per asset: `Supply` (unstaked wallet LP) and `Staking` (gauge-staked LP + gauge rewards). | |
| **DaiDsr** | DAI Savings Rate. | |
| **ERC4626Wrap** | Generic ERC-4626 wrap balance oracle. Reports `convertToAssets(balanceOf(account))` denominated in `wrapper.asset()`. Constructor reverts if `asset()` is not NAV-registered. Used for Aave V3 stata-tokens (`waEth*` family) and any other thin ERC-4626 wrapper whose share price is derivable from `convertToAssets`. | Per-instance constructor sets protocol/product/name. `positionId` = wrapper address. Chain config key prefix: `ERC4626Wrap_`. |
| **FluidFToken** | Fluid fToken (ERC4626 lending vault) — converts shares to underlying via `convertToAssets`. | |
| **FluidVault** | Fluid Smart Vault — reports collateral and debt legs per vault. | |
| **GearboxMarket** | Gearbox passive lending pool dToken balance. | |
| **KelpWithdrawalQueue** | Kelp DAO rsETH exit queue (`LRTWithdrawalManager`). Sums each account's open requests' `expectedAssetAmount` per payout asset and emits one credit position per asset. Payout-asset set discovered at runtime via `lrtConfig().getSupportedAssetList()` (stETH, ETHx, native ETH); positions emitted only for NAV-registered assets. | Mainnet only. Constructor: `(withdrawalManager, protocol, positionDetail, positionId, navCalculator)`. Protocol `"Kelp"`, product `"Staking"`, name `"rsETH Withdrawal Queue"`. |
| **LidoWithdrawalQueue** | Lido `WithdrawalQueueERC721`. Reports an account's open (un-claimed) withdrawal requests — enumerated via `getWithdrawalRequests` + `getWithdrawalStatus` — as a single **native-ETH** credit (Lido pays ETH on claim; priced ETH/USD, so a stETH depeg can't mis-value the claim). Per request: **finalized** → exact claimable ETH (`getClaimableEther`, since finalization can lock in less than `amountOfStETH` after a negative rebase); **not yet finalized** → `amountOfStETH` (rate not fixed; equals the ETH paid in the normal case). | Mainnet only. Constructor: `(withdrawalQueue, underlyingToken /* native ETH */, protocol, positionDetail, positionId, navCalculator)`. Protocol `"Lido"`, product `"Staking"`, name `"stETH Withdrawal Queue"`. |
| **MerklRewards** | Merkl (Angle Labs) **unclaimed** rewards via on-chain proof verification. | Mutable per-(user, token) cache, `onlyOwner` writes, proofs verified against the live Distributor root. The framework's documented mutable-adapter exception. See `docs/decisions/0007-merkl-trust-minimized-cache.md`. |
| **MorphoMarket** | Morpho market positions emitted **gross** by `getOraclePositions`: up to 3 rows per call — collateral, loan-token supply (`isDebt=false`), loan-token borrow (`isDebt=true`) — each guarded by `> 0`. Same `(positionDetail.type ∈ {Supply, Borrow, Collateral})` discriminators. Simple getters `getOracleBalanceForAsset` / `getOracleBalances` keep netting the loan token (one signed entry per asset), matching Aave V2/V3's simple-getter convention. `positionId` derived automatically from `marketId` via `Strings.toHexString` — no separate constructor param needed. | |
| **MorphoVault** | Morpho ERC4626 vault (MetaMorpho) share balance converted to underlying. One adapter per vault. | |
| **MorphoVaultsMeta** | **Meta-adapter** (§6.1): one immutable contract for *all* Morpho ERC4626 vaults. Active vault set configured on NAVCalculator via `setMetaInstances`. Identity derived on-chain (positionId = vault address, name = `vault.name()`). | Constructor: `(protocol, navCalculator)`. Chain config key: `MorphoVaultsMeta`; vaults under `metaInstances`. See `docs/decisions/0010-meta-balance-adapters.md`. |
| **MorphoMarketsMeta** | **Meta-adapter** (§6.1): one immutable contract for *all* Morpho Blue markets. The instance coordinate is the **`bytes32` marketId** (used directly). Emits up to 3 gross rows per market (Collateral/Supply/Borrow), same shape as `MorphoMarket`. Identity derived on-chain (positionId = marketId hex, name = `collateralSym/loanSym`). | Constructor: `(morpho, protocol, navCalculator)`. Chain config key: `MorphoMarketsMeta`; marketIds under `metaInstancesRaw` (raw bytes32, not addresses). See ADR 0010. |
| **AaveV3InstancesMeta** | **Meta-adapter** (§6.1): one immutable contract for *all* Aave V3 instances (Core, Prime, …). The instance coordinate is the instance's **ProtocolDataProvider address**; reserves are enumerated trustlessly inside each instance (not separate coordinates). Emits up to 2 rows per reserve (Supply/Collateral + Borrow), same shape as `AaveV3Instance`. Identity derived on-chain (positionId = instance Pool via `getPool()`, name = `getMarketId()`). | Constructor: `(protocol, navCalculator)`. Chain config key: `AaveV3InstancesMeta`; DataProviders under `metaInstances`. See ADR 0010. |
| **SkySavingsUsds** | Sky savings USDS. | |
| **SparkLend** | Spark lending positions (subclass of AaveV3Instance). | |
| **StakeWiseV3OsToken** | StakeWise V3 osToken wallet balance converted to underlying via `OsTokenVaultController.convertToAssets`. Same contract serves osETH (Mainnet) and osGNO (Gnosis). | Mainnet: `StakeWiseV3OsToken_ETH` (osETH → ETH-sentinel). |
| **StakeWiseV3VaultsMeta** | **Meta-adapter** (§6.1): one immutable contract for *all* StakeWise V3 vaults. Emits two legs per vault — `Staking` (vault shares → assets) and `Borrow` (osToken debt → assets) — denominated in the chain's underlying staking asset. Instance coordinate = **vault address**; the underlying token is pinned in the constructor (chain-level constant). Identity derived on-chain (positionId = vault address, name = vault `name()`). | Constructor: `(underlyingToken, protocol, navCalculator)`. Chain config key: `StakeWiseV3VaultsMeta`; vaults under `metaInstances`. Supersedes the per-vault `StakeWiseV3Vault`. See ADR 0010. |
| **StakeWiseV3Vault** | _Superseded by `StakeWiseV3VaultsMeta` (ADR 0010); per-vault deploys disabled in chain config._ StakeWise V3 vault. `getOraclePositions` emits two legs: `Staking` (vault shares → assets) and `Borrow` (osToken debt → assets). `getOracleBalances`/`getOracleBalanceForAsset` return the signed net for backward compat. | One adapter per vault. |
| **StaderWithdrawalQueue** | Stader UserWithdrawalManager pending unstake requests; reports the sum of `ethFinalized` (or `ethExpected` pre-finalization) for an account's open requests as a single underlying-token credit. | Mainnet only; underlying configured to WETH. |
| **UniswapV3PoolsMeta** | **Meta-adapter** (§6.1): one immutable contract for the LP of *all* Uniswap V3 pools — `Supply` (in-range liquidity) + `Fees` (unclaimed) legs across the account's NFT positions. Instance coordinate = **pool address**; the NonfungiblePositionManager is pinned in the constructor (chain-level constant). Identity derived on-chain (positionId = pool address, name = `sym0/sym1 feeTier`). Per-pool NFT scan bounded at 256. | Constructor: `(positionManager, protocol, navCalculator)`. Chain config key: `UniswapV3PoolsMeta`; pools under `metaInstances`. Splits the per-pool `UniswapV3Pool` adapter. Math via `UniswapV3PoolLib` (GPL-2.0, ADR 0008). See ADR 0010. |
| **UniswapV2PoolsMeta** | **Meta-adapter** (§6.1): one immutable contract for the LP of *all* Uniswap V2 pairs — one `Supply` leg per token (dilution-adjusted pro-rata reserves). Instance coordinate = **pair address**. Also serves SushiSwap/PancakeSwap V2 forks. Identity derived on-chain (positionId = pair address, name = `sym0/sym1 LP`). | Constructor: `(protocol, navCalculator)`. Chain config key: `UniswapV2PoolsMeta`; pairs under `metaInstances`. Math via `UniswapV2PairLib`. See ADR 0010. |
| **PancakeSwapV3PoolsMeta** | **Meta-adapter** (§6.1): subclass of `UniswapV3PoolsMeta` overriding the `slot0` read for PancakeSwap V3's `uint32 feeProtocol`. Own NonfungiblePositionManager. | Constructor: `(positionManager, protocol, navCalculator)`. Chain config key: `PancakeSwapV3PoolsMeta`. See ADR 0010. |
| **PancakeSwapV2PoolsMeta** | **Meta-adapter** (§6.1): thin subclass of `UniswapV2PoolsMeta` (PancakeSwap V2 is a byte-for-byte V2 fork). | Constructor: `(protocol, navCalculator)`. Chain config key: `PancakeSwapV2PoolsMeta`. See ADR 0010. |
| **UniswapV2** | _Superseded by `UniswapV2PoolsMeta` (ADR 0010)._ Uniswap V2 pair LP — pro-rata share of token0/token1 reserves, dilution-adjusted for the pending protocol-fee mint. No rewards (V2 swap fees auto-compound into reserves). One adapter per pair. | Constructor: `(pair, protocol, positionDetail, positionId, navCalculator)`. |
| **UniswapV3Pool** | _Superseded by `UniswapV3PoolsMeta` (ADR 0010); per-pool deploys disabled in chain config._ Uniswap V3 concentrated-liquidity LP — principal amounts derivable from `liquidity` at the current pool price, plus unclaimed fees, across all of the account's NFTs in this pool. One adapter per pool. | Constructor: `(pool, positionManager, protocol, positionDetail, positionId, navCalculator)`. Chain config key prefix: `UniswapV3_`. |

Protocol adapters typically take a **NAVCalculator** (or equivalent) in the constructor to read the asset registry (and sometimes symbols/decimals) so they can build correct `Asset` and only report registered assets if desired.

---

## 8. How to create a new adapter

### 8.1 Contract layout

1. Create a contract that implements `IBalanceOracleAdapter` and `IERC165`.
2. Add immutable (or storage) state for protocol contracts and, if needed, a reference to `NAVCalculator` for asset metadata.
3. Implement **`getOraclePositions(address account, address assetFilter)`**:
   - Query the protocol for the account’s positions (supply, borrow, stakes, etc.).
   - For each position: build `PositionBalance` with:
     - `underlyingAsset`: use `Asset` from NAVCalculator’s registry if you have it, or build from token address + symbol/decimals (must match registry for filtering).
     - `balanceOracle`: `address(this)`.
     - `amount`: positive `uint256` in asset decimals.
     - `isDebt`: `true` for borrows/debts, `false` for collateral/supply/claims.
     - `protocol`: emit `_protocol` from the constructor-pinned field (e.g. `"Aave V3"`, `"Morpho"`).
     - `positionDetail`: emit `string.concat(_positionDetail, "}")` for single-type adapters, or `PositionType.withType(_positionDetail, PositionType.<CONSTANT>)` (from `src/utils/PositionType.sol`) for multi-leg adapters. Per-adapter examples in [`docs/howto/position-detail-schema.md`](../../docs/howto/position-detail-schema.md) §4.
     - `positionId`: emit `_positionId` from the constructor-pinned field (hex string of the adapter's most-specific anchor address).
   - If `assetFilter != address(0)`, return only positions for that asset (or empty).
   - You may return only assets that are registered in NAVCalculator (like ERC20DefaultOracle) to avoid unnecessary work; unregistered positions are dropped by NAVCalculator anyway.
4. Implement **`getOracleBalances`** and **`getOracleBalanceForAsset`** (per-asset amounts and debt flags). Return `(assets[], amounts[], isDebt[])` from `getOracleBalances` and `(amount, isDebt)` from `getOracleBalanceForAsset`. Iterate over all `underlyingAssetsSupported()` and include only non-zero amounts. These can derive from the same data as `getOraclePositions` or be implemented with a simpler path.
5. Implement **`underlyingAssetsSupported()`**: return the list of underlying token addresses this oracle can report (e.g. base + collaterals + reward token for a Comet).
6. Implement **`supportsInterface(bytes4)`**: return `true` for `type(IBalanceOracleAdapter).interfaceId` and `type(IERC165).interfaceId`.

### 8.2 Dependencies

- **NAVCalculator:** Optional but recommended for protocol adapters. Use it to:
  - Resolve `Asset` (symbol, decimals) for tokens so `PositionBalance.underlyingAsset` is consistent.
  - Optionally restrict reported assets to `NAV_CALCULATOR.assets()` so you only return positions that will be used.
- **ERC20DefaultOracle** uses NAVCalculator for both: it only reports registered assets and gets `Asset` from the registry.

### 8.3 Testing and upgradeability

- Reuse shared errors and constants from `src/errors.sol` and `src/constants.sol` where applicable.
- Protocol adapters are often immutable (no proxy); if you use a proxy, follow the project’s initializer and `_disableInitializers()` pattern.

---

## 9. How to configure and use balance adapters

### 9.1 Asset registration

- Assets (and their price feeds) are registered on **NAVCalculator**, which extends Balances and Prices.
- Call **`NAVCalculator.registerAsset(asset, oracle, priceType, chainlinkHeartbeat)`** (requires **MANAGER**). This registers the asset in the asset registry and sets the price feed. Only registered assets are included in NAV and in the default oracle’s “registered assets” list.
- Use the chain’s native token address convention (e.g. ERC-7528 `NATIVE_ADDRESS`) for the native asset; register it like any other asset with a price feed.

### 9.2 Default oracle (no extra config)

- **ERC20DefaultOracle** is deployed and registered automatically in **`NAVCalculator.initialize(...)`**. It reports wallet ERC20 and native balances for all assets returned by `NAVCalculator.assets()`. No additional registration step.

### 9.3 Adding custom oracles

1. Deploy your adapter (e.g. CompoundV3Comet, AaveV3Instance), passing constructor args (protocol addresses, optional NAVCalculator).
2. As an account with **MANAGER** on NAVCalculator, call **`NAVCalculator.addBalanceOracle(adapter)`**. This runs `checkBalanceOracleSupport(adapter)` (ERC165 for `IBalanceOracleAdapter`) and adds the adapter to the global oracle list.
3. Ensure every asset your adapter reports is already registered via `registerAsset` (with a price feed); otherwise those positions will be filtered out when computing NAV.

### 9.4 Computing NAV

- Call **`NAVCalculator.getAccountNav(account, quoteAsset)`** to get the full NAV for the account in the given quote asset (`address(0)` for USD).
- Range-based APIs (e.g. `getAccountNavForRange`) use the same oracles and the same flow, restricted to an asset index range for gas control.

No per-oracle “enable for this asset” step is required: all registered oracles are queried for every NAV call; filtering is by **registered assets** (and optional range) on the NAVCalculator side.
