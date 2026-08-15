# NAV stack — from-scratch redeploy runbook

Ordered, per-chain command sequence for the full redeploy of the NAV stack onto a **new proxy**, with
the precondition and post-condition of every step. Written 2026-07-27, revised 2026-07-29 against
`main` @ `dc5810eb` — the hardening wave is complete and a short merge train still runs ahead of the
two-library pin regen (0.1, 0.3).

Revised again 2026-07-30: **why** this is a new proxy rather than a UUPS implementation upgrade is now
recorded below, with the consequences that follow from it, and the custom-feed count corrected to 41.

Revised again 2026-08-08 against `main` @ `a3974686`, which is **399 commits after the `dc5810eb`
reading above**. The two dated paragraphs above are left exactly as written; this pass corrected the
places where they, and the sections they point at, describe a state that has since changed. What moved:
the merge train named above **has landed** (0.1), and the pin regen **has run twice and the pin moved
again after the second one** (0.3). Every configured count in this section was re-measured and is
unchanged.

Both of that pass's open questions were closed the same day, and the results are recorded where they
belong rather than here — **0.3's pins are verified by a local clean build** at `a3974686`, and **the
first fork rehearsal ever run against `main`** (rather than a PR branch head) passed end to end. Two
things came out of that rehearsal that this document did not previously say and that will bite the next
operator: **pin the fork block** (see the note at the rehearsal invocation — it is the difference between
209 s and a 2,915 s hang) and **`NAVRegistryLib`'s salt seed is the mixed-case literal
`"NavRegistryLib"`** (see 0.3 — the all-caps spelling manufactures a false drift report).

**None of this means the system is deployed. It is not.** A fork rehearsal is evidence that the deploy
path executes; it is not a deploy, and it is not an approval to deploy.

Companion tooling lives in [`preflight/`](preflight/README.md). The only script there that broadcasts
at all is `rehearse_fork.sh`, whose RPC is built as loopback (`:49`) and refused otherwise (`:57`).
Four of its scripts write **git-tracked** files — and because that list has been wrong before,
**`git status` is the check of record, not this paragraph**:

- `reset_deployment_records.py --apply` — archives the in-scope records under
  `script/deploy/preflight/archive/<tag>/`, then clears the NAV keys in `script/config/deployments/`
  (and adds a blank `AssetKindRegistry` where a record lacks one); the bridge keys are deliberately
  kept (see 1.1). Dry-run by default. `--restore <tag>` reads that archive back — pass the same chain
  ids you cleared, or the run reports every other declared chain as `MISSING` and exits 1. **Note the
  dry-run default guards `--apply` only:** `--restore` is dispatched before it and writes
  unconditionally, keeping no archive of what it overwrote — judge by the flag you passed, not by
  the absence of `--apply`.
- `snapshot_production.py` — an `--out` value with no `/` names a directory under
  `preflight/snapshots/`; one containing a `/` is taken as a path in its own right (`:346`). It
  **defaults to `--out pre`**, the committed capture, and the documented pre-deploy step passes
  `--out pre` deliberately. Judge safety by the destination it resolves to, not by the flag text.
- `declared_heartbeat_guard.py --refresh` — rewrites the committed `chainlink_declared_heartbeats.json`.
- `rehearse_fork.sh` — mutates `script/config/` and `broadcast/` during a rehearsal, refuses to start
  if either is dirty (`:63` — those two paths only, not the whole tree), and on exit restores tracked
  files with `git checkout --` (`:386`) **and deletes untracked, non-ignored ones with
  `git clean -fdq`** (`:393`) under those same two paths. Two of its outputs land outside that
  cleanup and outside `git status`: `safe-transactions/` in the repo root, which is **gitignored**, so
  it survives every rehearsal and does not show up even under `--untracked-files=all` (use
  `--ignored`, or just look); and `steps.tsv`, `config-before`/`config-after` and `anvil.log` under
  `$WORK`, which defaults to `/tmp/nav-rehearsal-<chainId>`.

These tools take destinations from you — each `--json` report path, `snapshot_production.py`'s
`--out`, `reset_deployment_records.py`'s `--tag`, `rehearse_fork.sh`'s `$REHEARSAL_DIR`. Do not
expect one to stop you pointing it somewhere harmful: from the repo root `--out
script/config/deployments` would write snapshots over the deployment records, and `--tag /tmp/x` puts
the archive outside the repo. The four bullets above describe the **documented invocations**, not a
guarantee the tools enforce.

Reversibility is a property of *when you are*, not of the tool, so check what the target holds before
assuming an undo exists: once a step has written new addresses into `script/config/deployments/`,
`git checkout --` discards them and `--restore <tag>` writes the previous generation back over them.
Keep `archive/<tag>/` until the deploy has been *verified*, not merely until rollback stops being
wanted: `verify_step.py` requires it as the step 1.1 post-condition (`:252`).

- **Scope:** exactly the **24 chains** that already have a `NAVCalculatorProxy`. Chain **1101**
  (Polygon zkEVM) is excluded — its deployment record is empty, so it was never deployed.
- **Bridge is deferred.** `src/bridge/` was untouched by the wave and holds no NAV reference.
- **Step 07 (admin handoff) is NOT part of this deploy.** The deployer EOA keeps
  `DEFAULT_ADMIN_ROLE` + `MANAGER` on every chain afterwards.

| chains | what they get |
| --- | --- |
| all 24 | 2 libraries + NAV impl + **new** proxy + ERC20Default (minted by `initialize`) |
| 1, 10, 56, 100, 137, 8453, 42161 | + custom price feeds, balance adapters, assistants, full NAV config |
| the other 17 | ERC20Default only |

Configured totals, reconciled from config **and** confirmed against the live NAV on 2026-07-27;
feed count re-measured 2026-07-30 against the merged tree; meta instances amended 2026-08-12 (issue
#296, see "Meta instances" below — that one figure post-dates the 2026-07-27 confirmation):
**34 meta adapters, 113 meta instances, 13 plain adapters, 41 custom price feeds, 93 assets.**
<!-- 2026-08-15 (PR #308): meta adapters 33 -> 34 (SymbioticVaultsMeta), meta instances 111 -> 113
     (KPK USDC LiquidLane on the new adapter + KPK wARS Yield on MorphoVaultsMeta), custom price feeds
     40 -> 41 and assets 92 -> 93 (wARS via InvertedChainlinkCustomPriceFeed). Mainnet alone: meta 15 ->
     16, instances 67 -> 69, feeds 25 -> 26, assets 42 -> 43. Verified by `preflight_config.py`
     (0 errors / 24 chains) and by a full fork rehearsal that reconciled 29 adapters / 69 instances /
     43 assets on-chain. -->
<!-- meta instances 110 -> 111 on 2026-08-12: one MorphoVaultsMeta instance added on chain 1 (issue #296). See the amendment under "Meta instances" below. -->
<!-- feeds 41 -> 40 and assets 93 -> 92 on 2026-08-12: OETH removed from mainnet, Chainlink sunsetting its OETH/ETH rate feed 0x703118C4CbccCBF2AB31913e0f8075fbbb15f563. -->
<!-- plain adapters 12 -> 13 by #285: the combined Cap adapter split into CapStablecoin + CapSavings. -->
<!-- FOUR of the five totals have now moved since the 2026-07-27 confirmation, from three independent
     PRs. As of PR #308 NONE of the five is still the originally-confirmed figure — `meta adapters` was the last, and it moved 33 -> 34. Each amendment carries its
     own comment above; do not consolidate them, the provenance is the point. -->


The feed count is no longer pending anything — see the note under 1.5 for the two PRs that moved it.

**Re-measured 2026-08-08 at `a3974686` with `preflight_config.py`: all five totals and every per-chain
row below were unchanged AS OF THAT COMMIT.** (Superseded for FOUR of the five figures now, from three
independent PRs, all dated 2026-08-12: meta instances moved 110 -> 111 and mainnet 66 -> 67 for issue
#296; OETH's retirement moved custom price feeds 41 -> 40 and assets 93 -> 92 fleet-wide, with mainnet
26 -> 25 feeds and 43 -> 42 assets; and the Cap split moved plain adapters 12 -> 13 with mainnet
11 -> 12, per the table below. **Only `meta adapters` (33) is still the figure this attestation
confirmed.** It is left dated rather than restated — it was true of `a3974686` and is not a claim about
today's tree.) `script/config/` did change in the interval (labels were retired in #275 and realigned
to `ProtocolNames.sol`), so this was measured rather than assumed — but nothing moved a count then.
`0 error(s)` across all 24 chains; the warnings it prints are declared-heartbeat margin findings, which
are a separate axis and not a count.

⚠️ **One total has moved SINCE that measurement: plain adapters, 12 → 13.** The combined `Cap` adapter
was split into `CapStablecoin` + `CapSavings` (one adapter per leg, so each label segment is a
per-adapter constant an `AssetKindRegistry` override can address). Chain 1's `plain` column goes
**11 → 12** and the fleet total **12 → 13**. Nothing else moves:

| total | before | after | why |
| --- | --- | --- | --- |
| plain adapters | 12 | **13** | one `Cap` key replaced by two |
| meta adapters | 33 | 33 | Cap is a plain adapter |
| meta instances | 111 | 111 | ditto — **step 1.8's per-adapter set assertion is untouched** |
| custom price feeds | 40 | 40 | no feed involved |
| assets | 92 | 92 | both legs are still valued in the already-registered USDC |

⚠️ **The `meta instances` row reads 111, not the 110 this table carried before #298 merged.** The two
changes are independent and BOTH apply: #296 added one `MorphoVaultsMeta` instance on chain 1 (110 ->
111, mainnet 66 -> 67) and #285 split one plain adapter into two (12 -> 13, mainnet 11 -> 12). Neither
supersedes the other, and the chain-1 row below carries both — 67 instances AND 12 plain. A resolution
that took either side of the conflict wholesale would have silently reverted the other PR's count.

**The tooling moves with it and needs no edit.** `preflight_config.py` derives `plainAdapters` from
`len(enabled_keys(nav-config/balance-adapters/<id>.json))`, and `verify_step.py` **1.7** asserts
`len(record.balanceAdapters) == plainAdapters + metaAdapters + 1` plus set equality on the KEY NAMES —
both read config, so both expect 13 the moment the config lands. This table is the thing that goes
stale, which is why it is stated here. (Note 111 is **1.8**'s number, not 1.7's; 1.7 does not look at
meta instances at all.)

| chain | meta adapters | meta instances | plain | feeds | assets |
| --- | --- | --- | --- | --- | --- |
| 1 mainnet | 16 | 69 | 12 | 26 | 43 |
| 42161 arbitrum | 7 | 16 | 0 | 8 | 11 |
| 8453 base | 6 | 16 | 0 | 4 | 11 |
| 10 optimism | 2 | 4 | 0 | 0 | 6 |
| 100 gnosis | 2 | 4 | 1 | 3 | 11 |
| 137 polygon | 1 | 4 | 0 | 0 | 5 |
| 56 bsc | 0 | 0 | 0 | 0 | 6 |

("plain" excludes `ERC20Default`, which every chain gets automatically. Chain 56's only meta adapter,
`PancakeSwapV2PoolsMeta`, is `enabled: false` in nav-config, so BSC registers `ERC20Default` only. The
`meta adapters` and `meta instances` columns above are a summary of the table immediately below, which
is where they are derived and which is the authoritative one if the two ever disagree.)

#### Meta instances: **111** — the figure to compare a tool's output against

*(**110** was derived from config across all 24 chains, and confirmed ON-CHAIN on the 7 configured
chains, on 2026-07-29 by the method below — the two scopes differ and are not interchangeable; **+1 on 2026-08-12** for issue #296, one `MorphoVaultsMeta` instance on chain 1. The heading
carries the CURRENT number because step 1.8 compares against it; the dated derivation keeps its own date
and scope below rather than being restated as covering the later change.)*

> ⚠️ **AMENDED 2026-08-12 — the expected total is now 111, and `mainnet` is 67 rather than 66.** One
> `MorphoVaultsMeta` instance was added to chain 1's config (the KPK USDC Yield RWA vault,
> `0x7a72bcD2c3F7F7e4D6679170a0625bAB15D7DDa1`) to match a change already made on the LIVE NAV by
> `addMetaInstances` on 2026-08-12 (tx `0x1b86d482…b7024`, block 25739090). Without it `06_Configure`
> would reconcile the on-chain set back DOWN and drop the vault, re-introducing the under-reporting that
> transaction fixed — see issue #296.
>
> **What was rewritten and what was not, deliberately.** The per-chain DERIVATION TABLE below, the
> headline totals, and the summary row **have been updated to 111 / 67**, because the note under the summary table designates that
> table as "where they are derived and which is the authoritative one if the two ever disagree" — a table
> derived from config must move when config moves, or the document's own source of truth becomes the one
> wrong place. What is NOT rewritten is the **dated 2026-07-29 claim**, which now sits in the italic
> note directly under the heading rather than in the heading itself. Its scope was: derived from config
> across all 24 chains, and confirmed ON-CHAIN on the 7 configured chains (see the 1.8 set comparison
> below, and the pre-deploy capture in step 0.7 — NOT step 0.6, which funds the deployer). This change
> is one adapter on one chain, so restating that date's scope as
> though it covered today would destroy the provenance of both. What was
> measured today
> is narrower and is stated as such: `getMetaInstances(MorphoVaultsMeta)` on the live NAV
> (`0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d`) returns **10** entries for chain 1, and chain 1's config
> list now matches it exactly — same members, same order.
>
> Every other adapter and chain is untouched. **Four figures in the table below move, and they are the
> COMPONENT columns as well as the totals** — an amendment naming only the totals would leave the columns
> not summing to them:
>
> | figure | was | now |
> | --- | --- | --- |
> | mainnet `instances` | 52 | **53** |
> | mainnet total | 66 | **67** |
> | fleet `instances` | 90 | **91** |
> | fleet total | 110 | **111** |
>
> `instancesRaw` is unchanged everywhere (14 on mainnet, 20 fleet-wide) — this vault is an address
> coordinate, not a raw `bytes32` marketId. Re-derived from config at this branch's head rather than
> assumed: mainnet's `instances` sum to 53 and `instancesRaw` to 14 across the 15 enabled meta adapters.
>
> **Every ACTIONABLE figure in this document has been updated in place to 111 / 67.** The list below is
> illustrative, NOT exhaustive — measured at 2026-08-12 there are **twelve** such sites, and two
> hand-written lists of them (this one and the step-1.8 post-condition) were both short. **To find them
> all, grep for the FIGURE and not for a remembered phrase:** `grep -nE '\b(111|67|53|91|114)\b'` over
> this file, then discard gas figures and dated records. A maintained list of sites is the same
> documentary-guard shape this repo rejects everywhere else. Illustrative sites: the headline
> totals, the summary row, the derivation table, the two independent confirmations, the disabled-adapter
> arithmetic (now 111 + 3 = 114) and the step-1.8 post-condition. An operator is never asked to
> mentally substitute a value: where a number is compared against a tool's output, it is the current
> number. What is preserved as dated prose is the METHOD and DATE of the 2026-07-29 derivation, not its
> totals — the same figure was doing two jobs with opposite requirements, and they are now separated.

This number is what tells you at step 1.8 whether `06_Configure`'s reconciliation succeeded, so it is
settled here rather than at execution time. Three figures had been circulating — 104, 110 and 113
(the latter two now 111 and 114 after the 2026-08-12 amendment; the historical figures are named here
as they circulated, and the paragraphs below explain the CURRENT values).

| chain | enabled meta adapters | `instances` | `instancesRaw` | total |
| --- | --- | --- | --- | --- |
| 1 mainnet | 15 | 53 | 14 | **67** |
| 42161 arbitrum | 7 | 14 | 2 | **16** |
| 8453 base | 6 | 12 | 4 | **16** |
| 10 optimism | 2 | 4 | 0 | **4** |
| 100 gnosis | 2 | 4 | 0 | **4** |
| 137 polygon | 1 | 4 | 0 | **4** |
| 56 bsc | 0 | 0 | 0 | **0** |
| **total** | **33** | **91** | **20** | **111** |

Counted from `script/config/nav-config/meta-balance-adapters/<chainId>.json`, taking only adapters
with `enabled: true` and summing `instances` + `instancesRaw`. Two independent confirmations: the
deduplicated count is also 111 (no coordinate repeats within an adapter, so `06` cannot revert
`DuplicateMetaInstance`), and unique `(chain, coordinate)` pairs across *all* adapters is also 111
(no coordinate is claimed by two adapters on one chain). Both dedup figures are re-derived from
today's config and so carry the amended 111.

**The all-chain set comparison below is NOT re-derived — it is a dated result and it covers the 110
state.** On 2026-07-29 `verify_step.py 1.8` compared each adapter's on-chain `getMetaInstances()`
against config as a SET on all 7 configured chains and passed, so config and the live NAV agreed
exactly, not merely in total — **at that time, at 110**. The 2026-08-12 check behind the +1 was much
narrower: `getMetaInstances(MorphoVaultsMeta)` on chain 1 only. Re-running 1.8 across all 7 chains
against the amended config has NOT been done, and this paragraph does not claim it has.

**Where the other two figures come from:**

- **114** = every adapter in the files, ignoring `enabled`. The difference is **four** disabled meta
  adapters (37 in the files, 33 enabled), and they do NOT carry one instance each — the +3 is a
  coincidence of which ones are non-empty. Measured from `nav-config/meta-balance-adapters/*.json`:
  mainnet `BalancerV2PoolsMeta` (`instances` 0, `instancesRaw` 1), mainnet `BalancerV2GaugesMeta`
  (1, 0), bsc `PancakeSwapV2PoolsMeta` (1, 0), and base `PancakeSwapV3PoolsMeta` (0, 0) — the last
  contributes nothing **today**, so the day it gains an instance this reconciliation goes short. `ConfigReader.isAdapterEnabled` gates registration and a missing key
  reads as **false** (`ConfigReader.sol:368-369`), so `06` will not register any of them. 111 + 3 = 114.
- **104** is not reproducible from the current tree by any derivation — not `instances` alone (91),
  not the deploy-config tree (0, it holds no instance lists), not any enabled-filter variant. It
  predates the config split in `f4873617` and should be treated as retired, not reconciled.

Do not re-derive this by hand on deploy day. `preflight_config.py` prints the configured total and
`verify_step.py 1.8` asserts it per adapter against the chain; if a future config change moves the
number, those two move with it and this table is the thing that goes stale.

### Why this is a NEW PROXY and not an implementation upgrade

`NAVCalculator` is UUPS-upgradeable, so the cheap reading of this wave is "upgrade the implementation
behind `0x80eD5cc6…` and stop". **This is a deliberate decision not to do that**, and the reason is a
single contract: `ERC20DefaultBalanceAdapter` is minted *inside* `initialize()`, and **nothing in the
implementation or admin surface that exists today can replace it.**

- **It is deployed by `initialize()` itself** —
  `_setErc20DefaultBalanceAdapter(NAVRegistryLib.deployDefaultAdapter(initialAssets))`
  (`NAVCalculator.sol:86`), which runs once per proxy and never again.
- **The setter is set-once.** `_setErc20DefaultBalanceAdapter` reverts `InvalidArguments()` when
  `erc20DefaultBalanceAdapter != address(0)` (`Balances.sol:93-97`). It is `internal`, it has exactly
  **one call site in all of `src/`** — the `initialize()` line above — and **no public, admin or
  governance setter exists anywhere in the current tree.**
- **It is unremovable through the registry.** Both `NAVRegistryLib.removeBalanceAdapter` (`:181`) and
  `removeBalanceAdapters` (`:245`) revert `InvalidArguments()` when handed it, explicitly and by name.

So with the code as it stands, no upgrade, no config transaction and no admin call repoints a live
proxy at a new ERC20Default. Shipping the wave as an implementation-only upgrade would therefore
deliver every other fix and leave the wallet adapter — the one adapter every chain and every account
uses — running the **old** bytecode.

> **State this as a decision, not an impossibility — the honest version is the more persuasive one.**
> UUPS places no limit on what an upgrade may contain, so an implementation *could* carry bespoke
> migration logic that repoints ERC20Default. Claiming otherwise invites the one obvious objection
> ("then add a setter in the upgrade") and collapses the rationale into an argument. The precise claim
> survives it, because the choice was never possible-versus-impossible. It is cost and risk:
>
> | the in-place route would have to | the new-proxy route |
> | --- | --- |
> | write migration logic that **does not exist today** — `erc20DefaultBalanceAdapter` is plain storage (`Balances.sol:56`), so an upgrade can assign it, but the set-once helper will not do it | `initialize()` does it, on a path already exercised on 24 chains |
> | also repair three private registry structures by hand, since the helper that normally maintains them is bypassed: `_globalAdapters` (`:46` — remove old, push new), `_adapterTypes` (`:49`), `_isAdapterRegistered` (`:52`) | maintained by `_setErc20DefaultBalanceAdapter` as a unit |
> | re-seed the inclusion list — via the constructor's un-registry-checked `initialAssets` seed, or `addSupportedAsset`, which is `OnlyNAVCalculator`-gated and demands `isAssetRegistered` | `RegisterAssets` populates it as a side effect of 1.6 |
> | **deploy a new adapter anyway** — the adapter itself is immutable, so nothing here avoids that | same |
> | be audited as one-off code, then either be removed by a *second* upgrade or leave a permanent setter widening the admin surface of a contract whose immutability is load-bearing | no new surface |
> | all of it against a **live** proxy holding the production registry | against an empty proxy, with the old stack still answering as a fallback |
>
> Same end state, strictly more code, strictly more risk, on the harder target. **That** is why the
> redeploy takes a new proxy — not because repointing is forbidden.

**Its bytecode did change in this wave, so this is not hypothetical.** Counts from
`git diff --numstat 2bc8ba73..origin/main` — `2bc8ba73` is #159, the commit deployed to all 24 chains
on 2026-07-25, and the same baseline the published contract-delta changelog measures against:

| file | change | how it reaches ERC20Default |
| --- | --- | --- |
| `ERC20DefaultBalanceAdapter.sol` | +43 / −11 | directly |
| `BalanceAdapterBase.sol` | +8 / −3 | its base contract |
| `LabelLib.sol` | +154 / −23 | **inlined** — see below |

> **Quote these as `--numstat` pairs and nothing else.** `git diff --stat` renders a bar graph beside a
> single *total-changed-lines* figure, so reading a count off it yields 54 and 11 for the first two rows
> — the sums, presented as though they were insertions. That reading has already been passed between
> documents once. When the count itself is the claim, `--numstat` is the instrument.
>
> The figures are also **baseline-insensitive across the plausible candidates**: identical from
> `2bc8ba73` (2026-07-25) and from `06d28d0f` (2026-07-22), so a disagreement over which commit is
> "the deployed tree" cannot explain a difference in them.

`LabelLib` is the one that catches people out. Its readers are `internal` (`name` `:88`, `symbol`
`:94`, `readString` `:108`), so they are **compiled into every caller** and there is no library
address to swap; ERC20Default calls `LabelLib.symbol` at `:213`. A `LabelLib` fix therefore reaches a
contract **only when that contract is itself recompiled and redeployed** — which, for ERC20Default,
means a new proxy.

**A rehearsal demonstrated this mechanism empirically once, on 2026-07-30** (mainnet fork,
`REHEARSAL_EXIT=0`): it produced proxy `0x54EaD2A1…`, distinct from the live
`0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d`, carrying a **fresh** ERC20Default `0x4Bc39Dce…` in
place of the live `0x41967559D0a20Ad102F6e27b7723b1963390aD75`. That is the mechanism working as
described, not an anomaly to investigate — and it remains the correct reading of *that* run.

> ⚠️ **That run is NOT evidence that the deploy path works today, and this runbook previously implied it
> was.** The sentence above used to read "the rehearsal already demonstrated the whole chain
> empirically", present-perfect and unqualified. A reader would reasonably conclude the deploy path is
> proven. **It is not.**
>
> **Before the 2026-08-08 run recorded in the closure note below, no fork rehearsal had ever run against
> `main`.** The two most recent were against **PR branch heads** — `a4909342` and `0aebea7a` — and
> `git merge-base --is-ancestor` places **neither** in `main`'s history. The 2026-07-30 run above predates
> every merge since. **Read this paragraph as the state that motivated that closure, never as the current
> state.** What remains true today is narrower and is the reason the paragraph is kept: the 2026-07-30 run
> on its own is still not evidence about `main`.
>
> **The harness that produced those results no longer exists.** #279 rewrote it. As `--numstat` pairs,
> per the house rule above: `rehearse_fork.sh` **+158/−25**, `chainlib.py` **+157/−12**,
> `reset_deployment_records.py` **+33/−3**, and two new test files —
> `script/test/rehearsal-harness-guards.test.sh` **+314/−0** and
> `script/test/env-resolution-guards.test.sh` **+81/−35**. A green result from the old script is not a
> green result from the current one, and #279 exists precisely because the old one **reported success
> for work it never did**.
>
> ✅ **CLOSED 2026-08-08 — the first rehearsal ever run against `main`, and the first against #279's
> rewritten harness.** `REHEARSAL_HEAD == a3974686` (merged `main`, the real artifact — not a PR branch
> head), `EXIT=0`, **8 post-conditions PASS / 0 FAIL**, ~209 s total, one anvil pid throughout.
> **One shot, no retry.**
>
> - [x] `REHEARSAL_EXIT` at `a3974686` — **0**, against merged `main`
> - [x] proxy address differs from the live `0x80eD5cc6…` — asserted by the harness
> - [x] a fresh ERC20Default is minted by `initialize()`
> - [x] no step reported success while doing nothing — **8/0 on post-conditions**, which is the check
>       #279 added and the reason the exit code alone is not the evidence
>
> `RegisterAssets` ran **88 s against its 79 s historical norm** — the same step that previously hung for
> **2,915 s**. `06_Configure` completed in 10 s. **Pin the fork block; see the note at the invocation
> below** — that is what moved this run from "hangs" to "88 s", and it is not optional advice.
>
> **This is fork evidence, not a deploy.** The system is not deployed. It says the deploy path executes
> end to end on this tree; it does not say the deploy has happened or been approved.

#### What a new proxy obliges — the enlargement, in one place

`initialize()` leaves the new proxy holding **one** asset (`NATIVE_ADDRESS`) and **one** adapter (the
fresh ERC20Default). Everything else starts empty, and every deployed contract that hard-codes the
NAV address is invalidated by construction:

| consequence | scale | done at |
| --- | --- | --- |
| every custom price feed is redeployed — each holds `INAVCalculator public immutable NAV` (ADR 0019) | **40**: mainnet 25, arbitrum 8, base 4, gnosis 3 | 1.5 |
| every asset with its primary + monitor feeds is re-registered | **92** assets | 1.6 |
| every plain and meta adapter is redeployed | 13 plain + 33 meta | 1.7 |
| every meta instance is re-registered | **111** | 1.8 |
| each assisted adapter drags its assistant, which holds `immutable ADAPTER` | **4 pairs on 2 chains** | 2.1 |
| downstream consumers repoint off the old proxy | kpkShares, portal, agents, subgraphs | 2.7 |

(⚠️ The `done at` column's last two adapter rows read **1.6 / 1.7** until 2026-08-11 and were both off
by one against `verify_step.py`'s own map, where `1.6` is `RegisterAssets`, `1.7` is `04` and `1.8` is
`06`. §"Meta instances" already said 1.8 for the instance reconcile, so the document contradicted
itself; corrected here rather than left for deploy day.)

None of it is optional, and none of it fails loudly: a step skipped here leaves the new proxy quietly
**under-reporting**, not erroring. That asymmetry is also why "just upgrade the implementation" keeps
looking attractive — it is genuinely far smaller. It is also wrong.

> **If another document disagrees on the feed count, check its DATE before splitting the difference —
> and check whether it counted ENABLED entries.** The count has moved four times: 39 until #199 (merged
> 2026-07-29), 40 until #224 (merged 2026-07-30), 41 until OETH's retirement (2026-08-12), and **40
> again now** — Chainlink sunset the OETH/ETH rate feed, so mainnet's enabled count drops 26 -> 25.
> Re-derived from config on the merged tree: **40 enabled** — mainnet 25 ENABLED (26 entries,
> `ETHPlus` disabled), arbitrum 8, base 4, gnosis 3. The full derivation is under 1.5.
>
> ⚠️ **COUNT ENABLED ENTRIES, NOT ENTRIES**, and note where the two traps meet: counting entries gives
> 26 + 8 + 4 + 3 = **41**, which is exactly the value the ENABLED count legitimately held until
> 2026-08-12. The miscount does not look like a miscount — it looks like a correct slightly-older
> reading, which is why "it matches a figure I have seen" is not a check.
>
> ⚠️ **A count returning to a value it previously held is the nastiest version of this**, because a stale
> document quoting 40 now looks current and agrees with the tree for the wrong reason. Date-check rather
> than value-check. The **111** meta instances and the cutover off
> `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d` are unaffected and agree everywhere.

