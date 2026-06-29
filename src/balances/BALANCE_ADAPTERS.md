# Balance Adapters: Architecture and Integration

This document describes the balance adapter architecture: how NAV is computed from multiple balance adapters, the data structures involved, existing adapters, and how to implement and register a new balance adapter.

---

## 1. Overview

The balance system powers **Net Asset Value (NAV)** calculation by aggregating positions from multiple **balance adapters**:

- **Balances (via NAVCalculator):** Holds a **global registry** of balance adapters and an **asset registry** (decimals, symbols). Assets are registered with a price feed so positions can be valued. Only registered assets contribute to NAV.
- **Balance adapters:** Contracts implementing `IBalanceAdapter`. Each adapter reports **balance-only** positions (e.g. wallet ERC20/native, Compound supply/borrow, Aave positions) as `PositionBalance` structs — without pricing. One adapter is special: **ERC20DefaultBalanceAdapter**, which is deployed and registered automatically at initialization and reports wallet ERC20 and native balances for all registered assets.
- **NAVCalculator:** Extends Prices and Balances. It iterates over all registered adapters, calls `getAdapterPositions(account, assetFilter)` on each, filters positions by registered assets, enriches them with prices (value = amount × price, with sign from `isDebt`), and aggregates into a single NAV.

So: **adapters only report balances; NAVCalculator adds prices and sums values.**

---

## 2. NAV flow: from account and quote asset to NAV

The diagram below shows how a call to `getAccountNav(account, quoteAsset)` flows through adapters, filtering, and pricing to produce a single NAV value.

