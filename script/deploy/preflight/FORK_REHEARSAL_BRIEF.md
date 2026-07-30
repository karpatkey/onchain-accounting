# Fork-rehearsal brief — read this before running anything

Written 2026-07-30 against `main` @ `f72dd48a` (twelve PRs merged in the wave). For a session that has
no memory of the wave. It is deliberately self-contained: everything you need to decide **pass or
fail** is here, because a rehearsal run with a wrong pass/fail rule is worse than no rehearsal.

> **The rehearsal has been RUN. §9 records the first attempt, which FAILED at step 1.4 and found two
> blockers. §10 records the run that PASSED — every step, every post-condition, and the §4 NAV
> comparison, which answers the redeploy's central question: it is the same portfolio.
> Read §9 and §10 (last two sections) before running anything; they supersede anything above that
> disagrees, including a pass/fail rule in §4.1 that turned out to be wrong.**

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
| **#185** two-library pin regen | **MERGED** 2026-07-30; `main` is `7efcc8af`. Pins are `PriceFeedLib 0x8b7e4fA9…7dc1` / `NavRegistryLib 0x5f5D054E…fd90` |
| **#203** Curve `getPool`/`getLpToken` | **MERGED**, in `7efcc8af` |
| **#220** ETHx rate-leg proxy | fixes the §9 BLOCKER 1; the rehearsal that PASSED included it |
| this rehearsal | **PASSED** on `7efcc8af` + #220 — see §10. (First attempt failed at 1.4; §9.) |

If #185 has not landed, `01_2` will revert on its pin assertions and the rehearsal cannot pass. That
revert is correct behaviour, not a bug — see §5. It has landed, and the assertions passed: §9 records
the CREATE2 addresses observed, which is stronger evidence than any CI check can produce.

---

## 1. What the rehearsal is for

The redeploy puts the whole NAV stack on a **new proxy** across 24 chains, rather than shipping the
wave as a UUPS implementation upgrade. The deciding factor is `ERC20DefaultBalanceAdapter`: it is
minted inside `initialize()` behind a set-once guard, it is unremovable through the registry, and
**nothing in the implementation or admin surface that exists today can replace it.** An upgrade
*could* carry bespoke migration logic to repoint it — UUPS does not forbid that — but it would be
one-off code needing an audit, it would hand-repair private registry state, it would still end in a
new adapter deployment, and it would run against a live proxy. A fresh proxy reaches the same end
state through `initialize()`. The full costing is in the runbook's *Why this is a NEW PROXY and not an
implementation upgrade*; §9 below carries the empirical confirmation (new proxy + fresh
`ERC20Default`).

The rehearsal answers three questions that cannot be answered by reading:

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

### An EOA `eth_call` cannot validate a feed for contract use

This cost the redeploy a run, and it is the most transferable lesson in this document. `cast call`
sends `from` == the EOA, so **`msg.sender == tx.origin`** in the callee. Chainlink's read access
controllers grant access on exactly that condition:

```solidity
accessList[_user] || _user == tx.origin    // SimpleReadAccessController
```

So an access-gated feed answers a `cast call` perfectly and reverts `No access` for every contract —
which is every production reader. `cast call --from <contract address>` does **not** help: it sets
`tx.origin` to the same value, so the escape hatch still fires. Verifying a feed by reading
`description()` / `decimals()` / `latestRoundData()` from the shell proves nothing about whether the
NAV can read it.

To actually check a candidate feed:

```bash
cast call $FEED "typeAndVersion()(string)" --rpc-url $R   # "AccessControlled..." is the tell
cast call $FEED "checkEnabled()(bool)"     --rpc-url $R   # answers at all => access-controlled
cast call $FEED "hasAccess(address,bytes)(bool)" $SOME_CONTRACT 0x --rpc-url $R   # must be true
```

`hasAccess` is the decisive one, because the address you pass is not `tx.origin`, so it reports the
real production answer. A gated feed is unusable regardless of who deploys it, unless Chainlink
allowlists the reader contract — which requires its address in advance.

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
- A **higher** NAV must be *attributed* before it is accepted. **CORRECTED 2026-07-30 — the original
  rule here read "a higher NAV is never acceptable; if NAV goes up, stop", and that is unworkable.** It
  contradicts §4.2 one paragraph below, which concedes the two captures are at different blocks and that
  every priced position drifts — and drift is bidirectional. Applied literally it fails every correct
  rehearsal that is not same-block: the passing run of 2026-07-30 had two rises, both benign. The
  operative test is **attribution, not direction**: a delta must be explained by (a) price drift on an
  *unchanged* position set, or (b) a change in the account's real holdings, verified on-chain at both
  block heights. An **unattributable** rise is the stop condition. Worked examples in §10.
