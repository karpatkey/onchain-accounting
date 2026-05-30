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
- **`MetaBalanceOracle`** (`src/balances/MetaBalanceOracle.sol`) — abstract base providing ERC165 (advertising both interfaces), the empty no-arg methods, per-instance fan-out with **per-instance revert isolation** (a bad instance cannot zero out the batch), and the shared registered-asset helper. Concrete adapters implement two hooks: `_instancePositions` and `_instanceAssets`.
- **`NAVCalculator` / `Balances`** gain a per-oracle instance registry:
  - the meta flag is resolved **once at registration** (`_addBalanceOracle` probes `IMetaBalanceOracleAdapter` via ERC165), so the read hot path is a single SLOAD, not an ERC165 probe per query;
  - `setMetaInstances` / `addMetaInstance` / `removeMetaInstance` are gated by the existing `MANAGER` role — the same privilege that already governs `addBalanceOracle`;
  - `_getOraclePositionsView` routes meta-oracles through the instance-aware method with the configured set; all other oracles are untouched.
- Per-instance identity (`positionId`, `positionDetail`) is **derived on-chain** from the instance coordinate (e.g. `positionId = vaultAddress.toHexString()`, `name` read from the vault's ERC20 `name()`). Nothing instance-specific is stored in config.

The pilot is **`MorphoVaultsMetaBalanceOracle`** (`src/balances/protocols/MorphoVaultsMeta.sol`): one adapter for *every* Morpho ERC4626 vault, with the active vault set configured on NAVCalculator.

## Consequences

- **Adapters stay immutable.** No `Ownable`, no admin functions, no per-protocol ADR-0005 deviation. The mutable, governed state lives where mutable governed state already lives — the upgradeable, role-gated `NAVCalculator`. This is the key advantage over route 1.
- **Adding a pool/vault is a `MANAGER` TX, not a deploy.** `setMetaInstances(adapter, [...])` instead of CREATE2 + register.
- **Trust model.** `MANAGER` can add an arbitrary instance coordinate. A malicious/incorrect instance can only mis-report through the adapter's own read path (e.g. a fake ERC4626 that lies about `convertToAssets`); it cannot fabricate values out of band, and NAV still drops positions whose asset is unregistered. Instance curation is therefore a governance responsibility (index → whitelist → `MANAGER` TX), mirroring how price feeds and oracles are already added.
- **Gas / sizing.** A meta-adapter can emit up to `instances * assets` positions, so `NAVCalculator._getPositionBalances` now sizes its buffer as a sum over oracles. Per-instance reverts are isolated via an external self-call wrapped in try/catch.
- **Coexistence.** The existing per-instance adapters are untouched; keep-vs-replace is decided per protocol in follow-up migration PRs. `bytes32` was chosen for the instance coordinate so the same interface serves address-keyed protocols (vaults, pools, Aave instances) and bytes32-keyed ones (Morpho market ids).
