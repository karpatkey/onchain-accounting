# PR #201 — session handoff state

Written mid-round-4 at ~98% context. Everything here that is not in the diff exists only in one
session's head; the code is safe at `11698f80` (committed and pushed), the *reasoning* is not.

**#201 is the SOLE remaining trigger for #185** (pin regen → 24-chain redeploy). #199 merged;
#203 and #207 ruled out. Nothing else is waiting.

---

## Current position

- Branch `fix/bug-class-sweep`, worktree `/home/sgzerbo/github-projects/onchain-accounting-sweep`
- Pushed HEAD: **`11698f80`**. Base: `bc178b53`. **`main` has since moved to `777728a8`** — MERGE IT
  before the next gate round; a gate on a stale base wastes the round.
- Working tree at time of writing: `test/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.t.sol`
  modified (two new tests, see "round 4 in flight"), `HANDOFF-pr201.md` + `AUDIT-bug-classes.md`
  untracked. `src/` is CLEAN — verified after a gate left a mutation behind (see WARNING below).
- Local suite at `11698f80`: **1662 passing, 2 failing** — the two `LibraryPinConsistency` tests,
  red BY DESIGN.

### WARNING learned the hard way
Vigilo died mid-run (`Not logged in`) and **left a source mutation in place** — it had deleted the
`size < 0x60` gate in `AaveUmbrellaBalanceAdapter` to test whether anything pinned it. Always
`git status --porcelain --untracked-files=all` and `git diff src/` after a gate dies. Debris also
appeared as `test/balances/ZZVerifyTmp.t.sol`, `test/poc/EzShapeGate.t.sol`, `test/poc/Round4Probe.t.sol`.
`test/poc/CRITICAL-bridge-escrow-fallback-spoof.t.sol` and `HIGH-cctp-domain-zero-*.t.sol` are
TRACKED from an earlier session — not debris, leave them.

---

## The argument for how #201 was reviewed

Four gate rounds. **Three of them found a defect inside the previous round's fix, each time of the
very class that fix was removing.** That sequence is the review record and is not reconstructible
from the diff.

### Round 0 — the original sweep (8 findings, one commit each)
| Commit | Finding | Class | Direction |
|---|---|---|---|
| `820a9c2c` | `ERC4626RedeemLib` fell back `previewRedeem`→`convertToAssets`; EIP-4626 §4.3 makes the latter ignore the fee, so the fallback could only report MORE | 3 | **over** |
| `ec9d58e3` | `AssistedCoordCache._collect` swallowed a starved coordinate | 3 | under |
| `8aceb0d4` | `FluidVaultLib.aggregate` absorbed its own OOG mid-loop | 3 | mixed |
| `5c871cbf` | `BalancerV3PoolLib.poolTokens` raw `abi.decode(…,(address))` | 1 | under |
| `aca3abf3` | Two more raw address decodes in `AaveUmbrella` | 1 | under |
| `239c92d9` | `_resolveBareReserve` re-read `asset()`, dropping a whole stake token | 4+3 | under |
| `3d65f02a` | `ezETH._rate` try/catch over nested dynamic arrays | 1 | under |
| `3de270e6` | Three test suites that asserted nothing (T1/T3/T4) | 5 | — |
| `1d9082a7` | O3 ruling recorded, comments only | — | — |

### Round 1 (`653536f8`) — 3 defects, all introduced by round 0's own fixes
- **`FluidVaultLib`**: round 0's unconditional `revert` escalated a one-NFT omission into dropping the
  vault's whole collateral+debt pair. Vigilo measured it: 1,000,001e6 USDC debt vs 2e18 wstETH
  collateral → **zero legs, no revert, no signal**. For a net-debt vault that RAISES NAV. My
  justification ("one revert yields both behaviours") confused the caller *classifying* correctly
  with the caller *behaving* correctly. Now classified in-library via `GasStipendLib.exhausted`.
- **`ERC4626RedeemLib` ×2**: my NatSpec asserted a single `uint256` cannot revert past the `catch` —
  FALSE for an empty reply (a high-level call expecting return data emits no `extcodesize` check).
  And in Umbrella that revert is not isolated, so it dropped *every* Umbrella leg. Separately it
  still swallowed a starved `previewRedeem`. Now a bounded raw staticcall with a PROPORTIONAL stipend.
- Copilot's selector claim (`mstore(0x00, selector)` right-aligns) was **FALSE** — `bytes4` is
  left-aligned; refuted by fork test and independently by Vigilo across 9 PoC'd properties. But
  chasing it exposed that `_rate()` had **no** non-fork coverage at all.

