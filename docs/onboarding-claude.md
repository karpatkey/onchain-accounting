# Onboarding (for Claude or a new contributor)

Read this before starting any non-trivial PR in this repo. It gives you the architectural mental model. For implementation details, follow the links into the per-domain docs — don't re-derive them.

This document is descriptive, not prescriptive. Conventions you must follow are in [`/CLAUDE.md`](../CLAUDE.md). How-tos are under [`./howto/`](./howto/).

---

## 1. The product, in one paragraph

This repo provides onchain primitives for portfolio accounting. The single entry point is `NAVCalculator`: given an `account` and a `quoteAsset`, it returns the **net asset value** of that account in that currency. NAV is computed by aggregating positions from a registry of **balance oracles** (each one knows how to read positions from a specific protocol — Aave, Compound III, Morpho, etc.) and then valuing each position via the **price registry** (Chainlink or custom feeds). A separate **bridge** module (`BridgeEscrow` + per-protocol adapters) handles cross-chain asset movement with an invoice/release flow. There is no tokenized share, no subscribe/redeem; that lives in a layer above this one.

## 2. The four modules

```
NAVCalculator (UUPS upgradeable, AccessControl)
├── inherits Prices  ─┐
└── inherits Balances ─┴── per-asset feeds + per-account oracles
                          │
BridgeEscrow + adapters ───┘  (independent — uses NAV/balances? no, separate concern)
```

| Module | Lives in | One-line job |
|---|---|---|
| **Balances** | `src/balances/` | Registry of balance oracles. Each oracle returns `PositionBalance[]` for an account. |
| **Prices** | `src/prices/` | Per-asset price feeds (Chainlink + custom `IPriceFeedCustom`). Handles staleness + L2 sequencer. |
| **NAV** | `src/nav/` | One contract that extends Prices + Balances, registers assets, and computes NAV. |
| **Bridge** | `src/bridge/` | `BridgeEscrow` holds assets and tracks invoices; per-protocol adapters do the bridging. |

## 3. NAV flow (the load-bearing path)

User calls `NAVCalculator.getAccountNav(account, quoteAsset)`.

```
account, quoteAsset
        │
        ▼
NAVCalculator.getAccountNav
        │
        ▼
for each oracle in getAllOracles():
    adapter.getOraclePositions(account, address(0))   ──► PositionBalance[]
        │
        ▼
filter: keep positions whose asset is in the asset registry
        │
        ▼
for each position: lookup price, value = amount × price (sign by isDebt)
        │
        ▼
sum → NAV { value, quoteAsset, timestamp, stalePriceAssets, sequencerDown }
```

Authoritative reference: [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) §2.

Everything that goes wrong in NAV is one of three things:
1. **The adapter returned the wrong amount or sign.** Check the adapter's `_calculateBalance` and the `isDebt` flag.
2. **The asset is not registered.** Filtered out silently.
3. **The price feed is stale or wrong.** Check Chainlink heartbeat, custom feed, or sequencer-down state.

## 4. Balance adapters: the framework

Every balance source — wallet ERC20 holdings, Aave supply/borrow, Compound III, Morpho, Curve, Aura, Safety Module, etc. — is a contract that implements `IBalanceOracleAdapter` (in `src/balances/IBalanceOracleAdapter.sol`):

```solidity
function getOraclePositions(address account, address assetFilter) external view returns (PositionBalance[]);
function getOracleBalances(address account) external view returns (address[], uint256[], bool[]);
function getOracleBalanceForAsset(address account, address asset) external view returns (uint256, bool);
function underlyingAssetsSupported() external view returns (address[]);
function supportsInterface(bytes4) external view returns (bool);  // ERC165
```

Returned `PositionBalance` has `amount` always positive + `isDebt` flag. The adapter does **not** know about prices.

Adapters live under `src/balances/protocols/<protocol>/` (one folder per protocol). Each folder typically contains:

- `<Protocol>.sol` — the adapter contract.
- `<Protocol>AdapterFactory.sol` — a CREATE2 factory inheriting `BalanceAdapterFactoryBase`, with `PROTOCOL_KEY = keccak256("<Protocol>")`.

The framework guarantees:
- **Cross-chain identical addresses** for the same `(initCode, salt)` via the canonical CREATE2 deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
- **Single registration path:** factory `deploy()` calls `BalanceAdapterRegistry.register(adapter)`, which owns MANAGER on `NAVCalculator` and forwards to `addBalanceOracle`.
- **Idempotent re-registration** for adapters already in NAV.
- **Clean unregister:** `BalanceAdapterRegistry.unregister(adapter)` removes from NAV *and* notifies the originating factory via `onAdapterUnregistered` so factory tracking stays consistent.

