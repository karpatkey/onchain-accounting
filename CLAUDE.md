# CLAUDE.md

This file is auto-loaded into every Claude Code session in this repo. Treat it as the index you read before doing anything else. Detailed material lives in the per-domain docs linked below — don't duplicate it here.

## What this repo is

Onchain accounting infrastructure for portfolio NAV: **balances** (per-protocol position oracles), **prices** (Chainlink + custom feeds), **NAV** (`NAVCalculator` aggregates the two), and **bridge** (escrow + per-protocol bridge adapters). No tokenized share or sub/redeem logic lives here — that sits in a separate layer above NAV and the bridge.

`NAVCalculator` is UUPS-upgradeable. Balance and price adapters are deployed standalone (not proxied) — each is immutable post-deploy, with **one documented exception** (the Aave V3 Safety Module adapter; see `docs/decisions/0002-aave-safety-module-multi-token.md`).

## Repo layout

| Path | What lives here |
|---|---|
| `src/balances/` | Balance oracle interface + abstract `Balances` registry, plus per-protocol adapters under `protocols/<protocol>/`. Each protocol folder typically holds the adapter and a CREATE2 factory that inherits `BalanceAdapterFactoryBase`. |
| `src/balances/factories/` | `BalanceAdapterFactoryBase` (CREATE2 deploy + ERC165 check + registry hookup) and `BalanceAdapterRegistry` (central registry; holds MANAGER on `NAVCalculator`). |
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
| Add a new price feed | `docs/howto/add-price-feed.md`, then `docs/PRICE_ADAPTERS.md` for interface + existing feeds |
| Add a new chain | `docs/howto/add-chain.md`, then `script/config/CONFIG_GUIDE.md` and `script/deploy/README.md` |
| Add a new bridge adapter | `src/bridge/BRIDGE_ADAPTERS.md` (full design + how-to in one file) |
| Change deployment scripts | `script/DEPLOYMENT_SUMMARY.md` and `script/deploy/README.md` |
| Understand why a design is the way it is | `docs/decisions/` (numbered ADRs) |
| Get a quick local environment going | `QUICKSTART.md` |
| Understand the whole repo at a glance | `README.md` (this file is a *deeper* index — README is the elevator pitch) |

## Conventions you must respect

- **Adapters report balances, not values.** Every balance oracle returns `INAVCalculator.PositionBalance[]` with `amount` always **positive** and `isDebt` flagging debt vs. credit. NAVCalculator does the pricing and signing. See `src/balances/BALANCE_ADAPTERS.md` §2–§3.
- **`balanceOracle` field is `address(this)`.** Always. It is the audit trail.
- **Adapters are immutable.** No `Ownable`, no admin functions, no upgrade. Constructor pins everything. The Safety Module adapter is the documented exception (mutable stake-token list); any new mutable adapter requires a fresh ADR.
- **Factories are CREATE2.** Every per-protocol factory inherits `BalanceAdapterFactoryBase` and pins `PROTOCOL_KEY = keccak256("<ProtocolName>")` at construction. Cross-chain identical addresses for the same `(initCode, salt)`. Canonical deployer: `0x4e59b44847b379578588920cA78FbF26c0B4956C`. See `src/balances/factories/BalanceAdapterFactoryBase.sol`.
- **Registration goes through `BalanceAdapterRegistry`.** The registry owns MANAGER on `NAVCalculator`. Factory `deploy()` ends with `REGISTRY.register(adapter)`; never call `NAVCalculator.addBalanceOracle` directly.
- **Per-protocol folder layout.** New balance protocols go under `src/balances/protocols/<protocol>/` with a sibling factory file (`<Protocol>AdapterFactory.sol`) and matching tests under `test/balances/protocols/`.
- **Salt versioning.** Salts for factory-deployed adapters and for the factories themselves are derived from `(name, FACTORY_SALT_VERSION)` in `script/deploy/05_DeployAdapterFactories.s.sol`. Bump the version field rather than minting ad-hoc salts.
- **Solidity pragma.** `pragma solidity ^0.8;` on every file. Compiler is set in `foundry.toml`.

## Testing expectations

- `forge build` and `forge test` must pass before you push. CI runs both.
- New adapters require **both** unit tests (mock-only) under `test/balances/protocols/<Adapter>.t.sol` *and* a fork test under `test/balances/protocols/fork/<Adapter>.fork.t.sol` against a real holder at a pinned block.
- Fork tests use `FOUNDRY_PROFILE=slow forge test --match-path "test/**/fork/*.sol"` to throttle RPC.
- Don't mock the balance oracle in NAVCalculator integration tests — assert against deployed adapter instances on a fork.

## Project rules (from MEMORY.md)

- **The user merges PRs.** When CI is green, monitor and report. Do not run `gh pr merge` yourself.
- **Don't push to `main`.** Always work on a feature branch and open a PR.
- **Pre-existing local changes are not yours to commit.** If `git status` shows files you did not touch (e.g., `foundry.toml`, scripts), leave them alone unless the user asks.

## When in doubt

Ask. The shape of this codebase is small enough that one clarifying question saves a hundred lines of misaligned code. The user prefers terse responses without trailing summaries.