The old stack is **abandoned in place**, not decommissioned. It keeps answering on
`0x80eD5cc6…` until consumers move, so the cutover is a coordination item rather than an outage —
nothing on the old proxy needs unregistering (2.7).

---

## 0. Blocking prerequisites

Do not start until **all** of these hold.

### 0.1 The hardening wave — landed; so has the merge train that used to run ahead of 0.3

| landed | what it was |
| --- | --- |
| #175, #179 | malformed-`positionId` guards |
| #176 | StakeWise label leaf |
| #177 | cross-adapter enumeration tripwire |
| #178 | adapter gas caps (`PriceFeedLib._getAdapterPositions`, `NAVCalculator._safeStringArray`, the caller-side `registerAsset` codesize guard) |
| #181, #183 | `foundry.lock` drift + its CI guard (see 0.4) |
| #182 | meta-instance gas starvation |
| #186 | per-leaf gas bound on `positionLabels` |
| #189 | Morpho existence invariant + a tighter `protocolName` ceiling |
| #190 | enough runner memory for the `via_ir` build (see 0.8) |
| #191 | the library-pin assertions in `01` (see 1.2) |
| #187 | paginated NAV read over a caller-supplied adapter set |

`main` is at **`a3974686`**. The `89274d50` reading this section used to carry is **399 commits behind**
it, and **nothing in the table below is still open — both entries landed.** The table is kept because
the ordering rule in its second row is still the rule, and because that rule was subsequently broken.

| was listed as open | what actually happened |
| --- | --- |
| the O(1) registry-getter PR (`_getAssetInfo`, "not yet opened") | **opened and merged, as #195** — merged from branch `feat/registered-asset-getter`, which is how it was identified. `_getAssetInfo` is on `main`: `MetaBalanceAdapter.sol:594`, `CapBalanceAdapter.sol:299`, `ERC20DefaultBalanceAdapter.sol:258`. **Cross-reference by the PR number**; the branch is provenance and may be deleted |
| **#185, the regen itself (0.3)** | **merged** — then re-run as the "FINAL" regen in **#274**, after which **#278 moved the `PriceFeedLib` pin again**. "Computed last, against the final tree" was **not** held. See 0.3 |

The "measured, not predicted" instruction in the first row still applies to every future pin question,
and 0.3 is where it now lives.

**Both pinned values WERE regenerated, for two independent reasons — do not attribute either to the
other.** (Historical: this is the record of why each moved, not an outstanding instruction. The regen is
done — see 0.3 — and the pin moved again afterwards in #278; nothing here asks for another.)

- **`PriceFeedLib` moved because #187 edited `src/prices/PriceFeedLib.sol` directly.**
- **`NAVRegistryLib` was already drifted on `main`** before #187 existed, independently of anything in
  flight. Measured across four trees — `main` before #187, and #187 at `66490d6a`, `94dc81be` and
  `0d68fcf4` — its computed value was `0x7Fc30f7a1A3b89040f1CA74CbE71814B4A4dAF04` at **every** one.
  #187 did not move it. (That figure is cited as evidence of *invariance across four trees*, not as a
  value to pin: it is a CI reading, and per 0.3 those are not a reliable source for the pin itself.)

This matters because both `LibraryPinConsistency` tests are red simultaneously, which invites the
conclusion that one in-flight PR moved both. It did not. An earlier revision of this section asserted
that `INAVCalculator.sol` sits in both libraries' compilation closure and therefore any PR touching it
moves both pins; #187 touched that file and `NAVRegistryLib` did not move, so **that reasoning is
wrong and has been removed**. Do not predict a pin movement from the import graph — measure it.

### 0.2 Bump `DeploySalts.NAV_PROXY` — **CONFIRMED REQUIRED, already done (6 → 7)**

The NAV proxy address is
`CREATE2(0x4e59…4956C, keccak256("NAVCalculatorProxy" ++ DeploySalts.NAV_PROXY), UUPSProxy.creationCode ++ abi.encode(placeholder, ""))`.
Its creation code carries **no per-chain and no per-implementation data**, so a new NAV implementation
does **not** move it — unlike the libraries and the impl, whose addresses change automatically because
their bytecode changed.

**Measured on a mainnet fork, 2026-07-27.** With `NAV_PROXY = 6`, `02_2` computed
`0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d` — the live proxy — so `AtomicNAVProxyDeployer` found
code already there, skipped the deploy (`AtomicNAVProxyDeployer.sol:43`), and reverted on
`upgradeToAndCall` holding no admin role:

```
Placeholder impl (same on all chains): 0x85Ee38b0385D042918a59C01dB319b6eDdF7A8Cf
  NAVCalculator proxy: 0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d
[ATOMIC] Deploying placeholder + NAV proxy + upgrade in a single transaction
Error: script failed: NotAuthorized()
```

That would happen on **every chain**. The address did *not* drift on its own because
`UUPSPlaceholder`'s bytecode is unchanged — it still lands at `0x85Ee38b0…`, matching
`DEPLOYED_ADDRESSES.md`. **`NAV_PROXY` is therefore bumped to `7` on this branch.** Re-confirm with
the rehearsal after any further source change, since the placeholder's bytecode *can* shift under
`via_ir` with no source change (the `NAVRegistryLib` precedent):

```bash
script/deploy/preflight/rehearse_fork.sh 1 25708060   # <chainId> <forkBlock> — PIN THE BLOCK
```

> ⚠️ **PIN THE FORK BLOCK. This runbook did not say so before, and that omission cost a 2,915 s hang.**
> `rehearse_fork.sh` takes the block as an optional **second positional argument** (`FORK_BLOCK`,
> `rehearse_fork.sh:47`, passed to anvil as `--fork-block-number`, `:368`). Omit it and you fork
> `latest`, which is the root cause of both failures below. Use a recent finalized block, not the one
> above verbatim — `25708060` is simply the block the 2026-08-08 rehearsal used.
>
> **Correctness.** With the block pinned, the harness logged `fork block 25708060` and anvil served
> **25,708,060** from the second sample onward — **recorded and served heights agree exactly, and the
> ~1.2 M-block gap seen previously does not reproduce.** That gap belongs to **unpinned / `latest`**
> forking — forge and anvil each resolving "latest" at a different moment against a load-balanced
> endpoint — **not to anvil's semantics.** Do not go looking for a bug in anvil; pin the block.
>
> **Cost, which is the part that decides whether your run finishes.** A pinned fork re-reads from
> `~/.foundry/cache/rpc/mainnet/<block>/` instead of pulling fresh every time: **209 s pinned versus
> 2,915 s+ unpinned.** A run that finishes is not spending 12 retries per cache miss. **Pinning is both
> the correctness fix and the cost fix** — there is no tradeoff to weigh here.
>
> **What is NOT settled, and must not be written up as if it were.** Why forge expected block
> **24,492,904** is **unexplained**, and it could not have been answered by the 2026-08-08 run: the
> deadlock never occurred, so forge never entered the block-waiting path and never issued such a request.
> The standing hypothesis — that the deadlock is a consequence of the same unpinned-fork root cause — is
> **evidenced but unproven**. Settling it needs a deliberate reproduction against an unpinned fork on an
> archive RPC. **Nobody has run that, and it should not be run incidentally.**

