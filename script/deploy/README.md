# Deploy Scripts

Everything is deployed and configured by a single **deployer EOA** (private key + `--broadcast`). No Safe executes any deploy/config transaction. The deployer EOA holds `DEFAULT_ADMIN_ROLE` + `MANAGER` throughout, and the **final role-handoff** step (`07`) hands `DEFAULT_ADMIN_ROLE` + `MANAGER` to the **security-council Safe** and renounces the deployer's roles. The council Safe is the end-state governance admin (future upgrades go through it via `script/upgrade/*`, which still emit Safe-TX batches).

Deployment order (per chain unless noted):

**01** (implementations, once across chains) → **02** (proxies + init) → **03** (price feeds; asset registration is a separate `script/manage/RegisterAssets.s.sol` step) → **04** (balance adapters) → **05** (bridge adapters, CREATE2 same-address) → **06** (configure: register balance + meta-adapters, reconcile meta-instances, authorize bridge adapters + wire `trustedRemoteAdapter`) → **07** (transfer admin to the security council — last of the role handoff) → **08** (asset-kind registry; see below — **order-independent**, run it any time after the assets config carries the kind fields).

`07` is the last step that touches the NAV/Bridge **proxies**, and it is still what ends the deployer's control over them. It is no longer the last script in the directory: `08` deploys its own standalone contract with its own roles and is not coupled to `07` in either direction. Run `08` before or after `07` — but do not skip it, or the `AssetKindRegistry` simply does not exist on that chain and nothing in the pipeline says so.

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

