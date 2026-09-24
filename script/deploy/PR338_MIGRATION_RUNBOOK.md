# PR #338 migration runbook — claimant map, wallet-yield reclassification, timelock install

**Audience: the operator executing this migration.** Every transaction below is prepared by a script in
this repo; nothing here asks you to hand-build calldata. The person who wrote these scripts did **not**
broadcast any of them.

**The governing rule, and the reason for every batch boundary:** under-report is licensed in this
codebase, **over-report never is**. A window in which a token is reported by *two* adapters is a defect.
A window in which it is reported by *none* is tolerated but still closed wherever batching can close it.

---

## 0. What this migration changes

| | |
|---|---|
| **Implementation** | New `NAVCalculator` implementation; the proxy is **upgraded in place**. No new proxy. |
| **Libraries** | **Both** pinned libraries move — `NAVRegistryLib` and `PriceFeedLib`. New CREATE2 addresses, pins regenerated. |
| **Meta adapters** | ⚠️ **ALL 23 move address and must be redeployed AND re-registered.** `MetaBalanceAdapter._assetsForInstances` is now gas-metered, which changes the shared base's bytecode. Owner decision 2026-09-24: accepted. `testNavOnlyAdapterAddresses` / `testProtocolArgAdapterAddresses` are expected-red until the address records are regenerated. |
| **New storage** | `Balances._claimant` at slot **109**, declared after `__balancesGap` (48→47). Layout verified COMPATIBLE. |
| **New adapters** | 17 `…WalletMetaBalanceAdapter` contracts, CREATE2, on 5 chains. |
| **Governance** | `DEFAULT_ADMIN_ROLE` + `MANAGER` move from the deployer EOA to a new `TimelockController`. |

**Scope: 25 chains with a live NAV.** 7 carry assets (1, 10, 56, 100, 137, 8453, 42161) and need the full
sequence; the other 18 need libraries + implementation + `upgradeToAndCall` only. **Chain 1101
(polygon-zkevm) has no live NAV** — its `deployments/1101.json` has no `NAVCalculatorProxy`. Exclude it.

**`ERC20DefaultBalanceAdapter` and `LabelLib` are untouched**, so the set-once default-adapter pointer
coupling does not fire and no new proxy is needed. The two deployed contracts that *do* appear in the diff
(`EulerVaultsMetaBalanceAdapter`, `ETHx_CrossRateCustomPriceFeed`) changed **comments only**, so they are
bytecode-identical under `bytecode_hash = none`. Do not redeploy them.

---

## 1. Preflight — all of it, before any transaction

1. **Merge `origin/main`.** The branch is behind, and `main` added **Arc (5042)**, which needs libraries +
   implementation like any other asset-free chain. Arc's gas is USDC and its native asset is 18-decimal.
2. **Regenerate the two library pins.** `forge clean && forge build --force` first — CI's sticky disks are
   keyed on repo, not commit, so a warm tree can report a different address for byte-identical source.
   Follow `script/utils/LibraryPins.sol:17-38` and measure from **two independent clean builds that
   agree**. Until this is done, `01_2`'s guard (`:69-77`) and `UpgradeNAVCalculator`'s
   (`:81-94`) both hard-revert. **This is the deferred regen; the two red pin tests go green here.**

   ⚠️ **The regen must be the LAST source change before deploy, and this is measured rather than assumed.**
   A warm-tree reading on 2026-09-24 gave `PriceFeedLib -> 0x0f913658d70BB19b7B42eF9926c3df7c70fafCf2` and
   `NAVRegistryLib -> 0x7f87874AAf7ADBace6Dba48A0971C3Be1372299F`. An earlier reading, taken **before** the
   `_reincludeIfAsset` claim-gate landed in `NAVRegistryLib`, gave `0xca5f316d…` for that library — i.e. a
   two-line change to a library moved its pin, while the `PriceFeedLib` value reproduced identically across
   both readings (a useful cross-check that the method is sound and only the changed library moved).

   **Treat both numbers as evidence of drift, NOT as the pins.** `LibraryPins.sol:17-38` requires two
   independent CLEAN builds that agree, and a warm tree can report a different address for byte-identical
   source. Regenerate on the final tree, after the `origin/main` merge and after every source change.
