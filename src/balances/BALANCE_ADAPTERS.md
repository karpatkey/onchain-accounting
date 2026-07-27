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
2. **For each adapter** — `adapter.getAdapterPositions(account, address(0))` returns an array of `PositionBalance` (balance asset, amount, isDebt, protocolBrand, protocolId, protocolSubId, positionId, positionKind, isLocked, positionInstanceId). Unsupported adapters are skipped (try/catch).
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
| `protocolBrand` | `bytes32`     | `keccak256` of the version-stripped brand slug (e.g. `aave`, `balancer`; see `src/utils/ProtocolIds.sol`). The broadest roll-up — several `protocolId`s share it (`aave-v3` → `aave`; `balancer-v2` + `balancer-v3` → `balancer`). **Display / grouping only; NOT part of the identity key.** Equals `protocolId` for unversioned protocols. |
| `protocolId`    | `bytes32`     | `keccak256` of the broad protocol-ecosystem slug (e.g. `aave-v3`, `curve`; see `src/utils/ProtocolIds.sol`). A roll-up / grouping key — several `protocolSubId`s share it (`aave-v3-lending` + `aave-v3-safety-module` both roll up to `aave-v3`). **NOT part of the identity key** (functionally determined by `protocolSubId`). Equals `protocolSubId` for single-product ecosystems. |
| `protocolSubId` | `bytes32`     | `keccak256` of the specific protocol-product slug (e.g. `aave-v3-lending`; see `src/utils/ProtocolIds.sol`). Selects the `positionId` ABI-decode schema — one sub-slug implies exactly one schema — and is the protocol component of the stable identity key. |
| `positionId`    | `bytes`       | `abi.encode(...)` of the position's **static, timeless** key. Decode schema is determined by `protocolSubId`. e.g. for `aave-v3-lending`: `abi.encode(address pool)`. Withdrawal-queue / cooldown adapters use a static coordinate (queue / manager / vault / sUSDe) — never a per-request id; the owed/payout asset is in `balanceAsset`. The queues emit **one leg per open request** (and the NFT adapters one leg per NFT) all sharing this static positionId, with the ephemeral per-item id in `positionInstanceId`; such legs share the stable reconciliation key and must be **summed, not deduplicated**. Full schema table: `src/utils/ProtocolIds.sol` and `docs/howto/position-identity-schema.md`. |
| `positionKind`  | `PositionKind`| Semantic discriminator: `Wallet` / `Supplied` / `Borrowed` / `Collateral` / `Staking` / `Rewards` / `Fees`. See `src/utils/PositionKind.sol`. |
| `isLocked`      | `bool`        | `true` = not withdrawable now (a pending withdrawal request, OR an active/cooling stake); `false` = withdrawable now. "Partial = locked". Uniform rule: `isLocked = non-withdrawable` — active stake (Aave SM, Umbrella) needs a cooldown first, so it is locked; only an in-window elapsed cooldown is unlocked. **Part of the identity key** — the two legs share one static `positionId`, so `isLocked` is what keeps them distinct. `false` for all non-queue/non-cooldown/non-staking-with-cooldown adapters. See ADR 0016. |
| `positionInstanceId` | `bytes32` | OPTIONAL ephemeral per-item coordinate — a Uniswap V3 / PancakeSwap V3 NFT id, a withdrawal/exit request id, or a StakeWise exit ticket (each a `uint256` widened to `bytes32`). `bytes32(0)` when the adapter has no per-item granularity. The SOLE ephemeral identity field; the stable reconciliation key deliberately **excludes** it so the legs of one anchor sum. A consumer MAY append it to the key for per-item granularity, at the cost of an ephemeral key. **Never use it for stable identity.** |

The stable per-chain identity key for caching and reconciliation is `(chainId, protocolSubId, positionId, balanceAsset.asset, positionKind)`. `protocolBrand` / `protocolId` are excluded — they are grouping layers functionally determined by `protocolSubId`; `balanceAdapter` is excluded — redeploying an adapter doesn't change the position; `isDebt` is excluded — it is the canonical NAV-sign field, read directly (do **not** infer it from `positionKind`); `positionInstanceId` is excluded — it is the ephemeral per-item coordinate; `isLocked` is excluded — it is a **mutable per-leg attribute** (a withdrawal-queue / cooldown leg flips `true→false` as its portion finalizes), so keying on it would split one economic position into two keys over its lifetime. The key identifies a position **group**: the per-request withdrawal-queue adapters and the per-NFT adapters emit multiple legs sharing one key (differing in `positionInstanceId`), and the withdrawal-queue / cooldown adapters emit a claimable (`isLocked=false`) and a locked (`isLocked=true`) leg that also share one key — so reconcile by **summing** amounts across legs with the same key (the sum is the full holding; read `isLocked` per leg for the claimable-vs-locked split), never upsert/deduplicate by it.

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

- **Position:** Like `PositionBalance` plus `quoteAsset`, `value` (signed), `price`, `priceDecimals`, `stale`, `quoteAssetStale`. This is the enriched form returned by NAVCalculator for per-position views. It carries all of `PositionBalance`'s identity fields (`protocolBrand`, `protocolId`, `protocolSubId`, `positionId`, `positionKind`, `isLocked`, `positionInstanceId`).
- **VerbosePosition:** Wraps `Position` with a `protocolName` string and a `labels` **string array** (an ordered hierarchy below the protocol, leaf last — e.g. `["Market", "wstETH/USDC"]`), both sourced from the adapter's `IPositionDescribable`. The verbose reads call `positionLabels(positionId)` via a fail-open staticcall and derive the breadcrumb lazily from `positionId` (display work stays off the NAV hot path). The full breadcrumb is `[protocolName, ...labels]`. The ephemeral per-item id (Uniswap V3 / Nexus NFT id, request id) is **not** a label — it is the typed `Position.positionInstanceId` field. For display only — never use for identity or indexing.
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
- **Base:** `MetaBalanceAdapter` (abstract) supplies ERC165, the per-instance fan-out (with per-instance revert isolation via external `this.instancePositions` / `this.instanceAssets` wrappers), the shared `_leg` builder, and the registered-asset helper. Its `getAdapterPositions(account, assetFilter)` reads the adapter's own NAV-configured set via `getMetaInstances(address(this))` and fans out. A concrete meta-adapter implements the per-instance hooks `_instancePositions` and `_instanceAssets`, the identity hooks `_protocolBrand` / `_protocolId` / `_protocolSubId`, and `positionLabels`; it **must** override `_instancePositionId(bytes32 instance)` whenever its positionId is not the default `abi.encode(_toAddress(instance))` — `abi.encode(instance)` for raw-bytes32 coordinates, or a derived value (Aave V3 resolves the Pool from its DataProvider coordinate). This hook is **load-bearing, not an encoding convenience**: `positionIds()` maps the governed instance set through it, so it must equal the positionId `_instancePositions` passes to `_leg`, and it should be *called* from there rather than re-derived. See §6.2's `IPositionEnumerable` subsection.
- **Immutability preserved.** Meta-adapters have **no `Ownable`, no write functions** — they stay immutable like every other adapter. The mutable, governed instance set lives on NAVCalculator (UUPS-upgradeable, `MANAGER`-gated). No new mutable-adapter ADR is needed.
- **Identity is typed, not stored.** `protocolBrand` / `protocolId` / `protocolSubId` are compile-time `bytes32` constants from `ProtocolIds.sol` returned by the identity hooks. `positionId` is computed at query time via `abi.encode(...)` of the position's key (e.g. vault address, market id). Nothing instance-specific is stored in config or constructor args.
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

