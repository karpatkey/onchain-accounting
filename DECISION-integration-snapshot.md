# DECISION NEEDED — scoped integration-snapshot refresh for PR #199

**Status:** AUTHORISED by the user 2026-07-29. Execution blocked — see *Execution blocker* below.
**Written:** 2026-07-29, by the price-feed audit session, branch `audit/price-feed-leaf-sweep`.
**Why this file exists:** the reasoning below existed only in one session's context, and sessions have been
OOM-killed today. Committed so it survives that.

---

## The decision, in one glance

PR #199 deliberately changes how stETH is priced. That legitimately moves the recorded NAV for the two mainnet
accounts that hold stETH. CI "Integration tests" is red **for exactly that reason**.

**Authorise, or refuse, a scoped refresh of these two values in `test/integration/accounts.json`:**

| Account | `expected["1"].navUsd8dp` from | → to | Move |
|---|---|---|---|
| `ACCOUNT_2` | `79011141615569` | `79019130176381` | **+1.01 bps** |
| `ACCOUNT_9_MAINNET_DIVERSIFIED` | `1721677935275687` | `1721719028553325` | **+0.24 bps** |

Both are **mainnet (chainId 1)**. Both move **up**. Nothing changes on Arbitrum, Base, Gnosis or Optimism.
(The `debankUsd` companion fields would also be refreshed by the tool; the figures above are the on-chain NAVs.)

**The refresh has NOT been run.** Authorised, but the sanctioned tool cannot perform it at this scope — see
*Execution blocker*.

---

## Why the red is expected, not a defect

### 1. The commit that turned it red changes nothing but stETH's price *(this is the load-bearing argument)*

`b50218e2` touches two JSON files. Its only substantive edits:

```
-        "feed": "stETH",
+        "feed": "stETHFundamental",                              <- the primary swap
+      { "type": "Custom", "feed": "stETHCrossRate", ... }        <- a MONITOR
```

Monitor feeds **never price the NAV** — `src/prices/Prices.sol:37-39`: *"NEVER used to price the NAV; read only to
detect divergence."* So there is exactly **one** value-affecting change in the causing commit. No other mechanism
exists in that diff. This is exhaustive, not statistical.

### 2. Bisect isolates the boundary cleanly

| Commit | Integration |
|---|---|
| `main @ bc178b53` (merge base) | success |
| `main @ 5f35008a` | success |
| `7b6298de` — the guard alone | **success** |
| `b50218e2` — + stETH config | **failure** |
| `6d206707` — + merged main | failure |

### 3. Direction matches, measured from the actual feed

The Chainlink stETH/ETH feed returns `999715554206999400` at the pinned fork block — read out of the CI trace, not
assumed. That is `0.999715554207`, a **2.8445 bps discount**. The fundamental primary holds stETH/ETH at `1.0`, so
removing that discount must raise NAV. Both deltas are positive. ✓

### 4. Nine accounts did not move *(the falsification test)*

11 accounts were evaluated across 5 chains. **Exactly 2 mismatched — both mainnet, both stETH holders.** Nine
matched exactly.

The sharpest control is `ACCOUNT_10_MAINNET_LST_YIELD`: $69M NAV, explicitly LST-heavy, **unmoved**. It is built on
wstETH/weETH, whose feeds #199 does not touch; only *raw* stETH repriced. Any second cause from this branch — the
registration guard, the sDAI deletion, the `computeNav` stack refactor, or the merge of main — would very likely
have disturbed at least one of the nine. None did.

### 5. Implied exposures are plausible, not absurd

Derived from the measured 2.8445 bps gap:

| Account | Δ | Implied stETH holding | as % of NAV |
|---|---|---|---|
| `ACCOUNT_2` | $79.89 | $280,847 | 35.6% |
| `ACCOUNT_9_MAINNET_DIVERSIFIED` | $410.93 | $1,444,679 | 8.4% |

Both under 100%, both positive. 8.4% in a single LST is exactly what an account labelled `DIVERSIFIED` should
look like.

---

## The honest limit on this evidence

**Without RPC I could not independently measure either account's stETH balance.** So item 5 establishes that the
implied exposure is *plausible and internally consistent* — NOT that a predicted delta matched a measured holding.

An earlier attempt to do that quantitatively, using the DeBank cache under `test/integration/debank-cache/`,
produced figures that disagree with the table above ($558k and $679k). **Discount that attempt.** The cache is a
snapshot from a different time than the pinned fork block, and a naive walk double-counts stETH that appears both as
a token holding and inside protocol positions. It is not evidence either way.

The attribution rests on argument **1** — exhaustive, because the causing commit contains no other lever — supported
by **2**, **3** and **4**. It does not rest on the magnitude fit.

**What would falsify this:** any mismatched account that does not hold stETH, or a delta in the negative direction.
Neither is present.