3. **Refresh `script/deploy/preflight/snapshots/pre/` for chain 1.** The baseline is stale against live
   state, so `diff_snapshots.py`'s delta starts from the wrong number and the reclassification INFO
   downgrade will not fire.
4. **Run the residue + collision audit on all 7 asset chains:**
   ```
   python3 script/deploy/preflight/residue_audit.py --chain 1 --chain 10 --chain 56 \
       --chain 100 --chain 137 --chain 8453 --chain 42161
   ```
   A non-zero exit means either dormant residue on a deregistered adapter, or — the newer check — a
   **planned wallet-yield coordinate already governed by a live adapter**. The second is a hard stop: see
   §4 hazard H1.
5. **Quantify the expected NAV drop.** For every live coordinate and every wallet coordinate, record
   `isSupportedByDefault(low160(C))` **and** `isAssetRegistered(...)`. That intersection is a **live
   double-count today** — the base implementation never excluded on claim — and the backfill closes it.
   Write the number down now, or the drop will look like a regression later.
6. **Confirm all 35 wallet coordinates are registered assets.** An unregistered one makes the
   reclassification non-value-neutral for that token: `WalletTokenMetaBalanceAdapterBase.sol:163-166`
   returns empty and the position disappears.
7. **Check `isAdapterRegistered(0x5B50A5FF1C80A178bB8da9fdfF077FBc3DD4e543)` on chain 1** — the retired
   combined Cap adapter. See H6. ⚠️ **That address is NOT in the current deployment record** — the `Cap`
   key in `script/config/deployments/1.json` is an **empty string**, so the address exists only in git
   history (`git log -p -- script/config/deployments/1.json`). `residue_audit.py` will not flag it either,
   because it is *registered*, and the audit deliberately treats a registered adapter's set as governed
   rather than residue. This check is the only thing that catches it.
8. **Council Safe presence.** Confirmed deployed on 24 chains. Still unverified: **16661 (0G)** (its
   public RPC errored) and **Arc (5042)**. Check both, on **two independent endpoints** —
   `polygon-rpc.com` returns empty code for a Safe that demonstrably exists, so a single endpoint is not
   evidence.
9. **Fork-rehearse the in-place upgrade.** `script/deploy/preflight/rehearse_fork.sh` rehearses a
   from-scratch redeploy, **not** an upgrade of a live proxy — a new harness is needed. Its job: apply the
   real Phase 2 batch on chains 1/10/100/8453/42161, **measure per-batch gas** (the split decision in §3
   depends on it), and prove value-neutrality with `snapshot_production.py` + `diff_snapshots.py`.
10. **Freeze MANAGER activity** on the 7 asset chains from batch generation until execution. See H8.

---

## 2. Phase 1 — EOA, per chain. Changes no reported NAV.

```
FOUNDRY_PROFILE=slow PERSIST_DEPLOYMENTS=1 forge script script/deploy/01_2_DeployNAVImplementation.s.sol \
    --rpc-url "$RPC" --account kpk-deployer --broadcast
```

⚠️ **Use `01_2`, not `UpgradeNAVCalculator`, for the deploy.** `01_2` CREATE2-deploys **both libraries and
the implementation** (`:137-139`, `:144-166`), so the implementation lands at **one address fleet-wide**
and the 25 Safe files differ only in `chainId`. `UpgradeNAVCalculator` uses plain `new` (`:130-135`) —
25 different addresses, 25 verifications — and deploys **no libraries at all**, so the first library call
would delegatecall into nothing. Take `UpgradeNAVCalculator` only for its guards and its batch emitter.

Then, on the 5 chains with wallet-yield adapters (1, 10, 100, 8453, 42161):

```
FOUNDRY_PROFILE=slow PERSIST_DEPLOYMENTS=1 forge script script/deploy/04_DeployBalanceAdapters.s.sol \
    --rpc-url "$RPC" --account kpk-deployer --broadcast
```