- **Why a governed allowlist, not on-chain registry/factory enumeration.** Several of these protocols expose an
  on-chain enumerator that lists every instance — Aave's `PoolAddressesProviderRegistry`
  (`0xbaA999AC55EAce41CcAE355c77809e68Bb345170`), Gearbox's `ContractsRegister`
  (`0xA50d4E7D8946a7c90652339CDBd262c375d54D99`), Euler's permissionless `GenericFactory`
  (`0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e`). It is tempting to have a meta-adapter read that list directly so
  governance never has to seed instances. **We deliberately do not.** A meta-adapter reads an account's balance
  *trustlessly from the instance contract* (`vault.balanceOf`→`convertToAssets`, `comet.balanceOf`, `dp.getUserReserveData`),
  so auto-including whatever a factory emits is a **NAV-integrity hole**: anyone who can deploy an instance (Euler's
  factory is fully permissionless — ~850 vaults, including junk like `eUNDEFINED-1`) could stand up a contract that
  reports a fabricated balance in a *NAV-registered* asset and inflate NAV — the registered-asset filter does not
  help, because the attack is denominated in a registered asset. The governed `bytes32[]` set on NAVCalculator is
  exactly the **allowlist** that blocks this. Secondary reasons: (a) **bounded gas/DoS** — the read path sizes its
  buffers by `_metaInstanceTotal` and fans out per instance, so iterating hundreds of factory entries per account
  read is impractical; (b) **relevance** — a portfolio holds positions in a small curated subset, and the registries
  are often the wrong set anyway (the KPK-curated Gearbox markets we use are *not* in Gearbox's `ContractsRegister`,
  Aave's registry is both stale — still lists the deprecated EtherFi market — and incomplete — omits the Horizon RWA
  market). These registries are the right tool **off-chain**: a script can read them to *propose* candidate instances,
  but governance still approves each into the on-chain allowlist. The instance set therefore stays MANAGER-curated by
  design. See the per-adapter docstrings (Aave V3 / Gearbox / Euler) for the specific registry each protocol exposes.

### 6.2 Human-readable labels — `IPositionDescribable`

All adapters implement `IPositionDescribable`, which declares `protocolName()` plus `positionLabels(positionId)`:

```solidity
interface IPositionDescribable {
    function protocolName() external view returns (string memory); // e.g. "Aave V3", "Morpho"
    function positionLabels(bytes calldata positionId) external view returns (string[] memory);
}
```

`positionLabels` returns the ordered display hierarchy **below** the protocol (`string[]`, leaf last, e.g. `["Market", "wstETH/USDC"]`), derived **lazily from `positionId`** — so the breadcrumb is computed only in the verbose reads, never carried on every `PositionBalance` (that keeps display work off the NAV hot path). The verbose read methods on `NAVCalculator` (`getAccountPositionsVerbose`, `getAccountPositionsForAssetVerbose`, `getAccountNavVerbose`) call both via a fail-open staticcall and bundle them into `VerbosePosition` (`protocolName` + the `labels` array). The full breadcrumb is `[protocolName, ...labels]`. The ephemeral per-item id (Uniswap V3 NFT id, withdrawal request id, …) is **not** a label — it rides in the typed `PositionBalance.positionInstanceId` field. **These strings are for display only — never use them for identity, indexing, or reconciliation.** Use the typed `protocolSubId`, `positionId`, `positionKind` fields for those purposes.

Meta-adapters derive the label hierarchy on-chain from live state (ERC20 symbols, vault names, pool composition), returning `_labels("Category", leaf)` (the shared helper that applies the fail-open empty-leaf convention). Per-instance adapters return a fixed array.

##### Decoding `positionId`: never `abi.decode(pid, (address))`

`positionLabels` is display-only and reachable from a **configuration view** that probes with whatever word it has, so the decode carries two obligations. The obvious spelling — `if (pid.length < 32) return new string[](0); address a = abi.decode(pid, (address));` — meets neither:

1. **It must never revert.** Solidity's ABI decoder validates an `address`, so a 32-byte word whose upper 96 bits are dirty reverts rather than degrading. A `bytes32` marketId or poolId copied from a sibling adapter is the ordinary source of one.
2. **It must never over-claim.** `abi.decode` silently ignores trailing bytes, so a `< 32` guard lets a foreign **multi-word** coordinate through and labels it from its first word — a confident, wrong breadcrumb for a position the adapter never emitted.

Meta-adapters therefore go through the shared decoders on `MetaBalanceAdapter`, which accept **exactly one word** and reject everything else without reverting:

```solidity
(address instance, bool ok) = _pidAddress(pid);   // address-keyed coordinates
if (!ok) return new string[](0);

(bytes32 word, bool ok) = _pidWord(pid);          // raw-bytes32 coordinates (Morpho marketIds, Balancer V2 poolIds)
```

`_addressLabels` already applies `_pidAddress`, so adapters using it get this for free. A dirty word is **rejected, not masked** to its low 160 bits: those bits can name a real instance by coincidence, and a wrong label is worse than an absent one. Plain and assisted adapters do the same thing inline (`positionId.length != 32`, then a raw-word decode plus a `raw >> 160` range check) — see `CapBalanceAdapter`, `ERC20DefaultBalanceAdapter` and `NexusMutualStakingPoolsAssistedBalanceAdapter`.

#### `protocolName()` names the protocol, never the product

Every adapter sharing a `ProtocolIds` **protocolId** must return the **same** `protocolName()`. Aave V3's lending instances, Safety Module and Umbrella are all `"Aave V3"`; Morpho's vaults and markets are both `"Morpho"`; Balancer's pools and gauges are both `"Balancer V3"`. The *product* is what `positionLabels()` carries (`["Umbrella Module"]`, `["Safety Module"]`, `["Market", "wstETH/USDC"]`), backed by the typed `protocolSubId`.