> **The rehearsal treats the config tree as disposable, and you must let it.** It forks as the *real*
> chain id (ConfigReader keys every path off it), so the deploy scripts rewrite
> `script/config/deployments/<id>.json` wholesale — impl, proxy, every feed, every adapter including
> `ERC20Default` — with **anvil** addresses, and forge writes `broadcast/<script>/1/run-latest.json`,
> indistinguishable from a genuine mainnet broadcast (`.gitignore` only excludes
> `/broadcast/*/31337/`, and `script/verify/sweeps/make_targets.py` enumerates deployed price feeds
> from exactly those files, so a leftover would feed fork addresses into a verification sweep).
>
> `deployments/<id>.json` is the only record of what production runs and the baseline every audit
> diffs against, so `rehearse_fork.sh`: (a) **refuses to start** unless `script/config` and
> `broadcast` are git-clean, (b) restores both on exit with `git checkout --` + `git clean -fd`
> — byte-exact, whatever the run did — and (c) asserts they are clean again, keeping the run's own
> output under `/tmp/nav-rehearsal-<id>/config-after/`. Never blanket-delete `broadcast/`: it also
> holds committed records from the real PR #141 migrations (`MigrateAssistedAdapters`,
> `MigrateGnosisStakeWiseExit`, `RemoveMerkl`).

If the rehearsal's `NAV proxy address differs from the live one` assertion **fails**, bump
`DeploySalts.NAV_PROXY` again and re-run. The bump must land **before** 0.3 — `DeploySalts.sol` is in
the full-project `via_ir` compile scope, so it can move the `PriceFeedLib` pin, and any pin computed
before the bump is stale on arrival.

### 0.3 Regenerate BOTH library pins — last, in its own commit

> ⚠️ **SUPERSEDED TWICE — read this block as the 2026-07-30 record, not as the current pin.** The
> measurement below was real and its method is why it is kept, but the `PriceFeedLib` value it reports is
> **two regens out of date**. `script/utils/LibraryPins.sol` on `main` is the only source of truth for
> the current pins. **0.3 IS now satisfied for the `a3974686` tree** — but by the clean-build measurement
> recorded below, not by this block. Read the closure note, not this table.
>
> ✅ **DONE (2026-07-30).** Measured against the merged tree at `f837f076` from a cold `forge clean && forge build --force`
> (937 s) with `git submodule status` reporting **zero** mismatches:
>
> | library | pinned | |
> |---|---|---|
> | `PriceFeedLib` | `0xcD6F52F4b5F2e563993d1966C27E7E322281Bb26` | moved from `0xfc6AE534…` |
> | `NAVRegistryLib` | `0x5f5D054E021A53E1DEF54B3Bda3c939ccD14fd90` | **unchanged — measured, not assumed** |
>
> Derived twice by independent paths that agreed: the suite's own
> `vm.computeCreate2Address(computeSalt(name,1), keccak256(type(Lib).creationCode), …)`, and a separate
> keccak/CREATE2 computation over the built artifact. All four assertions in `LibraryPinConsistency.t.sol`
> pass on the regenerated tree.

> **What moved after that measurement — the reason the block above is marked superseded.**
>
> - **#274** (`chore(pins): FINAL library pin regeneration against the deploying tree`, `44018255`)
>   replaced `PriceFeedLib` `0xcD6F52F4…` with `0x2a0C3Ce6…`. It touched exactly `foundry.toml` and
>   `script/utils/LibraryPins.sol`, one line each — the discipline this section asks for.
> - **#278** (`38cc6ddd`) then replaced it **again** with `0x784bDE7A…`, which is what
>   `LibraryPins.sol:40` holds at `a3974686`.
> - `NAVRegistryLib` is `0x5f5D054E…` (`LibraryPins.sol:41`) — **unchanged across all three regens**,
>   and still measured rather than assumed.
>
> **#278 changed a pinned library's source and the pin itself in the same commit:**
> `src/prices/PriceFeedLib.sol` **+170/−8** alongside `script/utils/LibraryPins.sol` **+1/−1**. That is
> the exact pattern the paragraph below forbids, and the reason `6b7e4851` is cited there as writing a
> stale-from-birth pin. It does not follow that the new pin is wrong — the pin was regenerated in that
> same commit, so it may well be right — but it does mean **it has not been verified by the process this
> section requires**, and the "computed last, against the final tree" ordering from 0.1 no longer holds:
> `#278` is after the tree that was called final.
>
> ✅ **CLOSED 2026-08-08 — 0.3 is satisfied for `a3974686`. This is the measurement of record: a local
> clean build, not a CI reading, which is exactly what this section demands.**
>
> ⚠️ **READ THIS BEFORE THE BLOCK BELOW, BECAUSE THE BLOCK IS NOT SAFE TO PASTE.** The measurement is
> quoted verbatim, and the verbatim text contains two **non-ASCII** characters: `‖` (U+2016 DOUBLE VERTICAL
> LINE, standing for concatenation) and `…` (U+2026 HORIZONTAL ELLIPSIS, abbreviating the deployer address).
> A shell or script will mangle or reject both. **If you are recomputing the pins, copy this instead** — same
> derivation, ASCII-only, and complete rather than elided:
>
> ```
> version = 1                     # for both libraries
> name    = "PriceFeedLib"        # then repeat with name = "NavRegistryLib"
>                                 # NOTE the mixed case: NavRegistryLib, not NAVRegistryLib
> salt    = keccak256(utf8(name) ++ uint256_be32(version))          # abi.encodePacked(string, uint256)
> addr    = keccak256(0xff ++ 0x4e59b44847b379578588920cA78FbF26c0B4956C ++ salt ++ keccak256(initcode))[12:32]
> ```
>
> `0x4e59b44847b379578588920cA78FbF26c0B4956C` is `CANONICAL_CREATE2_DEPLOYER`
> (`01_2_DeployNAVImplementation.s.sol:22`); the salt encoding is `ConfigReader.computeSalt` (`:833-835`).
>
> **The verbatim record, for citation — not for pasting:**
>
> ```
> Local clean-build measurement of record, a3974686 (not a CI reading):
> PriceFeedLib    computed 0x784bDE7A519B0FA0Ad0c5B2820140501A02B0A62 == recorded in foundry.toml:82 and LibraryPins.sol:40
> NAVRegistryLib  computed 0x5f5D054E021A53E1DEF54B3Bda3c939ccD14fd90 == recorded in foundry.toml:83 and LibraryPins.sol:41
> Derived independently from freshly built artifacts:
>   salt = keccak256(name ‖ uint256(1));  addr = keccak256(0xff ‖ 0x4e59b448… ‖ salt ‖ keccak256(initcode))[12:]
> Sizes byte-identical to 253f6bd6: 7,923 / 24,475 / 24,475 / 24,567 (9 free — the binding CI figure) / 22,920
> ```
>
> **So the same-commit pin change in #278 turned out to be correct** — the pin was regenerated in that
> commit and the value it wrote is what a cold build computes. The process objection above still stands
> as a process objection: it was verified *after* the fact, by this measurement, not by the ordering the
> section asks for. Do not read this as a licence to bundle the next pin with a source change.
>
> 🪤 **THE SALT SEED IS MIXED-CASE `"NavRegistryLib"`, AND GETTING IT WRONG MANUFACTURES A DRIFT REPORT.**
> Per `01_2_DeployNAVImplementation.s.sol:132` the literal is **`"NavRegistryLib"`** — *not*
> `"NAVRegistryLib"`. Seeding the salt with the all-caps spelling yields **`0xf7461247…`** and a **false
> drift report** against a pin that is in fact correct. This is the highest-value trap in 0.3: the failure
> looks exactly like a real stale pin, and the instinct is to regenerate — which would replace a correct
> pin with a wrong one. Copy the literal from the script; never retype it from the library's name.

