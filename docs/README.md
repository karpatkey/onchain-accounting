# Documentation Index

Every project doc, organised by what kind of question it answers. If you're looking for "where do I find X", start here.

The companion is the top-level [`CLAUDE.md`](../CLAUDE.md) "Read this first by intent" table, which is optimised for Claude / CI sessions and points only at the docs they need most. This index is the human-facing complete map.

---

## I'm new — start here

| Doc | Purpose |
|---|---|
| [`README.md`](../README.md) | Project pitch — what `onchain-accounting` is, the four subsystems (balances, prices, NAV, bridge), and the elevator-summary architecture. |
| [`CLAUDE.md`](../CLAUDE.md) | Per-session orientation. Repo layout map + intent-keyed link table + conventions you must respect. **Read every session.** |
| [`QUICKSTART.md`](../QUICKSTART.md) | Local environment bring-up: install, env vars, first build, first test run. |
| [`docs/onboarding-claude.md`](onboarding-claude.md) | Architectural walkthrough for a new contributor (or new Claude session). Read before starting any non-trivial PR. |

---

## Adding new things — recipes (`docs/howto/`)

| Doc | When to read |
|---|---|
| [`howto/add-balance-adapter.md`](howto/add-balance-adapter.md) | Adding a new balance adapter. End-to-end: contract, unit + fork tests, chain config, deploy + register. Read [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) (framework) first. |
| [`howto/add-price-feed.md`](howto/add-price-feed.md) | Adding a new custom price feed. Same recipe shape, framework reference is [`src/prices/PRICE_ADAPTERS.md`](../src/prices/PRICE_ADAPTERS.md). |
| [`howto/add-chain.md`](howto/add-chain.md) | Adding a new chain — the per-concern config folders: `chains/<id>.json` (chain meta + roles), `contracts-deployment-config/` (what to deploy), `nav-config/` (assets + adapter registration), plus deploy steps. |
| [`howto/position-identity-schema.md`](howto/position-identity-schema.md) | **Position identity reference** — `protocolBrand`/`protocolId`/`protocolSubId` slugs, `positionId` ABI-decode schemas per protocol, `PositionKind` enum, stable reconciliation key, TypeScript decode examples, `NAVCalculator` verbose reads. Read when building indexers, frontends, or reconciliation jobs. |
| [`howto/refresh-integration-test-blocks.md`](howto/refresh-integration-test-blocks.md) | Bumping integration-test fork blocks, refreshing expected NAVs, cross-checking against DeBank. |
| [`howto/verify-oracle-heartbeat.md`](howto/verify-oracle-heartbeat.md) | Looking up Chainlink heartbeats via the reference-data-directory API; per-feed link table. |

---

## Reference tables (`docs/reference/`)

| Doc | What it is |
|---|---|
| [`reference/position-identity-matrix.md`](reference/position-identity-matrix.md) | Enumerates every position leg each balance adapter can emit — the actual `protocolSubId` / `positionId` / `PositionKind` value space, verified against `src/balances/` emission code. Companion to [`howto/position-identity-schema.md`](howto/position-identity-schema.md), which defines the schema. |

---

## Framework references — what is each subsystem?

| Doc | Subsystem |
|---|---|
| [`src/balances/BALANCE_ADAPTERS.md`](../src/balances/BALANCE_ADAPTERS.md) | Balance adapter architecture — `IBalanceAdapter`, `Balances` registry, all implemented adapters. |
| [`src/prices/PRICE_ADAPTERS.md`](../src/prices/PRICE_ADAPTERS.md) | Price feed architecture — `Prices` registry, `ICustomPriceFeed`, all implemented custom feeds. |
| [`src/bridge/BRIDGE_ADAPTERS.md`](../src/bridge/BRIDGE_ADAPTERS.md) | Bridge module — `BridgeEscrow` + per-protocol bridge adapters (CCIP, Across, CCTP, Stargate, Superchain, Gnosis). |

---

## Architecture decisions (`docs/decisions/`)

Numbered ADRs. Read when you want the *why* behind a design choice.