This is load-bearing, not cosmetic. A consumer enumerating **configured adapters** (as opposed to reading an account's positions) never sees the typed taxonomy — `protocolBrand` / `protocolId` / `protocolSubId` are `private constant` and only ride on `PositionBalance` structs returned by an account read — so the display name is the only protocol identity available at that layer. An adapter returning its product name splits itself out into a phantom sibling protocol. `AaveUmbrellaBalanceAdapter` returned `"Aave Umbrella"` and did exactly that: downstream NAV registry views listed Umbrella as a peer of Aave V3 rather than as its third product.

Mechanics:

| Adapter family | Where the name comes from | How it is kept canonical |
|---|---|---|
| Meta (`MetaBalanceAdapter`) | **Derived** — `protocolName()` returns `ProtocolNames.forProtocolId(_protocolId())` | **True by construction.** The name is a pure function of the typed identity the adapter already declares, so two adapters sharing a `protocolId` cannot disagree: they evaluate the same expression over the same input. There is no constructor argument, no config value, and no deploy-time input to get wrong. |
| Plain / assisted (hardcoded) | String literal in the adapter → baked into bytecode | Return a `src/utils/ProtocolNames.sol` constant, not a literal. `string internal constant` inlines identically, so adopting it is bytecode-neutral. All 12 are pinned to their constants by `test/ProtocolNameConsistency.t.sol`. |

An unknown `protocolId` reverts (`UnknownProtocolId`) rather than returning `""` — a meta adapter is immutable, so a silent empty name would be permanent. Reverting is safe because `protocolName()` is only ever reached through NAVCalculator's fail-open staticcall, so it degrades to an empty display name on a *verbose* read and can never break a NAV read.

`test/ProtocolNameConsistency.t.sol` covers what remains assertable: every hardcoded adapter matches its constant (including the single-member protocols no group comparison reaches), every protocol id the meta family declares has a name, an unknown id reverts, and distinct protocols do not collide on one name.

#### Describing an adapter with no account — `IPositionEnumerable`

`positionLabels` needs a `positionId`, and a **configuration view** (a registry page listing what the NAVCalculator is set up to account for) has no account and therefore no positionId to pass. There are exactly three answers an adapter can give, and every adapter falls into one of them:

| Adapter shape | What `positionLabels("")` returns | Does it implement `IPositionEnumerable`? |
|---|---|---|
| **Single-shape** — the breadcrumb does not depend on `positionId` (`ERC20Default`, `LidoWithdrawalQueue`, `EtherFiWithdrawalQueueAssisted`, …) | the full constant breadcrumb — that *is* the answer | No. Nothing to enumerate; the probe already answered. |
| **Enumerable** — a bounded shape set derivable on-chain: pinned at construction (`Cap`: cUSD / stcUSD) or governed (every meta-adapter's instance set) | `[]`, because the breadcrumb is per-position | **Yes.** `positionIds()` lists the shapes; pair each with `positionLabels(id)`. |
| **Per-account** — shapes are discovered from coordinates the position owner feeds in (`NexusMutualStakingPoolsAssisted`) | `[]` | No — there is no account-independent answer to give. |

```solidity
interface IPositionEnumerable {
    function positionIds() external view returns (bytes[] memory);
}
```

Optional, advertised via ERC-165, read through a fail-open staticcall, and **never called on the NAV path** — the same contract `IPositionDescribable` has. The ERC-165 bit is what makes the middle row distinguishable from the bottom one: both answer the probe with `[]`, and before this interface existed nothing on-chain told them apart, so a per-position adapter was indistinguishable from a broken one.

**The one binding guarantee: each returned id MUST be byte-identical to the `PositionBalance.positionId` the adapter emits for that shape**, so a configuration view can be *joined* against real positions. An id that merely *labels* correctly while differing from the emitted bytes silently breaks that join — which is exactly the trap Aave V3 sat in (its instance coordinate is a ProtocolDataProvider, but it emits the resolved Pool; both label identically, so only a byte comparison catches it). Two consequences worth internalising:

- **Join on the bytes, never on the index.** `positionIds()` is not index-aligned with `getAdapterPositions`, which omits shapes the account has no position in (and, for meta-adapters, may emit several legs sharing one id). Ordering is explicitly unspecified.
- **A listed shape is capability, not coverage.** It says the adapter *can* report that shape — not that the account holds anything, nor that the relevant assets are registered for pricing.

> **Deployment consequence — do not read an empty result as an integration bug.** `IPositionEnumerable` is advertised by the *code*, so every meta adapter deployed before this change answers `supportsInterface(0xe8850eeb)` with `false` and exposes no `positionIds()`. A configuration view gating on that bit will therefore show no shapes for any meta protocol until the adapters are redeployed and re-registered — indistinguishable, from the consumer's side, from "nothing is configured". Same caveat as the `protocolName` derivation change.

For meta-adapters this is implemented **once, on `MetaBalanceAdapter`**: the shape set of a meta-adapter *is* its governed instance set, so `positionIds()` reads `NAV_CALCULATOR.getMetaInstances(address(this))` and maps each coordinate through `_instancePositionId`. Each coordinate is resolved through an isolating `try this.instancePositionId(...)`, mirroring the position fan-out: deriving a positionId can revert (a malformed coordinate, or Aave V3's override reading the chain), and `addMetaInstances` does not check a coordinate is even a contract, so one bad entry would otherwise take the whole enumeration down — silently, since a reverting adapter looks identical to an unconfigured one through the consumer's fail-open staticcall. A failing instance is dropped; the rest still enumerate. That makes `_instancePositionId` load-bearing rather than a convenience — a concrete adapter that computes its positionId inline while leaving the hook on its default would advertise ids no position carries, with every test still green. `AaveV3InstancesMetaBalanceAdapter` overrides it for exactly that reason.

> **Adding a protocol.** Add a constant to `ProtocolNames` and a branch to `forProtocolId`. That is the whole change — there is no per-chain config value and no deploy-script wiring for the display name. The `protocol` key that used to live in `contracts-deployment-config/**` has been removed.
>
> **It did NOT feed nothing.** Until this change, `04_DeployBalanceAdapters.s.sol` read that key and passed it as every meta adapter's `protocolName_` constructor argument. Removing it is therefore *not* a config-only cleanup: the constructor signature changed, so all deployed meta adapters must be redeployed and re-registered (`addMetaBalanceAdapter` + `addMetaInstances`) before they report derived names. Until that happens the live adapters keep returning their old stored `_protocolName`, Umbrella included. Do not read the key's removal as "no on-chain consequence".

> **Deployed-vs-source note (2026-07-26).** The Umbrella fix changes a `pure` function, so the currently deployed mainnet adapter (`0x94910a2E35b8749529Dc9555Ed1599cd77E045bF`) still returns `"Aave Umbrella"` on chain until it is redeployed and re-registered. It is deployed on Ethereum only. The redeploy is deliberately folded into the batch redeploy that follows the in-flight adapter PRs, rather than run standalone for a display string; downstream consumers should keep any Umbrella→Aave V3 alias until then.

### 6.3 Assisted adapters (externally-fed) — `IAssistedBalanceAdapter`

Most adapters derive a position purely from on-chain state. A few cannot: the data needed to *find* a position is not enumerable from a `view` — ether.fi / StakeWise / Stader withdrawal & exit requests are keyed by per-account coordinates the contract does not index, and Nexus Mutual staking holds positions as NFTs with no per-account enumeration. For these, an **assistant** records the position coordinates (token ids, request ids, exit tuples) on-chain so the position becomes queryable. This is the third adapter family, peer to plain `BalanceAdapter`s and meta-adapters. (Uniswap V3 / PancakeSwap V3 are **not** here — their `NonfungiblePositionManager` is `ERC721Enumerable`, so they are ordinary meta-adapters; see §7.1 and the amendment on ADR [0015](../../docs/decisions/0015-assisted-balance-adapter-family.md).)

```solidity
interface IAssistedBalanceAdapter is IBalanceAdapter {
    function clearAccount() external; // self-service GC of the caller's cache
}
```

The interface is deliberately minimal — it only *identifies* the family; it does not prescribe the submit/verify surface (each protocol's coordinate shape differs). The family is **permissionless assistant-fed** ([ADR 0018](../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)): the cache mutators (`submit`/`remove`/`clearAccount`) are **`msg.sender`-keyed with no roles**, so a caller can only ever touch its own set. The canonical feeder is a stateless `BalanceAdapterAssistant` (`AssistedBalanceAdapters/assistants/`) the owner Safe **delegatecalls** — under `delegatecall` the adapter sees `msg.sender = Safe = owner`, so the deposit/claim action and the cache write are atomic and self-scoped; a direct (non-delegatecall) call reverts `NotDelegateCall`.

All members extend the single cache base **`AssistedCoordCache`** (`AssistedBalanceAdapters/`): a per-account cache where each coordinate is an opaque `abi.encode`d `bytes` blob (a bare `uint256` id, or StakeWise's `(vault, positionTicket, timestamp)` tuple), deduped by `keccak256`. It provides the `msg.sender`-keyed mutators (cap + fail-loud `CoordinateCacheFull` / `CoordinateNotOwned` custom errors), the single-underlying-asset `IBalanceAdapter` getter surface, and a per-coordinate fail-open self-`staticcall` valuation fan-out (so a revert-prone valuation — e.g. Nexus's `StakingViewer.getTokens` — isolates to that one coordinate). Concrete adapters implement `_validateCoord` / `_removable` / `_valueCoord` / `_coordId` / `_maxCoords` / `_maxLegsPerCoord` and expose a typed `submit`/`remove` that `abi.encode`s their coordinate. They **must** uphold the family invariant: cache only position *coordinates* (never amounts), value every read live on-chain, and re-verify ownership per read — so a faulty or compromised feeder can only **under-report, never over-report**.

**Members on the base** — `NexusMutualStakingPoolsAssistedBalanceAdapter`, `EtherFiWithdrawalQueueAssistedBalanceAdapter`, and `StakeWiseV3ExitQueueAssistedBalanceAdapter` — each paired with a `…Assistant`. (Stader's withdrawal queue is **not** here — it is a plain `BalanceAdapter` that enumerates the account's live requests on-chain via `getRequestIdsByUser`, which is claim-pruned and protocol-capped; see §7.) The NFT-position adapter (Nexus Mutual) caches a per-account `tokenId` set submitted via `submit(id)`: the write **reverts** (`CoordinateNotOwned`) on any id not currently owned by the account, and reads **discard** ids that are no longer owned (so a single stale id never zeroes the account). It values each position live (Nexus stake via `StakingViewer.getTokens`), re-verifying ownership (`tokenInfo`) on every read.

> Full family reference — invariant, cache design, assistant/delegatecall model, error taxonomy, and how to add a new member: [`AssistedBalanceAdapters/README.md`](AssistedBalanceAdapters/README.md). (A proof-verified Merkl rewards adapter previously lived in this family under an older `ASSISTANT_ROLE` agent-fed base; both were removed pending a rewrite of Merkl — retrievable from git history.)

### 6.4 Rejected: registry fetch-once threading

When NAV reads positions it calls `getAdapterPositions(account, address(0))` on every registered adapter, and each adapter that needs to validate a token against the asset registry re-fetches the **whole** registry (`NAVCalculator.getRegisteredAssets()`) per token via `RegisteredAssetLib.find` (see `MetaBalanceAdapter._getAssetInfo`). A read that touches *N* tokens across *M* adapters therefore does *N×M* registry fetches — superficially wasteful.

We implemented and then **deliberately reverted** the obvious optimisation — fetch the registry once in `PriceFeedLib`/`NAVCalculator` and thread the `INAVCalculator.Asset[]` snapshot down through a 3-arg `getAdapterPositions(account, assetFilter, registeredAssets)` overload to every adapter, eliminating the re-fetch. Two reasons:

1. **The gas saving has no consumer.** NAV is read off-chain/asynchronously by the sub/redeem layer ([ADR 0017](../../docs/decisions/0017-lp-valuation-instantaneous-amounts.md)); there is no atomic on-chain caller paying for the populated-path gas, so collapsing *N×M* fetches optimises a cost nobody bears.
2. **It regressed the cheap path.** Eagerly fetching and ABI-copying the registry into *every* adapter call pushed the empty-account read from **<100k to ~166k gas** (the team's `gasOptimization_emptyAccount` guard) — because adapters that early-return for an empty account previously never fetched the registry at all. The optimisation thus made the common cheap path *worse* in exchange for a saving that does not matter.

Conclusion: keep each adapter fetching the registry lazily, only on the path that actually needs it. Re-thread the registry **only if NAV ever becomes a synchronous on-chain consumer** of a mint/redeem flow — at which point the gas does matter and the trade-off flips.

---

## 7. Implemented adapters

### 7.1 Meta-adapters (21)

Meta-adapters extend `MetaBalanceAdapter` (PancakeSwap V2 extends `UniswapV2PoolsMetaBalanceAdapter`, which itself extends the base). The instance set is configured on NAVCalculator via `addMetaInstances`/`removeMetaInstances`.

| Adapter | Description | Constructor | Config key (deploy: `contracts-deployment-config/meta-balance-adapters/<chainId>.json`; register: `nav-config/meta-balance-adapters/<chainId>.json`) |
|---------|-------------|-------------|------------------|
| **AaveV3InstancesMeta** | All Aave V3 instances (Core, Prime, …). Instance coordinate = ProtocolDataProvider address. Up to 2 rows per reserve (`Supplied`/`Collateral` + `Borrowed`). Identity: positionId = `abi.encode(pool)` (one position per instance; reserves distinguished by `balanceAsset` + `positionKind`). | `(navCalculator)` | `AaveV3InstancesMeta`; DataProviders under `instances`. |
| **BalancerV2PoolsMeta** | Wallet-held (unstaked) LP for all Balancer V2 pools. Instance coordinate = raw bytes32 poolId. positionId = `abi.encode(bytes32 poolId)`. One `Supplied` leg per underlying token. | `(vault, navCalculator)` | `BalancerV2PoolsMeta`; poolIds under `instancesRaw`. |
| **BalancerV2GaugesMeta** | Gauge-staked LP + rewards for all Balancer V2 gauges. Instance coordinate = gauge address. positionId = `abi.encode(gauge)`. One `Staking` leg per underlying token + `Rewards` legs (BAL + extras). | `(vault, balancerMinter, navCalculator)` | `BalancerV2GaugesMeta`; gauges under `instances`. |
| **BalancerV3PoolsMeta** | Wallet-held (unstaked) LP for all Balancer V3 pools. Instance coordinate = pool/BPT address. positionId = `abi.encode(pool)`. One `Supplied` leg per underlying token. | `(navCalculator)` | `BalancerV3PoolsMeta`; pools under `instances`. |
| **BalancerV3GaugesMeta** | Gauge-staked LP + rewards for all Balancer V3 gauges. Instance coordinate = gauge address. positionId = `abi.encode(gauge)`. One `Staking` leg per underlying token + `Rewards` legs (BAL + extras). | `(balancerMinter, navCalculator)` | `BalancerV3GaugesMeta`; gauges under `instances`. |
| **CompoundV3CometsMeta** | All Compound V3 (Comet) markets. Instance coordinate = comet address. positionId = `abi.encode(comet)`. Base `Supplied`/`Borrowed`, `Collateral` per collateral, COMP `Rewards`. CometRewards + reward token pinned in constructor. | `(compoundRewards, rewardToken, navCalculator)` | `CompoundV3CometsMeta`; comets under `instances`. |
| **ConvexCurveLPStakingMeta** | Convex-staked Curve LP + rewards for all Convex pools. Instance coordinate = rewarder address. positionId = `abi.encode(rewarder)`. `Staking` legs (one per Curve pool coin, pro-rata from staked LP) + `Rewards` legs (CRV, CVX, up to 8 extras). | `(booster, cvxToken, navCalculator)` | `ConvexCurveLPStakingMeta`; rewarder addresses under `instances`. |
| **CurvePoolsMeta** | Wallet-held (unstaked) LP for all Curve pools. Instance coordinate = pool address. positionId = `abi.encode(pool)`. `Supplied` legs per underlying token. | `(navCalculator)` | `CurvePoolsMeta`; pools under `instances`. |
| **CurveGaugesMeta** | Gauge-staked LP + rewards (CRV + extras) for all Curve gauges. Instance coordinate = gauge address. positionId = `abi.encode(gauge)`. `Staking` + `Rewards` legs. | `(minter, crvToken, navCalculator)` | `CurveGaugesMeta`; gauges under `instances`. |
| **EulerVaultsMeta** | All Euler V2 ERC-4626 vaults — both EulerEarn aggregators (Earn) and core eVaults (Lend/Borrow). Instance coordinate = vault address. positionId = `abi.encode(vault)`. `Supplied` (or `Collateral` if EVC-enabled) leg via `convertToAssets(balanceOf)` + `Borrowed` leg (`debtOf`) for core eVaults. | `(navCalculator)` | `EulerVaultsMeta`; vaults under `instances`. |
| **FluidFTokensMeta** | All Fluid fTokens (ERC4626 lending vaults). Instance coordinate = fToken address. positionId = `abi.encode(fToken)`. One `Supplied` leg per fToken (`convertToAssets(balanceOf)`). | `(navCalculator)` | `FluidFTokensMeta`; fTokens under `instances`. |
| **FluidVaultsMeta** | All Fluid T1 vaults. Instance coordinate = vault address. positionId = `abi.encode(vault)`. `Collateral` (supply) + `Borrowed` (debt) legs per vault. VaultResolver pinned in constructor. | `(vaultResolver, navCalculator)` | `FluidVaultsMeta`; vaults under `instances`. |
| **GearboxV3MarketsMeta** | All Gearbox V3 ERC4626 farming pools (the passive supply side). Instance coordinate = pool/market address. positionId = `abi.encode(market)`. One `Supplied` leg per market (`convertToAssets(balanceOf)`). | `(navCalculator)` | `GearboxV3MarketsMeta`; markets under `instances`. |
| **GearboxV3CreditAccountsMeta** | Gearbox V3 borrow-side positions held in Credit Accounts. Instance coordinate = credit account address. positionId = `abi.encode(creditAccount)`. One `Borrowed` leg (total owed in the pool's underlying) + one `Collateral` leg per enabled token. Ownership verified via `creditAccountInfo(ca).borrower == account`. | `(navCalculator)` | `GearboxV3CreditAccountsMeta`; credit accounts under `instances`. |
| **MorphoVaultsMeta** | All Morpho ERC4626 vaults (MetaMorpho). Instance coordinate = vault address. positionId = `abi.encode(vault)`. One `Supplied` leg per vault (shares → underlying). | `(navCalculator)` | `MorphoVaultsMeta`; vaults under `instances`. |
| **MorphoMarketsMeta** | All Morpho markets. Instance coordinate = raw bytes32 marketId. positionId = `abi.encode(bytes32 marketId)`. Up to 3 rows per market (`Collateral`, `Supplied`, `Borrowed`). Morpho contract pinned in constructor. | `(morpho, navCalculator)` | `MorphoMarketsMeta`; marketIds under `instancesRaw`. |
| **StakeWiseV3VaultsMeta** | All StakeWise V3 vaults. Instance coordinate = vault address. positionId = `abi.encode(vault)`. `Staking` (vault shares → assets) + `Borrowed` (osToken debt) legs. Underlying token and osToken vault controller pinned in constructor. | `(underlyingToken, osTokenVaultController, navCalculator)` | `StakeWiseV3VaultsMeta`; vaults under `instances`. |
| **UniswapV2PoolsMeta** | LP of all Uniswap V2 pairs. Instance coordinate = pair address. positionId = `abi.encode(pair)`. One `Supplied` leg per token (dilution-adjusted pro-rata reserves). Also serves SushiSwap/PancakeSwap V2 forks. | `(navCalculator)` | `UniswapV2PoolsMeta`; pairs under `instances`. |
| **PancakeSwapV2PoolsMeta** | Thin subclass of `UniswapV2PoolsMeta` (PancakeSwap V2 is a byte-for-byte V2 fork). | `(navCalculator)` | `PancakeSwapV2PoolsMeta`; pairs under `instances`. |
| **UniswapV3PoolsMeta** | Uniswap V3 LP across all configured pools. Instance coordinate = pool address. Enumerates the account's NFTs on-chain via the `ERC721Enumerable` NonfungiblePositionManager (`balanceOf` → `tokenOfOwnerByIndex` → `positions`, bounded by `MAX_POSITIONS` = 1000 — a griefing/DoS guard since `balanceOf` is attacker-inflatable via force-minted NFTs; see ADR 0010 for the rationale), keeping the NFTs whose `(token0, token1, fee)` matches the pool. positionId = `abi.encode(pool)`; up to 4 legs per NFT — `Supplied` ×2 (in-range split off the pool's live `slot0`) + `Fees` ×2 (full unclaimed = `feeGrowthInside`-since-poke + settled `tokensOwed`). The NFT tokenId rides in `positionInstanceId`. **Both** pool tokens must be registered or the whole instance is dropped. NonfungiblePositionManager pinned in constructor. Spot manipulation of the split is mitigated by the asynchronous NAV consumer (ADR 0017); links GPL-2.0-or-later Uniswap math (ADR 0008). | `(positionManager, navCalculator)` | `UniswapV3PoolsMeta`; pools under `instances`. |
| **PancakeSwapV3PoolsMeta** | Thin subclass of `UniswapV3PoolsMeta` overriding only the protocol-identity slugs and the `_slot0` read (PancakeSwap V3's `slot0().feeProtocol` is `uint32`, not Uniswap's `uint8`). | `(positionManager, navCalculator)` | `PancakeSwapV3PoolsMeta`; pools under `instances`. |

> Uniswap V3 / PancakeSwap V3 **are** meta-adapters: their `NonfungiblePositionManager` is `ERC721Enumerable`, so an account's LP NFTs are discoverable on-chain with no off-chain assistant. (They were briefly assisted adapters — see the amendment on ADR [0015](../../docs/decisions/0015-assisted-balance-adapter-family.md); the live-`slot0` valuation is unchanged.)

### 7.2 Per-instance singleton adapters (12)

These adapters are a single immutable deployment each. The plain ones implement `IBalanceAdapter` directly (not `MetaBalanceAdapter`); the assisted ones (`EtherFiWithdrawalQueueAssisted`, `StakeWiseV3ExitQueueAssisted`, `NexusMutualStakingPoolsAssisted`) extend `AssistedCoordCache` (see §6.3) — **permissionless & `msg.sender`-keyed** (no `admin`/`assistant` args; fed on-chain by a delegatecall `BalanceAdapterAssistant`, [ADR 0018](../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)). Both plain and assisted constructors take protocol-specific addresses and `navCalculator` (the assistant feed is a separate contract, not a constructor arg). Identity is expressed via compile-time `bytes32` constants (`PROTOCOL_BRAND` / `PROTOCOL_ID` / `PROTOCOL_SUB_ID = ProtocolIds.<CONSTANT>`) and `positionId` computed at query time via `abi.encode(...)`.

| Adapter | Description | Constructor | Notes |
|---------|-------------|-------------|-------|
| **ERC20DefaultBalanceAdapter** | Wallet ERC20 and native balances for all registered assets. protocolId = `WALLET`, positionId = `abi.encode(asset)`, kind = `Wallet`. Auto-registered at init. | `(navCalculator, initialAssets[])` | Default adapter; registered by `NAVCalculator.initialize`. |
| **AaveV3SafetyModule** | Aave V3 Safety Module stake tokens (stkAAVE, stkABPT, stkABPTv2, stkGHO). Stake-token set hardcoded at construction. Up to three legs per token, **all sharing positionId `abi.encode(stakeToken)`** (no discriminator): a locked `Staking` leg (`isLocked=true` — active stake plus any cooling/expired cooldown; active stake is non-withdrawable), an unlocked `Staking` leg (`isLocked=false`, only when a cooldown has elapsed and is still inside the unstake window), and a `Rewards` leg (told apart by `positionKind`). Stake tokens without the V3 cooldown ABI degrade to a single locked-stake leg. | `(navCalculator)` | protocolSubId = `AAVE_V3_SAFETY_MODULE` (protocolId `AAVE_V3`, brand `AAVE`). Mainnet only. |
| **AaveUmbrella** | Aave Umbrella stake tokens discovered dynamically via `RewardsController.getAllAssets()`. Up to three legs per token, **all sharing positionId `abi.encode(stakeToken)`** (no discriminator): a locked `Staking` leg (`isLocked=true` — active stake plus any cooling/expired cooldown), an unlocked `Staking` leg (`isLocked=false`, only when a cooldown has elapsed and is still inside the withdrawal window) — both in the bare reserve — and a `Rewards` leg (told apart by `positionKind`). Picks up new stake tokens via governance without redeploy. | `(rewardsController, navCalculator)` | protocolSubId = `AAVE_V3_UMBRELLA` (protocolId `AAVE_V3`, brand `AAVE`). See `docs/decisions/0006-aave-umbrella-balance-adapter.md`. |
| **Cap** | Cap protocol balances reported as USDC, as **two legs**: held cUSD (`["Stablecoin", "cUSD"]`) and staked stcUSD (`["Savings", "stcUSD"]`). positionId = `abi.encode(cUSD)` / `abi.encode(stcUSD)` per leg; cUSD `Supplied`, staked stcUSD `Staking`. | `(cUsd, stcUsd, usdc, navCalculator)` | protocolSubId = `CAP` (brand and protocolId also `CAP`). |
| **EthenaCooldownBalanceAdapter** | USDe owed to an account in the sUSDe unstaking cooldown. Reads the single per-account `UserCooldown` slot on `StakedUSDeV2` (`cooldowns(account)` → `{cooldownEnd, underlyingAmount}`) and reports `underlyingAmount` as one position denominated in USDe; non-zero only while an unstake is in flight. positionId = `abi.encode(address sUSDe)` (static). `Supplied` kind; `isLocked=true` until the cooldown elapses, then `false`. | `(stakedUSDe, underlyingToken, navCalculator)` | protocolSubId = `ETHENA_COOLDOWN` (protocolId and brand `ETHENA`). Mainnet only. |
| **KelpWithdrawalQueue** | Kelp DAO rsETH exit queue (`LRTWithdrawalManager`). Emits **one `Supplied` leg per open request** (per payout asset), valued at `expectedAssetAmount`. Payout-asset set discovered at runtime; the payout asset is carried in `balanceAsset`. positionId = `abi.encode(address withdrawalManager)` (static, shared by all requests); the request's `userNonce` rides in `positionInstanceId`, never in positionId. A request is `isLocked=false` only once `userNonce < nextLockedNonce(asset)` **and** the block delay (`withdrawalStartBlock + withdrawalDelayBlocks()`) has passed, else `isLocked=true`. **No adapter-level request cap** — the full per-asset set is read (Kelp requests are keyed to the unstaking `msg.sender`, so they cannot be third-party-injected; a large count is self-inflicted). Balance getters report the summed total. | `(withdrawalManager, navCalculator)` | protocolSubId = `KELP_WITHDRAWAL` (protocolId and brand `KELP`). Mainnet only. |
| **LidoWithdrawalQueue** | Lido `WithdrawalQueueERC721`. Emits **one `Supplied` leg per open (un-claimed) withdrawal request** (enumerated via `getWithdrawalRequests`): finalized → exact claimable ETH (`getClaimableEther`, `isLocked=false`); not finalized → `amountOfStETH` (`isLocked=true`). positionId = `abi.encode(address withdrawalQueue)` (static, shared by every request); the ERC721 request id rides in `positionInstanceId`, never in positionId (it is ephemeral — burned on claim). `Supplied` kind, native-ETH. **No adapter-level request cap** — the full set is read (an O(1) `balanceOf` short-circuits the zero case); a griefed/third-party-inflated list makes only *that* account's NAV read expensive (liveness-only fail-safe, [`docs/operations/stader-withdrawal-queue-griefing.md`](../../docs/operations/stader-withdrawal-queue-griefing.md)). The balance getters report the summed total. | `(withdrawalQueue, underlyingToken, navCalculator)` | protocolSubId = `LIDO_WITHDRAWAL` (protocolId and brand `LIDO`). Mainnet only. |
| **EtherFiWithdrawalQueueAssisted** | ether.fi in-flight withdrawal-queue ETH. **permissionless** (`msg.sender`-keyed) cache of the caller's `WithdrawRequestNFT` tokenIds via `submit(tokenId)` (**ids only, never amounts**); values each live (`getClaimableAmount` / `getRequest`+`amountForShare`) and re-verifies `ownerOf` per read (non-owned discarded). Emits **one `Supplied` leg per owned cached request** (finalized → `isLocked=false`, pending → `isLocked=true`); positionId = `abi.encode(address withdrawRequestNFT)` (static, shared), native-ETH; the NFT tokenId rides in `positionInstanceId`, never in positionId. The caller's cached tokenIds are exposed via `tokenIdsOf(account)`. Balance getters report the summed total. | `(withdrawRequestNft, liquidityPool, underlyingToken, navCalculator)` | protocolSubId = `ETHERFI_WITHDRAWAL` (protocolId and brand `ETHERFI`). Assisted-family member (ADR 0015), permissionless assistant-fed via a delegatecall `BalanceAdapterAssistant` ([ADR 0018](../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)). The assistant can only under-report, never over-report. |
| **NexusMutualStakingPoolsAssisted** | Nexus Mutual V2 staked NXM across all staking pools (assisted; **permissionless** assistant-fed). The caller submits its `StakingNFT` tokenIds via `submit(tokenId)` (the NFT is not ERC721Enumerable — no per-owner view); the write **reverts** `CoordinateNotOwned` on any id whose `tokenInfo` owner ≠ account. `StakingViewer.getTokens` values **each** owned, cached id into a `Staking` leg (active + expired stake) + a `Rewards` leg, both NXM — one pair **per StakingNFT tokenId** — re-verifying ownership via `tokenInfo` per read (discarding ids no longer owned). positionId = `abi.encode(address stakingPool)` (the deterministic pool contract from `StakingViewer.stakingPool(poolId)`); the StakingNFT id is surfaced in `positionInstanceId`. (The no-arg balance getters return the summed NXM total via `getAggregatedTokens`.) | `(stakingNft, stakingViewer, underlyingToken, navCalculator)` | protocolSubId = `NEXUS_MUTUAL_STAKING_POOLS` (slug `nexus-mutual-staking-pools`; protocolId and brand `NEXUS_MUTUAL`). Mainnet only; underlying = NXM (priced PR #71). `MAX_TOKEN_IDS` (256) caps the per-account cache. Assisted-family member (ADR 0015), permissionless assistant-fed ([ADR 0018](../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)); cache stores ids only, never amounts. |
| **StakeWiseV3ExitQueueAssisted** | StakeWise V3 in-flight exit-queue assets. **permissionless** (`msg.sender`-keyed) cache of the caller's `(vault, positionTicket, timestamp)` tuples via `submit(vault, positionTicket, timestamp)` (**coordinates only, never amounts**); values each live as `calculateExitedAssets(account,…).exitedAssets + convertToAssets(leftShares)` (out-of-range index path for fully-pending positions), with `calculateExitedAssets(receiver=account)` as the on-chain ownership check and a `VaultsRegistry` membership check at submit time. Emits legs **per request (positionTicket)**: up to two per ticket — a claimable leg (`exitedAssets`, `isLocked=false`) and a still-queued leg (`convertToAssets(leftShares)`, `isLocked=true`) — both carrying the ticket id in `positionInstanceId`. positionId = `abi.encode(address vault)` (static, per vault, shared by a vault's tickets), native-ETH, `Supplied` kind. The caller's cached `(vault, ticket, timestamp)` tuples are exposed via `positionsOf(account)`. Balance getters report the summed total. | `(vaultsRegistry, underlyingToken, receiptSymbol, navCalculator, exitClaimDelay)` | protocolSubId = `STAKEWISE_V3_EXIT` (protocolId `STAKEWISE_V3`, brand `STAKEWISE`). Mainnet only. Assisted-family member (ADR 0015), permissionless assistant-fed via a delegatecall `BalanceAdapterAssistant` ([ADR 0018](../../docs/decisions/0018-assistant-fed-assisted-balance-adapters.md)), sibling of `EtherFiWithdrawalQueueAssisted`. The assistant can only under-report, never over-report. |
| **SparkLend** | Spark lending positions. Two legs per reserve (`Supplied`/`Collateral` + `Borrowed`). positionId = `abi.encode(pool)` (one position per instance; reserves distinguished by `balanceAsset` + `positionKind`). | `(dataProvider, navCalculator)` | protocolSubId = `SPARK_LEND` (protocolId and brand `SPARK`). Standalone adapter mirroring the Aave V3 lending pattern (same `ProtocolDataProvider` ABI). |
| **StaderWithdrawalQueue** | Stader `UserWithdrawalManager` pending unstake requests (enumerated via `getRequestIdsByUser`). Emits **one `Supplied` leg per open request**: finalized → `ethFinalized` (`isLocked=false`), pending → `ethExpected` (`isLocked=true`). positionId = `abi.encode(address userWithdrawalManager)` (static, shared); the request id rides in `positionInstanceId`, never in positionId. Pending legs are additionally capped at the live ETHx→ETH rate (`_cappedPending`, mirrors Lido). **No adapter-level request cap** — the full list is read (protocol-bounded to 1000); a griefed queue makes only *that* account's NAV read expensive, a liveness-only fail-safe (see [`docs/operations/stader-withdrawal-queue-griefing.md`](../../docs/operations/stader-withdrawal-queue-griefing.md)). Balance getters report the summed total. | `(userWithdrawalManager, underlyingToken, navCalculator)` | protocolSubId = `STADER_WITHDRAWAL` (protocolId and brand `STADER`). Mainnet only; underlying configured to WETH. |

Protocol adapters typically take **NAVCalculator** in the constructor to read the asset registry (symbol, decimals) so they can build correct `Asset` structs.

---

## 8. How to create a new adapter

### 8.1 Contract layout

1. Add the slug(s) to `src/utils/ProtocolIds.sol` (brand / ecosystem / per-product sub-slug as needed) and document the `positionId` ABI-decode schema in its NatSpec comment. Choose `abi.encode(primaryKey)` where `primaryKey` is the most specific stable on-chain identifier for this position.

2. Create a contract that implements `IBalanceAdapter` and `IERC165` (or extend `MetaBalanceAdapter` for a multi-instance adapter).

3. Declare the compile-time identity constants:
   ```solidity
   bytes32 private constant PROTOCOL_BRAND = ProtocolIds.<BRAND>;
   bytes32 private constant PROTOCOL_ID = ProtocolIds.<ECOSYSTEM>;
   bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.<PRODUCT>;
   ```
   For single-product, unversioned protocols all three may be the same constant.

4. Implement **`getAdapterPositions(address account, address assetFilter)`**:
   - Query the protocol for the account's positions.
   - For each position, build `PositionBalance` with:
     - `balanceAsset`: `Asset` from NAVCalculator's registry (must match registry for filtering).
     - `balanceAdapter`: `address(this)`.
     - `amount`: positive `uint256` in asset decimals.
     - `isDebt`: `true` for debts, `false` for everything else.
     - `protocolBrand` / `protocolId` / `protocolSubId`: `PROTOCOL_BRAND` / `PROTOCOL_ID` / `PROTOCOL_SUB_ID`.
     - `positionId`: `abi.encode(...)` of the position's **static, timeless** key. For withdrawal-queue / cooldown positions, encode the immutable anchor (`abi.encode(address <queue/manager/vault/sUSDe>)`) — never a per-request id — and split the holding into a claimable leg (`isLocked=false`) and a locked leg (`isLocked=true`) that share it.
     - `positionKind`: one of `PositionKind.Wallet / Supplied / Borrowed / Collateral / Staking / Rewards / Fees`.
     - `isLocked`: `true` = not withdrawable now (pending withdrawal OR active/cooling stake); `false` = withdrawable now. `false` for non-queue/non-cooldown/non-staking-with-cooldown adapters. Part of the identity key.
     - `positionInstanceId`: the ephemeral per-item coordinate (NFT id / request id / ticket) as `bytes32`, or `bytes32(0)` when the adapter has no per-item granularity.
   - If `assetFilter != address(0)`, return only positions for that asset (or empty).

5. Implement **`getAdapterBalances`** and **`getAdapterBalanceForAsset`** (per-asset amounts and debt flags). Meta-adapters return empty arrays for these (they are not used by the NAV path).

6. Implement **`underlyingAssetsSupported()`**: return the list of underlying token addresses this adapter can report.

7. Implement **`supportsInterface(bytes4)`**: return `true` for `type(IBalanceAdapter).interfaceId` and `type(IERC165).interfaceId`.

8. Implement **`IPositionDescribable.protocolName()`** and **`positionLabels(bytes positionId)`**, which derives the display hierarchy lazily from `positionId` (it runs only in the verbose reads, not on the NAV hot path):
   - Per-instance adapters return a fixed array (e.g. `["Safety Module"]`).
   - Meta-adapters derive labels on-chain (read token symbols, vault/pool names) and return `_labels("Category", leaf)`.
   - Decode `positionId` with `_pidAddress` / `_pidWord` (meta) or the equivalent `length != 32` + `raw >> 160` check (plain/assisted) — **never** `abi.decode(pid, (address))`, which reverts on a dirty word and labels an over-long one from its first word. See §6.2.

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
import {ProtocolNames} from "src/utils/ProtocolNames.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MyProtocolBalanceAdapter is IBalanceAdapter, IPositionDescribable {
    bytes32 private constant PROTOCOL_BRAND = ProtocolIds.MY_PROTOCOL;
    bytes32 private constant PROTOCOL_ID = ProtocolIds.MY_PROTOCOL;
    bytes32 private constant PROTOCOL_SUB_ID = ProtocolIds.MY_PROTOCOL;

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
            protocolBrand: PROTOCOL_BRAND,
            protocolId: PROTOCOL_ID,
            protocolSubId: PROTOCOL_SUB_ID,
            positionId: abi.encode(address(PROTOCOL)),
            positionKind: PositionKind.Supplied,
            isLocked: false,
            positionInstanceId: bytes32(0) // no per-item granularity
        });
        return out;
    }

    // IPositionDescribable — protocolName() plus positionLabels() (display only; derived lazily from positionId)
    // Names the PROTOCOL, not the product (see 6.2). Product goes in positionLabels().
    function protocolName() external pure returns (string memory) { return ProtocolNames.MY_PROTOCOL; }

    function positionLabels(bytes calldata) external pure returns (string[] memory out) {
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
