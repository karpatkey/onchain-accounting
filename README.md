# Onchain Accounting

Onchain infrastructure for portfolio accounting: **balances** (across protocols), **prices** (multi-feed: Chainlink, Redstone, API3, and custom), **NAV** (Net Asset Value calculation), and **cross-chain bridge escrow** with pluggable adapters.

---

## What This Project Does

| Module   | Purpose |
|----------|--------|
| **Balances** | Registry of balance adapters. Each adapter reports positions (balances) for an account in one or more protocols (e.g. Aave, Compound III, Morpho). Used by NAVCalculator to aggregate holdings. |
| **Prices**   | Registry of **N price feeds per asset** (N ≥ 1). Feed types: `Chainlink`, `Redstone`, `API3`, `Custom`. On every read, `_selectFeed` picks the **freshest non-stale feed** (freshest-wins); stale is returned only when every feed fails. Handles heartbeat staleness, clock-skew normalisation, and L2 sequencer uptime checks. |
| **NAV**      | Single contract that extends Prices + Balances. Registers assets with price feeds, registers balance adapters, and computes **NAV** for an account in a chosen quote currency (e.g. USD or a token). |
| **Bridge**   | **BridgeEscrow** holds assets and tracks invoices; authorized accounts call `depositAndBridge` to bridge to another chain. **Adapters** (Across, CCIP, CCTP, Gnosis, Stargate, Superchain) implement protocol-specific logic. On the destination chain, completion triggers `releaseByInvoiceId` so the escrow sends assets to the account. |

There is no tokenized-share or subscription/redemption logic in this repo; that would sit in a separate layer that uses NAV and/or the bridge as primitives.

---

## Repository Structure

```
src/
├── balances/                    # Balance adapters and registry
│   ├── Balances.sol             # Abstract registry (adapters, assets, meta-instance set)
│   ├── IBalances.sol
│   ├── IBalanceAdapter.sol
│   ├── IMetaBalanceAdapter.sol  # Extends above; per-instance fan-out
│   ├── MetaBalanceAdapter.sol   # Abstract base for all 19 meta-adapters (identity + _leg hooks)
│   ├── IAssistedBalanceAdapter.sol
│   ├── AssistedBalanceAdapter.sol # Abstract base for the agent-fed family (OZ AccessControl)
│   ├── IPositionDescribable.sol # Human-readable labels (ERC165)
│   ├── LabelLib.sol             # Fail-open ERC20 name()/symbol() reads for labels
│   ├── RegisteredAssetLib.sol   # Asset-registry helper
│   ├── BalanceAdapters/         # Plain per-protocol singleton adapters
│   ├── MetaBalanceAdapters/     # Meta-adapters (one per protocol family); per-protocol subdirs
│   └── AssistedBalanceAdapters/ # Agent-fed adapters. Full inventory in src/balances/BALANCE_ADAPTERS.md.
├── prices/                      # Price feeds
│   ├── Prices.sol               # Abstract: N feeds/asset, freshest-wins, L2 sequencer
│   ├── IPrices.sol
│   ├── ICustomPriceFeed.sol
│   ├── PriceFeedLib.sol         # External library (EIP-170 size management)
│   └── protocols/               # Custom price adapters (sDAI, wstETH, rsETH, osToken, …)
├── nav/                         # NAV calculator
│   ├── NAVCalculator.sol        # UUPS upgradeable; inherits Prices + Balances; verbose (labeled) position APIs
│   ├── INAVCalculator.sol
│   └── NAVRegistryLib.sol       # External library for registry mutations (EIP-170)
├── bridge/                      # Cross-chain escrow and adapters
│   ├── BridgeEscrow.sol
│   ├── BridgeAdapter.sol        # Base for adapters
│   ├── InvoiceDataLib.sol       # Message payload encoding
│   ├── adapters/                # Per-bridge adapters (Across, CCIP, CCTP, …)
│   └── BRIDGE_ADAPTERS.md       # Bridge design and how to add adapters
├── utils/                       # ProtocolIds.sol, PositionKind.sol, OracleArgumentChecks.sol, …
├── constants.sol
└── errors.sol

test/
├── balances/           # Balances + balance adapters (unit + fork)
├── bridge/             # BridgeEscrow + adapters (unit + fork)
├── nav/                # NAVCalculator (unit, fuzz, invariant, fork)
└── prices/             # Prices + custom price adapters
```

---

## Balances