- A **structural** difference (position count, `protocolId`/`protocolSubId`/`positionId`,
  `positionKind`, `isDebt`) that is not in §4.3 means the redeploy is wrong.

### 4.2 Compare structure exactly, value loosely

The snapshot and the rehearsal are at different blocks, so **every priced position drifts**. Compare:

| field | rule |
|---|---|
| position count, `protocolId`, `protocolSubId`, `positionId`, `positionKind`, `isDebt` | **exact** |
| labels, `protocolName` | exact **except** §4.3 |
| `amount` | drift expected; direction matters (see §4.1) |
| `nav.value` | drift expected; an **unattributable** delta in either direction is the stop condition (§4.1) |
| `stale`, `irregular`, `sequencerDown` | may differ with feed conditions, not with the redeploy |

`diff_snapshots.py` does this comparison. Addresses are expected to move; shape is not.

### 4.3 Differences that are LEGITIMATE

Each of these is a hardening fix doing its job. None is a regression.

**Expect FEWER legs or positions, from a deliberately suppressed unreportable leg:**

- **Assisted-adapter caches start EMPTY — but expect NO reduction, because the live ones are empty
  too.** `AssistedCoordCache` keys coordinates per account, so a redeployed assisted adapter reports
  nothing until the owner Safe feeds it through the **new** assistant. Four caches on two chains:
  mainnet `EtherFiWithdrawalQueueAssisted`, `NexusMutualStakingPoolsAssisted`,
  `StakeWiseV3ExitQueueAssisted`, and **gnosis `StakeWiseV3ExitQueueAssisted`** (the easy miss — the
  family is usually described as mainnet-only). Under-report only, by the ADR 0015 invariant:
  coordinates cached, values read live, ownership re-verified per read.
  > **CORRECTED 2026-07-30 — this was previously called "the single largest expected reduction". It is
  > not a reduction at all.** Measured on mainnet: all three chain-1 assisted adapters have emitted
  > **zero logs, ever** (no topic filter, so ABI-independent) and `coordsOf()` is empty for all nine
  > chain-1 accounts. The live caches have never been fed since PR #141 deployed them, so these
  > positions read **$0 on both sides** and the correct expectation is **no change**. Seeing $0 after
  > the redeploy is not the fix working and not a regression — it is the status quo. Feeding the new
  > caches would *begin* reporting value that has never been counted (runbook §2.1). Gnosis was not
  > separately log-checked.
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
  (#199, merged 2026-07-29). Mainnet feed count 24 → 25, total 39 → 40. This changes which contract
  prices stETH.
- **ezETH gains a market monitor** so its depeg check can fire (#224, merged 2026-07-30):
  `ezETHCrossRateMarket`. Mainnet 25 → **26**, total 40 → **41**.
- **ETHx monitors 2 → 1.** Redstone retired both its ETHx push feeds. The direct ETHx/USD monitor is
  gone with no replacement (Chainlink has no ETHx/USD feed at all). `ETHxCrossRate` survives with its
  rate feed migrated to Chainlink `0xC499ec76e2F5ac15e127A352Bc40cF24FC472401`. ETHx's **primary** was
  never involved — it reads Stader's on-chain rate — so `nav.value` should not move for it.
  > **WRONG — this is BLOCKER 1 in §9.** That Chainlink address is access-gated and **no contract can
  > read it**, so `03` reverts and `ETHxCrossRate` cannot be deployed at all. Do not treat an ETHx
  > monitor change as a benign §4.3 difference until §9 is resolved.
- Every custom feed is at a **new address** by construction: each holds an `immutable NAV` (ADR 0019),
  so a new proxy invalidates all of them.
- **Custom-feed asset guard** (#199) — a feed can no longer be registered against the wrong asset.
- Three feed **contracts** are dead code and deployed nowhere: `cbETH_CustomPriceFeed`,
  `ETHPlus_CustomPriceFeed`, `sDAI_CustomPriceFeed` (the last deleted by #199). They were never among
  the 39/40/41, so their absence changes no count.

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

ANVIL_PORT=8600 script/deploy/preflight/rehearse_fork.sh 1   # mainnet fork; asserts the proxy moved
```

**Pick a port outside 8546–8550.** A five-chain local dev stack occupies that whole range on this box,
including a **mainnet** fork on 8546 — the script's own default — so the collision is guaranteed, not
unlucky. Before PR #214 the failure was silent and total: `anvil --port 8546` fails to bind and dies,
but the readiness probe was `cast block-number` against that port, which answers from the *incumbent*,
so the rehearsal deployed the whole NAV stack into a fork it did not own and then reported that fork's
post-conditions as its own. #214 makes the script refuse an occupied port and verify its own anvil pid
before trusting the probe — the guard keys on **ownership**, not reachability. Pass `ANVIL_PORT`
anyway; do not rely on the default being free.

#214 also adds `$REHEARSAL_HOOK`, invoked with `(chainId, rpc)` after the post-conditions and before
`cleanup`. Use it for anything that must read the rehearsed stack — above all the §4 NAV comparison,
which needs the fork still up **and** the deployment record still holding fork addresses, a window
`cleanup` closes on both sides.

`rehearse_fork.sh` treats the config tree as disposable **and you must let it**. It forks as the real
chain id, so the deploy scripts rewrite `script/config/deployments/<id>.json` wholesale with anvil
addresses and forge writes `broadcast/<script>/1/run-latest.json`, indistinguishable from a real
mainnet broadcast. So the script: refuses to start unless `script/config` and `broadcast` are
git-clean, restores both on exit byte-exact, and asserts they are clean again. Its own output is kept
under `/tmp/nav-rehearsal-<id>/config-after/`.

**Never blanket-delete `broadcast/`** — it holds committed records from the real PR #141 migrations.

### anvil PANICS on an upstream state-read failure — learn the signature

The dangerous part is that the **symptom is a wall of misleading errors, not the real cause**. anvil dies,
and every subsequent step then reports a connection failure against a node that no longer exists, while
the post-conditions cheerfully assert nonsense about it. Two of this wave's rehearsal attempts died this
way and the first read as a deploy failure.

The real cause looks like this, in `$WORK/anvil.log` — **and nowhere else**:

```
The application panicked (crashed).
Message:  pre-execution changes failed: Internal(Other(Database(GetStorage(0x…, 8133,
          error sending request for url (https://eth-mainnet.g.alchemy.com/v2/…)
          - Error #2: connection reset))))
          … in anvil::eth::backend::mem::Backend<N>::do_mine_block
```

The downstream noise looks like this, and means only "anvil is gone":

```
Error: Failed to send transaction after 4 attempts … (http://127.0.0.1:<port>/)
  - Error #2: Connection refused (os error 111)
```

**So: whenever a step fails with `Connection refused` on the loopback RPC, read `anvil.log` FIRST.** Do
not debug the deploy script; it is almost certainly a victim. #214's pid check catches the startup variant
immediately, but a mid-run panic can only be recognised, not prevented.

A rehearsal is a long sequence of state-heavy calls against a shared, rate-limited endpoint, so one reset
is likely. Mitigations, all in #214 and all overridable: **raise `--retries` and `--timeout`** (plus
`--fork-retry-backoff`), and **pin the fork block** — foundry caches fork state per `(chain, block)` under
`~/.foundry/cache/rpc`, so a pinned retry re-reads far fewer slots upstream, which is the difference
between a retry that survives a flaky endpoint and one that trips it again.

### Verify the restore by HASH — do not assume it, even when nothing looks wrong

`cleanup` restoring `script/config` is the single most consequential thing this script does, because
`deployments/<id>.json` is the only record of what production runs. An earlier attempt left **eighteen
phantom `customPriceFeeds` addresses** in it (§5's step-1.1 trap), so the cost of a missed restore is
concrete, not theoretical.

```bash
git status --porcelain --untracked-files=all              # must be empty (untracked included)
sha256sum script/config/deployments/1.json
git show origin/main:script/config/deployments/1.json | sha256sum   # must match
```

**A near-miss worth recording in plain terms.** During one attempt this brief's author edited
`rehearse_fork.sh` *while it was still executing*. Bash reads a script incrementally by **byte offset**,
so inserting lines ahead of the interpreter can make it misread the remainder — including the `cleanup`
trap that performs this restore. It happened to survive; the restore was verified **by hash rather than by
assumption**, which is the only reason "it survived" is a known fact rather than a hopeful one.

Two rules out of that, in order of importance:

1. **Never edit a shell script while a run of it is in flight.** Copy it, or wait.
2. **Verify the restore by hash every time**, precisely because a corrupted-cleanup failure would leave
   the tree looking normal at a glance. Checking only when something looks wrong is checking exactly when
   the check is least needed.

### Step order — this is authoritative

```
1.1  clear the deployment record                             reset_deployment_records.py --apply
1.2  01_2_DeployNAVImplementation    libs + impl             PERSIST_DEPLOYMENTS=1
1.3  02_2_DeployNAVProxy             new proxy + ERC20Default PERSIST_DEPLOYMENTS=1
1.4  03_DeployPriceFeeds             41 custom feeds          <- BEFORE RegisterAssets
1.5  RegisterAssets                  assets + feeds          FOUNDRY_PROFILE=slow  <- REQUIRED, see below
1.6  04_DeployBalanceAdapters        adapters + assistants
1.7  06_Configure                    register + reconcile
```

### `FOUNDRY_PROFILE=slow` on step 1.5 is a REQUIREMENT, not a throughput preference

**`slow` does not mean "go slower to be safe". It raises `gas_limit` AND `memory_limit` from the default
1 GiB to 16 GiB** (`foundry.toml:108-117`). `RegisterAssets` needs that because it registers the whole
asset set inside **one call frame**, and EVM memory-expansion cost is **quadratic** — mainnet's 43 assets
plan 86 actions and the frame simply outgrows a 1 GiB budget.

Without it, measured on mainnet 2026-07-30: **`EvmError: MemoryOOG` after wiring 19 of 43 assets**, with
1 asset registered. With it: 79s, 43/43.

> **The hazard is the misreading, not the flag.** Someone who reads `slow` as a rate limit will drop it
> to save time on a chain that "does not need throttling", and get a failure that looks like a contract
> bug — an EVM-level error deep in a script that worked yesterday. Two of this wave's four rehearsal
> failures were misattributed exactly this way before being run down.

**This was NOT knowledge lost to session notes — and that is the uncomfortable part.** It was documented
in **three** places before it cost a run:

1. `REDEPLOY_RUNBOOK.md` §1.5's command line — `FOUNDRY_PROFILE=slow forge script … RegisterAssets`;
2. the sentence right below it: "`FOUNDRY_PROFILE=slow` (16 GiB) is required on mainnet — 43 assets
   otherwise `MemoryOOG`", plus a row in the runbook's troubleshooting table. Both present since the
   runbook was created (`7199e661`, 2026-07-27);
3. this brief's own step table above.

It still cost a run, because **`rehearse_fork.sh` — the automation that claims to run the runbook's
sequence — did not implement it** and ran every step on the default profile.

So the transferable lesson is not "write it down". It was written down three times. It is:

> **A documented requirement that the automation does not implement is more dangerous than an
> undocumented one**, because everyone reasonably assumes the script runs the procedure. Documentation
> and automation drifting apart is invisible until the exact conditions that need the requirement occur.

Two things close that gap. The first is done — the script now applies the profile per step (#214). The
second is **already written and sitting CLOSED: PR #188** added `BaseDeployScript._assertDeployProfile()`,
so each of the 18 deploy-script subclasses refuses to run under a profile whose artifacts are not
deploy-valid. It is **not in `main`** (`_assertDeployProfile` appears nowhere there), and it is the right
shape: an **allowlist** (`default`, `slow`) rather than a denylist, with no bypass env var, on the
reasoning that forgetting to extend a denylist fails silently and on-chain. Its own comment already states
this requirement in the strongest terms available — "`slow` … **REQUIRED, not merely tolerated**: the
redeploy runbook runs `RegisterAssets` under it, because mainnet's 43 assets otherwise `MemoryOOG`" —
which makes four places, and still did not stop the rehearsal running without it. Reviving #188 is the
durable fix; the design question is settled, not open.

> **If #188 is revived, correct one factual drift in it first.** Its allowlist comment justifies `slow` by
> claiming it "sets only `threads` / `compute_units_per_second`, so its bytecode is identical". On `main`,
> `[profile.slow]` sets `threads`, **`gas_limit` and `memory_limit`** — and no
> `compute_units_per_second` at all (`gas_limit`/`memory_limit` arrived with #169 on 2026-07-27, a day
> before #188). **The conclusion survives** — neither is a compiler setting, so bytecode really is
> identical — but the stated reason no longer matches the file, and a future reader checking the claim
> against `foundry.toml` will find it wrong and may distrust the allowlist.

Note also **why it stayed hidden until now**: with the ETHx blocker in place, `03` never produced the
full feed set, so `RegisterAssets` skipped most assets and never built a frame big enough to trip the
limit. **Fixing one blocker made the next one reachable for the first time** — expect that shape, and do
not read a newly-surfaced failure as a regression.

Four traps that have each already cost a run:

- **`PERSIST_DEPLOYMENTS=1` is mandatory on 1.2 and 1.3.** Without it those steps only *log* the new
  addresses; the record keeps the old ones and 1.4–1.7 build against the old NAV. Nothing errors.
- **Use `01_2`, never `01`.** `01` also deploys a `BridgeEscrow` impl — wasted gas and it rewrites
  bridge state for a deferred stack.
- **1.1 must precede 1.4 — and must be RE-RUN after any failed `03`.** Each of `03`'s 32 `_deploy*`
  helpers is skip-if-deployed and returns early without reverting, so a surviving `customPriceFeeds`
  record makes `03` a silent no-op leaving all 40 feeds bound to the **old** proxy. `verify_step.py
  1.4` enforces it by requiring every recorded feed address to be *new*, not merely non-zero.

  This is **not only a first-run ordering rule.** It is also the recovery procedure, because a `03`
  that reverts still writes addresses it never deployed:

  > **A reverting `03` broadcasts nothing but still pollutes `deployments/<id>.json`.** `03` reverts
  > during *simulation*, so no transaction is sent and no `broadcast/03_*/` directory appears — but
  > `vm.writeJson` is a filesystem side effect and is **not** rolled back. The record acquires feed
  > addresses that exist nowhere on chain. Worse, `04` then consumes the **same EOA nonce sequence**
  > and lands real adapters on exactly those addresses: measured on the 2026-07-30 run, all 18
  > phantom `customPriceFeeds` entries collided with a real `balanceAdapters` entry, e.g.
  > `customPriceFeeds.LDO == balanceAdapters.AaveV3InstancesMeta`. That is a record asserting a price
  > feed lives where a balance adapter actually is.
  >
  > Because `03` is skip-if-deployed, the natural next action — fix the config and retry — **silently
  > skips all eighteen feeds**, and the deploy then looks like it succeeded while shipping eighteen
  > wrong feed addresses.
  >
  > **So: after ANY failed `03`, re-run step 1.1 (`reset_deployment_records.py --apply`) before
  > retrying. Unconditionally.** `verify_step.py 1.4` does catch the polluted state (`NAV()
  > unreadable` on every phantom address) — that is the gate working, and it is the reason to gate
  > every step rather than trusting exit codes.
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
| custom price feeds | **41** | `preflight_config.py`, re-measured 2026-07-30 (39 before #199, 40 before #224) |
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

---

## 9. The 2026-07-30 run — what it found

Run against `main` @ `7efcc8af` (post-#185) on a mainnet fork at block 25642902, `ANVIL_PORT=8600`.
**Exit 1.** Nothing touched a live proxy; every broadcast went to loopback anvil.

| step | time | gas | status |
|---|---|---|---|
| `01_2_DeployNAVImplementation` | 6s | 17,503,955 | OK |
| `02_2_DeployNAVProxy` | 4s | 2,369,608 | OK |
| `03_DeployPriceFeeds` | 30s | 0 | **FAIL — blocker** |
| `RegisterAssets` | 6s | 0 | FAIL (downstream of `03`) |
| `04_DeployBalanceAdapters` | 16s | 64,430,119 | OK |
| `06_Configure` | 9s | 7,240,775 | OK |

`verify_step.py` 1.2, 1.3, 1.6, 1.7 clean; 1.4 (21 failures) and 1.5 (3) fail entirely downstream of
`03`. Note `03` at 30s against the expected 239s — the §6 smell test worked.

### BLOCKER 1 — a gated Chainlink feed stops the redeploy

`03` reverts `NotChainlinkOracle()` (`src/utils/OracleArgumentChecks.sol:59`) after deploying 18 of 40
feeds, while constructing `ETHxCrossRate`. Its `yToXFeed`
`0xC499ec76e2F5ac15e127A352Bc40cF24FC472401` — set 2026-07-27 for the Redstone ETHx sunset — is an
**`AccessControlledOCR2Aggregator 1.0.0` with `checkEnabled() == true`**, and `hasAccess()` is false
for every address tried. Access exists only via Chainlink's `_user == tx.origin` escape hatch, so **an
EOA `eth_call` succeeds and every contract read reverts `No access`** — permanently, on every NAV read,
not merely in the constructor probe. Confirmed live on mainnet, not only on the fork.

**Structurally it IS one layer too deep**, and the two facts below are both true — do not let either one
talk you out of the other:

- `0xC499ec76…` has **no `aggregator()` and no `phaseId()`**, so it is the raw aggregator, not the
  `EACAggregatorProxy` consumers are meant to read. Every other configured mainnet rate leg *is* a
  proxy: lsETH/ETH `0xE858728e…`, stETH/ETH `0x86392dC1…`, rETH/ETH `0x536218f9…`. **ETHx is the only
  one pointing at an aggregator.** A proxy fronting this aggregator would very likely be ungated, since
  Chainlink allowlists its own proxies.
- **but** `FeedRegistry.getFeed(ETHx, ETH)` genuinely returns that **same** gated address — re-measured
  2026-07-30 against live mainnet. It does **not** revert. (`getFeed(ETHx, **USD**)` is what reverts
  `Feed not found`; the config `$comment`'s true statement is about ETHx/USD, and conflating the two in
  either direction has now misled two sessions.) So **Chainlink's own registry offers no ungated
  route** — which is why the earlier flat claim "there is no ungated ETHx/ETH route" was too strong: the
  registry not offering one is not proof that no proxy exists.

So the fix to look for is the `EACAggregatorProxy` whose `aggregator()` returns `0xC499ec76…`. **Do not
guess it** — no such address appears anywhere in this repo. Prove a candidate with four checks, the last
of which is the one that actually matters: `aggregator()` == `0xC499ec76…`, `description() ==
"ETHx / ETH"`, `decimals() == 18`, and **readable from a contract context**, not merely from `cast` (see
§3). If no such proxy exists, the decision below stands.

**A `description()`-based pre-deploy guard would NOT have caught this**, because `description()` on the
bad address is *correct* — `"ETHx / ETH"`, 18 decimals. What caught it was constructing the feed from a
contract. **"Right pair" and "usable on-chain" are independent properties**, and a rate-feed guard has to
check both.

The superseded Redstone feed `0xc799194cAa24E2874Efa89b4Bf5c92a530B047FF` has no access control and *is*
contract-readable, but is being sunset — which is what prompted the migration.

**Blast radius while unresolved:** the direct Redstone ETHx/USD monitor was removed 2026-07-27 with no
replacement, leaving `ETHxCrossRate` as ETHx's only monitor — so for as long as it is undeployable, ETHx
has **zero** divergence checks. `preflight_config.py` reports exactly this as a WARN.

**Scope of the defect is narrow.** All 91 feed addresses in mainnet config, plus every feed address on
10 / 56 / 100 / 137 / 8453 / 42161, were swept for `checkEnabled()`: **this is the only gated feed
anywhere.** So this is one bad address, not a class.

**The decision is the user's** and the redeploy cannot proceed until it is made — drop the ETHx
cross-rate monitor (ETHx's primary is unaffected; it reads Stader's on-chain rate), or obtain a
Chainlink allowlisting for the feed contract, which needs its address in advance. See the §3 subsection
on why an EOA `eth_call` could never have caught this.

### BLOCKER 2 — a reverting `03` corrupts the deployment record

Documented in full at §5's step-1.1 trap, which is now written as a **post-failure recovery
requirement**: after any failed `03`, re-run 1.1 before retrying, unconditionally.

### Unresolved at the time — SINCE RESOLVED, see §10.3

> **It was an instrument defect, not a chain fact:** `snapshot_production.py` read `latest - 3`, and on a
> fork those three blocks hold the tail of the deploy. Fixed in #221. Kept here because the *reasoning*
> that cracked it is the reusable part.

Two instruments disagreed about the same fork state. The rehearsal's own assertions read
`getAdapterCount()` = **27** with the meta loop summing **66/66** (PASS); `snapshot_production.py`,
moments later on the same live fork, read `getAllAdapters()` = **24** and **58** instances, with
`EulerVaultsMeta`, `StakeWiseV3VaultsMeta` and `UniswapV3PoolsMeta` absent from the returned array
(all three present in the record, so `04` deployed them). Cause not established; anvil was torn down
before it could be probed, and the run was invalid downstream of `03` anyway.

**If real it is a §4.4 STOP condition** (adapter/meta-instance counts below the configured totals).
Resolve it on the re-run with the fork held open via `$REHEARSAL_HOOK` — do not let it be rationalised
away, and do not trust either count until they agree.

### The §4 NAV comparison did NOT run — IT HAS SINCE RUN, and PASSED. See §10.1

Only 1 of 43 assets registered, so there is no valid pre-versus-rehearsed diff. **The redeploy's
central question — is this the same portfolio? — is still unanswered**, and it is the first priority of
the re-run. Everything else is secondary.

### What the run did confirm

- **Both regenerated pins are correct against deployable bytecode.** The libraries CREATE2-deployed to
  exactly `0x8b7e4fA91490ADe5D52F1755c9e1D91618cd7dc1` and
  `0x5f5D054E021A53E1DEF54B3Bda3c939ccD14fd90` from a clean local build, with `01_2`'s four pin
  assertions passing. That is an actual deployment landing on the pinned address — strictly stronger
  than any CI check, which can only ever show a test reading a constant back.
- **The proxy moves**: new proxy `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214` ≠ live
  `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d`, so `DeploySalts.NAV_PROXY = 7` is good. Fresh
  `ERC20Default` `0x4Bc39Dce61245F5A63189d1FA03E6D76646f1EE6`, matching on-chain.
- **All three assistant `ADAPTER()` pointers paired correctly** — the fix for the four live orphans.
- `preflight_config.py`: 0 errors across 24 chains, totals exactly as §6 (33 / 110 / 12 / 40 / 93).
- The disposable-config rail restored `script/config` and `broadcast/` byte-exactly; `deployments/1.json`
  verified identical to `HEAD` by hash afterwards. **Always check this** — 18 phantom addresses in a
  deployments record is the worst thing that could leak out of a rehearsal.

---

## 10. The run that PASSED — 2026-07-30, and the answer to the central question

Fourth attempt, `ANVIL_PORT=8600`, fork **pinned at mainnet block 25645948**, against `main` @ `7efcc8af`
plus #220 (ETHx rate-leg proxy) and the two tooling PRs below. **`REHEARSAL_EXIT=0`.** Nothing touched a
live proxy; every broadcast went to loopback anvil.

| step | time | gas | status |
|---|---|---|---|
| `01_2_DeployNAVImplementation` | 5s | 17,503,955 | OK |
| `02_2_DeployNAVProxy` | 5s | 2,369,608 | OK |
| `03_DeployPriceFeeds` | 63s | 19,605,815 | OK |
| `RegisterAssets` | 79s | 22,846,969 | OK |
| `04_DeployBalanceAdapters` | 20s | 64,430,104 | OK |
| `06_Configure` | 11s | 7,310,219 | OK |

Every post-condition PASS. **`verify_step.py` 1.2 – 1.7 all exit 0.** 27 adapters, **43/43 assets**,
**66/66 meta instances**, all three assistant `ADAPTER()` pointers paired. New proxy
`0x54EaD2A1…6214`, fresh `ERC20Default` `0x4Bc39Dce…1eE6`. Both library pins CREATE2-landed on
`0x8b7e4fA9…7dc1` / `0x5f5D054E…fd90` for the third independent time.

### 10.1 Is it the same portfolio? YES

`snapshots/pre/` (block 25625439) versus the rehearsed stack (block 25646118) — 2.9 days apart:

- **Debt legs identical on all nine accounts** (2 / 1 / 1 / 1 preserved). No debt leg lost — the §4.4
  condition that matters most.
- **No `positionId` changed anywhere.** Aave V3 was *permitted* to differ (#172) and did not.
- **27 / 27 adapters, 66 / 66 meta instances, 43 / 43 assets.**
- Position counts identical on 7 of 9 accounts; the two that moved are explained below.
- NAV within ±0.8% on seven accounts; two rises, both attributed.

Nine `DIFF` lines, every one attributed — **no residual**:

| difference | classification |
|---|---|
| proxy / implementation / `ERC20Default` moved | §4.2 expected by construction |
| `ETHx` monitors 2 → 1 (Redstone dropped, Custom kept) | §4.3 Redstone ETHx sunset. The surviving Custom monitor **is** `ETHxCrossRate` — the ETHx fix working end to end |
| `stETH` gains a Custom monitor | §4.3 `stETHCrossRate` demoted to monitor (#199) |
| StakeWise labels `('Vault',)` → `('Vault','ETH 0x…')` | §4.3 symbol+address leaves (#163/#176) |
| `Aave Umbrella` → `Aave V3` protocolName | §4.3 `protocolName()` derived from `_protocolId()` |
| ACCOUNT_11 LOST wallet wstETH, GAINED `lido-withdrawal` | **real activity**, verified on-chain |
| ACCOUNT_9 GAINED wallet USDC + WETH + `lido-withdrawal` | **real activity**, verified on-chain |
| ACCOUNT_1 nav +2.41%, ACCOUNT_9 +1.13% | attributed — see below |

### 10.2 How the deltas were attributed — the method, not the numbers

Two rises had to be explained rather than tolerated, and the §4.1 rule as originally written would have
called both a STOP. Both were resolved by measurement:

**Position-set changes are real portfolio activity, checked against live mainnet archive state at *both*
block heights** — never inferred from plausibility:

| | @pre 25625439 | @fork 25645948 |
|---|---|---|
| ACCOUNT_11 Lido withdrawal requests | 0 | 1 |
| ACCOUNT_11 wstETH wallet | 311.36 | 0 |
| ACCOUNT_9 Lido withdrawal requests | 0 | 1 |
| ACCOUNT_9 USDC wallet | 0 | 277,438.21 |
| ACCOUNT_9 WETH wallet | 0 | 75.63 |

ACCOUNT_11 unstaked: wallet wstETH left, a withdrawal request appeared. The new stack reports what the
account actually holds.

**ACCOUNT_1's +2.41% on an IDENTICAL position set is the one worth copying.** The tempting explanation
was the deliberate stETH primary-feed change (§4.3), which *would* raise a reported value. It was tested
and **ruled out**: every price moved ≤ 0.04% and the account holds no stETH at all — it is entirely
stablecoins. The movement was in *amounts* — GHO Supplied +61.7%, USDT Supplied −54.5%, USDC Supplied
+6.5% — i.e. real lending activity. **Attributing a delta to the mechanism you expect, without checking
whether that mechanism is even in play, is the easy error here.** Compare prices and amounts separately.

### 10.3 §9's blockers — both closed, plus two instrument defects found on the way

- **BLOCKER 1 (ETHx) — FIXED** by #220 repointing the rate leg to the `EACAggregatorProxy`
  `0xC5f8c4aB091Be1A899214c0C3636ca33DcA0C547`. Verified independently of its CI: `aggregator()` returns
  the old raw address, `description() == "ETHx / ETH"`, `decimals() == 18`, and — decisively — the gated
  aggregator's allowlist contains **the proxy** (`hasAccess` true) and not arbitrary contracts, which is
  the mechanism by which a contract read now succeeds. `03` then constructed all 25 mainnet feeds
  including `ETHx_CrossRateCustomPriceFeed`. **The class is closed:** a sweep of all 83 configured
  Chainlink-shaped addresses across the four chains found 63 proxies, 19 RedStone feeds and exactly one
  raw access-controlled aggregator — ETHx.
- **BLOCKER 2 (record pollution) — unchanged and still true.** §5's step-1.1 rule stands.
- **`RegisterAssets` MemoryOOG was NOT a product defect** — this script ran every step on the default
  profile while the runbook requires `FOUNDRY_PROFILE=slow` for step 1.5 (16 GiB vs 1 GiB limits). It
  only surfaced once the ETHx fix let all 86 actions actually be planned. Fixed in #214.
- **The 27-vs-24 discrepancy was an instrument defect, now root-caused.** `snapshot_production.py` read
  `latest - 3`; on a fork with `--slow` the last three blocks *are* the tail of the deploy, so it silently
  omitted the final three registrations with `errors: []`. It manufactured the exact evidence for a §4.4
  STOP against a correct deploy. What cracked it was a source fact, not more measurement:
  `getAllAdapters()` and `getAdapterCount()` read the same storage array, so they cannot disagree about
  one block — which turned "which number is right?" into "which block?". Fixed in #221.
- **anvil panics on an upstream state-read failure** (`do_mine_block`, connection reset) and took two
  attempts down. Retry/timeout/backoff raised in #214; pin the fork block, which also makes retries cheap
  via foundry's per-(chain, block) cache.

**The deploy remains unauthorised.** This run cleared the gate that was blocking it; that is not permission.