⚠️ `04` **logs errors and exits 0.** Read the log; do not trust the exit code.

Finally, grant `DEFAULT_ADMIN_ROLE` and `MANAGER` on the NAV to the council Safe — step 1 only of
`07_TransferAdminToSecurityCouncil` (`:81-92`). **Do not run its steps 2-3** (`:95-102`): the deployer
must keep both roles as the escape hatch until every chain finishes Phase 3.

---

## 3. Phase 2 — the atomic Safe batch, per chain

**The 18 asset-free chains** need one transaction: `upgradeToAndCall(newImpl, "")`. Verify first that they
really are empty (`getAllAdapters()` + `getMetaInstances`) — H9.

**The 7 asset chains**, in this order:

| # | Call | Atomicity |
|---|---|---|
| 1 | `upgradeToAndCall(newImpl, "")` | May share the batch. The proxy SLOADs the implementation slot on **every** call with no caching, so later entries already run the new code. |
| 2…k | per adapter, **adjacent pair**: `removeMetaInstances(M, todo)` then `addMetaInstances(M, todo)` | **MANDATORY.** Generate with `forge script script/manage/BackfillMetaInstanceClaimants.s.sol --sig 'plan()'` |
| k+1… | `addMetaBalanceAdapter(walletAdapter, coords)` ×16/1/3/3/5 | **Must come after ALL of 2…k.** |
| last | chain 1 only: `removeBalanceAdapters([0x5B50A5FF1C80A178bB8da9fdfF077FBc3DD4e543])` | Anywhere in the batch. Cap's meta set is empty, so `_releaseInstances` re-arms nothing. |

Import each `safe-transactions/<chainId>-*.json` into the Safe **Transaction Builder**, which wraps a
multi-transaction import in MultiSend — that is what makes the pairs atomic.

### Chain 1 is ~54-58 entries and ~10M gas

Memory is not the constraint (largest single calldata is 548 bytes; total ≈10 KB). Gas is. Take the
3-batch split unless the fork rehearsal shows a single batch under ~15M:

- **Batch 1** — `upgradeToAndCall` + pairs for adapters 1-10.
- **Batch 2** — pairs for adapters 11-20 + the Cap deregistration.
- **Batch 3** — the 16 `addMetaBalanceAdapter` calls.

**Why those boundaries are the only safe ones.** After Batch 1, some adapters are backfilled and some are
not — which is exactly today's strength (see below), so no over-report. After Batch 2 everything is
backfilled and the wallet family is still unregistered, so every wstETH-class token is reported **exactly
once** by the default adapter: no over-report and no under-report, the cleanest resting state in the whole
migration. **Never split inside a pair. Never put Batch 3 before Batch 2.**

### The un-backfilled window is NOT a regression

Base `_appendInstances` (`git show 451e72ad:src/nav/NAVRegistryLib.sol:427-438`) scans only the adapter's
**own** set — there is no cross-adapter scan in the base implementation. The new `_claim`'s own-set loop
reproduces that exactly, so an un-backfilled coordinate is governed precisely as strongly as it is on the
live chain right now. What the backfill *adds* is the cross-adapter guarantee, which neither base nor an
un-backfilled head ever had. This is why the 3-way split is legitimate rather than a risk.

---

## 4. Ranked hazards

- **H1 — registering a wallet adapter before the backfill silently double-counts.** On an un-backfilled
  proxy `_claim` cannot see that a pre-existing adapter already holds `bytes32(token)`: `claimant` is empty
  and the own-set loop covers only the new adapter. Partly mitigated — `WalletTokenMetaBalanceAdapterBase`
  (`:172-174`) returns empty while the token is still armed on the default adapter, so the family fails
  **closed** — but that guard probes only the default adapter, not other meta adapters. **`residue_audit.py`
  now checks this; run it (§1.4).**
- **H2 — splitting a remove/add pair** is an unbounded, silent, permanent under-report: `_release`
  early-returns at `NAVRegistryLib.sol:523` before `_reincludeIfAsset`, so nothing re-arms. Use `plan()`.