Deploys the external libraries (`PriceFeedLib`, `NAVRegistryLib`) then the `NAVCalculator` (and `BridgeEscrow`) implementations via the canonical CREATE2 deployer — same deterministic addresses on every chain, so run **once**. The libraries are deployed before `NAVCalculator` because its bytecode DELEGATECALLs them at the foundry.toml-pinned addresses (confirm `01`'s logged library addresses match the `foundry.toml` pins before deploying — see the note in `01_2`).

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

## 04_DeployBalanceAdapters.s.sol

Deploys the per-protocol balance adapters (incl. the meta-adapters) via plain `new ...` (CREATE) from the deployer EOA, logging their addresses (persisted to the deployments file `script/config/deployments/{chainId}.json`). Balance-adapter addresses are therefore chain- and run-specific.

## 05_DeployBridgeAdapters.s.sol (CREATE2 same-address, ADR 0012 D7)

Deploys the six bridge adapters (CCIP, Across, Stargate, Gnosis, CCTP, Superchain) via the **canonical CREATE2 deployer** (`0x4e59…4956C`), so each adapter's address is **identical on every chain**. Adapters take their args through `initialize(...)` rather than constructor args, so their creation bytecode carries no per-chain data and the pinned salt (from `DeploySalts`) yields the same address everywhere. After each CREATE2 deploy the script **asserts** the on-chain address equals the predicted deterministic address and **reverts** otherwise (this is the D7 same-address guarantee that `trustedRemoteAdapter`, the CCTP `mintRecipient`/`destinationCaller`, and the Superchain `receiver` rely on). The flow stays EOA-broadcast and idempotent (a re-run skips an adapter that already has code at its deterministic address). Each enabled adapter is gated by config `enabled`; addresses are written under `bridgeAdapters.<Name>` in the deployments file `script/config/deployments/{chainId}.json` (this write goes through `ConfigReader.writeAdapterAddress` and happens on every run, unlike the impl/proxy address writes that `PERSIST_DEPLOYMENTS` gates — see the persistence note at the bottom of this README).

## 06_Configure.s.sol (EOA broadcast)

Run by the deployer EOA (holds admin + MANAGER). It is config-driven and idempotent (skips already-registered/authorized via `isAdapterRegistered` / `isAuthorizedAdapter`), so it can be re-run safely:

- **Plain balance adapters** (from `nav-config/balance-adapters/<chainId>.json`): registered with `addBalanceAdapters([adapter])`.
- **Meta-adapters** (ADR 0010, from `nav-config/meta-balance-adapters/<chainId>.json`): registered atomically with `addMetaBalanceAdapter(adapter, instances)` (register + seed the configured instance set in one call), then the on-chain instance set is reconciled against config via `addMetaInstances`/`removeMetaInstances` (diff-only, so a just-seeded adapter is a no-op). The instance set is `instances` addresses (widened to `bytes32`) and/or `instancesRaw` bytes32 coordinates.
- **Bridge adapters:** each enabled + deployed adapter is authorized on `BridgeEscrow` via `authorizeAdapter(address)`. (ADR 0012 D1 removed the escrow fallback dispatcher, so `authorizeAdapterWithCallback` no longer exists — the legacy `callbackSelector` config field is obsolete and ignored.) Then, for each remote chain id in the adapter's `remoteChains` config, the script wires its trusted sibling via `setTrustedRemoteAdapter(remoteChainId, bytes32(uint256(uint160(adapter))))` (ADR 0012 D2 + D7). The `sourceKey` is the remote **standard chain id** for every adapter — each adapter translates protocol-specific source identifiers (CCIP selector, LayerZero eid, CCTP domain, AMB/OP xDomain sender) back to the standard chain id internally before the lookup. The `remote` value is the adapter's own CREATE2 address, since the sibling on every remote chain shares it.
- **Bridge accounts + assets** (from `contracts-deployment-config/bridge-escrow/<chainId>.json`): each address in `.accounts` is authorized on `BridgeEscrow` via `authorizeAccount(address)` (DEFAULT_ADMIN_ROLE), and each `.assets` entry (logical bridge symbol → local token address) is registered via `registerAsset(string,address)` (MANAGER_ROLE). Both are **required** for a functioning deposit path — `02` initializes the escrow with an empty account set and no registered assets, so without this step `depositAndBridge` reverts (`NotAuthorized`, then the symbol lookup fails). Idempotent: skips accounts already authorized and assets already mapped to the same address. Must run before `07` (while the deployer holds both roles). The symbol is part of the cross-chain invoice identity, so both ends of a lane must register the **same** logical symbol mapped to each chain's local token. `.accounts` is filled per deployment — the deployer EOA for a smoke test, the fund Safes for production.

```bash
forge script script/deploy/06_Configure.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

## 07_TransferAdminToSecurityCouncil.s.sol (last of the role handoff)

Grants `DEFAULT_ADMIN_ROLE` + `MANAGER` to `addresses.securityCouncil` on both proxies (`NAVCalculator`, `BridgeEscrow`), revokes `MANAGER` from the deployer, and renounces the deployer's `DEFAULT_ADMIN_ROLE`.

It also hands off **each deployed bridge adapter** (CCIP, Across, Stargate, Gnosis, CCTP, Superchain — `AccessControl` contracts, not proxies; addresses read from `deployments/<chainId>.json` under `bridgeAdapters`, skipping any not deployed). Per [ADR 0012](../../docs/decisions/0012-bridge-provable-release-rearchitecture.md) (M1/AC-6) the deployer EOA must not retain ADMIN/MANAGER on the adapters: for each, the council is granted `DEFAULT_ADMIN_ROLE` + `MANAGER`, the deployer's `MANAGER` is revoked, and the deployer's `DEFAULT_ADMIN_ROLE` is renounced. The council's adapter `MANAGER` is what subsequently gates `completeBridge` / `recoverStuckAssets` (and, on Superchain, `proveWithdrawal` / `finalizeWithdrawal`); admin gates `setTrustedRemoteAdapter`.

After this the council Safe is the sole admin/manager on the proxies **and** the adapters, and the deployer holds nothing.

```bash
DEPLOYER_EOA=0xYourDeployer \
forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

## 08_DeployAssetKindRegistry.s.sol (order-independent)

Deploys the per-chain `AssetKindRegistry` and classifies every asset in `nav-config/assets-and-price-feeds/<chainId>.json` on the two-axis taxonomy — `PegKind { Pegged, Floating }` × `AccrualKind { None, Rebasing, Appreciating }`.

**Not coupled to `07`, in either direction.** It deploys a standalone contract with its own roles and never touches the NAV/Bridge proxies, so it can run before or after the council handoff. It is listed last only because it was added last.

**A pin regeneration IS owed for this feature, though not by this script.** `AssetKindRegistry`'s presence under `src/` tipped the `via_ir` whole-program stack margin and forced an extraction in `PriceFeedLib`, moving its pin `0xfc6AE534…` → `0x49C18627665562F4bEbae5208BA6eF7428039614`. `NAVRegistryLib` is unchanged. Do not conclude from "08 touches neither library" that nothing needs repinning.

**Fail-closed: it aborts unless EVERY configured asset carries a valid `pegKind` and `accrualKind` string.** Absent or unrecognized values are not defaulted, not skipped and not warned about — a default classification is indistinguishable from a real one once it is on-chain, so the only safe place to notice the gap is before the transaction. A revert here is the guard working. Values are strings rather than integers so a stale integer cannot silently re-map if an enum ever gains a member.

**Idempotent.** Re-running re-classifies the existing registry instead of deploying a second one, so it composes with the "re-run the numbered sequence" pattern like every other step.

**Run it with `PERSIST_DEPLOYMENTS=1`.** The idempotency above depends on the deployment record, and `saveDeployedAddress` only writes that record when the flag is set. A real `--broadcast` *without* it deploys a live registry and records nothing, so the next run deploys a second one. There is no fallback address to probe — and note the reason is the gated WRITER, not CREATE vs CREATE2: `04`'s adapters also use plain `new` behind a record lookup, but record through the ungated `writeAdapterAddress`, whereas `08` (like `04`'s three assistants) records through the gated `saveDeployedAddress`.

