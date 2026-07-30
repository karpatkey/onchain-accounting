# Fork-rehearsal brief — read this before running anything

Written 2026-07-30 against `main` @ `f72dd48a` (twelve PRs merged in the wave). For a session that has
no memory of the wave. It is deliberately self-contained: everything you need to decide **pass or
fail** is here, because a rehearsal run with a wrong pass/fail rule is worse than no rehearsal.

Companions, both authoritative and not duplicated here:
[`../REDEPLOY_RUNBOOK.md`](../REDEPLOY_RUNBOOK.md) (the ordered procedure) and
[`README.md`](README.md) (the tooling).

---

## 0. THE DEPLOY IS NOT AUTHORISED

The user instructs the real deploy explicitly, and has not. This rehearsal is preparation. It runs
**only against a local anvil fork** and must not touch a live proxy, broadcast to a real chain, or
modify live state. `rehearse_fork.sh` enforces the loopback part itself — it refuses any RPC that is
not loopback — but the discipline is yours, not the script's.

Do **not** run `script/test/refresh-integration-snapshot.sh`. It is deliberately deferred to just
before the redeploy, as a DeBank-compared final validation.

### Gating state

| item | state |
|---|---|
| **#185** two-library pin regen | green, **deliberately held** pending a measurement of whether `dynamic_test_linking` moves deployable bytecode |
| **#203** Curve `getPool`/`getLpToken` | in bounded mutation verification; merges after #185 |
| this rehearsal | runs **after #185 lands**, because the rehearsal must exercise the pinned tree |

If #185 has not landed, `01_2` will revert on its pin assertions and the rehearsal cannot pass. That
revert is correct behaviour, not a bug — see §5.

---

## 1. What the rehearsal is for

The redeploy puts the whole NAV stack on a **new proxy** across 24 chains. The rehearsal answers three
questions that cannot be answered by reading:

1. **Does the sequence run end to end on a real fork?** Several deploy scripts exit 0 having done
   nothing (`03`/`04` skip-if-deployed, `RegisterAssets` and `06` return early). The rehearsal is where
   that is caught cheaply.
2. **Does the proxy address actually move?** This is the premise the entire redeploy rests on. With
   `DeploySalts.NAV_PROXY = 6` the computed proxy was the **live** one, `AtomicNAVProxyDeployer` found
   code already there, skipped the deploy and reverted `NotAuthorized()` on `upgradeToAndCall`. That
   would have happened on all 24 chains. It is bumped to **7**; the rehearsal re-confirms it, because
   the placeholder's bytecode can shift under `via_ir` with no source change.
3. **Is the resulting NAV the same portfolio?** §4 is the whole of this question.

---

## 2. Machine constraint — read before you compile

**Whole-program `via_ir` builds peak around nine gigabytes, two fit and three do not, and the kernel
takes the largest process when it OOMs** — which during a rehearsal is the rehearsal.

Before any build:

```bash
pgrep -c solc          # if >= 2, WAIT
awk '/MemAvailable/{printf "%.1f GB\n", $2/1048576}' /proc/meminfo
```

Three hard-won rules:

- **Never wait on `pgrep -c solc` reaching 0**, and never on "no `forge build` running anywhere".
  Those are statements about a shared machine and essentially never become true here. Four sessions
  lost about 55 minutes to exactly that. Gate on `< 2`, and poll **your own artifact's mtime or a pid
  you captured yourself**.
- **Kill by PID, never `pkill -f <pattern>`.** The pattern matches your own shell's command line and
  kills your own session mid-operation.
- **A review workflow's fan-out can breach the ceiling on its own, and the per-session `pgrep` gate
  cannot see or constrain the agents it spawns.** Observed: four concurrent `solc` in one worktree with
  no second build command ever issued, `MemAvailable` down to 6.8 GB. If you launch a fan-out gate
  during a rehearsal, **it can kill the rehearsal rather than itself**. Either serialise it or do not
  run it concurrently.

---

## 3. The instrument rule — where numbers may come from

This cost the fleet several hours. Read it before trusting any measurement.

- **`forge build` and `forge test` compile different units, and neither is a superset of the other.**
  A green `forge build` does not imply the test tree compiles, and vice versa.
- **CI's Unit job downloads artifacts rather than building them.** Its result describes whatever the
  Build job uploaded, not the tree you are looking at.
