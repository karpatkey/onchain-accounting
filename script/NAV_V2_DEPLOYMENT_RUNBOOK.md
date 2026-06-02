# NAV v2 Deployment Runbook

> **⚠️ Deployment is now EOA-only.** A single deployer EOA runs every step with `--broadcast`; no Safe executes deploy/config txs. "Path A (Safe-TX bundles)" below is superseded — use the EOA path only. `06_Configure.s.sol` no longer exists (folded into `06_Configure.s.sol`, which now broadcasts `addBalanceOracle` + `setMetaInstances` + bridge authorization directly). The final step is `07_TransferAdminToSecurityCouncil.s.sol`, which hands `DEFAULT_ADMIN_ROLE` + `MANAGER` on **both** the NAV and Bridge proxies to `addresses.securityCouncil` and renounces the deployer's roles. See `script/deploy/README.md` for the authoritative, current procedure.

Step-by-step operational guide for deploying the NAV v2 system — NAVCalculator, BridgeEscrow, price oracles, balance oracles, bridge adapters — to any supported chain. This runbook is the source of truth for every NAV v2 deployment going forward, regardless of which fund (ETH Alpha, USD Alpha, kUSDprime, kREN, or any future fund) the deployment supports.

**Companion docs:**
- [`DEPLOYMENT_SUMMARY.md`](DEPLOYMENT_SUMMARY.md) — architectural overview (CREATE2, atomic proxy deploy, Safe multisig control). Read first if you're new to the system.
- [`docs/historical/oracle-migration-plan.md`](../docs/historical/oracle-migration-plan.md) — historical record of the v1 → v2 oracle migration, plus known follow-up improvements. Read if you want to understand why a particular oracle looks the way it does. Archival; for current ops, use this runbook.

**When you use this runbook:**
1. Deploying NAV v2 to a new chain for the first time.
2. Deploying additional price or balance oracles to an already-live chain.
3. Registering new assets on a live NAVCalculator.
4. Rotating MANAGER/DEFAULT_ADMIN roles.
5. Validating an existing deployment.

**Maintenance note:** keep this runbook current. Every time you change a deploy script, add a new adapter family, or hit a gotcha worth preserving, update the corresponding section and open a PR.

---

## System overview

> **Note on addresses in this runbook.** Concrete addresses cited below (`0x5a0b28e1...4f54C6` for NAVCalculator proxy, `0x1ECAEa1C...8A19` for BridgeEscrow proxy, `0xc07C9996...EBA21C` for ERC20Default) are the **salt-v2 test deployment** done in 2026-02. They are kept here for documentation continuity and as concrete examples in `cast` snippets. After the production **salt-v3 redeploy** (see "Redeploying proxies" below), substitute the new addresses from `script/config/chains/<chainId>.json.deployed.NAVCalculatorProxy` / `.BridgeEscrowProxy` / per-chain ERC20Default. The redeploy happens once; from that point the chain configs are the source of truth.

NAV v2 is a single, chain-local system. Each supported chain has:

- **One NAVCalculator proxy** (UUPS) at the same canonical address on every chain (test deploy: `0x5a0b28e1470Ef313f546466C37fD2cb83b4f54C6`). Any Safe can call `getAccountNav(safe, quoteAsset)` and get its NAV in USD or any registered quote asset.
- **One BridgeEscrow proxy** (UUPS) at `0x1ECAEa1C69c5A0b12139d44E6b7345D71FE68A19` (test deploy). Tracks outbound/inbound bridge liquidity that would otherwise be invisible to the NAV.
- **One default ERC20 balance adapter** at `0xc07C999644D8A3A5e57B835Aa460016b89eBA21C` (test deploy) — reports plain wallet balances for every registered ERC20 + the native coin.
- **N custom price feed adapters** — one per Custom-priced asset. Implements `IPriceFeedCustom.getLatestPrice()`.
- **N custom balance adapters** — one per protocol position (Aave V3 Core, Morpho vault, Curve gauge, etc.). Implements `IBalanceOracleAdapter.getOraclePositions()` / `getOracleBalances()` / `getOracleBalanceForAsset()`.

The NAVCalculator routes price lookups through an embedded `Prices` contract (Chainlink or Custom per asset) and position lookups through the registered balance oracles. Both are pluggable by adding/removing adapters — the proxy never needs to be upgraded to add new protocols.

**Key invariant:** the Safe's NAV is the sum of signed `(amount * price / quote_price)` across every `PositionBalance` returned by every registered balance oracle, plus the inflight bridged-out escrow balance. No oracle can lie about another oracle's asset — positions are keyed on `(oracle, underlyingAsset)` tuples.

---

## Roles and governance

NAVCalculator and BridgeEscrow both use OpenZeppelin `AccessControlUpgradeable` with two roles:

| Role | Code (constant) | What it gates |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000…0000` | UUPS upgrades (`_authorizeUpgrade`), grant/revoke any role, `setChainlinkL2SequencerUptimeFeed` |
| `MANAGER` | `keccak256("MANAGER")` | `registerAsset`, `addPriceFeed`, `removePriceFeedAt`, `removePriceFeed`, `addBalanceOracle`, `removeBalanceOracle`, `unregisterAsset`, `excludeAssetFromDefaultOracle`, `includeAssetInDefaultOracle`, `setChainlinkL2SequencerGracePeriod` |

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

**Current on-chain state (audited 2026-04-28).** Every chain config sets `addresses.admin = addresses.manager = 0x00008bB2Ff12ca49eD157B21a0D955c63C9ab31F`. The runbook originally treated this as a Safe; `cast code` on all 5 chains returns `0x` — it's actually an **EOA**. The address holds both `DEFAULT_ADMIN_ROLE` and `MANAGER` on the salt-v2 proxies on every chain, so a single private key controls the entire NAV v2 control plane on the test deploy. This is **not production-acceptable**; before launch the proxies must be redeployed with admin/manager set to a real per-chain Safe (see "Redeploying proxies (production fresh-start)" below).

**MANAGER-grant bug — FIXED in commit `d513f27` (2026-04-29).** The atomic path now grants MANAGER inside `AtomicProxyDeployer`'s constructor (where the deployer transiently holds `DEFAULT_ADMIN_ROLE`), so it works regardless of whether `chainConfig.admin` is an EOA or a Safe. The same commit also makes the deployer self-renounce its admin role at constructor end, closing the orphaned-admin cosmetic issue. The legacy path no longer attempts the grant from the deployer EOA — it logs a warning that MANAGER must be granted via Safe TX from the admin. **No workaround is required for tonight's redeploy.** Historical context: between 2026-04-20 and 2026-04-29 this was a blocking deploy bug with three documented workarounds in this runbook; PR #14's caveat callouts described those workarounds. They are now obsolete; flag remaining mentions for cleanup but do not act on them.

**Steady-state convention (target, not current).** `chainConfig.admin` and `chainConfig.manager` should point to the **same per-chain Safe multisig** (the "OIV Safe"). Deployer EOA pays gas at deploy time and retains no ongoing NAV powers. The current chain configs name this address `0x00008bB2Ff12ca49eD157B21a0D955c63C9ab31F`, which **is the EOA from the test deploy** — convention not yet reached. The redeploy is what gets us there.

**Why this matters (v1 precedent).** `karpatkey-tokenized-fund` ETH Alpha STAGE's NAVCalculator v1 ended up with MANAGER stuck on the deployer EOA and no `DEFAULT_ADMIN_ROLE` holder at all — leaving it upgrade-locked and requiring a full redeploy. NAV v2's access-control design is safer, and since `d513f27` the role grants are atomic with proxy initialization. Always run the post-deploy role validation below regardless — defence in depth.

**Post-deploy role validation** (run for every chain, every time you deploy):

```bash
CHAIN_ID=1   # 1 / 42161 / 8453 / 10 / 100
NAV_PROXY=$(jq -r '.deployed.NAVCalculatorProxy' script/config/chains/$CHAIN_ID.json)
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

