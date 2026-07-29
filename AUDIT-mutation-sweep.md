# Mutation sweep — Shape 1 (duplicate tests) and Shape 2 (unwired guards)

**Status:** the sweep that produced this report ran read-only against `81c2ed4d` and restored every mutation. The
findings below are now **fixed on this branch** — see PR #205. Kept as the evidence record: it states which
mutation proved each finding, and which guards were mutated and found sound.

> **The fix for finding 2.1 initially reproduced finding 2.1.** Two review gates independently found that the
> harness I wrote to wire the pin guards exposed only the *pins*, not the bytecode — and that this made the
> NAVRegistryLib linkage assertion **structurally untrippable in either pin state**, while a `vm.skip` would have
> retired its sibling the moment PR #185 lands. Deleting that assertion left the whole new file green. It is now
> fixed with the bytecode seam PR #194 already had, and verified the same way the original findings were: deleting
> the assertion turns exactly the two new linkage tests red and nothing else. Recorded here because it is the
> sharpest available illustration of the sweep's own thesis — writing a guard's test is not the same as wiring it,
> and only mutation tells them apart.

### Corrections this report has accumulated

Left visible rather than edited away. Each was caught by review, and the pattern is the point: three of the four
are cases where *my own reasoning about a test* was wrong in a way only mutation or careful control-flow reading
exposed — the same failure mode the sweep hunts, one level up in the justification rather than the assertion.

| # | Claim | Why it was wrong |
|---|---|---|
| 1 | "The `vm.warp` in `…_initializedUpAfterGracePeriod` is inert." | The mock is a ternary on `block.timestamp > 1 hours`; forge starts at 1, so the warp selects the *branch*. Removing it turned the test red. |
| 2 | The pin-guard harness wires the linkage assertions. | It injected only pins, so assertion 4 was untrippable in either pin state and `vm.skip` would have retired assertion 3 post-#185. |
| 3 | "`…_answerNonZero` is kept because it pins the blanking mutation, which the other does not." | Under `if (answer != 0) { }` the condition still MATCHES, so the `else if` chain is skipped and both fixtures read not-stale. Strictly subsumed. |
| 4 | The positive control proves the deploy wrapper works. | A raw `.call` to the code-less CREATE2 factory returns `ok == true`, so it could not distinguish "works" from "deployed nothing". |

### Two process hazards worth carrying forward

**Review gates left five source files mutated while reporting the tree clean.** Round 4 disabled guards in
`PriceFeedLib` (`if (answer != 0)` → `if (false)`, plus four registration guards commented out), `Prices`,
`OracleArgumentChecks`, `BaseDeployScript` and `01_DeployImplementations`, then asserted `git status` showed only
the untracked audit file. It did not. Nothing reached a commit, but a concurrently-running second gate spent its
whole run reading a tree with guards disabled, so its findings were worthless and had to be discarded. Fixes
adopted: **run gates sequentially**, and **fingerprint the tracked tree before and after every round**
(`sha256sum` over `git ls-files | grep -v '^lib/'`) so debris is detected rather than stumbled upon.

**An incremental build read a library pin that corresponded to no tree that ever existed.** Immediately after
the round-4 restore, `test_priceFeedLib_pinMatchesCurrentBytecode` reported `0x00a3AFAC…` instead of
`0xD477d7e2…`. Only two *test* files had changed, neither in `PriceFeedLib`'s closure, so a real move was
impossible — forge had linked artifacts cached from the mutated compilation. A `forge clean` + full build snapped
it back. `0x00a3AFAC` is the same value a previous session chased through CI and proved was sticky-cache reuse;
this is the local-side instance of it, with a known cause. **No pin value from an incremental build is evidence.**