- **H3 — no `RegisterAssets` and no `includeAssetInDefaultAdapter` between the upgrade and the last pair.**
  `includeAssetIfUnclaimed` sees `claimant == 0` and arms the default adapter for a governed token; the
  `revertIfClaimed` flag is vacuous while the map is empty.
- **H4 — stale pins ship an implementation linked to the OLD libraries, silently.** The old pinned
  addresses already hold code on every live chain, so nothing reverts at runtime: the batch executes, the
  proxy delegatecalls library versions nobody intended, none of the `_claim`/`_release` machinery exists,
  and the 10M-gas backfill is a no-op while the deployment record claims success. Only the **build-time**
  guards catch it. §1.2 is not optional.
- **H5 — `_reincludeIfAsset` is now claim-gated (fixed in this PR).** It narrows a coordinate to 20 bytes,
  which is not injective, so a marketId/poolId could re-arm the default adapter for a token another adapter
  governs. Covered by `test_releaseNarrowingOntoGovernedToken_doesNotArmDefault` and its not-firing twin.
- **H6 — a live double-count exists on mainnet today, outside this PR.** The retired combined Cap adapter
  `0x5B50A5FF1C80A178bB8da9fdfF077FBc3DD4e543` is registered alongside `CapStablecoin`
  (`0x121583E21C671e9B1193FE478ec9dc9D73D73a3F`) and `CapSavings`
  (`0xEc605FC2521792f2018dF92Bb5aDBf85EB417cb6`);
  `nav-config/balance-adapters/1.json` carries `deregister: true` for exactly this. Fold it into Batch 2.
- **H7 — the backfill DECREASES NAV.** See §1.5. Predict the number before causing it.
- **H8 — a stale batch dies whole.** `MetaInstanceNotFound` / `DuplicateMetaInstance` make it
  all-or-nothing, which is safe but wasteful. Regenerate immediately before signing.
- **H9 — the asset-free chains may not be empty.** Verify before sending them a bare upgrade.
- **H12 — `_metaInstanceTotal` freezes** (arithmetic retired, `NAVRegistryLib.sol:229-232`). No impact
  found: it is `internal` with no public getter, its `PriceFeedLib` parameters are unused, and the preflight
  gate's field of the same name is a **derived sum** over `getMetaInstances`, not this slot.

---

## 5. Phase 3 — heartbeat realignment, EOA, per chain

`script/manage/RealignHeartbeats.s.sol`. **Runs here: after the upgrade, before the timelock.**

- **Only possible post-upgrade** — the in-place heartbeat upsert exists only in the new `PriceFeedLib`;
  against the live implementation `addFeed` reverts `PriceFeedAlreadyRegistered`.
- **EOA-only** — no `writeSafeTx` path, so it needs the deployer's `MANAGER`, which Phase 4 removes.
- It hardcodes `NAV = 0x54EaD2…` (`:31`), correct only because the proxy is fleet-uniform. Confirm.

Then re-run the Phase 2 verification reads, and run the backfill in **dry-run** (no `--broadcast`): it
must revert `NothingToDo`, which is the completion proof.

---

## 6. Phase 4 — install the timelock. Not until Phase 3 is green everywhere.

```
PERSIST_DEPLOYMENTS=1 DEPLOYER_EOA=0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72 \
  forge script script/deploy/11_DeployTimelockController.s.sol --rpc-url "$RPC" \
  --account kpk-deployer --broadcast
```

CREATE2-deploys `TimelockController(0, [councilSafe], [address(0)], address(0))` — OZ 5.5.0 verbatim,
whose constructor grants PROPOSER **and CANCELLER** to the Safe and makes execution open. Identical args
fleet-wide ⇒ **one timelock address on every chain**. It then emits
`safe-transactions/<chainId>-install-timelock.json`.

⚠️ **Decide `SAFE_RETAINS_ROLES` before running.** Default `false`: the Safe's own roles are revoked and
the timelock is the only path to admin. Set it `true` and the Safe can still act directly — which means
raising `minDelay` later achieves **nothing**. Retaining is a reasonable transitional state while
`RealignHeartbeats` and `ClearDormantMetaInstances` lack timelock emitters; it is not a reasonable end
state.

