# 0002 — Aave V3 Safety Module: multi-token consolidation

**Status:** **superseded by [0005](0005-aave-safety-module-hardcoded-immutable.md)** (2026-XX-XX). The multi-token adapter described below was reverted in favour of a single-instance-per-stake-token immutable adapter — see ADR 0005 for the rationale. This document is preserved as the historical context for the change.

## Context

The first version of `AaveV3SafetyModuleBalanceOracle` (`src/balances/protocols/aave/AaveV3SafetyModule.sol`) followed the same shape as every other balance adapter in the framework: **one immutable instance per stake token**. Constructor: `(stakeToken, navCalculator)`. The adapter reads `STAKED_TOKEN()` and `REWARD_TOKEN()` from the stake contract at construction and pins them as immutables.

This is **already token-agnostic at the bytecode level** — the same compiled contract handles stkAAVE, stkABPT, stkGHO. To support a new stake token you call the factory with a different `stakeToken` parameter and get a different deterministic address. With CREATE2, that's a single call.

The adapter set in production at the time this ADR was written: `stkGHO` only, deployed at `0x191d6b8EdD19167e90419347d586081E2B01D8dD` on Mainnet.

So the question was: keep doing one instance per stake token, or consolidate into a single multi-token adapter that holds an admin-managed list of registered stake tokens?

Considerations:

- The Safety Module token set is small (3 active: stkAAVE, stkABPT, stkGHO; stkGHO is being migrated to sGHO via Aave Umbrella) and changes rarely.
- All Safety Module stake tokens share the same minimal interface (`STAKED_TOKEN`, `REWARD_TOKEN`, `balanceOf`, `previewRedeem`-style, `getTotalRewardsBalance`).
- There is **no on-chain registry** of Safety Module stake tokens. Each stake contract is standalone.
- Per-token attribution matters: a NAV consumer needs to distinguish "AAVE rewards from stkGHO" from "AAVE staked + rewards from stkAAVE."
- Every other adapter in the framework is immutable post-deploy. Mutable adapters introduce admin risk (a compromised admin can register a malicious stake token that returns inflated balances).

## Decision

Consolidate into **a single multi-token Safety Module adapter per chain**, with an admin-managed list of registered stake tokens.

Concretely:

- The adapter inherits `Ownable`. Admin = the OIV Safe.
- Storage holds a list of `StakeTokenInfo { stakedToken, rewardToken }` entries, indexed by stake-token address.
- Admin functions `addStakeToken(stakeToken)` and `removeStakeToken(stakeToken)` mutate the list. Adding queries `STAKED_TOKEN()` / `REWARD_TOKEN()` from the contract and pins them in storage; removing prunes the entry.
- The constructor accepts an initial list so the deploy + initial registration happens atomically.
- `getOraclePositions(account, assetFilter)` emits **one position per (stakeToken, role) pair** so attribution is preserved. A user with both stkGHO and stkAAVE balances sees three distinct positions: GHO as `Supplied` (stkGHO principal), AAVE as `Earned` (stkGHO rewards), and AAVE as `Supplied`/`Earned` (stkAAVE stake + rewards, merged into one entry because stkAAVE's staked and reward tokens are both AAVE). The stakeToken is encoded in each `positionId`.
- `getOracleBalanceForAsset(account, asset)` returns the **summed** balance across all registered stake tokens for that asset.
- The factory deploys a single canonical instance per chain. `PROTOCOL_KEY` is unchanged: `keccak256("AaveV3SafetyModule")`. The new factory `deploy` signature takes the initial stake-token list, the admin address, the protocol name, and a salt.
- Migration (Mainnet): the existing single-token stkGHO adapter is unregistered via `BalanceAdapterRegistry.unregister`, the new multi-token adapter is deployed (initial list = `[stkGHO]`), and the registry registers the new adapter on `NAVCalculator`. The old adapter stays on-chain but is no longer queried.

## Consequences

**Positive:**

- One adapter address per chain regardless of how many stake tokens are supported. Less ops surface (fewer `BalanceAdapterRegistry` registrations, fewer NAV oracle entries, fewer addresses for off-chain consumers to know about).
- Adding a new Safety Module stake token (e.g., a future Umbrella token) is a single admin call rather than a factory deploy + register flow.
- Per-token attribution is preserved via `positionId` (encoding the stakeToken address) on each `PositionBalance`.
- `getOracleBalanceForAsset` collapses cross-stake-token AAVE rewards into a single number, which is what NAV consumers actually want for "how much AAVE does this account have effective claim on."

**Negative / things to watch:**

- This is **the only mutable adapter in the framework.** Every other adapter is immutable post-deploy. Future contributors must read [`/CLAUDE.md`](../../CLAUDE.md) and this ADR before assuming all adapters are static.
- Admin risk: a compromised owner can register a malicious "stake token" contract that satisfies the minimal interface and returns inflated balances. Mitigations: admin is the OIV Safe (multisig), the registry's protocol key remains `keccak256("AaveV3SafetyModule")` so off-chain consumers can detect unexpected adapter swaps, and the contract validates that registered stake tokens actually return non-zero `STAKED_TOKEN()` and `REWARD_TOKEN()` at registration time.
- Reasoning had to be captured here because the consolidation is *not* an obvious improvement — the per-token design was already token-agnostic. If a future contributor asks "why didn't we just deploy more instances?", point them here.
- Any **future** mutable adapter requires its own ADR justifying the deviation. This is a one-off, not a precedent.

## Alternatives considered

1. **Status quo: keep one immutable instance per stake token.** Rejected for the ops-overhead reasons above. The instance count is small but the surface area (separate addresses, separate registry entries, separate NAV oracle slots) is real and grows linearly.
2. **Generic on-chain Safety Module registry.** Rejected because no such registry exists in Aave V3. Building one (an off-chain–curated list maintained on-chain) is exactly what this adapter now does internally.
3. **Hybrid: keep the per-token adapter shape, but route registrations through a thin "router" contract.** Rejected as it adds a layer without removing the per-token adapters; ops surface stays the same.

## Reference

- Adapter: `src/balances/protocols/aave/AaveV3SafetyModule.sol`
- Factory: `src/balances/protocols/aave/AaveV3SafetyModuleAdapterFactory.sol`
- Tests: `test/balances/protocols/AaveV3SafetyModule.t.sol`, `test/balances/protocols/fork/AaveV3SafetyModule.fork.t.sol`
- Migration script: `script/deploy/07_MigrateSafetyModule.s.sol`
- Framework reference: ADR [0001](0001-balance-adapter-factory-pattern.md)