**Branch:** `audit/mutation-sweep`, swept at `81c2ed4d` (origin/main, PR #194 merge), fixes applied on top of
`e04895b3`.
**Worktree:** `/home/sgzerbo/github-projects/onchain-accounting-mutation-sweep`
**Date:** 2026-07-29

---

## Method

Two shapes, two detection methods.

**Shape 1 — byte-identical-to-happy-path.** Mechanical. Two passes over every `.sol` file in the repo:

- *Strict pass:* strip comments, strip all whitespace, compare test-function bodies **within one contract**.
  Cross-contract pairs are excluded — a file may hold N test contracts with different `setUp()`s, which makes
  a cross-contract match meaningless. (A first, contract-blind version produced 156 pairs, almost all noise.)
- *Canonicalised pass:* additionally rename value-position identifiers consistently, and separately canonicalise
  numeric literals. Call targets (`foo(`) and member names (`.foo`) are **preserved** — an early version
  canonicalised them too and reported `addBalanceAdapters(…)` as identical to `registerAsset(…)`, which is wrong.

Every surviving pair was then read by hand to answer the question the detector cannot: *do the two bodies
exercise different states?* Several did (different mock, different pranked actor, different decimals) and are
recorded below as rejected candidates.

**Shape 2 — guard present but never wired.** For each guard, two independent mutations, per the PR #194 method:

- **blank the body** — proves the assertions fire when the guard objects;
- **delete the call site** — proves the production path reaches the guard at all.

A guard where only the first goes red is the finding. Where a guard's return value is consumed by its caller
(`PriceFeedLib.validateAdapterSlice`), deleting the call does not compile — those are wired by construction and
were not mutated.

Two static pre-filters narrowed where the mutation budget went:

1. **Guard inventory.** `src/{nav,prices,balances}` contains exactly **one** `require(` — the vendored
   `TickMath.sol:35`. Every other guard is a custom-error `revert`. So enumerating the distinct custom errors
   reverted in those trees *is* the complete guard inventory: **44 distinct errors**. Cross-referencing each
   against every `.selector` mention (and every bare textual mention) in `test/` + `script/test/` gives an exact
   list of guards no test names at all.
2. **Dead-guard detector.** Every `internal`/`private` function in `src/` + `script/` whose body contains a
   `revert`/`require`, with zero call sites anywhere in `src/` + `script/`. Six hits, all adjudicated below.

Both pre-filters are **candidate generators, not verdicts**, and the sweep proved why: one of the nine errors
pre-filter #1 flagged as "named by no test" is in fact covered by three tests that assert the guard's *behaviour*
without naming the error. It was only mutation that separated it from the other eight. A third detector — tests
naming a production function their body never calls — was written and discarded: 64 hits, almost all legitimate
indirection through harness wrappers (`harness.probeUint` for `safeUint`) or differently-named production methods
(`unsetBalanceAdapter` for `removeBalanceAdapter`). It is recorded here as a method that did not pay off.

**Build discipline.** This box was running 3–5 concurrent whole-program `via_ir` compiles for most of the
session (six other sessions share it); `MemAvailable` reached 38 MB at one point and the first baseline build was
killed. Every build was gated on `pgrep -c solc` and `MemAvailable`, and mutations were batched per build rather
than applied per assertion.

**Restore discipline.** A sha256 fingerprint of all **890** tracked non-submodule files was taken before any
edit. Every mutation batch is applied and restored by a scripted `git checkout --` of an explicit file list,
followed by a re-fingerprint that must match the baseline exactly. The diff was read, not just `git status`.
Baseline digest of the manifest: `ef740fd40f2b119c1f2e301dd66db6c4e59667d0354c0ae738ecd14233010154`.

---

## Scope — what was covered, and what was not

**Covered.**

- Shape 1: **every** `.sol` file in the repo (test and non-test), all contracts, both passes. This part of the
  sweep is exhaustive, not sampled.
- Shape 2 static inventory: all 44 custom-error guards in `src/{nav,prices,balances}`; all guard-bearing
  `internal`/`private` functions in `src/` and `script/`; all `require` sites in `script/deploy`,
  `script/upgrade`, `script/utils`.
- Shape 2 mutation: the deploy/upgrade guards listed in the results table, plus the `src` guards listed there.

**Not covered — stated plainly.**

- `src/bridge/` guards were inventoried but not mutated. Bridge is not on the NAV read path and is not in the
  24-chain immutable redeploy; it was deprioritised deliberately. One bridge observation is recorded anyway.
- Fork suites were not mutation-tested. They need RPC and `FOUNDRY_PROFILE=slow`, and the prior sweep already
  covered the fork-specific early-return shape mechanically (15/15 confirmed).
- Mutation was not run per-call-site. Where a guard has many call sites (`_requireManager`, 24 sites), the
  wiring mutation deletes them as a group; that proves *some* site is covered, not every site.
- `script/manage/` was inventoried, not mutated, except where it shares a guard with `script/utils`.

---

## Shape 1 — confirmed duplicates

Four pairs survived hand adjudication. All four are inside one contract, so `setUp()` is identical and there is
no hidden state difference to appeal to.

### 1.1 `test/nav/NAVCalculator.t.sol:223` — `test_addBalanceAdapter` is byte-identical to `test_registerAsset:248`

Bodies are the same after comment stripping — same `setupNAVCalculatorWithParams`, same `grantRole`, same single
`registerAsset(usdc, usdcAdapter, Custom, max)`, same `stopPrank`. The only textual difference is a comment in
`test_addBalanceAdapter`: *"ERC20DefaultBalanceAdapter is already registered globally, no need to add it again"*.

**What it claims vs what it pins.** The name claims coverage of `addBalanceAdapters`. The body never calls it.
It pins exactly what `test_registerAsset` pins, and nothing else. Neither test asserts anything at all — there is
no `assertEq` in either; both are "did not revert" tests.

**Mutation.** Deleting the entire body of `NAVCalculator.addBalanceAdapters` cannot fail `test_addBalanceAdapter`,
because the test does not reach it.

**Severity: low.** `addBalanceAdapters` is well covered elsewhere — 16 call sites in
`test/nav/NAVCalculator.gasCaps.t.sol`, plus `NAVCalculator.errors.t.sol`, `TestSetupHelpers.sol`, the invariant
and paginated suites. This is suite dead weight and a misleading name, not a coverage hole.

### 1.2 `test/nav/NAVCalculator.t.sol:689` — `test_getRegisteredAssets_lengthMatchesAssetCount` duplicates `test_getRegisteredAssets:759`

```
:689  INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
      assertEq(registered.length, nav.getAssetCount());
      assertTrue(registered.length > 0);

:759  INAVCalculator.Asset[] memory assets = nav.getRegisteredAssets();
      assertEq(assets.length, nav.getAssetCount());
      assertTrue(assets.length > 0);
```

Identical but for the local variable name. The longer name promises a *specific* invariant
("length matches asset count") that the shorter test already asserts verbatim.

The same file repeats the pattern one function later at a size the detector's 40-char floor excluded:
`test_assetCount:695` and `test_getAssetCount:765` both assert only `count >= 4`. `assetCount()` is a one-line
alias returning `getAssetCount()` (`src/nav/NAVCalculator.sol:311-313`), so the pair is near-vacuous too — though
the alias is at least a distinct ABI entry point, which is more than 1.2 can claim.

**Severity: low.** Redundancy, not a gap.

### 1.3 `test/balances/Balances.t.sol:292` — `test_RevertIf_InvalidAdapterERC20` is byte-identical to `test_RevertIf_InvalidAdapterCustom:299`

```solidity
address invalidAdapter = makeAddr("invalid");
vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
balances.checkBalanceAdapterSupport(invalidAdapter);
```

Both tests. Same `makeAddr` seed, so literally the same address.

**What it claims vs what it pins.** The names promise two distinct rejection scenarios — an ERC20 address and a
"custom" adapter address. Both pass an EOA with no code. No ERC20 is involved in the ERC20 test, and the file has
a real one to hand (`usdc`) that would have made the second case distinct: a contract *with* code that does not
implement ERC165/`IBalanceAdapter` is a different input class from a codeless EOA.

**Severity: low.** `checkBalanceAdapterSupport` (`src/balances/Balances.sol:110-116`) routes both through
OZ's `ERC165Checker`, which returns false for a non-contract and for a contract without ERC165 alike — so the
guard itself is covered. What is missing is the distinct *scenario* the name advertises.

### 1.4 `test/balances/BalanceAdapter.gas.t.sol:245` — `test_gasBenchmark_baseline_singleAsset` is byte-identical to `test_gasBenchmark_getAdapterBalanceForAsset:84`

Same mint, same call, same `assertGt(amount, 0)` and `assertGt(gasUsed, 0)`. The docstring calls it
"Establish baseline for single asset", but it establishes nothing: the measurement is never compared against the
other benchmark, or against any threshold. Both assert only that gas consumption was greater than zero.

**Severity: informational.** A gas benchmark, not a correctness guard.

### Shape 1 — candidates rejected after reading

Recorded so the sweep is auditable rather than a list of hits. Each of these normalised identically (or ≥0.95)
and was rejected because the two bodies genuinely drive different states:

| Pair | Why rejected |
|---|---|
| `Prices.t.sol:283` / `:300` | Different mocks — `disabledUptimeFeed` (answer=1) vs `uninitializedUptimeFeed` (startedAt=0). Two different arms of `checkSequencerUptime`. **But see finding 2.3** — the first is misnamed and the arm its name claims is unreached. |
| `BridgeEscrow.errors.t.sol:81` / `:92` | Different pranked actor (`unauthorized` vs `manager`). ADR 0012 H9 requires MANAGER to be rejected too; that is a real second scenario. |
| `EthenaCooldownBalanceAdapter.t.sol:127` / `:139` | Different asset (`usdc` = unsupported vs `usde` = supported-but-no-cooldown). Same return, different path. |
| `CapBalanceAdapter.t.sol:255` / `:261` | Same shape as above (unsupported vs zero asset). |
| `ERC4626VaultRatePriceFeed.t.sol:28` / `:42` | 18-decimal vs 6-decimal shares — the exact axis the fix was about. |
| `GearboxV3CreditAccountsMetaBalanceAdapter.t.sol:275` / `:283` | `setDebtReverts` vs `setInfoReverts` — different mocked failure. |
| `NexusMutual…fork.t.sol:190` / `:194` | Two different real holders. |
| ~30 `test_constructor_revertsOnZeroX` families | One argument zeroed per test; the varying literal is the point. |

A first, contract-blind version of the detector also flagged the `wstETH_L2` / `weETH_L2` fork files heavily.
Those are several test contracts per file, one per chain, with different `setUp()` fork blocks — all rejected once
pairing was scoped to a single contract.

---

## Shape 2 — guards and their wiring

### 2.1 The library-pin guards in `01_DeployImplementations` and `01_2_DeployNAVImplementation` are unwired

`script/deploy/01_DeployImplementations.s.sol:83-103` (four `require`s)
`script/deploy/01_2_DeployNAVImplementation.s.sol:47-68` (four `require`s)

These are the guards PR #191 added, and they are the direct ancestors of the ones PR #194 moved into
`UpgradeNAVCalculator`. In the upgrade script the guard was deliberately extracted into
`_assertPinnedLibrariesUsable` + `_deployGuardedNavImplementation` **precisely so a test could reach it** — the
PR's own docstring records that "deleting the guard CALL — not blanking its body — left every test green".

In `01` and `01_2` that extraction never happened. Both blocks sit inline in `run()`, and **no test anywhere
imports, constructs, or invokes `DeployImplementations` or `DeployNAVImplementation`.** `grep -rn` across `test/`
and `script/test/` returns only a doc-comment mention in `test/LibraryPinConsistency.t.sol:13`.

Because the guards are inline, "blank the body" and "delete the call site" collapse into one mutation — and there
is no seam through which the first could ever be exercised separately.

**Mutation — confirmed (batch B / M1, M2).** Rather than deleting the guards, I did something strictly stronger:
`revert("TRIP_01")` / `revert("TRIP_01_2")` as the **first statement of `run()`**, which fails the function before
anything at all can happen. Zero tests failed, and the marker strings appear **zero times** across 1562 tests'
output. Nothing reaches either `run()` by any route.

**What the tests claim vs what they pin.** Nothing claims to test these scripts, which is the honest part. The
misleading part is `script/test/README.md`, which advertises CI coverage for the deploy scripts and ends with a
YAML snippet under "Continuous Integration" that does not exist in `.github/workflows/foundry.yml`.

**Mitigating — state it plainly.** `test/LibraryPinConsistency.t.sol` asserts the same three underlying
properties directly (pin-matches-bytecode ×2, `NAVCalculator` creationCode linked against both pins). So the
*properties* are covered by CI; what is untested is the *script's refusal to broadcast*. Given `01`/`01_2` are what
actually deploy implementations across the 24 chains, and given the failure mode the comment block describes at
length (libraries deploy successfully at unpinned addresses, `require(ok)` never fires, the proxy later
DELEGATECALLs into the wrong version), the gap is in the wiring, not in the idea.

**Severity: medium.** The properties are guarded elsewhere; the scripts' behaviour is not.

### 2.2 `BaseDeployScript._requireTolerancesPlannable` has no test at all

`script/utils/BaseDeployScript.sol:157-180`. Three guard arms: a `require` that a divergence tolerance exists
when monitors are being added, and two `revert`s for tolerances above 10 000 bps.

Call sites are real and on the deploy path — `script/manage/RegisterAssets.s.sol:205` and
`script/manage/MigrateToMonitorFeeds.s.sol:134`.

Nothing in `test/` or `script/test/` imports or instantiates any contract in `script/manage/`. The integration
harness explicitly *re-implements* the logic instead: `test/integration/IntegrationFromConfigBase.fork.sol:802`
is commented "Wires an asset's divergence/peg tolerances and monitor feeds (**mirrors** production
RegisterAssets)". A mirror cannot catch a divergence from the thing it mirrors.

