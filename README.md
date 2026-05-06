# Onchain Accounting

Onchain infrastructure for portfolio accounting: **balances** (across protocols), **prices** (Chainlink and custom oracles), **NAV** (Net Asset Value calculation), and **cross-chain bridge escrow** with pluggable adapters.

---

## What This Project Does

| Module   | Purpose |
|----------|--------|
| **Balances** | Registry of balance oracles. Each oracle reports positions (balances) for an account in one or more protocols (e.g. Aave, Compound III, Morpho). Used by NAVCalculator to aggregate holdings. |
| **Prices**   | Registry of price feeds per asset (Chainlink or custom). Handles staleness (heartbeat, L2 sequencer). Used by NAVCalculator to value positions. |
| **NAV**      | Single contract that extends Prices + Balances. Registers assets with price feeds, registers balance oracles, and computes **NAV** for an account in a chosen quote currency (e.g. USD or a token). |
| **Bridge**   | **BridgeEscrow** holds assets and tracks invoices; authorized accounts call `depositAndBridge` to bridge to another chain. **Adapters** (Across, CCIP, CCTP, Gnosis, Stargate, Superchain) implement protocol-specific logic. On the destination chain, completion triggers `releaseByInvoiceId` so the escrow sends assets to the account. |

There is no tokenized-share or subscription/redemption logic in this repo; that would sit in a separate layer that uses NAV and/or the bridge as primitives.

---

## Repository Structure