```bash
PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/08_DeployAssetKindRegistry.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

### The registry is EOA-owned for now, by design — with a handover to come

**Deliberate for this deploy, not an oversight, and not something to "fix" by extending `07` or adding an `09`.** `DEFAULT_ADMIN_ROLE` and `MANAGER` both go to the deployer EOA. Every chain config sets `addresses.admin` and `addresses.manager` to that same EOA, so one key governs the registry on each chain, and `07_TransferAdminToSecurityCouncil` intentionally does not enumerate this contract.

**Expect to hand it over later.** The transfer to the security-council Safe is planned, riding with the same deferred step-07 Safe-handoff work that was excluded from this wave — the registry is in the same position as the NAV and Bridge proxies, not in a special one. It is a known, planned follow-on rather than a permanent posture.

Until it happens: that one key can re-classify any asset, and the only signal is the `AssetKindSet` event. Nothing consumes the registry today; watch that event once something does.

### Handing the registry to the council (planned, manual)

This is a step **you should expect to perform**, not an optional aside. It is a manual operational action taken after the deploy, outside any script — deliberately not automated, so it does not ride the numbered pipeline. Two council transactions from the deployer EOA, a verification, then two renouncements, mirroring what `07` does for the proxies:

```bash
RPC=$YOUR_MAINNET_RPC_URL                # cast defaults to localhost:8545 - always pass this
DEPLOYER_EOA=0xYourDeployer               # the EOA that ran 08; needed for the renounce calls
REGISTRY=$(jq -r '.AssetKindRegistry' script/config/deployments/1.json)
COUNCIL=$(jq -r '.addresses.securityCouncil' script/config/chains/1.json)
MANAGER_ROLE=$(cast keccak "MANAGER")     # DEFAULT_ADMIN_ROLE is 0x00…0

# 1. grant both roles to the council
cast send $REGISTRY "grantRole(bytes32,address)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 $COUNCIL \
  --rpc-url $RPC --account $DEPLOYER_NAME
cast send $REGISTRY "grantRole(bytes32,address)" $MANAGER_ROLE $COUNCIL \
  --rpc-url $RPC --account $DEPLOYER_NAME

# 2. verify BEFORE renouncing — a renounce with no council admin freezes the registry permanently
cast call $REGISTRY "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 $COUNCIL --rpc-url $RPC
cast call $REGISTRY "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $COUNCIL --rpc-url $RPC

# 3. only then drop the deployer's own roles
cast send $REGISTRY "renounceRole(bytes32,address)" $MANAGER_ROLE $DEPLOYER_EOA \
  --rpc-url $RPC --account $DEPLOYER_NAME
cast send $REGISTRY "renounceRole(bytes32,address)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 $DEPLOYER_EOA \
  --rpc-url $RPC --account $DEPLOYER_NAME
```

Step 2 is not optional. `AssetKindRegistry` is stock OZ `AccessControl` with no renounce restriction, so renouncing the last `DEFAULT_ADMIN_ROLE` before the council holds it leaves **no role admin at all**: the classification map keeps answering reads forever and can never be changed again. Because admin and manager are the same key, one misordered renounce loses both axes at once.

> Note: `PERSIST_DEPLOYMENTS=1` gates the top-level impl/proxy address writes (`saveDeployedAddress` in 01/01_2/02/02_2 **and 08**) to the deployments file `script/config/deployments/{chainId}.json` — without it those only log. The per-adapter writes in 04 (`balanceAdapters.<Name>`) and 05 (`bridgeAdapters.<Name>`) go through `ConfigReader.writeAdapterAddress` and are NOT gated by this flag — they write on every run. **Careful: that exemption does not cover all of 04.** 04's three *assistants* (`NexusMutualStakingPoolsAssistant`, `EtherFiWithdrawalQueueAssistant`, `StakeWiseV3ExitQueueAssistant`) are top-level keys written through the **gated** `saveDeployedAddress`, and their skip-if-deployed guards read those same records — so running 04 without the flag records no assistants and a re-run deploys duplicates. Run 04 with `PERSIST_DEPLOYMENTS=1` too. Governance after handoff (upgrades) is council-Safe-driven via `script/upgrade/*`, which still produce Safe-TX JSON batches.