- **CI's cache is a repo-wide sticky disk keyed only by repository, and it has been proven to serve
  stale bytecode.** A CI reading is advisory only.
- **Therefore: local clean builds only.** `forge clean && forge build`. For any pin or bytecode value,
  a local clean build is the only admissible measurement. Four clean local builds of one tree were
  shown identical, so local is deterministic; CI varied on identical source.

**Do not transcribe a pin value into any document.** Read pins from #185's output at deploy time. Do
not touch `foundry.toml` or `script/utils/LibraryPins.sol` — #185 owns that regeneration and must
compute it against the final merged tree.

### Closure membership is necessary but NOT sufficient

A file being in a library's compilation closure does not mean editing it moves that library's pin. An
interface-only or comment-only addition recompiles without moving it. Two independent instances:

1. A NatSpec-only edit to `INAVCalculator.sol` — genuinely inside `NAVRegistryLib`'s closure — moved
   **neither** pin.
2. PR #207 added a constructor guard to `MetaBalanceAdapter.sol`, also inside that closure, and
   `NAVRegistryLib` did not move. #195 had moved it while touching that same file, but #195 also
   touched `INAVCalculator.sol` and `ERC20DefaultBalanceAdapter.sol`, and one of those was the cause.

So: **measure pin movement, never predict it from the import graph.**

---

## 4. Pass or fail — the part only this brief holds

The rehearsal's output is compared against the committed pre-deploy snapshot in
`snapshots/pre/` (24 chains, captured 2026-07-27, zero read errors).

### 4.1 The governing asymmetry

> **Under-report is tolerable. Over-report is not.**

Every adapter-hardening fix in this wave was written to that rule. It gives you a decisive test:

- A **lower** NAV than the snapshot, explainable by one of the entries in §4.3, is a pass.
- A **higher** NAV is never acceptable and never explained by the fixes below. If NAV goes up, stop.
- A **structural** difference (position count, `protocolId`/`protocolSubId`/`positionId`,
  `positionKind`, `isDebt`) that is not in §4.3 means the redeploy is wrong.

### 4.2 Compare structure exactly, value loosely

The snapshot and the rehearsal are at different blocks, so **every priced position drifts**. Compare:

| field | rule |
|---|---|
| position count, `protocolId`, `protocolSubId`, `positionId`, `positionKind`, `isDebt` | **exact** |
| labels, `protocolName` | exact **except** §4.3 |
| `amount` | drift expected; direction matters (see §4.1) |
| `nav.value` | drift expected; a rise is a stop condition |
| `stale`, `irregular`, `sequencerDown` | may differ with feed conditions, not with the redeploy |

`diff_snapshots.py` does this comparison. Addresses are expected to move; shape is not.

### 4.3 Differences that are LEGITIMATE

Each of these is a hardening fix doing its job. None is a regression.

**Expect FEWER legs or positions, from a deliberately suppressed unreportable leg:**

- **Assisted-adapter caches start EMPTY.** `AssistedCoordCache` keys coordinates per account, so a
  redeployed assisted adapter reports nothing until the owner Safe re-feeds it through the **new**
  assistant. Four caches on two chains: mainnet `EtherFiWithdrawalQueueAssisted`,
  `NexusMutualStakingPoolsAssisted`, `StakeWiseV3ExitQueueAssisted`, and **gnosis
  `StakeWiseV3ExitQueueAssisted`** (the easy miss — the family is usually described as mainnet-only).
  **This is the single largest expected reduction.** Under-report only, by the ADR 0015 invariant:
  coordinates cached, values read live, ownership re-verified per read.