**Mutation — confirmed (batch B / M4).** Blanking the body to `{}` produced no failure. Deleting the call sites
would be equally invisible, because there is no test to notice either. That is a coverage hole rather than a
wiring hole, and worth separating from 2.1: 2.1 has the property covered elsewhere, this has nothing covering it.

**Severity: medium**, and rising with the redeploy — `RegisterAssets` runs per chain.

### 2.3 The grace-period arm of `PriceFeedLib.checkSequencerUptime` is unreachable by the mocks that are wired in

`src/prices/PriceFeedLib.sol:454-461`:

```solidity
if (answer != 0)            stale = true;      // "covered" — disabledUptimeFeed / sequencerUptimeFeedDown
else if (startedAt == 0)    stale = true;      // "covered" — uninitializedUptimeFeed
else {
    uint256 effectiveStartedAt = startedAt > block.timestamp ? block.timestamp : startedAt;
    if (block.timestamp - effectiveStartedAt <= gracePeriod) stale = true;   // <-- line 460
}
```

> **CORRECTION — both "covered" annotations above were wrong, and in the same way.** The original sweep found the
> grace-period arm unreached and reported the other two as covered. They were covered only against the *blanking*
> mutation. Against *arm removal* — the canonical branch-deletion operator, and the one this report treats as
> decisive — each was rescued by the arm beneath it:
>
> - **Arm 1** (`answer != 0`): its fixtures all report `startedAt == 0` as well, so removing the arm dropped
>   through to arm 2, which still set `stale`. Found in review round 3; fixed with a settable-answer mock and a
>   fixture carrying a real `startedAt`.
> - **Arm 2** (`startedAt == 0`): its one fixture runs at `block.timestamp == 1`, so removing the arm dropped
>   through to arm 3, where `elapsed = 1 <= gracePeriod` still set `stale`. Found in review round 7; fixed by
>   warping past the grace period.
>
> The general shape, which is the reusable part: **in an `if / else if / else` chain, every arm's removal is
> masked by the arm beneath it unless the fixture is chosen so the lower arms would answer differently.** A
> three-arm chain needs three fixtures selected against three different lower arms — one per arm is not enough,
> and "there is a test that reaches this arm" is not the same as "this arm is pinned". All three arms of this
> guard needed a distinct fixture, and all three were initially wrong in the same direction: under-reporting
> staleness, which is the over-report direction for NAV.