- **`Balances`** (abstract): Holds a **global list of balance adapters**. Each asset can have multiple adapters (e.g. ERC20 default + protocol-specific). It does not implement NAV or pricing.
- **`IBalanceAdapter`**: Implemented by every balance adapter. Key methods:
  - `getAdapterPositions(account, assetFilter)` → list of **PositionBalance** entries with typed identity (the 3-level `protocolBrand` / `protocolId` / `protocolSubId` bytes32 taxonomy — each a keccak256 hash of a canonical pluralised slug, broadest to narrowest — plus `positionId` abi-encoded key, `positionKind` enum, and `positionInstanceId`)
  - `getAdapterBalances(account)` → parallel arrays of assets, amounts (non-negative magnitude), and `isDebt` flags
  - `getAdapterBalanceForAsset(account, asset)` → `(amount, isDebt)` for a single asset (gas-optimized)
  - `underlyingAssetsSupported()` → which assets this adapter reports on
- **Protocol adapters** in `src/balances/{BalanceAdapters,MetaBalanceAdapters,AssistedBalanceAdapters}/`:
  - **ERC20DefaultBalanceAdapter**: Plain ERC20 and native token balances.
  - **19 meta-adapters** ([ADR 0010](docs/decisions/0010-meta-balance-adapters.md)): one immutable contract per protocol family covers every instance of that protocol. The **instance set** (which vaults, pools, or markets to query) is a `bytes32[]` held on `NAVCalculator` and set by the MANAGER role via `addMetaInstances/removeMetaInstances` — **adding a pool is a config TX, not a deploy**. The instance coordinate is the pool/vault/market address widened to `bytes32` for most protocols, or a raw `bytes32` for Morpho market IDs and Balancer V2 pool IDs. Per-instance reverts are isolated so one bad instance cannot zero out the batch. Families: `MorphoVaultsMeta`, `MorphoMarketsMeta`, `AaveV3InstancesMeta`, `EulerVaultsMeta`, `BalancerV3PoolsMeta`, `BalancerV3GaugesMeta`, `BalancerV2PoolsMeta`, `BalancerV2GaugesMeta`, `UniswapV2PoolsMeta`, `PancakeSwapV2PoolsMeta`, `GearboxV3MarketsMeta`, `GearboxV3CreditAccountsMeta`, `CompoundV3CometsMeta`, `FluidFTokensMeta`, `FluidVaultsMeta`, `StakeWiseV3VaultsMeta`, `CurvePoolsMeta`, `CurveGaugesMeta`, `ConvexCurveLPStakingMeta`. (Uniswap V3 / PancakeSwap V3 are **not** meta-adapters — their NFT positions are non-enumerable, so they are assisted; see below.)
  - **Assisted (agent-fed) adapters** ([ADR 0015](docs/decisions/0015-assisted-balance-adapter-family.md)): for positions that cannot be derived from on-chain state alone, a trusted `ASSISTANT_ROLE` submits coordinates and the adapter values them live, re-verifying ownership per read (the assistant can only under-report): `MerklRewardsAssisted` (proofs), `EtherFiWithdrawalQueueAssisted` / `StakeWiseV3ExitQueueAssisted` (withdrawal coordinates), and the NFT-`tokenId`-cached `UniswapV3PoolsAssisted` / `PancakeSwapV3PoolsAssisted` / `NexusMutualStakingPoolsAssisted` (`submitTokenIds` — write reverts on a non-owned id, reads discard ids no longer owned).
  - **14 per-instance singleton adapters** (no meta equivalent needed): **SparkLend** (AaveV3 logic inlined), **AaveV3SafetyModule**, **AaveUmbrella**, **Cap**, **MerklRewardsAssisted**, **StaderWithdrawalQueue**, **KelpWithdrawalQueue**, **LidoWithdrawalQueue**, **EtherFiWithdrawalQueueAssisted**, **StakeWiseV3ExitQueueAssisted**, **NexusMutualStakingPoolsAssisted**, **UniswapV3PoolsAssisted**, **PancakeSwapV3PoolsAssisted**, **EthenaCooldown**. All implement `IPositionDescribable` (ERC165-discoverable human-readable labels). Full inventory + framework reference in [`src/balances/BALANCE_ADAPTERS.md`](src/balances/BALANCE_ADAPTERS.md).

