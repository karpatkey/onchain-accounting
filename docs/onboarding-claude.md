# Onboarding (for Claude or a new contributor)

Read this before starting any non-trivial PR in this repo. It gives you the architectural mental model. For implementation details, follow the links into the per-domain docs — don't re-derive them.

This document is descriptive, not prescriptive. Conventions you must follow are in [`/CLAUDE.md`](../CLAUDE.md). How-tos are under [`./howto/`](./howto/).

---

## 1. The product, in one paragraph

This repo provides onchain primitives for portfolio accounting. The single entry point is `NAVCalculator`: given an `account` and a `quoteAsset`, it returns the **net asset value** of that account in that currency. NAV is computed by aggregating positions from a registry of **balance adapters** (each one knows how to read positions from a specific protocol — Aave, Compound V3, Morpho, etc.) and then valuing each position via the **price registry** (Chainlink or custom feeds). A separate **bridge** module (`BridgeEscrow` + per-protocol adapters) handles cross-chain asset movement with an invoice/release flow. There is no tokenized share, no subscribe/redeem; that lives in a layer above this one.

## 2. The four modules

```
NAVCalculator (UUPS upgradeable, AccessControl)
├── inherits Prices  ─┐
└── inherits Balances ─┴── per-asset feeds + per-account adapters
                          │
BridgeEscrow + adapters ───┘  (independent — does not touch NAV/balances; separate concern)
```

| Module | Lives in | One-line job |
|---|---|---|
| **Balances** | `src/balances/` | Registry of balance adapters. Each adapter returns `PositionBalance[]` for an account. |
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
for each adapter in getAllAdapters():
    adapter.getAdapterPositions(account, address(0))   ──► PositionBalance[]
        │
        ▼
filter: keep positions whose asset is in the asset registry
        │
        ▼
for each position: lookup price, value = amount × price (sign by isDebt)
        │
        ▼
