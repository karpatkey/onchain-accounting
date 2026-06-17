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
│   ├── MetaBalanceAdapter.sol    # Abstract base for all 21 meta-adapters
│   ├── IPositionDescribable.sol # Human-readable labels (ERC165)
│   └── protocols/               # Per-protocol adapters. Full inventory in src/balances/BALANCE_ADAPTERS.md.
├── prices/                      # Price feeds
│   ├── Prices.sol               # Abstract: N feeds/asset, freshest-wins, L2 sequencer
│   ├── IPrices.sol
│   ├── IPriceFeedCustom.sol
│   ├── PriceFeedLib.sol         # External library (EIP-170 size management)
│   └── protocols/               # Custom price adapters (sDAI, wstETH, rsETH, osToken, …)
├── nav/                         # NAV calculator
│   ├── NAVCalculator.sol        # UUPS upgradeable; inherits Prices + Balances
│   ├── INAVCalculator.sol
│   └── NavRegistryLib.sol       # External library for registry mutations (EIP-170)
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

- **`Balances`** (abstract): Holds a **global list of balance adapters** and an **asset registry** (decimals, symbols). Each asset can have multiple adapters (e.g. ERC20 default + protocol-specific). It does not implement NAV or pricing.
- **`IBalanceAdapter`**: Implemented by every balance adapter. Key methods:
  - `getAdapterPositions(account, assetFilter)` → list of **PositionBalance** entries with typed identity (`protocolId` bytes32 keccak256 hash of the canonical slug, `positionId` abi-encoded key, `positionKind` enum)
  - `getAdapterBalance(account)` → assets and net balances (signed)
  - `underlyingAssetsSupported()` → which assets this adapter reports on
- **Protocol adapters** in `src/balances/protocols/`:
  - **ERC20DefaultAdapter**: Plain ERC20 and native token balances.
  - **21 meta-adapters** ([ADR 0010](docs/decisions/0010-meta-balance-adapters.md)): one immutable contract per protocol family covers every instance of that protocol. The **instance set** (which vaults, pools, or markets to query) is a `bytes32[]` held on `NAVCalculator` and set by the MANAGER role via `addMetaInstances/removeMetaInstances` — **adding a pool is a config TX, not a deploy**. The instance coordinate is the pool/vault/market address widened to `bytes32` for most protocols, or a raw `bytes32` for Morpho market IDs and Balancer V2 pool IDs. Per-instance reverts are isolated so one bad instance cannot zero out the batch. Families: `MorphoVaultsMeta`, `MorphoMarketsMeta`, `AaveV3InstancesMeta`, `AaveV2InstancesMeta`, `BalancerV3PoolsMeta`, `BalancerV3GaugesMeta`, `BalancerV2PoolsMeta`, `BalancerV2GaugesMeta`, `UniswapV3PoolsMeta`, `UniswapV2PoolsMeta`, `PancakeSwapV3PoolsMeta`, `PancakeSwapV2PoolsMeta`, `GearboxMarketsMeta`, `CompoundV3CometsMeta`, `FluidFTokensMeta`, `FluidVaultsMeta`, `StakeWiseV3VaultsMeta`, `CurvePoolsMeta`, `CurveGaugesMeta`, `ConvexRewardsMeta`, `AuraRewardsMeta`.
  - **11 per-instance singleton adapters** (no meta equivalent needed): **SparkLend** (AaveV3 logic inlined), **AaveV3SafetyModule**, **AaveUmbrella**, **Cap**, **ERC4626Wrap**, **DaiDsr**, **SkySavingsUsds**, **MerklRewards**, **StaderWithdrawalQueue**, **KelpWithdrawalQueue**, **LidoWithdrawalQueue**. All 11 implement `IPositionDescribable` (ERC165-discoverable human-readable labels). Full inventory + framework reference in [`src/balances/BALANCE_ADAPTERS.md`](src/balances/BALANCE_ADAPTERS.md).