| ADR | Topic |
|---|---|
| [`0001-balance-adapter-factory-pattern.md`](decisions/0001-balance-adapter-factory-pattern.md) | CREATE2 factory pattern for balance adapters. |
| [`0002-aave-safety-module-multi-token.md`](decisions/0002-aave-safety-module-multi-token.md) | (Superseded by 0005.) |
| [`0003-integration-test-snapshot-workflow.md`](decisions/0003-integration-test-snapshot-workflow.md) | JSON-driven fork-test snapshots; weekly refresh cron; DeBank cross-check. |
| [`0004-morpho-projected-vs-stored-balances.md`](decisions/0004-morpho-projected-vs-stored-balances.md) | Morpho projected-share accounting vs stored values. |
| [`0005-aave-safety-module-hardcoded-immutable.md`](decisions/0005-aave-safety-module-hardcoded-immutable.md) | Aave V3 SM adapter immutability (supersedes 0002). |
| [`0006-aave-umbrella-balance-adapter.md`](decisions/0006-aave-umbrella-balance-adapter.md) | Aave Umbrella stake-token coverage. |
| [`0007-merkl-trust-minimized-cache.md`](decisions/0007-merkl-trust-minimized-cache.md) | Merkl rewards adapter — the framework's documented mutable-adapter exception. |
| [`0008-uniswap-v3-math-libs-gpl-license.md`](decisions/0008-uniswap-v3-math-libs-gpl-license.md) | License rationale for Uni V3 math library inclusion. |
| [`0009-multi-feed-price-redundancy.md`](decisions/0009-multi-feed-price-redundancy.md) | Multi-feed price redundancy / freshest-feed selection. |
| [`0010-meta-balance-adapters.md`](decisions/0010-meta-balance-adapters.md) | Meta balance-adapters: one adapter per protocol, instances governed on NAVCalculator. |
| [`0011-nav-size-and-shared-abstractions.md`](decisions/0011-nav-size-and-shared-abstractions.md) | NAVCalculator size headroom (EIP-170) + shared adapter/feed abstractions. |
| [`0012-bridge-provable-release-rearchitecture.md`](decisions/0012-bridge-provable-release-rearchitecture.md) | Bridge: provable destination-side release (remove the escrow fallback dispatcher, authenticate the real protocol). |
| [`0014-agent-fed-cache-adapters-for-exit-queues.md`](decisions/0014-agent-fed-cache-adapters-for-exit-queues.md) | Agent-fed cache adapters for non-enumerable withdrawal/exit queues (ether.fi, StakeWise V3). |
| [`0015-assisted-balance-adapter-family.md`](decisions/0015-assisted-balance-adapter-family.md) | Assisted balance-adapter family — shared interface + AccessControl base. |
| [`0016-islocked-position-status.md`](decisions/0016-islocked-position-status.md) | `isLocked` position status (claimable vs locked) via a static positionId + two-leg split. |
| [`0017-lp-valuation-instantaneous-amounts.md`](decisions/0017-lp-valuation-instantaneous-amounts.md) | LP-position valuation: report instantaneous underlying amounts; pool-liquidity manipulation out of scope under an async NAV consumer. |
| [`decisions/README.md`](decisions/README.md) | ADR index + template. |

---

## Operations (`docs/operations/`)

| Doc | When to use |
|---|---|
| [`operations/merkl-proof-submitter.md`](operations/merkl-proof-submitter.md) | Periodic operator loop that fetches Merkl proofs and pushes them to the `MerklRewardsAssistedBalanceAdapter` cache so unclaimed rewards stay valued in NAV. |
| [`operations/etherfi-withdrawals-submitter.md`](operations/etherfi-withdrawals-submitter.md) | Operator bot that discovers an account's ether.fi `WithdrawRequestNFT` tokenIds and submits them to the `EtherFiWithdrawalQueueAssistedBalanceAdapter` id cache (ids only — the adapter values them live). |
| [`operations/stakewise-exit-submitter.md`](operations/stakewise-exit-submitter.md) | Operator bot that discovers an account's StakeWise V3 exit-queue positions (`(vault, positionTicket, timestamp)`) and submits them to the `StakeWiseV3ExitQueueAssistedBalanceAdapter` cache (coordinates only — the adapter values them live). |

---

## Roadmap (`docs/roadmap/`)

| Doc | Use |
|---|---|
| [`roadmap/balance-adapter-coverage.md`](roadmap/balance-adapter-coverage.md) | Backlog of protocols / position types not yet covered by balance adapters (LST withdrawal queues, restaking primitives, RWA, perps). Pick from here when adding a new adapter. |
| [`roadmap/comparison-report-improvements.md`](roadmap/comparison-report-improvements.md) | Polish backlog for the `comparison-report.md` generator (drift breakdown lines, Etherscan links, sub-row tables, etc.). |

---

## Deploys + production state (`script/`)