- **Morpho existence gate** (#189) suppresses an instance that cannot be proven to exist.
- **Per-instance gas starvation now raises `InstanceGasExhausted`** (#182) instead of silently
  recording zero legs. A starved instance becomes a *visible failure* rather than a missing leg — if
  you see it, that is the fix working, not the deploy failing.
- **Euler `_supplyKind` fail-open fix** (#167) and **Euler `debtOf` starvation** (#193) — previously a
  whole instance including its debt leg could be dropped, which *over*-reported. Corrected behaviour
  may show debt that the snapshot lacked. **Debt appearing is a legitimate NAV decrease.**
- **Adapter gas caps** (#178) and **meta label gas bounds** (#186) can suppress a leaf whose read is
  unaffordable.

**Expect DIFFERENT labels or names, from label work:**

- `protocolName()` is derived from `_protocolId()` rather than supplied at construction, so names may
  differ from the snapshot's strings.
- StakeWise vault labels became `symbol + address` leaves (#163/#176).
- Label and over-report fixes (#161/#164), string-read fail-open hardening (#168), `positionLabels`
  leaf gas bounds (#186).
- `positionId` guards across the meta family (#175/#179) and the `_instancePositionId` hook fix (#172)
  — a `positionId` **may** legitimately differ for Aave V3, which was the one divergent adapter of 21.
  Any *other* adapter's `positionId` changing is **not** expected.

**Expect DIFFERENT price feeds:**

- **stETH is now priced by a new primary feed** and `stETHCrossRate` is demoted to a **monitor**
  (#199). Mainnet feed count 24 → 25, total 39 → **40**. This changes which contract prices stETH.
- **ETHx monitors 2 → 1.** Redstone retired both its ETHx push feeds. The direct ETHx/USD monitor is
  gone with no replacement (Chainlink has no ETHx/USD feed at all). `ETHxCrossRate` survives with its
  rate feed migrated to Chainlink `0xC499ec76e2F5ac15e127A352Bc40cF24FC472401`. ETHx's **primary** was
  never involved — it reads Stader's on-chain rate — so `nav.value` should not move for it.
- Every custom feed is at a **new address** by construction: each holds an `immutable NAV` (ADR 0019),
  so a new proxy invalidates all of them.
- **Custom-feed asset guard** (#199) — a feed can no longer be registered against the wrong asset.
- Three feed **contracts** are dead code and deployed nowhere: `cbETH_CustomPriceFeed`,
  `ETHPlus_CustomPriceFeed`, `sDAI_CustomPriceFeed` (the last deleted by #199). They were never among
  the 39/40, so their absence changes no count.

**Expect a different asset-filter view, documented not fixed:**

- Asset-filter projection semantics are **ruled intended** and documented in #205: an *asset* slice is
  a projection and its slices need not sum, whereas an *adapter* slice partitions and its slices **do**
  sum. If you are slicing, use `getAccountNavForAdapters`.

### 4.4 Differences that mean STOP

- `nav.value` **higher** than the snapshot beyond price drift.
- A **debt** leg present in the snapshot and absent now.
- `positionId` changed for any adapter other than Aave V3.
- Adapter or meta-instance **counts** below the configured totals in §6.
- Any asset registered that is not in config, or any configured asset missing.
- An **assistant whose `ADAPTER()` is not its paired assisted adapter**, or points at an adapter not
  registered on the NAV. All four live assistants are currently ORPHANS of exactly this kind — the
  redeploy is the first time they will be paired correctly, and `bytecode_audit.py` asserts it.
- **Aave V3 double-counting.** Aave exposes two DataProviders; registering both double-counts every
  position. Operator check at re-registration (#172).

---

## 5. Running it

```bash
cd /home/sgzerbo/github-projects/onchain-accounting-deploy-prep   # or a fresh worktree off main
git submodule update --init --recursive --force
git submodule status | grep -v '^ ' && echo "DRIFT — fix before building" || echo "submodules OK"

pgrep -c solc                     # must be < 2 (see §2)
forge clean && forge build        # local clean build only (see §3)

mkdir -p safe-transactions        # else RegisterAssets aborts AFTER broadcasting

script/deploy/preflight/rehearse_fork.sh 1        # mainnet fork; asserts the proxy address moved
```

`rehearse_fork.sh` treats the config tree as disposable **and you must let it**. It forks as the real
chain id, so the deploy scripts rewrite `script/config/deployments/<id>.json` wholesale with anvil
addresses and forge writes `broadcast/<script>/1/run-latest.json`, indistinguishable from a real
mainnet broadcast. So the script: refuses to start unless `script/config` and `broadcast` are
git-clean, restores both on exit byte-exact, and asserts they are clean again. Its own output is kept
under `/tmp/nav-rehearsal-<id>/config-after/`.

**Never blanket-delete `broadcast/`** — it holds committed records from the real PR #141 migrations.

### Step order — this is authoritative

```
1.1  clear the deployment record                             reset_deployment_records.py --apply
1.2  01_2_DeployNAVImplementation    libs + impl             PERSIST_DEPLOYMENTS=1
1.3  02_2_DeployNAVProxy             new proxy + ERC20Default PERSIST_DEPLOYMENTS=1
1.4  03_DeployPriceFeeds             40 custom feeds          <- BEFORE RegisterAssets
1.5  RegisterAssets                  assets + feeds          FOUNDRY_PROFILE=slow on mainnet
1.6  04_DeployBalanceAdapters        adapters + assistants
1.7  06_Configure                    register + reconcile
```

Four traps that have each already cost a run:

- **`PERSIST_DEPLOYMENTS=1` is mandatory on 1.2 and 1.3.** Without it those steps only *log* the new
  addresses; the record keeps the old ones and 1.4–1.7 build against the old NAV. Nothing errors.
- **Use `01_2`, never `01`.** `01` also deploys a `BridgeEscrow` impl — wasted gas and it rewrites
  bridge state for a deferred stack.
- **1.1 must precede 1.4.** Each of `03`'s 32 `_deploy*` helpers is skip-if-deployed and returns early
  without reverting, so a surviving `customPriceFeeds` record makes `03` a silent no-op leaving all 40
  feeds bound to the **old** proxy. `verify_step.py 1.4` enforces it by requiring every recorded feed
  address to be *new*, not merely non-zero.
- **1.4 must precede 1.5.** `RegisterAssets` resolves Custom feeds from the record; run first it skips
  **20 of mainnet's 43 assets** with `[skip] primary feed unresolved`.

### Gate every step on its post-condition, not its exit code

```bash
python3 script/deploy/preflight/verify_step.py 1.2      # then 1.3, 1.4, 1.5, 1.6, 1.7
```

It exits non-zero on the first real problem and treats an **unreachable** chain as a failure. Do not
advance until the current step reports PASS.

---

## 6. Expected values, and where they come from

Read these from the tooling, not from this table — the tooling follows config, this table goes stale.
Measured on `main` @ `f72dd48a`:

| | count | source |
|---|---|---|
| meta adapters | **33** | `preflight_config.py` |
| meta instances | **110** | `preflight_config.py`; per-chain table in the runbook |
| plain adapters | **12** (+1 `ERC20Default` per chain) | `preflight_config.py` |
| custom price feeds | **40** | `preflight_config.py` (was 39 before #199) |
| assets | **93** | `preflight_config.py` |

Per-chain meta instances: 66 / 16 / 16 / 4 / 4 / 4 / 0 for 1 / 42161 / 8453 / 10 / 100 / 137 / 56.
Adapter counts per chain: 27 / 8 / 7 / 4 / 3 / 2 / 1 for 1 / 42161 / 8453 / 100 / 10 / 137 / 56.

**Scope: 24 chains** (declared in `redeploy_scope.json`, which no tool writes — see README).
**7 are configured**: 1, 10, 56, 100, 137, 8453, 42161. The other 17 get `ERC20Default` only.

**Accounts** come from `test/integration/accounts.json` — 14 total, per configured chain:
9 mainnet, 4 optimism, 4 base, 4 arbitrum, 3 gnosis, 1 polygon.

### Rehearsal timings, from the 2026-07-27 mainnet run

`01_2` 2s, `02_2` 9s, `03` 239s, `RegisterAssets` 43s, `04` 54s, `06` 12s. Meta reconcile landed
**66/66** on mainnet. Useful only as a smell test: a step finishing far faster than this probably
skipped.

---

## 7. Two facts about production worth knowing before you compare

- **The live mainnet proxy reverts on `getRegisteredAsset(address(0))`.** Its implementation predates
  that getter. So the deployed stack *is* the "old NAVCalculator" that #207's guard refuses, and every
  meta-adapter must be constructed **after** the new implementation lands. The step order above
  already enforces that; do not reorder it.
- **`excludedFromDefaultAdapter` is empty on all 24 chains**, re-measured live 2026-07-29. It is the
  one piece of NAV config a fresh proxy cannot rebuild (`RegisterAssets` re-includes everything), so
  it would need re-applying — but there is nothing to re-apply. Re-check before the real deploy.

---

## 8. When the rehearsal passes

Report: which chain, the new proxy and `ERC20Default` addresses, each step's `verify_step.py` result,
the diff against `snapshots/pre/` classified against §4.3 and §4.4, and any residual you could not
attribute. **A residual you cannot attribute to a named entry in §4.3 is a fail**, not a curiosity.

Then stop. The deploy is the user's to authorise.