Balance adapters return **PositionBalance** (`balanceAsset`, `amount`, `isDebt`, `protocolId` bytes32, `positionId` bytes, `positionKind` enum). **`PositionKind`** classifies each leg: `Wallet` · `Supplied` · `Borrowed` · `Collateral` · `Staking` (principal locked behind an unstake action — Safety Module, Umbrella, StakeWise vaults, gauge/Convex/Aura-staked LP) · `Rewards` (accrued reward tokens) · `Fees` (uncollected LP/protocol fees). `amount` is always positive; `isDebt` carries the sign for NAV. The NAVCalculator enriches these with prices to get **Position** (same + quoteAsset, value, price, stale) and optionally a **VerbosePosition** (adds `protocolName` + `positionLabel` strings from each adapter's `IPositionDescribable` implementation — for display only, not identity). Full struct schema, per-protocol positionId decode tables, reconciliation key, and TypeScript examples: [`docs/howto/position-identity-schema.md`](docs/howto/position-identity-schema.md).

---

## Prices

- **`Prices`** (abstract): Maps each asset to a **`PriceFeedConfig[]` array** — N ≥ 1 feeds per asset. On every `latestPrice(asset)` call, `_selectFeed` iterates all feeds and picks the **freshest non-stale survivor** (freshest-wins). Only returns `stale=true` when every feed fails. Feeds are added via `addPriceFeed` and removed via `removePriceFeed` (reverts on last feed). L2 sequencer uptime check (configurable grace period, minimum 1 hour) is applied on top.
- **Feed types** (`PriceType` enum):
  - `Chainlink` — `AggregatorV3Interface.latestRoundData()`; staleness = heartbeat timeout.
  - `Redstone` — Redstone Classic Push; same read path as Chainlink.
  - `API3` — `Api3ReaderProxyV1` (implements `AggregatorV2V3Interface`); deterministic cross-chain address; proxy returns 18 dec, normalised to 8 dec internally.
  - `Custom` — Implements `IPriceFeedCustom` (`getLatestPrice() → (price, stale)` + `latestRoundData()` for freshness ranking). Used for derived prices where the staleness condition spans multiple constituent Chainlink feeds (the `getLatestPrice` stale bool is the primary gate; `latestRoundData().updatedAt` is used for heartbeat + freshness ranking). `updatedAt == 0` is treated as `block.timestamp - 1` so rate-only feeds participate but yield to feeds with a real push timestamp.
- **Existing custom feeds** in `src/prices/protocols/`: yield-bearing stable wrappers (`sDAI`, `sUSDS`, `sUSDe`, `sXDAI`, `syrupUSDC`), liquid (re)staking tokens (`wstETH`, `rETH`, `cbETH`, `rsETH`, `eETH`, `weETH`, `ezETH`, `ETHx`, `osToken`), and derived feeds (`LDO`, `ETH+`, `CrossRate`). L2 variants (`*_L2_*`) read Chainlink-secured rate feeds on L2 rather than L1 rate providers.
- **`PriceFeedLib`**: external Solidity library (`DELEGATECALL`) holding the `_selectFeed` loop and feed-management functions — extracted to stay under EIP-170's 24 576-byte bytecode limit. Deployed at a deterministic CREATE2 address (linked in `foundry.toml`).
- Full architecture, staleness design, and how to add a custom feed: [`src/prices/PRICE_ADAPTERS.md`](src/prices/PRICE_ADAPTERS.md).

---

## NAV (NAVCalculator)

- **`NAVCalculator`**: Inherits **Prices** and **Balances**, and adds:
  - `initialize(admin, chainlinkL2SequencerUptimeFeed, nativeTokenSymbol)`: deploys **ERC20DefaultAdapter**, inits Prices and Balances. Pass `address(0)` for the sequencer feed on chains without L2 sequencer (Mainnet, Gnosis).
  - **MANAGER** role: `registerAsset(asset, feed, priceType, heartbeat)`, `addPriceFeed` / `removePriceFeed`, `addBalanceAdapters` / `removeBalanceAdapters`, `addMetaInstances/removeMetaInstances`.
  - **Assets**: Registered via `registerAsset` (sets price feed + adds to asset registry). Additional feeds per asset via `addPriceFeed`; removal via `removePriceFeed` (cannot remove the last feed).
  - **Balance adapters**: Added with `addBalanceAdapters`; ERC165-checked for `IBalanceAdapter`. For meta-adapters, also call `addMetaInstances`/`removeMetaInstances` to configure the instance set (vault/pool/market addresses or raw bytes32 IDs).
- **Query flow**: `getAccountNav(account, quoteAsset)` iterates all registered adapters, calls `getAdapterPositions` on each (with per-adapter try/catch), filters to registered assets, prices each position via `latestPrice` (freshest-wins), and returns **NAV** (`value`, `quoteAsset`, `timestamp`, `stalePriceAssets`, `sequencerDown`). Range-based variants (`getAccountNavForRange`) restrict to an asset index range for gas control.
- **Verbose APIs**: `getAccountPositionsVerbose` / `getAccountNavVerbose` bundle `protocolName` + `positionLabel` strings from each adapter's `IPositionDescribable` into `VerbosePosition`. For display only — use typed `protocolId`/`positionId`/`positionKind` for identity and reconciliation.
- **External libraries** (EIP-170): `PriceFeedLib` (price selection and feed management) and `NavRegistryLib` (asset + adapter registry mutations) are `DELEGATECALL`'d at deterministic CREATE2 addresses. Deployed by scripts `01` before `NAVCalculator`.

NAVCalculator is **UUPS upgradeable** and uses **AccessControl** (DEFAULT_ADMIN_ROLE, MANAGER).

---

## Bridge

- **BridgeEscrow**: Holds assets on each chain; authorized **accounts** call `depositAndBridge(destinationChainId, assetSymbol, amount, adapter)`. The escrow creates an **invoice** (BRIDGING), transfers tokens to the adapter (or approves it), and calls `adapter.bridge(messagePayload)`. On the **destination** chain, release is via `releaseByInvoiceId(messagePayload)` (checksum-validated); only authorized adapters or OPERATOR can call it. Escrow has a **fallback** that forwards protocol callbacks (e.g. `ccipReceive`) to the adapter registered for that selector; the adapter then calls `releaseByInvoiceId`.
- **Adapters**: Each implements `_bridge` (initiate transfer, recipient = BridgeEscrow) and `_completeBridge` (operator path); callback-based adapters also implement the protocol’s receive function and call `releaseByInvoiceId` when the escrow forwards to them.
- **Invoice lifecycle**: Created on source as BRIDGING; on destination, `releaseByInvoiceId` marks completion there. On source, an operator calls **`markInvoiceCompleted(invoiceHashes)`** to set status to COMPLETED and update in-transit balances and active-invoice list.

Full flow, invoice system, and how to implement/configure new adapters: see **`src/bridge/BRIDGE_ADAPTERS.md`**.

---

## How to Navigate the Codebase

| Goal | Where to look |
|------|----------------|
| Add or understand a **balance** source (e.g. new DeFi protocol) | `src/balances/IBalanceAdapter.sol`, then an adapter in `src/balances/protocols/`. Register via `addBalanceAdapters`; for meta-adapters also call `addMetaInstances`/`removeMetaInstances`. Full how-to: `src/balances/BALANCE_ADAPTERS.md`. |
| Add or understand a **price** source | `src/prices/IPriceFeedCustom.sol`; adapters in `src/prices/protocols/`. Register asset + first feed via `registerAsset`; additional redundant feeds via `addPriceFeed`. Full how-to: `src/prices/PRICE_ADAPTERS.md`. |
| **Position identity** (protocolId / positionId / PositionKind) | `docs/howto/position-identity-schema.md` — slugs, decode tables, reconciliation key, TypeScript examples. Constants in `src/utils/ProtocolIds.sol` and `src/utils/PositionKind.sol`. |
| How **NAV** is computed | `src/nav/NAVCalculator.sol`: `getAccountNav` → `_readPositionsRangeWithQuote` fans out over all adapters, prices each position, sums to NAV. |
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

- **Balances**: 21 meta-adapters + 12 per-instance singletons covering Aave, Morpho, Balancer, Uniswap, Compound, Curve, Convex, Aura, Fluid, Gearbox, StakeWise, Lido, Kelp, Stader, Sky, Cap, and more — all returning typed `PositionBalance` structs.
- **Prices**: N feeds per asset (Chainlink / Redstone / API3 / Custom); freshest-wins selector; custom adapters cover LSTs, yield-bearing stables, RTokens, and cross-rates.
- **NAV**: `NAVCalculator` (UUPS) = Prices + Balances. One contract registers assets + feeds + adapters and computes account NAV in any quote currency. Verbose APIs expose human-readable position labels via `IPositionDescribable`.
- **Bridge**: Escrow + invoice system + adapters (Across, CCIP, CCTP, Stargate, Gnosis, Superchain); destination release via `releaseByInvoiceId`; source closure via `markInvoiceCompleted`.

For bridge design, flows, and adding adapters, use **`src/bridge/BRIDGE_ADAPTERS.md`**.