Three things line up here, and the third is the one that makes this more than a coverage note:

1. **The test named for the branch does not enter it.** `test/prices/Prices.t.sol:283`
   `test_checkL2SequencerUptime_withinGracePeriod` constructs its harness with `disabledUptimeFeed`, whose
   `answer` is 1. Its own comment says so: *"The uptime feed is disabled (answer = 1), so sequencer is down"*.
   It exits at line 454, two branches above the one it is named for.
2. **The mock built for this branch is constructed and abandoned.**
   `Mock_ChainlinkL2SequencerUptimeFeedWithinGracePeriod` (`test/mocks/price_oracles.sol:149`) returns
   `startedAt = block.timestamp`, i.e. elapsed 0 — exactly the input line 460 needs. `test/SuperTest.sol:54`
   declares it and `:92` constructs it as `sequencerUptimeFeedtWithinGracePeriod`. **No test references it.**
3. **The mock that IS wired in sits one second outside the window.** `Mock_ChainlinkL2SequencerUptimeFeed`
   (`:109-121`) returns `startedAt = block.timestamp - 1 hours - 1` once the clock is past an hour, so elapsed is
   3601 against a `gracePeriod` of `1 hours` (`src/prices/Prices.sol:57`; `NAVCalculator` uses 3600 too) —
   permanently one second outside the window.

> **CORRECTION.** This finding originally added that the `vm.warp(block.timestamp + 2 hours + 1)` in
> `test_checkL2SequencerUptime_initializedUpAfterGracePeriod` was *inert, because the mock is time-relative*.
> **That was wrong, and the fix's own test caught it.** The mock's body is a ternary —
> `block.timestamp > 1 hours ? block.timestamp - 1 hours - 1 : 1` — and forge starts the clock at
> `block.timestamp == 1`. Without the warp the SECOND arm applies, `startedAt` is 1, elapsed is 0, and the feed
> lands *inside* the grace window. The warp is what selects the first arm. Removing it flipped the test red
> immediately. The time-relative reasoning holds for the first arm and says nothing about which arm is taken.
> The rest of the finding stands: the arm at line 460 was genuinely unreached, and neutralising it left the
> suite green.

