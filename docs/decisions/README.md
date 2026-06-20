# Architecture Decision Records (ADRs)

Short, numbered records of *why* the codebase looks the way it does. Read these when you want to understand the reasoning behind a non-obvious choice — or when you're about to argue with a design and want to check whether the argument has already been had.

## Convention

- Files are named `<NNNN>-<kebab-slug>.md`, numbered monotonically from `0001`.
- Each ADR has four sections:
  1. **Status** — one of: `proposed`, `accepted`, `superseded by NNNN`, `deprecated`.
  2. **Context** — what problem prompted the decision; constraints in play.
  3. **Decision** — what was decided, in plain language.
  4. **Consequences** — what changes for future contributors. Both positive and negative.
- Keep them short. ~80–150 lines each. A good ADR is read in two minutes.
- Don't edit accepted ADRs in place to revise the decision — write a new one and mark the old as `superseded by NNNN`.

## Index

| # | Title | Status |
|---|---|---|
| 0001 | [Balance adapter factory pattern](0001-balance-adapter-factory-pattern.md) | accepted (design); not yet implemented |
| 0002 | [Aave V3 Safety Module: multi-token consolidation](0002-aave-safety-module-multi-token.md) | superseded by 0005 |
| 0003 | [Integration-test snapshot workflow + Debank cross-check](0003-integration-test-snapshot-workflow.md) | accepted |
| 0004 | [Morpho: project pending interest into NAV (vs use stored values)](0004-morpho-projected-vs-stored-balances.md) | accepted |
| 0005 | [Aave V3 Safety Module: hardcoded stake-token list, immutable adapter](0005-aave-safety-module-hardcoded-immutable.md) | accepted |
| 0006 | [Aave Umbrella Balance Adapter: dynamic discovery via RewardsController](0006-aave-umbrella-balance-adapter.md) | accepted |
| 0007 | [Merkl rewards adapter: owner-gated, proof-verified, trust-minimized cache](0007-merkl-trust-minimized-cache.md) | accepted |
| 0008 | [Uniswap V3 adapter: inline GPL-2.0 math libs alongside MIT adapter code](0008-uniswap-v3-math-libs-gpl-license.md) | accepted |
| 0009 | [Multi-feed price redundancy](0009-multi-feed-price-redundancy.md) | accepted |
| 0010 | [Meta balance-adapters: one adapter per protocol, instances governed on NAVCalculator](0010-meta-balance-adapters.md) | accepted |
| 0011 | [NAVCalculator size headroom + shared adapter/feed abstractions](0011-nav-size-and-shared-abstractions.md) | accepted |
| 0012 | [Bridge: provable destination-side release (remove escrow fallback dispatcher, authenticate the real protocol)](0012-bridge-provable-release-rearchitecture.md) | proposed |