Own PR, own commit, computed against the **final merged tree** — which already includes the
`DeploySalts.NAV_PROXY` bump from 0.2 (merged in #180 ahead of the regen for this reason). Never in the same commit as a source change — that is exactly how `6b7e4851` wrote a
stale-from-birth pin.

This is a hard gate, not a nicety: `01_2` asserts the computed CREATE2 addresses equal
`LibraryPins.PRICE_FEED_LIB` / `LibraryPins.NAV_REGISTRY_LIB` and that the impl bytecode is linked
against both (`01_2_DeployNAVImplementation.s.sol:46-68`). A wrong pin reverts `01_2` on every chain
before it broadcasts anything.

Iterate to a fixpoint; a 2-cycle has been observed. Always `forge clean` first — an incremental `out/`
yields a wrong address that looks authoritative.

> **A CI reading is only trustworthy if the branch contains #200.** That PR set `cache: false` on the
> Build job; anything measured before it was reading a partially cached compile, which is the most
> likely explanation for the divergent `PriceFeedLib` values seen across branches. Treat every pin
> figure measured on a pre-#200 branch as corroboration at best, never as proof — including the reading
> from #197's own CI run, which predates it.
>
> **Even with #200, a CI reading is not a measurement of record.** Two runs of the same branch 25
> minutes apart, with a one-markdown-file diff and **zero `.sol` changed**, produced two different
> computed `PriceFeedLib` addresses (`0x00a3AFAC…` and `0xD477d7e2…`), both runs' `headSha` confirmed
> via the API. Cause not yet settled — `via_ir` non-determinism or a CI cache effect; the regen
> session is running back-to-back local clean builds to pin it down. Until that is resolved, **the
> regen's own local clean-build measurement is the only source this runbook or `LibraryPins.sol`
> should take a value from.** No pin address is quoted anywhere in this runbook as authoritative for
> that reason — where addresses appear above they record **what `LibraryPins.sol` holds** and **what
> moved between regens**, which is provenance, not a measurement of record. Never copy a pin out of this
> document into `LibraryPins.sol`; the direction of trust runs the other way. See
> `reference_pricefeedlib_pin_drift` for the full history.

### 0.4 Submodules at the recorded commits — **root cause fixed, keep the check**

This was a live hazard during deploy prep and is now resolved. The history is worth keeping because
the failure was silent and would have invalidated every measurement taken against it.

**What went wrong:** a fresh worktree has an empty `lib/`, so `forge build` runs `forge install`. The
committed `foundry.lock` was **malformed JSON** (a trailing comma), so forge discarded it
(`Warning: Failed to parse foundry.lock`) and resolved to remote tips instead — observed moving
`openzeppelin-contracts-upgradeable` from `1334fc17` to `heads/master` and `forge-std` from
`887e8725` to `6e8c4a92`, among others. OZ-upgradeable is in `NAVCalculator`'s inheritance chain, so
that silently changes compiled bytecode and would poison both the library pins and the bytecode audit.
Worse, the lock's revisions also **disagreed with the gitlinks for 5 of 9** submodules, so repairing
only the comma would have made forge honour a lock that installs the *wrong* set.

**Fixed by #181 + #183:** the lock was regenerated from the gitlinks, and CI now asserts they stay in
agreement (`script/ci/check-foundry-lock.sh`, wired into `.github/workflows/foundry.yml`). Verified on
`2077c82e`: the lock parses, has 9 entries, and matches all 9 gitlinks.

Still run the check before building — it is two seconds and it is the thing that goes wrong:

```bash
git submodule update --init --recursive --force
git submodule status | grep -v '^ ' && echo "DRIFT — fix before building" || echo "submodules OK"
```

### 0.5 RPC endpoints for all 24 chains

The Alchemy app behind `ALCHEMY_API_KEY` has most networks **disabled**; only
`eth / opt / gnosis / base / arb` answer. `ConfigReader` resolves 22 of the 24 chains through
`$ALCHEMY` alone (`ConfigReader._resolveRpcUrl`, `ConfigReader.sol:837`), so **19 of the 24 configured
endpoints do not answer** — including **polygon (137), a configured chain**.

**That is endpoint availability, not Foundry reachability, and conflating the two is a trap.**
`ConfigReader` assigns the resolved URL to `chainConfig.rpc` (`ConfigReader.sol:163`) and
`BaseDeployScript.setUp` loads it (`BaseDeployScript.sol:28`) — but **nothing reads it after that**.
There is no production read of `chainConfig.rpc` anywhere under `script/`, and `foundry.toml` declares
neither `[rpc_endpoints]` nor `eth_rpc_url`, so Foundry never sees these URLs at all. The practical
consequence is **stronger** than "19 chains are unreachable": a broadcast needs an explicit
`--rpc-url` on **every** chain, including the five where Alchemy does answer. A resolvable `rpc`
field is not a substitute on any of them.

**Supply the endpoint explicitly on every chain** — `--rpc-url` on every invocation. For **19 of the 24**
the URL comes from that chain's `*_URL` var (`CHAIN_URL_ENV`, `chainlib.py:63-69`). **The remaining five —
`143 monad`, `196 xlayer`, `204 opbnb`, `16661 0g`, `43111 hemi` — have no `*_URL` var at all**, so there
is nothing to source from: pass the provisioned endpoint to `--rpc-url` directly, and if you want the
preflight to see it too, add the chain to `CHAIN_URL_ENV` (a code change, not config). Those five are the
same chains that currently fall back to public RPCs — see the note below. This is **not** an either/or
with the Alchemy app:
because `chainConfig.rpc` is inert (see the paragraph above), enabling those networks does not hand Foundry an
endpoint, so it is never a substitute for passing one. Enabling them is still worth doing — it gives you
a good URL to pass and restores the preflight's first-choice candidate — but it is complementary, not an
alternative. Confirm the full inventory first:

```bash
python3 script/deploy/preflight/deployer_balances.py      # prints the endpoint each chain resolves to
```

**Re-confirmed 2026-08-10 against `main` @ `08cff61d`, by measurement, and every number above held.**
Resolving each chain the way `ConfigReader` does (`chainlib.resolve_rpc(config_only=True)`, which
exists for exactly this question) and then issuing a real `eth_blockNumber`:

- **Alchemy answers on exactly 5 chains** — `1, 10, 100, 8453, 42161`, i.e. eth / opt / gnosis / base / arb.
- **The configured endpoint answers for 5 and fails for 19**, polygon (137) among them. Read this as
  *config endpoint health only* — per the note above, Foundry never consumes `chainConfig.rpc`, so this
  split says nothing about what `forge script` can reach; without `--rpc-url` it has no endpoint on any
  chain.
- Exactly **22** chains carry `rpc: "$ALCHEMY"`; the other two are `$QUICKNODE_0G` (16661) and
  `$QUICKNODE_HEMI` (43111), neither of which is in the environment.

> ⚠️ **`deployer_balances.py` reporting `0 unreachable` does NOT contradict any of this, and must not be
> read as clearing 0.5.** That script is deliberately more capable than a bare `forge script`:
> `chainlib.probe_rpc` tries the configured endpoint, then the per-chain `*_URL` var, then a public
> fallback. On 2026-08-10 all 24 chains answered — but only 5 answered *via Alchemy*; 14 answered only
> because a `*_URL` var was set (polygon among them, via `POLYGON_URL`), and 5 only via a public
> fallback. So a green `0 unreachable` is evidence the **preflight** can read every chain, never
> evidence that `forge script` without `--rpc-url` can.

Chains with no `*_URL` and no Alchemy access — `143 monad`, `196 xlayer`, `204 opbnb`, `16661 0g`,
`43111 hemi` — currently fall back to public RPCs. Public endpoints are fine for reads but should be
replaced with real ones before broadcasting. (Re-verified individually 2026-08-10: all five have no
`*_URL` set and all five resolved to the public fallback. 143/196/204 resolve to Alchemy and are
refused; 16661/43111 do not resolve at all, their `$QUICKNODE_*` vars being absent.)

### 0.6 Fund the deployer

```bash
python3 script/deploy/preflight/deployer_balances.py --json topup.json
```

Re-measured **2026-07-29, after the linea top-up landed**: every priced chain is funded, linea
included (0.03066 ETH against an estimated 0.02800). Re-check on the day — linea had already been
topped up once on 2026-07-27 without clearing, so measure rather than assume.

That linea comparison is **stale on its second number only**: linea still holds 0.03066 ETH, but its
estimate is now **0.00293**, not 0.02800 — the balance figure aged well, the estimate did not. Which is
the general lesson for this section: re-measure both sides, not just the balance.

**Current state: `0 short, 2 unpriceable, 0 unreachable — not clear to deploy`.** **`0 short` means no
PRICED chain is short — it is not a statement that nothing is under-funded.** Scroll **and hemi** are
unpriced, so their funding is **UNKNOWN, not verified**, and this report is no evidence that they need
none. Gnosis and plasma are priced from pinned constants and their rows are authoritative; **scroll and
hemi are the two blockers** and both fail closed deliberately.

> **hemi (43111) joined scroll late, and it was a fail-open before that.** It charges an L1
> data-availability fee measured at **5.485e-5 ETH against a whole `need` of 2.801e-5 ETH — 1.96x the
> entire estimate** (2026-08-12, OP GasPriceOracle at `0x420…0F`), and it sat in **neither** L1
> collection, so it received no regime probe, no headroom floor, and printed a clean `OK` at roughly a
> third of its real cost. It had a `WORKAROUNDS` entry for its fee floor the whole time, which is exactly
> what made it look handled. The gate now also **probes every unclassified chain's oracle at runtime** and
> fails the row closed on a non-zero reading, so the next missed chain names itself instead of waiting for
> a reviewer. The three chains that used to sit in
`UNPRICEABLE` because their *quote* was unusable turned out to be three different mechanisms, each
measured in `deployer_balances.py`:

| chain | what the quote actually is | handling | trust the row? |
| --- | --- | --- | --- |
| **100 gnosis** — a **CONFIGURED** chain (it carries `nav-config/` entries) | an honest but near-zero **base** fee (43–64 wei measured, blocks 6.7–98.1% full). Inclusion is **tip**-driven: the median landed tx paid `1,000,000,048` wei — base fee plus a 1 gwei client-default tip, 20-block tip p90 of 9.8 gwei | priced from a pinned **2 gwei** (`GAS_PRICE_OVERRIDE_WEI`) | **yes** |
| **9745 plasma** | the **inverse** — the node pads the quote with a suggested tip nobody pays: `8,000,318` wei quoted against a **9 wei** median landed price, over an 8 wei constant base fee | priced from a pinned `0.01` gwei, above **both** observed values — so the verdict does not flip on *which* of the two the node happens to return | **yes** |
| **534352 scroll** | **correct, and exactly what txs pay.** A hard floor: exactly `120,008` wei at −0/−5k/−50k/−200k/−1,000,000 blocks, tips a flat 100 wei | its quote is usable, but ~99.9% of its cost is an unmodelled L1 fee, so it **fails closed** | **no** |
| **43111 hemi** | a fee-floor quote of `1,000,252` wei — usable, and it cleared the old `1_000_000` implausibility floor too | **the quote is not the problem: the omitted L1 fee is `5.485e-5` ETH against a whole `need` of `2.801e-5` ETH, i.e. 1.96x the entire estimate** (measured 2026-08-12 via the OP GasPriceOracle at `0x420…0F`). Scroll's category, not the eight OP chains'. **Fails closed** | **no** |

**Treat the gnosis quote as a live, drifting value, not a constant.** Readings across days: `2266`,
`2283`, then `53`–`60` wei, later `3209`. That drift is the evidence it tracks a real near-zero base fee
rather than being a stuck bad value — and it is why plasma's old "intermittently unpriceable" behaviour
was never a fix when it happened to price on a given day. Both are now pinned, so neither depends on the
day.

> ### ⚠️ SCOPE OF THIS GATE, AND WHY IT STAYS RED
>
> `deployer_balances.py` prices as `(gasUnits × gasPrice) × headroom` and models **no L1
> data-availability fee** (open issue **#287**). That term is not a rounding error — on scroll it
> measured **~99.9% of total cost**. **Ten** of 24 chains are affected (the eight below, plus scroll and
> hemi), and the question is **settled by
> measurement rather than left as reasoning**:
>
> | chains | n | status |
> | --- | --- | --- |
> | `10, 130, 204, 480, 5000, 8453, 42220, 57073` | 8 | **Pass, with a documented omission.** Measured margins (balance ÷ current need) are **10× to 996×**. A row flips once the added fee exceeds `balance − need`, so the **flip thresholds are ~9× to ~995× the current need** — the two are different quantities, do not quote the margin as the threshold. Either way the margins are nowhere near close, so the omission does not change these verdicts |
> | `534352` scroll | 1 | **Stays failed closed.** ~99.9% of its cost is the unmodelled term, so no honest number exists for it |
> | `43111` hemi | 1 | **Now failed closed.** The unmodelled term measured **1.96× its entire `need`** (5.485e-5 ETH vs 2.801e-5 ETH, 2026-08-12) — scroll's category, not the eight's. It was in neither collection and printed a clean `OK` |
> | the remaining 14 | 14 | No known omission — but that is **absence of a measurement, not a clearance**, and hemi is what that distinction costs when it is ignored |
>
> **So the gate is authoritative for the 8 above and for the remaining 14 as far as anything has been
> checked — gnosis and plasma are among those 14, both priced from pinned constants — and it is NOT
> authoritative for scroll or hemi.** The four groups partition the 24: **8 + 1 scroll + 1 hemi + 14 = 24.**
>
> **"No known omission" is now partly enforced rather than merely asserted.** Every chain in neither L1
> collection has its OP GasPriceOracle probed at runtime, and a non-zero reading fails the row closed
> naming itself. That closes the hemi shape specifically. It does **not** cover a DA surcharge levied
> without that predeploy, and **eight** of the 14 (`56` bsc, `137` polygon, `146` sonic, `999`
> hyperevm, `9745` plasma, `43114` avalanche, `59144` linea, `80094` berachain) were unreachable from the
> environment this was measured in, so they are **unverified, not cleared**. arbitrum (`42161`) was
> checked and has no such predeploy: Nitro charges its L1 component by inflating gas units, which
> `gas × price` already captures.
>
> **Scroll and hemi are the blockers.** They will keep printing `not clear to deploy` on every full-scope
> run until **#287 lands**. That is the gate working, not a regression. **Do not "fix" it by raising a floor or
> silencing the row** — a 1 gwei floor was already measured reporting `TOP UP` on **11 of 24** amply-funded
> chains.
>
> **A waiver does not turn the gate green, and there is no flag, env var or input that does.** This
> paragraph used to say the row persists "until #287 lands or scroll is explicitly waived", which reads as
> though a waiver is a second way to clear the check. It is not: a waiver is a human decision to **proceed
> despite a red exit**, recorded outside this script with a named person, a date and the sizing basis. The
> run still exits non-zero and the row still reads `UNPRICEABLE`, which is the intended outcome — the
> record of the override lives with the person who made it, not in the tool's exit code.
>
> **The one thing that does make it exit `0` is SCOPE.** The script takes positional chain ids, so
> `deployer_balances.py 1 100` omits scroll and exits successfully. It prints a
> `SUBSET: N declared chain(s) not covered` line, so the narrowing is visible — but **a green exit is only
> ever authoritative for the scope shown on the first line.** A subset run is a debugging aid, not a gate.

#### The eight OP-stack chains: a decision that was taken, not a default

**Ruling: pass the eight as implemented.** `L1_FEE_UNMODELLED` holds **scroll and hemi** (it was
scroll-only when this ruling was written; hemi was added after measurement put it in scroll's category,
which does not disturb the ruling about the eight). The alternative —
failing all ten closed — was proposed repeatedly in review and is defensible on principle: those chains
do charge a fee this estimator omits, and a large balance does not make a verdict authoritative. It was
rejected for two reasons: the omitted term is **~2.7e-5 native** against those margins and **no chain's
verdict flips** when it is added; and an over-strict gate gets bypassed, for which the 11-of-24
false-alarm measurement above is the precedent. That figure read `~1e-7` until 2026-08-12, when the probe
payload was found to be compressible; **it is INFERENCE, not measurement** — the pre-correction number
scaled by the measured 59.1957× ratio, not re-measured per transaction, so treat it as an order of
magnitude. The ruling is unaffected: flipping any of the eight needs the term to exceed the whole
`need` by between one and three ORDERS OF MAGNITUDE depending on the row — stated that way
deliberately, because the table above forbids quoting the measured **10× to 996×** margin as the flip
threshold, and the module declines to quote those figures for the same reason. The correction consumed
1.8 of the 3 orders that argument tolerates. **Scroll is treated differently because there the
omitted term is ~99.9% of the cost** — applying the same treatment to the eight would be theatre.

Full pricing for all **ten** remains **issue #287**, which carries everything already measured. **#287's
own scope still says nine and should be widened** — it predates hemi's reclassification.

#### Both expiry axes are enforced — but neither models the omitted fee

The measured margins are a snapshot, so two structural guards keep them honest. Values below are marked
*at time of writing*; **the constants in `script/deploy/preflight/deployer_balances.py` are
authoritative**, and if they disagree with this paragraph the code is right.

* **Balance side** — `L1_OMITTED_MIN_HEADROOM_WEI`, applied to `L1_FEE_OMITTED_PRICED`. If a chain's
  headroom (`balance − need`) falls below that floor (**1e-3 native**), the row goes `UNPRICEABLE` and
  drives the non-zero exit. **Verified on all eight** by forcing each balance under its `need`: every one
  reported `UNPRICEABLE`, none reached a `TOP UP` verdict. **Why an absolute floor and not a ratio:**
  celo sits at 9.95× margin with ~50 CELO of headroom against a measured addition of ~0, so a "10× need"
  rule would have failed it spuriously. `1e-3` native is **~38×** the largest addition (mantle, ~2.7e-5).
  That factor read ~2,200× until 2026-08-12, when the probe payload was found to be compressible and the
  term was corrected upward ~59× (see **Why two probe sizes** below). The floor VALUE still covers the
  term; only its margin shrank.
* **Fee side** — a **two-point regime probe**: the oracle's own `getL1Fee` on **64,887 bytes**
  (`L1_REGIME_PROBE_BYTES_BIG`, the region the real payload occupies) **and** on **4,096 bytes**
  (`L1_REGIME_PROBE_BYTES_SMALL`, the second point on the curve), each against a per-chain baseline
  (`L1_REGIME_BASELINE_WEI`, `L1_REGIME_BASELINE_SMALL_WEI`). Either exceeding `L1_REGIME_MAX_RISE`
  (**100×**) sends the row to `UNPRICEABLE`, naming which **probe** tripped (`big-payload` /
  `small-payload`) — not what caused it, which one reading cannot establish. A read failure also fails
  closed.
  **Both probes pin to one block**, because `l1BaseFee` was observed moving `298,580,940 → 320,948,895`
  wei inside a 20-second window.

**Why two probe sizes, and why the probe payload is incompressible.** A single 4,096-byte probe was
measured to have **zero sensitivity to payload size**: on base, `getL1Fee(0)` and `getL1Fee(4096)`
returned an identical `971,132,088` wei. **The original explanation for that was wrong** — this section
used to say 4 KB "sits entirely below the size-dependent region". The real cause was the probe payload:
it was `"ff" * n`, and post-Fjord `getL1Fee` prices the **FastLZ-compressed** size, so a single repeated
byte compresses to almost nothing and both readings landed in the flat region. `isFjord()` is 1 on seven
of the eight chains (mantle reverts every mode getter yet behaves identically).

Measured 2026-08-12, one pinned block per chain, ratios **identical to four significant figures on every
charging chain**:

| payload at 64,887 bytes | ratio to `"ff"` |
| --- | --- |
| all-zero | 1.0000 |
| incompressible (iterated sha256) | **86.9003** |
| real creation bytecode | **59.1957** |

So the old probe understated real deploy calldata ~59×, and the chain-independence says the fee is linear
in compressed size with a per-chain scalar. The probe now sends a deterministic incompressible keystream
(`_probe_payload`), and **all 16 baselines were re-measured with those exact bytes** — a baseline is only
meaningful against the payload it was measured with. Real bytecode was rejected as the probe payload
despite being more representative: it changes whenever a contract changes, which would silently invalidate
every baseline. Representativeness is #287's (real per-transaction `input` bytes from the rehearsal).

**A shortfall figure for an affected chain is a LOWER BOUND.** `need` omits the L1 fee, so a printed
top-up amount for one of those chains would tell the operator to send too little. The row carries
`shortfallExcludesL1` and the instruction says `LOWER BOUND … SEND MORE`. The headroom guard makes this
unreachable for the eight today, but **unreachable is not correct** — it holds only while that guard
exists and only for chains in one of the two sets.

**Residuals this does not remove.** A fee-mode change that leaves both probe readings under the limit
while altering the curve shape would not trip; the measured big/small ratio (**15.7787×** on every charging
chain, 0 on celo which charges nothing) is the signal, deliberately not enforced with an invented
tolerance. That ratio was recorded as 6.44× before 2026-08-12; 6.44× is what the compressible `"ff"`
payload yields and is how the artefact was identified, so a reading near it is now itself suspicious. And `L1_FEE_OMITTED_PRICED` membership is by **rollup family, not per-chain measurement** —
mantle reverts on all three OP fee-mode getters while `getL1Fee` works, so it is not a standard OP-stack
oracle.

> 🛑 **SCROLL IS DELIBERATELY UNPRICED, and its figure was wrong three times before it was refused.**
>
> | attempted model | error | verdict it produced |
> | --- | --- | --- |
> | the oracle's **retired** `overhead`/`scalar` pair (`isCurie()` is `1`) | understated ~27× | false `OK` |
> | `getL1Fee` over the **aggregate** byte count | overstates 2.29× | false `TOP UP` |
> | `getL1Fee` summed over a split proportional to deployed runtime sizes | fourth payload undercounted — `02_2` broadcasts `new AtomicNAVProxyDeployer(...)` (`02_2_DeployNAVProxy.s.sol:114`), so DA is charged on that outer creation input, not the 89-byte proxy | `OK` narrowly — withdrawn |
>
> The shell total is **64,887 bytes, artifact-derived**: that settles the *sum* but not the
> *per-transaction split*, and the split matters because the fee is super-linear. **What unblocks it is a
> real broadcast record** — run the fork rehearsal and read per-transaction `input` byte counts from
> `broadcast/*/run-latest.json`. **Pin the fork block** (second positional argument to
> `rehearse_fork.sh`); omitting it forks `latest` and reproduces a 2,915 s hang.
>
> **Funding scroll generously is the other route**, and the only one that does not wait on a measurement.

> ⚠️ **`--with-gas-price` ALONE DOES NOT FIX GNOSIS, and the failure is silent.** Per `forge script
> --help`, `--with-gas-price` is *"Gas price for legacy transactions, or **max fee per gas** for EIP1559
> transactions"* — it does **not** set `maxPriorityFeePerGas`. Gnosis inclusion is **tip**-driven and the
> node suggests only **~31 wei**, so a broadcast carrying only `--with-gas-price` keeps that unusably
> small tip and can sit unmined **while appearing to have applied the 2 gwei workaround**. Pass both:
> `--with-gas-price 2000000000 --priority-gas-price 2000000000`. `--legacy` also works.

> ⚠️ **`deployer_balances.py` HAS AUTOMATED COVERAGE OF ITS VERDICT LOGIC, AND NONE OF ITS NUMBERS.**
> `preflight/test_deployer_balances.py` is a verdict truth table run by the `Preflight gate tests` CI job
> under both `python3` and `python3 -O`; it derives its expectations from the invariants in this section
> rather than from the module, and it is mutation-tested. It replaces the earlier warning that there was no
> test at all.
>
> **What it does NOT cover, which is the part that has actually gone wrong:** every live value is faked.
> RPC readings, oracle prices and the **16 measured baselines** are constants in the test, so the suite
> cannot detect a stale baseline, a chain that changed its fee mode, or a payload that measures the wrong
> thing — the last of which is exactly the defect that forced all 16 baselines to be re-measured. Those
> claims still rest on **manual measurement**, and a regression in them is caught by a human reading the
> output or not at all. **`forge test` and the library-pin job DO run on a change to this file** —
`.github/workflows/foundry.yml` puts no `paths:` filter on its `pull_request` trigger, so Build,
unit tests, fork tests and Library pins all run on a preflight-only PR, as this PR's own runs show.
An earlier version of this line claimed the opposite.

### 0.7 Capture the pre-deploy production state — **irreplaceable, do it before anything else**

```bash
python3 script/deploy/preflight/snapshot_production.py --out pre
```

This is the only chance: the old NAV is abandoned in place, and without the snapshot "does the new
stack reproduce the old one?" becomes unanswerable. **0.9 is the other one-shot capture** — do both
while the old stack is still live, and do not let a green build or a busy day defer either. The `pre/` capture from 2026-07-27 is committed;
refresh it if the deploy happens materially later.

### 0.8 Green build and tests

```bash
forge clean && forge build --sizes
forge test                                   # both LibraryPinConsistency tests must pass
python3 script/deploy/preflight/bytecode_audit.py --self-test
```

### 0.9 NAV parity against DeBank — on the OLD stack, and only here

**This is the last moment it can be done.** After the deploy every address is new, so a disagreement
found later cannot be attributed: it will look like the redeploy caused it. Running it now answers
"did the deployed NAV already disagree with an independent source?" and establishes the reference
figure for 2.3's before/after comparison.

Scope: each of the 7 configured chains, for each account in `test/integration/accounts.json` enabled
on that chain (14 accounts; 9 on mainnet, 4 on optimism, 4 on base, 4 on arbitrum, 3 on gnosis,
1 on polygon). Record every figure — this capture is not repeatable.

**Capture the DeBank side by hand, from the UI.** That is the documented method, not a fallback. At
this size — 25 account/chain pairs — it is tractable in one sitting, it needs no API key and no
credential handling on deploy day, and the comparison is a human judgement anyway: the residual has to
be attributed to named positions (see the list below), which is not something a script decides. A
figure read off the UI is no less trustworthy for that purpose than one pulled by an API.

Record, per account and chain: the DeBank total, the NAV from `getAccountNavVerbose` on the live
proxy, the block the NAV was read at, and the wall-clock time of the DeBank read. The two are not
synchronised, so note the gap — an unexplained residual is only meaningful once price movement between
the two reads is accounted for.

**Do not build tooling for this.** If the account set grows enough that hand capture stops being
tractable, the alternative is an API-based capture against DeBank's endpoint, which needs a key
provisioned first — an edit to this step, not a redesign of it.

> **Write the expected-divergence list BEFORE the first run, or this step is decoration.** DeBank does
> not hold, or values differently, several classes this portfolio carries. If the list is written
> afterwards it becomes a rationalisation of whatever came out, someone waves it through, and the check
> joins the sixteen other things this wave found that reported success without checking anything.
>
> Known-divergent classes, to be itemised with their positions and values at capture time:
>
> | class | why it diverges |
> | --- | --- |
> | withdrawal queues — StakeWise exit queue, ether.fi, Stader | in-flight exits; DeBank may show the burnt principal, the claimable amount, or neither |
> | Nexus Mutual staking pools | pool-share positions DeBank does not decompose |
> | assisted-adapter coordinate sets | we report only what the owner Safe has fed and we can re-verify (ADR 0015, under-report only) |
> | LP positions | ADR 0017 pins instantaneous amounts deliberately; DeBank uses its own methodology |
>
> Make the list **subtractive and itemised**: name each excluded position and its value, so the residual
> is a number rather than a hand-wave. "Everything else is expected to differ" is not a list.

**The threshold, so this is a gate and not a report.** Express it per account, in basis points of that
account's own NAV, not as an absolute figure — mainnet's accounts differ by orders of magnitude, so one
dollar threshold is simultaneously too loose for the largest and too tight for the smallest.

- **residual ≤ 50 bps** of the account's NAV, after subtracting the itemised list → proceed.
- **50–200 bps** → explain before proceeding; an unexplained residual in this band is the shape a real
  pricing bug takes.
- **> 200 bps, or any residual that cannot be attributed to a named position** → **stop.** Do not
  deploy on top of a discrepancy nobody can account for; after the cutover it becomes unattributable.

Record the residual per account even when it passes: 2.3 compares against these numbers, and a
threshold with no recorded baseline cannot detect drift.

---

## 1. Per-chain deploy sequence

**THE AUTHORITATIVE ORDER:**

```
1.1  clear the deployment record
1.2  01_2_DeployNAVImplementation     libraries + NAV impl        PERSIST_DEPLOYMENTS=1
1.3  02_2_DeployNAVProxy              new proxy + ERC20Default    PERSIST_DEPLOYMENTS=1
1.4  08_DeployAssetKindRegistry       registry + MANAGER grant    <- MOVED, must precede 1.6
1.5  03_DeployPriceFeeds              40 custom feeds             <- BEFORE RegisterAssets
1.6  RegisterAssets                   assets + feeds + kinds + LABELS, via the registry
1.7  04_DeployBalanceAdapters         adapters + assistants       PERSIST_DEPLOYMENTS=1  <- assistants
1.8  06_Configure                     register + reconcile
1.9  DECISION: does the council keep MANAGER on the NAV?          <- decide BEFORE 07 runs
```

⚠️ **`08` MOVED from last to 1.4, and the move is load-bearing rather than cosmetic.** An asset's PRIMARY
registration is now routed through `AssetKindRegistry.registerAsset`, which registers, classifies and LABELS in
one transaction, so the registry must exist — and must already hold `MANAGER` on the NAV — before `RegisterAssets`
runs. Run them in the old order and `RegisterAssets` aborts with `AssetKindRegistryNotDeployed`; it does **not**
fall back to `NAVCalculator.registerAsset`, because that would succeed while leaving every asset in the run both
unclassified and unlabelled. Both are now repairable after the fact — `setAssetKinds` for the kinds,
`setAssetLabels` for the labels — so the cost is a batch of recovery transactions and a window in which the
registry disagrees with the NAV, NOT the permanent data loss earlier revisions of this note claimed. The guard
still fails closed, because a silent partial registration is the thing worth refusing.

Its "must precede `07`" constraint is unchanged and now trivially satisfied: `07` revokes the deployer's `MANAGER`,
and `08` needs it. Moving `08` earlier strengthens that ordering rather than weakening it — there is now more, not
less, between the two.

`verify_step.py`'s step numbers moved with it: the asset-kind-registry gate is now **1.4**, and the checks are keyed
to semantic function names so a renumber cannot silently point a step at the wrong body.

This **differs from the original plan**, which had `RegisterAssets` before `03`. That order is wrong:
`RegisterAssets` resolves each `Custom` feed from `deployments/<id>.json .customPriceFeeds.<name>`
(`RegisterAssets.s.sol:19` states the dependency outright), so run first it logs
`[skip] primary feed unresolved (deploy it first)` and moves on. Measured on a mainnet fork in the
plan's order: **19 of 42 assets skipped** — wstETH, eETH, weETH, rETH, ezETH, rsETH, ETHx, osETH,
stETH, lsETH, sUSDe, sUSDS, syrupUSDC, RWIV, sGHO, LDO, ankrETH, NXM, wNXM. (The dated fork
measurement was **20 of 43**, the twentieth being OETH; both figures drop by one with its retirement,
and the list below the headline is the authoritative one — it now enumerates exactly 19.)
`RegisterAssets` is
idempotent so a later re-run tops them up, but the first pass leaves nearly half of mainnet
unregistered while reporting nothing worse than a skip line.

`01_DeployImplementations` is **not** in the sequence — see 1.2 for why.

Every command runs from the repo root. Common flags:

```bash
CID=1
RPC=<endpoint for $CID>                       # see 0.5
DEPLOYER=0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
BROADCAST="--rpc-url $RPC --broadcast --account my-deployer --password-file <pwfile> --slow"
```

> **`PERSIST_DEPLOYMENTS=1` is mandatory on steps 1.2 and 1.3.** `BaseDeployScript.sol:33` gates the
> top-level address writes on it. Without it `01_2`/`02_2` only *log* the new library, impl and proxy
> addresses; `script/config/deployments/<CID>.json` keeps the OLD ones, and steps 1.5–1.8 then build
> feeds against the old NAV and register adapters on the old proxy. Nothing errors.
> **`PERSIST_DEPLOYMENTS=1` is also mandatory on 1.7 — and the reason is a split inside one script.**
> The per-**adapter** writes in `03`/`04` are NOT gated: they go through `ConfigReader.writeAdapterAddress`
> (`04:241`) and always write. But the three **`*Assistant`** writes go through `saveDeployedAddress`
> (`04:272,290,298`), which is the gated helper — `BaseDeployScript.sol:69-86` early-returns when the flag
> is unset. So without it `04` **deploys every assistant and records none of them**: the `new …Assistant(…)`
> is evaluated *before* the save, so the contract is created and the gas is spent, the address is only
> printed, and the run exits **0**. Read the old wording carefully if you meet it elsewhere — "the writes in
> `04` are not gated" is **true for adapters and false for assistants**, which is exactly the sentence that
> would stop you worrying.

> **Gate every step on its post-condition, not on its exit code.** Each step below states one, and
> `verify_step.py` asserts them:
>
> ```bash
> python3 script/deploy/preflight/verify_step.py 1.2            # the whole 24-chain scope
> python3 script/deploy/preflight/verify_step.py 1.6 1 100      # named chains
> python3 script/deploy/preflight/verify_step.py all 1          # every step, one chain
> ```
>
> It exits non-zero on the first real problem and treats an **unreachable** chain as a failure, not a
> pass, so "no problem found" cannot come from a chain that was never read. It reads only the
> deployment records and the chains — no `forge build` — so it works *between* steps; code identity is
> `bytecode_audit.py`'s job (2.2), not this one's. Do not advance to the next step until the current
> one reports `PASS` on every chain in scope.

### 1.1 Clear the deployment record — otherwise 03 and 04 are silent no-ops

`03_DeployPriceFeeds` and `04_DeployBalanceAdapters` are skip-if-already-deployed. Every feed's
`_deploy*` helper and `04`'s `_deployIfEnabled` (`04:230-234`, **32** such guards in `03`) start with

```solidity
address deployed = _readAdapterDeployed(<section>, <name>);
if (deployed != address(0)) { console2.log("  Already deployed at:", deployed); return; }
```

A re-run against a populated record therefore **succeeds while deploying nothing**, and `06` then
registers the OLD feeds and adapters — which bake the OLD NAV address as an immutable — onto the NEW
proxy. There is no error at any point.

```bash
# dry run first: prints every address that would be cleared
python3 script/deploy/preflight/reset_deployment_records.py

# archive + clear all 24 (bridge keys are deliberately left alone)
python3 script/deploy/preflight/reset_deployment_records.py --apply --tag pre-redeploy
```

Values are set to `""` and the keys kept, not deleted.

> **Expect ABSENT noise from gate 1.1 here.** Its absence check does not cover every key it iterates —
> tracked in **#299**, and deliberately not fixed in the docs PR that found it.
>
> `vm.writeJson` creates a missing key unaided, so a brand-new adapter needs **no** seeded key. Pinned
> by `script/test/WriteJsonCreatesMissingKeys.t.sol`.

The pre-clear record is archived to `preflight/archive/pre-redeploy/<CID>.json` and is
the "old addresses" input for the before/after audits.

- **Precondition:** `git status` clean; snapshot 0.7 captured.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.1` — every key in the NAV
  stack blank, the bridge keys still populated, and a rollback archive present for every chain
  (without it, `--restore` has nothing to put back). Or by hand:
  `jq '.NAVCalculatorProxy, .balanceAdapters.ERC20Default' script/config/deployments/$CID.json` → `""`.

### 1.2 `01_2_DeployNAVImplementation` — libraries + NAV implementation

```bash
PERSIST_DEPLOYMENTS=1 forge script script/deploy/01_2_DeployNAVImplementation.s.sol $BROADCAST
```

**Use `01_2`, not `01` — this matters more than it looks.**

1. ~~**`01` has NO pin assertions.**~~ **No longer true** — `01` gained the same four `require`s
   (both CREATE2 pins, plus impl-linked-against-both, `01_2:47-68`) in the PR superseding #188. The
   history is kept because it is the measurement that motivated the change. Measured on a
   mainnet fork against `main` @ `31c7b1b7` (stale pin): `01_2` reverted safely before broadcasting,
   while `01` **succeeded** and deployed `PriceFeedLib` to `0xee114702…` and `NAVRegistryLib` to
   `0x660e6018…` — the *computed* addresses — even though `NAVCalculator` is linked against the
   foundry.toml pins `0x450421a3…` / `0x549f6fB0…`. On a fresh chain that impl would DELEGATECALL
   code-less addresses and `initialize()` would revert. It only looked healthy on the fork because
   the old pinned libraries already exist on mainnet.
2. `01` additionally deploys and persists `BridgeEscrowImplementation` (`01:68,115`) — wasted ~3–4M
   gas on each of 24 chains, and it rewrites bridge deployment state for a deferred stack.

`01_2` deploys exactly the NAV subset and fails fast on a bad pin.

- **Precondition:** pins regenerated (0.3); record cleared (1.1).
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.2` — all three addresses
  populated, each with code on-chain, the two recorded library addresses equal to the pins (which is
  what the impl is linked against), the two canonical pin copies agreeing with each other, and all
  three **identical on every chain**, since CREATE2 means they must be. The four `require`s in `01_2`
  passing is the pin check on the deploy side; this is the same check from the outside.

### 1.3 `02_2_DeployNAVProxy` — the new proxy + ERC20Default

```bash
PERSIST_DEPLOYMENTS=1 forge script script/deploy/02_2_DeployNAVProxy.s.sol $BROADCAST
```

One atomic transaction: placeholder + proxy + `upgradeToAndCall(impl, initialize(...))`, with roles
granted to `addresses.admin` / `addresses.manager` and the deployer contract renouncing its own
admin. `initialize()` mints the fresh `ERC20DefaultBalanceAdapter` via
`NAVRegistryLib.deployDefaultAdapter` (`NAVCalculator.sol:86`) and `02_2` records it.

**This step is the whole reason the redeploy is a new proxy rather than a UUPS upgrade** — the mint is
set-once and unremovable through the registry, so replacing ERC20Default on a live proxy would take
migration logic that does not exist today, and would still end in a new adapter deployment. See *Why
this is a NEW PROXY and not an implementation upgrade* at the top of this document, which costs that
alternative out, before proposing a smaller deploy.

- **Precondition:** 1.2 done; `DeploySalts.NAV_PROXY` bumped if 0.2 said so.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.3` — the proxy differs from
  the pre-deploy one and is identical on all 24 chains, its EIP-1967 implementation slot equals the
  recorded impl, `version()` is 1, `erc20DefaultBalanceAdapter()` is a *fresh* address that also
  matches the record (it is minted inside `initialize()`, so an unchanged one means the proxy is the
  old one), and `admin`/`manager` hold `DEFAULT_ADMIN_ROLE` + `MANAGER` while `securityCouncil` holds
  neither — step 07 is excluded from this deploy, so a handoff here would be a mistake, not progress.
  Or by hand:
  ```bash
  cast call $PROXY 'erc20DefaultBalanceAdapter()(address)' --rpc-url $RPC   # != 0x41967559D0a20Ad102F6e27b7723b1963390aD75
  cast call $PROXY 'version()(uint64)' --rpc-url $RPC                       # 1
  cast call $PROXY 'hasRole(bytes32,address)(bool)' 0x00…00 $DEPLOYER --rpc-url $RPC  # true
  ```

> **There is no `initialAssets` argument.** `initialize(admin_, chainlinkL2SequencerUptimeFeed_,
> nativeTokenSymbol_)` hardcodes the ERC20Default seed to `[NATIVE_ADDRESS]`
> (`NAVCalculator.sol:99-118`). The asset set is *not* frozen at genesis — every `registerAsset` calls
> `addSupportedAsset` on it (`NAVCalculator.sol:176`), and
> `excludeAssetFromDefaultAdapter`/`includeAssetInDefaultAdapter` (`:356`/`:363`) mutate it later.
> Nothing needs preparing here, and `script/manage/update-erc20-default-from-chain.sh` is dead code
> (it reads `chains/<id>.json .deployed.NAVCalculatorProxy`, a path that no longer exists, and skips
> every chain).
>
> The one thing a fresh proxy genuinely cannot rebuild from config is the **exclusion** set, since
> `RegisterAssets` re-includes everything. The 2026-07-27 snapshot shows it is **empty on all 24
> chains**, so there is nothing to re-apply — but re-check `excludedFromDefaultAdapter` in the `pre`
> snapshot on the day.

*Chains 130, 143, 146, 196, 204, 480, 999, 5000, 9745, 16661, 42220, 43111, 43114, 57073, 59144,
80094, 534352 are finished here.*

### 1.4 `08_DeployAssetKindRegistry` — asset kinds

```bash
PERSIST_DEPLOYMENTS=1 forge script script/deploy/08_DeployAssetKindRegistry.s.sol $BROADCAST
```

**This step exists now — PR #241 is merged.** Both `script/deploy/08_DeployAssetKindRegistry.s.sol` and
`src/nav/AssetKindRegistry.sol` are present at `a3974686`. Confirm it against **the tree you are actually
deploying** — an explicit tree-ish, never a moving ref like `origin/main`, whose meaning changes every time
`main` does. Set `TREE` to the commit you are deploying; `a3974686` is the example, not a constant:

```bash
TREE=a3974686   # <- the tree you are deploying
git ls-tree -r --name-only "$TREE" -- script/deploy/08_DeployAssetKindRegistry.s.sol src/nav/AssetKindRegistry.sol
```

**It is also gated now, and the earlier warning here was wrong on both counts.** This note used to say
`verify_step.py`'s `STEPS` list *"ends at `1.7` and has no gate for it either"*. Both halves are false at
`a3974686`: `STEPS` is `["1.1" … "1.8"]`, and **`08` is gated as step `1.4`** —
`"08 — asset-kind registry: MANAGER grant AND classification"` (`verify_step.py:57`), implemented by
`step_asset_kind_registry` (`:579`), which checks the MANAGER grant and samples asset classifications.
Do not infer the coverage from the step *numbers*: the gate for `08` is filed under a `1.x` label, so
grepping `STEPS` for `"08"` finds nothing and reads as absent.

**What it will not do is fail you for skipping `08`.** An absent `AssetKindRegistry` in the deployment
record is an explicit **SKIP, not a failure** — `step 1.4 asserts NOTHING on this chain` is emitted as an
`info` line (`:609`). That is deliberate, since `08` is a late step many chains will not have reached.
So the original hazard survives in a narrower form: `verify_step.py 1.4` **will tell you** the registry is
missing, but a run that skipped `08` still does not go red. Read the `info` lines, not just the verdict.

#### What this step broadcasts — FOUR transactions, and BOTH directions of the link

| # | transaction | target | wires |
|---|---|---|---|
| 1 | `new AssetKindRegistry(nav)` | — | — |
| 2 | **`setAssetKindRegistry(registry)`** | **NAV** | **NAV → registry: the READ direction** |
| 3 | `grantRole(MANAGER, registry)` | NAV | registry → NAV: the WRITE direction |
| 4 | `setAssetKinds(assets, kinds)` | registry | — |

> **⚠️ TRANSACTION 2 IS NEW, AND ITS ABSENCE WAS A LIVE DEFECT, NOT A HYPOTHETICAL.**
> `NAVCalculator.setAssetKindRegistry` shipped with the read surface and was called by **nothing** outside
> tests — no deploy script, no runbook line, no preflight gate. Every deploy therefore finished with the
> NAV's `assetKindRegistry` at `address(0)` and **every `getAssetInfo` call reverting**, while every other
> check passed. It was found by a session writing documentation, because it had to say what a caller
> actually gets.
>
> **The two directions are not symmetric and were assumed to be.** Transaction 3 lets the registry WRITE to
> the NAV. Transaction 2 lets the NAV READ the registry. Each is invisible from inside the other contract,
> which is how one of them went missing for the whole life of the feature.
>
> Transaction 2 is dispatched **first** of the three post-deploy calls on purpose: a broadcast is sequential,
> so an earlier failure tends to prevent the later ones, and the partial states that survive are then
> visibly incomplete rather than complete-looking and dead on the read side.
>
> **Verify all three landed** — `verify_step.py 1.4` asserts the pointer, the grant and the classification.
> The pointer is compared by **equality** against the recorded registry, so a stale pointer from a previous
> run fails rather than passing as merely non-zero.
>
> `RegisterAssets` (1.6) also refuses to run against a NAV that does not point back, so a missed transaction
> 2 stops at the next step instead of surviving to production.

> **⚠️ IT MUST RUN BEFORE `07`, AND THE REASON MATTERS MORE THAN THE ORDER.** `08` is a **privileged** step:
> it makes **two** privileged calls on the NAV — `setAssetKindRegistry` and `grantRole(MANAGER, registry)`.
> The grant is needed because the registry facade forwards to `NAV.registerAsset` and the NAV gates on
> **its** `msg.sender` — the registry contract, not the operator. Without the grant the facade is dead code;
> without the pointer every read reverts.
>
> `grantRole` requires `DEFAULT_ADMIN` on the NAV, and `07_TransferAdminToSecurityCouncil` hands that to the
> security-council Safe **and revokes the deployer's `MANAGER`**. Run `08` after `07` and it reverts:
> `setAssetKinds` always, for lack of MANAGER, plus the grant itself on a first run, for lack of admin. `08`
> is EOA-broadcast only — there is no Safe path to fall back on.
>
> So the rule is **not** "07 is last". It is **"`07` is the last step of the ROLE HANDOFF, and every step
> needing deployer privileges — `08` included — must precede it."** Stated with its reason attached because
> an ordering rule without one is one somebody tidies back later; an earlier revision of `08` itself, and
> seven other doc sites, claimed it was order-independent. It is not.

**In THIS wave the constraint is satisfied for free, which is exactly why it is easy to lose.** Step `07` is
deliberately excluded from this deploy (see *What is not yet deployed*), so nothing here can run it too
early. The constraint binds the **later, manual** council handover: whoever eventually runs `07` must
confirm `08` has already run on that chain, because afterwards there is no non-Safe path to grant the role.

**Placement is NO LONGER flexible, and this changed with the labels work.** `08` still references neither
`PriceFeedLib` nor `NAVRegistryLib`, so it does not gate — and is not gated by — the NAV redeploy. But it must
now run **before `RegisterAssets` (1.6)**, not merely before `07`: an asset's primary registration is routed
through `AssetKindRegistry.registerAsset`, which registers, classifies and labels atomically. Run `08` late and
`RegisterAssets` aborts with `AssetKindRegistryNotDeployed` — deliberately, rather than falling back to
`NAVCalculator.registerAsset`, which would succeed while leaving that run's assets unclassified and unlabelled.
Recoverable (`setAssetKinds` + `setAssetLabels`), but only once somebody notices.

> **The pin regeneration this feature owed has been DONE — see 0.3.** The registry's arrival under `src/`
> coincided with the `via_ir` whole-program stack margin being reached, which prompted the
> `PriceFeedLib._assignHealthArrays` extraction and moved that library's pin. Both pins are now measured
> against the merged tree; `NAVRegistryLib` did not move.

- **Precondition:** #241 merged; 1.3 done (the registry is granted a role on the **new** proxy); the chain's
  `nav-config/assets-and-price-feeds/<CID>.json` carries a valid `accrualKind` on **every** asset — it is
  fail-closed with no default, so one missing or misspelled value aborts that chain's run. `preflight_config.py`
  rejects the same cases before any transaction is sent — a **missing** key, a misspelled key (which makes the
  real one read as absent), an empty string, and a mis-cased or out-of-vocabulary value — so run preflight rather
  than discovering it mid-deploy.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.4` — asserts the registry is recorded,
  has code, is bound to the recorded proxy, **holds `MANAGER` on the new NAV** (without which the facade is
  dead on writes) and that **the NAV points BACK at it** (without which every read reverts), plus a sampled
  classification. An earlier revision of this line said no gate existed; it does, and it covers both
  directions of the link.

#### What the adapter-label override surface costs to read — measured on merged `main`

The registry this step deploys also holds #278's adapter-keyed overrides
(`setAdapterProtocolName` / `setAdapterLabels` and their `clear…` pair). Reading them is not free,
and **the day-one cost is the higher of the two figures.** Measured on merged `main` at `a3974686` — not on
a branch, and not on the superseded head that earlier numbers came from:

| verbose read, per distinct adapter | gas |
| --- | --- |
| override **MISS** — **what an operator pays today** | **114,552** |
| override **HIT** | 112,169 |

> ⚠️ **Both figures predate #285**, which replaced the segment-0-only scalar `setAdapterLabelCategory` with
> the per-segment `setAdapterLabels(address, string[])`. The label half of the read is now an ARRAY fetch
> through an isolating decode shim rather than a flat `string`, so **treat these as a floor and re-measure
> against the merged tree** before quoting them at deploy time. The MISS-dearer-than-HIT shape is unchanged.

**MISS is dearer than HIT, and every adapter is a MISS today.** No overrides exist on `main`; one comes
into being only when a `MANAGER` calls `setAdapterProtocolName` or `setAdapterLabels`. A hit skips
the adapter's `protocolName()` staticcall entirely; a miss pays the registry lookup **and still makes the
adapter call**, so a miss is strictly a superset of the work. **You pay the higher number from day one, for
zero benefit until an override is actually set.**

**The denominator is the whole point: the surcharge is PER VERBOSE READ, PER DISTINCT ADAPTER — not per
position.**

| fixture | surcharge |
| --- | --- |
| 1 distinct adapter / 1 position | 5,378 |
| 2 distinct adapters / 3 positions | **≥ 10,968 — warm-fixture floor** |

Two adapters across three positions cost the same as two across two: **the third position adds nothing.** An
account with N distinct adapters pays roughly **N × 5.4k warm**, however many positions those adapters emit.
Quote the denominator with the number or do not quote the number.

**Three qualifiers travel with these figures. Do not strip them.**

1. **`10,968` is a warm-fixture FLOOR, not the live cost.** The test warms the read before measuring; a real
   portfolio touches each adapter's slot **cold**. Phrase it as *"≥ 10,968, warm-fixture floor; real cost is
   higher by an unmeasured cold-access premium"*. **The cold figure was not measured.**
2. **The linear-in-adapters property is demonstrated only at N=1 and N=2.** The fixture is 1–2 adapters; the
   mainnet fixture is 117 positions across many more. **No extrapolation was made, and none should be.**
3. **This is a read cost on the verbose path only.** It is not a deploy cost and does not affect any step here.

**Why the bound is trustworthy: it is mutation-defended.** Breaking the cache so overrides resolve
per-position instead of per-distinct-adapter gives clean **10,968** against mutant **16,296**, tripping a
12,000 bound and failing with *"the surcharge must scale with DISTINCT ADAPTERS, not with positions"*. Tree
restored clean afterwards, 0 modified files. The per-adapter denominator is therefore an asserted invariant,
not an observation that happened to hold on one fixture.

> **NOT MEASURED, and not to be papered over: the benign-path gas of the new `getAdapterDisplayInfo`
> configuration surface.** Only its **hostile ceiling** exists — **667,962** for 3 entries against a
> stipend-burning registry. There is **no normal-operation measurement** of it. Do not infer one from the
> hostile figure, and do not present that ceiling as a typical cost.

### 1.5 `03_DeployPriceFeeds` — 40 custom feeds

```bash
forge script script/deploy/03_DeployPriceFeeds.s.sol $BROADCAST
```

Chains 1 (25 enabled, of 26 entries), 42161 (8), 8453 (4), 100 (3) only. Each feed's constructor takes the NAV proxy
address, held as `INAVCalculator public immutable NAV` (ADR 0019) — which is precisely why a new
proxy invalidates every existing feed.

> **THE COUNT IS 40, AND IT IS NO LONGER PENDING ANYTHING.** Both PRs it was waiting on have merged,
> so the earlier figure of 39 is stale, and so is the 41 that #224 briefly made correct. Re-derived from
> config on 2026-08-13: **mainnet 25, arbitrum 8, base 4, gnosis 3 = 40.** (Chain 1 holds 26 feed
> ENTRIES; `ETHPlus` is `enabled: false`, and `03` is gated on `isAdapterEnabled`, so it deploys 25.
> Counting entries rather than enabled entries is how 26 got here.)
>
> | PR | merged | effect on the count |
> | --- | --- | --- |
> | **#199** (stETH primary becomes fundamental) | 2026-07-29 | deploys a **stETH primary** (`stETHFundamental`) and demotes `stETHCrossRate` to a monitor: mainnet 24 → **25** |
> | **#224** (ezETH market monitor) | 2026-07-30 | adds `ezETHCrossRateMarket` so ezETH's depeg check can fire: mainnet 25 → **26** |
>
> Both have their `03_DeployPriceFeeds.s.sol` call sites in place — `_deployEEth("stETHFundamental")`
> (`03:147`), `_deployCrossRateMonitor("stETHCrossRate")` (`03:153`) and
> `_deployCrossRateMonitor("ezETHCrossRateMarket")` (`03:230`) — verified against the merged tree, so
> `03` deploys all 25 ENABLED mainnet feeds and nothing is skipped as `primary feed unresolved`.
>
> Keep taking the number from the tooling rather than from here: `preflight_config.py` prints the
> configured total and `verify_step.py 1.5` compares against it, so both follow config automatically.
> This paragraph is the thing that goes stale — as it just did, twice.
>
> **The three dead feed contracts are a separate matter and change the count by ZERO.**
> `cbETH_CustomPriceFeed`, `ETHPlus_CustomPriceFeed` and `sDAI_CustomPriceFeed` are deployed on no chain
> and enabled in no config (`cbETH`/`sDAI` are not config keys at all; `ETHPlus` is present on mainnet
> with `enabled: false`). All three call sites are `isAdapterEnabled`-gated (`03:98`, `03:153`, `03:183`)
> and a missing key reads as false, so the branches are never taken — and they stay unreached after step
> 1.1, since clearing the record removes only the skip-guard short-circuit, not the enablement gate.
> #199 deletes the sDAI contract; that is dead-code removal, not a count change. An earlier audit note
> suggested dropping all three would make the redeploy 36 instances; it would not, because they were
> never among the 39. Verified against both the deployment records and the enabled config 2026-07-29.

- **Precondition:** 1.1 cleared `customPriceFeeds.*`; 1.3 wrote the NEW `NAVCalculatorProxy`.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.5` — the feed count matches
  the table above, every feed has code, and every feed's `NAV()` immutable points at the **new** proxy.
  That last one is the check that matters: a feed is otherwise indistinguishable from a correct one
  while still pricing against the abandoned NAV.

### 1.6 `RegisterAssets` — assets + feeds on the new NAV

```bash
mkdir -p safe-transactions        # REQUIRED — see below
FOUNDRY_PROFILE=slow forge script script/manage/RegisterAssets.s.sol $BROADCAST
```

`FOUNDRY_PROFILE=slow` (16 GiB) is required on mainnet — 42 assets otherwise `MemoryOOG`.

`safe-transactions/` must exist: the script ends by writing a Safe-TX batch there, and if the
directory is missing it aborts with
`vm.writeJson: failed to open file ".../safe-transactions/1-register-assets.json"` **after** the
on-chain registrations have already been broadcast. The chain state is fine and the script is
idempotent, but the run reports failure. The directory is not in the repo, so create it once per
checkout.

- **Precondition:** **1.5 done** (`03_DeployPriceFeeds`; 1.4 is `08`, which writes no feed addresses) — Custom feeds resolve through
  `deployments/<id>.json .customPriceFeeds.<name>`, and without them 19 of mainnet's 42 assets are
  silently skipped (see the authoritative order at the top of section 1).
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.6` — `getAssetCount()` equals
  the configured count (42 / 11 / 11 / 6 / 11 / 5 / 6 for chains 1 / 42161 / 8453 / 10 / 100 / 137 /
  56) **and** the registered address set equals the configured one, so one asset silently substituted
  for another cannot pass on the count alone.

### 1.7 `04_DeployBalanceAdapters` — adapters + assistants

```bash
PERSIST_DEPLOYMENTS=1 forge script script/deploy/04_DeployBalanceAdapters.s.sol $BROADCAST
```

Deploys plain + meta adapters via plain `new` (CREATE), then the delegatecall assistants, whose
`immutable ADAPTER` must point at the **new** assisted adapters.

> **The flag is REQUIRED here, and this step is the reason.** Adapters record either way; the four
> `*Assistant` addresses do not — see the persistence note under the common flags above. Without it you get
> four live assistant contracts on chain and four empty `*Assistant` keys in the record, with exit code 0.
> The addresses are recoverable (stdout prints each one twice, and `broadcast/…/run-latest.json` records
> every CREATE), and the cheapest repair is simply re-running this step **with** the flag — adapters
> short-circuit as already-deployed, so only the assistants redeploy. But the ops team whitelists these on
> the Roles modifier by reading them out of the record, so an unrecorded assistant is an assistant nobody
> can be handed.
>
> **If `verify_step.py 1.7` says an assistant is missing, read its hint sceptically.** It reports
> *"`04` skips an assistant whose key is already populated, so check 1.1 cleared it"* — which names the
> wrong cause for this failure. Check whether the flag was set on this step **before** re-litigating 1.1.

- **Precondition:** 1.1 cleared `balanceAdapters.*` **and** the three `*Assistant` keys.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.7` — adapter count per chain
  = 27 / 8 / 7 / 4 / 3 / 2 / 1 for 1 / 42161 / 8453 / 100 / 10 / 137 / 56 (ERC20Default included),
  every adapter has code, and **each assistant's `ADAPTER()` resolves to its paired assisted adapter**.
  Run it on chains 1 and 100: against the live stack it reproduces all four orphaned pairings from
  2.1, so a clean report here is the proof the swap was rebuilt rather than inherited.

### 1.8 `06_Configure` — register adapters, reconcile meta instances

```bash
forge script script/deploy/06_Configure.s.sol $BROADCAST
```

Idempotent and reconciling; safe to re-run. If a chain hits an RPC nonce race, re-run just this step
with `--slow`.

`06` also configures `BridgeEscrow`, but it reads `BridgeEscrowProxy` from the deployment record
(`06:31`) and **no chain has one** — so it logs `WARNING: BridgeEscrow not deployed, skipping Bridge
configuration` (`06:37`) and skips the entire bridge block. The deferred bridge is therefore not
touched at all by this step, not merely touched idempotently.

- **Precondition:** 1.5, 1.6 **and 1.7** done. 1.7 (`04`) is the step that DEPLOYS the adapters this
  step registers — run `06` without it and every adapter is absent from the record, so `06` takes
  `if (deployed == address(0)) continue;` for all of them, registers nothing, and exits 0.
- **Post-condition:** `python3 script/deploy/preflight/verify_step.py 1.8` — `getAdapterCount()`
  matches 1.7 (`04` is what deploys adapters; 1.6 is `RegisterAssets` and produces no adapter count),
  every recorded adapter reports `isAdapterRegistered`, nothing is registered that is not
  in the record, and each meta adapter's `getMetaInstances()` **set equals** its configured coordinate
  set, summing to the total in the meta-instance table at the top of this document (**111**; 110 as
  reconciled 2026-07-29, +1 on 2026-08-12 for issue #296). The per-chain breakdown lives in that table only and is not repeated here, so the table
  is where a config change is corrected — but "one place" understates it badly. Measured at 2026-08-12 the
  meta-instance figure appears at **twelve** sites in this file. Do NOT work from a list — including
  this sentence: grep for the figure itself (`grep -nE '\b(111|67|53|91|114)\b'`), discard gas values
  and dated records, and change what remains. Two hand-written site lists in this document were both
  short, which is why the instruction is now a derivation rather than an enumeration.

> **Watch for the silent skip.** `06` does `if (deployed == address(0)) continue;` (`06:113` for
> meta, same shape for plain), so an adapter that failed to deploy is skipped **without an error**.
> Always assert the post-condition counts; never trust the exit status alone. Running
> `python3 script/deploy/preflight/preflight_config.py` beforehand catches the config-side causes.

> **Operator check during re-registration (from #172).** Verify each registered instance resolves as
> intended rather than silently masking a misconfiguration. In particular, Aave V3 exposes two
> DataProviders; registering both double-counts positions. `verify_step.py 1.8` compares instance
> **sets**, not counts, so a wrong-but-same-sized instance set fails — but it compares against
> *config*, so it cannot tell you the config itself named the wrong DataProvider. That judgement stays
> human.

### 1.9 DECISION — does the security council keep `MANAGER` on the NAV?

**This is a choice, not a step. Nothing in the deploy makes it for you, and it is easiest to make here** —
after `1.8`, before `07_TransferAdminToSecurityCouncil` runs.

#### What is actually being decided

`AssetKindRegistry` is ownerless: every write gates on `NAV.hasRole(MANAGER, msg.sender)`, and the registry
itself holds `MANAGER` so it can forward into the NAV. But `NAVCalculator.registerAsset` is gated by nothing
except `_requireManager()`. So `MANAGER` is simultaneously **the registry's permission to write** and **a
human's permission to bypass the registry**.

That leaves **two doors into "this asset is registered"**:

| door | classification | labels |
|---|---|---|
| `AssetKindRegistry.registerAsset` — the facade | written, atomically | written, atomically |
| `NAVCalculator.registerAsset` — direct | **none** | **none** |

`AssetKindRegistry.sol:188` states the second case outright: an asset registered directly on the NAV *"has no
kind"*.

**So the invariant "no registered asset is unclassified" is STRUCTURAL only if the NAV's `MANAGER` set is exactly
`{registry}`. Otherwise it is CONVENTIONAL** — upheld by whoever is at the keyboard.

⚠️ **It still matters, but it no longer bites the way this note used to say.** Labels were write-once; an asset
registered through the wrong door could never be labelled, and the only repair was `unregisterAsset` plus
re-registration — taking the asset out of the NAV and putting it back, with its price feeds, to fix a display
string. `AssetKindRegistry.setAssetLabels(asset, labels)` (MANAGER-gated) now corrects a label in one call, with
feeds, monitors and tolerances untouched. Registering through the facade is still the right thing to do, because
it is what classifies the asset atomically — but a labelling mistake is no longer expensive to undo.

#### What `07` already does, which narrows the question

`07_TransferAdminToSecurityCouncil` per target: grants `DEFAULT_ADMIN_ROLE` **and `MANAGER`** to
`chainConfig.securityCouncil`, then revokes `MANAGER` from the deployer EOA and renounces the deployer's
`DEFAULT_ADMIN_ROLE`.

**The deployer is therefore already handled.** After `07` the `MANAGER` set on the NAV is
`{AssetKindRegistry, securityCouncil}`, so the decision is only ever about **the council**.

#### What revoking does and does not buy

`NAVCalculator` uses stock `AccessControlUpgradeable` with **no `_setRoleAdmin` override**, so `DEFAULT_ADMIN_ROLE`
is the role admin of `MANAGER` — and `07` grants the council `DEFAULT_ADMIN_ROLE`.

**A council that has been revoked can therefore re-grant itself `MANAGER` at any time.** Revocation does not make
the bypass impossible; it makes it a **deliberate, separately-authorised, on-chain-visible act** rather than a
one-transaction routine operation. Read "structural" in that sense and not a stronger one.

#### The cost of revoking — every function `MANAGER` gates on the NAV

All 19 are on `NAVCalculator`; `Prices` and `Balances` declare no `MANAGER`-gated external functions of their own.
A revoked council cannot call any of these without first re-granting itself the role:

| area | functions |
|---|---|
| assets | `registerAsset` · `unregisterAsset` |
| price feeds | `addPriceFeed` · `removePriceFeed` · `removePriceFeedAt` |
| monitors | `addMonitorFeed` · `removeMonitorFeed` · `removeMonitorFeedAt` |
| tolerances | `setDivergenceTolerance` · `setPegTolerance` |
| balance adapters | `addBalanceAdapters` · `removeBalanceAdapters` |
| meta adapters | `addMetaBalanceAdapter` · `addMetaInstances` · `removeMetaInstances` |
| default adapter | `excludeAssetFromDefaultAdapter` · `includeAssetInDefaultAdapter` |
| wiring | `setAssetKindRegistry` |
| L2 | `setChainlinkL2SequencerGracePeriod` |

Note `registerAsset` is the only one the facade covers. **Everything else in that table is ordinary NAV
operations with no facade equivalent** — routine feed and adapter maintenance goes through `MANAGER` directly.
That is the real cost, and it is why keeping the council's `MANAGER` may be the right answer.

#### Check the current set

The NAV uses `AccessControlUpgradeable`, **not** the `Enumerable` variant, so `getRoleMemberCount` /
`getRoleMember` **do not exist** — the set cannot be read directly and must be reconstructed from events, then
confirmed per address:

```bash
MANAGER=0xaf290d8680820aad922855f39b306097b20e28774d6c1ad35a20325630c3a02c

# every address ever granted MANAGER on this proxy (3rd topic = account)
cast logs --address $PROXY --from-block $DEPLOY_BLOCK --rpc-url $RPC \
  'RoleGranted(bytes32,address,address)' $MANAGER
# and every revocation, to net them off
cast logs --address $PROXY --from-block $DEPLOY_BLOCK --rpc-url $RPC \
  'RoleRevoked(bytes32,address,address)' $MANAGER

# then confirm each survivor — this is the authoritative read, and it can answer false
cast call $PROXY 'hasRole(bytes32,address)(bool)' $MANAGER $ADDR --rpc-url $RPC
```

The invariant is structural on a chain **iff** the only address returning `true` is that chain's recorded
`AssetKindRegistry` — `cast call $PROXY 'assetKindRegistry()(address)' --rpc-url $RPC`.

#### Revoke, if that is the decision

Run **after** `07` (the council must already hold `DEFAULT_ADMIN_ROLE`, or there is nobody left who can grant
anything), and execute from the council Safe, not the deployer:

```bash
cast send $PROXY 'revokeRole(bytes32,address)' $MANAGER $COUNCIL --rpc-url $RPC   # from the council Safe
cast call $PROXY 'hasRole(bytes32,address)(bool)' $MANAGER $COUNCIL --rpc-url $RPC  # must now be false
```

**Do not revoke before `1.8`.** `06_Configure` broadcasts `addBalanceAdapters` / `addMetaBalanceAdapter` /
`addMetaInstances` from the deployer EOA, all `MANAGER`-gated; revoking early aborts the chain's configuration.

---

### 1.10 Chain-specific workarounds

- **hyperevm (999):** the NAV impl deploy is ~12.5M gas; HyperEVM's small blocks cap at ~3M. Enable
  "big blocks" (~30M) for the deployer via the Hyperliquid `evmUserModify` L1 action
  (`Exchange(wallet, MAINNET_API_URL).use_big_blocks(True)`) before 1.2/1.3, and disable afterwards.
  The chain's reported block gas limit still shows 3M — that is expected.
- **hemi (43111):** the chain enforces a fee floor; a tx priced off a naive `eth_gasPrice` is
  rejected. Raise `--with-gas-price`.
- **gnosis (100) — PASS BOTH FLAGS, and the failure mode is a silent stall.** Its base fee is
  near-zero (43–64 wei measured) but inclusion is **tip**-driven: the median landed tx pays base fee
  plus a **1 gwei** tip, and the node suggests only **~31 wei**. Broadcast with **both**:

  ```bash
  forge script … --chain-id 100 --with-gas-price 2000000000 --priority-gas-price 2000000000
  ```

  **`--with-gas-price` on its own is not enough.** Per `forge script --help` it sets *"max fee per gas
  for EIP1559 transactions"* — it does **not** set `maxPriorityFeePerGas`, so a broadcast carrying only
  that flag keeps the ~31 wei tip and can sit unmined **while looking like the workaround was applied.**
  `--legacy` also works, since a legacy transaction has a single gas price and no separate tip.
  Full reasoning in 0.6.

---

## 2. After the deploy

### 2.1 Owners must FEED the assisted coordinate caches — **4 caches on 2 chains**

> **This step ADDS value that has never been reported. It does not restore value the deploy dropped.**
> Measured on mainnet 2026-07-30: all three chain-1 assisted adapters have emitted **zero logs, ever**
> — checked with no topic filter, so the result does not depend on matching an event signature — and
> `coordsOf()` is empty for all nine chain-1 integration accounts. The caches have never been fed since
> PR #141 deployed them, so **production NAV already omits these positions today, and has all along.**
>
> Two consequences, both important:
>
> - **This step is NOT deploy-blocking.** There is no window of understated NAV created by the
>   cutover, because the value is not being reported before it either. Feeding can follow at the
>   owners' pace.
> - **Do not describe it as a regression, and do not go hunting one.** A before/after comparison that
>   shows these positions at $0 on *both* sides is the **correct** result, not a missed fault — §2.3's
>   comparison matched for exactly this reason. Anyone told to "restore what the deploy dropped" will
>   look for a bug that does not exist.
>
> Not measured separately: **gnosis**. Its pair follows the same pattern and was recorded as an orphan
> on 2026-07-27, but no log check was run against chain 100 — treat it as unverified rather than proven
> empty.

`AssistedCoordCache` keys its coordinate cache by account
(`mapping(address account => bytes[] coords)`, `AssistedCoordCache.sol:41`), so a redeployed assisted
adapter starts **empty** and reports nothing for those positions until the owner Safe submits. The
assistants hold an `immutable ADAPTER`, so they are redeployed too and the Safe must delegatecall the
**new** assistant addresses.

| chain | assisted adapter | assistant |
| --- | --- | --- |
| 1 | `EtherFiWithdrawalQueueAssisted` | `EtherFiWithdrawalQueueAssistant` |
| 1 | `NexusMutualStakingPoolsAssisted` | `NexusMutualStakingPoolsAssistant` |
| 1 | `StakeWiseV3ExitQueueAssisted` | `StakeWiseV3ExitQueueAssistant` |
| **100 gnosis** | **`StakeWiseV3ExitQueueAssisted`** | **`StakeWiseV3ExitQueueAssistant`** — the easy miss |

The gnosis pair is easy to miss — the assisted family is usually described as mainnet-only. Read the
new addresses out of `deployments/{1,100}.json` and hand them to the owners. This was left open after
PR #141; do not let it slip again.

> **The assistants recorded today are ORPHANS — measured 2026-07-27.** All four point at adapters
> that are *not* registered on the NAV:
>
> | chain | assistant | its `ADAPTER()` | registered assisted adapter |
> | --- | --- | --- | --- |
> | 1 | `0x8a887C7F` Nexus | `0xb73b3a6b` (has code, **not registered**) | `0x9b3ee866` |
> | 1 | `0xd45cB5B6` ether.fi | `0xb0a8a756` (has code, **not registered**) | `0xdCF0E047` |
> | 1 | `0x13845Fc9` StakeWise | `0xb9a7a8ac` (has code, **not registered**) | `0xcb97dA2c` |
> | 100 | `0xEb438283` StakeWise | `0xe333a72e` (has code, **not registered**) | `0x04E39d91` |
>
> Almost certainly fallout from the PR #141 adapter swap: the assisted adapters were replaced, the
> assistants were not. Delegatecalling the recorded assistants today writes coordinates into the
> cache of an unregistered adapter, which the NAV never reads — so those positions are currently
> un-feedable through the recorded addresses, and this deploy is the first time they will be fed
> correctly.
>
> The redeploy fixes it by construction: `04`'s `_deployAssistantsIfEnabled` builds each assistant
> from the freshly-deployed adapter address, so the pairings are rebuilt from nothing. **But only if
> the `*Assistant` keys are cleared** — it skips an assistant whose key is already populated.
> `reset_deployment_records.py` clears them; do not hand-edit around that.

**2.1a Verify every assistant pairing — REQUIRED, both chains.**

```bash
python3 script/deploy/preflight/bytecode_audit.py 1 100
# every entry must be CURRENT; no CURRENT_CODE_STALE_POINTER, no ORPHAN
```

The audit resolves `ADAPTER()` on each assistant and checks **two** things — that it is in the
deployment record, *and* that `isAdapterRegistered(ADAPTER())` is true on the new NAV. The second is
the one that matters: an assistant pointing at an unregistered adapter feeds a cache the NAV never
reads, which is precisely the live failure (all four report `ORPHAN` against the current stack). Or by
hand, per pair:

```bash
ASST=$(jq -r '.StakeWiseV3ExitQueueAssistant' script/config/deployments/$CID.json)
ADAP=$(cast call $ASST 'ADAPTER()(address)' --rpc-url $RPC)
cast call $PROXY 'isAdapterRegistered(address)(bool)' $ADAP --rpc-url $RPC   # must be true
jq -r '.balanceAdapters.StakeWiseV3ExitQueueAssisted' script/config/deployments/$CID.json  # must equal $ADAP
```

**2.1b Owners feed the coordinate caches — 4 caches on 2 chains.**

Hand the owners the **new** assistant addresses from `deployments/{1,100}.json` and confirm each cache
is non-empty afterwards. All four must be done; the gnosis one is the easy miss because the assisted
family is usually described as mainnet-only.

> **The first feed is a live test of a code path that has NEVER executed.** The assistants have never
> been invoked — zero logs on every adapter — so the delegatecall route (owner Safe → `…Assistant` →
> `msg.sender == Safe` seen by the adapter) has never run against a live registered adapter. A direct
> call reverts `NotDelegateCall`, and the whole point of the pattern is that the adapter sees the Safe
> rather than the assistant, which is exactly the property no production transaction has yet
> demonstrated.
>
> So do the first one **deliberately: one adapter, a small submission, verified before continuing** —
> not four caches in a bulk batch. Confirm with `coordsOf` that the coordinate landed under the **Safe's**
> address (not the assistant's, which would mean the delegatecall degraded to a plain call), and that the
> NAV's reported position moves as expected, before feeding the rest. This is a cheap precaution now and
> an expensive discovery if skipped.

> **Observability is asymmetric — a green DeBank tolerance check does NOT clear this step.** In chain-1
> `supportedDeBankProtocols` (`test/integration/accounts.json`): `etherfi` and `stakewise` are present,
> so a gap in those two would surface as drift in §2.3 / the integration snapshots. **No Nexus id is in
> the allowlist at all** — verified — so a Nexus gap is invisible on *both* sides of any comparison, and
> a passing tolerance check proves nothing whatsoever about it.
>
> Nexus is also the one that looks fine by coincidence: wallet **NXM/wNXM are registered priced assets**
> and reconcile normally, which masks an absent *staked* leg of roughly **$3.35M**. Read that figure as
> **unrealised coverage** — value the system does not currently report and could — rather than as value
> gone missing. Nothing is lost; it has simply never been counted.

**Until a cache is fed those positions UNDER-report — they do not report wrongly.** That is the
family invariant (ADR 0015): the adapter caches position *coordinates only*, values every position
from live on-chain reads, and re-verifies ownership on every read, so a missing coordinate can only
omit value, never invent it. Consequence for triage: a NAV that is *low* after the cutover points at
an un-fed cache and is safe to sit with while owners catch up; a NAV that is *high* is a different
bug entirely and must not be attributed to this step.

```bash
# per (chain, adapter): returns [] until the owner has submitted, then the coordinate blobs.
# `coordsOf` is the shared raw-coordinate getter (AssistedCoordCache.sol:110); the concrete adapters
# add decoded views — `tokenIdsOf` (Nexus `:80`, EtherFi `:75`), `positionsOf` (StakeWise `:84`).
# None is a dedicated count getter — you count by fetching an array and reading its length, so
# there is no cheap way to ask "how many?" without pulling the whole set back.
cast call $ADAPTER 'coordsOf(address)(bytes[])' $OWNER_SAFE --rpc-url $RPC
```

The cache is keyed per account (`mapping(address account => bytes[] coords)`,
`AssistedCoordCache.sol:41`), so query it for **the owner Safe that holds the positions**, not for the
deployer.

### 2.2 Bytecode-reality audit — the acceptance test

```bash
forge clean && forge build
python3 script/deploy/preflight/bytecode_audit.py --self-test
python3 script/deploy/preflight/bytecode_audit.py --require-current --json post-deploy-bytecode.json
python3 script/deploy/preflight/verify_step.py all          # every step's post-condition, all 24
```

Every address in every `deployments/<chainId>.json` must report `CURRENT`. Any `STALE` is an address
still running code this build does not produce — i.e. something was missed.

**`--require-current` is what makes this a gate.** Without it the audit prints its findings and exits
0 regardless, which is right for the *pre*-deploy run — where 155 `STALE` out of 231 was the expected
answer, not a failure — and wrong here. With it, any non-`CURRENT` address *or any unreachable chain*
exits 1: a chain that was never read has not passed. Pair it with `verify_step.py all`, which asserts
the shape (counts, sets, pointers, roles) that identical bytecode alone does not guarantee.

### 2.3 Before/after NAV comparison

```bash
python3 script/deploy/preflight/snapshot_production.py --out post
python3 script/deploy/preflight/diff_snapshots.py pre post
```

Expect equality except where a hardening fix legitimately changes a label or suppresses an
unreportable leg. Any change in `nav.value` beyond price drift between the two capture blocks needs
an explanation before the cutover.

> **Enumerate the expected differences BEFORE running the comparison** — same discipline as 0.9, and
> for the same reason. This wave changed labels and suppressed legs deliberately, so a raw diff will
> not be empty, and a non-empty diff nobody predicted is indistinguishable from a regression. After
> #193, #195, #199 and the `main:9` PR there will be several, and they must be listed with the adapter,
> the account and the field each one touches *before* the first run. Without that list the comparison
> cannot be adjudicated, and the outcome is someone waving through a difference that mattered.
>
> The two capture blocks differ, so price drift is expected on every priced position. Compare
> **structure** (position count, `protocolId`/`protocolSubId`/`positionId`, `positionKind`, `isDebt`,
> labels) exactly, and `nav.value` only against the 0.9 residual band — that is what 0.9's per-account
> figures are for. A structural difference is never explained by drift.

**This is step 3 of 3.** The end-to-end validation is: **0.9** DeBank parity on the old stack
(pre-deploy, unrepeatable) → **2.3** old-vs-new NAV comparison (here) → **2.6** integration-snapshot
refresh. Each depends on the one before it: 0.9 supplies the reference figures this step compares
against, and 2.6 cannot run until the new addresses are recorded.

**Known-expected diffs — do NOT treat these as regressions:**

- **`MorphoVaultsMeta` GAINS one meta instance on mainnet, and `metaInstanceTotal` goes 66 → 67.** The
  committed pre-snapshot (`snapshots/pre/1.json`, block 25625439) was captured when chain 1 held 9
  `MorphoVaultsMeta` instances. The KPK USDC Yield RWA vault
  `0x7a72bcD2c3F7F7e4D6679170a0625bAB15D7DDa1` was added to the LIVE NAV on 2026-08-12 by
  `addMetaInstances` (issue #296) and to config in the same PR, so `diff_snapshots.py pre post` will
  print `GAINED meta instance 0x…7a72bcd2…` and `metaInstanceTotal 66 -> 67`. **This is a STRUCTURAL
  diff and this section's rule is that a structural diff is never explained by drift — which is exactly
  why it is enumerated here rather than left to be waved through.** **Expect the STRUCTURAL lines and NOTHING ELSE — no new position entry and no `nav.value`
  movement.** Measured on mainnet 2026-08-12: the vault holds `totalAssets() = 1002452` (1.0025 USDC)
  against `totalSupply() = 1e18`, and that entire supply sits at `0x…dEaD` — seed shares. Every tracked
  chain-1 account holds ZERO, so no snapshotted account has a position to report. **The check to make is
  the GAINED-instance line and `metaInstanceTotal 66 -> 67`.** Their ABSENCE means the reconciliation
  dropped the vault — **but ONLY when diffing against the COMMITTED `pre/` snapshot (block 25625439),
  which holds 9 instances.** §0.7 sanctions refreshing `pre/`; if it is refreshed AFTER this change,
  both lines legitimately disappear and their absence proves nothing. Check `pre/1.json`'s
  `MorphoVaultsMeta` length first: 9 means the absence test is valid, 10 means it is not and the
  structural check has already been absorbed into the baseline. Do NOT treat a flat `nav.value` as evidence of a drop — a $1 seed position could
  not clear the residual band in any case, and an earlier revision of this entry said the opposite,
  which would have halted a correct deploy at the last gate before cutover.

- **ETHx drops from 2 monitor feeds to 1 on mainnet.** Redstone is retiring both of its ETHx push
  feeds, which backed both monitors. The direct Redstone **ETHx/USD** monitor `0xFaBEb147…` is gone
  with no replacement — Chainlink has no ETHx/USD feed at all (`FeedRegistry.getFeed` reverts
  `Feed not found`). The **`ETHxCrossRate`** monitor survives: its underlying ETHx/ETH rate feed was
  migrated from Redstone `0xc799194c…` to **Chainlink `0xC499ec76e2F5ac15e127A352Bc40cF24FC472401`**.
  So the diff shows ETHx's `monitorFeeds` 2 → 1, and the cross-rate feed at a new address (every feed
  is redeployed anyway). **This change is feed-count-neutral** — it swaps ETHx's rate leg rather than
  adding or dropping a feed contract; the totals moved to 26 mainnet / 41 for unrelated reasons (#199
  and #224, see 1.5). ETHx keeps its divergence/`irregular` signal at 250 bps.
  ETHx's **primary** price was never involved — `ETHx_CustomPriceFeed` reads Stader's on-chain rate
  via `stakePoolsManager` — so `nav.value` should not move.
  Verified on-chain before adopting: `description() == "ETHx / ETH"`, 18 decimals, answer
  `1.093319e18` vs Stader `getExchangeRate` `1.093906e18` = **5.4 bps** apart, last update ~13.8 h
  (inside the 86400 s heartbeat). The 18 decimals need no config change —
  `TwoFeedChainlinkPriceFeed` captures `10 ** rateFeed.decimals()` in its constructor
  (`TwoFeedChainlinkPriceFeed.sol:72`), so the rate decimals cancel into `NAV_DECIMALS`.

### 2.4 Records and docs

- `script/config/deployments/<chainId>.json` — the only place addresses live; all 24 updated.
- `script/deploy/DEPLOYED_ADDRESSES.md` — update the canonical addresses. **It must NOT claim the
  security-council Safe holds admin.** Step 07 is deliberately excluded, so the deployer EOA
  `0xAa5A7C7E…` retains `DEFAULT_ADMIN_ROLE` + `MANAGER` on every chain (verified on-chain across all
  24 in the `pre` snapshot). That file made exactly this false claim once before, fixed in
  `e2230a9d`; today's wording is correct — keep it.

### 2.5 Source verification

Use the `verify-contracts` skill. `PriceFeedLib` needs its special recipe: a **287-file**
standard-json (the import closure of all non-test roots, which pulls in exactly 3 `test/` files that
`script/test/*` imports), whitespace-only reduction to fit Etherscan's hard **3,000,000-character**
limit, and `settings.libraries` linking **both** `NAVRegistryLib` and `PriceFeedLib` (self-link).
Comment-stripping corrupts the bytecode; whitespace-only reduction does not. Always local-compile the
reduced JSON and assert the `PriceFeedLib` creation size before submitting.

### 2.6 Integration snapshots — AFTER the deploy, not before

```bash
script/test/refresh-integration-snapshot.sh
```

**Order matters and is not arbitrary.** `refresh-integration-snapshot.sh` derives fork blocks and
expected NAVs from live addresses, and the redeploy replaces every one of them. Refreshing beforehand
would pin the old stack and be invalidated by the deploy it was meant to guard — so the pre-deploy
slot belongs to 0.9 (DeBank parity), which is only possible while the old stack exists, and the
refresh belongs here, once the new addresses are recorded.

**The allowlist defect this refresh used to carry is fixed — expect ACCOUNT_1's DeBank anchor to move.**
From the 2026-06-17 config split (`5e25464d`) until `8fe1a949` (#286), three sites read
`chains/<id>.json .balanceAdapters`, a key the split removed, so the wallet-aggregating contribution to
the DeBank allowlist was **silently empty**. cUSD and stcUSD are deliberately not standalone priceable
assets, so that branch was their only path in.

Verified by direct read — `cast call balanceOf` for both tokens against **all 12 accounts** at **mainnet
block 25732915** (2026-08-11 16:21:47 UTC): **ACCOUNT_1 holds ~4.990006 cUSD and ~4.772012 stcUSD**; the
other 11 hold **zero of both**. So ~**$9.76** was missing from its anchor, against a recorded
`debankUsd` of `175.305516` — about **5.6%** of that figure.

**Material, but do not overstate it: it does not flip a parity verdict.** ACCOUNT_1's committed
`navUsd8dp` is ~$218.96, so the drift is **~19.9% before the fix and ~15.5% after** when expressed
against NAV (**~24.9% → ~18.3%** against the anchor — state the denominator, the two differ). The
account sits far outside the 1% tolerance either way, and its own `$comment` already documents an
expected ~12% drift. The correction moves the anchor toward NAV; it does not change a pass into a fail.

**This script is a full re-baseline, so more than one account will move.** It bumps every chain's
`forkBlock`, recomputes every `navUsd8dp`, and refetches DeBank for every enabled (chain × account).
Only the change *attributable to the allowlist fix* is isolated to ACCOUNT_1 — every other moved field
still needs reviewing on its own merits.

**It also spends DeBank units, so treat the run as an explicit authorisation, not a routine step.** One
`/v1/user/all_complex_protocol_list` per account (`:537`, covers every chain) plus one
`/v1/user/token_list` per (chain × account) (`:633`), gated on `DEBANK_API_KEY`, with
`/v1/account/units` queried first (`:127`).

**A skipped DeBank step is NOT an acceptable completion of this re-baseline, and it fails quietly.** The
cross-check is conditional: with `DEBANK_API_KEY` unset the script prints *"DEBANK_API_KEY not set —
DeBank cross-check skipped"*, and if the units probe returns no balance it prints *"proceeding without
DeBank cross-check"* — in both cases it continues and **leaves every existing `debankUsd` untouched**.
**Do not use the exit code to tell whether this happened.** There is no dedicated failure for skipping
DeBank, and the run can still exit non-zero for an unrelated reason: step 4 evaluates the *retained*
anchors against tolerance and exits 2 on a violation — and ACCOUNT_1 already exceeds 1%, as recorded
below. So a non-zero exit does not mean DeBank ran, and a zero exit does not mean it did. **The
field-change check below is necessary but not sufficient; acceptance rests on the four conditions
after it, never on the exit status** — the same doctrine this
runbook already applies everywhere else ("gate every step on its post-condition, not on its exit code",
and the `a step exits 0 having done nothing` row in the failure table). The whole point of this
re-baseline is ACCOUNT_1's corrected anchor, so a run that skipped DeBank has not done it.
**Prerequisites are therefore: authorisation for the unit spend AND a working key with units
available.** Afterwards, confirm the DeBank requests for ACCOUNT_1 actually completed, and reconcile
`expected."1".debankUsd` against ACCOUNT_1's **current** holdings.
**An unchanged value does not prove the step was skipped.** The ~$9.76 figure is ACCOUNT_1's position at
block **25732915**; this refresh reads *current* state, so the holding may have moved, or unrelated
changes may offset it, before the runbook is executed. Treat an unchanged value as a prompt to check the
requests — not as proof of a skip, and not as proof nothing needed correcting.

**That single-field check is necessary but NOT sufficient, so do not treat it as authoritative on its
own.** A non-empty units response counts as active even when it reads `0` (`:136-140`), and a failed
request is substituted with `[]` and the anchor written anyway: a failed `all_complex_protocol_list`
warns *"protocol totals will be 0"* (`:538-541`) and a failed `token_list` warns *"using protocol total
only"* (`:634-636`). So a run can change ACCOUNT_1 correctly while **silently writing partial totals over
other accounts' anchors**. Accept the re-baseline only when all **four** hold: **positive units**, **no
`[warn] … request failed` lines in the output**, **every enabled anchor reviewed** (not just the one this
fix targets), and **no failed or skipped chains**.

That fourth condition is not covered by the other three. If step 2 fails for a chain,
`finalize_step2_outcomes` rolls its `forkBlock` back, **narrows `chain_ids` to the survivors**
(`refresh-integration-snapshot.sh:482-503`), and steps 3/4 then run normally over the rest — so DeBank
can succeed everywhere it was asked and all three earlier checks pass while the skipped chain keeps
**stale snapshots**. The script does say so: it prints `Incomplete run … NAV was not regenerated for
chain(s): …` and exits 1 (`:684-689`), and exits 1 on `failed_chains` (`:762-764`).

**So narrow the earlier exit-status warning to what it was about.** "The exit code proves nothing"
applies to **detecting whether DeBank ran** — a skipped cross-check has no dedicated failure. It does
**not** license ignoring a non-zero exit in general: `Incomplete run` / exit 1 is a real signal and must
not be waved through.

Before spending anything, re-verify the allowlist matches its exact expected pair. **Do not run
`generate-comparison-report.py` as a program to do this** — it fetches live DeBank data whenever
`DEBANK_API_KEY` is set (`generate-comparison-report.py:1525-1529`, `:1560-1564`), which would spend the
units this check exists to protect, and it does not print the set anyway. The helper has no CLI. Load
the module without executing it, with the key forced empty:

```bash
DEBANK_API_KEY= python3 -c "
import importlib.util
s = importlib.util.spec_from_file_location('g', 'script/test/generate-comparison-report.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(sorted(m.adapter_aggregated_addrs('1')))"
```

`main()` is behind an `if __name__ == "__main__"` guard (`:1724`), so importing runs no network code.
Expect both Cap token addresses:
`['0x88887be419578051ff9f4eb6c858a951921d8888', '0xcccc62962d17b8914c62d74ffb843d73b2a3cccc']`.
**Require exact equality with that pair, and stop on any other output.** An empty list means the
allowlist is broken again; **one address means a PARTIAL regression** — if either constructor parameter
is absent or misnamed the helper returns a single token, and an empty-only check would wave that
through and let the costly refresh proceed with the other token still omitted. This is the check whose
absence let the defect run for ~8 weeks, and it costs nothing **only when invoked this way**.

⚠️ **This gate checks a DIFFERENT implementation from the one the refresh uses, so it is necessary but
not sufficient.** `adapter_aggregated_addrs` is `generate-comparison-report.py`'s Python helper
(`:222`); the costly refresh builds its own allowlist in **jq**
(`refresh-integration-snapshot.sh:566-587`). Both read the same source of truth
(`script/test/wallet-aggregating-adapters.json`), so the *data* cannot diverge — but the *logic* can:
a regression confined to the jq expression would leave this pre-check printing the expected pair and
the refresh still omitting a token. Until the refresh exposes a no-network "print allowlist" mode, or
the two are centralised on one implementation, a passing pre-check means the Python path is intact,
not that the refresh's path is.

> **Methodology warning — the harness can answer confidently and emptily.** The first instrument used to
> ask "does any account hold these tokens?" returned **"no chain-1 accounts, nothing to check"** and a
> benign verdict, reporting `chain1=no` for all 14 entries including `ACCOUNT_9_MAINNET_DIVERSIFIED`.
> Cause: a guessed schema key — the field is **`enabledChains`**, not `chains`. Nothing errored; the
> wrong key returned an empty set, and an empty set reads exactly like "clean". The tell was that the
> result was **too tidy given something already known**: ACCOUNT_1's own `$comment` advertises *"dust
> positions across Morpho/Aave V3/**Cap**/Sky/Ethena"*. Treat an empty result here as unproven until
> something independent corroborates it.

PR #174 (the bot's snapshot refresh) was **closed, not merged**, so nothing has refreshed these since
before the wave. That is outstanding independently of this deploy and should not be mistaken for
redeploy fallout.

### 2.7 Downstream cutover — the user's

kpkShares / portal / agents / subgraphs must repoint from `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d`
to the new proxy. The old stack keeps answering until they do; nothing needs unregistering on it.

---

## 3. Failure playbook

> **Exit status 0 does not mean work happened.** Several scripts return cleanly when a precondition
> is unmet: `RegisterAssets` prints `NAVCalculator not deployed for this chain. Deploy it first, then
> re-run.` and returns; `03`/`04` print `Already deployed at:`; `06` prints `BridgeEscrow not
> deployed, skipping`. In the fork rehearsal, `RegisterAssets`, `04` and `06` all reported success
> having done nothing, purely because `01_2` had reverted upstream. Always verify the
> post-condition counts, never the exit code. `rehearse_fork.sh` now treats those phrases as
> failures, and `verify_step.py <step>` asserts the post-conditions themselves.
>
> **The preflight tools have the same failure mode, and it was real.** They defaulted their chain
> scope to `chainlib.deployed_chain_ids()`, which infers scope from a populated `NAVCalculatorProxy` —
> the very key step 1.1 blanks on all 24 chains. Post-1.1 that returns `[]`, so
> `preflight_config.py` reported `0 error(s) across 0 chain(s)` and exited 0, and
> `reset_deployment_records.py --restore <tag>` with no chain arguments restored **nothing** and
> exited 0 — the rollback failing silently at the one moment it is needed. Scope now comes from
> `chainlib.resolve_chains`, which takes an explicit chain list first and otherwise uses the declared
> `redeploy_scope.json` (a file no tool writes), cross-checking `snapshots/pre/index.json` and
> reporting any disagreement as a `SCOPE WARNING` rather than absorbing it — and **exits 2 rather
> than resolving to an empty list**. Every tool prints the
> scope it resolved and where from; read that line.

| symptom | cause | fix |
| --- | --- | --- |
| `01_2` reverts `… CREATE2 addr != foundry.toml pin` | library bytecode drifted from the pin | regenerate both pins against the final tree (0.3); never from an incremental build |
| `01` "succeeds" but the NAV reverts on `initialize` | historical: `01` had no pin assertions and deployed the libraries at the *computed* addresses while the impl links the *pinned* ones. `01` now asserts the pins, so this fails fast instead | if it still happens, the pins are stale — regenerate, do not work around |
| a step exits 0 having done nothing | unmet precondition, handled by an early `return` | `verify_step.py <step>`; check the post-condition, not the exit code |
| a preflight tool reports `0 … across 0 chain(s)` | its chain scope resolved to empty | it now exits 2 instead; if you see this on an old checkout, pass the chain ids explicitly |
| `--restore` prints `restored 0 record(s)` | same empty-scope bug, on the rollback path | pass the chain ids explicitly, and check `archive/<tag>/` actually holds the records |
| `01_2` reverts `NAVCalculator impl not linked against pinned …` | `foundry.toml [libraries]` drifted from `LibraryPins` | make them agree, rebuild |
| `02_2` reverts inside `AtomicNAVProxyDeployer` | proxy address unchanged → code already there → `upgradeToAndCall` with no admin | bump `DeploySalts.NAV_PROXY` (0.2), then re-pin (0.3) |
| `03`/`04` log "Already deployed at:" and deploy nothing | the record was not cleared | run 1.1, re-run |
| `06` finishes but adapter/instance counts are short | an adapter never deployed; `06:113` skipped it silently | `preflight_config.py`, then re-run **1.7** (`04`, deploys the missing adapter) **and 1.8** (`06`, registers it and adds its meta instances). Re-running 1.7 alone leaves the adapter deployed but UNREGISTERED and the NAV still short |
| `06` reverts `addMetaInstances failed … DuplicateMetaInstance` | duplicate coordinate in config | `preflight_config.py` flags it; fix nav-config |
| `RegisterAssets` `MemoryOOG` on mainnet | default memory limit | `FOUNDRY_PROFILE=slow` |
| `RegisterAssets` logs `[skip] primary feed unresolved (deploy it first)` | it ran before `03`, so Custom feeds are not in the record | run `03` first; re-run `RegisterAssets` (idempotent) and confirm `getAssetCount()` |
| `vm.writeJson: failed to open .../safe-transactions/<id>-register-assets.json` | the directory does not exist; on-chain writes already succeeded | `mkdir -p safe-transactions`, re-run |
| addresses differ per chain that should be identical | a chain ran with a different build or submodule set | 0.4, then rebuild and redeploy that chain — `verify_step.py 1.2`/`1.3` compares across chains and names the odd one out |
| an assistant's `ADAPTER()` is not its paired adapter | the `*Assistant` key was not cleared, so `04` skipped the redeploy | clear it (1.1), re-run 1.7, re-check with `verify_step.py 1.7` |
| hyperevm impl deploy "exceeds block gas limit" | small blocks | enable big blocks (1.10) |
| hemi tx rejected on price | fee floor | raise `--with-gas-price` (1.10) |