**Mutation — confirmed (batch C / M5).** Neutralising line 460 changed nothing: `1556 passed, 6 failed`, and all
six failures are accounted for by the baseline three plus M13's three. Not one test noticed that the grace-period
arm had stopped working.

**What the tests claim vs what they pin.** Four tests named for sequencer-uptime behaviour, one of which claims
the grace period by name; between them they pin the `answer != 0` arm, the `startedAt == 0` arm, the
`uptimeFeed == 0` early return, and one point 1 second outside the window. The grace window itself — the reason
the L2 sequencer check exists — is pinned by nothing.

**Severity: medium.** This is on the NAV read path on every L2 (`Prices.sol:66`, `NAVCalculator.sol:908`) and
`PriceFeedLib` is in the redeploy.

### 2.4 Eight guard arms on the price-feed registration path are asserted by nothing

> **Scoped down by mutation.** The static pre-filter produced nine candidates; one of them
> (`InvalidArgumentsWithContext` in `MetaBalanceAdapter._toAddress`) turned out to be **well covered** — three
> tests assert the behaviour without ever naming the error. See batch C / M13 below. The finding is the other
> eight, six of which are confirmed by mutation and two of which are static-only.

`src/{nav,prices,balances}` contains exactly one `require(` (vendored `TickMath.sol:35`); every other guard is a
custom-error `revert`, so the distinct-error list *is* the guard inventory. 44 distinct errors; 35 are named by
at least one test; these 9 are named by none — not as `.selector`, not textually anywhere under `test/` or
`script/test/`:

| Error | Site | Guarded operation |
|---|---|---|
| `PriceFeedDecimalsMismatch` | `PriceFeedLib.sol:1511` | `addFeed` — second feed disagrees on decimals |
| `PriceFeedIndexOutOfBounds` | `PriceFeedLib.sol:1531` | `removeFeedAt` |
| `PriceFeedIndexOutOfBounds` | `PriceFeedLib.sol:1608` | `removeMonitorFeedAt` |
| `PriceFeedIndexOutOfBounds` | `Prices.sol:91` | `getPriceFeedAt` |
| `MonitorFeedDecimalsMismatch` | `PriceFeedLib.sol:1582` | `addMonitorFeed` |
| `MonitorFeedAlreadyRegistered` | `PriceFeedLib.sol:1587` | `addMonitorFeed` |
| `MonitorFeedNotFound` | `PriceFeedLib.sol:1633` | `removeMonitorFeed` |
| `InvalidPriceOracleType` | `PriceFeedLib.sol:1663` | `_validateFeedSupportInternal` — **static only, not mutated** |
| `MonitorFeedNotFound` | `PriceFeedLib.sol:1633` | `removeMonitorFeed` — **static only, not mutated** |
| ~~`InvalidArgumentsWithContext`~~ | ~~`MetaBalanceAdapter.sol:455`~~ | **withdrawn — covered, see M13** |

The enclosing functions are themselves exercised (`addFeed`, `addMonitorFeed` are all over the price suites), so
this is branch-level, not function-level: neutralising any one of these arms is invisible to the suite.

All eight sit on the **feed-registration** path — `addFeed` / `addMonitorFeed` / `removeFeedAt` /
`removeMonitorFeedAt` / `getPriceFeedAt` — which is precisely what `06_Configure` and
`script/manage/RegisterAssets.s.sol` drive on all 24 chains during the redeploy.

**Severity: medium** as a group, low individually.

### 2.5 `ETHPlus_CustomPriceFeed`'s zero-heartbeat guard is masked by the guard above it

`test/prices/protocols/ETHPlus_CustomPriceFeed.t.sol` is the whole file — two tests, both bare `vm.expectRevert()`:

```solidity
function test_invalidConstructorArgs_zeroAddress()  { vm.expectRevert(); new ETHPlus_CustomPriceFeed(address(0),   86400); }
function test_invalidConstructorArgs_zeroHeartbeat(){ vm.expectRevert(); new ETHPlus_CustomPriceFeed(address(0x1), 0);     }
```

The constructor (`src/prices/protocols/ETHPlus_CustomPriceFeed.sol:53-57`) runs
`OracleArgumentChecks.assertERC20Address(ethPlus_)` **first**, then `assertNotZeroNumber(heartbeat_)`.
`address(0x1)` has no code, so the heartbeat test reverts on the *address* check and never reaches the heartbeat
check. A bare `expectRevert()` accepts either.

This is the same masking the PR #194 reviewers hit ("the PriceFeedLib check fires first and masks it"), reached
by a different route: not a missing seam, but an unnamed `expectRevert` plus an argument that trips an earlier
guard.

**Mutation — confirmed (batch C / M6).** Replacing `assertNotZeroNumber(reserveProtocolHeartbeat_)` with the bare
argument left both tests passing. The file's entire purpose is to check two constructor arguments; it checks one.

**Severity: low.** `ETHPlus_CustomPriceFeed` is deployed on no chain (confirmed independently in the price-feed
audit, call-out B). The pattern is what matters — I checked the other 30-odd feed constructor suites and they
zero exactly one argument per test, so this file is the only instance.

### 2.6 Two guard-bearing helpers with no call site — both documented, neither a defect

The dead-guard detector (guard-bearing `internal`/`private` functions with zero call sites in `src/` + `script/`)
returned six hits. Four are explained: `_authorizeUpgrade` is a UUPS override the base calls;
`_getImplementations` is a test helper; `_removeBalanceAdapter` / `_revokeBridgeAdapter` in
`script/manage/ManageAdapters.s.sol` are `--sig` entry points. The remaining two:

