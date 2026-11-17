# Deploy Scripts

Everything is deployed and configured by a single **deployer EOA** (private key + `--broadcast`). No Safe executes any deploy/config transaction. The deployer EOA holds `DEFAULT_ADMIN_ROLE` + `MANAGER` throughout, and the **final role-handoff** step (`07`) hands `DEFAULT_ADMIN_ROLE` + `MANAGER` to the **security-council Safe** and renounces the deployer's roles. The council Safe is the end-state governance admin (future upgrades go through it via `script/upgrade/*`, which still emit Safe-TX batches). The production NAVs (since PR #338) instead sit behind a `TimelockController`, installed with `11` in place of `07` for the NAV — see the `11` section.

Deployment order (per chain unless noted):

**01** (implementations, once across chains) → **02** (proxies + init) → **03** (price feeds; asset registration is a separate `script/manage/RegisterAssets.s.sol` step) → **04** (balance adapters) → **05** (bridge adapters, CREATE2 same-address) → **06** (configure: register balance + meta-adapters, reconcile meta-instances, authorize bridge adapters + wire `trustedRemoteAdapter`) → **07** (transfer admin to the security council — last of the role handoff; or `11` for the NAV — see the `11` section). **08** (asset-kind registry) is **PRIVILEGED and must run BEFORE 07** — see below; the pipeline is therefore **01 → 02 → 08 → 03 → `RegisterAssets` → 04 → 05 → 06 → 07**. ⚠️ **`08` moved ahead of asset registration:** an asset's primary registration is routed through `AssetKindRegistry.registerAsset` so it is registered, classified and LABELLED atomically, and registration is where labels are first written — so the registry must exist and hold `MANAGER` before `RegisterAssets` runs. (A wrong label is corrected afterwards with `setAssetLabels`; the ordering requirement is about the ATOMIC register+classify, not about labels being unfixable.)

`07` is the last step that touches the NAV/Bridge **proxies**, and it is still what ends the deployer's control over them. It is no longer the last script in the directory: `08` deploys its own standalone contract, but it is **not** order-independent: it grants the registry `MANAGER` on the NAV, which needs `DEFAULT_ADMIN` — a role `07` hands to the council. **`08` must run BEFORE `07`.** Do not skip it either, or the `AssetKindRegistry` does not exist on that chain and nothing in the pipeline says so.

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


> ⚠️ **Run `RegisterAssets.s.sol` under `FOUNDRY_PROFILE=slow` whenever it has real work to do.** On mainnet's 44
> assets the default profile dies with a bare `EvmError: MemoryOOG` that names nothing. Only `profile.slow` lifts
> `memory_limit`/`gas_limit` off forge's 32 MiB default. A re-run with nothing to do plans 0 actions and passes on
> the default profile — which is exactly why this is easy to miss until the one time it matters. **One** planned
> action is already enough to trip it (measured at 1, 2, 4, 8, 12 and 17), because the config scan alone sits just
> under the ceiling; see the script's docstring for the measured cause.