⚠️ **`minDelay = 0` provides no timing protection and its canceller is decorative.** At zero delay the
Safe can `scheduleBatch` and `executeBatch` in one transaction, and because the executor is open anyone can
execute a pending operation immediately, so cancelling is a race. What it buys today is one canonical admin
address instead of a hot EOA, plus the option to raise the delay later — `updateDelay` is a **self-call**,
so the Safe schedules it through the timelock.

⚠️ **After this, every config operation needs `scheduleBatch` + `executeBatch` wrapping.**
`RealignHeartbeats.s.sol` and `ClearDormantMetaInstances.s.sol` are EOA-only and will stop working.

### Verify on-chain — the scripts cannot do this for you

`forge script` bodies run as local simulation and Foundry sends transactions only after `run()` returns,
so any in-script post-condition checks the *simulation*.

- **NAV:** `hasRole(0x00, timelock)` and `hasRole(MANAGER, timelock)` true; both false for the deployer;
  `getRoleMemberCount(0x00) >= 1`.
- **Timelock:** `getMinDelay() == 0`; `hasRole(PROPOSER_ROLE, safe)`; `hasRole(CANCELLER_ROLE, safe)`;
  `hasRole(EXECUTOR_ROLE, address(0))`; `hasRole(DEFAULT_ADMIN_ROLE, deployer)` false.
- **Backfill:** every live coordinate's claimant names its adapter —
  `cast storage $NAV $(cast keccak $(cast abi-encode "f(bytes32,uint256)" $COORD 109))`. This is the
  **only** proof the backfill landed.
- **Reclassification:** for each of the 35 wallet tokens, `isSupportedByDefault == false` **and** exactly
  one meta-adapter registration. Both — `false` with a zero claimant means the token is reported by nobody.
- **Value:** `diff_snapshots.py` reduces to exactly `reclassification.json`, every wallet row
  `RECLASSIFIED` with the same asset, same `isDebt`, same exact amount. Total NAV differs from the
  before-picture only by the H7 double-counts and the H6 Cap legs.
- **Rehearse one `scheduleBatch` → `executeBatch` round trip on ONE chain before declaring done.** A
  timelock that cannot execute is a bricked NAV, and nothing above detects it.

Refresh the integration snapshot (`script/test/refresh-integration-snapshot.sh`) **only after** Phase 2 has
landed on all 7 asset chains — never between chains.

---

## 7. Rollback

Phase 1 is abortable with no on-chain effect. Phase 2 is atomic per batch, and both split boundaries are
correct resting states. Rollback means upgrading the proxy back to the implementation recorded in
`script/config/deployments/<chainId>.json`; the `_claimant` writes then become inert, since the old
implementation never reads slot 109.

⚠️ **Rollback is not complete on its own, and this is now a HARD RULE rather than advice.**
`_excludeIfAsset` wrote to `ERC20DefaultBalanceAdapter`'s inclusion list — **state on a separate immutable
contract** — and a proxy rollback does not undo it. Any token excluded during the backfill stays excluded.

**`_release` no longer re-arms the default adapter** (owner decision 2026-09-24, reversing the earlier
"retirement no longer means deletion"), because at release time the code cannot see a PLAIN adapter
reporting the same token's wallet balance under a different reported asset — `CapStablecoinBalanceAdapter`,
`AaveV3SafetyModuleBalanceAdapter` and `AaveUmbrellaBalanceAdapter` all do, and re-arming over one is an
over-report. So nothing hands a token back automatically any more.

**Therefore: RE-ARM FIRST, DEREGISTER SECOND.** Deregistering a meta adapter leaves every registered token
it governed reported by nobody until `includeAssetInDefaultAdapter` is called for each (that call is
claim-guarded, so it cannot itself create a second reporter). Doing it in the other order produces a silent
NAV drop with no health flag. This applies to the wallet-yield rollback specifically: retiring those
adapters strands their 35 tokens until each is re-armed.

**Do not revoke the deployer EOA until every chain has completed Phase 2 and Phase 3.**