- **`BalanceAdapterAssistant._requireSelf`** (`src/balances/.../BalanceAdapterAssistant.sol:51`) — reverts
  `AssistantAccountMismatch`, has its own entry in `src/errors.sol` and a paragraph in the family README, and is
  called by nothing. Its own docstring explains why: all three shipped assistants force the receiver to
  `address(this)` in the forwarded call, so none has an argument to check. Provided for a future assistant.
- **`BridgeAdapter._transferTokensToEscrow`** (`src/bridge/BridgeAdapter.sol:173`) — explicitly documented
  "Legacy push-to-escrow helper, NOT on the shipped completion path… No shipped adapter (CCTP included) calls
  this."

**Not findings.** Recorded because a future wiring of either would be wiring an *untested* guard: neither has
coverage, so the first assistant to call `_requireSelf` inherits an unexercised check.

---

## Mutation results

### Baseline

`forge test --no-match-path "*fork*"` on the unmodified tree:

```
Ran 119 test suites: 1559 tests passed, 3 failed, 0 skipped (1562 total)
```

The three baseline failures — the reference set every mutation run is diffed against:

| Failing test | Cause |
|---|---|
| `test_priceFeedLib_pinMatchesCurrentBytecode` | Pin regen in flight (red by design). Local value `0xD477d7e2…` vs pinned `0x450421a3…`. |
| `test_navRegistryLib_pinMatchesCurrentBytecode` | Pin regen in flight (red by design). `0x7Fc30f7a…` vs `0x549f6fB0…`. |
| `setUp()` in `script/test/Test02_DeployProxies.t.sol:Test02a_DeployProxies` | `RpcUrlNotSet()` — needs an RPC locally. |

The brief predicted two failures; there are three. The third is environmental, not a defect: this suite's
`setUp()` needs an RPC URL that is present in CI (`*_URL` env) and absent here. **Consequence for scope: all 19
tests in `Test02a_DeployProxies` did not execute in any of my runs**, so nothing they cover was mutation-tested.
That is a real hole in this sweep and is listed under "not covered".

One thing settled early and worth recording, because it changes how finding 2.1 should be read:
**`script/test/*.t.sol` IS discovered and run by `forge test`** (verified with `--list`:
`UpgradeNAVCalculatorPinsTest`, `ConfigReaderTest`, `Test02a_DeployProxies` all appear). So the deploy-script
test directory is on the CI path already — a test for `01`/`01_2` needs no new infrastructure, only writing.
`script/test/README.md`'s "Continuous Integration" section, which presents a CI step that does not exist in
`.github/workflows/foundry.yml`, is misleading but harmless: the tests run anyway via the default test path.

### Batch B — deploy and upgrade path (script-only mutations)

Four mutations applied together; `1557 passed, 5 failed`. Delta vs baseline: **exactly two new failures, both
from M3.**

| # | Mutation | Expected | Result | Verdict |
|---|---|---|---|---|
| M1 | `revert("TRIP_01")` as the **first statement** of `DeployImplementations.run()` | — | no test failed; the string `TRIP_01` appears **0 times** in the output | **Unwired — finding 2.1** |
| M2 | `revert("TRIP_01_2")` as the first statement of `DeployNAVImplementation.run()` | — | no test failed; `TRIP_01_2` appears 0 times | **Unwired — finding 2.1** |
| M3 | **delete the call site** `_assertPinnedLibrariesUsable(...)` in `UpgradeNAVCalculator._deployGuardedNavImplementation:131` | red | `test_guardedDeploy_revertsWhenTheGuardRejects` and `test_guardedDeploy_succeedsOnlyWhenEverythingHolds` both fail with *"next call did not revert as expected"* | **SOUND** |
| M4 | blank the body of `BaseDeployScript._requireTolerancesPlannable` | — | no test failed | **No coverage — finding 2.2** |

**On M1/M2.** An unconditional `revert` at the top of `run()` is a strictly stronger probe than deleting the
guard: it fails the function before anything else can happen. Zero tests noticed, and the marker string never
appears anywhere in 1562 tests' output. Nothing reaches either script's `run()`, so the eight pin `require`s
inside them are unreachable from the test suite by any route.

**On M3 — PR #194's fix verified, and worth stating precisely.** Both failing tests use `vm.expectRevert()`.
On this tree the pins drift, so `test_guardedDeploy_succeedsOnlyWhenEverythingHolds` takes its `else` branch and
also expects a revert — which is why *both* fire rather than one. The wiring claim in that PR holds: deleting
the call, not just blanking the body, is caught.

### Batch C — `src` guard bodies (nine neutralisations, one run)

Each guard's condition was rewritten to `if (false && <original>)`, so the statement and the surrounding control
flow are otherwise untouched and only the guard becomes un-triggerable. Result: `1556 passed, 6 failed`. Delta
vs baseline: **three new failures, all from one mutation.**

| # | Guard | Site | Result | Verdict |
|---|---|---|---|---|
| M5 | grace-period arm of `checkSequencerUptime` | `PriceFeedLib.sol:460` | no failure | **Unreached — finding 2.3** |
| M6 | `assertNotZeroNumber(heartbeat)` | `ETHPlus_CustomPriceFeed.sol:55` | no failure | **Masked — finding 2.5** |
| M7 | `PriceFeedDecimalsMismatch` | `PriceFeedLib.sol:1510` (`addFeed`) | no failure | **Uncovered — 2.4** |
| M8 | `PriceFeedIndexOutOfBounds` | `PriceFeedLib.sol:1531` (`removeFeedAt`) | no failure | **Uncovered — 2.4** |
| M9 | `PriceFeedIndexOutOfBounds` | `PriceFeedLib.sol:1608` (`removeMonitorFeedAt`) | no failure | **Uncovered — 2.4** |
| M10 | `MonitorFeedDecimalsMismatch` | `PriceFeedLib.sol:1582` (`addMonitorFeed`) | no failure | **Uncovered — 2.4** |
| M11 | `MonitorFeedAlreadyRegistered` | `PriceFeedLib.sol:1587` (`addMonitorFeed`) | no failure | **Uncovered — 2.4** |
| M12 | `PriceFeedIndexOutOfBounds` | `Prices.sol:91` (`getPriceFeedAt`) | no failure | **Uncovered — 2.4** |
| M13 | `InvalidArgumentsWithContext` | `MetaBalanceAdapter.sol:455` (`_toAddress`) | **3 tests red** | **SOUND** |

