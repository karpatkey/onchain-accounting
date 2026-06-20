# Development infra (anvil + fresh NAV)

Spin up five anvil forks (Ethereum, Optimism, Gnosis, Arbitrum, Base), deploy a fresh NAV v2 proxy
on each, point the Next.js dashboard at them. State persists between sessions via anvil's
`--state` flag, so you only redeploy when you choose to (after an interface change, say).

This tree is intentionally minimal: only the pieces that differ from the prod deploy live here.
Custom price feeds and per-protocol balance adapters reuse `script/deploy/03_DeployPriceFeeds.s.sol`
and `script/deploy/04_DeployBalanceAdapters.s.sol` directly against the dev anvil RPC.

## Why

- No gas, no real-world side effects.
- Free to break/replace the NAV interface and balance-adapter interfaces between iterations.
- Persistent state means you pay the slow first-fork cost once, then resume in seconds.

## Prereqs

- `anvil` and `forge` on PATH (Foundry).
- `jq`.
- `app/` dependencies installed (one-time `pnpm install` inside `app/`). On Windows/WSL, install
  node natively in WSL (the Windows-side pnpm panics on `\\wsl.localhost\` UNC paths). The
  `@karpatkey/design-system` git dep needs an ssh-agent with your key loaded — run
  `ssh-add ~/.ssh/id_ed25519` once per WSL shell before `pnpm install`.
- `.env` at repo root with `MAINNET_URL`, `OP_URL`, `GNOSIS_URL`, `ARBITRUM_URL`, `BASE_URL`.

## Layout

```
script/development/
├── README.md
├── anvil/
│   ├── start-forks.sh      — spawn 5 anvils with --state persistence
│   ├── stop-forks.sh       — SIGTERM each anvil so --state dumps cleanly
│   ├── reset-state.sh      — nuke state files (refuses if anvils still running)
│   └── status-forks.sh     — one-line status per fork (pid, block, NAV proxy)
├── app/
│   └── sync-app-env.sh     — write app/.env.local pointing at the local forks
├── deploy/
│   ├── 01_DeployNAV.s.sol       — fresh NAV impl + proxy + DEFAULT_ADMIN/MANAGER + native feed
│   ├── register-assets.sh       — Chainlink-asset registrar via cast (forge-script alternative hangs)
│   ├── register-custom-assets.sh — custom-feed asset registrar via cast
│   ├── deploy.sh                — orchestrator: 01_DeployNAV then register-assets per chain
│   └── deploy-*.sh / *.s.sol    — per-protocol ad-hoc adapter wiring helpers (forge create / forge script + cast send)
├── config/
│   └── chains.json         — chainId → port + RPC env var + native symbol/feed/heartbeat + sequencer feed
├── state/                  — anvil state files, PIDs, logs, per-chain deployed addresses (gitignored)
└── test/                   — balance-adapter verification evidence packs (one folder per protocol)
```

Anything else (custom price feeds, balance adapters) is **driven by the prod scripts** under
`script/deploy/`. The dev tree intentionally doesn't duplicate them.

## Daily loop

```bash
bash script/development/anvil/start-forks.sh    # spawn anvils, resuming state if present
bash script/development/deploy/deploy.sh        # 01_DeployNAV + register-assets per chain
bash script/development/app/sync-app-env.sh     # rewrite app/.env.local
( cd app && pnpm dev )                          # or restart your existing dev server
bash script/development/anvil/status-forks.sh   # one-line status per chain
```

`start-forks.sh` and `deploy.sh` take optional chain-id args to restrict to a subset — e.g.
`start-forks.sh 1` then `deploy.sh 1` bring up mainnet only. With no args they process every chain
in `config/chains.json`. Useful when the protocol under verification only lives on one chain.

When you're done for the session:

```bash
bash script/development/anvil/stop-forks.sh     # SIGTERM each anvil so --state dumps cleanly
```

Next session, `start-forks.sh` loads each state file back and the deployed contracts come with it.
Total resume time is seconds, not the ~15 min of a fresh deploy.

## When to reset

If you've changed any contract that gets deployed by `deploy.sh` (e.g. NAVCalculator interface or
storage layout), the cached state is stale:

```bash
bash script/development/anvil/stop-forks.sh
bash script/development/anvil/reset-state.sh
bash script/development/anvil/start-forks.sh
bash script/development/deploy/deploy.sh
bash script/development/app/sync-app-env.sh
```

`reset-state.sh` refuses to run while any anvil is still up — call `stop-forks.sh` first.

You do **not** need to reset to add a new balance adapter or register more assets — those are just
new transactions sent to the running anvils.

## Adding a new balance adapter to the local forks

The verification workstream under `script/development/test/<protocol>/` cherry-picks one holder per
protocol, pins a block, and ships a strict-equality fork test. To make the dashboard surface those
positions for visual cross-check vs Debank, you also need the adapter deployed + registered on the
local anvil:

1. **Pre-verification (per-protocol ad-hoc):** small bash deploy script under
   `script/development/deploy/deploy-<protocol>.sh` that does `forge create` + `cast send addBalanceAdapters(address[])`
   (plain adapter) or `cast send addMetaBalanceAdapter(address,bytes32[])` (meta adapter) per adapter instance. See
   `script/development/deploy/deploy-lido-withdrawal-queue.sh` (plain) and
   `script/development/deploy/deploy-aave-instances-meta.sh` (meta) for canonical examples.
2. **Post-verification:** the adapter is appended to `script/deploy/04_DeployBalanceAdapters.s.sol`
   and its config goes into `script/config/contracts-deployment-config/balance-adapters/<id>.json`
   (plain) or `meta-balance-adapters/<id>.json` (meta) for the deploy, plus
   `script/config/nav-config/{balance-adapters,meta-balance-adapters}/<id>.json` for NAV
   registration. The ad-hoc dev script is then deleted; dev anvil deploys go through the same prod
   script with `--rpc-url http://127.0.0.1:<port>`.

This convention keeps the dev-anvil tooling tiny: once an adapter is verified, prod's 04 is the
single source of truth for "what's deployed".

## Fork block is frozen — implications

Each anvil pins its fork at the **latest block at the moment `start-forks.sh` ran**. After that:

- Chainlink prices read by NAV are frozen at that block.
- Account balances are frozen at that block, unless you send transactions locally to anvil.
- The dashboard's auto-refresh just re-reads the same static values.

Live cross-check against Debank therefore has up to several days of drift, depending on when you
last reset. For verification work, refork at the start of each session to minimise that drift.

## Per-chain NAV addresses

In production, NAV is at the same address (`0x0793…EB19`) on every chain via CREATE2. On dev
forks we use plain `CREATE`, and the deployer EOA's nonce on each forked chain inherits from the
live chain (different per chain), so the resulting proxy address differs per chain.

The app handles this with per-chain env-var overrides written by `app/sync-app-env.sh`:

```
NEXT_PUBLIC_NAV_ADDRESS_1=...
NEXT_PUBLIC_NAV_ADDRESS_10=...
NEXT_PUBLIC_NAV_ADDRESS_100=...
NEXT_PUBLIC_NAV_ADDRESS_42161=...
NEXT_PUBLIC_NAV_ADDRESS_8453=...
```

`app/src/config/chains.ts` reads these into a per-chain `navAddress` and the wagmi hooks use
`chain.navAddress` instead of a global constant.

## Port and feed mapping

| Chain | ID | Port | Native | Native Chainlink feed | Sequencer feed |
|---|---|---|---|---|---|
| Ethereum | 1 | 8545 | ETH | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | — |
| Optimism | 10 | 8546 | ETH | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` | `0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389` |
| Gnosis   | 100 | 8547 | xDAI | `0x678df3415fc31947dA4324eC63212874be5a82f8` | — |
| Arbitrum | 42161 | 8548 | ETH | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` | `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` |
| Base     | 8453 | 8549 | ETH | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |

Edit `config/chains.json` if any of these changes (rare).

## Deployer EOA

Every dev deploy uses anvil's prefunded account #0:

- address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- private key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

The dev `01_DeployNAV.s.sol` grants this EOA `DEFAULT_ADMIN_ROLE` (via initialize) and `MANAGER`
(via explicit `grantRole`), so one key can deploy + register assets + manage balance adapters. No Safe
handoff in dev (that's prod's `07_TransferAdminToSecurityCouncil.s.sol`, which dev skips).

To call admin-only functions from `cast` use `--private-key` with the value above.

## Useful cast cheats

```bash
# Source of truth per chain
cat script/development/state/1-addresses.json

# Block tip
cast block-number --rpc-url http://127.0.0.1:8545

# All registered balance adapters
cast call <NAV> "getAllAdapters()(address[])" --rpc-url http://127.0.0.1:8545

# NAV positions for an account
cast call <NAV> "getAccountPositions(address,address)" <account> 0x0000000000000000000000000000000000000000 --rpc-url http://127.0.0.1:8545

# Advance time / mine blocks (e.g. to age a Chainlink update)
cast rpc anvil_setNextBlockTimestamp <unix> --rpc-url http://127.0.0.1:8545
cast rpc anvil_mine 0x1 --rpc-url http://127.0.0.1:8545

# Impersonate a Safe / treasury account
cast rpc anvil_impersonateAccount <addr> --rpc-url http://127.0.0.1:8545
```

## forge-script hang gotcha (important)

`forge script ... --broadcast` against anvil's `--fork-url` hangs (or runs >5 min) whenever the
simulation phase issues many cross-contract calls. We hit this on the original
`02_RegisterAssets.s.sol` (deleted; superseded by `register-assets.sh`) and on the original
`03_DeployCustomFeeds.s.sol` (deleted; use prod's `script/deploy/03_DeployPriceFeeds.s.sol`
instead — it's structured differently and works against anvil).

**Workaround for transaction batches**: use bash + `cast send` directly. `register-assets.sh` is
the canonical pattern.

**Workaround for contract deployments**: use `forge create` per contract. Each is a single CREATE
tx, no batch simulation.

## What ships in each phase

- **Phase 1 — NAV bootstrap.** `01_DeployNAV.s.sol`. NAV impl + proxy + admin/manager + native
  feed. Done.
- **Phase 2 — asset registration.** `register-assets.sh`. Chainlink-priced assets, per chain.
  Done. (Custom feeds + per-protocol adapters are now driven via prod's `script/deploy/03` and
  `script/deploy/04` directly, no longer duplicated under `development/`.)
- **Phase 3 — verification.** One protocol at a time under `test/<protocol>/`. Strict-equality
  fork test + dev-anvil visual cross-check vs Debank. See `test/README.md` for the methodology.