Read [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) for the contract-level details and [`./howto/add-balance-adapter.md`](./howto/add-balance-adapter.md) for the end-to-end walkthrough.

## 5. Price feeds

Two flavors:
- **Chainlink** — registered with `priceType = Chainlink` and a heartbeat for staleness. Most assets use this.
- **Custom** — a contract implementing `IPriceFeedCustom` that derives a price (e.g., `sDAI_Price` reads `sDAI.previewRedeem(1e18)` × DAI/USD; `wstETH_Price` reads stETH-per-token rate × stETH/USD). Used for receipt tokens, LP tokens, and synthetic rates. All custom feeds live under `src/prices/protocols/`.

L2 deployments check `chainlinkSequencerFeed`; if down or in grace period, prices are flagged stale.

Read [`./PRICE_ADAPTERS.md`](./PRICE_ADAPTERS.md) for the full list of custom feeds and [`./howto/add-price-feed.md`](./howto/add-price-feed.md) when adding one.

## 6. Bridge module (separate concern)

`BridgeEscrow` holds assets per chain and tracks **invoices** (BRIDGING → COMPLETED). An authorized account calls `depositAndBridge(destinationChainId, assetSymbol, amount, adapter)`; the escrow creates an invoice, hands tokens to the adapter, and the adapter calls into the underlying bridge protocol (Across, CCIP, CCTP, Stargate, Superchain, Gnosis). On the destination chain, completion calls `releaseByInvoiceId(messagePayload)` which validates a checksum and releases funds. Source-side closure (`markInvoiceCompleted`) is an operator action.

Bridge has its own complete reference: [`src/bridge/BRIDGE_ADAPTERS.md`](../src/bridge/BRIDGE_ADAPTERS.md). It is independent of the balances/prices/NAV stack — a contributor can work on bridge without understanding NAV and vice versa.

## 7. Deployment lifecycle

Deployment is scripted and config-driven. Read [`script/DEPLOYMENT_SUMMARY.md`](../script/DEPLOYMENT_SUMMARY.md), [`script/deploy/README.md`](../script/deploy/README.md), and [`script/config/CONFIG_GUIDE.md`](../script/config/CONFIG_GUIDE.md) for specifics. Skeleton:

1. `01_DeployImplementations.s.sol` — implementation contracts (NAVCalculator, BridgeEscrow).
2. `02_DeployProxies.s.sol` — UUPS proxies + initializers.
3. `03_RegisterAssets.s.sol` — registers assets + price feeds.
4. `04_DeployBalanceAdapters.s.sol` — deploys per-chain balance adapters from chain config and registers them with NAVCalculator.
5. `05_DeployAdapterFactories.s.sol` — deploys `BalanceAdapterRegistry` + per-protocol factories at deterministic addresses (CREATE2). Once factories own MANAGER, they become the registration path.
6. `06_MigrateExistingAdapters.s.sol` — moves pre-existing adapters under registry tracking via `factory.registerExternal(adapter)`.

Per-chain configuration is in `script/config/chains/<chainId>.json`. Five chains today: `1` (Mainnet), `10` (Optimism), `100` (Gnosis), `42161` (Arbitrum), `8453` (Base).

Adding a new chain or new adapter is a config edit + a single deploy script run; see the `./howto/` guides.

## 8. Where to look when something is unclear

| Question | Best file |
|---|---|
| What does this protocol's adapter actually return? | The adapter source under `src/balances/protocols/<protocol>/` and its fork test. |
| What is registered on chain X today? | `script/config/chains/<X>.json` — `deployed`, `assets`, `balanceAdapters` blocks. |
| Why is the framework structured this way? | [`./decisions/`](./decisions/) ADRs. |
| How do positions flow into NAV? | [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) §2 + `NAVCalculator._readPositionsRangeWithQuote`. |
| Why is the Aave Safety Module adapter mutable while everything else is immutable? | [`./decisions/0002-aave-safety-module-multi-token.md`](./decisions/0002-aave-safety-module-multi-token.md). |
| Bridge invoice lifecycle? | [`src/bridge/BRIDGE_ADAPTERS.md`](../src/bridge/BRIDGE_ADAPTERS.md). |

## 9. Conventions and rules

These are not optional. See [`/CLAUDE.md`](../CLAUDE.md) for the canonical list. Highlights:

- Adapters return `PositionBalance` with positive `amount` + `isDebt` flag.
- Adapters are immutable. The Safety Module adapter is the documented exception.
- Factories use CREATE2 with `PROTOCOL_KEY = keccak256("<Name>")`.
- Registration goes through `BalanceAdapterRegistry`, never directly to `NAVCalculator.addBalanceOracle`.
- Tests: every adapter ships with both a unit test and a fork test against a real holder at a pinned block.
- The user merges PRs; we monitor CI and report.
