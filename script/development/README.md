# Development infra (anvil + fresh NAV)

Spin up five anvil forks (Ethereum, Optimism, Gnosis, Arbitrum, Base), deploy a fresh NAV v2 proxy
on each, point the Next.js dashboard at them. State persists between sessions via anvil's
`--state` flag, so you only redeploy when you choose to (after an interface change, say).

## Why

- No gas, no real-world side effects.
- Free to break/replace the NAV interface and balance-oracle interfaces between iterations
  (typed-identity-v2, etc.) without touching production.
- Persistent state means you pay the slow first-fork cost once, then resume in seconds.

## Prereqs

- `anvil` and `forge` on PATH (Foundry).
- `jq`.
- `app/` dependencies installed (one-time `pnpm install` inside `app/`). On Windows/WSL, install
  node natively in WSL (the Windows-side pnpm panics on `\\wsl.localhost\` UNC paths). The
  `@karpatkey/design-system` git dep needs an ssh-agent with your key loaded — run
  `ssh-add ~/.ssh/id_ed25519` once per WSL shell before `pnpm install`.
- `.env` at repo root with `MAINNET_URL`, `OP_URL`, `GNOSIS_URL`, `ARBITRUM_URL`, `BASE_URL`.

## Daily loop

```bash
script/development/start-forks.sh   # spawn anvils, resuming state if present
script/development/deploy.sh        # idempotent — runs only what's missing
script/development/sync-app-env.sh  # rewrite app/.env.local
( cd app && pnpm dev )              # or restart your existing dev server
script/development/status-forks.sh  # one-line status per chain
```

When you're done for the session:

```bash
script/development/stop-forks.sh    # SIGTERM each anvil so --state dumps cleanly
```

Next session, `start-forks.sh` loads each state file back and the deployed contracts come with it.
Total resume time is seconds, not the ~15 min of a fresh deploy.

## When to reset

If you've changed any contract that gets deployed by `deploy.sh` (e.g. NAVCalculator interface or
storage layout), the cached state is stale:

```bash
script/development/stop-forks.sh
script/development/reset-state.sh
script/development/start-forks.sh
script/development/deploy.sh
script/development/sync-app-env.sh
```

`reset-state.sh` refuses to run while any anvil is still up — call `stop-forks.sh` first.

You do **not** need to reset to add a new balance oracle or register more assets — those are just
new transactions sent to the running anvils.

## Adding a new balance oracle (incremental loop)

The whole point of this infra is to grow oracle coverage one protocol at a time and verify each
one against a known KPK account / Debank.

1. Implement the new adapter under `src/balances/protocols/<NewAdapter>.sol`.
2. Add a numbered dev script that deploys it and registers it with NAV. E.g.
   `script/development/03_DeployAaveV3Mainnet.s.sol` that does:
   ```solidity
   AaveV3Adapter a = new AaveV3Adapter(...);
   nav.addBalanceOracle(address(a));
   nav.registerAsset(USDC, USDC_FEED, PriceType.Chainlink, 86400);  // any needed assets
   ```
3. Wire it into `deploy.sh` so it runs idempotently per chain.
4. `bash script/development/deploy.sh` — fast (seconds per chain, no fork refetch).
5. Reload the dashboard with the KPK account you're targeting; cross-check the row against Debank.

No state reset needed. Forks stay at the same block; the new oracle just gets registered into the
already-deployed NAV.

## Fork block is frozen — implications

Each anvil pins its fork at the **latest block at the moment `start-forks.sh` ran**. After that:

- Chainlink prices read by NAV are frozen at that block.
- KPK account balances are frozen at that block, unless you send transactions locally to anvil.
- The dashboard's auto-refresh just re-reads the same static values.

Live cross-check against Debank therefore has up to several days of drift, depending on when you
last reset. For most "does this oracle correctly value this position" work that's fine. If you
need fresher state, do a full reset + fresh fork (the 15-min cost).

## Per-chain NAV addresses

In production, NAV is at the same address (`0x0793…EB19`) on every chain via CREATE2. On dev
forks we use plain `CREATE`, and the deployer EOA's nonce on each forked chain inherits from the
live chain (different per chain), so the resulting proxy address differs per chain.

The app handles this with per-chain env-var overrides written by `sync-app-env.sh`:

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

## Deployer EOA and roles

Every dev deploy uses anvil's prefunded account #0:

- address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- private key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

The deploy script grants this EOA `DEFAULT_ADMIN_ROLE` (via initialize) and `MANAGER` (via
explicit `grantRole`), so one key can deploy + register assets + manage oracles.

To call admin-only functions from `cast` use `--private-key` with the value above.

## Useful cast cheats

```bash
# Source of truth per chain
cat script/development/state/1-addresses.json

# Block tip
cast block-number --rpc-url http://127.0.0.1:8545

# Registered assets on a fork's NAV
cast call <NAV> "getRegisteredAssets()((address,string,uint8)[])" --rpc-url http://127.0.0.1:8545

# NAV for an account on a chain
cast call <NAV> "getAccountNav(address,address)" <account> 0x0000000000000000000000000000000000000000 --rpc-url http://127.0.0.1:8545

# Default-oracle address (auto-deployed inside initialize)
cast call <NAV> "erc20DefaultOracle()(address)" --rpc-url http://127.0.0.1:8545

# Advance time / mine blocks (e.g. to age a Chainlink update)
cast rpc anvil_setNextBlockTimestamp <unix> --rpc-url http://127.0.0.1:8545
cast rpc anvil_mine 0x1 --rpc-url http://127.0.0.1:8545

# Impersonate a Safe / treasury account
cast rpc anvil_impersonateAccount <addr> --rpc-url http://127.0.0.1:8545
```

## Layout

```
script/development/
├── README.md                       — this file
├── config/chains.json              — chain id → port + RPC env var + native symbol + sequencer feed + native Chainlink feed
├── state/                          — anvil state files, PIDs, logs, per-chain deployed addresses (gitignored)
├── start-forks.sh                  — spawn 5 anvils with --state persistence
├── stop-forks.sh                   — SIGTERM each anvil so --state dumps cleanly
├── reset-state.sh                  — nuke state files (refuses if anvils still running)
├── status-forks.sh                 — one-line status per fork (pid, block, NAV proxy)
├── deploy.sh                       — runs 01_DeployNAV (and 02 if you uncomment); idempotent per chain
├── sync-app-env.sh                 — writes app/.env.local pointing at the local forks
├── 01_DeployNAV.s.sol              — fresh NAV impl + proxy + DEFAULT_ADMIN/MANAGER grant + native feed wiring
├── 02_RegisterAssets.s.sol         — Forge version of asset registration (Chainlink-only) — DON'T RUN, hangs
├── 03_DeployCustomFeeds.s.sol      — Forge version of custom-feed deploys — DON'T RUN, hangs
├── register-assets.sh              — Working Chainlink-asset registrar (bash + cast send)
└── deploy-custom-feeds.sh          — Working Custom-feed deploy + register (bash + forge create + cast send)
```

## What's deployed today (Phase 1 + Phase 2a)

Per chain, `01_DeployNAV.s.sol` produces:

- NAVCalculator implementation
- ERC1967 proxy → initialized with `(admin=deployer, sequencerFeed, nativeSymbol)`
- ERC20DefaultOracle (auto-deployed inside `NAVCalculator.initialize`, tracks wallet balances for
  every asset registered with NAV)
- Native asset registered (by `initialize`) + native Chainlink price feed wired (by the dev script)

`register-assets.sh` then registers every Chainlink-priced asset from `script/config/assets.json`,
and `deploy-custom-feeds.sh` deploys + registers each Custom-priced asset's oracle. Final
per-chain count today:

| Chain    | Total registered | of which Custom |
|----------|-----------------:|----------------:|
| Mainnet  | 29 | 11 |
| Optimism | 6  | 0  (production uses Chainlink only) |
| Gnosis   | 7  | 2  |
| Arbitrum | 11 | 5  |
| Base     | 9  | 3  |

That's the full prod-equivalent asset set visible in the dashboard's wallet view (ETH, WETH,
USDC, USDT, DAI, USDS, sUSDS, GHO, COMP, MORPHO, RLUSD, USDe, crvUSD, WBTC, AAVE, BAL, RPL, stETH,
CRV, CVX, wstETH, eETH, weETH, rETH, ETH+, ezETH, rsETH, ETHx, sUSDe, syrupUSDC on mainnet; the
L2 variants on Arb/Base; xDAI/sXDAI/wstETH_L2 on Gnosis). What's NOT yet covered is protocol
positions (Aave V3 supply, Morpho vault shares, etc.) — that's Phase 3.

## forge script hang gotcha (important)

`forge script ... --broadcast` against anvil's `--fork-url` hangs (or runs >5 min) whenever the
simulation phase issues many cross-contract calls. We hit this on both `02_RegisterAssets.s.sol`
(many `registerAsset` calls × `decimals()`/`symbol()`/`supportsInterface()`/`latestRoundData()`)
and `03_DeployCustomFeeds.s.sol` (many oracle constructors each fetching dependent contracts).

**Workaround for transaction batches**: use bash + `cast send` directly. `register-assets.sh`
is the working example — runs the full 5-chain Chainlink set in ~2 min. No simulation overhead.

**Workaround for contract deployments**: use `forge create` per contract, one at a time. Each
`forge create` is a single CREATE tx with no simulation batching. Use it inside a bash wrapper
that captures `Deployed to: 0x...` from stdout.

The `*.s.sol` Forge scripts are kept around for reference + future fast-fork scenarios, but
treat `register-assets.sh` (and the upcoming Phase 2b `cast-create-feeds.sh`) as the canonical
way to apply state.

## Roadmap (next phases)

- **Phase 3 — per-protocol balance adapters**: Aave V3, Morpho, Spark, etc. Driven by
  `config/accounts.json` so we incrementally cover one KPK account at a time, verifying each
  oracle against Debank as we go.
