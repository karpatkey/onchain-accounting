# 0005 — Aave V3 Safety Module: hardcoded stake-token list, immutable adapter

**Status:** accepted  •  **Supersedes:** [0002](0002-aave-safety-module-multi-token.md)

## Context

ADR 0002 picked an `Ownable` adapter with an admin-managed list of registered stake tokens. The framework convention captured in the original PR (#16/#17) was that *every* balance adapter is immutable and write-function-free — 0002 carved out the SM as the one explicit exception, justified by the ergonomics of adding new SM stake tokens via a single admin call rather than a new deploy + register flow.

Reviewing that decision before implementation landed: the framework convention is more valuable than the marginal ergonomic gain. An adapter that exposes admin functions is a permanent surface area for trust, key management, and audit attention; even with a well-secured Safe behind it, every reviewer of every future change has to remember that this adapter is special. By contrast:

- The legacy Safety Module set is small and slow-moving. As of 2026-05, the full set is **four stake tokens**: `stkAAVE`, `stkABPT` (Balancer V1 BPT), `stkABPTv2` (Balancer V2 AAVE/wstETH BPT), `stkGHO`. New additions (the next being Aave Umbrella, which uses a different contract architecture and will get its own adapter) are infrequent enough that "redeploy when the set changes" is not painful.
- Reward tokens are uniform (AAVE for all four), and `STAKED_TOKEN()` for each is well-known. There's no operational reason the addresses have to be discovered at deploy time.
- Aave does not publish an on-chain registry of SM stake tokens (see ADR 0002's earlier analysis). Without on-chain discovery, an admin-managed list is the only way to *add* tokens at runtime — which loops back to the question of whether the runtime addition itself is actually valuable.

## Decision

Make `AaveV3SafetyModuleBalanceAdapter` fully **immutable** and **write-function-free**. The four legacy SM stake-token addresses, their staked / reward tokens, and their per-position labels are pinned as compile-time `address public constant` declarations and assembled in a `pure` `_records()` function. The constructor takes only `(navCalculator)` — no admin, no Ownable, no `addStakeToken` / `removeStakeToken`, no init list.

Concretely:

- 4 `STK_*` constants (the stake token addresses).
- 4 staked/reward asset constants (`AAVE`, `GHO`, `ABPT`, `ABPT_V2` — `AAVE` doubles as the staked asset of stkAAVE and the reward of all four).
- A `_records()` function returning a fixed `StakeTokenRecord[4]`, used by the position/balance functions.
- `underlyingAssetsSupported()` returns the deduplicated four-asset union.

When Aave governance ships a new SM stake token, updating this adapter is a **source-code change** (new constant + new record + new test holder) followed by a fresh deploy + Safe-transaction registration on `NAVCalculator`. Same flow as adding any other adapter.

## Consequences

**Positive:**

- One uniform rule for the framework: every balance adapter is immutable. No "but the SM is special" carve-out for reviewers, future contributors, or future Claude sessions to remember.
- No admin role, no Ownable, no `addStakeToken` / `removeStakeToken`. Smaller surface area, smaller bytecode, simpler audit story.
- Constructor takes one argument (`navCalculator`) instead of four. `04_DeployBalanceAdapters.s.sol` reads only the `enabled` flag from the balance-adapter deploy config (`contracts-deployment-config/balance-adapters/<chainId>.json`); that config no longer needs `admin`/`stakeTokenAddresses`/`stakeTokenDetails` fields.
- Compile-time verification: a wiring bug (wrong stkAAVE address, wrong reward token) would have to land via a code review of the constants table — caught at review time, not at runtime.

**Negative / things to watch:**

- Adding a new SM stake token requires a code change + redeploy + Safe transaction (remove old adapter, add new). Higher friction than the admin-call shape from 0002, but acceptable for an event that happens at most once or twice a year.
- The adapter is **Mainnet-only** in spirit (the legacy SM is an Ethereum-mainnet protocol; deploying on another chain is meaningless). The constants are baked in; running this contract on any other chain would resolve those addresses to EOAs and revert at the first `IStakeToken.balanceOf` call. This is fine because chain config gates deployment per-chain; it's worth keeping in mind.
- A future Aave Umbrella migration (where `stkGHO` becomes `sGHO`, etc.) requires a new adapter altogether — Umbrella uses different contracts (`Umbrella` / `StakeToken` / `RewardsController`) with different interfaces. That work goes in its own ADR.

## Test holders

Fork tests cover all four stake tokens against real holders sourced from recent Transfer-event logs, verified to have non-zero current balances at the pinned fork block:

| Stake token | Holder |
|---|---|
| stkAAVE | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| stkABPT | `0xD9a776A672E4Df85bbbE97d390Ff9674B382d2ea` |
| stkABPTv2 | `0x000000000004444c5dc75cB358380D2e3dE08A90` (same address as stkAAVE — also useful for cross-stake-token AAVE-summing tests) |
| stkGHO | `0xa94ec39c91DF334DCAb55aDaA8EdD9C1dAF67cA7` |

When refreshing fork blocks (via the bump workflow described in `docs/howto/refresh-integration-test-blocks.md`), re-verify these addresses still hold positions. If a holder withdraws between bumps, swap in a fresh one from a Transfer-events scan over the last few hundred thousand blocks.

## Alternatives considered

1. **Admin-managed list with Ownable (ADR 0002's design).** Rejected per the rationale above — the framework-uniformity argument outweighs the runtime-flexibility argument given how rarely the SM set changes.
2. **Read `STAKED_TOKEN()` / `REWARD_TOKEN()` from each stake token at deploy time** (rather than hardcoding both). Rejected because it adds 8 RPC reads to construction with no upside — the staked/reward addresses are known facts, and pinning them in source surfaces wiring bugs at code review.
3. **Discovery via on-chain registry.** Rejected because Aave does not publish one for the legacy SM. Umbrella has a partial reverse-lookup (`Umbrella.tokenForDeficitCoverage(reserve)`) combined with `Pool.getReservesList()` — but that's Umbrella-specific and will live in a future Umbrella adapter, not this one.

## Reference

- Adapter: `src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol`
- Tests: `test/balances/protocols/AaveV3SafetyModuleBalanceAdapter.t.sol` (unit), `test/balances/protocols/fork/AaveV3SafetyModuleBalanceAdapter.fork.t.sol` (fork)
- Deploy schema: `script/config/contracts-deployment-config/balance-adapters/1.json` `AaveV3SafetyModule` (deploy intent) and `script/config/nav-config/balance-adapters/1.json` `AaveV3SafetyModule` (NAV-registration intent). `04`'s `_deployAaveV3SafetyModule` reads only the `enabled` flag and passes `navCalculator` to the constructor; the stake-token set is hardcoded in the adapter. (The deploy-config entry still carries a vestigial `constructor` block — `protocol`/`positionDetail`/`positionId` — which this adapter's deploy path ignores; the nav-config entry is `enabled`-only.)
- Migration: replaced `0x191d6b8EdD19167e90419347d586081E2B01D8dD` on Mainnet via `nav.removeBalanceAdapters(legacy)` + `nav.addBalanceAdapters(new)` (two Safe transactions) — same pattern used for every adapter pre-#16.
- Superseded: ADR [0002](0002-aave-safety-module-multi-token.md) (the admin-managed-list design)