Balance adapters return **PositionBalance** (`balanceAsset`, `balanceAdapter`, `amount`, `isDebt`, `protocolBrand` bytes32, `protocolId` bytes32, `protocolSubId` bytes32, `positionId` bytes, `positionKind` enum, `isLocked` bool, `positionInstanceId` bytes32). The 3-level `protocolBrand` / `protocolId` / `protocolSubId` taxonomy groups broadest-to-narrowest (e.g. `aave` → `aave-v3` → `aave-v3-lending`); `protocolSubId` is the stable identity layer. **`PositionKind`** classifies each leg: `Wallet` · `Supplied` · `Borrowed` · `Collateral` · `Staking` (principal locked behind an unstake action — Safety Module, Umbrella, StakeWise vaults, gauge/Convex-staked LP) · `Rewards` (accrued reward tokens) · `Fees` (uncollected LP/protocol fees). `amount` is always positive; `isDebt` carries the sign for NAV. `isLocked` marks the not-withdrawable portion: withdrawal-queue / cooldown adapters split a holding into a claimable (`isLocked=false`) and a pending (`isLocked=true`) leg that share one static `positionId`; `isLocked` is a mutable per-leg status flag and is NOT part of the reconciliation key — the two legs share one key and are summed. `positionInstanceId` carries the ephemeral per-item id (Uniswap V3 NFT id, withdrawal request id, …) when one exists. The NAVCalculator enriches these with prices to get **Position** (same fields + quoteAsset, value, price, stale) and optionally a **VerbosePosition** (adds `protocolName` and a `labels` `string[]` display hierarchy below it, leaf last). Both are derived **lazily** in the verbose reads from `IPositionDescribable` (`protocolName()` + `positionLabels(positionId)` — computed off the static `positionId`, not carried on every `PositionBalance`); display only, not identity. Full struct schema, per-protocol positionId decode tables, reconciliation key, and TypeScript examples: [`docs/howto/position-identity-schema.md`](docs/howto/position-identity-schema.md).

---

## Prices

- **`Prices`** (abstract): Maps each asset to a **`PriceFeedConfig[]` array** — N ≥ 1 feeds per asset. On every `latestPrice(asset)` call, `_selectFeed` iterates all feeds and picks the **freshest non-stale survivor** (freshest-wins). Only returns `stale=true` when every feed fails. Feeds are added via `addPriceFeed` and removed via `removePriceFeed` (reverts on last feed). L2 sequencer uptime check (configurable grace period, minimum 1 hour) is applied on top.
- **Feed types** (`PriceType` enum):
  - `Chainlink` — `AggregatorV3Interface.latestRoundData()`; staleness = heartbeat timeout.
  - `Redstone` — Redstone Classic Push; same read path as Chainlink.
  - `API3` — `Api3ReaderProxyV1` (implements `AggregatorV2V3Interface`); deterministic cross-chain address; proxy returns 18 dec, normalised to 8 dec internally.
  - `Custom` — Implements `ICustomPriceFeed` (`getLatestPrice() → (price, stale)` + `latestRoundData()` for freshness ranking). Used for derived prices where the staleness condition spans multiple constituent Chainlink feeds (the `getLatestPrice` stale bool is the primary gate; `latestRoundData().updatedAt` is used for heartbeat + freshness ranking). `updatedAt == 0` is treated as `block.timestamp - 1` so rate-only feeds participate but yield to feeds with a real push timestamp.
- **Existing custom feeds** in `src/prices/protocols/`: yield-bearing stable wrappers (`sDAI`, `sUSDS`, `sUSDe`, `sXDAI`, `syrupUSDC`), liquid (re)staking tokens (`wstETH`, `rETH`, `cbETH`, `rsETH`, `eETH`, `weETH`, `ezETH`, `ETHx`, `ankrETH`, `osToken`), and derived feeds (`LDO`, `ETH+`, `CrossRate`, `NXM`). L2 variants (`*_L2_*`) read Chainlink-secured rate feeds on L2 rather than L1 rate providers.
- **`PriceFeedLib`**: external Solidity library (`DELEGATECALL`) holding the `selectFeed` loop, feed-management functions, **and NAVCalculator's read/compute engine** (NAV, positions, health, value) — extracted to stay under EIP-170's 24 576-byte bytecode limit (see [ADR 0011](docs/decisions/0011-nav-size-and-shared-abstractions.md)). Deployed at a deterministic CREATE2 address (linked in `foundry.toml`).
- Full architecture, staleness design, and how to add a custom feed: [`src/prices/PRICE_ADAPTERS.md`](src/prices/PRICE_ADAPTERS.md).