Deploys the custom price-feed adapter contracts only (chain-branched, enabled per `contracts-deployment-config/custom-price-feeds/<chainId>.json`). It does **not** register assets/feeds on `NAVCalculator` — that is a separate EOA step run by the deployer-as-MANAGER via `script/manage/RegisterAssets.s.sol` (first feed per asset through **`AssetKindRegistry.registerAsset`**, which forwards to the NAV and carries the asset's kind and labels; any additional feeds through `addOrModifyPriceFeed` on the NAV directly, so the batch is mixed-target by design).

## 04_DeployBalanceAdapters.s.sol

Deploys the per-protocol balance adapters (incl. the meta-adapters) from the deployer EOA, logging their addresses (persisted to the deployments file `script/config/deployments/{chainId}.json`). Three tiers: adapters whose only constructor argument is the NAV proxy are CREATE2-deployed at one address fleet-wide (`_create2NavOnly`); adapters with one chain-specific protocol argument (`MorphoMarketsMeta`, `UniswapV3PoolsMeta`, `FluidVaultsMeta`, plus `MerklRewards`) are CREATE2-deployed with `_create2WithArgs`, so their address is shared only where the argument is; every other adapter is plain `new` (CREATE), chain- and run-specific.

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

## 07_TransferAdminToSecurityCouncil.s.sol (role handoff to the security council)

Grants `DEFAULT_ADMIN_ROLE` + `MANAGER` to `addresses.securityCouncil` on both proxies (`NAVCalculator`, `BridgeEscrow`), revokes `MANAGER` from the deployer, and renounces the deployer's `DEFAULT_ADMIN_ROLE`.

It also hands off **each deployed bridge adapter** (CCIP, Across, Stargate, Gnosis, CCTP, Superchain — `AccessControl` contracts, not proxies; addresses read from `deployments/<chainId>.json` under `bridgeAdapters`, skipping any not deployed). Per [ADR 0012](../../docs/decisions/0012-bridge-provable-release-rearchitecture.md) (M1/AC-6) the deployer EOA must not retain ADMIN/MANAGER on the adapters: for each, the council is granted `DEFAULT_ADMIN_ROLE` + `MANAGER`, the deployer's `MANAGER` is revoked, and the deployer's `DEFAULT_ADMIN_ROLE` is renounced. The council's adapter `MANAGER` is what subsequently gates `completeBridge` / `recoverStuckAssets` (and, on Superchain, `proveWithdrawal` / `finalizeWithdrawal`); admin gates `setTrustedRemoteAdapter`.

After this the council Safe is the sole admin/manager on the proxies **and** the adapters, and the deployer holds nothing.

```bash
DEPLOYER_EOA=0xYourDeployer \
forge script script/deploy/07_TransferAdminToSecurityCouncil.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

## 08_DeployAssetKindRegistry.s.sol (PRIVILEGED — must run BEFORE 07)

Deploys the per-chain `AssetKindRegistry` and classifies every asset in `nav-config/assets-and-price-feeds/<chainId>.json` on the two-axis taxonomy — `PegKind { Pegged, Floating }` × `AccrualKind { None, Rebasing, Appreciating }`.

**Order-dependent: `08` MUST run before `07`.** It grants the registry `MANAGER` on the NAV, and `grantRole` needs `DEFAULT_ADMIN` — which `07` transfers to the security-council Safe while also revoking the deployer's `MANAGER` (`07:97`). Run it after `07` and both the grant and `setAssetKinds` revert; `08` is EOA-broadcast only, with no Safe path. It is numbered last because it was added last, not because it runs last.

**The pin regeneration this feature owed has been DONE.** Adding `AssetKindRegistry` under `src/` coincided with the `via_ir` whole-program stack margin being reached, prompting an extraction in `PriceFeedLib` that moved its pin. It is now pinned at `0x784bDE7A…`, measured from a cold clean build with every submodule at its recorded revision; `NAVRegistryLib` did not move. The authoritative values live in `foundry.toml` and `LibraryPins.sol`, and `LibraryPinConsistency.t.sol` is what proves they still match the tree — do not take a pin from prose, including this sentence.

**Fail-closed: it aborts unless EVERY configured asset carries a valid `accrualKind` string.** (There is no `pegKind` in config — the peg axis is derived on-chain from the NAV's `pegToleranceBps`.) Absent or unrecognized values are not defaulted, not skipped and not warned about — a default classification is indistinguishable from a real one once it is on-chain, so the only safe place to notice the gap is before the transaction. A revert here is the guard working. Values are strings rather than integers so a stale integer cannot silently re-map if an enum ever gains a member.

**Idempotent.** Re-running re-classifies the existing registry instead of deploying a second one, so it composes with the "re-run the numbered sequence" pattern like every other step.

**Run it with `PERSIST_DEPLOYMENTS=1` — but note the idempotency no longer depends on it.** Since the registry became CREATE2 (2026-08-19), the skip-if-deployed guard probes the **predicted address for code on-chain**, so a re-run without the flag is a no-op rather than a second registry: the address is a pure function of (creation code, NAV, salt), so there is always an address to probe. That closes the old failure mode where a real `--broadcast` without the flag recorded nothing and the next run deployed a duplicate.

The flag is still required, for a different reason: downstream consumers — `09_BackfillAssetLabels`, `verify_step.py 1.4`, the deployment record itself — read the registry address from the record, and `saveDeployedAddress` only writes it when the flag is set. Omit it and the deploy is still correct on-chain, but nothing downstream can find the registry.


```bash
PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/08_DeployAssetKindRegistry.s.sol --chain-id 1 --broadcast --account $DEPLOYER_NAME
```

**Verify the wiring after broadcasting — the exit code will not.** A first run dispatches **four** transactions: deploy, `setAssetKindRegistry(registry)`, `grantRole(MANAGER, registry)`, then `setAssetKinds`. Two of them can fail silently in opposite directions. If the grant fails while `setAssetKinds` succeeds, you get a fully classified registry whose facade is **dead on writes**. If `setAssetKindRegistry` fails, everything looks complete and **every read reverts** — which is the state every deploy was in before that transaction existed, because nothing called it. The script still exits `0` in both cases and nothing inside `08` can detect either. Gate on `python3 script/deploy/preflight/verify_step.py 1.4` rather than on the exit status.

### The registry has no owner — nothing to hand over

`AssetKindRegistry` holds **no roles of its own**: no `AccessControl`, no admin, no manager. Every write gates on `NAV.hasRole(MANAGER, msg.sender)`, so authority is exactly the NAV's MANAGER set — one set of humans for the whole system, and one fewer governance surface to keep in sync.

Consequences worth stating, because earlier revisions of this file said the opposite: there is **no Safe handover owed for this contract** (`07` correctly does not enumerate it, and now there is no reason it should), no admin that can grant itself write access, and no sequence of renouncements that can freeze the classification map.

### Registering an asset: use the registry, not the NAV

`AssetKindRegistry.registerAsset(asset, priceFeed, priceType, chainlinkHeartbeat, accrualKind, labels)` registers on the NAV **and** classifies **and** labels, atomically, in one call — the same arguments you used on the NAV plus two, at a different address. `registerAsset` is where labels are first written; `setAssetKind`/`setAssetKinds` still take none, because classification and labelling are separate axes. **A wrong label is corrected with `setAssetLabels(asset, labels)`** (MANAGER-gated, replaces the set wholesale, reverts on an empty array or an asset the NAV does not hold) — it leaves price feeds, monitor feeds and `_assetPricing` untouched. The old repair, unregister-then-re-register, is no longer needed for a label and is destructive: it drops every feed and both tolerances. `unregisterAsset` still clears labels, so registration and labels share one lifetime. `unregisterAsset(asset)` is symmetric. If either half reverts, neither takes effect.

Calling `NAVCalculator.registerAsset` directly still works and is deliberately not blocked. Whether it *should* is a deploy-time role decision: revoking `MANAGER` from humans on the NAV makes the facade the only path and the "always classified" invariant structural rather than conventional. That choice is left to the operator — the code does not force it, so the registry is not a required dependency for asset registration unless you decide it should be.

> Note: `PERSIST_DEPLOYMENTS=1` gates the top-level impl/proxy address writes (`saveDeployedAddress` in 01/01_2/02/02_2 **and 08**) to the deployments file `script/config/deployments/{chainId}.json` — without it those only log. The per-adapter writes in 04 (`balanceAdapters.<Name>`) and 05 (`bridgeAdapters.<Name>`) go through `ConfigReader.writeAdapterAddress` and are NOT gated by this flag — they write on every run. **Careful: that exemption does not cover all of 04.** 04's three *assistants* (`NexusMutualStakingPoolsAssistant`, `EtherFiWithdrawalQueueAssistant`, `StakeWiseV3ExitQueueAssistant`) are top-level keys written through the **gated** `saveDeployedAddress`, and their skip-if-deployed guards read those same records — so running 04 without the flag records no assistants and a re-run deploys duplicates. Run 04 with `PERSIST_DEPLOYMENTS=1` too. Governance after handoff (upgrades) is council-Safe-driven via `script/upgrade/*`, which still produce Safe-TX JSON batches.

## 11_DeployTimelockController.s.sol (NAV governance)

CREATE2-deploys the NAV's governance `TimelockController` (an EOA broadcast that needs no privileges) and writes a
Safe batch, `safe-transactions/<chainId>-install-timelock.json`, for the security-council Safe. The batch grants the
NAV's `DEFAULT_ADMIN_ROLE` + `MANAGER` to the timelock and revokes them from the deployer EOA and, unless
`SAFE_RETAINS_ROLES=true`, from the Safe itself. It governs the NAV only; it does not touch `BridgeEscrow` or the
bridge adapters.

**It is an alternative to `07` for the NAV, not a step after it.** It needs BOTH the deployer and the Safe to hold
the NAV's `DEFAULT_ADMIN_ROLE` when it runs (it reverts `DeployerNotAdmin` / `BatchExecutorNotAdmin` otherwise),
and `07` renounces the deployer's NAV roles. Conversely, `07` cannot run after `11`'s batch: it requires the
deployer to still hold the NAV's admin role. So there is no scripted bridge-contract handoff on the timelock path;
on a chain with a `BridgeEscrow` proxy or bridge adapters, hand those off separately.

How the live fleet ran it (PR #338): the deployer granted the Council the NAV's roles directly, then ran `11` with
the Council keeping its roles alongside the timelock, after every step that needed deployer privileges:

```bash
for R in 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast keccak MANAGER); do
  cast send $NAV "grantRole(bytes32,address)" $R $COUNCIL --rpc-url $RPC --account $DEPLOYER_NAME
done
DEPLOYER_EOA=$DEPLOYER SAFE_RETAINS_ROLES=true PERSIST_DEPLOYMENTS=1 \
forge script script/deploy/11_DeployTimelockController.s.sol --rpc-url $RPC --account $DEPLOYER_NAME --broadcast --slow
# then the Council signs safe-transactions/<chainId>-install-timelock.json
```

`OPS_SAFE=<address>` revokes a throwaway ops Safe in the same batch, if one was used. `PERSIST_DEPLOYMENTS=1` is
what records the timelock in `script/config/deployments/<chainId>.json`. The default (`SAFE_RETAINS_ROLES` unset)
revokes the Safe's own roles, leaving the timelock as the only path. The mandatory post-execution checks are listed
in the script header.
