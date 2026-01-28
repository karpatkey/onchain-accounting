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
| `protocol`       | `string` | Protocol name (e.g. `"wallet"`, `"Compound v3 USDC"`). |
| `positionDetail` | `string` | Short label (e.g. `"Holding"`, `"Collateral"`, `"Borrow"`). |

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
| `getOracleBalance(account)` | Returns `(assets[], balances[])` — net balances (positive = credit, negative = debt). Optional for NAV path but part of the interface. |
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

---

## 7. Implemented adapters

| Adapter | Description | Protocol string / notes |
|---------|-------------|-------------------------|
| **ERC20DefaultOracle** | Wallet ERC20 and native balances for all registered assets. | `"wallet"`, positionDetail `"Holding"`. Auto-registered at init. |
| **AaveV3Instance** | Aave v3 positions (supply/borrow) for one market. | Configurable protocol name. |
| **AaveV3SafetyModule** | Aave safety module (e.g. staked AAVE). | |
| **Aura** | Aura vault/lp positions. | |
| **BalancerV3** | Balancer V3 positions. | |
| **CompoundV3Comet** | Compound V3 Comet: base borrow, collaterals, rewards. | Constructor: protocol string (e.g. "Compound v3 USDC"). Uses NAVCalculator for asset metadata. |
| **DaiDsr** | DAI Savings Rate. | |
| **GMX** | GMX positions. | |
| **MorphoMarket** | Morpho market positions. | |
| **SkySavingsUsds** | Sky savings USDS. | |
| **SparkLend** | Spark lending positions. | |
| **StakeWiseV3OsToken** | StakeWise V3 osToken. | |
| **StakeWiseV3Vault** | StakeWise V3 vault. | |

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
     - `protocol`: e.g. `"YourProtocol Name"`.
     - `positionDetail`: e.g. `"Collateral"`, `"Borrow"`, `"Rewards"`.
   - If `assetFilter != address(0)`, return only positions for that asset (or empty).
   - You may return only assets that are registered in NAVCalculator (like ERC20DefaultOracle) to avoid unnecessary work; unregistered positions are dropped by NAVCalculator anyway.
4. Implement **`getOracleBalance`** and **`getOracleBalanceForAsset`** (net balances, signed: positive = credit, negative = debt). These can derive from the same data as `getOraclePositions` or be implemented with a simpler path.
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