---

## NAV (NAVCalculator)

- **`NAVCalculator`**: Inherits **Prices** and **Balances**, and adds:
  - `initialize(admin, chainlinkL2SequencerUptimeFeed, nativeTokenSymbol)`: deploys **ERC20DefaultBalanceAdapter**, inits Prices and Balances. Pass `address(0)` for the sequencer feed on chains without L2 sequencer (Mainnet, Gnosis).
  - **MANAGER** role: `registerAsset(asset, feed, priceType, heartbeat)`, `addPriceFeed` / `removePriceFeed`, `addBalanceAdapters` / `removeBalanceAdapters`, `addMetaInstances/removeMetaInstances`.
  - **Assets**: Registered via `registerAsset` (sets price feed + adds to asset registry). Additional feeds per asset via `addPriceFeed`; removal via `removePriceFeed` (cannot remove the last feed).
  - **Balance adapters**: Added with `addBalanceAdapters`; ERC165-checked for `IBalanceAdapter`. For meta-adapters, also call `addMetaInstances`/`removeMetaInstances` to configure the instance set (vault/pool/market addresses or raw bytes32 IDs).
- **Query flow**: `getAccountNav(account, quoteAsset)` iterates all registered adapters, calls `getAdapterPositions` on each (with per-adapter try/catch), filters to registered assets, prices each position via `latestPrice` (freshest-wins), and returns **NAV** (`value`, `quoteAsset`, `timestamp`, `stalePriceAssets`, `sequencerDown`, `quoteAssetStale`). `getAccountPositions(account, quoteAsset)` returns the per-leg `Position[]` breakdown.
- **Verbose APIs**: `getAccountPositionsVerbose` / `getAccountPositionsForAssetVerbose` / `getAccountNavVerbose` on `NAVCalculator` bundle each adapter's `protocolName()` plus its `positionLabels(positionId)` hierarchy (both from `IPositionDescribable`, read via a fail-open staticcall) into `VerbosePosition`. For display only — use the typed `protocolSubId`/`positionId`/`positionKind` fields for identity and reconciliation.
- **External libraries** (EIP-170): `PriceFeedLib` (price selection + feed management + the NAV/positions/health/value read-compute engine) and `NAVRegistryLib` (asset + adapter registry mutations) are `DELEGATECALL`'d at deterministic CREATE2 addresses; `NAVCalculator` keeps only storage, admin mutations, and thin view wrappers. Deployed by scripts `01` before `NAVCalculator`.

NAVCalculator is **UUPS upgradeable** and uses **AccessControl** (DEFAULT_ADMIN_ROLE, MANAGER).

---

## Bridge

- **BridgeEscrow**: Holds assets on each chain; authorized **accounts** call `depositAndBridge(destinationChainId, assetSymbol, amount, adapter)`. The escrow creates an **invoice** (BRIDGING), transfers tokens to the adapter (or approves it), and calls `adapter.bridge(messagePayload)`. On the **destination** chain, release is via `releaseByInvoiceId(messagePayload)` (checksum-validated); it is callable **only by an authorized adapter** — there is **no escrow `fallback()` dispatcher and MANAGER cannot call it directly** (ADR 0012, closing the forged-payload drain). The destination adapter authenticates the inbound protocol message (its MANAGER-operated `completeBridge` runs the protocol-specific verification) and then funds the release in the same call: release is a **funded pass-through** — the escrow pulls exactly `amount` from the adapter (or requires `msg.value == amount` for native) and forwards it to the account, never paying from a standing balance.
- **Adapters**: Each implements `_bridge` (initiate transfer, recipient = BridgeEscrow) and `_completeBridge` (invoked by `completeBridge`, gated by the MANAGER role). `completeBridge` performs protocol-specific verification, ensures the adapter holds the delivered `amount`, then funds the escrow and calls `releaseByInvoiceId` atomically.
- **Invoice lifecycle**: Created on source as BRIDGING; on destination, `releaseByInvoiceId` marks completion there. On source, the MANAGER role calls **`markInvoiceCompleted(invoiceHashes)`** to set status to COMPLETED and update in-transit balances and active-invoice list.

Full flow, invoice system, and how to implement/configure new adapters: see **`src/bridge/BRIDGE_ADAPTERS.md`**.

---

## How to Navigate the Codebase

