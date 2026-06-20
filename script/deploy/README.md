# Deploy Scripts

Everything is deployed and configured by a single **deployer EOA** (private key + `--broadcast`). No Safe executes any deploy/config transaction. The deployer EOA holds `DEFAULT_ADMIN_ROLE` + `MANAGER` throughout, and the **final** step (`07`) hands `DEFAULT_ADMIN_ROLE` + `MANAGER` to the **security-council Safe** and renounces the deployer's roles. The council Safe is the end-state governance admin (future upgrades go through it via `script/upgrade/*`, which still emit Safe-TX batches).

Deployment order (per chain unless noted):

**01** (implementations, once across chains) → **02** (proxies + init) → **03** (price feeds + asset registration) → **04** (balance adapters) → **05** (bridge adapters) → **06** (configure: register balance + meta-adapters, reconcile meta-instances, authorize bridge adapters) → **07** (transfer admin to the security council, last).

## Role model

- `addresses.admin` and `addresses.manager` in `script/config/chains/{chainId}.json` must be set to the **deployer EOA** before deploying — the atomic proxy deployer (02) grants both roles to those addresses, so the deployer can run 03–06.
- `addresses.securityCouncil` is the **end-state admin** (the council Safe). It receives `DEFAULT_ADMIN_ROLE` + `MANAGER` in step 07; the deployer renounces afterward.

## RPC and environment

- Chain config uses `"rpc": "$ALCHEMY"` in `script/config/chains/{chainId}.json`, resolved by **ConfigReader** from **ALCHEMY_API_KEY**. Run without `--rpc-url` if it is set; otherwise pass `--rpc-url` explicitly.
- All commands broadcast from the deployer key: `--account $DEPLOYER_NAME` (a `cast wallet` account) or `--private-key $PK`.

```bash
# RPC taken from config ($ALCHEMY → ALCHEMY_API_KEY)
forge script script/deploy/02_DeployProxies.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
# or explicit RPC
forge script script/deploy/02_DeployProxies.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

---

## 01_DeployImplementations.s.sol (and 01_2 for NAV only)

Deploys the external libraries (`PriceFeedLib`, `NavRegistryLib`) then the `NAVCalculator` (and `BridgeEscrow`) implementations via the canonical CREATE2 deployer — same deterministic addresses on every chain, so run **once**. The libraries are deployed before `NAVCalculator` because its bytecode DELEGATECALLs them at the foundry.toml-pinned addresses (confirm `01`'s logged library addresses match the `foundry.toml` pins before deploying — see the note in `01_2`).

```bash
forge script script/deploy/01_DeployImplementations.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

## 02_DeployProxies.s.sol (02_2 for NAV only)

Deploys the `NAVCalculator` + `BridgeEscrow` **proxies** and **initializes** them in one atomic CREATE2 transaction via **AtomicProxyDeployer**, so proxy addresses are deterministic across chains. Proxy bytecode uses a chain-independent placeholder impl (CREATE2, same address everywhere), then `upgradeToAndCall` sets the real impl + runs `initialize(...)`. The atomic deployer grants `DEFAULT_ADMIN_ROLE` to `admin` and `MANAGER` to `manager` (both = the deployer EOA), then renounces its own admin.

- **Prerequisites:** 01 done; chain config (`script/config/chains/{chainId}.json`) has `addresses.{admin,manager,securityCouncil}`, and the deployments file (`script/config/deployments/{chainId}.json`) has `NAVCalculatorImplementation` + `BridgeEscrowImplementation` (written by 01).
- `USE_LEGACY_DEPLOY=1` switches to the legacy multi-tx path (does not grant MANAGER — grant it afterward from the admin).

```bash
forge script script/deploy/02_DeployProxies.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

## 03_DeployPriceFeeds.s.sol + asset registration

Deploys the custom price-feed adapter contracts only (chain-branched, enabled per `contracts-deployment-config/custom-price-feeds/<chainId>.json`). It does **not** register assets/feeds on `NAVCalculator` — that is a separate EOA step run by the deployer-as-MANAGER via `script/manage/RegisterAssets.s.sol` (first feed per asset through `registerAsset`, any additional feeds through `addPriceFeed`).

## 04_DeployBalanceAdapters.s.sol / 05_DeployBridgeAdapters.s.sol

Deploy the per-protocol balance adapters (incl. the meta-adapters) and bridge adapters via plain `new ...` (CREATE) from the deployer EOA, logging their addresses (persisted to the deployments file `script/config/deployments/{chainId}.json` only when `PERSIST_DEPLOYMENTS=1`; see the note below). (Addresses are therefore chain- and run-specific — only the impl/library layer in `01`/`02` uses CREATE2.)

## 06_Configure.s.sol (EOA broadcast)

Run by the deployer EOA (holds admin + MANAGER). It is config-driven and idempotent (skips already-registered/authorized via `isAdapterRegistered` / `isAuthorizedAdapter`), so it can be re-run safely:

- **Plain balance adapters** (from `nav-config/balance-adapters/<chainId>.json`): registered with `addBalanceAdapters([adapter])`.
- **Meta-adapters** (ADR 0010, from `nav-config/meta-balance-adapters/<chainId>.json`): registered atomically with `addMetaBalanceAdapter(adapter, instances)` (register + seed the configured instance set in one call), then the on-chain instance set is reconciled against config via `addMetaInstances`/`removeMetaInstances` (diff-only, so a just-seeded adapter is a no-op). The instance set is `instances` addresses (widened to `bytes32`) and/or `instancesRaw` bytes32 coordinates.
- **Bridge adapters:** each enabled + deployed adapter is authorized on `BridgeEscrow` (`authorizeAdapter`, or `authorizeAdapterWithCallback` when a callback selector is configured).

```bash
forge script script/deploy/06_Configure.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

## 07_TransferAdminToSecurityCouncil.s.sol (run LAST)

Grants `DEFAULT_ADMIN_ROLE` + `MANAGER` to `addresses.securityCouncil` on both proxies, revokes `MANAGER` from the deployer, and renounces the deployer's `DEFAULT_ADMIN_ROLE`. After this the council Safe is the sole admin/manager and the deployer holds nothing.

```bash
DEPLOYER_EOA=0xYourDeployer \
forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

> Note: `PERSIST_DEPLOYMENTS=1` makes the scripts persist newly deployed addresses to the deployments file `script/config/deployments/{chainId}.json` (otherwise they only log). Governance after handoff (upgrades) is council-Safe-driven via `script/upgrade/*`, which still produce Safe-TX JSON batches.