```mermaid
flowchart LR
    subgraph INPUT
        A[account]
        Q[quoteAsset]
    end

    subgraph NAV["NAVCalculator"]
        G[getAllAdapters]
        L[Loop adapters]
        P["getAdapterPositions(account, 0)"]
        F[Filter: registered assets]
        E[Enrich: price × amount, isDebt sign]
        S[Sum → totalValue]
    end

    subgraph ADAPTERS["Balance adapters"]
        O1[ERC20Default]
        O2[CompoundV3CometsMeta]
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

1. **getAllAdapters()** — Returns the global list of adapters (ERC20Default plus any custom adapters added via `addBalanceAdapters`, and any meta-adapters added via `addMetaBalanceAdapter`).
2. **For each adapter** — `adapter.getAdapterPositions(account, address(0))` returns an array of `PositionBalance` (balance asset, amount, isDebt, protocolId, positionId, positionKind, isLocked). Unsupported adapters are skipped (try/catch).
3. **Filter** — Skip positions whose `balanceAsset.asset` is not in the asset registry.
4. **Enrich** — For each position: look up price (from Prices), compute USD value = amount × price (sign by `isDebt`: subtract for debt), then convert to quote asset if `quoteAsset != address(0)`.
5. **Aggregate** — Sum all position values → `totalValue`; build `NAV` (value, quoteAsset, timestamp, stale assets, sequencer down).

So balance adapters are **position sources**; they do not need to know about prices or quote assets.

---

## 3. Data structures

### 3.1 PositionBalance (balance-only, from adapters)

Defined in `INAVCalculator`. This is what every balance adapter returns.

| Field           | Type          | Description |
|-----------------|---------------|-------------|
| `balanceAsset`  | `Asset`       | Asset (address, symbol, decimals). The token `amount` is denominated in. |
| `balanceAdapter` | `address`     | The adapter that reported this position. Provenance/audit trail — NOT part of identity. |
| `amount`        | `uint256`     | **Always positive.** Nominal amount in asset decimals. |
| `isDebt`        | `bool`        | `true` = debt (subtract from NAV), `false` = credit (add to NAV). Canonical NAV-sign signal. |
| `protocolId`    | `bytes32`     | `keccak256` of a canonical protocol slug (see `src/utils/ProtocolIds.sol`). Selects the `positionId` ABI-decode schema — one slug implies exactly one schema. |
| `positionId`    | `bytes`       | `abi.encode(...)` of the position's **static, timeless** key. Decode schema is determined by `protocolId`. e.g. for `aave-v3-lending`: `abi.encode(address pool)`. Withdrawal-queue / cooldown adapters use a static coordinate (queue / manager / vault / sUSDe) — never a per-request id; the owed/payout asset is in `balanceAsset`. The queues emit **one leg per open request** (and the NFT adapters one leg per NFT) all sharing this static positionId, with the ephemeral per-item id in `labels`; such legs share the full reconciliation key and must be **summed, not deduplicated**. Full schema table: `src/utils/ProtocolIds.sol` and `docs/howto/position-identity-schema.md`. |
| `positionKind`  | `PositionKind`| Semantic discriminator: `Wallet` / `Supplied` / `Borrowed` / `Collateral` / `Staking` / `Rewards` / `Fees`. See `src/utils/PositionKind.sol`. |
| `isLocked`      | `bool`        | `true` = not withdrawable now (a pending withdrawal request, OR an active/cooling stake); `false` = withdrawable now. "Partial = locked". Uniform rule: `isLocked = non-withdrawable` — active stake (Aave SM, Umbrella) needs a cooldown first, so it is locked; only an in-window elapsed cooldown is unlocked. **Part of the identity key** — the two legs share one static `positionId`, so `isLocked` is what keeps them distinct. `false` for all non-queue/non-cooldown/non-staking-with-cooldown adapters. See ADR 0016. |
| `labels`        | `string[]`    | Adapter-filled display hierarchy below `protocolName` (leaf last), derived on-chain (ERC20 symbols, vault/pool names, etc.). **Every adapter fills this directly** — it is the single label mechanism (there is no `positionLabels` method, no fallback); the verbose reads surface it verbatim. May carry per-leg data not recoverable from `positionId` alone — e.g. the NFT id of a Uniswap V3 / Nexus position whose `positionId` is the pool address. **Display only; never part of identity.** |

The stable per-chain identity key for caching and reconciliation is `(chainId, protocolId, positionId, balanceAsset.asset, positionKind, isLocked)`. `balanceAdapter` is excluded — redeploying an adapter doesn't change the position; `isDebt` is excluded — it is the canonical NAV-sign field, read directly (do **not** infer it from `positionKind`). The key identifies a position **group**: the per-request withdrawal-queue adapters and the per-NFT adapters emit multiple legs sharing one key (differing only in the display `labels`), so reconcile by **summing** amounts across legs with the same key — never upsert/deduplicate by it.

**Credits-only adapters** (e.g. ERC20DefaultBalanceAdapter, AaveV3SafetyModule) always report `isDebt: false`.

Pricing is **not** in this struct; NAVCalculator adds it when building full `Position` and NAV.

### 3.2 PositionKind

Defined in `src/utils/PositionKind.sol`.

| Value         | Meaning |
|---------------|---------|
| `Wallet`      | Plain ERC20 / native-token balance held directly (ERC20DefaultBalanceAdapter). |
| `Supplied`    | Credit deployed into a protocol: lending supply, vault shares, unstaked LP principal. |
| `Borrowed`    | Debt owed to a protocol (`isDebt = true`). |
| `Collateral`  | Credit locked as collateral (e.g. Aave reserve with `usageAsCollateralEnabled = true`). Distinct from `Supplied` because it cannot be freely withdrawn. |
| `Staking`     | Principal locked behind an unstake action (Safety Module, Umbrella, StakeWise vaults, gauge/Convex-staked LP). The kind reflects the outermost action family; the inner exposure stays recoverable from `protocolId`/`positionId`. |
| `Rewards`     | Accrued but not yet claimed reward tokens (CRV, CVX, BAL, …). |
| `Fees`        | Uncollected protocol or LP fees (e.g. Uniswap V3 position fees). |

### 3.3 Asset

| Field     | Type      | Description |
|-----------|-----------|-------------|
| `asset`   | `address` | Token address (or native convention, e.g. ERC-7528). |
| `symbol`  | `string`  | Display symbol. |
| `decimals`| `uint8`   | Token decimals. |

Adapters should use the same `Asset` notion as the rest of the system; protocol adapters often take `NAVCalculator` in the constructor to resolve asset info (symbol, decimals) from the asset registry.

### 3.4 Position and NAV (enriched, from NAVCalculator)

- **Position:** Like `PositionBalance` plus `quoteAsset`, `value` (signed), `price`, `priceDecimals`, `stale`. This is the enriched form returned by NAVCalculator for per-position views.
- **VerbosePosition:** Wraps `Position` with a `protocolName` string (from `IPositionDescribable`) and a `labels` **string array** (an ordered hierarchy below the protocol, leaf last — e.g. `["Market", "wstETH/USDC"]`). `labels` is the adapter-filled `PositionBalance.labels` surfaced verbatim — every adapter fills it directly (e.g. Uniswap V3 / Nexus encode the pool in `positionId` and put the NFT id in the last label). The full breadcrumb is `[protocolName, ...labels]`. For display only — never use for identity or indexing.
- **NAV:** Total `value` in `quoteAsset`, `timestamp`, list of assets with stale prices, sequencer-down flag.

For building adapters, the only required output is **PositionBalance**; Position and NAV are computed by NAVCalculator.

---

## 4. Balances contract (adapter and asset registry)

`Balances` is an abstract contract used by NAVCalculator. It maintains the **adapter registry** (the asset registry lives in NAVCalculator, not here):

- **Global adapter registry:** `_globalAdapters[]`, `_adapterTypes[adapter]`, `_isAdapterRegistered[adapter]`. All adapters are in one flat list (no per-asset mapping for registration).
- **Meta-adapter instance registry:** `_metaInstances[adapter]` — the per-adapter `bytes32[]` of instance coordinates a meta-adapter queries, plus the running total `_metaInstanceTotal`. See §6.1.
- **ERC20DefaultBalanceAdapter:** Set once in NAVCalculator's `initialize()` via `_setErc20DefaultBalanceAdapter(address)`. It is pushed into `_globalAdapters` and marked `AdapterType.Default`.

The **asset registry** (decimals, symbols) lives on **NAVCalculator** (`_registeredAssets`, `_assetIndex`), not on `Balances`. NAVCalculator exposes `registerAsset(asset, priceFeed, priceType, chainlinkHeartbeat)` (MANAGER), which registers the asset and sets its price feed.

**Internal API (used by NAVCalculator):**

- `_addBalanceAdapters(adapters)` — Batch-registers non-meta adapters: checks `IBalanceAdapter` via ERC165, rejects meta-adapters (`MetaAdapterNotAllowed`), pushes to `_globalAdapters`, sets type `Custom`, prevents duplicates. The storage mutation is delegated to `NAVRegistryLib.addBalanceAdapters`. Wrapped by the external `addBalanceAdapters(address[])` (MANAGER). (`_addBalanceAdapter(adapter)` is a single-adapter variant retained for the test harness.)
- `_addMetaBalanceAdapter(adapter, instances)` — Registers a meta-adapter and seeds its instance set atomically; wrapped by the external `addMetaBalanceAdapter(address, bytes32[])`.
- `_removeBalanceAdapters(adapters)` — Removes from the global list; wrapped by the external `removeBalanceAdapters(address[])`.
- `_addMetaInstances(adapter, instances)` / `_removeMetaInstances(adapter, instances)` — Mutate a meta-adapter's instance set; wrapped by the external `addMetaInstances` / `removeMetaInstances`.
- `_setErc20DefaultBalanceAdapter(defaultAdapter)` — Sets and registers the default wallet adapter.

**Public / IBalances:** `getAllAdapters()`, `getAdapterCount()`, `isAdapterRegistered()`, `getAdapterType()`, `getAdaptersForAsset(asset)` (adapters whose `underlyingAssetsSupported()` contains the asset), and `getMetaInstances(adapter)`. Asset registry views (`isAssetRegistered`, `getRegisteredAssets`, `getAssetCount`) live on NAVCalculator / `INAVCalculator`.

---

## 5. IBalanceAdapter

Every balance adapter must implement this interface and ERC165.

| Method | Purpose |
|--------|---------|
| `getAdapterPositions(account, assetFilter)` | Returns `PositionBalance[]` for the account. `assetFilter == address(0)` means all supported assets; otherwise only that asset (or empty). |
| `getAdapterBalances(account)` | Returns `(assets[], amounts[], isDebt[])` — per-asset balance magnitudes and debt flags. Optional for NAV path but part of the interface. |
| `getAdapterBalanceForAsset(account, asset)` | Net balance for one asset (gas-optimized). |
| `underlyingAssetsSupported()` | Returns `address[]` of underlying assets this adapter can report. Used by `getAdaptersForAsset(asset)`. |
| `supportsInterface(interfaceId)` | Must return true for `IBalanceAdapter.interfaceId` (and `IERC165.interfaceId`). |

**Semantics for NAV:**

- `amount` in `PositionBalance` is always **positive**; use `isDebt` to indicate whether it reduces NAV (debt) or adds to it (credit).
- Only positions whose `balanceAsset.asset` is **registered** in the asset registry are included in NAV; adapters may still return unregistered assets (they will be filtered out).
- `balanceAdapter` should be `address(this)` so NAVCalculator can attribute the position to the correct adapter.

---

## 6. How NAVCalculator uses adapters

- **getAccountNav(account, quoteAsset):** Validates the quote asset, computes sequencer status, then delegates the whole read/compute path to `PriceFeedLib.computeNav(...)` (passing the price-oracle/registry storage refs, `getAllAdapters()`, `_metaInstanceTotal`, and the native-token symbol). The read/compute engine lives in `PriceFeedLib` to keep `NAVCalculator` under EIP-170 — see [ADR 0010](../../docs/decisions/0010-meta-balance-adapters.md). `computeNav`:
  - For each adapter in `getAllAdapters()`: `getAdapterPositions(account, address(0))` (with try/catch).
  - Filters: keep only positions with a registered asset.
  - Fetches prices for all assets that appear in the filtered positions; marks stale.
  - For each position: value = amount × price, sign by `isDebt`; sum to total USD then convert to quote asset if needed.
  - Returns the full `NAV` (`value`, `quoteAsset`, `timestamp`, `stalePriceAssets`, `sequencerDown`, `quoteAssetStale`).

Other APIs (`getAccountPositions`, `getAccountPositionsForAsset`, `hasPositions`, `getAssetsWithPositions`, `calculateValue`) are likewise thin `NAVCalculator` wrappers over `PriceFeedLib` entrypoints, following the same pattern: same adapter list, same `getAdapterPositions`, with additional filtering (single asset for the per-asset variant). The heavy `PositionBalance[]`/`Position[]` arrays are built and consumed inside the library and never cross the ABI boundary.

### 6.1 Meta-adapters (multi-instance) — `IMetaBalanceAdapter`

Most adapters pin a single instance (one vault, one pool, one market) in their constructor. A **meta-adapter** instead serves *every* instance of a protocol from one immutable contract, and the set of instances to actually query is held on **NAVCalculator** — not in the adapter. See [ADR 0010](../../docs/decisions/0010-meta-balance-adapters.md).

- **Interface:** `IMetaBalanceAdapter` extends `IBalanceAdapter` and adds `getAdapterPositionsForInstances(account, bytes32[] instances, assetFilter)` and `underlyingAssetsSupportedForInstances(bytes32[])`. The instance coordinate is `bytes32` (an address widened to bytes32 for vault/pool/instance-address protocols; raw bytes32 for e.g. Morpho market ids).
- **Base:** `MetaBalanceAdapter` (abstract) supplies ERC165, the per-instance fan-out (with per-instance revert isolation), and the registered-asset helper. Its `getAdapterPositions(account, assetFilter)` reads the adapter's own NAV-configured set via `getMetaInstances(address(this))` and fans out. A concrete meta-adapter implements `_instancePositions` and `_instanceAssets`, and may optionally override `_instancePositionId(bytes32 instance)` to customise the positionId encoding (default: `abi.encode(_toAddress(instance))`; override with `abi.encode(instance)` for raw-bytes32 coordinates).
- **Immutability preserved.** Meta-adapters have **no `Ownable`, no write functions** — they stay immutable like every other adapter. The mutable, governed instance set lives on NAVCalculator (UUPS-upgradeable, `MANAGER`-gated). No new mutable-adapter ADR is needed.
- **Identity is typed, not stored.** `protocolId` is a compile-time `bytes32` constant from `ProtocolIds.sol`. `positionId` is computed at query time via `abi.encode(...)` of the position's key (e.g. vault address, market id). Nothing instance-specific is stored in config or constructor args.
- **NAVCalculator read path is unchanged.** NAV calls `getAdapterPositions(account, assetFilter)` on every adapter uniformly; the meta-adapter pulls its own configured set inside that call, so there is no meta-specific branch in NAV (this also keeps `NAVCalculator` under the EIP-170 size limit).
- **Registering a meta-adapter:** meta-adapters (those implementing `IMetaBalanceAdapter`) register via
  **`addMetaBalanceAdapter(adapter, bytes32[] instances)`** (MANAGER), which registers the adapter **and** seeds its
  instance set atomically in one call. The plain `addBalanceAdapters([...])` path is reserved for non-meta adapters
  and **reverts `MetaAdapterNotAllowed`** if handed a meta-adapter; conversely `addBalanceAdapters` is the only path
  for non-meta adapters. The instance list may be empty (registers the meta-adapter with no instances yet).

- **Updating the instance set:** once registered, `MANAGER` calls `addMetaInstances(adapter, bytes32[])` /
  `removeMetaInstances(adapter, bytes32[])` on NAVCalculator. Both are incremental and all-or-nothing:
  `addMetaInstances` reverts on a coordinate already present or repeated within the batch (a duplicate would
  double-count NAV), `removeMetaInstances` reverts on a coordinate not present, an empty list reverts, and both
  revert `NotMetaAdapter` if the target is not a meta-adapter. In deploy config, list the instances in
  `script/config/nav-config/meta-balance-adapters/<chainId>.json` under `<AdapterKey>.instances` (address array, widened
  to bytes32 — for vault/pool-address adapters) or `<AdapterKey>.instancesRaw` (raw bytes32 — for marketId-keyed adapters
  like `MorphoMarketsMeta`); `06_Configure` detects meta-vs-plain on-chain via ERC165, registers meta-adapters via
  `addMetaBalanceAdapter` (seeded from config), and on re-runs reconciles the on-chain set against config by diffing
  `getMetaInstances` (current) vs the configured set, then emits the `addMetaInstances`/`removeMetaInstances` TX.

### 6.2 Human-readable labels — `IPositionDescribable`

All adapters implement `IPositionDescribable` (which now declares only `protocolName()`):

```solidity
interface IPositionDescribable {
    function protocolName() external view returns (string memory); // e.g. "Aave V3", "Morpho"
}
```

The display hierarchy below the protocol is the `labels` array each adapter fills **directly on every `PositionBalance`** it returns (`string[]`, leaf last, e.g. `["Market", "wstETH/USDC"]`) — this is the single label mechanism (no `positionLabels` method, no fallback). The verbose read methods on `NAVCalculator` (`getAccountPositionsVerbose`, `getAccountPositionsForAssetVerbose`, `getAccountNavVerbose`) read `protocolName()` via a fail-open staticcall and surface the position's own `labels` verbatim, bundling both into `VerbosePosition` (`protocolName` + the `labels` array). The full breadcrumb is `[protocolName, ...labels]`. **These strings are for display only — never use them for identity, indexing, or reconciliation.** Use the typed `protocolId`, `positionId`, `positionKind` fields for those purposes.

Meta-adapters derive the label hierarchy on-chain from live state (ERC20 symbols, vault names, pool composition); each fills `[category, …leaf]`. Per-instance adapters fill a fixed array.

### 6.3 Assisted adapters (externally-fed) — `IAssistedBalanceAdapter`

Most adapters derive a position purely from on-chain state. A few cannot: the data needed to value a position lives off-chain or is not enumerable from a `view`. Merkl distributes rewards via off-chain merkle trees; ether.fi / StakeWise withdrawal requests are keyed by per-account coordinates the contract does not index; and NFT-position protocols (Uniswap V3, PancakeSwap V3, Nexus Mutual staking) hold positions as non-enumerable NFTs that are gas-prohibitive to discover by scanning every minted id. For these, a trusted **assistant** submits the position coordinates (token ids, request ids, proofs) via transactions so the position becomes queryable. This is the third adapter family, peer to plain `BalanceAdapter`s and meta-adapters.

```solidity
// IAccessControl is listed before IBalanceAdapter so the MRO matches AccessControl's
// (OZ v5 IAccessControl is not IERC165); the reverse order fails C3 linearization.
interface IAssistedBalanceAdapter is IAccessControl, IBalanceAdapter {
    function ASSISTANT_ROLE() external view returns (bytes32);
}
```

The interface is deliberately minimal — it only *identifies* the family and exposes the role; it does not prescribe the submit/verify surface (each protocol's data shape differs). The abstract `AssistedBalanceAdapter` base contributes only the access-control scaffolding via OpenZeppelin `AccessControl`:

- **`DEFAULT_ADMIN_ROLE`** — administers (grants/revokes) `ASSISTANT_ROLE`. Held by the admin (e.g. the security-council Safe).
- **`ASSISTANT_ROLE`** — authorized to submit the assistance. Held by the off-chain submitter (a kpk-agents automation).

Concrete adapters still implement `IBalanceAdapter` (and typically `IPositionDescribable`) themselves and gate their submit/clear mutators with `onlyRole(ASSISTANT_ROLE)`. They **must** uphold the family invariant: cache only position *coordinates* (never amounts), value every read live on-chain, and re-verify ownership per read — so a faulty or compromised assistant can only **under-report, never over-report**. See ADR `docs/decisions/0007-merkl-trust-minimized-cache.md` (Merkl, proof-verified cache) and `docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md` (ether.fi, StakeWise — id-only cache).

**Members on the base** — `MerklRewardsBalanceAdapter`, `EtherFiWithdrawalQueueBalanceAdapter`, `StakeWiseV3ExitQueueBalanceAdapter`, `UniswapV3PoolsBalanceAdapter` (and its `PancakeSwapV3PoolsBalanceAdapter` subclass), and `NexusMutualStakingPoolsBalanceAdapter` — all extend `AssistedBalanceAdapter`. The NFT-position adapters (Uniswap V3 / PancakeSwap V3 / Nexus Mutual) cache a per-account `tokenId` set submitted via `submitTokenIds`: the write **reverts** (`NotTokenOwner`) on any id not currently owned by the account, and reads **discard** ids that are no longer owned (so a single stale id never zeroes the account). They value each position live — Uniswap/PancakeSwap LP off the pool's live `slot0` (instantaneous on-chain amounts; PancakeSwap V3 overrides `_slot0` for its `uint32 feeProtocol` ABI), Nexus stake via `StakingViewer.getTokens` — re-verifying ownership (`ownerOf` / `tokenInfo`) on every read. Spot manipulation of the V3 LP split is mitigated by the asynchronous NAV consumer, not by a fair-value reconstruction (ADR 0017).

---

## 7. Implemented adapters

### 7.1 Meta-adapters (18)

Meta-adapters extend `MetaBalanceAdapter`. The instance set is configured on NAVCalculator via `addMetaInstances`/`removeMetaInstances`.

| Adapter | Description | Constructor | Config key (deploy: `contracts-deployment-config/meta-balance-adapters/<chainId>.json`; register: `nav-config/meta-balance-adapters/<chainId>.json`) |
|---------|-------------|-------------|------------------|
| **AaveV3InstancesMeta** | All Aave V3 instances (Core, Prime, …). Instance coordinate = ProtocolDataProvider address. Up to 2 rows per reserve (`Supplied`/`Collateral` + `Borrowed`). Identity: positionId = `abi.encode(pool)` (one position per instance; reserves distinguished by `balanceAsset` + `positionKind`). | `(protocolName, navCalculator)` | `AaveV3InstancesMeta`; DataProviders under `instances`. |
| **BalancerV2PoolsMeta** | Wallet-held (unstaked) LP for all Balancer V2 pools. Instance coordinate = raw bytes32 poolId. positionId = `abi.encode(bytes32 poolId)`. One `Supplied` leg per underlying token. | `(vault, protocolName, navCalculator)` | `BalancerV2PoolsMeta`; poolIds under `instancesRaw`. |
| **BalancerV2GaugesMeta** | Gauge-staked LP + rewards for all Balancer V2 gauges. Instance coordinate = gauge address. positionId = `abi.encode(gauge)`. One `Staking` leg per underlying token + `Rewards` legs (BAL + extras). | `(vault, balancerMinter, protocolName, navCalculator)` | `BalancerV2GaugesMeta`; gauges under `instances`. |
| **BalancerV3PoolsMeta** | Wallet-held (unstaked) LP for all Balancer V3 pools. Instance coordinate = pool/BPT address. positionId = `abi.encode(pool)`. One `Supplied` leg per underlying token. | `(protocolName, navCalculator)` | `BalancerV3PoolsMeta`; pools under `instances`. |
| **BalancerV3GaugesMeta** | Gauge-staked LP + rewards for all Balancer V3 gauges. Instance coordinate = gauge address. positionId = `abi.encode(gauge)`. One `Staking` leg per underlying token + `Rewards` legs (BAL + extras). | `(balancerMinter, protocolName, navCalculator)` | `BalancerV3GaugesMeta`; gauges under `instances`. |
| **CompoundV3CometsMeta** | All Compound V3 (Comet) markets. Instance coordinate = comet address. positionId = `abi.encode(comet)`. Base `Supplied`/`Borrowed`, `Collateral` per collateral, COMP `Rewards`. CometRewards + reward token pinned in constructor. | `(compoundRewards, rewardToken, protocolName, navCalculator)` | `CompoundV3CometsMeta`; comets under `instances`. |
| **ConvexRewardsMeta** | All Convex staking (CRV, CVX, extras). Instance coordinate = rewarder address. positionId = `abi.encode(rewarder)`. | `(booster, cvxToken, protocolName, navCalculator)` | `ConvexRewardsMeta`; rewarder addresses under `instances`. |
| **CurvePoolsMeta** | Wallet-held (unstaked) LP for all Curve pools. Instance coordinate = pool address. positionId = `abi.encode(pool)`. `Supplied` legs per underlying token. | `(protocolName, navCalculator)` | `CurvePoolsMeta`; pools under `instances`. |
| **CurveGaugesMeta** | Gauge-staked LP + rewards (CRV + extras) for all Curve gauges. Instance coordinate = gauge address. positionId = `abi.encode(gauge)`. `Staking` + `Rewards` legs. | `(minter, crvToken, protocolName, navCalculator)` | `CurveGaugesMeta`; gauges under `instances`. |
| **EulerVaultsMeta** | All Euler V2 ERC-4626 vaults — both EulerEarn aggregators (Earn) and core eVaults (Lend/Borrow). Instance coordinate = vault address. positionId = `abi.encode(vault)`. `Supplied` (or `Collateral` if EVC-enabled) leg via `convertToAssets(balanceOf)` + `Borrowed` leg (`debtOf`) for core eVaults. | `(protocolName, navCalculator)` | `EulerVaultsMeta`; vaults under `instances`. |
| **FluidFTokensMeta** | All Fluid fTokens (ERC4626 lending vaults). Instance coordinate = fToken address. positionId = `abi.encode(fToken)`. One `Supplied` leg per fToken (`convertToAssets(balanceOf)`). | `(protocolName, navCalculator)` | `FluidFTokensMeta`; fTokens under `instances`. |
| **FluidVaultsMeta** | All Fluid T1 vaults. Instance coordinate = vault address. positionId = `abi.encode(vault)`. `Collateral` (supply) + `Borrowed` (debt) legs per vault. VaultResolver pinned in constructor. | `(vaultResolver, protocolName, navCalculator)` | `FluidVaultsMeta`; vaults under `instances`. |
| **GearboxMarketsMeta** | All Gearbox V3 ERC4626 farming pools. Instance coordinate = market address. positionId = `abi.encode(market)`. One `Supplied` leg per market (`convertToAssets(balanceOf)`). | `(protocolName, navCalculator)` | `GearboxMarketsMeta`; markets under `instances`. |
| **MorphoVaultsMeta** | All Morpho ERC4626 vaults (MetaMorpho). Instance coordinate = vault address. positionId = `abi.encode(vault)`. One `Supplied` leg per vault (shares → underlying). | `(protocolName, navCalculator)` | `MorphoVaultsMeta`; vaults under `instances`. |
| **MorphoMarketsMeta** | All Morpho Blue markets. Instance coordinate = raw bytes32 marketId. positionId = `abi.encode(bytes32 marketId)`. Up to 3 rows per market (`Collateral`, `Supplied`, `Borrowed`). Morpho contract pinned in constructor. | `(morpho, protocolName, navCalculator)` | `MorphoMarketsMeta`; marketIds under `instancesRaw`. |
| **StakeWiseV3VaultsMeta** | All StakeWise V3 vaults. Instance coordinate = vault address. positionId = `abi.encode(vault)`. `Staking` (vault shares → assets) + `Borrowed` (osToken debt) legs. Underlying token pinned in constructor. | `(underlyingToken, protocolName, navCalculator)` | `StakeWiseV3VaultsMeta`; vaults under `instances`. |
| **UniswapV2PoolsMeta** | LP of all Uniswap V2 pairs. Instance coordinate = pair address. positionId = `abi.encode(pair)`. One `Supplied` leg per token (dilution-adjusted pro-rata reserves). Also serves SushiSwap/PancakeSwap V2 forks. | `(protocolName, navCalculator)` | `UniswapV2PoolsMeta`; pairs under `instances`. |
| **PancakeSwapV2PoolsMeta** | Thin subclass of `UniswapV2PoolsMeta` (PancakeSwap V2 is a byte-for-byte V2 fork). | `(protocolName, navCalculator)` | `PancakeSwapV2PoolsMeta`; pairs under `instances`. |

> Uniswap V3 / PancakeSwap V3 are **not** meta-adapters — their NFT positions are non-enumerable, so they are assisted (agent-fed `tokenId` cache). See §7.2 (`UniswapV3Pools` / `PancakeSwapV3Pools`) and §6.3.

### 7.2 Per-instance singleton adapters (16)

These adapters implement `IBalanceAdapter` directly (not `MetaBalanceAdapter`). Each is a single immutable deployment. Constructors take only protocol-specific addresses and `navCalculator`. Identity is expressed via a compile-time `bytes32` constant (`PROTOCOL_ID = ProtocolIds.<CONSTANT>`) and `positionId` computed at query time via `abi.encode(...)`.

| Adapter | Description | Constructor | Notes |
|---------|-------------|-------------|-------|
| **ERC20DefaultBalanceAdapter** | Wallet ERC20 and native balances for all registered assets. protocolId = `WALLET`, positionId = `abi.encode(asset)`, kind = `Wallet`. Auto-registered at init. | `(navCalculator, initialAssets[])` | Default adapter; registered by `NAVCalculator.initialize`. |
| **AaveV3SafetyModule** | Aave V3 Safety Module stake tokens (stkAAVE, stkABPT, stkABPTv2, stkGHO). Stake-token set hardcoded at construction. Up to three legs per token, **all sharing positionId `abi.encode(stakeToken)`** (no discriminator): a locked `Staking` leg (`isLocked=true` — active stake plus any cooling/expired cooldown; active stake is non-withdrawable), an unlocked `Staking` leg (`isLocked=false`, only when a cooldown has elapsed and is still inside the unstake window), and a `Rewards` leg (told apart by `positionKind`). Stake tokens without the V3 cooldown ABI degrade to a single locked-stake leg. | `(navCalculator)` | protocolId = `AAVE_V3_SAFETY_MODULE`. Mainnet only. |
| **AaveUmbrella** | Aave Umbrella stake tokens discovered dynamically via `RewardsController.getAllAssets()`. Up to three legs per token, **all sharing positionId `abi.encode(stakeToken)`** (no discriminator): a locked `Staking` leg (`isLocked=true` — active stake plus any cooling/expired cooldown), an unlocked `Staking` leg (`isLocked=false`, only when a cooldown has elapsed and is still inside the withdrawal window) — both in the bare reserve — and a `Rewards` leg (told apart by `positionKind`). Picks up new stake tokens via governance without redeploy. | `(rewardsController, navCalculator)` | protocolId = `AAVE_V3_UMBRELLA`. See `docs/decisions/0006-aave-umbrella-balance-adapter.md`. |
| **Cap** | Cap protocol balances reported as USDC, as **two legs**: held cUSD (`["Stablecoin", "cUSD"]`) and staked stcUSD (`["Savings", "stcUSD"]`). positionId = `abi.encode(cUSD)` / `abi.encode(stcUSD)` per leg; cUSD `Supplied`, staked stcUSD `Staking`. | `(cUsd, stcUsd, usdc, navCalculator)` | protocolId = `CAP`. |
| **EthenaCooldownBalanceAdapter** | USDe owed to an account in the sUSDe unstaking cooldown. Reads the single per-account `UserCooldown` slot on `StakedUSDeV2` (`cooldowns(account)` → `{cooldownEnd, underlyingAmount}`) and reports `underlyingAmount` as one position denominated in USDe; non-zero only while an unstake is in flight. positionId = `abi.encode(address sUSDe)` (static). `Supplied` kind; `isLocked=true` until the cooldown elapses, then `false`. | `(stakedUSDe, underlyingToken, navCalculator)` | protocolId = `ETHENA_COOLDOWN`. Mainnet only. |
| **KelpWithdrawalQueue** | Kelp DAO rsETH exit queue (`LRTWithdrawalManager`). Emits **one `Supplied` leg per open request** (per payout asset), valued at `expectedAssetAmount`. Payout-asset set discovered at runtime; the payout asset is carried in `balanceAsset`. positionId = `abi.encode(address withdrawalManager)` (static, shared by all requests); the request's `userNonce` rides in the last label (`["rsETH Withdrawal Queue", "Request #<nonce>"]`), never in positionId. A request is `isLocked=false` only once `userNonce < nextLockedNonce(asset)` **and** the block delay (`withdrawalStartBlock + withdrawalDelayBlocks()`) has passed, else `isLocked=true`. Bounded by `MAX_REQUESTS_PROBED` per asset; balance getters still report the summed total. | `(withdrawalManager, navCalculator)` | protocolId = `KELP_WITHDRAWAL`. Mainnet only. |
| **LidoWithdrawalQueue** | Lido `WithdrawalQueueERC721`. Emits **one `Supplied` leg per open (un-claimed) withdrawal request** (enumerated via `getWithdrawalRequests`): finalized → exact claimable ETH (`getClaimableEther`, `isLocked=false`); not finalized → `amountOfStETH` (`isLocked=true`). positionId = `abi.encode(address withdrawalQueue)` (static, shared by every request); the ERC721 request id rides in the last label (`["stETH Withdrawal Queue", "Request #<id>"]`), never in positionId (it is ephemeral — burned on claim). `Supplied` kind, native-ETH. Bounded by `MAX_REQUESTS_PROBED`; the balance getters still report the summed total. | `(withdrawalQueue, underlyingToken, navCalculator)` | protocolId = `LIDO_WITHDRAWAL`. Mainnet only. |
| **MerklRewards** | Merkl (Angle Labs) **unclaimed** rewards via on-chain proof verification. Per-(user, token) merkle-proof cache, `onlyOwner` writes, proofs verified against the live Distributor root. positionId = `abi.encode(distributor)` (the reward token is carried by `balanceAsset`, so encoding it in positionId would be redundant; one leg per reward token, distinguished by `balanceAsset`). `Rewards` kind. | `(distributor, navCalculator, initialOwner)` | protocolId = `MERKL`. A documented mutable-cache adapter (see `docs/decisions/0007-merkl-trust-minimized-cache.md`). |
| **EtherFiWithdrawalQueue** | ether.fi in-flight withdrawal-queue ETH. `onlyOwner` cache of per-account `WithdrawRequestNFT` tokenIds (**ids only, never amounts**); values each live (`getClaimableAmount` / `getRequest`+`amountForShare`) and re-verifies `ownerOf` per read (non-owned discarded). Emits **one `Supplied` leg per owned cached request** (finalized → `isLocked=false`, pending → `isLocked=true`); positionId = `abi.encode(address withdrawRequestNFT)` (static, shared), native-ETH; the NFT tokenId rides in the last label (`["eETH Withdrawal Queue", "Request #<tokenId>"]`), never in positionId. The agent-fed per-account tokenIds are also exposed via `tokenIdsOf(account)`. Balance getters report the summed total. | `(withdrawRequestNft, liquidityPool, underlyingToken, navCalculator, initialOwner)` | protocolId = `ETHERFI_WITHDRAWAL`. Mutable-cache adapter, agent-fed (see `docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`). The owner can only under-report, never over-report. |
| **NexusMutualStakingPools** | Nexus Mutual V2 staked NXM across all staking pools (assisted; agent-fed). The assistant submits an account's `StakingNFT` tokenIds via `submitTokenIds` (the NFT is not ERC721Enumerable — no per-owner view); the write **reverts** `NotTokenOwner` on any id whose `tokenInfo` owner ≠ account. `StakingViewer.getTokens` values **each** owned, cached id into a `Staking` leg (active + expired stake) + a `Rewards` leg, both NXM — one pair **per StakingNFT tokenId** — re-verifying ownership via `tokenInfo` per read (discarding ids no longer owned). positionId = `abi.encode(address stakingPool)` (the deterministic pool contract from `StakingViewer.stakingPool(poolId)`); the StakingNFT id is surfaced as the last adapter-supplied **label** (`["Staking", "<pool>", "NFT #<id>"]`). (The no-arg balance getters return the summed NXM total via `getAggregatedTokens`.) | `(stakingNft, stakingViewer, underlyingToken, navCalculator, admin, assistant)` | protocolId = `NEXUS_MUTUAL_STAKING` (slug `nexus-mutual-staking`). Mainnet only; underlying = NXM (priced PR #71). `MAX_TOKEN_IDS` (64) caps the per-account cache. Assisted-family member (ADR 0015); cache stores ids only, never amounts. |
| **UniswapV3Pools** | Uniswap V3 LP across any pool (assisted; agent-fed). The assistant submits an account's NFT tokenIds via `submitTokenIds` (NPM positions are non-enumerable at scale); the write **reverts** `NotTokenOwner` on any id not owned by the account. For each cached id still owned (re-verified via `ownerOf` per read; non-owned discarded), reads `positions(tokenId)` and emits `Supplied` (in-range liquidity) + `Fees` (full unclaimed fees) legs. positionId = `abi.encode(address pool)` (`factory.getPool(token0, token1, fee)` — each fee tier is its own deployed pool); the NFT id is surfaced as the last adapter-supplied **label** (`["Liquidity Pool", "<pool>", "NFT #<id>"]`). The in-range split is valued off the pool's live `slot0` (the `sqrtPriceX96` split plus the full unclaimed fees off the real tick); a position whose tokens are unregistered/unpriced/stale is dropped. Spot manipulation of the reported amounts is mitigated by the asynchronous NAV consumer rather than a fair-value reconstruction (ADR 0017). NonfungiblePositionManager (and its factory) pinned in constructor; `MAX_TOKEN_IDS` (256) caps the cache. | `(positionManager, protocolName, navCalculator, admin, assistant)` | protocolId = `UNISWAP_V3`. Assisted-family member (ADR 0015); cache stores ids only. `underlyingAssetsSupported()` is empty (open-universe, like Merkl). Config key `UniswapV3Pools`. Reads live `slot0`; full unclaimed fees (M-A1 reverted under ADR 0017). |
| **PancakeSwapV3Pools** | Subclass of `UniswapV3Pools` differing in the protocol-id slug (`pancakeswap-v3`) and a `_slot0` override. Own NonfungiblePositionManager. Because the adapter reads the pool's live `slot0` (ADR 0017) and PancakeSwap declares `slot0().feeProtocol` as `uint32` (Uniswap's is `uint8`), the subclass overrides `_slot0` to decode the `uint32 feeProtocol` ABI. | `(positionManager, protocolName, navCalculator, admin, assistant)` | protocolId = `PANCAKESWAP_V3`. Config key `PancakeSwapV3Pools`. |
| **StakeWiseV3ExitQueue** | StakeWise V3 in-flight exit-queue assets. `onlyOwner` cache of per-account `(vault, positionTicket, timestamp)` tuples (**coordinates only, never amounts**); values each live as `calculateExitedAssets(account,…).exitedAssets + convertToAssets(leftShares)` (out-of-range index path for fully-pending positions), with `calculateExitedAssets(receiver=account)` as the on-chain ownership check and a `VaultsRegistry` membership check at submit time. Emits legs **per request (positionTicket)**: up to two per ticket — a claimable leg (`exitedAssets`, `isLocked=false`) and a still-queued leg (`convertToAssets(leftShares)`, `isLocked=true`) — both carrying the ticket id in the last label (`["Exit Queue", "Ticket #<positionTicket>"]`). positionId = `abi.encode(address vault)` (static, per vault, shared by a vault's tickets), native-ETH, `Supplied` kind. The agent-fed `(vault, ticket, timestamp)` tuples are also exposed via `positionsOf(account)`. Balance getters report the summed total. | `(vaultsRegistry, underlyingToken, navCalculator, initialOwner)` | protocolId = `STAKEWISE_EXIT`. Mainnet only. Mutable-cache adapter, agent-fed, sibling of `EtherFiWithdrawalQueue` (see `docs/decisions/0014-agent-fed-cache-adapters-for-exit-queues.md`). The owner can only under-report, never over-report. |
| **SparkLend** | Spark lending positions. Two legs per reserve (`Supplied`/`Collateral` + `Borrowed`). positionId = `abi.encode(pool)` (one position per instance; reserves distinguished by `balanceAsset` + `positionKind`). | `(dataProvider, navCalculator)` | protocolId = `SPARK_LEND`. Standalone adapter mirroring the Aave V3 lending pattern (same `ProtocolDataProvider` ABI). |
| **StaderWithdrawalQueue** | Stader `UserWithdrawalManager` pending unstake requests (enumerated via `requestIdsByUserAddress`). Emits **one `Supplied` leg per open request**: finalized → `ethFinalized` (`isLocked=false`), pending → `ethExpected` (`isLocked=true`). positionId = `abi.encode(address userWithdrawalManager)` (static, shared); the request id rides in the last label (`["ETHx Withdrawal Queue", "Request #<id>"]`), never in positionId. Bounded by `MAX_REQUESTS_PROBED`; balance getters report the summed total. | `(userWithdrawalManager, underlyingToken, navCalculator)` | protocolId = `STADER_WITHDRAWAL`. Mainnet only; underlying configured to WETH. |

Protocol adapters typically take **NAVCalculator** in the constructor to read the asset registry (symbol, decimals) so they can build correct `Asset` structs.

---

## 8. How to create a new adapter

### 8.1 Contract layout

1. Add a slug to `src/utils/ProtocolIds.sol` and document the `positionId` ABI-decode schema in its NatSpec comment. Choose `abi.encode(primaryKey)` where `primaryKey` is the most specific stable on-chain identifier for this position.

2. Create a contract that implements `IBalanceAdapter` and `IERC165` (or extend `MetaBalanceAdapter` for a multi-instance adapter).

3. Declare a compile-time constant:
   ```solidity
   bytes32 private constant PROTOCOL_ID = ProtocolIds.<YOUR_CONSTANT>;
   ```

4. Implement **`getAdapterPositions(address account, address assetFilter)`**:
   - Query the protocol for the account's positions.
   - For each position, build `PositionBalance` with:
     - `balanceAsset`: `Asset` from NAVCalculator's registry (must match registry for filtering).
     - `balanceAdapter`: `address(this)`.
     - `amount`: positive `uint256` in asset decimals.
     - `isDebt`: `true` for debts, `false` for everything else.
     - `protocolId`: `PROTOCOL_ID`.
     - `positionId`: `abi.encode(...)` of the position's **static, timeless** key. For withdrawal-queue / cooldown positions, encode the immutable anchor (`abi.encode(address <queue/manager/vault/sUSDe>)`) — never a per-request id — and split the holding into a claimable leg (`isLocked=false`) and a locked leg (`isLocked=true`) that share it.
     - `positionKind`: one of `PositionKind.Wallet / Supplied / Borrowed / Collateral / Staking / Rewards / Fees`.
     - `isLocked`: `true` = not withdrawable now (pending withdrawal OR active/cooling stake); `false` = withdrawable now. `false` for non-queue/non-cooldown/non-staking-with-cooldown adapters. Part of the identity key.
   - If `assetFilter != address(0)`, return only positions for that asset (or empty).

5. Implement **`getAdapterBalances`** and **`getAdapterBalanceForAsset`** (per-asset amounts and debt flags). Meta-adapters return empty arrays for these (they are not used by the NAV path).

6. Implement **`underlyingAssetsSupported()`**: return the list of underlying token addresses this adapter can report.

7. Implement **`supportsInterface(bytes4)`**: return `true` for `type(IBalanceAdapter).interfaceId` and `type(IERC165).interfaceId`.

8. Implement **`IPositionDescribable.protocolName()`** and **fill `PositionBalance.labels`** on each returned position (the single label mechanism — there is no `positionLabels` method):
   - Per-instance adapters fill a fixed array (e.g. `["Safety Module"]`).
   - Meta-adapters derive labels on-chain (read token symbols, vault/pool names) and fill `[category, …leaf]`.

### 8.2 PositionKind assignment

| Position type | `PositionKind` |
|---------------|----------------|
| ERC20 wallet balance | `Wallet` |
| Lending supply (freely withdrawable) | `Supplied` |
| Lending supply as collateral | `Collateral` |
| Debt | `Borrowed` |
| Vault shares, unstaked LP principal | `Supplied` |
| Principal exited via unstake (staking contracts, gauge/Convex-staked LP) | `Staking` |
| Unclaimed reward tokens | `Rewards` |
| Uncollected LP/protocol fees | `Fees` |

### 8.3 Minimal example (per-instance adapter)

```solidity
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MyProtocolBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    bytes32 private constant PROTOCOL_ID = ProtocolIds.MY_PROTOCOL;

    IMyProtocol public immutable PROTOCOL;
    INAVCalculator public immutable NAV_CALCULATOR;

    constructor(address protocol_, address navCalculator_) {
        PROTOCOL = IMyProtocol(protocol_);
        NAV_CALCULATOR = INAVCalculator(navCalculator_);
    }

    function getAdapterPositions(address account, address assetFilter)
        external view override returns (INAVCalculator.PositionBalance[] memory)
    {
        address underlying = PROTOCOL.underlying();
        if (assetFilter != address(0) && assetFilter != underlying) {
            return new INAVCalculator.PositionBalance[](0);
        }
        uint256 bal = PROTOCOL.balanceOf(account);
        if (bal == 0) return new INAVCalculator.PositionBalance[](0);

        (INAVCalculator.Asset memory asset, bool found) = _getAssetInfo(underlying);
        if (!found) return new INAVCalculator.PositionBalance[](0);

        INAVCalculator.PositionBalance[] memory out = new INAVCalculator.PositionBalance[](1);
        out[0] = INAVCalculator.PositionBalance({
            balanceAsset: asset,
            balanceAdapter: address(this),
            amount: bal,
            isDebt: false,
            protocolId: PROTOCOL_ID,
            positionId: abi.encode(address(PROTOCOL)),
            positionKind: PositionKind.Supplied,
            isLocked: false,
            labels: _labels() // display hierarchy below protocolName, leaf last; the single label mechanism
        });
        return out;
    }

    // IPositionDescribable — only protocolName(); labels are filled on each PositionBalance above
    function protocolName() external pure returns (string memory) { return "My Protocol"; }

    function _labels() internal pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = "Supply";
    }

    // IBalanceAdapter — simple getters
    function getAdapterBalances(address account)
        external view override returns (address[] memory, uint256[] memory, bool[] memory) { ... }
    function getAdapterBalanceForAsset(address account, address asset)
        external view override returns (uint256, bool) { ... }
    function underlyingAssetsSupported() external view override returns (address[] memory) { ... }

    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IBalanceAdapter).interfaceId
            || id == type(IPositionDescribable).interfaceId
            || id == type(IERC165).interfaceId;
    }

    function _getAssetInfo(address asset)
        internal view returns (INAVCalculator.Asset memory, bool found)
    {
        INAVCalculator.Asset[] memory reg = NAV_CALCULATOR.getRegisteredAssets();
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) return (reg[i], true);
        }
        return (INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), false);
    }
}
```

For a **meta-adapter**, extend `MetaBalanceAdapter` and implement `_instancePositions` and `_instanceAssets` instead. The base handles ERC165, the fan-out loop, and revert isolation.

### 8.4 Testing expectations

- Unit tests (mock-only): `test/balances/<family>/<Adapter>.t.sol`
- Fork tests against a real holder at a pinned block: `test/balances/<family>/fork/<Adapter>.fork.t.sol`
- Run fork tests with: `FOUNDRY_PROFILE=slow forge test --match-path "test/**/fork/*.sol"`

See also `docs/howto/add-balance-adapter.md` for the end-to-end recipe.

---

## 9. How to configure and use balance adapters

### 9.1 Asset registration

- Assets (and their price feeds) are registered on **NAVCalculator**, which extends Balances and Prices.
- Call **`NAVCalculator.registerAsset(asset, priceFeed, priceType, chainlinkHeartbeat)`** (requires **MANAGER**). This registers the asset in the asset registry and sets the price feed. Only registered assets are included in NAV.
- Use the chain's native token address convention (e.g. ERC-7528 `NATIVE_ADDRESS`) for the native asset.

### 9.2 Default adapter (no extra config)

- **ERC20DefaultBalanceAdapter** is deployed and registered automatically in **`NAVCalculator.initialize(...)`**. It reports wallet ERC20 and native balances for all assets returned by `NAVCalculator.getRegisteredAssets()`. No additional registration step.

### 9.3 Adding custom adapters

1. Deploy your adapter, passing constructor args (protocol addresses, `navCalculator`).
2. As an account with **MANAGER** on NAVCalculator:
   - **Non-meta adapter:** call **`NAVCalculator.addBalanceAdapters(adapters)`**. This validates ERC165 support for `IBalanceAdapter`, rejects any meta-adapter (`MetaAdapterNotAllowed`), and adds the adapter to the global adapter list.
   - **Meta-adapter:** call **`NAVCalculator.addMetaBalanceAdapter(adapter, instances)`**, which registers the adapter **and** seeds its instance set (vault addresses, pool addresses, or raw marketIds — all `bytes32`) atomically. The instance list may be empty. Afterwards, update the set incrementally with `addMetaInstances(adapter, instances)` / `removeMetaInstances(adapter, instances)`.
3. Ensure every asset your adapter reports is already registered via `registerAsset` (with a price feed); otherwise those positions will be filtered out when computing NAV.

### 9.4 Computing NAV

- Call **`NAVCalculator.getAccountNav(account, quoteAsset)`** to get the full NAV for the account in the given quote asset (`address(0)` for USD).
- For per-position views, use `getAccountPositions(account, quoteAsset)` or `getAccountPositionsForAsset(account, asset, quoteAsset)` — same adapters, same flow.
- For human-readable output, call the verbose methods on `NAVCalculator` (`getAccountPositionsVerbose` / `getAccountNavVerbose`), which bundle `IPositionDescribable` labels.

No per-adapter "enable for this asset" step is required: all registered adapters are queried for every NAV call; filtering is by **registered assets** on the NAVCalculator side.
