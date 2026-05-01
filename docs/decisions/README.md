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
| 0001 | [Balance adapter factory pattern](0001-balance-adapter-factory-pattern.md) | accepted |
| 0002 | [Aave V3 Safety Module: multi-token consolidation](0002-aave-safety-module-multi-token.md) | accepted |
| 0003 | [Integration-test snapshot workflow + Debank cross-check](0003-integration-test-snapshot-workflow.md) | accepted |