sum → NAV { value, quoteAsset, timestamp, stalePriceAssets, sequencerDown, quoteAssetStale }
```

Authoritative reference: [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) §2.

Everything that goes wrong in NAV is one of three things:
1. **The adapter returned the wrong amount or sign.** Check the adapter's `_calculateBalance` and the `isDebt` flag.
2. **The asset is not registered.** Filtered out silently.
3. **The price feed is stale or wrong.** Check Chainlink heartbeat, custom feed, or sequencer-down state.

## 4. Balance adapters: the framework

Every balance source — wallet ERC20 holdings, Aave supply/borrow, Compound V3, Morpho, Curve, Aura, Safety Module, etc. — is a contract that implements `IBalanceAdapter` (in `src/balances/IBalanceAdapter.sol`):

```solidity
function getAdapterPositions(address account, address assetFilter) external view returns (PositionBalance[]);
function getAdapterBalances(address account) external view returns (address[], uint256[], bool[]);
function getAdapterBalanceForAsset(address account, address asset) external view returns (uint256, bool);
function underlyingAssetsSupported() external view returns (address[]);
function supportsInterface(bytes4) external view returns (bool);  // ERC165
```

Returned `PositionBalance` has `amount` always positive + `isDebt` flag, plus `balanceAsset` (the `Asset` metadata — address, symbol, decimals — that `amount` is denominated in), `balanceAdapter` (`address(this)`), `protocolId` (bytes32 protocol identifier), `positionId` (bytes, abi-encoded position anchor), and `positionKind` (enum from `PositionKind.sol`). The adapter does **not** know about prices. See [`docs/howto/position-identity-schema.md`](./howto/position-identity-schema.md) for the full schema.

Adapters live under `src/balances/protocols/<protocol>/` (single-file adapters may sit directly under `protocols/`). A folder typically contains:

- `<Protocol>.sol` — the adapter contract (immutable; the constructor pins everything).
- For multi-instance protocols, a single `<Protocol>MetaBalanceAdapter` covering every instance (ADR 0010) instead of one contract per instance. The active instance set is governed on `NAVCalculator` via `addMetaInstances`/`removeMetaInstances`.

How adapters reach NAV today:
- **Per-chain addresses** — adapters are deployed with plain `new` (CREATE) broadcast from the deployer EOA in `04_DeployBalanceAdapters.s.sol` (constructor args from `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` for plain adapters and `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` for meta adapters; `04` reads both), so each adapter's address is chain- and run-specific. Read deployed addresses from `script/config/deployments/<chainId>.json` (`.balanceAdapters.<name>`); do not assume they match across chains.
- **Registration** is done by `06_Configure.s.sol`, which broadcasts directly from the deployer EOA: `addBalanceAdapters(adapters)` for plain adapters and `addMetaBalanceAdapter(adapter, instances)` for meta-adapters, plus `addMetaInstances(adapter, …)/removeMetaInstances` for meta instance set changes (all idempotent).
- **No factory or registry contract exists.** The per-protocol factory pattern (`BalanceAdapterFactoryBase` / `BalanceAdapterRegistry`) in [ADR 0001](./decisions/0001-balance-adapter-factory-pattern.md) is designed but **not yet shipped** — `src/balances/factories/` does not exist.

Read [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) for the contract-level details and [`./howto/add-balance-adapter.md`](./howto/add-balance-adapter.md) for the end-to-end walkthrough.

## 5. Price feeds

Two flavors:
- **Chainlink** — registered with `priceType = Chainlink` and a heartbeat for staleness. Most assets use this.
- **Custom** — a contract implementing `IPriceFeedCustom` that derives a price (e.g., `sDAI_Price` combines DAI/USD with Maker's DSR `chi` ratio (sDAI/DAI); `wstETH_Price` reads stETH-per-token rate × stETH/ETH × ETH/USD). Used for receipt tokens, LP tokens, and synthetic rates. All custom feeds live under `src/prices/protocols/`.

L2 deployments check `chainlinkL2SequencerUptimeFeed`; if down or in grace period, prices are flagged stale.

Read [`src/prices/PRICE_ADAPTERS.md`](../src/prices/PRICE_ADAPTERS.md) for the full list of custom feeds and [`./howto/add-price-feed.md`](./howto/add-price-feed.md) when adding one.

## 6. Bridge module (separate concern)

`BridgeEscrow` holds assets per chain and tracks **invoices** (BRIDGING → COMPLETED). An authorized account calls `depositAndBridge(destinationChainId, assetSymbol, amount, adapter)`; the escrow creates an invoice, hands tokens to the adapter, and the adapter calls into the underlying bridge protocol (Across, CCIP, CCTP, Stargate, Superchain, Gnosis). On the destination chain, completion calls `releaseByInvoiceId(messagePayload)` which validates a checksum and releases funds. Source-side closure (`markInvoiceCompleted`) is an operator action.

Bridge has its own complete reference: [`src/bridge/BRIDGE_ADAPTERS.md`](../src/bridge/BRIDGE_ADAPTERS.md). It is independent of the balances/prices/NAV stack — a contributor can work on bridge without understanding NAV and vice versa.

## 7. Deployment lifecycle

Deployment is scripted and config-driven. Read [`script/DEPLOYMENT_SUMMARY.md`](../script/DEPLOYMENT_SUMMARY.md), [`script/deploy/README.md`](../script/deploy/README.md), and [`script/config/CONFIG_GUIDE.md`](../script/config/CONFIG_GUIDE.md) for specifics. Skeleton:

The whole flow is **EOA-only** (deployer key + `--broadcast`; no Safe executes deploy/config). The deployer EOA holds admin + MANAGER throughout; the security-council Safe becomes admin only at the end (step 07).

1. `01_DeployImplementations.s.sol` — libraries (PriceFeedLib, NAVRegistryLib) + implementation contracts (NAVCalculator, BridgeEscrow), via EOA CREATE2.
2. `02_DeployProxies.s.sol` — UUPS proxies + atomic initialize + role grants (admin + MANAGER to `chainConfig.admin`/`manager` = the **deployer EOA**; the atomic deployer renounces its own admin).
3. `03_DeployPriceFeeds.s.sol` — deploys per-chain custom price feed adapters; asset registration via `script/manage/RegisterAssets.s.sol`.
4. `04_DeployBalanceAdapters.s.sol` — deploys per-chain balance adapters from `contracts-deployment-config/balance-adapters/<id>.json` (plain) and `contracts-deployment-config/meta-balance-adapters/<id>.json` (meta).
5. `05_DeployBridgeAdapters.s.sol` — deploys per-chain bridge adapters (CCIP, Across, CCTP, Stargate, Superchain, Gnosis).
6. `06_Configure.s.sol` — **EOA broadcast**: add balance adapters to NAV, `addMetaInstances`/`removeMetaInstances` for meta-adapters, authorize bridge adapters on BridgeEscrow (idempotent).
7. `07_TransferAdminToSecurityCouncil.s.sol` — **last:** grants DEFAULT_ADMIN_ROLE + MANAGER to `securityCouncil` on both proxies and renounces the deployer's roles.

For the operational sequencing see [`script/deploy/README.md`](../script/deploy/README.md) and [`script/NAV_V2_DEPLOYMENT_RUNBOOK.md`](../script/NAV_V2_DEPLOYMENT_RUNBOOK.md).

Per-chain configuration is split under `script/config/`: `chains/<chainId>.json` holds chain metadata + role addresses; `contracts-deployment-config/{custom-price-feeds,balance-adapters,meta-balance-adapters,bridge-adapters}/<chainId>.json` holds what to deploy; `nav-config/{assets-and-price-feeds,balance-adapters,meta-balance-adapters}/<chainId>.json` holds what to register on NAV; `deployments/<chainId>.json` holds the resulting deployed addresses. Seven chains today: `1` (Mainnet), `10` (Optimism), `56` (BNB Chain), `100` (Gnosis), `137` (Polygon), `42161` (Arbitrum), `8453` (Base).

Adding a new chain or new adapter is a config edit + a single deploy script run; see the `./howto/` guides.

## 7.5. Integration test freshness

The integration tests under `test/integration/` deploy a NAV stack on a forked chain at a pinned block, register every adapter from chain config, and assert exact NAV values for a set of accounts. Fork blocks and expected NAVs are stored in `test/integration/accounts.json` — **the per-chain `NAV.<Chain>.integration.fork.t.sol` files are stubs that just point at the JSON**.

When you add an adapter that should appear in an existing test account's NAV, or when you want to add a new test account: edit `accounts.json` and run `script/test/refresh-integration-snapshot.sh`. The script bumps fork blocks, regenerates the expected NAVs, and (if `DEBANK_API_KEY` is set) cross-checks each NAV against Debank's USD total within a configurable tolerance. Tests stay deterministic; the Debank check happens at bump time only.

Full workflow + schema + tolerance triage: [`./howto/refresh-integration-test-blocks.md`](./howto/refresh-integration-test-blocks.md). Design rationale: [`./decisions/0003-integration-test-snapshot-workflow.md`](./decisions/0003-integration-test-snapshot-workflow.md).

## 8. Where to look when something is unclear

| Question | Best file |
|---|---|
| What does this protocol's adapter actually return? | The adapter source under `src/balances/protocols/<protocol>/` and its fork test. |
| What is registered on chain X today? | Deployed addresses: `script/config/deployments/<X>.json`. Registered assets: `script/config/nav-config/assets-and-price-feeds/<X>.json`. Balance adapters on NAV: `script/config/nav-config/{balance-adapters,meta-balance-adapters}/<X>.json` (deploy config under `contracts-deployment-config/`). |
| Why is the framework structured this way? | [`./decisions/`](./decisions/) ADRs. |
| How do positions flow into NAV? | [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) §2 + §6 (`NAVCalculator.getAccountNav` → `PriceFeedLib.computeNav`). |
| Why is the Merkl rewards adapter mutable while every other adapter is immutable? | [`./decisions/0007-merkl-trust-minimized-cache.md`](./decisions/0007-merkl-trust-minimized-cache.md). The Aave Safety Module was previously the documented exception (ADR 0002) but is now fully immutable per ADR 0005. |
| Bridge invoice lifecycle? | [`src/bridge/BRIDGE_ADAPTERS.md`](../src/bridge/BRIDGE_ADAPTERS.md). |
| How are integration-test fork blocks and expected NAVs kept current? | [`./howto/refresh-integration-test-blocks.md`](./howto/refresh-integration-test-blocks.md). |

## 9. Conventions and rules

These are not optional. See [`/CLAUDE.md`](../CLAUDE.md) for the canonical list. Highlights:

- Adapters return `PositionBalance` with positive `amount` + `isDebt` flag. Fields include `balanceAsset`, `protocolId` (bytes32), `positionId` (bytes), and `positionKind` (enum from `PositionKind.sol`). See `docs/howto/position-identity-schema.md`.
- Adapters are immutable. The Merkl rewards adapter is the documented mutable-storage exception (ADR 0007).
- Adapters are deployed with plain `new` (CREATE) from the deployer EOA in `04_DeployBalanceAdapters.s.sol` — addresses are chain-/run-specific (read from `deployments/<id>.json` `.balanceAdapters.<name>`) — and registered by `06_Configure.s.sol` calling `NAVCalculator.addBalanceAdapters` (plain) / `addMetaBalanceAdapter` (meta) directly from the deployer EOA (+ `addMetaInstances`/`removeMetaInstances` for meta-adapters). The factory/registry pattern (ADR 0001) is designed but not yet shipped.
- Tests: every adapter ships with both a unit test and a fork test against a real holder at a pinned block.
- The user merges PRs; we monitor CI and report.