```
src/
├── balances/           # Balance oracles and registry
│   ├── Balances.sol    # Abstract registry (oracles, assets, getBalance)
│   ├── IBalances.sol
│   ├── IBalanceOracleAdapter.sol
│   └── protocols/      # Per-protocol balance adapters — full list in src/balances/BALANCE_ADAPTERS.md.
│                       # Highlights: ERC20DefaultOracle (wallet ERC20 + native, auto-registered);
│                       # Aave V3 + V3 Safety Module + V2 + Umbrella; Compound V3 (Comet);
│                       # Morpho (markets + MetaMorpho vaults); Spark; Balancer V3 + Aura;
│                       # Curve + Convex; Fluid (fToken + Vault); Gearbox; Sky savings; Cap;
│                       # Uniswap V2/V3; PancakeSwap V2/V3; StakeWise V3 (osToken + Vault);
│                       # Stader withdrawal queue; Merkl rewards (mutable cache, ADR 0007).
├── prices/             # Price feeds
│   ├── Prices.sol      # Abstract: Chainlink + custom, staleness, L2 sequencer
│   ├── IPrices.sol
│   ├── IPriceFeedCustom.sol
│   └── protocols/      # Custom price adapters (e.g. sDAI, LDO)
├── nav/                # NAV calculator
│   ├── NAVCalculator.sol   # UUPS upgradeable; inherits Prices + Balances
│   └── INAVCalculator.sol
├── bridge/             # Cross-chain escrow and adapters
│   ├── BridgeEscrow.sol
│   ├── BridgeAdapter.sol   # Base for adapters
│   ├── InvoiceDataLib.sol  # Message payload encoding
│   ├── adapters/           # Per-bridge adapters (Across, CCIP, CCTP, …)
│   └── BRIDGE_ADAPTERS.md  # Bridge design and how to add adapters
├── utils/              # Shared helpers
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

- **`Balances`** (abstract): Holds a **global list of balance oracles** and an **asset registry** (decimals, symbols). Each asset can have multiple oracles (e.g. ERC20 default + protocol-specific). It does not implement NAV or pricing.
- **`IBalanceOracleAdapter`**: Implemented by every balance oracle. Key methods:
  - `getOraclePositions(account, assetFilter)` → list of positions (asset, amount, isDebt, protocol, detail)
  - `getOracleBalance(account)` → assets and net balances (signed)
  - `underlyingAssetsSupported()` → which assets this oracle reports on
- **Protocol adapters** in `src/balances/protocols/`:
  - **ERC20DefaultOracle**: Plain ERC20 and native token balances.
  - Protocol-specific positions (supply, borrow, LP, rewards, lockups, withdrawal queues): **AaveV3Instance**, **AaveV3SafetyModule**, **AaveV2Instance**, **AaveUmbrella**, **CompoundV3Comet**, **MorphoMarket**, **MorphoVault**, **SparkLend**, **BalancerV3**, **Aura**, **Curve**, **Convex**, **Cap**, **DaiDsr**, **SkySavingsUsds**, **FluidFToken**, **FluidVault**, **GearboxMarket**, **StakeWiseV3OsToken**, **StakeWiseV3Vault**, **StaderWithdrawalQueue**, **UniswapV2**, **UniswapV3**, **PancakeSwapV2**, **PancakeSwapV3**, **MerklRewards**. Full inventory + framework reference in [`src/balances/BALANCE_ADAPTERS.md`](src/balances/BALANCE_ADAPTERS.md).

Balance oracles return **PositionBalance** (asset, amount, isDebt, protocol, positionDetail). The NAVCalculator enriches these with prices to get **Position** (same + quoteAsset, value, price, stale).

---

## Prices

- **`Prices`** (abstract): Maps each asset to a **PriceFeedConfig** (oracle address, decimals, Chainlink heartbeat or custom, price type). Provides `latestPrice(asset)` (price, decimals, stale) and L2 sequencer uptime checks when the Chainlink sequencer feed is set.
- **Chainlink**: Uses `AggregatorV3Interface`; staleness = heartbeat timeout.
- **Custom**: Implements `IPriceFeedCustom` (getLatestPrice, decimals). Used for derived/synthetics (e.g. sDAI, LDO, sUSDS, sXDAI, cross-rate).

---

## NAV (NAVCalculator)

- **`NAVCalculator`**: Inherits **Prices** and **Balances**, and adds:
  - Single `initialize(admin, chainlinkL2SequencerUptimeFeed, nativeTokenSymbol)`: deploys and registers **ERC20DefaultOracle**, inits Prices and Balances. Pass `address(0)` for the sequencer feed on chains without L2 sequencer (Mainnet, Gnosis).
  - **MANAGER** role: register assets (with price feed), add/remove balance oracles, set/unsets price feeds.
  - **Assets**: Registered via `registerAsset(asset, oracle, priceType, chainlinkHeartbeat)` (asset must have a price feed).
  - **Balance oracles**: Added with `addBalanceOracle(oracle)`; each oracle must implement `IBalanceOracleAdapter` and list supported assets.
- **Query flow**: `getAccountNav(account, quoteAsset)` aggregates positions from **all** registered oracles, converts to the quote asset using Prices, and returns **NAV** (value, quoteAsset, timestamp, stalePriceAssets, sequencerDown). Positions are combined across oracles per asset (credits and debts).

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
| Add or understand a **balance** source (e.g. new DeFi protocol) | `src/balances/IBalanceOracleAdapter.sol`, then an adapter in `src/balances/protocols/`. Register it with NAVCalculator via `addBalanceOracle`. |
| Add or understand a **price** source | `src/prices/IPrices.sol`, `IPriceFeedCustom.sol`; adapters in `src/prices/protocols/`. Register asset + feed via NAVCalculator `registerAsset` or `setPriceFeed`. |
| How **NAV** is computed | `src/nav/NAVCalculator.sol`: `getAccountNav` → `_readPositionsRangeWithQuote` aggregates oracles and converts to quote. |
| Bridge flow and adapter list | `src/bridge/BRIDGE_ADAPTERS.md`. |
| Add a new **bridge** adapter | `src/bridge/BridgeAdapter.sol` (base), existing adapter in `src/bridge/adapters/`, and “How to Create a New Adapter” in `BRIDGE_ADAPTERS.md`. |
| Shared types and errors | `src/constants.sol`, `src/errors.sol`. |

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

- **Balances**: Registry + protocol-specific oracles (Aave, Compound, Morpho, etc.) returning positions.
- **Prices**: Chainlink and custom feeds per asset; L2 sequencer check.
- **NAV**: One contract (NAVCalculator = Prices + Balances) to register assets and oracles and compute account NAV in a quote currency.
- **Bridge**: Escrow + invoice system + adapters for multiple chains; destination release via `releaseByInvoiceId`; source closure via `markInvoiceCompleted`.

For bridge design, flows, and adding adapters, use **`src/bridge/BRIDGE_ADAPTERS.md`**.