| Doc | When to read |
|---|---|
| [`script/DEPLOYMENT_SUMMARY.md`](../script/DEPLOYMENT_SUMMARY.md) | **Architectural overview** of the deployment system — CREATE2, atomic proxy deploy, EOA-only deploy/config with a final admin handoff to the security-council Safe, the per-script roles (`01_…` → `07_…`). Read first if new. |
| [`script/NAV_V2_DEPLOYMENT_RUNBOOK.md`](../script/NAV_V2_DEPLOYMENT_RUNBOOK.md) | **Operational playbook** — step-by-step deploy guide. The living doc; companion to DEPLOYMENT_SUMMARY. Use when deploying to a new chain, deploying additional adapters to a live chain, registering new assets, rotating roles, validating an existing deployment. |
| [`script/DEPLOYED_ADDRESSES.md`](../script/DEPLOYED_ADDRESSES.md) | Current production addresses per chain — NAVCalculator proxy + impl, every deployed price-feed and balance adapter. Updated after each production deploy. |
| [`script/PENDING_DEPLOYS.md`](../script/PENDING_DEPLOYS.md) | What's wired in code but not yet on mainnet — running checklist for the next deploy session. |
| [`script/config/CONFIG_GUIDE.md`](../script/config/CONFIG_GUIDE.md) | Schema and conventions for `chains/<chainId>.json` plus the `contracts-deployment-config/` and `nav-config/` per-chain files. |
| [`script/config/README.md`](../script/config/README.md) | Per-folder index for `script/config/`. |
| [`script/deploy/README.md`](../script/deploy/README.md) | Per-script reference for the `01_…` → `07_…` deploy scripts. |
| [`script/test/README.md`](../script/test/README.md) | Reference for the deployment-script tests in `script/test/` (this folder also holds the snapshot-refresh and comparison-report scripts). |

---

## Security audits (`docs/audits/`)

| Doc | What it covers |
|---|---|
| [`audits/2026-06-final-pre-deploy-audit.md`](audits/2026-06-final-pre-deploy-audit.md) | Final pre-deployment audit covering all of `src/` — core (NAVCalculator, PriceFeedLib, Prices, Balances), every custom price feed, and every balance + meta-balance adapter and their math libs. |
| [`audits/2026-06-nav-core-internal-audit.md`](audits/2026-06-nav-core-internal-audit.md) | Internal audit scoped to `src/nav/`, `src/prices/`, and `src/balances/` (bridge out of scope). |
| [`audits/2026-06-vigilo-adapter-audit.md`](audits/2026-06-vigilo-adapter-audit.md) | Vigilo per-adapter audit — each balance / meta / assisted adapter and custom price feed audited individually. |
| [`audits/2026-06-vigilo-automated-audit.md`](audits/2026-06-vigilo-automated-audit.md) | Vigilo automated multi-agent audit across all of `src/**` plus the `01`–`07` deploy scripts. |
| [`audits/2026-06-vigilo-remediation.md`](audits/2026-06-vigilo-remediation.md) | Remediation triage — disposition of every Vigilo finding (fixed vs. deliberately not, with reasons). Companion to the automated-audit doc. |

---

## Historical / archival (`docs/historical/`)

| Doc | Why kept |
|---|---|
| [`historical/oracle-migration-plan.md`](historical/oracle-migration-plan.md) | The NAV v1 → v2 oracle (price + balance) migration plan (PRs #10, #11, #12, completed 2026-04-17). Preserved as the authoritative record of what was ported, why specific divergences were accepted, and which follow-ups remained open at that point. **Not for current ops** — see `script/NAV_V2_DEPLOYMENT_RUNBOOK.md` for that. |

---

## Generated artifacts (committed for review)

| File | What it is |
|---|---|
| [`comparison-report.md`](../comparison-report.md) | Per-(account × chain) NAV-vs-DeBank comparison. Regenerated by `script/test/generate-comparison-report.py`. The drift summary table at the top is the headline. |
| [`refresh-report.md`](../refresh-report.md) | Compact summary of the most-recent `refresh-integration-snapshot.sh` run — fork blocks, per-account NAV/drift, DeBank credit consumption. Regenerated on every snapshot bump. |

---

## Where to track a NAV-vs-DeBank gap

When you spot a position in `comparison-report.md` that NAV doesn't cover (a `—` row, a drift on a specific account, etc.), the right place to record it depends on **what action would close it**. Four-bucket partition by intent:

| Bucket | When to use | Where it lives |
|---|---|---|
| **Untracked by design** | The gap is intentional — token has no Chainlink mainnet feed, protocol is deprecated/legacy, etc. "Will not fix unless rule changes." | `test/integration/accounts.json.chains.<chainId>.$untracked_by_design` (per-chain prose field; today only chain 1 is populated). |
| **Pending production deploy** | Adapter / price-feed code is in the repo and the harness already exercises it; just hasn't been deployed to mainnet yet. "Wire's done, ship pending." | [`script/PENDING_DEPLOYS.md`](../script/PENDING_DEPLOYS.md) — operational checklist with the forge invocations + Safe TX flow. |
| **Need new adapter / feed code** | The gap requires a new contract or new ADR. "Have to build something." | [`roadmap/balance-adapter-coverage.md`](roadmap/balance-adapter-coverage.md) for missing balance adapters; [`howto/add-price-feed.md`](howto/add-price-feed.md) is the recipe to fix one. |
| **Display polish / matcher heuristics** | The math is right but the report's per-row pairing or layout could be clearer. "Visual / UX work on the report itself." | [`roadmap/comparison-report-improvements.md`](roadmap/comparison-report-improvements.md). |

A single gap should land in exactly one of these — the bucket determines who owns the next action. If it doesn't fit any, that's a flag worth raising before adding a fifth bucket.