| Goal | Where to look |
|------|----------------|
| Add or understand a **balance** source (e.g. new DeFi protocol) | `src/balances/IBalanceAdapter.sol`, then an adapter in `src/balances/{BalanceAdapters,MetaBalanceAdapters,AssistedBalanceAdapters}/`. Register via `addBalanceAdapters`; for meta-adapters also call `addMetaInstances`/`removeMetaInstances`. Full how-to: `src/balances/BALANCE_ADAPTERS.md`. |
| Add or understand a **price** source | `src/prices/ICustomPriceFeed.sol`; adapters in `src/prices/protocols/`. Register asset + first feed via `registerAsset`; additional redundant feeds via `addPriceFeed`. Full how-to: `src/prices/PRICE_ADAPTERS.md`. |
| **Position identity** (protocolId / positionId / PositionKind) | `docs/howto/position-identity-schema.md` — slugs, decode tables, reconciliation key, TypeScript examples. Constants in `src/utils/ProtocolIds.sol` and `src/utils/PositionKind.sol`. |
| How **NAV** is computed | `src/nav/NAVCalculator.sol`: `getAccountNav` → `PriceFeedLib.computeNav` fans out over all adapters, prices each position, sums to NAV (the read/compute engine lives in `PriceFeedLib` for EIP-170 headroom). |
| Bridge flow and adapter list | `src/bridge/BRIDGE_ADAPTERS.md`. |
| Add a new **bridge** adapter | `src/bridge/BridgeAdapter.sol` (base), existing adapter in `src/bridge/adapters/`, and “How to Create a New Adapter” in `BRIDGE_ADAPTERS.md`. |
| Shared types and errors | `src/constants.sol`, `src/errors.sol`, `src/utils/`. |

---

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity 0.8.x (see `foundry.toml`)

### Build

```bash
forge build
```

### Tests

```bash
# All tests
forge test

# By area
forge test --match-path "test/balances/**/*.sol"
forge test --match-path "test/bridge/**/*.sol"
forge test --match-path "test/nav/**/*.sol"
forge test --match-path "test/prices/**/*.sol"

# Fork tests (use slow profile to throttle RPC)
FOUNDRY_PROFILE=slow forge test --match-path "test/**/fork/*.sol"
```

- **Invariant / fuzz**: See `test/*/BalanceAdapter.invariant.t.sol`, `NAVCalculator.invariant.t.sol`, etc.
- **Gas**: e.g. `forge test --match-contract NAVCalculatorGasTest` (if present).

### Config

- **foundry.toml**: `src = "src"`, optimizer, `via_ir = true`, coverage and invariant profiles.
- **remappings.txt**: OpenZeppelin, Chainlink, Aave, Comet, Morpho, GMX, Optimism (`@optimism/`), etc.

---

## Dependencies (remappings)

| Prefix | Library |
|--------|--------|
| `@openzeppelin/*` | OpenZeppelin Contracts (upgradeable) |
| `@chainlink/*` | Chainlink (CCIP, CCTP, price feed interfaces) |
| `forge-std/` | Foundry standard library |
| `@optimism/` | Optimism contracts-bedrock (Superchain adapter) |
| `aave-v3-core/` | Aave V3 |
| `comet-contracts/` | Compound III |
| `morpho-blue/` | Morpho |
| `gmx-contracts/` | GMX |
| `openzeppelin-foundry-upgrades/` | UUPS deploy helpers |

---

## Summary

- **Balances**: 19 meta-adapters + 14 per-instance singletons (plus the ERC20 default adapter) covering Aave, Morpho, Euler, Balancer, Uniswap, Compound, Curve, Convex, Fluid, Gearbox, StakeWise, Lido, Kelp, Stader, Cap, and more — all returning typed `PositionBalance` structs.
- **Prices**: N feeds per asset (Chainlink / Redstone / API3 / Custom); freshest-wins selector; custom adapters cover LSTs, yield-bearing stables, RTokens, and cross-rates.
- **NAV**: `NAVCalculator` (UUPS) = Prices + Balances. One contract registers assets + feeds + adapters and computes account NAV in any quote currency, and exposes human-readable position labels via `IPositionDescribable` through its verbose read methods.
- **Bridge**: Escrow + invoice system + adapters (Across, CCIP, CCTP, Stargate, Gnosis, Superchain); destination release via `releaseByInvoiceId`; source closure via `markInvoiceCompleted`.

For bridge design, flows, and adding adapters, use **`src/bridge/BRIDGE_ADAPTERS.md`**.
