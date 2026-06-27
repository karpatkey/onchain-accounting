# 0001 — Balance adapter factory pattern

**Status:** accepted (in design); **not yet implemented in the codebase as of `4def473` (2026-05-06)**.

> **Reality check.** The factory framework described below — `BalanceAdapterFactoryBase`, `BalanceAdapterRegistry`, `05_DeployAdapterFactories.s.sol`, `06_MigrateExistingAdapters.s.sol` — was designed but has not yet been shipped. `src/balances/factories/` does not exist today; the directory is reserved for the future rollout. The current production deploy uses `04_DeployBalanceAdapters.s.sol` calling `_deployIfEnabled(...)` per adapter (plain `new ...` / CREATE, so adapter addresses are chain- and run-specific — not deterministic across chains), with registration via `06_Configure.s.sol` broadcasting directly from the deployer EOA (no Safe) and calling `NAVCalculator.addBalanceAdapters(address[])`. The aspirational design below remains the target end state; until then, treat references to it elsewhere in the docs as forward-looking.

## Context

Before this change, every balance adapter was deployed by an ad-hoc deploy step in `script/deploy/04_DeployBalanceAdapters.s.sol` and registered by a direct call to `NAVCalculator.addBalanceAdapters(address[])` from the OIV Safe. This worked, but had three rough edges that compounded as the adapter set grew (~14 protocols, multi-chain):

1. **No deterministic addresses.** Adapters lived at different addresses on every chain. Cross-chain tooling (block explorers, dashboards, off-chain consumers) had to maintain per-chain address books. There was no on-chain way to ask "give me every adapter for protocol X."
2. **Two-step ceremony.** Deploy in one transaction; register in a follow-up Safe transaction. Safe queues sometimes lagged days behind deploys, leaving "deployed but unregistered" adapters lying around.
3. **No per-protocol grouping.** All adapters were a flat list inside NAVCalculator. There was no central index, no protocol key, no way to migrate or replace adapters in a structured way.

The framework needs to support: adding new protocols frequently, deploying them on multiple chains atomically, replacing adapters cleanly, and querying the active set per protocol — all from on-chain state, not config files.

## Decision

Introduce a per-protocol **factory pattern** + a **central registry**:

1. **`BalanceAdapterFactoryBase`** (`src/balances/factories/BalanceAdapterFactoryBase.sol`): abstract base every per-protocol factory inherits from. Pins a `PROTOCOL_KEY = keccak256("<ProtocolName>")` at construction. Owns the per-protocol list of deployed adapters. Deploys via the **canonical CREATE2 deployer** at `0x4e59b44847b379578588920cA78FbF26c0B4956C`, so adapter addresses are identical on every chain for the same `(initCode, salt)`.

2. **`BalanceAdapterRegistry`** (`src/balances/factories/BalanceAdapterRegistry.sol`): the single registry that maps `protocolKey ⇒ factory`, owns MANAGER on `NAVCalculator`, and is the **only** entity that calls `NAVCalculator.addBalanceAdapters` / `removeBalanceAdapters`. Every factory's `deploy(...)` ends with `REGISTRY.register(adapter)`; the registry idempotently registers in NAV.

3. **Per-protocol folder layout** under `src/balances/{BalanceAdapters,MetaBalanceAdapters,AssistedBalanceAdapters}/`: each folder holds the adapter contract and its sibling factory. Same convention for tests.

4. **Migration hook for pre-existing adapters**: factories expose `registerExternal(adapter)` to absorb adapters deployed before the framework existed. The registry's `_register` is idempotent (checks `NAVCalculator.isAdapterRegistered`), so absorbing a pre-registered adapter just records it in registry state without duplicating in NAV.

5. **Salt versioning**: salts for both factories and adapters are derived from `(name, FACTORY_SALT_VERSION)` in `script/deploy/05_DeployAdapterFactories.s.sol`. Bumping the version field is the way to change a deployment address; ad-hoc salts are discouraged.

## Consequences

**Positive:**

- Adapter addresses are deterministic across chains. Same `(MorphoVault, salt-for-kpkUSDCPrime-V1)` resolves to the same address on Mainnet, Arbitrum, Base, etc.
- Deploy + register is one transaction. No more orphaned adapters between Safe queues.
- `BalanceAdapterRegistry.getAdaptersByProtocol(key)` returns the live set per protocol, on-chain.
- Replacing an adapter is supported: the registry's `unregister(adapter)` removes from NAV *and* notifies the originating factory (`onAdapterUnregistered`), keeping all bookkeeping consistent.
- New chains get the same factory addresses for free if `FACTORY_SALT_VERSION` is unchanged.

**Negative / things to watch:**

- Adapters and factories must follow the strict pattern (constructor signature, `PROTOCOL_KEY` at construction, ERC165 conformance). Deviation breaks address determinism or registry tracking. The single mutable-adapter exception (the Merkl rewards adapter — see ADR 0007; the Aave V3 Safety Module was the original exception under ADR 0002, but ADR 0005 superseded that and made it fully immutable) was added explicitly and required documentation.
- The registry is the single owner of MANAGER on NAVCalculator. If the registry is compromised, NAV adapter list is at risk. Mitigation: registry is `Ownable` and the Safe is the only authorized factory-setter / external-registrar.
- CREATE2 with the canonical deployer requires that deployer to exist on the target chain. Standard EVM chains have it; verify before deploying to anything exotic.
- One factory per protocol means N factory contracts to maintain. Acceptable cost for the structural benefits; partially offset by the shared base class doing all the heavy lifting.

## Reference

- Implementation: `src/balances/factories/BalanceAdapterFactoryBase.sol`, `src/balances/factories/BalanceAdapterRegistry.sol`.
- Deploy script: `script/deploy/05_DeployAdapterFactories.s.sol`.
- Migration script: `script/deploy/06_MigrateExistingAdapters.s.sol`.
- Walkthrough: [`../howto/add-balance-adapter.md`](../howto/add-balance-adapter.md).
