# 0010 — Meta balance adapters: one immutable adapter per protocol, instance set held on NAVCalculator

**Status:** accepted

## Context

Until now there is **one deployed balance adapter contract per pool / market / vault**. `MorphoVaultBalanceOracle` pins a single vault in its constructor; `BalancerV3PoolBalanceOracle` pins a single (pool, gauge); `AaveV3InstanceBalanceOracle` pins a single market DataProvider. Covering N Morpho vaults means deploying and registering N immutable contracts, each via CREATE2 + a `06_Configure` Safe TX.

For protocols with many fungible instances (Morpho vaults/markets, Balancer pools, Convex/Aura positions, Aave instances) this scales badly: every new pool is a deploy, an audit-surface delta, and a governance action. The [ADR 0001](0001-balance-adapter-factory-pattern.md) factory pattern was designed to soften this but was never shipped.

The whole oracle stack is being redeployed, which is the window to fix the structure. The question is how to let **one** adapter serve **many** instances without breaking the framework's core rule — *adapters are immutable, no `Ownable`, no admin functions* (see [ADR 0005](0005-aave-safety-module-hardcoded-immutable.md); the sole documented mutable exception is the proof-verified Merkl cache, [ADR 0007](0007-merkl-trust-minimized-cache.md)).

Two routes were considered:

1. **Owner-gated registry inside the adapter.** The adapter holds a mutable set of instances, gated by an `onlyOwner` (Security Council Safe) `addInstance`/`removeInstance`. This is what the original design discussion landed on. It works, but it makes *every* meta-adapter a new mutable, admin-controlled contract — a fresh deviation from ADR 0005 for each protocol, and a standing audit burden.

2. **Instance set held on NAVCalculator; adapter stays immutable and instance-stateless.** The adapter is a pure function of `(account, instance)` over *any* instance of the protocol. The governed "which instances do we actually query" set lives on `NAVCalculator` — which is already UUPS-upgradeable and `AccessControl`-gated (`MANAGER`) — and is passed to the adapter at query time.

## Decision

Adopt route 2. Introduce a second adapter class alongside `IBalanceOracleAdapter`:

- **`IMetaBalanceOracleAdapter`** (`src/balances/IMetaBalanceOracleAdapter.sol`) extends `IBalanceOracleAdapter` and adds two instance-aware methods keyed by a `bytes32` instance coordinate:
  - `getOraclePositionsForInstances(account, bytes32[] instances, assetFilter)`
  - `underlyingAssetsSupportedForInstances(bytes32[] instances)`
  The inherited no-arg methods return **empty** on a meta-adapter (it holds no instance set locally).
- **`MetaBalanceOracle`** (`src/balances/MetaBalanceOracle.sol`) — abstract base providing ERC165 (advertising both interfaces), per-instance fan-out with **per-instance revert isolation** (a bad instance cannot zero out the batch), and the shared registered-asset helper. Concrete adapters implement two hooks: `_instancePositions` and `_instanceAssets`. Its `getOraclePositions(account, assetFilter)` reads its own NAV-configured set via `NAV_CALCULATOR.getMetaInstances(address(this))` and fans out over it.
- **`NAVCalculator` / `Balances`** gain a per-oracle instance registry:
  - `_metaInstances` (a plain `bytes32[]` per oracle) holds the configured set; `getMetaInstances(oracle)` exposes it; `_metaInstanceTotal` is a running count used only to size the NAV read buffer.
  - `setMetaInstances` is gated by the existing `MANAGER` role — the same privilege that already governs `addBalanceOracle`. It applies to any registered oracle; only meta-adapters read the set, so it is inert for others.
  - **The NAVCalculator read path is unchanged**: it calls `getOraclePositions(account, assetFilter)` on every oracle as before. Meta-adapters pull their own set inside that call, so there is no meta-specific branch (and no per-oracle ERC165 flag) in the hot path. This also keeps `NAVCalculator` under the EIP-170 code-size limit, which a routing branch would have exceeded.
