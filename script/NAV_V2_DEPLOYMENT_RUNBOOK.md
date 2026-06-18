# NAV v2 Deployment Runbook

> **⚠️ Deployment is now EOA-only.** A single deployer EOA runs every step with `--broadcast`; no Safe executes deploy/config txs. "Path A (Safe-TX bundles)" below is superseded — use the EOA path only. `06_Configure.s.sol` no longer exists (folded into `06_Configure.s.sol`, which now broadcasts `addBalanceAdapters`/`addMetaBalanceAdapter` + `addMetaInstances`/`removeMetaInstances` + bridge authorization directly). The final step is `07_TransferAdminToSecurityCouncil.s.sol`, which hands `DEFAULT_ADMIN_ROLE` + `MANAGER` on **both** the NAV and Bridge proxies to `addresses.securityCouncil` and renounces the deployer's roles. See `script/deploy/README.md` for the authoritative, current procedure.

Step-by-step operational guide for deploying the NAV v2 system — NAVCalculator, BridgeEscrow, price oracles, balance adapters, bridge adapters — to any supported chain. This runbook is the source of truth for every NAV v2 deployment going forward, regardless of which fund (ETH Alpha, USD Alpha, kUSDprime, kREN, or any future fund) the deployment supports.

**Companion docs:**
- [`DEPLOYMENT_SUMMARY.md`](DEPLOYMENT_SUMMARY.md) — architectural overview (CREATE2, atomic proxy deploy, Safe multisig control). Read first if you're new to the system.
- [`docs/historical/adapter-migration-plan.md`](../docs/historical/adapter-migration-plan.md) — historical record of the v1 → v2 adapter migration, plus known follow-up improvements. Read if you want to understand why a particular adapter looks the way it does. Archival; for current ops, use this runbook.

**When you use this runbook:**
1. Deploying NAV v2 to a new chain for the first time.
2. Deploying additional price or balance adapters to an already-live chain.
3. Registering new assets on a live NAVCalculator.
4. Rotating MANAGER/DEFAULT_ADMIN roles.
5. Validating an existing deployment.

**Maintenance note:** keep this runbook current. Every time you change a deploy script, add a new adapter family, or hit a gotcha worth preserving, update the corresponding section and open a PR.

---

## System overview

> **Note on addresses in this runbook.** All of OUR deployed-contract addresses are reset to `TBD` for the from-scratch NAV v2 redeploy. After broadcast, read the live addresses from `script/config/deployments/<chainId>.json` (`NAVCalculatorProxy` / `BridgeEscrowProxy` / per-chain `ERC20Default`). The deployments file is written by the deploy scripts and is the source of truth; this runbook intentionally carries no concrete addresses for our contracts.

NAV v2 is a single, chain-local system. Each supported chain has:

- **One NAVCalculator proxy** (UUPS) at the same canonical address on every chain (`TBD`). Any Safe can call `getAccountNav(safe, quoteAsset)` and get its NAV in USD or any registered quote asset.
- **One BridgeEscrow proxy** (UUPS) at `TBD`. Tracks outbound/inbound bridge liquidity that would otherwise be invisible to the NAV.
- **One default ERC20 balance adapter** at `TBD` — reports plain wallet balances for every registered ERC20 + the native coin.
- **N custom price feed adapters** — one per Custom-priced asset. Implements `IPriceFeedCustom.getLatestPrice()`.
- **N custom balance adapters** — one per protocol position (Aave V3 Core, Morpho vault, Curve gauge, etc.). Implements `IBalanceAdapter.getAdapterPositions()` / `getAdapterBalances()` / `getAdapterBalanceForAsset()`.

The NAVCalculator routes price lookups through an embedded `Prices` contract (Chainlink or Custom per asset) and position lookups through the registered balance adapters. Both are pluggable by adding/removing adapters — the proxy never needs to be upgraded to add new protocols.

**Key invariant:** the Safe's NAV is the sum of signed `(amount * price / quote_price)` across every `PositionBalance` returned by every registered balance adapter, plus the inflight bridged-out escrow balance. No adapter can lie about another adapter's asset — positions are keyed on `(adapter, balanceAsset, protocolId, positionId, positionKind)` tuples.

---

## Roles and governance

NAVCalculator and BridgeEscrow both use OpenZeppelin `AccessControlUpgradeable` with two roles:

| Role | Code (constant) | What it gates |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000…0000` | UUPS upgrades (`_authorizeUpgrade`), grant/revoke any role, `setChainlinkL2SequencerUptimeFeed` |
| `MANAGER` | `keccak256("MANAGER")` | `registerAsset`, `addPriceFeed`, `removePriceFeedAt`, `removePriceFeed`, `addBalanceAdapters`, `addMetaBalanceAdapter`, `addMetaInstances`, `removeMetaInstances`, `removeBalanceAdapter`, `unregisterAsset`, `excludeAssetFromDefaultAdapter`, `includeAssetInDefaultAdapter`, `setChainlinkL2SequencerGracePeriod` |

**How the roles actually get assigned (read `02_DeployProxies.s.sol` + `AtomicProxyDeployer.sol` for the source of truth):**

**Atomic deploy path (default, post commit `d513f27`).**

1. `02_DeployProxies.s.sol` constructs `new AtomicProxyDeployer(navImpl, bridgeImpl, sequencerFeed, nativeSymbol, chainConfig.admin, chainConfig.manager)`.
2. Inside that constructor, the proxies are CREATE2-deployed and `NAVCalculator.initialize(address(this), ...)` / `BridgeEscrow.initialize(address(this), ...)` are called — so `AtomicProxyDeployer` itself gets `DEFAULT_ADMIN_ROLE` transiently.
3. Still inside the constructor:
   - `grantRole(DEFAULT_ADMIN_ROLE, chainConfig.admin)` on both proxies.
   - **`grantRole(MANAGER, chainConfig.manager)` on both proxies** (this is the fix from `d513f27` — previously this was a separate post-constructor call from the deployer EOA, which reverted whenever admin was a Safe).
   - **`renounceRole(DEFAULT_ADMIN_ROLE, address(this))` on both proxies** — the AtomicProxyDeployer drops its own admin role, eliminating the orphaned-admin-role cosmetic issue at the same time.
4. Control returns to `02_DeployProxies.s.sol`. There's no longer a post-constructor `grantRole` call — the atomic flow is complete. Lines that used to do that (formerly 179–183) were removed; only a no-op log line remains.

**Legacy path (`USE_LEGACY_DEPLOY=1`).** Initialization is `NAVCalculator.initialize(chainConfig.admin, ...)` directly — `chainConfig.admin` gets `DEFAULT_ADMIN_ROLE`. The broadcast sender (deployer EOA) does NOT hold any role afterwards. **The script logs a warning** that `MANAGER` must be granted via Safe TX from the admin (because `02_DeployProxies.s.sol` no longer attempts the grant). For tonight's deploy, prefer the atomic path; only use legacy if you have a specific reason.

**On-chain state.** All past deployments have been wiped; there is no live NAV v2 control plane until this redeploy completes. Every chain config must set `addresses.admin = addresses.manager` to the governance Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` (verify it is a Safe — `cast code` returns bytecode, not `0x`) before broadcast, so the Safe holds both `DEFAULT_ADMIN_ROLE` and `MANAGER` from deploy time. Do not point admin/manager at a deployer EOA for production.

**MANAGER-grant bug — FIXED in commit `d513f27` (2026-04-29).** The atomic path now grants MANAGER inside `AtomicProxyDeployer`'s constructor (where the deployer transiently holds `DEFAULT_ADMIN_ROLE`), so it works regardless of whether `chainConfig.admin` is an EOA or a Safe. The same commit also makes the deployer self-renounce its admin role at constructor end, closing the orphaned-admin cosmetic issue. The legacy path no longer attempts the grant from the deployer EOA — it logs a warning that MANAGER must be granted via Safe TX from the admin. **No workaround is required for tonight's redeploy.** Historical context: between 2026-04-20 and 2026-04-29 this was a blocking deploy bug with three documented workarounds in this runbook; PR #14's caveat callouts described those workarounds. They are now obsolete; flag remaining mentions for cleanup but do not act on them.