### Round 2 (`ed894bba`) — 5 defects, 4 mine
- **Vigilo F5, the worst**: `FluidVaultLib.aggregate` — logic on its THIRD revision, defective twice —
  had **zero test coverage**. Mutation-proved: reinstating round-0 behaviour left the whole suite
  green. My round-1 commit claimed "every new guard is mutation-verified"; that sentence only covered
  the ezETH guards. **Overclaim, caught by a gate.**
- ezETH `size >= 96` was below the canonical 160-byte minimum (3 head words + one length word per
  empty dynamic member). The 96–159 window accepted replies the decoder rejects.
- **Vigilo F4**: `_umbrellaCooldownSplit` still had the decode-past-catch shape *three lines away* in
  the same call chain. Pre-fix code measured reverting with `EvmError: Revert`.
- Umbrella `redeemValue` failure paths were untestable (mock's `previewRedeem` always succeeded).
- A starvation test docstring described round-0 behaviour while asserting round-1's.

### Round 3 (`11698f80`) — 1 PoC'd defect + 5 from a DEAD gate's discard pile
- **Vigilo F8 (PoC-validated)**: round 2's cooldown assembly read three full 256-bit words unmasked,
  then ran `cdEnd + cdWindow` through CHECKED arithmetic. `(1, 1, 2**256-1)` panics `Panic(0x11)`
  in-frame, past every catch. Same uncatchable-revert class the rewrite removed. Masked now:
  `shr(64, shl(64, …))` for the uint192, `and(…, 0xffffffff)` for the two uint32s.
- **THE WORKFLOW GATE LIED**: reported "No findings survived verification" with `candidates: 15,
  verified: 0, refuted: 0` and all 12 verifiers dead on a session limit. **Mechanical tell:
  `verified == 0 && refuted == 0 && candidates > 0` means nothing ran.** Recovered the 15 candidates
  from `journal.jsonl`; **four independent finders had converged** on F8.
- From that pile: Fluid allocated the 416-byte window *per loop iteration* (quadratic memory — the
  cost the bounded window existed to prevent, undone by where I put it); `COOLDOWN_PROBE_GAS`
  duplicated `StaticCallLib.PROBE_GAS` four lines below the comment explaining the deletion;
  `CoordinateGasExhausted` reported `keccak256(coord)` not `_coordId`; a dead ternary branch; stale
  `>= 96` NatSpec.

---

## Round 4 — IN FLIGHT, NOT DRY, BOTH GATES INCOMPLETE

- **Vigilo: FAILED** (`Not logged in`) after reporting a partial: *"Both arms confirmed unpinned."*
- **Workflow: INCOMPLETE** — 11 of 30 agents died on session limits INCLUDING `[synthesize]`; summary
  says "Synthesis step was skipped". It still returned verified findings.

### Round-4 findings so far
1. **Vigilo (partial, CONFIRMED by me)** — both arms of `if (!ok || size < 0x60)` in
   `_umbrellaCooldownSplit` are **UNPINNED**. My `MockEmptyCooldownStakeToken` test *reaches* the arm
   but does not *pin* it: a zero-length reply leaves the window zeroed, so `cdAmount == 0`
   short-circuits and deleting the gate yields an identical answer. **This is the "reaching an arm is
   not pinning it" lesson landing on my own code.**
2. **Workflow `FluidVaultLib.sol:200` (PLAUSIBLE)** — `vaultByNftId` sits INSIDE the loop I hardened
   but is an unbounded high-level call whose in-frame `address` decode bypasses the new
   starved/unreadable classification entirely. A dirty word reverts past the `size < 384` gate, past
   `GasStipendLib.exhausted`, past everything — dropping the ENTIRE vault instance
   (`sum(supply)` AND `sum(borrow)`). **For a net-debt vault that is an OVER-report** — the cardinal
   sin, and the very thing the two-way split 30 lines above exists to prevent. Also a stipend
   asymmetry: `positionByNftId` is bounded and classified; `vaultByNftId` one line up is neither.
   **This would be the FOURTH consecutive round finding the same class in the previous round's fix.**
3. **Workflow `BalancerV3PoolLib.sol:51` (PLAUSIBLE)** — my U3 change converted a dirty `asset()` word
   from an instance-dropping revert into a silently masked address returned as the pool's underlying.
   Under-report normally, but needs checking for a masked-address-collides-with-a-registered-asset case.

### IN-FLIGHT WORK (uncommitted, in the test file)
Two new tests added to pin the cooldown arms — `test_truncatedCooldownReply_isRejectedNotReadAsLive`
(new `MockTruncatedCooldownStakeToken`, returns 64 bytes with word0 = full stake amount and
word1 = `timestamp()` so `inWindow` is true with a zero window) and
`test_revertingCooldownRead_payloadIsNotReadAsCooldownData` (reuses `MockUmbrellaStakeToken` with
`cooldownAbiEnabled == false`, whose `Error(string)` payload is 100 bytes ≥ 0x60, so the size gate
does NOT catch it and `!ok` is the only thing that does).

**STATUS: BOTH MUTATIONS STILL PASS — the tests do NOT yet pin the arms.** Mutation A (drop
`size < 0x60`) → 20 passed. Mutation B (drop `!ok`) → 20 passed. Either the `sed` mutation did not
apply to the reformatted line, or the fixtures still do not differ on the arms beneath. **Do not
claim these arms are pinned until a mutation actually goes red.** Re-derive from scratch; check the
exact source line text after `forge fmt` before trusting a `sed`-based mutation.

---

## What I would do next

1. Restore/verify `src/` is clean; re-run the two mutations verifying the `sed` actually applied.
2. Make the two cooldown-arm tests genuinely mutation-sensitive, or delete them rather than ship
   tests that look like coverage and are not — that is the exact defect class this PR sweeps for.
3. Fix `FluidVaultLib:200` (`vaultByNftId`) — likely the real round-4 defect, and it is an
   **over-report**, so it outranks everything else here.
4. Assess `BalancerV3PoolLib:51`.
5. Merge `main` (`777728a8`), `forge clean` + full local suite, push.
6. Round 5 — round 4 was not dry and both gates were incomplete.
7. Only when a round returns **nothing new**: `gh pr merge 201 --merge --admin`, then report the new
   base SHA immediately (a waiting session has been told to disbelieve any such claim not relayed by
   the operator).

---

## Out-of-scope list handed to every gate

- The two `LibraryPinConsistency` failures — **red BY DESIGN** until #185 lands its regen. **NEVER
  repin**; `foundry.toml` and `script/utils/LibraryPins.sol` must not be touched.
- Asset-filter / per-asset-view projection semantics — ruled intended, documented in **merged #205**.
- O2/U2/U7 — `UniswapV2PairLib.kLast`; `AaveV3SafetyModule.stakersCooldowns` decode;
  `CompoundV3CometLib._rewardConfig` decode — hypothetical-only (signature present, trigger absent).
- The seven vacuous tests in `CurveMeta.fork.t.sol` — another session's.
- `AssistedCoordCache._collect`'s shrinking per-iteration stipend — accepted round 1; matches the
  merged `MetaBalanceAdapter` pattern and `GasStipendLib` documents that direction as deliberately cheap.
- `BalancerV3PoolLib`'s two-evaluation divergence — accepted, recorded in NatSpec (fixed cap +
  monotonically decreasing gas ⇒ later probe only more starved ⇒ under-report). Re-raise only with a
  reachable OVER-reporting inverse.