- Per-instance identity (`positionId`, `positionDetail`) is **derived on-chain** from the instance coordinate (e.g. `positionId = vaultAddress.toHexString()`, `name` read from the vault's ERC20 `name()`). Nothing instance-specific is stored in config.

The first two concrete adapters:
- **`MorphoVaultsMetaBalanceOracle`** (`src/balances/protocols/MorphoVaultsMeta.sol`): one adapter for *every* Morpho ERC4626 vault. Instance coordinate = vault address (widened to bytes32). Config: `metaInstances` (address array).
- **`MorphoMarketsMetaBalanceOracle`** (`src/balances/protocols/MorphoMarketsMeta.sol`): one adapter for *every* Morpho Blue market. Instance coordinate = the **`bytes32` marketId, used directly** (the case the bytes32 coordinate was chosen for). Emits up to three gross legs per market (collateral / loan-supply / loan-borrow), matching the per-market `MorphoMarket` adapter. Config: `metaInstancesRaw` (raw bytes32 array). Because a single asset filter can match two legs (loan-token supply + borrow), `NAVCalculator._getPositionBalances` sizes its buffer as `(oracles + metaInstanceTotal) × assetCount` in both the filtered and unfiltered cases.

- **`AaveV3InstancesMetaBalanceOracle`** (`src/balances/protocols/AaveV3InstancesMeta.sol`): one adapter for *every* Aave V3 instance (Core, Prime, …). Instance coordinate = the instance's **ProtocolDataProvider address** (widened to bytes32); reserves are enumerated trustlessly inside each instance via `getAllReservesTokens()` (not separate coordinates). Emits up to two legs per reserve (Supply/Collateral + Borrow), matching `AaveV3Instance`. Config: `metaInstances` (address array of DataProviders). Identity derived on-chain: positionId = the instance Pool (`ADDRESSES_PROVIDER.getPool()` — matches the per-instance adapter), name = `ADDRESSES_PROVIDER.getMarketId()`.

- **`BalancerV3PoolsMetaBalanceOracle`** + **`BalancerV3GaugesMetaBalanceOracle`** (`src/balances/protocols/balancer/`): the single `BalancerV3PoolBalanceOracle` (which pinned one `(pool, gauge)` and emitted both wallet-LP `Supply` and gauge `Staking`/`Rewards` legs) is **split into two meta-adapters along its two structurally distinct legs**:
  - **Pools** — wallet-held (unstaked) AMM liquidity only. Instance coordinate = the **pool/BPT address** (V3 identifies pools by address; there is no `bytes32` poolId as in V2). Emits one `Supply` leg per underlying pool token. Config: `metaInstances` (pool addresses). Constructor `(protocol, navCalculator)`.
  - **Gauges** — gauge-staked LP + BAL/extra rewards. Instance coordinate = the **gauge address**. Emits one `Staking` leg per underlying pool token (staked BPT share) plus `Rewards` legs (BAL via the minter, extra gauge reward tokens). Config: `metaInstances` (gauge addresses). Constructor `(balancerMinter, protocol, navCalculator)`.
  - The shared pool-share math (`poolBalanceOf`, ERC4626 unwrap) lives in `BalancerV3PoolLib` so both adapters stay leg-for-leg consistent with the original. The only numerical difference: the combined adapter did a single `poolBalanceOf(wallet + staked)` conversion, whereas the split converts wallet and staked separately — a ≤ a-few-units rounding difference per token (fork-tested for parity within tight tolerances).

These migrate their per-instance predecessors (`MorphoVault_*`, `MorphoMarket_*`, `AaveV3_*`, `BalancerV3_*`) in the mainnet config + integration suite; NAV value is unchanged for the address/marketId-keyed adapters (verified: position-level delta = 0) and within sub-unit rounding for the Balancer split.

**NAV read-buffer sizing.** Each meta-instance is budgeted `assetCount` rows — exactly the budget the single per-instance oracle it replaces received (`(oracles + metaInstanceTotal) × assetCount`). Multi-leg adapters (Aave supply+borrow on one reserve; a market's loan supply+borrow) rely on the global sum across the many registered oracles, the same way the per-instance `AaveV3Instance`/`MorphoMarket` adapters always have — the meta-adapters add no new buffer-overflow risk over the contracts they replace.

## Consequences

- **Adapters stay immutable.** No `Ownable`, no admin functions, no per-protocol ADR-0005 deviation. The mutable, governed state lives where mutable governed state already lives — the upgradeable, role-gated `NAVCalculator`. This is the key advantage over route 1.
- **Adding a pool/vault is a `MANAGER` TX, not a deploy.** `setMetaInstances(adapter, [...])` instead of CREATE2 + register.
- **Trust model.** `MANAGER` can add an arbitrary instance coordinate. A malicious/incorrect instance can only mis-report through the adapter's own read path (e.g. a fake ERC4626 that lies about `convertToAssets`); it cannot fabricate values out of band, and NAV still drops positions whose asset is unregistered. Instance curation is therefore a governance responsibility (index → whitelist → `MANAGER` TX), mirroring how price feeds and oracles are already added.
- **Gas / sizing.** A meta-adapter can emit up to `instances * assets` positions, so `NAVCalculator._getPositionBalances` now sizes its buffer as a sum over oracles. Per-instance reverts are isolated via an external self-call wrapped in try/catch.
- **Coexistence.** The existing per-instance adapters are untouched; keep-vs-replace is decided per protocol in follow-up migration PRs. `bytes32` was chosen for the instance coordinate so the same interface serves address-keyed protocols (vaults, pools, Aave instances) and bytes32-keyed ones (Morpho market ids).
