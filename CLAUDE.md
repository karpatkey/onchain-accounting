# CLAUDE.md

This file is auto-loaded into every Claude Code session in this repo. Treat it as the index you read before doing anything else. Detailed material lives in the per-domain docs linked below — don't duplicate it here.

## What this repo is

Onchain accounting infrastructure for portfolio NAV: **balances** (per-protocol position oracles), **prices** (Chainlink + custom feeds), **NAV** (`NAVCalculator` aggregates the two), and **bridge** (escrow + per-protocol bridge adapters). No tokenized share or sub/redeem logic lives here — that sits in a separate layer above NAV and the bridge.

`NAVCalculator` is UUPS-upgradeable. Balance and price adapters are deployed standalone (not proxied) — each is immutable post-deploy, with **one documented exception**: the Merkl rewards adapter (`src/balances/protocols/MerklRewards.sol`) keeps a per-(user, token) merkle-proof cache as mutable storage, gated by `onlyOwner` and verified on-chain against the live Merkl Distributor root, so the owner cannot fabricate amounts. See `docs/decisions/0007-merkl-trust-minimized-cache.md`. (The Aave V3 Safety Module was previously listed as the documented exception per ADR 0002; ADR 0005 superseded that and made the SM adapter fully immutable.)

## Repo layout

| Path | What lives here |
|---|---|
| `src/balances/` | Balance oracle interface (`IBalanceOracleAdapter`) + abstract `Balances` registry + per-protocol adapter contracts. Adapters live either directly under `protocols/` (single-file) or in `protocols/<protocol>/` (multi-file). The factory pattern in [ADR 0001](docs/decisions/0001-balance-adapter-factory-pattern.md) is designed but not yet implemented; `src/balances/factories/` does not exist today. |
| `src/prices/` | `IPrices`, `Prices` (abstract: Chainlink + custom feeds, staleness, L2 sequencer), `IPriceFeedCustom`, and per-asset custom price contracts under `protocols/`. |
| `src/nav/` | `NAVCalculator` (extends Prices + Balances) + `INAVCalculator`. |
| `src/bridge/` | `BridgeEscrow` + `BridgeAdapter` base + per-protocol adapters under `adapters/` (Across, CCIP, CCTP, Stargate, Superchain, Gnosis). |
| `src/utils/`, `src/errors.sol`, `src/constants.sol` | Shared helpers, errors, and constants. |
| `script/deploy/` | Numbered deploy scripts `01_*` → `06_*` (and any later additions). Reads `script/config/chains/<chainId>.json`. |
| `script/config/chains/<chainId>.json` | Per-chain deployment config: deployed addresses, asset registry, price feeds, balance adapter constructor args. |
| `test/` | Mirrors `src/`. Each protocol has a unit test alongside a fork test under `test/.../fork/`. |
| `docs/` | This onboarding folder — howto guides, decision records, price-adapter reference. |

## Read this first by intent

| If you are about to … | Read |
|---|---|
| Add a new balance adapter | `docs/howto/add-balance-adapter.md`, then `src/balances/BALANCE_ADAPTERS.md` for interface + framework details |
| Pick the next protocol to cover | `docs/roadmap/balance-adapter-coverage.md` (backlog of LST queues, restaking, RWA, perps) |
| Add a new price feed | `docs/howto/add-price-feed.md`, then `src/prices/PRICE_ADAPTERS.md` for interface + existing feeds |
| Add a new chain | `docs/howto/add-chain.md`, then `script/config/CONFIG_GUIDE.md` and `script/deploy/README.md` |
| Refresh integration-test fork blocks or add a test account | `docs/howto/refresh-integration-test-blocks.md` (single source of truth: `test/integration/accounts.json`) |
| Add a new bridge adapter | `src/bridge/BRIDGE_ADAPTERS.md` (full design + how-to in one file) |
| Change deployment scripts | `script/DEPLOYMENT_SUMMARY.md` and `script/deploy/README.md` |
| Understand why a design is the way it is | `docs/decisions/` (numbered ADRs) |
| Get a quick local environment going | `QUICKSTART.md` |
| Understand the whole repo at a glance | `README.md` (this file is a *deeper* index — README is the elevator pitch) |

## Conventions you must respect

- **Adapters report balances, not values.** Every balance oracle returns `INAVCalculator.PositionBalance[]` with `amount` always **positive** and `isDebt` flagging debt vs. credit. NAVCalculator does the pricing and signing. See `src/balances/BALANCE_ADAPTERS.md` §2–§3.
- **`balanceOracle` field is `address(this)`.** Always. It is the audit trail.
- **Adapters are immutable.** No `Ownable`, no admin functions, no upgrade. Constructor pins everything. The Merkl rewards adapter is the documented exception (proof-verified mutable cache, owner-gated; see ADR 0007). Any new mutable adapter requires a fresh ADR.
- **CREATE2 deterministic addresses for adapters.** The deployer EOA at the canonical CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` is used so the same adapter constructor inputs produce the same address on every chain. The deploy script `04_DeployBalanceAdapters.s.sol` calls `_deployIfEnabled(...)` per adapter; current adapters do NOT use a per-protocol factory contract — that pattern is **designed but not yet shipped** (see [ADR 0001](docs/decisions/0001-balance-adapter-factory-pattern.md), and `src/balances/factories/` does not exist as of `4def473`). Until the factory rollout lands, registration on `NAVCalculator` is via the `06_Configure.s.sol` Safe TX bundle (`addBalanceOracle(adapter)`), not via a factory.
- **Per-protocol folder layout.** New balance protocols go under `src/balances/protocols/<protocol>/` (or directly under `src/balances/protocols/` for single-file adapters) with matching tests under `test/balances/protocols/`. The sibling factory file pattern from ADR 0001 is aspirational — don't add one until the factory framework is shipped.
- **Solidity pragma.** `pragma solidity ^0.8;` on every file. Compiler is set in `foundry.toml`.

## Testing expectations

- `forge build` and `forge test` must pass before you push. CI runs both.
- New adapters require **both** unit tests (mock-only) under `test/balances/protocols/<Adapter>.t.sol` *and* a fork test under `test/balances/protocols/fork/<Adapter>.fork.t.sol` against a real holder at a pinned block.
- Fork tests use `FOUNDRY_PROFILE=slow forge test --match-path "test/**/fork/*.sol"` to throttle RPC.
- Don't mock the balance oracle in NAVCalculator integration tests — assert against deployed adapter instances on a fork.
- Integration tests in `test/integration/` are JSON-driven (`test/integration/accounts.json`). Don't edit fork blocks or expected NAVs directly in the per-chain `*.t.sol` files — run `script/test/refresh-integration-snapshot.sh` (see `docs/howto/refresh-integration-test-blocks.md`).

## Project rules (from MEMORY.md)

- **The user merges PRs.** When CI is green, monitor and report. Do not run `gh pr merge` yourself.
- **Don't push to `main`.** Always work on a feature branch and open a PR.
- **Pre-existing local changes are not yours to commit.** If `git status` shows files you did not touch (e.g., `foundry.toml`, scripts), leave them alone unless the user asks.

## When in doubt

Ask. The shape of this codebase is small enough that one clarifying question saves a hundred lines of misaligned code. The user prefers terse responses without trailing summaries.