**Steady-state convention.** `chainConfig.admin` and `chainConfig.manager` should point to the **same Safe multisig** (the governance Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`). Deployer EOA pays gas at deploy time and retains no ongoing NAV powers. This redeploy wires the Safe in from the start.

**Why this matters (v1 precedent).** `karpatkey-tokenized-fund` ETH Alpha STAGE's NAVCalculator v1 ended up with MANAGER stuck on the deployer EOA and no `DEFAULT_ADMIN_ROLE` holder at all — leaving it upgrade-locked and requiring a full redeploy. NAV v2's access-control design is safer, and since `d513f27` the role grants are atomic with proxy initialization. Always run the post-deploy role validation below regardless — defence in depth.

**Post-deploy role validation** (run for every chain, every time you deploy):

```bash
CHAIN_ID=1   # 1 / 42161 / 8453 / 10 / 100
NAV_PROXY=$(jq -r '.NAVCalculatorProxy' script/config/deployments/$CHAIN_ID.json)
SAFE=<chainConfig.admin / chainConfig.manager — expected holder>
DEPLOYER=<deployer EOA — expected non-holder>
MANAGER_ROLE=$(cast keccak "MANAGER")
RPC=<rpc url>

# Expected: true, true, false, false
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" 0x0 $SAFE --rpc-url "$RPC"
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $SAFE --rpc-url "$RPC"
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" 0x0 $DEPLOYER --rpc-url "$RPC"
cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $DEPLOYER --rpc-url "$RPC"
```

If any of these return the wrong result, **stop and fix** before proceeding. See "Troubleshooting — Role misconfiguration" at the bottom.

---

## Canonical addresses

> **STATUS — all past deployments wiped; NAV v2 is being redeployed from scratch (new bytecode).** No live addresses exist until this redeploy completes. Admin + manager on every NAV proxy will be held by the governance Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` (same address on every chain). Deployer EOA holds no privileged role at end state. Per-chain inventory of every deployed address (proxies, impls, price-feed adapters, balance adapters, bridge adapters) lives in `script/config/deployments/<chainId>.json`, written by the deploy scripts.

### NAV v2

| Component | Address | Chains |
|-----------|---------|--------|
| NAVCalculator Implementation | `TBD` | Same on all 5 chains (CREATE2). |
| NAVCalculator Proxy (CREATE2) | `TBD` | Same on all 5 chains. The address every consumer should use. |
| ERC20Default Balance Adapter | `TBD` | Same on all 5 chains (auto-deployed in `NAVCalculator.initialize`). |
| `UUPSPlaceholder` impl | `TBD` | Same on all 5 chains. Used transiently during atomic deploy. |
| Governance Safe (admin + manager on every NAV proxy) | `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` | Same on all 5 chains. |

### Bridge

| Component | Address | Chains |
|-----------|---------|--------|
| BridgeEscrow Implementation | `TBD` | All 5 chains. |
| BridgeEscrow Proxy (CREATE2) | `TBD` | All 5 |

> When BridgeEscrow is required, follow the same atomic-deploy pattern: deploy the proxy via the atomic deployer, hand off roles to the governance Safe.

> **Source of truth for per-chain deployed addresses:** `script/config/deployments/<chainId>.json`, written by the deploy scripts. `chains/<chainId>.json` no longer holds deployed addresses. Never rely on abbreviated addresses — always copy the full value from the deployments file for any chain-specific implementation exception.

All deployed adapter addresses are persisted in the per-chain deployments file:
- Bridge adapters → `deployments/<chainId>.json` (per-adapter key)
- Price feed adapters → `deployments/<chainId>.json` (per-adapter key)
- Balance adapters → `deployments/<chainId>.json` (per-adapter key)

The per-concern config files (`contracts-deployment-config/custom-price-feeds/<chainId>.json`, `contracts-deployment-config/balance-adapters/<chainId>.json`, `contracts-deployment-config/meta-balance-adapters/<chainId>.json`, `nav-config/assets-and-price-feeds/<chainId>.json`, `nav-config/balance-adapters/<chainId>.json`, `nav-config/meta-balance-adapters/<chainId>.json`) hold constructor/config inputs only — they do **not** store deployed addresses. `ConfigReader.writeAdapterAddress` always writes to `deployments/<chainId>.json`, regardless of adapter type.

> **Querying current deploy state.** To see what's actually deployed on each chain at any point: read `deployments/<chainId>.json`. A missing or empty entry = not yet deployed. This runbook is the process; the deployments file is the source of truth for state.

## Supported chains

| Chain | ID | Config file |
|-------|----|-------------|
| Ethereum Mainnet | 1 | `script/config/chains/1.json` |
| Arbitrum | 42161 | `script/config/chains/42161.json` |
| Base | 8453 | `script/config/chains/8453.json` |
| Optimism | 10 | `script/config/chains/10.json` |
| Gnosis | 100 | `script/config/chains/100.json` |

---

## Redeploying proxies (production fresh-start)

Use this section for the from-scratch redeploy: all past deployments have been wiped and you need fresh proxies (new bytecode) with Safe-controlled roles from the start.

**Fresh implementations + fresh proxies (new bytecode).** This is a from-scratch redeploy: deploy new NAVCalculator and BridgeEscrow implementations (Phase 1 / `01_DeployImplementations.s.sol`), then new proxies pointing at them. All past deployments have been wiped from the configs; the new addresses are written to `deployments/<chainId>.json`.

> **CREATE2 collision avoidance.** Proxies and the placeholder are CREATE2-deployed with `generateSalt("NAVCalculatorProxy", <ver>)` / `("BridgeEscrowProxy", <ver>)` / `("ProxyPlaceholderImpl", <ver>)` (the trailing integer is a salt version). CREATE2 cannot redeploy at an address still occupied on-chain — so if a prior proxy at the current salt version is still live, bump the salt version in `script/deploy/02_DeployProxies.s.sol` (lines 33, 40, 44) to derive fresh addresses. If the prior on-chain proxies are gone (or never existed on this chain), the existing salt values can be reused as-is.

### R.1 Prerequisites

- [ ] **Confirm target Safe address.** This Safe will hold `DEFAULT_ADMIN_ROLE` + `MANAGER` on both proxies after the redeploy. Ideally the same Safe address on all 5 chains (Safe Protocol's `SafeProxyFactory.createProxyWithNonce(...)` with a deterministic nonce + initializer can give matching addresses; coordinate with the Safe deploy team if not yet provisioned). Verify per chain with `cast call <SafeAddr> "getThreshold()(uint256)" --rpc-url <RPC>` — should return a positive integer (and code present).
- [ ] **Decide which Safe address goes in `chainConfig.admin` vs `chainConfig.manager`.** Recommended: same Safe in both, per the runbook's steady-state convention.
- [ ] **Salt version checked against on-chain state.** The salt version lives in `script/deploy/02_DeployProxies.s.sol:32,39,43`, `script/deploy/AtomicProxyDeployer.sol:29,33,37`, `script/deploy/02_2_DeployNAVProxy.s.sol:32,37`, and `script/deploy/AtomicNAVProxyDeployer.sol:27,31`. If a prior proxy at the current salt version is still live on a target chain, broadcasting will hit a CREATE2 collision — the atomic deployer's `code.length == 0` guards will skip the deploys, and the subsequent `upgradeToAndCall` will revert. In that case, bump the salt version consistently across all 4 files before R.2 step 4. If the prior on-chain proxies are gone, keep the existing salt values.
- [ ] **MANAGER-grant bug** — already fixed in commit `d513f27` (atomic path grants MANAGER + self-renounces admin inside `AtomicProxyDeployer`'s constructor). No workaround needed for tonight's redeploy. Legacy path (`USE_LEGACY_DEPLOY=1`) still requires a Safe TX from the admin to grant MANAGER; if you need legacy, plan that handoff separately.
- [ ] **Deployer EOA gas funded on all 5 chains.** Rule of thumb: 0.05 ETH on Mainnet, 0.01 ETH-equivalent on each L2/Gnosis. `02` uses CREATE2 + UUPS upgrade-and-init, ~600k gas per chain.
- [ ] **Per-chain `.env` keys present:** `ALCHEMY_API_KEY`, `DEPLOYER_NAME` (Foundry keystore account name; import once with `cast wallet import $DEPLOYER_NAME --interactive`). For Path B (EOA-then-handoff) also `DEPLOYER_EOA` (= `cast wallet address --account $DEPLOYER_NAME`).
- [ ] **All tests green** on the branch you're deploying from. `forge test` non-fork = 716+ passing (latest run confirmed this 2026-04-29 post-`d513f27`).

#### About the MANAGER-grant bug — historical (FIXED in `d513f27`)

This subsection used to describe the deploy bug + three workaround options and was load-bearing between 2026-04-20 and 2026-04-29. Since commit `d513f27` (2026-04-29) the bug is fixed in code: `AtomicProxyDeployer`'s constructor now grants `MANAGER` to `chainConfig.manager` while it still holds `DEFAULT_ADMIN_ROLE`, then self-renounces admin (eliminating the orphaned-admin cosmetic issue at the same time). The post-constructor `grantRole(MANAGER, ...)` block at the old `02_DeployProxies.s.sol:179-183` was removed.

**No workaround is needed.** The atomic path now works cleanly regardless of whether `chainConfig.admin` is an EOA or a Safe. If you're using `USE_LEGACY_DEPLOY=1`, the legacy path logs a warning at deploy time that MANAGER must be granted via Safe TX from the admin afterwards — handle that separately.

If you're reading historical PR comments or older PR #14 versions that describe the three-option decision matrix, those are obsolete. Current decision: just use the default atomic path.

### R.2 Step-by-step

1. **Check the salt version (bump only if colliding).** In `script/deploy/02_DeployProxies.s.sol`:
   ```solidity
   bytes32 saltPlaceholder = generateSalt("ProxyPlaceholderImpl", <ver>);
   ...
   bytes32 saltNavProxy    = generateSalt("NAVCalculatorProxy",    <ver>);
   ...
   bytes32 saltBridgeProxy = generateSalt("BridgeEscrowProxy",     <ver>);
   ```
   Keep the existing salt values unless a prior proxy at that version is still live on a target chain (CREATE2 collision) — in which case bump `<ver>` consistently across the 4 files listed in R.1. Compute the resulting addresses locally (`forge script` prints them in dry-run before broadcasting) — these are the **canonical proxy addresses** going forward.

2. ~~Patch the MANAGER-grant bug~~ — already fixed in `d513f27`. Verify the atomic path is current by checking `AtomicProxyDeployer.sol` constructor signature includes `address managerToGrant`; if so, no patch needed.

3. **Update each `script/config/chains/<id>.json`:**
   - Set `addresses.admin` and `addresses.manager` to: **Path A** the governance Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`; **Path B** `$DEPLOYER_EOA` (to be transferred to the Safe by `07_TransferAdminToSecurityCouncil.s.sol` after Phase 6).
   - Deployed addresses are no longer stored in `chains/<id>.json` — the deploy scripts write everything (proxies, impls, ERC20Default, adapters) to `deployments/<chainId>.json`. For a from-scratch redeploy, start from an empty `deployments/<chainId>.json` (or none); the scripts create/populate it after broadcast.
   - Balance-adapter constructor inputs live in `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` (plain) and `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta); the `navCalculator` wiring for ERC20Default comes from the new deploy and need not be hand-edited.

4. **Run `02_DeployProxies.s.sol --broadcast` per chain:**
   ```bash
   for chain in 1 42161 8453 10 100; do
     case $chain in
       1)     RPC=https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       42161) RPC=https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       8453)  RPC=https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       10)    RPC=https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       100)   RPC=https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
     esac
     forge script script/deploy/02_DeployProxies.s.sol \
       --rpc-url "$RPC" --chain-id $chain \
       --broadcast --account $DEPLOYER_NAME
   done
   ```
   Expected per chain: 3 CREATE2 transactions (placeholder, NAV proxy, Bridge proxy) + 2 UUPS upgrade-and-init transactions. The script writes the new proxy addresses into `deployments/<chainId>.json`.

5. **Final handoff:** after Phase 6 completes (adapters registered via `addBalanceAdapters`/`addMetaBalanceAdapter` + meta-instances applied via `addMetaInstances`/`removeMetaInstances` + bridge adapters authorized via `06_Configure.s.sol`), run `07_TransferAdminToSecurityCouncil.s.sol` to grant DEFAULT_ADMIN_ROLE + MANAGER to `addresses.securityCouncil` on **both** the NAV and Bridge proxies and renounce the deployer EOA's roles.

6. **Verify roles** post-deploy with the cast block from §"Roles and governance":
   ```bash
   NAV_PROXY=<new address>
   SAFE=<target Safe>
   DEPLOYER=<deployer EOA>
   MANAGER_ROLE=$(cast keccak "MANAGER")
   for chain in 1 42161 8453 10 100; do
     case $chain in
       1)     RPC=https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       42161) RPC=https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       8453)  RPC=https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       10)    RPC=https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
       100)   RPC=https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY ;;
     esac
     # Expected: true, true, false, false (Safe holds both, deployer holds neither)
     cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" 0x0 $SAFE     --rpc-url "$RPC"
     cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $SAFE     --rpc-url "$RPC"
     cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" 0x0 $DEPLOYER --rpc-url "$RPC"
     cast call $NAV_PROXY "hasRole(bytes32,address)(bool)" $MANAGER_ROLE $DEPLOYER --rpc-url "$RPC"
   done
   ```
   Repeat for `BRIDGE_PROXY`. **Stop and fix** if any returns the wrong result.

7. **Confirm the per-chain ERC20Default Balance Adapter address** in `deployments/<chainId>.json` — this gets deployed during `NAVCalculator.initialize()`. Read the new address from the broadcast logs (`02_DeployProxies.s.sol` logs `ERC20Default adapter (from NAV init): 0x...`) or query the proxy directly via the public getter: `cast call <NAV_PROXY> "erc20DefaultAdapter()(address)" --rpc-url <RPC>`. The script writes it to `deployments/<chainId>.json` — verify in the diff before committing.

8. **Confirm the new proxy + ERC20Default addresses landed in `deployments/<chainId>.json`.** The "Canonical addresses" table at the top of this runbook carries `TBD` for our contracts by design; the deployments file is the source of truth.

9. **Update `docs/historical/adapter-migration-plan.md`** "Aspects to improve" — the `02_DeployProxies` MANAGER-grant bug entry should be marked as fixed in `d513f27` (already past tense in this runbook; align the historical plan to match).

10. **Optionally clean up the orphaned `AtomicProxyDeployer` admin role.** From the new constructor logs, find the `AtomicProxyDeployer` address(es) deployed on each chain. Issue a Safe TX:
    ```
    NAVCalculator.revokeRole(DEFAULT_ADMIN_ROLE, <AtomicProxyDeployer>)
    BridgeEscrow.revokeRole(DEFAULT_ADMIN_ROLE, <AtomicProxyDeployer>)
    ```
    Cosmetic — that contract has no callable functions to abuse the role with.

11. **Continue with Phase 4** (deploy balance adapters), then Phase 5+6 (Safe TX batch from the new admin Safe), Phase 8 (verification), Phase 9 (validation).

### R.3 What about the OLD proxies?

All past deployments have been wiped from the configs. Any prior proxies that remain on-chain are orphan deployments with no consumers — chain configs and downstream consumers read the new addresses from `deployments/<chainId>.json` once this redeploy writes them. Nothing functional uses the old proxies. Belt-and-braces hygiene (revoking roles on stale proxies) is optional since they have no balance and no consumers.

### R.4 Don't forget downstream

- `karpatkey-tokenized-fund` — any deploy script that hardcodes the NAV v2 proxy addresses needs updating once the new addresses are in `deployments/<chainId>.json`.
- `onchain-investment-vehicles` — same; check before re-deploying any Shares contract.
- Internal monitoring / dashboards / docs — anywhere the old addresses are referenced.

---

## Two deployment paths (post-`d513f27` and `088467a`)

There are now two end-to-end deploy paths. Pick one before broadcast; do not mix mid-deploy.

### Path A — Safe-from-the-start (default, recommended)

Use this if `chainConfig.admin` and `chainConfig.manager` are set to the production Safe(s) before broadcast.

Phases / scripts:
1. `01_DeployImplementations.s.sol` (or `01_2_DeployNAVImplementation.s.sol` for NAV-only) — same canonical implementation addresses across chains.
2. `02_DeployProxies.s.sol` (or `02_2_DeployNAVProxy.s.sol` for NAV-only) — atomic deploy: `AtomicProxyDeployer` deploys placeholder + proxies, calls `initialize`, grants `DEFAULT_ADMIN_ROLE` to the Safe, grants `MANAGER` to `chainConfig.manager`, self-renounces admin. Single tx per proxy.
3. `03_DeployPriceFeeds.s.sol` — broadcast (currently SKIPPED for Alpha funds, see Phase 3).
4. `04_DeployBalanceAdapters.s.sol` — broadcast.
5. `05_DeployBridgeAdapters.s.sol` — broadcast.
6. `06_Configure.s.sol` — reads `nav-config/balance-adapters/<chainId>.json` (plain) + `nav-config/meta-balance-adapters/<chainId>.json` (meta) and generates Safe TX batch (`addBalanceAdapters(address[])` / `addMetaBalanceAdapter(address,instances)` + `addMetaInstances`/`removeMetaInstances` for meta-adapters + `authorizeAdapter` per bridge adapter). Safe executes via Safe UI Transaction Builder.
7. Phase 5 (`RegisterAssets.s.sol`) — generates Safe TX batch for asset registration.
8. Phase 8 (`VerifyEtherscan`), Phase 9 (validation).

Roles end state: Safe holds `DEFAULT_ADMIN_ROLE` + `MANAGER` on both proxies. Deployer EOA holds nothing. AtomicProxyDeployer holds nothing (self-renounced).

### Path B — EOA-then-handoff (alternative)

Use this if you want all post-deploy configuration done by the deployer EOA via direct broadcast (no Safe-batch flow), then hand off to the Safe at the end. Useful if the Safe signers aren't available at deploy time, or if you want to minimize the Safe-side workflow.

Phases / scripts (additions in **bold**):
1. `01_DeployImplementations.s.sol` (same as Path A).
2. `02_DeployProxies.s.sol` with `chainConfig.admin = chainConfig.manager = $DEPLOYER_EOA` — atomic deployer grants both roles to the EOA.
3. `03_DeployPriceFeeds.s.sol` (currently SKIPPED).
4. `04_DeployBalanceAdapters.s.sol`.
5. `05_DeployBridgeAdapters.s.sol`.
6. **`06_Configure.s.sol`** — direct EOA broadcast of `addBalanceAdapters()` + `addMetaInstances()`/`removeMetaInstances()` per deployed adapter, plus bridge-adapter authorization. Idempotent (skips already-registered adapters / already-authorized adapters; meta-instance sets are reconciled by diffing against the on-chain set).
7. Phase 5 (`RegisterAssets.s.sol` with the broadcast path) — EOA registers assets directly using its `MANAGER` role.
8. **`07_TransferAdminToSecurityCouncil.s.sol`** — grants `DEFAULT_ADMIN_ROLE` + `MANAGER` to the target Safe, revokes `MANAGER` from the EOA, renounces `DEFAULT_ADMIN_ROLE`. **Currently NAV-only** (does not touch BridgeEscrow); if Bridge is in scope you must hand-roll a Safe TX batch for Bridge admin handoff.
9. Phase 8 (`VerifyEtherscan`), Phase 9 (validation).

Roles end state (after step 8): Safe holds `DEFAULT_ADMIN_ROLE` + `MANAGER` on NAVCalculator. Deployer EOA holds nothing on NAV. **BridgeEscrow handoff is manual** — see step 8 caveat.

### Which path tonight?

If the production Safe(s) are deployed and signers are available, prefer **Path A** — it's the cleanest end state (Safe holds roles from moment 1, no EOA-admin window) and uses the standard Safe UI flow that auditors and signers are already familiar with. **Path B** is appropriate if signers aren't available or if you specifically need the EOA-broadcast simplicity for some part of the operation.

`06_Configure.s.sol`'s `_balanceAdapterNames()` list must stay in sync with `04_DeployBalanceAdapters.s.sol`. If you see drift, that's a bug.

---

## Phase 0: Prerequisites

### 0.1 Merge adapter migration PRs

The adapter migration PRs have all merged to `main`:

| PR | Branch | Content | Status |
|----|--------|---------|--------|
| [#10](https://github.com/karpatkey/onchain-accounting/pull/10) | `feat/pr1-surgical-changes` | Base infrastructure changes | Merged 2026-04-17 (`f97f264`) ✓ |
| [#11](https://github.com/karpatkey/onchain-accounting/pull/11) | `feat/pr2-price-oracles` | 16 custom price oracles + L2 deploy wiring | Merged 2026-04-17 (`369efd0`) ✓ |
| [#12](https://github.com/karpatkey/onchain-accounting/pull/12) | `feat/pr3-balance-adapters` | 5 new balance adapter adapters (MorphoVault, GearboxMarket, Cap, Curve, Convex) + per-instance deploy wiring | Merged 2026-04-17 (`f32d560`) ✓ |
| [#13](https://github.com/karpatkey/onchain-accounting/pull/13) | `docs/nav-v2-runbook-update` | NAV v2 runbook + tracked migration plan + SparkLend dispatch fix | Merged 2026-04-24 (`849e3ff`) ✓ |
| [#14](https://github.com/karpatkey/onchain-accounting/pull/14) | `feat/usd-alpha-token-registry` | USD Alpha token registry alignment + heartbeat fixes + redeploy guidance docs | Open — must merge before Phase 4 |

### 0.2 Environment setup

Create or update `.env` in the project root:

```bash
# RPC (used by all chain configs via "$ALCHEMY" placeholder)
ALCHEMY_API_KEY=your_alchemy_key

# Foundry keystore account name (import once: cast wallet import $DEPLOYER_NAME --interactive)
DEPLOYER_NAME=my-deployer

# Explorer API keys (for contract verification)
ETHERSCAN_API_KEY=...
ARBISCAN_API_KEY=...
BASESCAN_API_KEY=...
OPTIMISM_ETHERSCAN_API_KEY=...
GNOSISSCAN_API_KEY=...
```

### 0.3 Run all tests

```bash
# Unit tests
forge test --no-match-path 'test/**/fork/*.sol'

# Fork tests (requires ALCHEMY_API_KEY)
forge test --match-path 'test/**/fork/*.sol'
```

Expected: all tests green. As of post-merge on `main` (2026-04-17): **716 unit + 271 fork**. Re-run locally to confirm counts haven't drifted.

### 0.4 Review chain configs

Open `script/config/chains/{chainId}.json` and confirm every field is correct for your target. Critical fields:

| Field | Meaning | Validation |
|---|---|---|
| `rpc` | RPC endpoint or `"$ALCHEMY"` placeholder | Resolve to a live endpoint; 429/timeout during scripts points to this |
| `explorer` + `explorerApiKey` | For Etherscan-family verification in Phase 8 | Must match chainId |
| `chainlinkSequencerFeed` | Chainlink L2 sequencer uptime feed; `address(0)` on L1s | Required on L2s — otherwise `getAccountNav` can't detect sequencer downtime |
| `nativeTokenSymbol` | `"ETH"`, `"xDAI"`, etc. | Shows up in NAV responses for the native sentinel |
| `addresses.securityCouncil` | The governance Safe | **Must be a Safe** — verify via `cast code <addr> --rpc-url <RPC>` (returns bytecode, not `0x`) AND `cast call <addr> "getThreshold()(uint256)"` (returns ≥1). Governance Safe: `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`. |
| `addresses.admin` | Holds `DEFAULT_ADMIN_ROLE` post-deploy | Must equal `securityCouncil` (the governance Safe). |
| `addresses.manager` | Holds `MANAGER` post-deploy | Must equal `securityCouncil` (the governance Safe). |
| `deployments/<chainId>.json` | NAV/Bridge/adapter addresses, written by deploy scripts | Empty for the from-scratch redeploy; populated by broadcast. `chains/<id>.json` no longer holds deployed addresses. |

**Rule:** if you change any `addresses.*` value after `02_DeployProxies.s.sol` has run for a chain, you must re-grant roles explicitly via a Safe TX batch. You cannot re-run `02` idempotently for role changes.

### 0.5 Pre-flight checklist (do before any `--broadcast` invocation)

Tick every box below before you broadcast on any chain. Each one has burned a past deployment:

- [ ] **NAV v2 proxies have been redeployed with Safe admin/manager.** Verify with `cast code <safeAddr> --rpc-url <RPC>` returning bytecode, not `0x`, AND `hasRole(DEFAULT_ADMIN_ROLE, <safe>) = true` on both proxies. If admin/manager is not the governance Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`, **stop and complete "Redeploying proxies" first** — Phase 4-9 against EOA-controlled proxies is single-key custody.
- [ ] Branch you're deploying from is `main` (or a documented release tag). `git rev-parse HEAD` matches the commit you expect.
- [ ] `forge build` passes clean (default profile — `foundry.toml` defines only `default`, `coverage`, and `slow`; there is no `local` profile here).
- [ ] Non-fork tests pass: `forge test --no-match-path 'test/**/fork/*.sol'` → 716+ passing.
- [ ] Fork tests pass against your target chain: `FOUNDRY_PROFILE=slow forge test --match-path 'test/**/fork/*.sol'` → 271+ passing.
- [ ] `.env` has: `ALCHEMY_API_KEY`, `DEPLOYER_NAME` (Foundry keystore account name), `<CHAIN>_ETHERSCAN_API_KEY`.
- [ ] Deployer EOA has native gas on the target chain (check with `cast balance <EOA> --rpc-url ...`). Rule of thumb: 0.05 ETH on L1, 0.01 ETH-equivalent on L2s/Gnosis for a full Phase 4+5 run (Phase 3 typically skipped — see Phase 3 intro).
- [ ] Chain config `addresses.admin` and `addresses.manager` point to the correct per-chain Safe (post-redeploy).
- [ ] For redeploys of a specific adapter: `deployed: ""` is cleared in the config (otherwise the script skips).
- [ ] You know which Safe's signers will execute the generated Safe TX JSONs in Phases 5/6, and those signers are available.
- [ ] You have a rollback plan: any pre-existing price feed or balance adapter you intend to replace is documented, and you know the `cast send` commands to revert.

---

## Phase 1: Configure Price Feed Adapters

Price feed adapter configuration is split across two per-chain files: `script/config/contracts-deployment-config/custom-price-feeds/<chainId>.json` (constructor inputs for the Custom price adapters we deploy, keyed by feed name) and `script/config/nav-config/assets-and-price-feeds/<chainId>.json` (per-symbol token + feed definitions, keyed by symbol). In both, the top-level keys are the entries — the filename is the chain.

### 1.1 Add custom price feed deploy entries

Under `contracts-deployment-config/custom-price-feeds/<chainId>.json.<name>`, add `enabled` + `constructor` params for each custom price adapter you want `03_DeployPriceFeeds.s.sol` to deploy on that chain. A token references a custom feed from its own `priceFeeds` list (in `nav-config/assets-and-price-feeds/<chainId>.json`) via `{ "type": "Custom", "feed": "<name>", "heartbeat": ... }`.

> **Looking up Chainlink heartbeats.** Every `*chainlinkHeartbeat` constructor parameter must match (or slightly exceed) the published heartbeat of the underlying Chainlink feed — otherwise every query returns `stale: true` between heartbeat writes. Chainlink's authoritative source is the JSON directory at `https://reference-data-directory.vercel.app/feeds-<network>.json` (e.g. `feeds-mainnet.json`, `feeds-ethereum-mainnet-arbitrum-1.json`). Each feed entry exposes `heartbeat` (seconds) and `threshold` (deviation %). Alternatively, [data.chain.link](https://data.chain.link) shows the same values per feed page. ETH/USD mainnet is 3600s; USD stablecoins are typically 86400s. If in doubt, round up (e.g. 3900s) to tolerate block-time jitter.

> **Deployed addresses go to the deployments file.** `ConfigReader.writeAdapterAddress(...)` writes deployed price-feed addresses to `script/config/deployments/<chainId>.json` (per-adapter key) — not into the config files and not into `chains/<chainId>.json`. The per-concern config files hold constructor/config inputs only.

Structure — `nav-config/assets-and-price-feeds/<chainId>.json` (keyed by symbol):

```json
{
  "<SYM>": {
    "address": "0x...",
    "priceFeeds": [
      { "type": "Chainlink", "address": "0x...", "heartbeat": 3600 },
      { "type": "Custom", "feed": "<name>", "heartbeat": "115792089237316195423570985008687907853269984665640564039457584007913129639935" }
    ]
  }
}
```

Structure — `contracts-deployment-config/custom-price-feeds/<chainId>.json` (keyed by feed name):

```json
{
  "<name>": {
    "enabled": true,
    "constructor": {
      "param1": "0x...",
      "param2": "3600"
    }
  }
}
```

The first entry in a token's `priceFeeds` array is set via `registerAsset`; any subsequent entries are appended via `addPriceFeed` (ADR 0009).

### 1.2 Mainnet custom price feed adapters

`03_DeployPriceFeeds.s.sol._deployMainnetPriceAdapters()` dispatches each adapter below, guarded by `ConfigReader.isAdapterEnabled(...)`. An adapter is deployed only if its entry exists and is `enabled: true` under `contracts-deployment-config/custom-price-feeds/1.json.<name>`. The **Configured today** column reflects the current state of that file on this branch — adapters marked `—` are supported by the deploy script but have no deploy entry, so they are skipped at deploy time. Add them to `contracts-deployment-config/custom-price-feeds/1.json` when a fund needs them.

| Adapter | Config key | Configured today | Constructor params needed |
|---------|-----------|------------------|--------------------------|
| wstETH | `wstETH` | ✓ | `wstEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| rETH | `rETH` | ✓ | `rEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| weETH | `weETH` | ✓ | `weEth`, `weEthToEthChainlinkOracle`, `ethToUsdChainlinkOracle`, `weEthToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |
| eETH | `eETH` | ✓ | `eEth`, `weEth`, `weEthToEthChainlinkOracle`, `ethToUsdChainlinkOracle`, `weEthToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |
| ezETH | `ezETH` | ✓ | `ezEth`, `restakeManager`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| rsETH | `rsETH` | ✓ | `rsEth`, `rateProvider`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |
| sUSDe | `sUSDe` | ✓ | `sUsde`, `usdeToUsdChainlinkAddress`, `usdeToUsdChainlinkHeartbeat` |
| sUSDS | `sUSDS` | ✓ | `sUsds`, `usdsToUsdChainlinkAddress`, `usdsToUsdChainlinkHeartbeat` |
| syrupUSDC | `syrupUSDC` | ✓ | `syrupUsdc`, `usdcToUsdChainlinkAddress`, `usdcToUsdChainlinkHeartbeat` |
| sDAI | `sDAI` | — | `sDai`, `dsrManager`, `daiToUsdChainlinkOracle`, `daiToUsdChainlinkHeartbeat` |
| LDO | `LDO` | — | `ldo`, `ldoToEthChainlinkAddress`, `ethToUsdChainlinkAddress`, `ldoToEthChainlinkHeartbeat`, `ethToUsdChainlinkHeartbeat` |
| cbETH | `cbETH` | — | `cbEth`, `ethToUsdChainlinkOracle`, `ethToUsdChainlinkHeartbeat` |

### 1.3 Gnosis price feed adapters

| Adapter | Config key | Constructor params needed |
|---------|-----------|-------------------------|
| sXDAI | `sXDAI` | `sXdai`, `xDaiToUsdChainlinkOracle`, `xDaiToUsdChainlinkHeartbeat` |

### 1.4 L2 and Mainnet custom price feed adapter dispatch

Authoritative source: the `_deploy<Chain>PriceAdapters` functions in `03_DeployPriceFeeds.s.sol`. Current wiring (post-PR #11 merge):

| Adapter | Deployed on | Source file | Notes |
|--------|-------------|-------------|-------|
| `wstETH_L2` | Arbitrum, Base, Gnosis | `wstETH_L2_Price.sol` | Gnosis uses an Aave ratio provider in place of a Chainlink feed, same interface |
| `cbETH_L2` | Base | `cbETH_L2_Price.sol` | |
| `weETH_L2` | Arbitrum, Base | `weETH_L2_Price.sol` | |
| `rsETH_L2` | Arbitrum | `rsETH_L2_Price.sol` | |
| `ezETH_L2` | Arbitrum | `ezETH_L2_Price.sol` | Uses `xRenzoDeposit.getRate()`, different from Mainnet `ezETH` |
| `syrupUSDC_L2` | Arbitrum | `syrupUSDC_L2_Price.sol` | |
| `sXDAI` | Gnosis | `sDAI_Price.sol` (aliased as `sXDAI_PriceOracle` — constructor is re-used) | |
| `ezETH` | Mainnet | `ezETH_Price.sol` | Uses `restakeManager.calculateTVLs()` |
| `ETHPlus` | **not deployed** | `ETHPlus_Price.sol` | The adapter contract exists and is unit + fork tested, but no `_deployIfEnabled("ETHPlus")` call is wired because ETH Alpha uses a Chainlink feed for ETHPlus on mainnet. Leave it that way unless a fund starts relying on the Custom path. |

**Optimism has no Custom price adapters.** Alpha funds on OP use Chainlink feeds exclusively (`wstethToUsdChainlink`, `usdcToUsdChainlink`, `usdtToUsdChainlink`). `_deployOptimismPriceAdapters()` is an intentional no-op; if a future fund needs a Custom adapter on OP, add it there.

> **Double-check before you add a new Custom adapter:** some assets on L2s already have a `priceFeeds` entry of `type: "Chainlink"` pointing at a third-party-deployed ratio feed `address` (e.g. an Aave-provided ratio feed), rather than a `type: "Custom"` adapter we own. Confirm whether the existing feed is ours or third-party before deploying a duplicate Custom adapter.

### 1.5 Heartbeat conventions

The asset/price-feed config and the chain configs both surface heartbeat values, and they mean different things in different places. Get this wrong and `NAVCalculator.getAccountNav` either over-reports staleness (every price flagged stale) or under-reports it (a multi-hour-stale price is treated as fresh).

**Where heartbeats appear and what they control:**

| Location | Used by | What it does |
|---|---|---|
| `nav-config/assets-and-price-feeds/<chainId>.json .<symbol>.priceFeeds[].heartbeat` (number or string) | `RegisterAssets.s.sol` → `NAVCalculator.registerAsset(_, _, _, heartbeat)` for the first feed / `addPriceFeed(_, _, _, heartbeat)` for the rest → stored in `priceOracles[asset].chainlinkHeartbeat` | For `Chainlink`/`Redstone`/`API3`-typed entries: NAV checks `block.timestamp - latestRoundData().updatedAt >= heartbeat` and flags the feed stale if exceeded. For `Custom`-typed entries: the primary gate is `getLatestPrice().stale`; the registered heartbeat is then also applied as an external gate on `latestRoundData().updatedAt` (same `>=` check). |
| `contracts-deployment-config/custom-price-feeds/<chainId>.json .<name>.constructor.<feed>Heartbeat` (string) | `03_DeployPriceFeeds.s.sol` → adapter constructor → stored in the adapter's immutable | Per-feed staleness threshold inside the Custom adapter's `getLatestPrice()`. Multi-feed adapters OR-check each one (`weETH_Price.sol:85-90`), so any single feed exceeding its heartbeat marks the whole price stale. |

**Conventions to follow (PR #14 baseline, all aligned to the fund-side):**

- **Chainlink-typed token entries.** Use the **fund-side `<chain>PriceOracles.<feed>ToUsdChainlink().chainlinkHeartbeat`** value. Notable non-86400 cases:
  - DAI/USD Mainnet: **3600**
  - USDC/USD Mainnet: **82800** (not 86400 — the standard `0x8fFfFfd4...818f6` aggregator publishes every 23h)
  - USDe/USD Mainnet: **82800**
  - ETH/USD Base, Optimism: **1200** (20-minute cadence)
  - All other ETH/USD feeds (Mainnet, Arbitrum, Gnosis): 3600 / 86400 depending on chain — check `PriceOracles.sol`
  - Stablecoins generally: **86400**
- **Custom-typed token entries.** Use **`type(uint256).max`** (the literal `115792089237316195423570985008687907853269984665640564039457584007913129639935`). This matches the fund-side `maxHeartbeat` constant. The Custom adapter reports its own staleness; this field is advisory.
- **Custom adapter constructor heartbeats** (in `contracts-deployment-config/custom-price-feeds/<chainId>.json .<name>.constructor`). Each per-feed heartbeat parameter must equal the **actual Chainlink feed's published heartbeat** for the feed it points at. Example: `custom-price-feeds/1.json .syrupUSDC.constructor.usdcToUsdChainlinkHeartbeat = "82800"` because that adapter consumes the standard USDC/USD Mainnet feed (heartbeat 82800). A 86400 here would silently tolerate a 1-hour-stale USDC price.

**Source of truth.** Every heartbeat — token-entry or adapter-constructor — should match the corresponding fund-side `karpatkey-tokenized-fund/contracts/script/deploy/adapters/priceOracles/PriceOracles.sol` `<chain>PriceOracles.<getter>().chainlinkHeartbeat`. PR #14 audited and aligned all 55 token entries and all 19 adapter-constructor heartbeats; CI doesn't currently enforce this drift, so re-audit on every change.

---

## Phase 2: Configure Balance Adapters

Balance adapter configuration is split across four per-chain files — **not** in `chains/<id>.json`. Deploy config (constructor inputs) lives in `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` (plain adapters) and `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta adapters), each keyed by `<AdapterKey>` → `{ enabled, constructor }` (no instances). NAV registration lives in `script/config/nav-config/balance-adapters/<chainId>.json` (plain adapters → `{ enabled }`) and `script/config/nav-config/meta-balance-adapters/<chainId>.json` (meta adapters → `{ enabled, instances? | instancesRaw? }`). In every file the top-level keys are the adapter names.

### 2.1 Add adapter entries

> **Starting state:** for the from-scratch redeploy, these files define the adapter set per chain. Most multi-instance protocols are covered by a single meta-adapter (e.g. `AaveV3InstancesMeta`, `MorphoVaultsMeta`, `MorphoMarketsMeta`, `AuraRewardsMeta`, `CurveGaugesMeta`); any legacy per-instance keys (`AaveV3_Core`, `MorphoMarket_*`, `Aura_*`, etc.) that remain are `enabled: false` and superseded (ADR 0010). Before editing, review what's already there and either add a new instance to a meta-adapter's `instances`/`instancesRaw` set (in `nav-config/meta-balance-adapters/<chainId>.json`) or add a missing standalone adapter. `04_DeployBalanceAdapters.s.sol` deploys the intersection of (a) names in its `run()` list and (b) entries with `enabled: true` across `contracts-deployment-config/balance-adapters/<chainId>.json` (plain) and `contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta).

For each new adapter you want to **deploy** on a given chain, add an entry in `contracts-deployment-config/balance-adapters/<chainId>.json` (plain adapters) or `contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta adapters):

```json
{
  "SparkLend": {
    "enabled": true,
    "constructor": {
      "dataProvider": "0x...",
      "protocol": "Spark"
    }
  }
}
```

To **register** it on NAV, add the same key to `nav-config/balance-adapters/<chainId>.json` (plain) as `{ "enabled": true }`, or to `nav-config/meta-balance-adapters/<chainId>.json` (meta) with its instance set:

```json
{
  "AaveV3InstancesMeta": {
    "enabled": true,
    "instances": ["0x..."]
  }
}
```

Deployed addresses are written to `deployments/<chainId>.json` by the deploy script, not stored alongside the constructor inputs. `instances` (formerly `metaInstances`) and `instancesRaw` (formerly `metaInstancesRaw`) hold a meta-adapter's instance set and are applied on-chain via `addMetaInstances`/`removeMetaInstances` (meta-vs-plain is detected on-chain via ERC165).

### 2.2 Balance adapters available for deployment

The deploy script (`04_DeployBalanceAdapters.s.sol`) supports these adapters:

| Adapter name | Key config params | Applicable chains |
|---|---|---|
| `AaveV3InstancesMeta` | `protocol` (DataProvider set via `addMetaInstances`/`removeMetaInstances`) | Mainnet, Arbitrum, Base, Optimism, Gnosis |
| `AaveV3SafetyModule` | *(no extra params)* | Mainnet |
| `AaveUmbrella` | `rewardsController` | Mainnet |
| `SparkLend` | `dataProvider` | Mainnet |
| `CompoundV3CometsMeta` | `compoundRewards`, `rewardToken`, `protocol` | Mainnet |
| `MorphoVaultsMeta` | `protocol` | Mainnet, Arbitrum |
| `MorphoMarketsMeta` | `morpho`, `protocol` (marketIds via `instancesRaw`) | Mainnet, Arbitrum, Base |
| `GearboxMarketsMeta` | `protocol` | Mainnet |
| `BalancerV3PoolsMeta` | `protocol` | Mainnet |
| `BalancerV3GaugesMeta` | `balancerMinter`, `protocol` | Mainnet |
| `BalancerV2PoolsMeta` | `vault`, `protocol` | Mainnet |
| `BalancerV2GaugesMeta` | `vault`, `balancerMinter`, `protocol` | Mainnet |
| `AuraRewardsMeta` | `booster`, `balancerV2Vault`, `protocol` | Mainnet, Arbitrum, Base. AURA token resolved dynamically via `Booster.minter()` — do **not** add an `auraToken` config field. |
| `CurvePoolsMeta` | `protocol` | Mainnet |
| `CurveGaugesMeta` | `minter`, `crvToken`, `protocol` | Mainnet (pass `minter=address(0)` on L2) |
| `ConvexRewardsMeta` | `booster`, `cvxToken`, `protocol` | Mainnet |
| `StakeWiseV3VaultsMeta` | `underlyingToken`, `protocol` | Mainnet, Gnosis |
| `Cap` | `cUsd`, `stcUsd`, `usdc` | Mainnet |
| `DaiDsr` | `dai`, `dsrManager` | Mainnet |
| `SkySavingsUsds` | `savingsUsds` | Mainnet |
| `LidoWithdrawalQueue` | `withdrawalQueue`, `underlyingToken` | Mainnet |
| `StaderWithdrawalQueue` | `userWithdrawalManager`, `underlyingToken` | Mainnet |
| `KelpWithdrawalQueue` | `withdrawalManager`, `lrtConfig` | Mainnet |

### 2.3 Specific adapters currently wired in the deploy script

`04_DeployBalanceAdapters.s.sol` has a single `run()` that holds the **union** of adapter names across every chain (currently 30 `_deployIfEnabled(...)` calls). There are no chain-specific dispatch functions — per-chain selection is controlled by the `enabled` flag in `contracts-deployment-config/balance-adapters/<chainId>.json` (plain) / `contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta). Most multi-instance protocols are covered by a single **meta-adapter** (ADR 0010) whose instance set is configured on `NAVCalculator` via `addMetaInstances`/`removeMetaInstances` (from `nav-config/meta-balance-adapters/<chainId>.json`), rather than one adapter per instance. Source of truth: the `run()` list in `04_DeployBalanceAdapters.s.sol`.

To deploy additional instances (e.g., a new Curve gauge, or AaveV3 on a different chain):

1. Add a new `_deployIfEnabled("<AdapterName>")` call inside the `run()` function of `04_DeployBalanceAdapters.s.sol`.
2. Add a corresponding `<AdapterName>` entry to `script/config/contracts-deployment-config/balance-adapters/<chainId>.json` (plain) or `script/config/contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta) with `enabled: true` and constructor params, plus the matching key in `nav-config/balance-adapters/<chainId>.json` (plain) or `nav-config/meta-balance-adapters/<chainId>.json` (meta).
3. Run `04_DeployBalanceAdapters.s.sol` for that chain — adapters not enabled in that chain's `contracts-deployment-config/balance-adapters/<chainId>.json` or `contracts-deployment-config/meta-balance-adapters/<chainId>.json` entry are skipped, and already-deployed adapters are skipped (idempotent).
4. Add the adapter address to NAVCalculator via Phase 6.

### 2.4 Adapter inventory (authoritative — `run()` list in `04_DeployBalanceAdapters.s.sol`)

`04_DeployBalanceAdapters.s.sol`'s `run()` calls `_deployIfEnabled(<name>)` for every adapter name below, on every chain. Each call fires only if the adapter's `<name>.enabled == true` in `contracts-deployment-config/balance-adapters/<chainId>.json` (plain) or `contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta). This means the `run()` list is the **union** across chains; per-chain selection happens through those files.

The `_deployIfEnabled(...)` calls in `run()` are the authoritative source. Most families are now single **meta-adapters** (ADR 0010); the legacy per-instance config keys (`AaveV3_Core`, `MorphoVault_*`, `MorphoMarket_*`, `GearboxMarket_*`, `BalancerV3_*`, `Aura_*`, `Curve_*`, `Convex_*`, `Fluid_*`, `CompoundV3_*`, `UniswapV3_*`, etc.) remain in the deploy config as `enabled: false` and are superseded by the metas. Each meta's active instance set lives on `NAVCalculator` (applied via `addMetaInstances`/`removeMetaInstances`, configured under `nav-config/meta-balance-adapters/<chainId>.json .<Meta>.instances`, or `instancesRaw` for the bytes32-keyed `MorphoMarketsMeta`).

**Aave:** `AaveV2InstancesMeta`, `AaveV3InstancesMeta` (meta-adapters — DataProvider / instance sets via `addMetaInstances`/`removeMetaInstances`; the legacy per-market `AaveV3_Core`/`AaveV3_Prime`/`AaveV3_<chain>` keys are disabled in config and have no deploy path — Aave V3 is fully meta); standalone `SparkLend`, `AaveV3SafetyModule`, `AaveUmbrella`

**Other lending / yield:** `Cap`, `CompoundV3CometsMeta`, `FluidFTokensMeta`, `FluidVaultsMeta`

**Morpho:** `MorphoVaultsMeta` (vaults via `instances`), `MorphoMarketsMeta` (raw bytes32 marketIds via `instancesRaw`)

**Gearbox:** `GearboxMarketsMeta`

**Balancer:** `BalancerV3PoolsMeta`, `BalancerV3GaugesMeta`, `BalancerV2PoolsMeta`, `BalancerV2GaugesMeta`

**Aura / Curve / Convex:** `AuraRewardsMeta`, `CurvePoolsMeta`, `CurveGaugesMeta`, `ConvexRewardsMeta` (one meta per family covering all pools/gauges/rewarders; instances via `addMetaInstances`/`removeMetaInstances`)

**DEX LP:** `UniswapV3PoolsMeta`, `PancakeSwapV3PoolsMeta`, `PancakeSwapV2PoolsMeta` (`UniswapV2PoolsMeta` is implemented and dispatchable but not yet in `run()` / enabled on any chain)

**StakeWise V3:** `StakeWiseV3VaultsMeta` (vault deposits net of minted-osToken debt — see the osETH/osGNO pricing note below)

**ERC-4626 wrappers:** `ERC4626Wrap_waEthLidoGHO`, `ERC4626Wrap_sGHO`

**Withdrawal queues:** `StaderWithdrawalQueue`, `KelpWithdrawalQueue`, `LidoWithdrawalQueue`

**Rewards:** `MerklRewards` (mutable proof-verified per-(user,token) cache — ADR 0007)

**StakeWise V3 pricing note:** osETH (Mainnet) and osGNO (Gnosis) are **Custom-priced ERC20s** via `osToken_PriceOracle` (`convertToAssets(1e18) × underlying/USD`); held osTokens are reported by `ERC20DefaultAdapter` (deployed by `03_DeployPriceFeeds` / registered by `RegisterAssets`, custom-feed keys `osETH` / `osGNO` in `contracts-deployment-config/custom-price-feeds/<chainId>.json`). The `StakeWiseV3VaultsMeta` adapter separately reports vault deposits net of minted-osToken debt (`vaultAssets - mintedOs`, denominated in ETH/GNO). Wired primarily for integration cross-checks; the Alpha funds do not currently use StakeWise.

**Explicitly not wired** (contracts exist in the repo but no Alpha fund needs them): `CompoundV3_*`, `DaiDsr`, `SkySavingsUsds`, `AaveV3SafetyModule_stkAAVE`. If you need one later, add a `_deployIfEnabled("<Name>")` line to `run()`, add the deploy entry to `contracts-deployment-config/balance-adapters/<chainId>.json` (or `contracts-deployment-config/meta-balance-adapters/<chainId>.json` for a meta) and the register entry to `nav-config/balance-adapters/<chainId>.json` (or `nav-config/meta-balance-adapters/<chainId>.json`), and add the name to `06_Configure.s.sol`'s `_balanceAdapterNames()` — otherwise the adapter deploys but never registers on NAVCalculator.

> **`ERC20Default` is special** — it's deployed inside `NAVCalculator.initialize()` (via `02_DeployProxies.s.sol`), not by `04_DeployBalanceAdapters.s.sol`. It auto-covers every asset registered on the NAVCalculator (wallet balances + native sentinel). Don't put it in the `run()` list.

> **Naming discipline matters.** The `_deployAdapter` dispatcher in `04_DeployBalanceAdapters.s.sol` routes by prefix (`_startsWith(adapterName, "AaveV3_")`). A new instance on Aave V3 must start with `AaveV3_`, a new Morpho Vault with `MorphoVault_`, and so on — otherwise the dispatcher falls through to `"Unknown adapter type"` and the deploy is a no-op.

**Invariant to check before each deploy run:** `<Name>` exists in `contracts-deployment-config/balance-adapters/<chainId>.json` (plain) or `contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta) ⇔ `04_DeployBalanceAdapters.s.sol` has `_deployIfEnabled("<Name>")` ⇔ `06_Configure.s.sol._balanceAdapterNames()` includes `"<Name>"` ⇔ a matching entry in `nav-config/balance-adapters/<chainId>.json` or `nav-config/meta-balance-adapters/<chainId>.json`. All or none.

---

## Phase 3: Deploy Price Feed Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

> **When this phase is needed (and when it isn't).** Phase 3 builds NAV v2 versions of Custom price oracles. The fund-side repo (`karpatkey-tokenized-fund`) ships its own deployments of every Custom adapter we currently use, and those v1 deployments **satisfy the v2 `IPriceFeedCustom` interface** — verified empirically across all 18 deployed Custom adapters (see `docs/historical/adapter-migration-plan.md` → "Empirical confirmation"). For any asset whose `priceFeeds` entry in `nav-config/assets-and-price-feeds/<chainId>.json .<symbol>` already points at a working fund-side `address`, **deploying a NAV v2 copy is redundant** — both contracts return the same price for the same block, and NAV v2 just reads whatever address is in the registry.
>
> Running this phase only adds value when:
> - You're onboarding a new adapter that the fund-side never deployed.
> - You explicitly want NAV v2 to own its adapter stack independently of the fund repo (e.g. for an audit boundary).
>
> If neither applies, set `contracts-deployment-config/custom-price-feeds/<chainId>.json .<name>.enabled = false` (skips the deploy) and proceed to Phase 4. As of 2026-04-28 every `enabled: true` adapter falls in the redundant category — the matching token entries point at fund-side addresses — so Phase 3 can be skipped entirely for the current Alpha-fund deployment.

> **RPC shortcut:** `--rpc-url` is optional when `ALCHEMY_API_KEY` is set — each chain config has `"rpc": "$ALCHEMY"` which `ConfigReader` resolves using `ALCHEMY_API_KEY` and the chain's Alchemy network. See `script/deploy/README.md`. The commands below include `--rpc-url` explicitly for clarity.

### 3.1 Mainnet

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --account $DEPLOYER_NAME
```

### 3.2 Gnosis

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 100 \
  --broadcast \
  --account $DEPLOYER_NAME
```

### 3.3 L2 chains (Arbitrum, Base, Optimism)

```bash
# Arbitrum
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 \
  --broadcast \
  --account $DEPLOYER_NAME

# Base
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 8453 \
  --broadcast \
  --account $DEPLOYER_NAME

# Optimism
forge script script/deploy/03_DeployPriceFeeds.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 10 \
  --broadcast \
  --account $DEPLOYER_NAME
```

### 3.4 Verify

Deployed adapter addresses are auto-saved to `script/config/deployments/<chainId>.json` via `ConfigReader.writeAdapterAddress(...)`. `contracts-deployment-config/custom-price-feeds/<chainId>.json` is only used for constructor inputs; it is not the authoritative record of deployed addresses. Check the console output for each deployed adapter address too — the `[OK] <Name> deployed at: 0x...` line is the fastest sanity check.

**Re-run safety:** If the script is interrupted, re-running will skip already-deployed adapters (checks the deployments file).

---

## Phase 4: Deploy Balance Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

> **⚠ Dry-run hazard.** `04_DeployBalanceAdapters.s.sol:144` (and 21 sites in `03_DeployPriceFeeds.s.sol`) calls `ConfigReader.writeAdapterAddress(...)` unconditionally — even on a bare `forge script` invocation **without `--broadcast`**. A dry run will write deterministic-test-sender CREATE2 addresses (`0x5b73...`, `0x7FA9...`, `0x34A1...`, etc.) into `script/config/deployments/<chainId>.json`. Subsequent real broadcasts will then read those bogus addresses, report "already deployed", and **silently skip every adapter** — leaving NAVCalculator wired to zero-code addresses. **After ANY exploratory `forge script` run of `03` or `04` without `--broadcast`, run `git checkout -- script/config/deployments/` before the real broadcast.** Tracked as a blocking follow-up in `docs/historical/adapter-migration-plan.md` "Aspects to improve" #4.

### 4.1 Mainnet

```bash
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --account $DEPLOYER_NAME
```

### 4.2 Other chains

Same pattern — replace RPC URL and chain ID:

```bash
# Arbitrum
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 42161 --broadcast --account $DEPLOYER_NAME

# Base
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 8453 --broadcast --account $DEPLOYER_NAME

# Optimism
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 10 --broadcast --account $DEPLOYER_NAME

# Gnosis
forge script script/deploy/04_DeployBalanceAdapters.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 100 --broadcast --account $DEPLOYER_NAME
```

### 4.3 Verify

Deployed addresses are auto-saved to `script/config/deployments/{chainId}.json` (per-adapter key).

**Re-run safety:** Same as price feeds — already-deployed adapters are skipped.

---

## Phase 5: Register Assets on NAVCalculator

Assets (tokens) must be registered on NAVCalculator with their price feed (Chainlink or Custom adapter address). This is done via `RegisterAssets.s.sol`.

> **This is the on-chain wiring step for price oracles.** `nav-config/assets-and-price-feeds/<chainId>.json` is just the source data. NAV v2 reads from its own `priceOracles[asset]` mapping at runtime (`Prices.sol:32`); that mapping stays empty until `RegisterAssets.s.sol` writes to it via `NAVCalculator.registerAsset(asset, feed, priceType, heartbeat)` (first feed) and `addPriceFeed(...)` (subsequent feeds, ADR 0009). After this phase completes per chain, NAV's price stack is fully wired — every registered asset returns a price (or a `stale` flag) when queried. Phases 3 and 5 are independent: Phase 3 deploys *new* adapter contracts, Phase 5 *registers* the feed addresses from `nav-config/assets-and-price-feeds/<chainId>.json .<symbol>.priceFeeds` (whether a Chainlink `address`, a fund-side v1 Custom deployment, or a NAV v2 redeploy from Phase 3 — Custom-feed addresses are resolved from the deployments file by `feed` name).

### 5.1 Review token list

Token definitions live in `script/config/nav-config/assets-and-price-feeds/<chainId>.json`, keyed by symbol. Each token has:

- `address` — token contract address
- `priceFeeds` — an ordered list of feed entries. Each is either `{ "type": "Chainlink"|"Redstone"|"API3", "address": "0x...", "heartbeat": ... }` or `{ "type": "Custom", "feed": "<name>", "heartbeat": ... }` (the Custom adapter address is resolved from `deployments/<chainId>.json` by `feed` name).

The first feed in the list is registered via `registerAsset`; any remaining feeds are appended via `addPriceFeed` (ADR 0009). Tokens with an empty `priceFeeds` list are skipped.

The set of symbols to register per chain comes from the top-level keys of `nav-config/assets-and-price-feeds/<chainId>.json`, read via `getAssetSymbols` (the old hardcoded `_symbolsForChain()` in `RegisterAssets.s.sol` was deleted). Add a new symbol by adding its entry to that file.

### 5.2 Dry run (report only)

Run without `--broadcast` and without `--rpc-url` to see what would be registered:

```bash
forge script script/manage/RegisterAssets.s.sol --chain-id 1
```

### 5.3 Generate Safe TX batch + broadcast

Run with `--rpc-url` to verify on-chain state and generate Safe TX JSON. With `--broadcast --account`, the script also calls `registerAsset()` directly (sender must have MANAGER role):

```bash
# Mainnet
forge script script/manage/RegisterAssets.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1 \
  --broadcast \
  --account $DEPLOYER_NAME
```

Output: `safe-transactions/{chainId}-register-assets.json`

If broadcasting directly (sender has MANAGER), assets are registered immediately. Otherwise, import the Safe TX JSON into Safe UI and execute via multisig.

### 5.4 Safe UI Transaction Builder workflow

If you're executing the queued Safe TX JSON (not broadcasting directly), this is the exact flow:

1. Open the per-chain Safe in Safe UI: `https://app.safe.global/home?safe=<chain_shortname>:<safe_address>` (chain shortnames per Safe: `eth` for Mainnet, `arb1` for Arbitrum, `base` for Base, `oeth` for Optimism, `gno` for Gnosis). Use the **governance Safe address from `chains/<id>.json.addresses.securityCouncil`** (`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`).
2. Apps → "Transaction Builder".
3. Click the JSON icon top-right → "Load batch" → select `safe-transactions/{chainId}-register-assets.json`.
4. The Builder parses each call. Review every row: contract address should be the **NAVCalculator proxy** from `deployments/<chainId>.json` (`NAVCalculatorProxy`), function should be `registerAsset(address,address,uint8,uint256)`, and the arguments should match `nav-config/assets-and-price-feeds/<chainId>.json` for the chain. **Don't skip this step** — the JSON is generated but not cryptographically tied to the config.
5. "Create Batch" → "Send Batch" → collect threshold signatures → execute.
6. After execution, run the verification commands in Phase 9.1 to confirm every intended asset is registered.

Same flow applies to `safe-transactions/{chainId}-configure.json` in Phase 6 and any `ManageAdapters.s.sol` output in Phase 7.

### 5.5 Repeat for all chains

Run the same script for each chain (42161, 8453, 10, 100).

---

## Phase 6: Add Balance Adapters to NAVCalculator

After balance adapters are deployed, they must be registered on NAVCalculator. `06_Configure.s.sol` reads `nav-config/balance-adapters/<chainId>.json` (plain) and `nav-config/meta-balance-adapters/<chainId>.json` (meta). Plain adapters register via `addBalanceAdapters(address[])`; meta-adapters register via `addMetaBalanceAdapter(address,instances)` and have their instance set reconciled with `addMetaInstances`/`removeMetaInstances`. Meta-vs-plain is detected on-chain via ERC165. This requires the MANAGER role.

### Option A: Use `06_Configure.s.sol` (Safe TX batch)

```bash
forge script script/deploy/06_Configure.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

Output: `safe-transactions/{chainId}-configure.json` — import into Safe UI.

### Option B: Use `ManageAdapters.s.sol` (individual Safe TXs)

Edit `ManageAdapters.s.sol` and uncomment `_addBalanceAdapter(adapterAddress)` calls:

```solidity
function run() public override {
    setUp();
    validateAddresses();
    _addBalanceAdapter(0x...); // adapter address from config
}
```

Then run:

```bash
forge script script/manage/ManageAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

### Option C: Direct broadcast (if sender has MANAGER)

Call `addBalanceAdapters()` directly on the NAVCalculator proxy using `cast`. **Read the proxy address from the deployments file** rather than hardcoding — the runbook's Canonical addresses table carries `TBD` for our contracts by design:

```bash
NAV_PROXY=$(jq -r '.NAVCalculatorProxy' script/config/deployments/1.json)

# Plain adapters (array arg)
cast send $NAV_PROXY \
  "addBalanceAdapters(address[])" "[<adapter_address>]" \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME

# Meta-adapters (adapter + initial instance set)
cast send $NAV_PROXY \
  "addMetaBalanceAdapter(address,bytes32[])" <meta_adapter_address> "[<instance>...]" \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME
```

---

## Phase 7: Add or Update Price Feeds on NAVCalculator

Custom price feed adapters (deployed in Phase 3) must be linked to their assets on NAVCalculator via `addPriceFeed()`. `registerAsset()` sets the first feed; use `addPriceFeed()` to append a second or third feed for redundancy, or after replacing an old adapter.

If you registered assets in Phase 5 with the correct Custom adapter addresses in `nav-config/assets-and-price-feeds/<chainId>.json`, the price feeds are already set. Only use this phase if you need to update or add feeds after initial registration.

To remove an old feed after replacing it: `removePriceFeed(asset, oldFeedAddress)` (MANAGER). Cannot remove the last remaining feed — add the replacement first.

### Using ManageAdapters.s.sol

```solidity
_addPriceFeed(
    0x...,  // asset address
    0x...,  // custom price adapter address (from Phase 3)
    IPrices.PriceType.Custom,
    3600    // heartbeat
);
```

### Using cast

```bash
NAV_PROXY=$(jq -r '.NAVCalculatorProxy' script/config/deployments/1.json)
cast send $NAV_PROXY \
  "addPriceFeed(address,address,uint8,uint256)" \
  <asset> <priceFeed> 1 3600 \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME
```

(PriceType: 0 = Chainlink, 1 = Redstone, 2 = API3, 3 = Custom)

---

## Phase 8: Contract Verification

### 8.1 Generate verification commands

```bash
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
```

> **Known limitation — hardcoded adapter list.** `VerifyEtherscan.s.sol` does **not** iterate the full `04_DeployBalanceAdapters.run()` inventory. It emits `forge verify-contract` commands only for the names in the hardcoded arrays inside `_emitVerifyBalanceAdapters` and `_balanceAdapterPathAndArgs` (today: `AaveV3_USDC/WETH`, `CompoundV3_USDC/WETH`, `SparkLend`, `SparkLend_USDC`, `MorphoBlue_USDC`, `DaiDsr`, `SkySavingsUsds`, `ERC20Default`). Adapters outside that list — including all 21 meta-adapters (`AaveV3InstancesMeta`, `MorphoMarketsMeta`, `AuraRewardsMeta`, `CurveGaugesMeta`, etc.), the standalone adapters, and the legacy per-instance keys — are silently skipped. When you add a new adapter type or instance, either extend the hardcoded arrays in `VerifyEtherscan.s.sol` or run `forge verify-contract` manually for that instance. Tracked as a follow-up in `docs/historical/adapter-migration-plan.md` ("Aspects to improve").

### 8.2 Run the printed commands

The script outputs ready-to-run `forge verify-contract` commands. Copy and run each one. Make sure the corresponding explorer API key is set in your environment.

### 8.3 Repeat for all chains

```bash
# Arbitrum
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Base
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Optimism
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

# Gnosis
forge script script/verify/VerifyEtherscan.s.sol \
  --rpc-url "https://gnosis-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
```

---

## Phase 9: Post-Deployment Validation

> **Setup once per chain.** All cast examples below use `$NAV_PROXY` and `$RPC` so they work for any chain (the Canonical addresses table carries `TBD` for our contracts — read the live address from the deployments file). Set both at the top:
>
> ```bash
> CHAIN_ID=1                 # 1 / 42161 / 8453 / 10 / 100
> RPC="https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"   # match the chain
> NAV_PROXY=$(jq -r '.NAVCalculatorProxy' script/config/deployments/$CHAIN_ID.json)
> echo "NAV_PROXY=$NAV_PROXY"   # sanity check — should be the address written by R.2 step 4
> ```

### 9.1 Verify on-chain state

For each chain, check:

```bash
# Check whether a specific asset is registered
cast call $NAV_PROXY \
  "isAssetRegistered(address)(bool)" <asset_address> \
  --rpc-url "$RPC"

# List all registered assets (returns Asset[] — address, symbol, price type, etc.)
cast call $NAV_PROXY \
  "getRegisteredAssets()" \
  --rpc-url "$RPC"

# Get detailed price feed data for an asset
# Returns PriceFeedData: (address priceFeed, uint8 priceType, int256 price, uint8 decimals,
#                        uint256 chainlinkHeartbeat, uint256 updatedAt, bool stale, bool sequencerDown)
cast call $NAV_PROXY \
  "getPriceData(address)" <asset_address> \
  --rpc-url "$RPC"
```

> **Note:** NAVCalculator inherits from `Balances`, which exposes balance-adapter registry getters. Use these for registration checks (all public, `view`):
>
> ```bash
> # All registered balance adapters
> cast call $NAV_PROXY "getAllAdapters()(address[])" --rpc-url "$RPC"
>
> # Is a specific adapter registered?
> cast call $NAV_PROXY "isAdapterRegistered(address)(bool)" <adapter> --rpc-url "$RPC"
>
> # Count of registered adapters
> cast call $NAV_PROXY "getAdapterCount()(uint256)" --rpc-url "$RPC"
>
> # Which adapters report an asset
> cast call $NAV_PROXY "getAdaptersForAsset(address)(address[])" <asset> --rpc-url "$RPC"
> ```
>
> Phase 9.3 below is for confirming a *registered* adapter returns plausible data, not for checking registration.

### 9.2 Test NAV calculation

```bash
# Get total NAV for a Safe in a given quote asset.
# Returns NAV struct: (int256 value, Asset quoteAsset, uint64 timestamp,
#                     Asset[] stalePriceAssets, bool sequencerDown)
cast call $NAV_PROXY \
  "getAccountNav(address,address)" <safe_address> <quote_asset_address> \
  --rpc-url "$RPC"
```

### 9.3 Verify each balance adapter returns data

```bash
# For each balance adapter, call the v2 interface (IBalanceAdapter)
cast call <adapter_address> \
  "getAdapterBalanceForAsset(address,address)(uint256,bool)" <safe_address> <underlying_asset> \
  --rpc-url <RPC_URL>

# Or enumerate every position the adapter reports for the Safe:
cast call <adapter_address> \
  "getAdapterPositions(address,address)" <safe_address> 0x0000000000000000000000000000000000000000 \
  --rpc-url <RPC_URL>
```

---

## Known Gaps to Address Before Deployment

> **Gaps 1–3 closed** by PRs [#11](https://github.com/karpatkey/onchain-accounting/pull/11) and [#12](https://github.com/karpatkey/onchain-accounting/pull/12) (merged 2026-04-17). The remaining gaps 4 and 5 do not block Alpha fund launch. Scope is limited to what the **ETH Alpha Fund** and **USD Alpha Fund** actually use — stale or unused v1 entries are intentionally excluded.

### 1. L2 price feed deploy functions — CLOSED

Closed in PR #11 (commits [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f) and [`2a9c0d7`](https://github.com/karpatkey/onchain-accounting/commit/2a9c0d7)). L2 deploy functions (`_deployWstEthL2`, `_deployWeEthL2`, `_deployRsEthL2`, `_deployEzEthL2`, `_deployCbEthL2`, `_deploySyrupUsdcL2`) are implemented and wired into `_deployArbitrumPriceAdapters`, `_deployBasePriceAdapters`, and `_deployGnosisPriceAdapters`. `_deploySxdai` added to Gnosis in the same PR.

### 2. Custom price feed config — CLOSED

Closed in PR #11 (commit [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f)). Every Custom price adapter used by ETH Alpha or USD Alpha has a `contracts-deployment-config/custom-price-feeds/<chainId>.json .<name>` entry with `enabled` and `constructor` params, and the consuming tokens (in `nav-config/assets-and-price-feeds/<chainId>.json`) reference it via a `priceFeeds[]` entry of `{ type: Custom, feed: <name> }`. Deployed addresses persist to `deployments/<chainId>.json` via `ConfigReader.writeAdapterAddress`.

### 3. `06_Configure.s.sol` and `04_DeployBalanceAdapters.s.sol` alignment — CLOSED

Closed in PR #12 (commit [`2a75423`](https://github.com/karpatkey/onchain-accounting/commit/2a75423)). `06_Configure.s.sol` was rewritten around a shared `_balanceAdapterNames()` helper that matches the 43 adapter names deployed by `04`. No more MorphoBlue_USDC ghost reference; all 10 new adapters from PR #12 are included.

### 4. Bridge adapters — partial per-chain coverage

Intended per-chain enablement (deployed addresses are written to `deployments/<chainId>.json` on broadcast; all are `TBD` until then):

| Chain | Enabled | Deployed |
|---|---|---|
| Mainnet (1) | CCIP, Across, Stargate, CCTP — all `enabled: false` | TBD |
| Arbitrum (42161) | CCIP, Across, Stargate, CCTP | TBD |
| Base (8453) | Superchain, Across, Stargate, CCTP | TBD |
| Optimism (10) | Superchain, CCTP | TBD |
| Gnosis (100) | Gnosis bridge — `enabled: false` | TBD |

Bridge adapters exist to account for funds in-flight between chains (outbound: bridged-out USDC sitting in a Safe on source chain + inbound ERC20 on destination chain pending claim). Without them, NAV under-reports during an inflight bridge. Each adapter implements `IBridgeAdapter` and is registered on `BridgeEscrow` via `AuthorizeBridgeAdapters.s.sol` (or Safe TX batch from `06_Configure.s.sol`).

**Does not block Alpha fund launch** — Alpha funds bridge inbound to Arbitrum and outbound from Base, both covered. Deploy on Optimism + Mainnet before using those chains as bridge sources. Gnosis doesn't have a cross-chain bridge product yet; its entry is a placeholder.

Use `05_DeployBridgeAdapters.s.sol` to deploy. Bridge-adapter config (`enabled` + `initialize` args + optional `callbackSelector`, keyed by adapter name) is read from `script/config/contracts-deployment-config/bridge-adapters/<chainId>.json` — **not** from `chains/<chainId>.json`, which no longer carries a `bridgeAdapters` block. Re-run safety is the same as `03`/`04` — already-deployed entries are skipped.

### 5. Native xDAI coverage on Gnosis — deferred

`ERC20Default` is registered on Gnosis with the xDAI sentinel address (`NATIVE_ADDRESS`) pre-inserted at NAVCalculator init, but no fork test confirms that `getAdapterBalanceForAsset(NATIVE_ADDRESS, safe)` returns the correct native balance. USD Alpha Fund uses native xDAI on Gnosis. Verify with a fork test against a Safe holding xDAI before the Gnosis deployment goes live. Not blocking pre-deployment.

---

## Quick Reference: Deployment Order

```
Phase R: Redeploying proxies (from-scratch redeploy) -- one-time
         (REQUIRED — all past deployments wiped; deploy fresh impls +
         proxies (new bytecode); admin/manager set to the governance
         Safe; addresses written to deployments/<chainId>.json. Keep
         existing CREATE2 salts unless a prior proxy is still live (bump
         the salt version then). See "Redeploying proxies" section above.)
    |
    v
Phase 0: Prerequisites (merge PRs, env setup, run tests)
    |
Phase 1: Configure custom price feeds in contracts-deployment-config/custom-price-feeds/<id>.json
         + assets in nav-config/assets-and-price-feeds/<id>.json
Phase 2: Configure balance adapter deploy params in
         contracts-deployment-config/balance-adapters/<id>.json (plain) +
         contracts-deployment-config/meta-balance-adapters/<id>.json (meta) + NAV registration in
         nav-config/balance-adapters/<id>.json + nav-config/meta-balance-adapters/<id>.json
    |   (these two can be done in parallel)
    v
Phase 3: Deploy price feed adapters (03_DeployPriceFeeds.s.sol) -- per chain
         (OFTEN SKIPPED — see "When this phase is needed" above. If every
         enabled adapter has a working fund-side v1 deployment already
         referenced by a token's priceFeeds[].address in
         nav-config/assets-and-price-feeds/<id>.json, this phase is
         redundant; flip enabled: false instead.)
Phase 4: Deploy balance adapters (04_DeployBalanceAdapters.s.sol) -- per chain
    |   (Phase 4 is independent of Phase 3 / Phase 5 — pure contract deploys,
    |   no NAVCalculator interaction)
    v
Phase 5: Register assets on NAVCalculator (RegisterAssets.s.sol) -- per chain
         (THE on-chain wiring step for prices — fills priceOracles[asset]
         mapping. nav-config/assets-and-price-feeds/<id>.json is the source
         data; runtime reads from this on-chain mapping.)
Phase 6: Add balance adapters to NAVCalculator (Path A: 06_Configure Safe TX batch
         | Path B: 06_Configure direct broadcast) -- per chain
    |   (5 and 6 can be batched into one Safe TX on Path A; both must
    |   complete before getAccountNav works at runtime. Path B uses
    |   06_Configure.s.sol — broadcast from EOA, idempotent;
    |   then 07_TransferAdminToSecurityCouncil.s.sol transfers admin+manager to Safe.)
    v
Phase 7: Set custom price feeds (if not done in Phase 5) -- per chain
    |
Phase 8: Verify contracts on block explorers -- per chain
Phase 9: Post-deployment validation -- per chain
```

---

## Rollback

- **Price feeds and balance adapters are NOT upgradeable** — they're standalone contracts. To "rollback", deploy a corrected version and update the NAVCalculator to point to the new one via `addPriceFeed()` + `removePriceFeed()` / `removeBalanceAdapter()` + `addBalanceAdapters()`. Both are MANAGER-only.
- **NAVCalculator and BridgeEscrow ARE upgradeable** (UUPS). Use `script/upgrade/UpgradeNAVCalculator.s.sol` or `UpgradeBridgeEscrow.s.sol`. Requires DEFAULT_ADMIN_ROLE on the target proxy — i.e. the governance Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` after the redeploy (see §"Roles and governance").
- **Partial deploys are re-runnable.** `03_DeployPriceFeeds.s.sol` and `04_DeployBalanceAdapters.s.sol` both read the per-adapter entry in `deployments/<chainId>.json` and skip any entry already populated. If a broadcast runs out of gas halfway, top up the EOA and re-run — the script will continue from where it stopped.

---

## Troubleshooting

### "Unknown adapter type" in the `04_DeployBalanceAdapters.s.sol` output

The dispatcher routes by prefix (e.g. `AaveV3_`, `MorphoVault_`) with exact-match fallbacks for the single-instance adapters `Cap`, `DaiDsr`, `SkySavingsUsds`, and `SparkLend`. If you see `Unknown adapter type: <Name>`, either your config entry name doesn't match a prefix or exact-match case — fix by adding the missing branch in `_deployAdapter`. When adding a new single-instance adapter, add an `_equals(adapterName, "<Name>")` branch alongside the existing prefix branch, following the `SparkLend` pattern:

```solidity
if (_equals(adapterName, "SparkLend") || _startsWith(adapterName, "SparkLend_")) {
    return _deploySparkLend(adapterName, navCalculator);
}
```

`_deployIfEnabled` silently treats a fall-through as a no-op (returns `address(0)` and skips the config write) — watch the console output for the `Unknown adapter type:` line.

### `PriceFeedNotSet(<asset>)` revert during `getAccountNav`

The asset is registered in NAVCalculator, but no price feed is linked. Happens when Phase 5 registered the asset with an empty `priceFeeds` list. Fix: call `addPriceFeed(asset, priceFeed, priceType, heartbeat)` via Phase 7.

### Every asset flagged `stale: true`

Check `chainConfig.chainlinkSequencerFeed`. On L2s, `checkL2SequencerUptime()` ORs into every price's stale flag — if the sequencer uptime feed is misconfigured (wrong address or not set during `NAVCalculator.initialize`), every price reads stale. On L1 it should be `address(0)`.

### `getAccountNav` reverts with `AssetNotFound()`

A balance adapter returned a `PositionBalance` for an underlying asset that isn't registered on NAVCalculator. Either register the asset (Phase 5) or fix the adapter to stop returning it.

### Chainlink feed shows `answer <= 0`

NAV v2 returns `(0, decimals, true)` for any Chainlink answer ≤ 0 (`src/prices/Prices.sol:70-72`). The asset contributes 0 to NAV and is flagged stale. Usually indicates a broken feed or one that just reverted; check `latestRoundData()` directly and contact the adapter provider.

### `forge script` fails with `vm.writeJson: no such key`

Foundry's `vm.writeJson` requires the parent object to exist. `ConfigReader.writeAdapterAddress` writes deployed addresses to `deployments/<chainId>.json` — make sure that file exists with at least an empty top-level object `{}` (the script creates per-adapter keys, but cannot create the file/root if missing). If the run **reverts** with `vm.writeJson: no such key`, pre-seed the `deployments/<chainId>.json` root before re-running.

### Role misconfiguration

If `hasRole(DEFAULT_ADMIN_ROLE, <deployer EOA>) == true` after `02_DeployProxies.s.sol`, that's a red flag — the deployer should retain no ongoing roles. Investigate before running Phases 3-7. If `hasRole(MANAGER, <safe>) == false`, the `grantRole(MANAGER, ...)` step in `02_DeployProxies.s.sol` (or `06_Configure.s.sol`) didn't execute or hasn't been executed yet — re-run or generate a Safe TX.

### `02_DeployProxies.s.sol` reverts at `grantRole(MANAGER, ...)` — historical (FIXED in `d513f27`)

This used to happen when `chainConfig.admin` was a Safe and the deployer EOA lacked `DEFAULT_ADMIN_ROLE`. As of `d513f27` the grant happens inside `AtomicProxyDeployer`'s constructor (where the deployer transiently holds admin) and the post-constructor block was removed, so this revert path no longer exists in the atomic flow. If you see it: you're running pre-`d513f27` code or `USE_LEGACY_DEPLOY=1`. For the legacy path: have the admin Safe execute `grantRole(MANAGER, <ManagerSafe>)` on both proxies via a Safe TX batch.

### `forge verify-contract` fails with "Already verified"

Not actually a failure — Etherscan caches verified bytecode by hash. You can skip or pass `--watch` to just confirm.

---

## How to add a new Custom price oracle

Workflow for a brand-new adapter after the migration PRs are merged. Each step has a canonical reference file — mirror it.

1. **Write the adapter** under `src/prices/protocols/<Name>_Price.sol`. Inherit `IPriceFeedCustom` (8-decimal USD output, `(uint256 price, bool stale)` return). Reference: `sDAI_Price.sol` for a simple ERC4626-style feed, `weETH_Price.sol` for a two-hop Chainlink composition.
2. **Write the unit test** under `test/prices/protocols/<Name>_Price.t.sol`. Minimum: constructor revert coverage for every invalid-argument path.
3. **Write the fork test** under `test/prices/protocols/fork/<Name>_Price.fork.t.sol`. Pin a block, assert an exact price value, exercise the stale path by warping `block.timestamp` past the heartbeat.
4. **Register the deploy config** in `contracts-deployment-config/custom-price-feeds/<chainId>.json .<Name>` with `enabled: true` and all constructor params, and reference it from the consuming token's `priceFeeds[]` (in `nav-config/assets-and-price-feeds/<chainId>.json`) via `{ type: Custom, feed: <Name> }`. Make sure `deployments/<chainId>.json` exists (at least `{}`) so `ConfigReader.writeAdapterAddress` has a file to write the deployed address to.
5. **Wire into `03_DeployPriceFeeds.s.sol`**: add `import {...}` at top, add `_deployIfEnabled`-style dispatch inside the correct `_deploy<Chain>PriceAdapters()` function, add a `_deploy<Name>()` helper that reads constructor params via `ConfigReader.readPriceFeedParam` and writes back via `ConfigReader.writeAdapterAddress`. Reference: `_deploySdai` in the same file.
6. **Run tests locally**: `forge test --match-path "test/prices/protocols/<Name>*"` must pass before pushing.
7. **Register the asset with the new price feed**. If the asset is already registered on NAVCalculator with a Chainlink feed, call `addPriceFeed(asset, newFeed, PriceType.Custom, heartbeat)` (Phase 7) via Safe, then remove the old feed with `removePriceFeed(asset, oldFeed)`. Otherwise, register from scratch in Phase 5.
8. **Point the token's `priceFeeds` entry at the new adapter.** Set the relevant feed in `nav-config/assets-and-price-feeds/<chainId>.json .<Symbol>.priceFeeds` to `{ "type": "Custom", "feed": "<Name>", "heartbeat": ... }` (the address is resolved from `deployments/<chainId>.json` by `feed` name), so future `RegisterAssets.s.sol` runs (if you unregister + re-register) use the right feed.

---

## How to add a new balance adapter

Workflow for adding a new protocol adapter or a new instance of an existing protocol.

**New instance of an existing protocol (e.g. a new Curve pool):**

1. Add a deploy config entry to `contracts-deployment-config/balance-adapters/<chainId>.json .Curve_<pool>` with the constructor param (`gauge`) (deployed address is written to `deployments/<chainId>.json` on broadcast). For a new gauge on the existing `CurveGaugesMeta`, instead add the gauge address to `CurveGaugesMeta.instances` in `nav-config/meta-balance-adapters/<chainId>.json`.
2. Add `_deployIfEnabled("Curve_<pool>")` inside `04_DeployBalanceAdapters.s.sol`'s `run()` function.
3. Add `"Curve_<pool>"` to `_balanceAdapterNames()` in `06_Configure.s.sol`, and the matching key in `nav-config/balance-adapters/<chainId>.json` (or `nav-config/meta-balance-adapters/<chainId>.json`).
4. Run `forge build` + `forge test` to confirm nothing regressed.
5. Deploy (Phase 4) and add to NAVCalculator (Phase 6).

**New protocol entirely (e.g. a new yield primitive):**

1. **Write the adapter** under `src/balances/protocols/<Protocol>.sol`. Inherit `IBalanceAdapter` — must implement `getAdapterPositions`, `getAdapterBalances`, `getAdapterBalanceForAsset`, `underlyingAssetsSupported`, and `supportsInterface`. Reference: `MorphoVault.sol` for a single-asset vault, `Convex.sol` for a multi-reward-token protocol.
2. **Write the unit test** under `test/balances/protocols/<Protocol>.t.sol`. Cover: constructor, `underlyingAssetsSupported`, zero balance, non-zero balance, asset filter.
3. **Write the fork test** under `test/balances/protocols/fork/<Protocol>.fork.t.sol`. Cover: real on-chain position, real reward accruals, asset filter at a pinned block.
4. **Add to `AdapterConsistency.t.sol`** if the protocol has non-trivial edge cases the existing cross-adapter invariants don't cover (zero balance handling, debt positions, asset filter).
5. **Import + dispatch in `04_DeployBalanceAdapters.s.sol`**: add `import`, add `_deployIfEnabled("<Protocol>_<Instance>")` to `run()`, add a `_startsWith(adapterName, "<Protocol>_")` branch in `_deployAdapter`, and a `_deploy<Protocol>()` helper that reads params.
6. **Add to `06_Configure.s.sol._balanceAdapterNames()`.**
7. **Add config entries:** deploy config in `contracts-deployment-config/balance-adapters/<chainId>.json` (plain) or `contracts-deployment-config/meta-balance-adapters/<chainId>.json` (meta), plus the NAV registration key in `nav-config/balance-adapters/<chainId>.json` (plain) or `nav-config/meta-balance-adapters/<chainId>.json` (meta, with `instances`/`instancesRaw`).
8. **Run full test suite.** `forge test` non-fork + fork must both be green before pushing.
9. **Deploy + register on NAV** via Phases 4 and 6.

> **Naming rule:** new balance adapter files use PascalCase. Meta-adapters (one contract per protocol covering many instances) use the `MetaBalanceAdapter` suffix (e.g. `AuraRewardsMetaBalanceAdapter`, `MorphoVaultsMetaBalanceAdapter`); per-instance singletons use descriptive names (e.g. `SparkLendBalanceAdapter`, `AaveV3SafetyModuleBalanceAdapter`). The `balanceOf` parameter must be named `account` (enforced pattern, not `safe`).

---

## Maintaining this runbook

Every time you:
- Change anything in `02_DeployProxies.s.sol`, `03_DeployPriceFeeds.s.sol`, `04_DeployBalanceAdapters.s.sol`, `05_DeployBridgeAdapters.s.sol`, or `06_Configure.s.sol`,
- Add a new adapter family,
- Hit a gotcha that burned a deployment,
- Change the role-granting flow or `chainConfig.admin`/`manager`,

update the corresponding section here in the same PR. This runbook only stays trustworthy if it's kept in lockstep with the code it describes.