**M13 is a correction to finding 2.4, and the reason this had to be mutation-tested rather than grepped.**
`InvalidArgumentsWithContext` appears nowhere in the test tree — not as a `.selector`, not textually — so my
static pre-filter listed it as uncovered. It is not. Three tests in
`test/balances/MetaBalanceAdapterEnumeration.t.sol` fail when the guard is neutralised:

```
[FAIL: the good instance survives the bad one: 2 != 1] test_positionIds_isolatesAMalformedCoordinate()
                                                       test_positionIds_isolationDoesNotTruncateLaterInstances()
                                                       test_positionIds_allCoordinatesBad_returnsEmptyWithoutReverting()
```

They assert the *behaviour* the guard produces — a malformed instance coordinate is isolated to its own slot and
does not truncate the rest of the enumeration — rather than naming the error. That is a better test than one
which pins the selector, and the name-based heuristic cannot see it. **Finding 2.4 is therefore 8 errors, not 9**,
and the general lesson is that "no test names this error" is a candidate generator, not a verdict.

Of the remaining eight, **six are confirmed by mutation** (M7–M12) and two are static-only (below). All eight sit
on the feed-registration path that `06_Configure` and `script/manage/RegisterAssets.s.sol` drive on every one of
the 24 chains.

**Two of the nine were not mutated**, and are carried on static evidence only: `MonitorFeedNotFound`
(`PriceFeedLib.sol:1633`) and `InvalidPriceOracleType` (`PriceFeedLib.sol:1663`) are terminal `revert`s at the
end of a fall-through, not conditional guards — neutralising them changes the enclosing function's contract
rather than just disabling a check. Their error names appear nowhere in the test tree, but after M13 that is
explicitly not proof. Treat them as unverified.

### Batch D — NAV read-path guard WIRING (call-site deletion)

Four call-site deletions, targeting the guards whose *wiring* — not whose body — carries the load. Result:
`1544 passed, 18 failed`. Delta vs baseline: **15 new failures. Every mutation in this batch was caught.**

| # | Call site deleted | Result | Verdict |
|---|---|---|---|
| D1 | `_validateAssetFilter(asset)` — **both** sites, `NAVCalculator.sol:416` and `:437` | 2 red | **SOUND** |
| D2 | read-time `ownerOf` re-verification in `EtherFiWithdrawalQueue…_owedForToken` | 5 red | **SOUND** |
| D3 | read-time `tokenInfo`/owner re-verification in `NexusMutualStakingPools…_valueCoord` | 4 red | **SOUND** |
| D4 | `_validateCoord(account, coord)` in `AssistedCoordCache._submitCoord:163` | 8 red across all three assisted adapters | **SOUND** |

**D1.** `test_getAccountPositionsForAsset_invalidAsset` and `test_getAccountPositionsForAssetVerbose_invalidAsset`
both fail with *"next call did not revert as expected"* — one per entry point. Worth noting because this pair was
a Shape-1 near-duplicate candidate (0.9707); the mutation proves the two are not redundant, since deleting the
guard on one entry point would leave the other's test green. That is the reciprocal of the Shape-1 method, and a
good argument for keeping both.

**D2/D3/D4 — the ADR 0015 family invariant is genuinely pinned.** This is the result I most expected to find a
hole in, and did not. The assisted family is the repo's one documented immutability exception, and its whole
safety argument is *"cache coordinates only, value live, re-verify ownership on every read → under-report only"*.
Both halves of that are load-bearing and both are wired:

- Deleting the read-time ownership check makes non-owned positions **reappear in the balance** —
  `test_transferredAway_dropped` and `test_burned_dropped_doesNotRevert` fail with
  `1000000000000000000 != 0`, i.e. a full ether of phantom balance, which is precisely the over-report the
  invariant forbids. `test_read_discardsTransferredId` fails `2 != 1`.
- Deleting the write-time `_validateCoord` call makes eight `test_submit_reverts*` tests stop reverting, across
  ether.fi, Nexus **and** StakeWise — the shared base's one call site is covered from all three concrete
  adapters, including `test_submit_reverifiesOwnershipOnResubmit`, which is the case the call site's own comment
  exists to protect ("re-validate on EVERY submit, before the dedup early-return").

StakeWise's read-time ownership check was **not** mutated: it is implicit in passing `account` to the vault's
`calculateExitedAssets(account, …)`, so there is no guard statement to delete without changing what is being
asked of the protocol. Its write-time path is covered by D4.



---

## Mutated and found SOUND — the other half of the sweep

A sweep is only meaningful if the negatives are recorded too. Seventeen guard sites were mutated and killed the
suite; these are load-bearing and correctly wired.