- The four remaining unhardened high-level Umbrella reads (`balanceOf`, `convertToAssets`,
  `getAllAssets`, `calculateCurrentUserRewards`) — skipped round 3: no `catch`, so no false guarantee;
  pre-existing; consistent with the documented trust model.

**Files held by other sessions** (callable, not editable): `StaticCallLib.sol`, `GasStipendLib.sol`,
`MetaBalanceAdapter.sol`, `NAVCalculator.sol`, `INAVCalculator.sol`, `PriceFeedLib.sol`,
`IPrices.sol`, `EulerVaultsMetaBalanceAdapter.sol`.

---

## Gate hygiene (all observed failing today)

1. **Empty diff** — a gate resolved git context to the main clone (92 commits behind) and would have
   reported clean about nothing. Always confirm a non-empty diff of the right head first.
2. **Dead verifiers reporting clean** — check `verified`/`refuted` against `candidates`. Both zero
   with candidates > 0 = nothing ran. Recover candidates from `journal.jsonl`.
3. **Mid-run death leaving mutations in `src/`** — see WARNING above.
4. **A shrinking finding count is not convergence.** Another PR is at round eight because each round
   probed a frame the earlier ones had not.
5. **"A test reaches this arm" ≠ "this arm is pinned."** Only a fixture that answers *differently* on
   the arms beneath pins anything.

## Pin story (do not act on)
`NAVRegistryLib = 0x5f5D054E021A53E1DEF54B3Bda3c939ccD14fd90` — stable everywhere, my commits do not
move it. `PriceFeedLib` produced both `0xD477d7e2…` and `0x00a3AFAC…` across readings; #199's owner
retracted every figure from `forge test --match-path` because it compiles a NARROWER unit than CI's
`forge build`. Leading explanation is compilation **scope**, not my changes and not nondeterminism.
**#185 owns the regeneration.** Do not repin.