> **STATUS — production NAV v2 is live on all 5 chains since 2026-04-30** (PR #15). Admin + manager on every NAV proxy held by the OIV Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` (5/N threshold, same address on every chain, verified). Deployer EOA holds no privileged role anywhere. **Full per-chain inventory of every deployed address (price-feed adapters, balance adapters, etc.) lives in [`DEPLOYED_ADDRESSES.md`](./DEPLOYED_ADDRESSES.md).** The salt-v2 test-deploy NAV/Bridge proxies (referenced in earlier `cast` snippets in this runbook below) remain on-chain but are orphan deployments — chain configs and downstream consumers point at the salt-v3 production proxy.

### NAV v2 — production (salt v2 impl, salt v3 proxy)

| Component | Address | Chains |
|-----------|---------|--------|
| NAVCalculator Implementation | `0xc572dd1F36E50E9b9551838df8916Ac81200af62` | Same on all 5 chains (CREATE2). |
| NAVCalculator Proxy (CREATE2, salt v3) | `0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19` | Same on all 5 chains. The address every consumer should use. |
| ERC20Default Balance Adapter | `0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39` | Same on all 5 chains (auto-deployed in `NAVCalculator.initialize`). |
| `UUPSPlaceholder` impl (salt v3) | `0xE8CfE5bCD2dC7e8cBF5eF2B5cf8bD8EE259A4953` | Same on all 5 chains. Used transiently during atomic deploy. |
| OIV Safe (admin + manager on every NAV proxy) | `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` | Same on all 5 chains. |

### Bridge — salt-v2 test deploy (still in `chains/<id>.json.deployed.BridgeEscrow*`)

| Component | Address | Chains |
|-----------|---------|--------|
| BridgeEscrow Implementation | `0x50FE322E01eB7e537418D6C90ea586063260454D` | Mainnet, Arbitrum, Base, Gnosis. Optimism uses `0xB9330561EA35a7643A95b68D8A70fA6D6c004773`. |
| BridgeEscrow Proxy (CREATE2, **salt v2 — test deploy**) | `0x1ECAEa1C69c5A0b12139d44E6b7345D71FE68A19` | All 5 |

> Bridge was not part of the NAV v2 production redeploy (PR #15) since the OIVs in scope don't yet need it. When BridgeEscrow is required for production, repeat the same Phase R pattern: bump bridge salt, deploy new proxy via atomic deployer, hand off roles to the OIV Safe.

> **Source of truth for per-chain deployed addresses:** the `deployed` object inside `script/config/chains/<chainId>.json` (i.e. the `.deployed` top-level JSON key, not a separate `*.deployed` file). Never rely on abbreviated addresses — always copy the full value from the per-chain config for any chain-specific implementation exception (currently only Optimism).

All deployed adapter addresses are persisted in the per-chain config:
- Bridge adapters → `chains/<id>.json.bridgeAdapters.<name>.deployed`
- Price feed adapters → `chains/<id>.json.priceFeeds.<name>.deployed`
- Balance adapters → `chains/<id>.json.balanceAdapters.<name>.deployed`

`assets.json.priceFeeds` holds constructor/config inputs only — it does **not** store deployed addresses. `ConfigReader.writeAdapterAddress` always writes to `chains/<chainId>.json`, regardless of adapter type.

> **Querying current deploy state.** To see what's actually deployed on each chain at any point: look at the `deployed` field of every adapter entry in `chains/<id>.json`. Empty string = not yet deployed. This runbook is the process; the configs are the source of truth for state.

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

Use this section when the existing proxies were a **test deployment** (admin/manager held by an EOA, unverified roles, or any other reason to start clean) and you need fresh proxies with proper Safe-controlled roles.

**Implementations stay; only proxies redeploy.** The NAVCalculator and BridgeEscrow implementation contracts (already deployed at the canonical addresses in the previous section) can be reused — they're current source code (NAV unchanged since deploy; Bridge has cosmetic source drift but no breaking interface changes for Phase 4-9 use). New proxies pointing at existing implementations is the cheapest, lowest-risk redeploy.

> **CREATE2 collision avoidance.** The existing proxies were deployed with `generateSalt("NAVCalculatorProxy", 2)` / `("BridgeEscrowProxy", 2)` / `("ProxyPlaceholderImpl", 2)` (the trailing `2` is a version number). Calling `02_DeployProxies.s.sol` again with the same salts would collide (CREATE2 cannot redeploy at an occupied address). **Bump the version to `3`** in `script/deploy/02_DeployProxies.s.sol` lines 33, 40, 44 to derive fresh addresses on every chain.

### R.1 Prerequisites

- [ ] **Confirm target Safe address.** This Safe will hold `DEFAULT_ADMIN_ROLE` + `MANAGER` on both proxies after the redeploy. Ideally the same Safe address on all 5 chains (Safe Protocol's `SafeProxyFactory.createProxyWithNonce(...)` with a deterministic nonce + initializer can give matching addresses; coordinate with the Safe deploy team if not yet provisioned). Verify per chain with `cast call <SafeAddr> "getThreshold()(uint256)" --rpc-url <RPC>` — should return a positive integer (and code present).
- [ ] **Decide which Safe address goes in `chainConfig.admin` vs `chainConfig.manager`.** Recommended: same Safe in both, per the runbook's steady-state convention.
- [ ] **Salt v2 → v3 bump applied in code.** ⚠ As of 2026-04-29 this is **NOT YET DONE**. `script/deploy/02_DeployProxies.s.sol:32,39,43`, `script/deploy/AtomicProxyDeployer.sol:29,33,37`, `script/deploy/02_2_DeployNAVProxy.s.sol:32,37`, and `script/deploy/AtomicNAVProxyDeployer.sol:27,31` all still use `uint256(2)`. Broadcasting against the salt-v2 test deploy without bumping will hit a CREATE2 collision (placeholder + proxies are already at the v2 addresses) — the atomic deployer's `code.length == 0` guards will skip the deploys, and the subsequent `upgradeToAndCall` will revert because the v2 proxy is admin'd by the EOA, not by the new `AtomicProxyDeployer`. **Bump all 4 files to `3` before R.2 step 4.** Exact line numbers in R.2 step 1 below.
- [ ] **MANAGER-grant bug** — already fixed in commit `d513f27` (atomic path grants MANAGER + self-renounces admin inside `AtomicProxyDeployer`'s constructor). No workaround needed for tonight's redeploy. Legacy path (`USE_LEGACY_DEPLOY=1`) still requires a Safe TX from the admin to grant MANAGER; if you need legacy, plan that handoff separately.
- [ ] **Deployer EOA gas funded on all 5 chains.** Rule of thumb: 0.05 ETH on Mainnet, 0.01 ETH-equivalent on each L2/Gnosis. `02` uses CREATE2 + UUPS upgrade-and-init, ~600k gas per chain.
- [ ] **Per-chain `.env` keys present:** `ALCHEMY_API_KEY`, `DEPLOYER_NAME` (Foundry keystore account name; import once with `cast wallet import $DEPLOYER_NAME --interactive`). For Path B (EOA-then-handoff) also `DEPLOYER_EOA` (= `cast wallet address --account $DEPLOYER_NAME`).
- [ ] **All tests green** on the branch you're deploying from. `forge test` non-fork = 716+ passing (latest run confirmed this 2026-04-29 post-`d513f27`).

#### About the MANAGER-grant bug — historical (FIXED in `d513f27`)

This subsection used to describe the deploy bug + three workaround options and was load-bearing between 2026-04-20 and 2026-04-29. Since commit `d513f27` (2026-04-29) the bug is fixed in code: `AtomicProxyDeployer`'s constructor now grants `MANAGER` to `chainConfig.manager` while it still holds `DEFAULT_ADMIN_ROLE`, then self-renounces admin (eliminating the orphaned-admin cosmetic issue at the same time). The post-constructor `grantRole(MANAGER, ...)` block at the old `02_DeployProxies.s.sol:179-183` was removed.

**No workaround is needed.** The atomic path now works cleanly regardless of whether `chainConfig.admin` is an EOA or a Safe. If you're using `USE_LEGACY_DEPLOY=1`, the legacy path logs a warning at deploy time that MANAGER must be granted via Safe TX from the admin afterwards — handle that separately.

If you're reading historical PR comments or older PR #14 versions that describe the three-option decision matrix, those are obsolete. Current decision: just use the default atomic path.

### R.2 Step-by-step

1. **Patch the salt version.** Edit `script/deploy/02_DeployProxies.s.sol`:
   ```solidity
   bytes32 saltPlaceholder = generateSalt("ProxyPlaceholderImpl", 3);  // was 2
   ...
   bytes32 saltNavProxy    = generateSalt("NAVCalculatorProxy",    3);  // was 2
   ...
   bytes32 saltBridgeProxy = generateSalt("BridgeEscrowProxy",     3);  // was 2
   ```
   Compute the new addresses locally (`forge script` will print them in dry-run before broadcasting) — these are the **new canonical proxy addresses** going forward.

2. ~~Patch the MANAGER-grant bug~~ — already fixed in `d513f27`. Skip this step on a salt-v3+ deploy. Verify the atomic path is current by checking `AtomicProxyDeployer.sol` constructor signature includes `address managerToGrant`; if so, no patch needed.

3. **Update each `script/config/chains/<id>.json`:**
   - Set `addresses.admin` and `addresses.manager` to: **Path A** the target Safe address; **Path B** `$DEPLOYER_EOA` (to be transferred to the Safe by `07_TransferAdminToSecurityCouncil.s.sol` after Phase 6).
   - Clear `deployed.NAVCalculatorProxy` and `deployed.BridgeEscrowProxy` (set to `""`). The script writes new ones after broadcast.
   - Clear `balanceAdapters.ERC20Default.deployed` and `balanceAdapters.ERC20Default.constructor.navCalculator` — both reference the salt-v2 stale addresses. New values will come from the salt-v3 deploy.
   - Leave `deployed.NAVCalculatorImplementation` and `deployed.BridgeEscrowImplementation` populated — these are reused. Confirm they match the canonical addresses table above for your chain.

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
   Expected per chain: 3 CREATE2 transactions (placeholder, NAV proxy, Bridge proxy) + 2 UUPS upgrade-and-init transactions. The script writes the new proxy addresses into `chains/<chainId>.json.deployed.*`.

5. **Final handoff:** after Phase 6 completes (oracles registered + meta-instances set + bridge adapters authorized via `06_Configure.s.sol`), run `07_TransferAdminToSecurityCouncil.s.sol` to grant DEFAULT_ADMIN_ROLE + MANAGER to `addresses.securityCouncil` on **both** the NAV and Bridge proxies and renounce the deployer EOA's roles.

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

7. **Update `chains/<chainId>.json.deployed`** for the per-chain ERC20Default Balance Adapter address — this gets re-deployed during `NAVCalculator.initialize()`, so the new proxies will have a different ERC20Default address than the old `0xc07C999644...EBA21C`. Read the new address from the broadcast logs (`02_DeployProxies.s.sol` logs `ERC20Default oracle (from NAV init): 0x...`) or query the proxy directly via the public getter: `cast call <NAV_PROXY> "erc20DefaultOracle()(address)" --rpc-url <RPC>`. Note: if you broadcast `02_DeployProxies` with `PERSIST_DEPLOYMENTS=1` set, the script writes `balanceAdapters.ERC20Default.deployed` for you — verify in the diff before committing.

8. **Update the "Canonical addresses" table** at the top of this runbook with the new proxy + ERC20Default addresses. Bump the verification date.

9. **Update `docs/historical/oracle-migration-plan.md`** "Aspects to improve" — the `02_DeployProxies` MANAGER-grant bug entry should be marked as fixed in `d513f27` (already past tense in this runbook; align the historical plan to match).

10. **Optionally clean up the orphaned `AtomicProxyDeployer` admin role.** From the new constructor logs, find the `AtomicProxyDeployer` address(es) deployed on each chain. Issue a Safe TX:
    ```
    NAVCalculator.revokeRole(DEFAULT_ADMIN_ROLE, <AtomicProxyDeployer>)
    BridgeEscrow.revokeRole(DEFAULT_ADMIN_ROLE, <AtomicProxyDeployer>)
    ```
    Cosmetic — that contract has no callable functions to abuse the role with.

11. **Continue with Phase 4** (deploy balance adapters), then Phase 5+6 (Safe TX batch from the new admin Safe), Phase 8 (verification), Phase 9 (validation).

### R.3 What about the OLD proxies?

The salt-v2 proxies stay on-chain at `0x5a0b28e1...4f54C6` and `0x1ECAEa1C...8A19`. They retain the EOA-as-admin/manager state. **Nothing functional uses them after this redeploy** — chain configs point at the new salt-v3 addresses, and any downstream consumer (Shares contract, monitoring) reads from the chain configs. The old proxies remain as orphan deployments. If you want belt-and-braces hygiene, the EOA can call `revokeRole(DEFAULT_ADMIN_ROLE, EOA)` on each old proxy to render them ungovernable — but they have no balance and no consumers, so leaving them is acceptable.

### R.4 Don't forget downstream

- `karpatkey-tokenized-fund` — any deploy script that hardcodes the NAV v2 proxy addresses (search `0x5a0b28e1` / `0x1ECAEa1C`) needs updating.
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
6. `06_Configure.s.sol` — generates Safe TX batch (`addBalanceOracle` per adapter + `authorizeAdapter` per bridge adapter). Safe executes via Safe UI Transaction Builder.
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
6. **`06_Configure.s.sol`** — direct EOA broadcast of `addBalanceOracle()` + `setMetaInstances()` per deployed adapter, plus bridge-adapter authorization. Idempotent (skips already-registered oracles / already-authorized adapters).
7. Phase 5 (`RegisterAssets.s.sol` with the broadcast path) — EOA registers assets directly using its `MANAGER` role.
8. **`07_TransferAdminToSecurityCouncil.s.sol`** — grants `DEFAULT_ADMIN_ROLE` + `MANAGER` to the target Safe, revokes `MANAGER` from the EOA, renounces `DEFAULT_ADMIN_ROLE`. **Currently NAV-only** (does not touch BridgeEscrow); if Bridge is in scope you must hand-roll a Safe TX batch for Bridge admin handoff.
9. Phase 8 (`VerifyEtherscan`), Phase 9 (validation).

Roles end state (after step 8): Safe holds `DEFAULT_ADMIN_ROLE` + `MANAGER` on NAVCalculator. Deployer EOA holds nothing on NAV. **BridgeEscrow handoff is manual** — see step 8 caveat.

### Which path tonight?

If the production Safe(s) are deployed and signers are available, prefer **Path A** — it's the cleanest end state (Safe holds roles from moment 1, no EOA-admin window) and uses the standard Safe UI flow that auditors and signers are already familiar with. **Path B** is appropriate if signers aren't available or if you specifically need the EOA-broadcast simplicity for some part of the operation.

`06_Configure.s.sol`'s `_balanceAdapterNames()` list must stay in sync with `04_DeployBalanceAdapters.s.sol`. If you see drift, that's a bug.

---

## Phase 0: Prerequisites

### 0.1 Merge oracle migration PRs

The oracle migration PRs have all merged to `main`:

| PR | Branch | Content | Status |
|----|--------|---------|--------|
| [#10](https://github.com/karpatkey/onchain-accounting/pull/10) | `feat/pr1-surgical-changes` | Base infrastructure changes | Merged 2026-04-17 (`f97f264`) ✓ |
| [#11](https://github.com/karpatkey/onchain-accounting/pull/11) | `feat/pr2-price-oracles` | 16 custom price oracles + L2 deploy wiring | Merged 2026-04-17 (`369efd0`) ✓ |
| [#12](https://github.com/karpatkey/onchain-accounting/pull/12) | `feat/pr3-balance-oracles` | 5 new balance oracle adapters (MorphoVault, GearboxMarket, Cap, Curve, Convex) + per-instance deploy wiring | Merged 2026-04-17 (`f32d560`) ✓ |
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
| `addresses.securityCouncil` | The per-chain OIV Safe | **Must be a Safe** — verify via `cast code <addr> --rpc-url <RPC>` (returns bytecode, not `0x`) AND `cast call <addr> "getThreshold()(uint256)"` (returns ≥1) |
| `addresses.admin` | Holds `DEFAULT_ADMIN_ROLE` post-deploy | Must equal `securityCouncil`. **Audit 2026-04-28: currently set to EOA `0x00008bB2Ff12ca49eD157B21a0D955c63C9ab31F` on all 5 chains — must be updated to the OIV Safe before the production redeploy.** |
| `addresses.manager` | Holds `MANAGER` post-deploy | Must equal `securityCouncil`. Same EOA caveat as `admin`. |
| `deployed.*` | Canonical NAV/Bridge addresses already populated on all 5 chains | These point at the salt-v2 **test deploy**. Will be replaced by the salt-v3 redeploy; do not treat as production until then. |

**Rule:** if you change any `addresses.*` value after `02_DeployProxies.s.sol` has run for a chain, you must re-grant roles explicitly via a Safe TX batch. You cannot re-run `02` idempotently for role changes.

### 0.5 Pre-flight checklist (do before any `--broadcast` invocation)

Tick every box below before you broadcast on any chain. Each one has burned a past deployment:

- [ ] **NAV v2 proxies have been redeployed with Safe admin/manager** (or you've explicitly accepted the test-deploy state). Verify with `cast code <safeAddr> --rpc-url <RPC>` returning bytecode, not `0x`, AND `hasRole(DEFAULT_ADMIN_ROLE, <safe>) = true` on both proxies. If still pointing at EOA `0x00008bB2Ff12ca49eD157B21a0D955c63C9ab31F`, **stop and complete "Redeploying proxies" first** — Phase 4-9 against EOA-controlled proxies is single-key custody.
- [ ] Branch you're deploying from is `main` (or a documented release tag). `git rev-parse HEAD` matches the commit you expect.
- [ ] `forge build` passes clean (default profile — `foundry.toml` defines only `default`, `coverage`, and `slow`; there is no `local` profile here).
- [ ] Non-fork tests pass: `forge test --no-match-path 'test/**/fork/*.sol'` → 716+ passing.
- [ ] Fork tests pass against your target chain: `FOUNDRY_PROFILE=slow forge test --match-path 'test/**/fork/*.sol'` → 271+ passing.
- [ ] `.env` has: `ALCHEMY_API_KEY`, `DEPLOYER_NAME` (Foundry keystore account name), `<CHAIN>_ETHERSCAN_API_KEY`.
- [ ] Deployer EOA has native gas on the target chain (check with `cast balance <EOA> --rpc-url ...`). Rule of thumb: 0.05 ETH on L1, 0.01 ETH-equivalent on L2s/Gnosis for a full Phase 4+5 run (Phase 3 typically skipped — see Phase 3 intro).
- [ ] Chain config `addresses.admin` and `addresses.manager` point to the correct per-chain Safe (post-redeploy).
- [ ] For redeploys of a specific adapter: `deployed: ""` is cleared in the config (otherwise the script skips).
- [ ] You know which Safe's signers will execute the generated Safe TX JSONs in Phases 5/6, and those signers are available.
- [ ] You have a rollback plan: any pre-existing price feed or balance oracle you intend to replace is documented, and you know the `cast send` commands to revert.

---

## Phase 1: Configure Price Feed Adapters

Price feed adapter configuration lives in `script/config/assets.json` under the `priceFeeds` section.

### 1.1 Add `priceFeeds` section to `assets.json`

The `priceFeeds` section must be added to `assets.json` with constructor parameters for each custom price adapter, organized by adapter name and chain ID. The deploy script (`03_DeployPriceFeeds.s.sol`) reads from this config.

> **Looking up Chainlink heartbeats.** Every `*chainlinkHeartbeat` constructor parameter must match (or slightly exceed) the published heartbeat of the underlying Chainlink feed — otherwise every query returns `stale: true` between heartbeat writes. Chainlink's authoritative source is the JSON directory at `https://reference-data-directory.vercel.app/feeds-<network>.json` (e.g. `feeds-mainnet.json`, `feeds-ethereum-mainnet-arbitrum-1.json`). Each feed entry exposes `heartbeat` (seconds) and `threshold` (deviation %). Alternatively, [data.chain.link](https://data.chain.link) shows the same values per feed page. ETH/USD mainnet is 3600s; USD stablecoins are typically 86400s. If in doubt, round up (e.g. 3900s) to tolerate block-time jitter.

> **Also pre-seed chain configs.** `ConfigReader.writeAdapterAddress(...)` writes deployed price-feed addresses to `script/config/chains/{chainId}.json` at `.priceFeeds.{adapter}.deployed`. Foundry `vm.writeJson` will not create a missing parent object, so each chain config must have a `"priceFeeds": {}` key (with per-adapter sub-objects for anything you want to deploy) before `03_DeployPriceFeeds.s.sol` runs. `ConfigReader.readAdapterParam` documents this behaviour inline; use that as the authoritative reference if in doubt.

Structure:

```json
{
  "priceFeeds": {
    "<AdapterName>": {
      "<chainId>": {
        "enabled": true,
        "constructor": {
          "param1": "0x...",
          "param2": "3600"
        }
      }
    }
  }
}
```

### 1.2 Mainnet custom price feed adapters

`03_DeployPriceFeeds.s.sol._deployMainnetPriceAdapters()` dispatches each adapter below, guarded by `ConfigReader.isAdapterEnabled(...)`. An adapter is deployed only if its entry exists and is `enabled: true` under `assets.json.priceFeeds.<name>.1`. The **Configured today** column reflects the current state of `assets.json` on this branch — adapters marked `—` are supported by the deploy script but have no `assets.json` entry, so they are skipped at deploy time. Add them to `assets.json` when a fund needs them.

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

| Oracle | Deployed on | Source file | Notes |
|--------|-------------|-------------|-------|
| `wstETH_L2` | Arbitrum, Base, Gnosis | `wstETH_L2_Price.sol` | Gnosis uses an Aave ratio provider in place of a Chainlink feed, same interface |
| `cbETH_L2` | Base | `cbETH_L2_Price.sol` | |
| `weETH_L2` | Arbitrum, Base | `weETH_L2_Price.sol` | |
| `rsETH_L2` | Arbitrum | `rsETH_L2_Price.sol` | |
| `ezETH_L2` | Arbitrum | `ezETH_L2_Price.sol` | Uses `xRenzoDeposit.getRate()`, different from Mainnet `ezETH` |
| `syrupUSDC_L2` | Arbitrum | `syrupUSDC_L2_Price.sol` | |
| `sXDAI` | Gnosis | `sDAI_Price.sol` (aliased as `sXDAI_PriceOracle` — constructor is re-used) | |
| `ezETH` | Mainnet | `ezETH_Price.sol` | Uses `restakeManager.calculateTVLs()` |
| `ETHPlus` | **not deployed** | `ETHPlus_Price.sol` | The oracle contract exists and is unit + fork tested, but no `_deployIfEnabled("ETHPlus")` call is wired because ETH Alpha uses a Chainlink feed for ETHPlus on mainnet. Leave it that way unless a fund starts relying on the Custom path. |

**Optimism has no Custom price adapters.** Alpha funds on OP use Chainlink feeds exclusively (`wstethToUsdChainlink`, `usdcToUsdChainlink`, `usdtToUsdChainlink`). `_deployOptimismPriceAdapters()` is an intentional no-op; if a future fund needs a Custom adapter on OP, add it there.

> **Double-check before you add a new Custom adapter:** some assets on L2s already have `type: "Custom"` in `assets.json` with a third-party-deployed `pricefeed` address (e.g. an Aave-provided ratio feed). Confirm whether the existing address is ours or third-party before deploying a duplicate.

### 1.5 Heartbeat conventions

`assets.json` and the chain configs both surface heartbeat values, and they mean different things in different places. Get this wrong and `NAVCalculator.getAccountNav` either over-reports staleness (every price flagged stale) or under-reports it (a multi-hour-stale price is treated as fresh).

**Where heartbeats appear and what they control:**

| Location | Used by | What it does |
|---|---|---|
| `tokens.<chainId>.<symbol>.heartbeat` (number) | `RegisterAssets.s.sol` → `NAVCalculator.registerAsset(_, _, _, heartbeat)` → stored in `priceOracles[asset].chainlinkHeartbeat` | For `Chainlink`/`Redstone`/`API3`-typed entries: NAV checks `block.timestamp - latestRoundData().updatedAt >= heartbeat` and flags the feed stale if exceeded. For `Custom`-typed entries: the primary gate is `getLatestPrice().stale`; the registered heartbeat is then also applied as an external gate on `latestRoundData().updatedAt` (same `>=` check). |
| `priceFeeds.<adapter>.<chainId>.constructor.<feed>Heartbeat` (string) | `03_DeployPriceFeeds.s.sol` → adapter constructor → stored in the adapter's immutable | Per-feed staleness threshold inside the Custom oracle's `getLatestPrice()`. Multi-feed adapters OR-check each one (`weETH_Price.sol:85-90`), so any single feed exceeding its heartbeat marks the whole price stale. |

**Conventions to follow (PR #14 baseline, all aligned to the fund-side):**

- **Chainlink-typed token entries.** Use the **fund-side `<chain>PriceOracles.<feed>ToUsdChainlink().chainlinkHeartbeat`** value. Notable non-86400 cases:
  - DAI/USD Mainnet: **3600**
  - USDC/USD Mainnet: **82800** (not 86400 — the standard `0x8fFfFfd4...818f6` aggregator publishes every 23h)
  - USDe/USD Mainnet: **82800**
  - ETH/USD Base, Optimism: **1200** (20-minute cadence)
  - All other ETH/USD feeds (Mainnet, Arbitrum, Gnosis): 3600 / 86400 depending on chain — check `PriceOracles.sol`
  - Stablecoins generally: **86400**
- **Custom-typed token entries.** Use **`type(uint256).max`** (the literal `115792089237316195423570985008687907853269984665640564039457584007913129639935`). This matches the fund-side `maxHeartbeat` constant. The Custom oracle reports its own staleness; this field is advisory.
- **Custom adapter constructor heartbeats** (in `priceFeeds.<adapter>.<chainId>.constructor`). Each per-feed heartbeat parameter must equal the **actual Chainlink feed's published heartbeat** for the feed it points at. Example: `priceFeeds.syrupUSDC.1.constructor.usdcToUsdChainlinkHeartbeat = "82800"` because that adapter consumes the standard USDC/USD Mainnet feed (heartbeat 82800). A 86400 here would silently tolerate a 1-hour-stale USDC price.

**Source of truth.** Every heartbeat — token-entry or adapter-constructor — should match the corresponding fund-side `karpatkey-tokenized-fund/contracts/script/deploy/oracles/priceOracles/PriceOracles.sol` `<chain>PriceOracles.<getter>().chainlinkHeartbeat`. PR #14 audited and aligned all 55 token entries and all 19 adapter-constructor heartbeats; CI doesn't currently enforce this drift, so re-audit on every change.

---

## Phase 2: Configure Balance Adapters

Balance adapter configuration lives in each chain's config file under `balanceAdapters`.

### 2.1 Add adapter entries to chain configs

> **Starting state:** chain configs already include many `balanceAdapters` entries beyond `ERC20Default` (pre-seeded during PR #12 — e.g. `AaveV3_Core`, `AaveV3_Prime`, `MorphoMarket_*`, `Aura_*`, etc.). Before editing `script/config/chains/{chainId}.json`, review what's already there and add only the adapters still missing for your deployment. `04_DeployBalanceAdapters.s.sol` deploys the intersection of (a) names in its `run()` list and (b) entries with `enabled: true` in the chain config.

For each new adapter you want to deploy on a given chain, add an entry to `script/config/chains/{chainId}.json` under `balanceAdapters`:

```json
"balanceAdapters": {
  "AaveV3_Core": {
    "enabled": true,
    "constructor": {
      "dataProvider": "0x...",
      "protocol": "Aave V3 Core"
    },
    "deployed": ""
  }
}
```

### 2.2 Balance adapters available for deployment

The deploy script (`04_DeployBalanceAdapters.s.sol`) supports these adapters:

| Adapter prefix | Constructor params | Applicable chains |
|---------------|-------------------|-------------------|
| `AaveV3_*` | `dataProvider`, `protocol` | Mainnet, Arbitrum, Base, Optimism, Gnosis |
| `CompoundV3_*` | `compoundRewards`, `comet`, `rewardToken`, `protocol` | Mainnet |
| `SparkLend`, `SparkLend_*` | `dataProvider`, `protocol` | Mainnet (current wiring uses the bare `SparkLend`; the `SparkLend_*` prefix is supported for future multi-market use) |
| `MorphoMarket_*` | `morpho`, `marketId`, `protocol` | Mainnet, Arbitrum, Base (per-chain via config `enabled` flag) |
| `MorphoVault_*` | `vault`, `protocol`, `positionDetail` | Mainnet |
| `GearboxMarket_*` | `market`, `protocol`, `positionDetail` | Mainnet |
| `Cap` | `cUsd`, `stcUsd`, `usdc`, `protocol`, `positionDetail` | Mainnet |
| `Curve_*` | `gauge`, `protocol`, `positionDetail` | Mainnet |
| `Convex_*` | `rewarder`, `lpToken`, `protocol`, `positionDetail` | Mainnet |
| `AaveV3SafetyModule_*` | `stakeToken`, `protocol`, `positionDetail` | Mainnet |
| `BalancerV3_*` | `pool`, `gauge`, `balancerMinter`, `protocol` | Mainnet |
| `Aura_*` | `pool`, `gauge`, `booster`, `pid`, `protocol`, `positionDetail` | Mainnet, Arbitrum, Base. AURA token resolved dynamically inside the adapter via `Booster.minter()` (+ `L2Coordinator.auraOFT()` staticcall on L2s) — do **not** add an `auraToken` config field, it's unused since PR #12 commit `62fcdee`. |
| `StakeWiseV3Vault_*` | `underlyingToken`, `vault`, `protocol`, `positionDetail` | Mainnet |
| `DaiDsr` | `dai`, `dsrManager`, `protocol`, `positionDetail` | Mainnet |
| `SkySavingsUsds` | `savingsUsds`, `protocol`, `positionDetail` | Mainnet |

### 2.3 Specific adapters currently wired in the deploy script

`04_DeployBalanceAdapters.s.sol` has a single `run()` that holds the **union** of adapter names across every chain. There are no chain-specific dispatch functions — per-chain selection is controlled by the `enabled` flag in each chain config. The current inventory (43 instances across 5 chains) was scoped to what ETH Alpha Fund and USD Alpha Fund require. Source of truth: the `run()` list in `04_DeployBalanceAdapters.s.sol`.

To deploy additional instances (e.g., a new Curve gauge, or AaveV3 on a different chain):

1. Add a new `_deployIfEnabled("<AdapterName>")` call inside the `run()` function of `04_DeployBalanceAdapters.s.sol`.
2. Add a corresponding `balanceAdapters.<AdapterName>` entry to `script/config/chains/<chainId>.json` with `enabled: true` and constructor params for the target chain.
3. Run `04_DeployBalanceAdapters.s.sol` for that chain — adapters not enabled in that chain's config are skipped, and already-deployed adapters are skipped (idempotent).
4. Add the adapter address to NAVCalculator via Phase 6.

### 2.4 Adapter inventory (authoritative — `run()` list in `04_DeployBalanceAdapters.s.sol`)

`04_DeployBalanceAdapters.s.sol`'s `run()` calls `_deployIfEnabled(<name>)` for every adapter name below, on every chain. Each call fires only if `chains/<chainId>.json.balanceAdapters.<name>.enabled == true`. This means the `run()` list is the **union** across chains; per-chain selection happens through the config file.

The current `run()` list (check `04_DeployBalanceAdapters.s.sol` lines 45–109 for the authoritative source):

**Aave V3 (one instance per market):** `AaveV3_Core`, `AaveV3_Prime`, `AaveV3_Arbitrum`, `AaveV3_Base`, `AaveV3_Optimism`, `AaveV3_Gnosis`

**Single-instance protocols:** `SparkLend`, `AaveV3SafetyModule_stkGHO`, `Cap`

**Morpho Vaults:** `MorphoVault_kpkETHPrime_V1`, `MorphoVault_kpkETHPrime_V2`, `MorphoVault_kpkUSDCPrime_V1`, `MorphoVault_kpkUSDCPrime_V2`, `MorphoVault_kpkUSDCYieldV1`

**Morpho Markets (USD Alpha + Mainnet/Arbitrum):** `MorphoMarket_wstETH_USDC`, `MorphoMarket_cbBTC_USDC`, `MorphoMarket_wstUSR_USDC`, `MorphoMarket_ETHPlus_USDC`, `MorphoMarket_WBTC_USDC`, `MorphoMarket_RLP_USDC`, `MorphoMarket_syrupUSDC_USDC`, `MorphoMarket_sUSDS_USDT`, `MorphoMarket_sUSDS_USDC`

**Morpho Markets (ETH Alpha):** `MorphoMarket_ETHPlus_WETH`, `MorphoMarket_wstETH_WETH`, `MorphoMarket_weETH_WETH`, `MorphoMarket_rsETH_WETH`, `MorphoMarket_cbETH_USDC`

**Gearbox (Mainnet — ETH Alpha):** `GearboxMarket_kpkWETH`, `GearboxMarket_kpkwstETH`

**Balancer V3 (Mainnet — ETH Alpha):** `BalancerV3_rETH_WETH`

**Aura (one per pool):** `Aura_rETH_WETH` (Mainnet), `Aura_GHO_USDT_USDC` (Mainnet), `Aura_GHO_USDC_USDT` (Arbitrum), `Aura_GHO_USDC` (Base). Pool IDs: `rETH_WETH=271`, `GHO_USDC_USDT=99`, `GHO_USDC=19` (these go in the config's `pid` param).

**Curve (Mainnet):** `Curve_weETH_WETH`, `Curve_crvUSD_USDC`, `Curve_crvUSD_USDT`, `Curve_RLUSD_USDC`

**Convex (Mainnet):** `Convex_weETH_WETH`, `Convex_crvUSD_USDC`, `Convex_crvUSD_USDT`, `Convex_RLUSD_USDC`

**StakeWise V3:** osETH (Mainnet) and osGNO (Gnosis) are **Custom-priced ERC20s** via `osToken_PriceOracle` (`convertToAssets(1e18) × underlying/USD`); held osTokens are reported by `ERC20DefaultOracle` (deployed by `03_DeployPriceFeeds` / registered by `RegisterAssets`, config keys `priceFeeds.osETH` / `priceFeeds.osGNO`). The `StakeWiseV3VaultsMeta` adapter separately reports vault deposits net of minted-osToken debt (`vaultAssets - mintedOs`, denominated in ETH/GNO). Wired primarily for integration cross-checks; the Alpha funds do not currently use StakeWise.

**Explicitly not wired** (contracts exist in the repo but no Alpha fund needs them): `CompoundV3_*`, `DaiDsr`, `SkySavingsUsds`, `AaveV3SafetyModule_stkAAVE`. If you need one later, add a `_deployIfEnabled("<Name>")` line to `run()`, add the config entry to `chains/<id>.json`, and add the name to `06_Configure.s.sol`'s `_balanceAdapterNames()` — otherwise the adapter deploys but never registers on NAVCalculator.

> **`ERC20Default` is special** — it's deployed inside `NAVCalculator.initialize()` (via `02_DeployProxies.s.sol`), not by `04_DeployBalanceAdapters.s.sol`. It auto-covers every asset registered on the NAVCalculator (wallet balances + native sentinel). Don't put it in the `run()` list.

> **Naming discipline matters.** The `_deployAdapter` dispatcher in `04_DeployBalanceAdapters.s.sol` routes by prefix (`_startsWith(adapterName, "AaveV3_")`). A new instance on Aave V3 must start with `AaveV3_`, a new Morpho Vault with `MorphoVault_`, and so on — otherwise the dispatcher falls through to `"Unknown adapter type"` and the deploy is a no-op.

**Invariant to check before each deploy run:** `chains/<id>.json.balanceAdapters.<Name>` exists ⇔ `04_DeployBalanceAdapters.s.sol` has `_deployIfEnabled("<Name>")` ⇔ `06_Configure.s.sol._balanceAdapterNames()` includes `"<Name>"`. All three or none.

---

## Phase 3: Deploy Price Feed Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

> **When this phase is needed (and when it isn't).** Phase 3 builds NAV v2 versions of Custom price oracles. The fund-side repo (`karpatkey-tokenized-fund`) ships its own deployments of every Custom oracle we currently use, and those v1 deployments **satisfy the v2 `IPriceFeedCustom` interface** — verified empirically across all 18 deployed Custom oracles (see `docs/historical/oracle-migration-plan.md` → "Empirical confirmation"). For any adapter whose `assets.json.tokens.<chainId>.<symbol>.pricefeed` already points at a working fund-side address, **deploying a NAV v2 copy is redundant** — both contracts return the same price for the same block, and NAV v2 just reads whatever address is in the registry.
>
> Running this phase only adds value when:
> - You're onboarding a new oracle that the fund-side never deployed.
> - You explicitly want NAV v2 to own its oracle stack independently of the fund repo (e.g. for an audit boundary).
>
> If neither applies, set `priceFeeds.<name>.<chainId>.enabled = false` (skips the deploy) and proceed to Phase 4. As of 2026-04-28 every `enabled: true` adapter falls in the redundant category — the matching token entries point at fund-side addresses — so Phase 3 can be skipped entirely for the current Alpha-fund deployment.

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

Deployed adapter addresses are auto-saved to `script/config/chains/<chainId>.json` under `.priceFeeds.<name>.deployed` via `ConfigReader.writeAdapterAddress(...)`. `assets.json` is only used for constructor inputs; it is not the authoritative record of deployed addresses. Check the console output for each deployed adapter address too — the `[OK] <Name> deployed at: 0x...` line is the fastest sanity check.

**Re-run safety:** If the script is interrupted, re-running will skip already-deployed adapters (checks the `deployed` field in the chain config).

---

## Phase 4: Deploy Balance Adapters

Run per chain. Only adapters with `enabled: true` in config are deployed.

> **⚠ Dry-run hazard.** `04_DeployBalanceAdapters.s.sol:144` (and 21 sites in `03_DeployPriceFeeds.s.sol`) calls `ConfigReader.writeAdapterAddress(...)` unconditionally — even on a bare `forge script` invocation **without `--broadcast`**. A dry run will write deterministic-test-sender CREATE2 addresses (`0x5b73...`, `0x7FA9...`, `0x34A1...`, etc.) into `script/config/chains/<id>.json.balanceAdapters.<name>.deployed`. Subsequent real broadcasts will then read those bogus addresses, report "already deployed", and **silently skip every adapter** — leaving NAVCalculator wired to zero-code addresses. **After ANY exploratory `forge script` run of `03` or `04` without `--broadcast`, run `git checkout -- script/config/chains/` before the real broadcast.** Tracked as a blocking follow-up in `docs/historical/oracle-migration-plan.md` "Aspects to improve" #4.

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

Deployed addresses are auto-saved to `script/config/chains/{chainId}.json` under `balanceAdapters.{name}.deployed`.

**Re-run safety:** Same as price feeds — already-deployed adapters are skipped.

---

## Phase 5: Register Assets on NAVCalculator

Assets (tokens) must be registered on NAVCalculator with their price feed (Chainlink or Custom oracle address). This is done via `RegisterAssets.s.sol`.

> **This is the on-chain wiring step for price oracles.** `assets.json` is just the source data. NAV v2 reads from its own `priceOracles[asset]` mapping at runtime (`Prices.sol:32`); that mapping stays empty until `RegisterAssets.s.sol` writes to it via `NAVCalculator.registerAsset(asset, oracle, priceType, heartbeat)`. After this phase completes per chain, NAV's price stack is fully wired — every registered asset returns a price (or a `stale` flag) when queried. Phases 3 and 5 are independent: Phase 3 deploys *new* oracle contracts, Phase 5 *registers* whatever address is in `assets.json.tokens.<chain>.<symbol>.pricefeed` (whether that's a fund-side v1 deployment or a NAV v2 redeploy from Phase 3).

### 5.1 Review token list

Token definitions live in `script/config/assets.json` under `tokens.{chainId}`. Each token has:

- `address` — token contract address
- `type` — `"Chainlink"`, `"Custom"`, or `"None"`
- `pricefeed` — oracle address (Chainlink feed or custom price adapter)
- `heartbeat` — staleness threshold in seconds

Tokens with `type: "None"` or empty `pricefeed` are skipped.

The list of symbols to register per chain is hardcoded in `RegisterAssets.s.sol` function `_symbolsForChain()`. Add new symbols there if needed.

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

1. Open the per-chain Safe in Safe UI: `https://app.safe.global/home?safe=<chain_shortname>:<safe_address>` (chain shortnames per Safe: `eth` for Mainnet, `arb1` for Arbitrum, `base` for Base, `oeth` for Optimism, `gno` for Gnosis). Use the **production Safe address from the post-redeploy `chains/<id>.json.addresses.securityCouncil`** — not the test-deploy EOA.
2. Apps → "Transaction Builder".
3. Click the JSON icon top-right → "Load batch" → select `safe-transactions/{chainId}-register-assets.json`.
4. The Builder parses each call. Review every row: contract address should be the **post-redeploy NAVCalculator proxy** from `chains/<id>.json.deployed.NAVCalculatorProxy` (NOT the salt-v2 test-deploy `0x5a0b…54C6`), function should be `registerAsset(address,address,uint8,uint256)`, and the arguments should match `assets.json` for the chain. **Don't skip this step** — the JSON is generated but not cryptographically tied to the config.
5. "Create Batch" → "Send Batch" → collect threshold signatures → execute.
6. After execution, run the verification commands in Phase 9.1 to confirm every intended asset is registered.

Same flow applies to `safe-transactions/{chainId}-configure.json` in Phase 6 and any `ManageAdapters.s.sol` output in Phase 7.

### 5.5 Repeat for all chains

Run the same script for each chain (42161, 8453, 10, 100).

---

## Phase 6: Add Balance Oracles to NAVCalculator

After balance adapters are deployed, they must be registered on NAVCalculator via `addBalanceOracle()`. This requires the MANAGER role.

### Option A: Use `06_Configure.s.sol` (Safe TX batch)

```bash
forge script script/deploy/06_Configure.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

Output: `safe-transactions/{chainId}-configure.json` — import into Safe UI.

### Option B: Use `ManageAdapters.s.sol` (individual Safe TXs)

Edit `ManageAdapters.s.sol` and uncomment `_addBalanceOracle(adapterAddress)` calls:

```solidity
function run() public override {
    setUp();
    validateAddresses();
    _addBalanceOracle(0x...); // adapter address from config
}
```

Then run:

```bash
forge script script/manage/ManageAdapters.s.sol \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --chain-id 1
```

### Option C: Direct broadcast (if sender has MANAGER)

Call `addBalanceOracle()` directly on the NAVCalculator proxy using `cast`. **Read the proxy address from chain config** rather than hardcoding — the salt-v2 address `0x5a0b…54C6` in this runbook's Canonical addresses table is the test deploy and will not match post-Phase-R production:

```bash
NAV_PROXY=$(jq -r '.deployed.NAVCalculatorProxy' script/config/chains/1.json)
cast send $NAV_PROXY \
  "addBalanceOracle(address)" <adapter_address> \
  --rpc-url "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  --account $DEPLOYER_NAME
```

---

## Phase 7: Add or Update Price Feeds on NAVCalculator

Custom price feed adapters (deployed in Phase 3) must be linked to their assets on NAVCalculator via `addPriceFeed()`. `registerAsset()` sets the first feed; use `addPriceFeed()` to append a second or third feed for redundancy, or after replacing an old adapter.

If you registered assets in Phase 5 with the correct Custom oracle addresses in `assets.json`, the price feeds are already set. Only use this phase if you need to update or add feeds after initial registration.

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
NAV_PROXY=$(jq -r '.deployed.NAVCalculatorProxy' script/config/chains/1.json)
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

> **Known limitation — hardcoded adapter list.** `VerifyEtherscan.s.sol` does **not** iterate the full `04_DeployBalanceAdapters.run()` inventory. It emits `forge verify-contract` commands only for the names in the hardcoded arrays inside `_emitVerifyBalanceAdapters` and `_balanceAdapterPathAndArgs` (today: `AaveV3_USDC/WETH`, `CompoundV3_USDC/WETH`, `SparkLend`, `SparkLend_USDC`, `MorphoBlue_USDC`, `DaiDsr`, `SkySavingsUsds`, `ERC20Default`). Adapters outside that list (`AaveV3_Core`, `AaveV3_Prime`, `Aura_*`, `Curve_*`, `Convex_*`, `MorphoMarket_*`, etc.) are silently skipped. When you add a new adapter type or instance, either extend the hardcoded arrays in `VerifyEtherscan.s.sol` or run `forge verify-contract` manually for that instance. Tracked as a follow-up in `docs/historical/oracle-migration-plan.md` ("Aspects to improve").

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

> **Setup once per chain.** All cast examples below use `$NAV_PROXY` and `$RPC` so they work for any chain post-Phase-R (don't paste the salt-v2 stale `0x5a0b…54C6` from the Canonical addresses table — that's the test deploy). Set both at the top:
>
> ```bash
> CHAIN_ID=1                 # 1 / 42161 / 8453 / 10 / 100
> RPC="https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"   # match the chain
> NAV_PROXY=$(jq -r '.deployed.NAVCalculatorProxy' script/config/chains/$CHAIN_ID.json)
> echo "NAV_PROXY=$NAV_PROXY"   # sanity check — should be the salt-v3 address from R.2 step 4
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

> **Note:** NAVCalculator inherits from `Balances`, which exposes balance-oracle registry getters. Use these for registration checks (all public, `view`):
>
> ```bash
> # All registered balance oracles
> cast call $NAV_PROXY "getAllOracles()(address[])" --rpc-url "$RPC"
>
> # Is a specific adapter registered?
> cast call $NAV_PROXY "isOracleRegistered(address)(bool)" <adapter> --rpc-url "$RPC"
>
> # Count of registered oracles
> cast call $NAV_PROXY "getOracleCount()(uint256)" --rpc-url "$RPC"
>
> # Which oracles report an asset
> cast call $NAV_PROXY "getOraclesForAsset(address)(address[])" <asset> --rpc-url "$RPC"
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

### 9.3 Verify each balance oracle returns data

```bash
# For each balance adapter, call the v2 interface (IBalanceOracleAdapter)
cast call <adapter_address> \
  "getOracleBalanceForAsset(address,address)(uint256,bool)" <safe_address> <underlying_asset> \
  --rpc-url <RPC_URL>

# Or enumerate every position the oracle reports for the Safe:
cast call <adapter_address> \
  "getOraclePositions(address,address)" <safe_address> 0x0000000000000000000000000000000000000000 \
  --rpc-url <RPC_URL>
```

---

## Known Gaps to Address Before Deployment

> **Gaps 1–3 closed** by PRs [#11](https://github.com/karpatkey/onchain-accounting/pull/11) and [#12](https://github.com/karpatkey/onchain-accounting/pull/12) (merged 2026-04-17). The remaining gaps 4 and 5 do not block Alpha fund launch. Scope is limited to what the **ETH Alpha Fund** and **USD Alpha Fund** actually use — stale or unused v1 entries are intentionally excluded.

### 1. L2 price feed deploy functions — CLOSED

Closed in PR #11 (commits [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f) and [`2a9c0d7`](https://github.com/karpatkey/onchain-accounting/commit/2a9c0d7)). L2 deploy functions (`_deployWstEthL2`, `_deployWeEthL2`, `_deployRsEthL2`, `_deployEzEthL2`, `_deployCbEthL2`, `_deploySyrupUsdcL2`) are implemented and wired into `_deployArbitrumPriceAdapters`, `_deployBasePriceAdapters`, and `_deployGnosisPriceAdapters`. `_deploySxdai` added to Gnosis in the same PR.

### 2. `assets.json` `priceFeeds` section — CLOSED

Closed in PR #11 (commit [`581719f`](https://github.com/karpatkey/onchain-accounting/commit/581719f)). Every Custom price adapter used by ETH Alpha or USD Alpha has a `priceFeeds.{adapter}.{chainId}` entry with `enabled` and `constructor` params. Chain configs were pre-seeded with matching `priceFeeds` scaffolds so `ConfigReader.writeAdapterAddress` can persist deployed addresses.

### 3. `06_Configure.s.sol` and `04_DeployBalanceAdapters.s.sol` alignment — CLOSED

Closed in PR #12 (commit [`2a75423`](https://github.com/karpatkey/onchain-accounting/commit/2a75423)). `06_Configure.s.sol` was rewritten around a shared `_balanceAdapterNames()` helper that matches the 43 adapter names deployed by `04`. No more MorphoBlue_USDC ghost reference; all 10 new adapters from PR #12 are included.

### 4. Bridge adapters — partial per-chain coverage

Current state per chain (verified 2026-04-17 from `chains/<id>.json.bridgeAdapters`):

| Chain | Enabled | Deployed |
|---|---|---|
| Mainnet (1) | CCIP, Across, Stargate, CCTP — all `enabled: false` | None |
| Arbitrum (42161) | CCIP, Across, Stargate, CCTP | All four deployed |
| Base (8453) | Superchain, Across, Stargate, CCTP | All four deployed |
| Optimism (10) | Superchain, CCTP | `enabled: true` but `deployed: ""` — **pending broadcast** |
| Gnosis (100) | Gnosis bridge — `enabled: false` | None |

Bridge adapters exist to account for funds in-flight between chains (outbound: bridged-out USDC sitting in a Safe on source chain + inbound ERC20 on destination chain pending claim). Without them, NAV under-reports during an inflight bridge. Each adapter implements `IBridgeAdapter` and is registered on `BridgeEscrow` via `AuthorizeBridgeAdapters.s.sol` (or Safe TX batch from `06_Configure.s.sol`).

**Does not block Alpha fund launch** — Alpha funds bridge inbound to Arbitrum and outbound from Base, both covered. Deploy on Optimism + Mainnet before using those chains as bridge sources. Gnosis doesn't have a cross-chain bridge product yet; its entry is a placeholder.

Use `05_DeployBridgeAdapters.s.sol` to deploy. Re-run safety is the same as `03`/`04` — already-deployed entries are skipped.

### 5. Native xDAI coverage on Gnosis — deferred

`ERC20Default` is registered on Gnosis with the xDAI sentinel address (`NATIVE_ADDRESS`) pre-inserted at NAVCalculator init, but no fork test confirms that `getOracleBalanceForAsset(NATIVE_ADDRESS, safe)` returns the correct native balance. USD Alpha Fund uses native xDAI on Gnosis. Verify with a fork test against a Safe holding xDAI before the Gnosis deployment goes live. Not blocking pre-deployment.

---

## Quick Reference: Deployment Order

```
Phase R: Redeploying proxies (production fresh-start) -- one-time
         (REQUIRED for production launch from the salt-v2 test deploy.
         Bumps salt v2 → v3 in 02_DeployProxies.s.sol; admin/manager
         set to per-chain Safe; reuses existing implementations. See
         "Redeploying proxies" section above. Skip ONLY if salt-v2
         proxies already have Safe-controlled admin/manager — verify
         via cast code + hasRole.)
    |
    v
Phase 0: Prerequisites (merge PRs, env setup, run tests)
    |
Phase 1: Configure price feed params in assets.json
Phase 2: Configure balance adapter params in chain configs
    |   (these two can be done in parallel)
    v
Phase 3: Deploy price feed adapters (03_DeployPriceFeeds.s.sol) -- per chain
         (OFTEN SKIPPED — see "When this phase is needed" above. If every
         enabled adapter has a working fund-side v1 deployment already
         referenced in assets.json.tokens.*.pricefeed, this phase is
         redundant; flip enabled: false instead.)
Phase 4: Deploy balance adapters (04_DeployBalanceAdapters.s.sol) -- per chain
    |   (Phase 4 is independent of Phase 3 / Phase 5 — pure contract deploys,
    |   no NAVCalculator interaction)
    v
Phase 5: Register assets on NAVCalculator (RegisterAssets.s.sol) -- per chain
         (THE on-chain wiring step for prices — fills priceOracles[asset]
         mapping. assets.json is the source data; runtime reads from this
         on-chain mapping.)
Phase 6: Add balance oracles to NAVCalculator (Path A: 06_Configure Safe TX batch
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

- **Price feeds and balance adapters are NOT upgradeable** — they're standalone contracts. To "rollback", deploy a corrected version and update the NAVCalculator to point to the new one via `addPriceFeed()` + `removePriceFeed()` / `removeBalanceOracle()` + `addBalanceOracle()`. Both are MANAGER-only.
- **NAVCalculator and BridgeEscrow ARE upgradeable** (UUPS). Use `script/upgrade/UpgradeNAVCalculator.s.sol` or `UpgradeBridgeEscrow.s.sol`. Requires DEFAULT_ADMIN_ROLE on the target proxy — i.e. the OIV Safe for each chain after the production redeploy (currently still the EOA on salt-v2 proxies; see §"Roles and governance").
- **Partial deploys are re-runnable.** `03_DeployPriceFeeds.s.sol` and `04_DeployBalanceAdapters.s.sol` both read `.deployed` and skip any entry already populated. If a broadcast runs out of gas halfway, top up the EOA and re-run — the script will continue from where it stopped.

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

The asset is registered in NAVCalculator, but no price feed is linked. Happens when Phase 5 registered the asset with `type: "None"` or empty `pricefeed`. Fix: call `addPriceFeed(asset, priceFeed, priceType, heartbeat)` via Phase 7.

### Every asset flagged `stale: true`

Check `chainConfig.chainlinkSequencerFeed`. On L2s, `checkL2SequencerUptime()` ORs into every price's stale flag — if the sequencer uptime feed is misconfigured (wrong address or not set during `NAVCalculator.initialize`), every price reads stale. On L1 it should be `address(0)`.

### `getAccountNav` reverts with `AssetNotFound()`

A balance oracle returned a `PositionBalance` for an underlying asset that isn't registered on NAVCalculator. Either register the asset (Phase 5) or fix the oracle to stop returning it.

### Chainlink feed shows `answer <= 0`

NAV v2 returns `(0, decimals, true)` for any Chainlink answer ≤ 0 (`src/prices/Prices.sol:70-72`). The asset contributes 0 to NAV and is flagged stale. Usually indicates a broken feed or one that just reverted; check `latestRoundData()` directly and contact the oracle provider.

### `forge script` fails with `vm.writeJson: no such key`

Foundry's `vm.writeJson` requires the parent object to exist. Make sure `chains/<id>.json` has `"priceFeeds": {}` and `"balanceAdapters": {}` keys even if empty, and every specific adapter name you reference has its sub-object (with `"deployed": ""` at minimum). `ConfigReader.writeAdapterAddress` calls `vm.writeJson` directly — if any parent in the path is missing, the script run **reverts** with `vm.writeJson: no such key`. Pre-seed the parent objects (see Phase 0.2) before re-running.

### Role misconfiguration

If `hasRole(DEFAULT_ADMIN_ROLE, <deployer EOA>) == true` after `02_DeployProxies.s.sol`, that's a red flag — the deployer should retain no ongoing roles. Investigate before running Phases 3-7. If `hasRole(MANAGER, <safe>) == false`, the `grantRole(MANAGER, ...)` step in `02_DeployProxies.s.sol` (or `06_Configure.s.sol`) didn't execute or hasn't been executed yet — re-run or generate a Safe TX.

### `02_DeployProxies.s.sol` reverts at `grantRole(MANAGER, ...)` — historical (FIXED in `d513f27`)

This used to happen when `chainConfig.admin` was a Safe and the deployer EOA lacked `DEFAULT_ADMIN_ROLE`. As of `d513f27` the grant happens inside `AtomicProxyDeployer`'s constructor (where the deployer transiently holds admin) and the post-constructor block was removed, so this revert path no longer exists in the atomic flow. If you see it: you're running pre-`d513f27` code or `USE_LEGACY_DEPLOY=1`. For the legacy path: have the admin Safe execute `grantRole(MANAGER, <ManagerSafe>)` on both proxies via a Safe TX batch.

### `forge verify-contract` fails with "Already verified"

Not actually a failure — Etherscan caches verified bytecode by hash. You can skip or pass `--watch` to just confirm.

---

## How to add a new Custom price oracle

Workflow for a brand-new oracle after the migration PRs are merged. Each step has a canonical reference file — mirror it.

1. **Write the oracle** under `src/prices/protocols/<Name>_Price.sol`. Inherit `IPriceFeedCustom` (8-decimal USD output, `(uint256 price, bool stale)` return). Reference: `sDAI_Price.sol` for a simple ERC4626-style feed, `weETH_Price.sol` for a two-hop Chainlink composition.
2. **Write the unit test** under `test/prices/protocols/<Name>_Price.t.sol`. Minimum: constructor revert coverage for every invalid-argument path.
3. **Write the fork test** under `test/prices/protocols/fork/<Name>_Price.fork.t.sol`. Pin a block, assert an exact price value, exercise the stale path by warping `block.timestamp` past the heartbeat.
4. **Register in `assets.json`** under `priceFeeds.<Name>.<chainId>` with `enabled: true` and all constructor params. Also make sure `chains/<chainId>.json.priceFeeds.<Name>` exists (even as `{"deployed": ""}`) so `ConfigReader.writeAdapterAddress` has a parent to write to.
5. **Wire into `03_DeployPriceFeeds.s.sol`**: add `import {...}` at top, add `_deployIfEnabled`-style dispatch inside the correct `_deploy<Chain>PriceAdapters()` function, add a `_deploy<Name>()` helper that reads constructor params via `ConfigReader.readPriceFeedParam` and writes back via `ConfigReader.writeAdapterAddress`. Reference: `_deploySdai` in the same file.
6. **Run tests locally**: `forge test --match-path "test/prices/protocols/<Name>*"` must pass before pushing.
7. **Register the asset with the new price feed**. If the asset is already registered on NAVCalculator with a Chainlink feed, call `addPriceFeed(asset, newFeed, PriceType.Custom, heartbeat)` (Phase 7) via Safe, then remove the old feed with `removePriceFeed(asset, oldFeed)`. Otherwise, register from scratch in Phase 5.
8. **Update `assets.json.tokens.<chainId>.<Symbol>.pricefeed`** to the newly-deployed adapter address, so future `RegisterAssets.s.sol` runs (if you unregister + re-register) use the right feed.

---

## How to add a new balance adapter

Workflow for adding a new protocol adapter or a new instance of an existing protocol.

**New instance of an existing protocol (e.g. a new Curve pool):**

1. Add a config entry to `chains/<chainId>.json.balanceAdapters.Curve_<pool>` with the constructor params (`gauge`, `protocol`, `positionDetail`) and `"deployed": ""`.
2. Add `_deployIfEnabled("Curve_<pool>")` inside `04_DeployBalanceAdapters.s.sol`'s `run()` function.
3. Add `"Curve_<pool>"` to `_balanceAdapterNames()` in `06_Configure.s.sol`.
4. Run `forge build` + `forge test` to confirm nothing regressed.
5. Deploy (Phase 4) and add to NAVCalculator (Phase 6).

**New protocol entirely (e.g. a new yield primitive):**

1. **Write the adapter** under `src/balances/protocols/<Protocol>.sol`. Inherit `IBalanceOracleAdapter` — must implement `getOraclePositions`, `getOracleBalances`, `getOracleBalanceForAsset`, `underlyingAssetsSupported`, and `supportsInterface`. Reference: `MorphoVault.sol` for a single-asset vault, `Convex.sol` for a multi-reward-token protocol.
2. **Write the unit test** under `test/balances/protocols/<Protocol>.t.sol`. Cover: constructor, `underlyingAssetsSupported`, zero balance, non-zero balance, asset filter.
3. **Write the fork test** under `test/balances/protocols/fork/<Protocol>.fork.t.sol`. Cover: real on-chain position, real reward accruals, asset filter at a pinned block.
4. **Add to `AdapterConsistency.t.sol`** if the protocol has non-trivial edge cases the existing cross-adapter invariants don't cover (zero balance handling, debt positions, asset filter).
5. **Import + dispatch in `04_DeployBalanceAdapters.s.sol`**: add `import`, add `_deployIfEnabled("<Protocol>_<Instance>")` to `run()`, add a `_startsWith(adapterName, "<Protocol>_")` branch in `_deployAdapter`, and a `_deploy<Protocol>()` helper that reads params.
6. **Add to `06_Configure.s.sol._balanceAdapterNames()`.**
7. **Add instance to chain config.**
8. **Run full test suite.** `forge test` non-fork + fork must both be green before pushing.
9. **Deploy + register on NAV** via Phases 4 and 6.

> **Naming rule:** new balance adapter files use PascalCase. Contract names use the same PascalCase + a `BalanceOracle` suffix where the convention exists (see `CurveBalanceOracle`, `MorphoVaultBalanceOracle`). The `balanceOf` parameter must be named `account` (enforced pattern, not `safe`).

---

## Maintaining this runbook

Every time you:
- Change anything in `02_DeployProxies.s.sol`, `03_DeployPriceFeeds.s.sol`, `04_DeployBalanceAdapters.s.sol`, `05_DeployBridgeAdapters.s.sol`, or `06_Configure.s.sol`,
- Add a new adapter family,
- Hit a gotcha that burned a deployment,
- Change the role-granting flow or `chainConfig.admin`/`manager`,

update the corresponding section here in the same PR. This runbook only stays trustworthy if it's kept in lockstep with the code it describes.