| Guard | Mutation | Tests that caught it |
|---|---|---|
| `UpgradeNAVCalculator._assertPinnedLibrariesUsable` | **call site deleted** (`:131`) | `test_guardedDeploy_revertsWhenTheGuardRejects`, `test_guardedDeploy_succeedsOnlyWhenEverythingHolds` |
| `MetaBalanceAdapter._toAddress` widening check | body neutralised | `test_positionIds_isolatesAMalformedCoordinate`, `…_isolationDoesNotTruncateLaterInstances`, `…_allCoordinatesBad_returnsEmptyWithoutReverting` |
| `NAVCalculator._validateAssetFilter` (2 sites) | **both call sites deleted** | `test_getAccountPositionsForAsset_invalidAsset`, `test_getAccountPositionsForAssetVerbose_invalidAsset` |
| ether.fi read-time ownership re-verification | **call site deleted** | `test_transferredAway_dropped`, `test_burned_dropped_doesNotRevert`, `test_read_discardsTransferredId`, `test_read_discardsRevertingId`, `test_submit_revertsOnNonOwnedId` |
| Nexus read-time ownership re-verification | **call site deleted** | `test_getAdapterPositions_nonOwnedCachedId_discarded_noLeg` + 3 |
| `AssistedCoordCache._validateCoord` call | **call site deleted** | 8 `test_submit_reverts*` across ether.fi, Nexus and StakeWise |

Also inspected and **not** mutated, with the reason:

- **`PriceFeedLib.validateAdapterSlice`** (`EmptyAdapterSlice`, `DuplicateAdapterInSlice`, `AdapterNotRegistered`)
  — its return value is consumed by `getAccountNavForAdapters`, so deleting the call does not compile. Wired by
  construction; the strongest form of wiring there is.
- **`MetaBalanceAdapter._positionsForInstances`** per-instance `InstanceGasExhausted` classifier — sits inside
  the fan-out loop with its result used immediately; same argument. `InstanceGasExhausted` is also named by tests.
- **`NAVCalculator._requireManager`** (24 sites), **`_requireAssetExists`** (12), **`_requirePriceFeedExists`**,
  **`_validateQuoteAsset`** (7) — not mutated for budget reasons. All four are named by tests and have dense
  `notAuthorized` / `invalidAsset` coverage. Recorded as *unverified-but-unsuspicious*, not as swept.
- **StakeWise read-time ownership** — implicit in the protocol call's `account` argument; no statement to delete.

---

## Restore verification

| Round | Files touched | Restored | Fingerprint |
|---|---|---|---|
| Batch B | 4 (`script/`) | `git checkout --` explicit list | 890/890 match |
| Batch C | 4 (`src/`) | `git checkout -- .` | 890/890 match |
| Batch D | 4 (`src/`) | `git checkout -- .` | 890/890 match |

Final state: `git status --porcelain --untracked-files=all` reports exactly one line, `?? AUDIT-mutation-sweep.md`.
`git diff` is empty. The sha256 manifest of all 890 tracked non-submodule files matches the pre-edit baseline
(`ef740fd40f2b119c1f2e301dd66db6c4e59667d0354c0ae738ecd14233010154`) byte for byte. Diffs were read in full
before each restore, not inferred from `git status`.

**Behavioural confirmation.** A fingerprint proves the bytes came back; it does not prove the build did. So the
suite was re-run on the restored tree as a final check:

```
Ran 119 test suites: 1559 tests passed, 3 failed, 0 skipped (1562 total)
  setUp()                                        <- Test02a_DeployProxies, RpcUrlNotSet
  test_navRegistryLib_pinMatchesCurrentBytecode  <- red by design
  test_priceFeedLib_pinMatchesCurrentBytecode    <- red by design
```

Identical to the baseline in count and in identity. No mutation leaked out of any round.

---

## Summary — ranked for the redeploy

| # | Finding | Shape | Confirmed by | Severity |
|---|---|---|---|---|
| 2.1 | `01_DeployImplementations` + `01_2_DeployNAVImplementation` pin guards are unreachable from the test suite | 2 | mutation | medium |
| 2.3 | Grace-period arm of `checkSequencerUptime` unreached; purpose-built mock constructed and abandoned | 2 | mutation | medium |
| 2.4 | 8 guard arms on the price-feed registration path asserted by nothing (6 by mutation, 2 static-only) | 2 | mutation + static | medium |
| 2.2 | `BaseDeployScript._requireTolerancesPlannable` has no test at all | 2 | mutation | medium |
| 2.5 | `ETHPlus_CustomPriceFeed` zero-heartbeat guard masked by the check above it | 2 | mutation | low (deployed nowhere) |
| 1.1–1.4 | Four duplicate test pairs; none is a coverage hole, all are misleading names | 1 | reading | low |
| 2.6 | Two documented-dead guards (`_requireSelf`, `_transferTokensToEscrow`) carry no coverage for whoever wires them next | — | static | informational |

**What I would fix before the redeploy, in order.** 2.1 and 2.2 are the two that touch what the redeploy
actually executes 24 times, and both are cheap: `script/test/` is already on the CI path, and the seam pattern
PR #194 built for `UpgradeNAVCalculator` transfers to `01`/`01_2` almost verbatim. 2.3 is a one-line test —
the mock already exists at `test/mocks/price_oracles.sol:149` and is already constructed at `SuperTest.sol:92`;
it just needs a test to use it, and `test_checkL2SequencerUptime_withinGracePeriod` should be renamed to what it
actually tests. 2.4 is the largest volume but the shallowest work.

**What this sweep should not be read as saying.** It did not cover `src/bridge/`, the fork suites, the 19 tests
in `Test02a_DeployProxies` (which never ran locally), or per-call-site wiring for the four high-fan-out
`NAVCalculator` guards. Shape 1 detection *was* exhaustive across the repo; Shape 2 mutation was not, and was
scoped to the NAV read path and the deploy path as instructed.