---

## Process ruling — why the refresh was not run

The user deferred the integration-snapshot refresh **deliberately**, specifying both *when* (at the very end,
immediately before the redeploy) and *how it is validated* (by comparison against DeBank). That is a considered
ruling about process, not an oversight.

It also matters for evidence: **running the refresh makes the red disappear whether or not the cause is
legitimate.** It is the single action that destroys the ability to distinguish an expected reprice from a
regression hiding behind one. That is why it is left undone even though the analysis above is complete.

Use `script/test/refresh-integration-snapshot.sh`. Never hand-edit the expected values —
see `docs/howto/refresh-integration-test-blocks.md`.

---

## Execution blocker — the refresh CANNOT be scoped to these two values

Discovered when the scoped refresh was authorised. **`refresh-integration-snapshot.sh` is a full re-baseline, not a
targeted fix.** Its step 1 re-pins EVERY chain's `forkBlock` to `cast block-number` (latest), unconditionally:

```
line 141:  === 1. Bumping forkBlock for each chain (parallel) ===
line 153:  cast block-number --rpc-url "$rpc" > "$block_dir/$chain_id"
line 171:  jq_inplace ".chains.\"$chain_id\".forkBlock = $new_block"
```

Fork blocks that would all move: mainnet `25426915`, Optimism `153590310`, Gnosis `46953622`, Base `47995025`,
Arbitrum `478750897`. Step 2 then recomputes every account at those NEW blocks, so nearly all expected values move —
driven by market movement between the old pins and now, which dwarfs the $79.89 / $410.93 stETH deltas.

The script takes **no arguments**: no `--chain`, no `--account`, no way to skip the block bump. The only `case "$1"`
is an internal chain-id-to-contract mapping.

**Consequence:** running it produces a commit containing five new fork blocks and dozens of changed NAVs, in which the
two stETH deltas are unrecoverable. That is the opposite of the isolated, auditable commit the authorisation was
meant to produce — it buries the evidence this document exists to preserve.

Secondary blocker: the audit session had no RPC egress (no `.env`, no `ALCHEMY_API_KEY` or `*_URL`; three public
endpoints refused), so it could not have run regardless. The scoping problem is the load-bearing one — it means
running the tool would be wrong even with working RPC.

**Recommendation:** let the end-of-wave re-baseline absorb these two deltas, using this document as the record of
why they moved. If Integration must be green sooner, run the full refresh deliberately AS a re-baseline and do not
expect its commit to isolate the stETH change. Do not hand-edit the two values: `CLAUDE.md` forbids editing expected
NAVs directly, and it is that invariant which makes the snapshot trustworthy.

---

## Where PR #199 stands

Branch `audit/price-feed-leaf-sweep`, head `8b0806bd`. **Do not merge without the user.**

Green: Build (on a forced-clean run — #200 set `cache: false`), Fork tests, Format, Lockfile, CodeQL, all Analyze jobs.

Two expected reds:
- **`LibraryPinConsistency` (2 tests)** — red BY DESIGN on every branch until PR #185 lands the pin regeneration.
  Do NOT repin. Do NOT touch `foundry.toml` or `script/utils/LibraryPins.sol`. Current computed values:
  `PriceFeedLib 0x8b7e4fA91490ADe5D52F1755c9e1D91618cd7dc1`, `NAVRegistryLib 0x5f5D054E021A53E1DEF54B3Bda3c939ccD14fd90`.
- **`Integration tests`** — this document.

Local non-fork suite: 1616 passed, 10 failed (those same 2 pin + 8 RPC-gated).

#199 is one of three things gating the pin regen, and therefore the deploy. The other two are #201 and the
constructor-guard PR.

### One change in #199 recorded as UNATTRIBUTED

The `computeNav` stack refactor (`8b7f3d22`, extracting `_sumPositionValues`) was made to fix a CI
`Variable is 1 too deep in the stack` build failure. **It cannot be credited with the fix:** #200 removed CI's
sticky build cache in the same push, and a cold local build passed both *with and without* the refactor — so "the
fix worked" and "the cause was removed" are indistinguishable. It was kept on an asymmetry argument (reverting
returns `computeNav` to a state CI has rejected once, under conditions we cannot reconstruct), and it is proven
behaviour-neutral by `test/prices/PoC_ComputeNavEquivalence.t.sol`. Do not later read it as a proven fix.

---

## Not in scope, on the morning list

Feed-audit findings **#2, #3, #5, #6, #8, #9** remain unscoped — see `AUDIT-price-feeds.md`, committed alongside this file.
Recommended first: **#3 — 16 of 31 primary feed instances have no divergence or peg check at all**, so
`getPriceDivergence` returns a constant rather than a measurement and those assets can never appear in
`irregularPriceAssets`.
