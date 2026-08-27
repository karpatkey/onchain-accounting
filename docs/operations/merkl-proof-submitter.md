# Merkl proof-submitter bot — operator's guide

> **Status (2026-07):** the Merkl adapter is being **re-added as `MerklRewardsAttestedBalanceAdapter`** — its own **`attested`** balance-adapter family ([ADR 0022](../decisions/0022-attested-balance-adapter-family.md)), NOT the assisted family. It is **permissionless** and **proof-verified** (no roles), and submit is **upsert** semantics; any `ASSISTANT_ROLE` framing below is historical and does not apply. This runbook applies once the adapter is deployed and its per-chain address is wired.

The `MerklRewardsAttestedBalanceAdapter` adapter (`src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol`) reports a portfolio's *unclaimed* Merkl rewards by reading an on-chain cache of `(user, token, cumulativeAmount)` tuples. The cache is populated by an off-chain bot that fetches merkle proofs from the Merkl API and submits them to the adapter, where they're verified against the live `Distributor.getMerkleRoot()` before being stored. The adapter cannot fabricate amounts; the bot cannot fabricate amounts; only Merkl's published merkle tree determines the per-token **amounts** the adapter reports. It does **not** determine the *campaign attribution* of those amounts — the proof binds the per-token cumulative, and the contract checks only that the campaign shares sum to it, so campaign identity is submitter-controlled. See "Why this is trust-minimized" below. See [`docs/decisions/0007-merkl-trust-minimized-cache.md`](../decisions/0007-merkl-trust-minimized-cache.md) for the design rationale and trust model.

> **Access control: none — permissionless.** `submitProofs` / `submitProofsBatch` / `clearAllocation` take no roles; any address can call them, and every write is verified against the live `Distributor.getMerkleRoot()` — so **proof-verification, not a role, is the integrity guarantee** (no caller can fabricate amounts). The submitter is therefore just a **funded keeper EOA** (this bot): it needs gas and nothing else — no Safe module, no role grant, no ownership wiring. See ADR 0007's 2026-07 permissionless amendment. Where this guide says "owner"/"owner key" below, read it as the keeper EOA.

This document specifies what the bot must do, how often, with what inputs and what failure modes. It does **not** specify the language, framework, or deployment topology — those are operator choices. The bot lives outside this repo; this file is the contract between the on-chain adapter and whatever ops process keeps it fed.

---

## Responsibilities

Exactly three things, every cycle — garbage collection is one of them, not an afterthought:

1. **For each (account, chain) pair the operator wants tracked**, fetch the current set of `(token, cumulativeAmount, proof, breakdowns)` allocations from Merkl's API.
2. **Submit each account's allocations to the deployed `MerklRewardsAttestedBalanceAdapter` on that chain** via `submitProofs` (or the multi-account `submitProofsBatch`), signed by the keeper EOA (no on-chain role required). Submission is **upsert** semantics: each `submitProofs(user, allocs)` call adds or refreshes the `(user, token)` entries it carries and **never drops** a token it omits (a token that leaves the tree goes stale → reads 0, and is GC'd via `clearAllocation`). The bot submits the account's full current allocation set every cycle; a partial submit is also safe (it can only add/refresh, never suppress).

3. **Garbage-collect dead slots on the same cadence, BEFORE submitting** — `clearAllocation(user, token)` for every cached token that reads 0. It is stale-gated, so it can never suppress real value. Run it unconditionally, including for accounts whose allocations have not changed: those are precisely the accounts whose dead slots accumulate. See the reference loop below, step 2.

(There is no ownership transfer — the adapter has no owner.)

**GC belongs in the steady-state loop, and this used to say the opposite.** Under upsert semantics `_userTokens` accumulates every token ever proven for an account: a token that leaves the tree goes stale and reads 0, but it keeps occupying its slot until `clearAllocation` frees it. Only that call frees one. So an account farming Merkl across many root rotations drifts toward `MAX_TOKENS_PER_USER` (**64** — lowered from 256 to bound read gas, so the drift is four times tighter than before), and at the cap a submit carrying any NEW token reverts `TooManyTokens`. Because a submit is **atomic over its whole list**, that failure also rolls back the refresh of every other token in the same call. After the next root rotation all 64 cached entries are stale, every one reads 0, and the account's entire Merkl contribution disappears from NAV until someone clears slots by hand.

Run a GC pass on the same cadence as the submit loop: for each tracked account, `clearAllocation(user, token)` every cached token whose entry reads 0. It is stale-gated, so a call against a still-live entry reverts `AllocationStillLive` and cannot suppress real value — an aggressive GC pass is safe by construction.

## Inputs

The bot needs four pieces of operator-provided configuration:

| Input | Source | Notes |
|---|---|---|
| **Account list** | Operator config | One or more EVM addresses to track. Typically the OIV's per-chain accounts. |
| **Chain list** | Operator config | Subset of {1, 10, 100, 8453, 42161}. Merkl supports more chains; only those the OIV deploys to matter. |
| **Adapter address per chain** | `script/config/deployments/<id>.json` → `balanceAdapters.MerklRewards` | Read at startup; refresh on redeploy. |
| **Keeper EOA** | Operator secret store | The EOA that signs `submitProofs`. **No on-chain role** — the adapter is permissionless, so any funded EOA works; keep it topped up with gas on each chain. A plain hot EOA is acceptable here precisely because the key has no privilege beyond paying gas to submit proof-verified data: it cannot fabricate amounts, move funds, or suppress live entries (`clearAllocation` is stale-gated). |

The Distributor address and proof-verification rules are pinned in the adapter; the bot does not need to know about them.

## Steady-state loop

Per chain, per account, on a cadence of **roughly every 4 hours** (Merkl rotates roots every ~8h, with a 1–2h dispute window — sub-cycle frequency keeps the cache fresh):

```text
for chain in chains:
    adapter = adapter_for(chain)
    for account in accounts:
        # 1. Fetch from Merkl API
        rewards = GET https://api.merkl.xyz/v4/users/{account}/rewards?chainId={chain}
        # response shape, per `rewards[]`:
        #   { token: { address, decimals, symbol },
        #     amount: "<cumulative wei as string>",
        #     claimed: "<wei as string>",
        #     proofs: ["0xhex32", ...],
        #     breakdowns: [{ campaignId, subCampaignId, amount }, ...] }

        # 2. GC FIRST, every cycle, before anything else. This is NOT optional and it is
        #    NOT conditional on the account having changed — an account whose allocations
        #    are unchanged is exactly the account whose dead slots accumulate. Freeing a
        #    slot is what keeps step 4 from hitting TooManyTokens. clearAllocation is
        #    stale-gated, so a call against a still-live entry reverts AllocationStillLive
        #    and can never suppress real value: an aggressive pass is safe by construction.
        for token in adapter.userTokens(account):        # cached set, not the API's set
            if adapter.getAdapterBalanceForAsset(account, token)[0] == 0:
                try_call(adapter.clearAllocation, account, token)   # ignore AllocationStillLive

        # 3. Build the account's COMPLETE allocation list (upsert semantics — submit
        #    every currently-allocated token, not a delta). Keep only entries with a
        #    positive UNCLAIMED amount (amount > claimed) — a fully-claimed token reads 0,
        #    so submitting it burns one of the 64 slots on an entry the GC pass above
        #    would immediately clear again. Omitting a token does NOT drop it (upsert never
        #    suppresses); a token that leaves the tree goes stale → reads 0, and is GC'd.
        allocs = [
            Allocation(
                token    = r.token.address,
                amount   = int(r.amount),            # per-token cumulative; proof-verified
                proof    = r.proofs,
                # Optional. If non-empty the shares MUST sum to `amount`, so DO NOT truncate
                # an over-long breakdown — a truncated list no longer sums and reverts
                # CampaignSumMismatch. Above MAX_CAMPAIGNS_PER_TOKEN (8) the only correct
                # fallback is to drop the breakdown entirely and submit ONE untagged leg
                # carrying the whole amount; the token total stays exact either way, and
                # campaign attribution is display-grade regardless (see below).
                campaigns = (
                    [CampaignShare(b.campaignId, b.subCampaignId, int(b.amount))
                     for b in r.breakdowns]
                    if 0 < len(r.breakdowns) <= MAX_CAMPAIGNS_PER_TOKEN else []
                ),
            )
            for r in rewards
            if int(r.amount) > int(r.claimed)        # unclaimed > 0, NOT cumulative > 0
        ]

        # 4. Skip the submission entirely if nothing changed since the cache was last
        #    written against the current root (see below). NOTE this skip is amount+root
        #    only — see the campaign-attribution caveat under "Deciding whether to submit".
        if not changed(adapter, account, allocs): continue

        # 5. Submit the full list (one account) or batch across accounts.
        adapter.submitProofs(account, allocs)
        # or, across many accounts: adapter.submitProofsBatch(users[], allocs[][])
```

`Allocation` is `(address token, uint256 cumulativeAmount, bytes32[] proof, CampaignShare[] campaigns)` and `CampaignShare` is `(bytes32 campaignId, bytes32 subCampaignId, uint256 cumulativeAmount)`. The `campaigns` breakdown is optional: leave it empty for one untagged position per token, or supply it to split the token into per-campaign positions — if non-empty, the shares **must** sum to the token's `cumulativeAmount`, or the call reverts with `CampaignSumMismatch`. No more than `MAX_CAMPAIGNS_PER_TOKEN` (8) shares per token, or it reverts with `TooManyCampaigns`.

To decide whether a submission is worth the gas, read the current cache via `adapter.allocations(account, token)` — which returns `(uint256 cumulativeAmount, bytes32 root, uint64 submittedAt)` — for each token in the list. If, for every token, the API's `amount` equals the cache's `cumulativeAmount` *and* the cache's `root` equals `adapter.DISTRIBUTOR().getMerkleRoot()`, the cache is already current and the submission can be skipped. (Because submit is **upsert**, each `(user, token)` entry is refreshed in place, so the `AmountRegression` guard is meaningful **across** submits — a proven cumulative below the cached one reverts; Merkl cumulative is monotonic per root, so a legitimate decrease only follows a root rotation, which makes the entry stale → 0 → clearable before a fresh submit.)

## Why this is trust-minimized

Three properties hold by construction; the bot does not need to be trusted to maintain any of them:

1. **The bot cannot inflate amounts.** For each entry, `submitProofs` recomputes `keccak256(abi.encode(user, token, cumulativeAmount))`, runs Merkl's exact sorted-pair proof verification against `Distributor.getMerkleRoot()`, and reverts if the proof does not match. Submitting a fabricated amount fails on-chain. A per-campaign `breakdowns[]` split is not individually proof-backed, but the contract requires the shares to sum to the proof-verified per-token total — so the bot can mis-split value across campaigns but can never inflate the token total.
2. **The bot cannot suppress amounts past Merkl's own cycle.** If the bot stops running, the cache becomes stale on the next root rotation (~8h) and the adapter reports 0 for every cached entry. NAV under-counts; it never over-counts. Recovery is "start the bot again; cache reads correctly within one cycle."
3. **Anyone can audit.** Given the on-chain root, the adapter's cached `(cumulativeAmount, root)`, and `Distributor.claimed(account, token).amount`, anyone can verify the reported balance is exactly `cumulativeAmount - claimed` and verify the cached `cumulativeAmount` against the published merkle tree.

The bot's only privileged capability is *availability* — keeping the cache fresh. It cannot deceive a reader about the **amount**. It *can* mis-attribute that amount across campaigns (see property 1), and so can any third party holding the account's public proof — campaign attribution is **display-grade, not audit-grade**. The per-token total, i.e. the sum of a token's legs, is the proof-backed figure.

## Cadence and root rotation

Merkl rotates the merkle root approximately every 8 hours, gated by a 1–2 hour dispute window. During the dispute window, `Distributor.getMerkleRoot()` returns `lastTree.merkleRoot` (the previous root). The adapter handles this transparently — proofs verifying against `lastTree.merkleRoot` are fine while the dispute window is open.

Operationally:

- **4-hour cadence is a good default.** Sub-cycle frequency tolerates one missed run without going stale.
- **Don't rely on hour-aligned scheduling.** Merkl's rotation isn't strictly periodic. If the bot's run aligns badly with a rotation, the next run picks up the new root.
- **Avoid running multiple submitters in parallel** for the same `(adapter, account)`. They will race; because each submit **upserts** the `(user, token)` entries it carries, the later submission simply refreshes what the earlier one wrote (it does not replace the account's set, and neither run can drop a token the other submitted), so in steady state it is wasted gas. Use a per-chain mutex / leader election if HA matters.

## Dry-run / preview (read-only)

The adapter exposes a read-only preview the operator (or a portal/frontend) can use to **validate proofs before
submitting**, or to show an account's live unclaimed rewards without waiting for the next submit cycle:
`previewPositions(address account, bytes data)` — the family interface read, where Merkl's `data` is
`abi.encode(Allocation[])` (the same allocations a submit would take). It verifies every proof against the live
Distributor root and returns the positions as a `view` — no gas, no state change, no cache write. A proof that fails
verification reverts the preview the same way `submitProofs` would, so it is a safe pre-flight for **proof and
campaign-shape validity**. It is not full submit-equivalence: the preview omits the cache-only monotonicity check
(`AmountRegression`) and rejects duplicate tokens / a zero account, so a passing preview does not guarantee the submit
transaction succeeds. It is a convenience only: it does not feed the cache, so NAV coverage still requires the
steady-state submit loop below.

## Submission model

The adapter is **permissionless**: `submitProofs(user, allocs)` / `submitProofsBatch` are callable by anyone, so the bot simply signs and sends from a funded keeper EOA — no Safe module, no role grant, no ownership wiring. A plain hot EOA is acceptable because proof-verification bounds what any caller can do: it can only cache a user's *real*, Merkl-attested per-token **amount** — it cannot fabricate or inflate that amount, and `clearAllocation` is stale-gated so it cannot suppress an already-admitted live entry. (Two things it *can* do: fabricate the campaign split of a real amount, and — see the `TooManyTokens` row under Failure modes — occupy cache slots. Neither inflates NAV.) Keep the EOA funded with gas on each chain and rotate it with ordinary hot-key hygiene; there are no on-chain permissions to manage.

## Failure modes and what to do

| Symptom | Likely cause | Action |
|---|---|---|
| `submitProofs` reverts with `InvalidProof` | API returned a proof for a root that hasn't reached this chain yet, or returned a proof for `lastTree` after the dispute window closed | Re-fetch from API and retry once. If still failing, log and skip — the next cycle will recover. |
| `submitProofs` reverts with `UninitializedRoot` | Distributor's `tree.merkleRoot` is 0 (e.g., on a chain where Merkl is freshly deployed) | Disable the bot for that chain until Merkl publishes a root. |
| `submitProofs` reverts with `AmountRegression` | A proven cumulative for a `(user, token)` is **below** the value already cached (checked across submits, since submit is upsert — not just within one list). Merkl cumulative is monotonic per root, so this suggests a stale proof, an API bug, or a campaign restructuring after a root rotation. | Re-fetch and retry once. If the amount genuinely dropped (root rotation / restructuring), the cached entry will be stale and read 0 — GC it with `clearAllocation`, then resubmit the fresh proof. `submitProofs` is upsert (refreshes in place, does **not** clear-first), so a legitimate decrease requires that stale-gated clear first. Page an operator if it persists. |
| `submitProofs` reverts with `CampaignSumMismatch` | The per-campaign `breakdowns[]` shares for a token don't sum to that token's `cumulativeAmount` | Re-fetch and recompute the breakdown; submit an empty `campaigns` list (one untagged position) if the API's breakdown can't be reconciled. |
| `submitProofs` reverts with `TooManyCampaigns` | The token's `breakdowns[]` from the API has more than `MAX_CAMPAIGNS_PER_TOKEN` (8) entries — routine for a token earning from many concurrent campaigns | Re-submit that token with an **empty** `campaigns` list (one untagged leg carrying the whole amount). **Do NOT truncate the breakdown** — a truncated list no longer sums to the proven total and reverts `CampaignSumMismatch` instead. **The whole call rolled back**, so no other token in the same list was refreshed either |
| `submitProofs` reverts with `TooManyTokens` | The account is at `MAX_TOKENS_PER_USER` (64) and the submit carries a token not already cached. **Two distinct causes — diagnose before acting.** (a) *Neglect*: dead slots accumulated because the GC pass has not been keeping up. (b) *Squatting*: a third party used the account's public Merkl proofs to fill slots with genuinely-earned but low/zero-value tokens. Those entries are **live**, so they are un-clearable by anyone — including the operator | First run the GC pass and re-submit; that resolves cause (a). If GC reverts `AllocationStillLive` on **every** cached token, it is cause (b) and **there is no clean remedy at the current root** — a live entry cannot be evicted by design. The slots free only at the next root rotation, when the squatted entries go stale; land an atomic multisend `[clearAllocation ×N, submitProofs]` in that window before they can be re-filled. **The whole call rolled back**, so the account's other tokens were NOT refreshed either; do not assume a partial success. **This is an open design call — see "Known gaps" below.** |
| `clearAllocation` reverts `AllocationStillLive` | Tried to GC a `(user, token)` that still contributes to NAV (cached root matches live root AND unclaimed > 0) | Normally expected/by-design — a live entry can't be cleared, only *refreshed* via `submitProofs` (upsert). Only GC entries that already read 0 (stale root or fully claimed). `NothingToClear` similarly means nothing was cached. **But do not read this as benign when it fires on EVERY token of an account that is also throwing `TooManyTokens`** — that combination is the squat signature in the row above, not a healthy cache, and the two rows together are the diagnosis. |
| Cache reads as 0 even though API shows non-zero `amount` | Cached `root` does not match current `Distributor.getMerkleRoot()`. Bot has not yet run since the last root rotation. | Wait for next bot cycle. If persistent, the bot is stopped — investigate. |
| Adapter not in NAV | Either `enabled: false` in chain config or `addBalanceAdapters` wasn't called | Check `NAVCalculator.isAdapterRegistered(adapter)`; if false, register via Safe. |

## Known gaps — OPEN DESIGN CALLS, not settled behaviour

Four properties of this design were surfaced by review, confirmed against the code, and **deliberately left
unpatched pending the user's decision**. They are documented here so an operator meets them in the runbook rather
than in production. None can inflate NAV — all are under-report or attribution-only.

**Gap 1 — cache-slot squatting is possible and un-evictable at the current root.** Merkl proofs are public (the
API is keyed on address). Any third party can therefore call `submitProofs(account, …)` with the account's own
genuinely-earned but low- or zero-value tokens and occupy `MAX_TOKENS_PER_USER` (64) slots. Every such entry is
proof-valid, so it is *live*, so `clearAllocation` reverts `AllocationStillLive` on it — **no caller, including the
operator, can free the slot** until the next root rotation makes it stale. The valuable token can then not be
admitted, and because a submit is atomic over its whole list, the failure also blocks the refresh of every other
token in the same call. Options on the table: skip-over-cap instead of reverting; evict the lowest-`submittedAt`
entry to admit a new one; or feed per-token rather than batched (removes the amplifier, not the squat, and needs no
contract change). **Awaiting the user — this changes a balance adapter's admission semantics.**

**Gap 2 — the "already current" skip cannot see a fabricated campaign split.** The `changed()` predicate below
compares the API amount against the cached `cumulativeAmount` and the cached root against the live root. A third
party who re-submits the account's real proof under fabricated `campaignId`s **preserves both** — they are the only
two things the merkle proof binds. So `changed()` reports "already current" forever and the keeper never
resubmits. ADR 0022 records that such a fabrication is "repairable by one upsert, callable by anyone"; that repair
is real but **this keeper will never perform it**. Including `campaignsOf(account, token)` in the comparison would
close it, at the cost of letting a griefer force a resubmit — and therefore keeper gas — at will. **Awaiting the
user — this trades attribution correctness against a running operational bill.**

**Gap 3 — stale-root GC during a Merkl dispute-revoke can drop a reactivating entry.** Merkl's root is
non-monotonic: `getMerkleRoot()` serves `lastTree.merkleRoot` during the dispute window and `revokeTree()` reverts a
disputed tree, so the live root can go `R2 → R3 → R2`. While R3 is live, a cached R2 entry is stale and reads 0, so
`clearAllocation` — and the routine per-cycle GC pass below — can delete it. If the root then reverts to R2, that
entry would have re-activated at exactly the figure R2 attests (pinned by
`test_rootOscillation_revokeBackReactivatesAtAttestedFigure`), but it is gone and reads 0 until a resubmit.
**Under-report only and self-healing** — one permissionless resubmit (the next keeper cycle) restores it. It cannot
be closed on-chain: the contract has no signal for whether R3 is final or about to be revoked (Merkl decides
off-chain, over time), and *delaying* stale-root GC to protect this case would reintroduce Gap 1's cap-fill outage —
the two pull in opposite directions. Operational mitigation, no contract change: the keeper can skip the GC pass
during a known Merkl dispute window, or simply rely on the self-heal. **Accepted tradeoff.**

**Gap 4 — per-token gas isolation does not cover the read's own prologue, so a large cache can make the whole
account's `getAccountNav` revert.** `buildPositionsSelf` resolves `getRegisteredAsset` for every cached token, sums
the leg `cap`, and allocates a `cap`-sized scratch buffer **before** the first `try … {gas: stipend}` frame. That
prologue is therefore outside every per-token guard, and `getAdapterPositions` does not wrap the
`this.buildPositionsSelf` self-call. If the stipend `PriceFeedLib` forwarded is consumed there, the out-of-gas
bubbles, `GasStipendLib.exhausted` classifies it, and `AdapterGasExhausted` takes down the account's **entire** NAV
read — every adapter's legs, not just Merkl's. Because a third party can inflate a real token's leg count using the
account's public proofs (campaign ids are not proof-bound), the gas floor of a tracked account's NAV read is
partly third-party-controlled. Two smaller variants sit alongside it: the per-token stipend divides by tokens
remaining rather than **legs** remaining, so an 8-campaign token early in the list can be starved and dropped while
most of the budget goes unspent; and when `gasleft()` is at or below `reserve` every stipend is 0, so all tokens
drop and the read returns an empty array successfully. *(That last one changes nothing a caller can observe — a
revert here makes `PriceFeedLib` fail open to the same empty result — so it is a budget-sizing and monitoring
concern, not a correctness one.)*

Direction is availability and under-report, never over-report, and none of it is reachable while the adapter ships
`enabled: false`. **Before enablement, size the read budget with a measurement rather than an argument:** an
end-to-end test that registers the adapter on a production-scale asset registry, seeds a worst-case cache
(`MAX_TOKENS_PER_USER × MAX_CAMPAIGNS_PER_TOKEN` = 512 legs, griefer-shaped), and calls `getAccountNav` through the
real `PriceFeedLib` path — pinning the budget at which it succeeds and asserting that below it the failure surfaces
as `AdapterGasExhausted` rather than a silent zero. No test in the tree currently drives this adapter through
`PriceFeedLib` at all; the isolation tests all call `getAdapterPositions` directly, so the classification behaviour
is inferred from the sibling family rather than measured here.

## Before flipping `enabled: true` — tripwires that fire on the config change, not on deploy

Both are inert while the adapter is disabled and both turn a "one-line config change" PR red:

- **Integration-harness dispatch.** `IntegrationFromConfigBase._deployBalanceAdapter` has no `MerklRewards` branch
  and `test/integration/undispatched-adapters.json` has no declaration for it, so `UndispatchedAdapterGuard` will
  revert `UndispatchedAdapterNotDeclared` the moment the key is enabled — taking the chain's integration fork tests
  and `refresh-integration-snapshot.sh` step 2 with it. Add the dispatch branch (preferred) or the declaration.
- **Position-labels probe coverage.** `PositionLabelsProbeCoverage._expectedNonMetaAdapters()` does not list
  `MerklRewards`, and its config-time arm skips entries with `enabled: false` — so the guard fires at neither
  config time nor deploy time today. Decide what `positionLabels("")` must answer for this adapter and pin it.
- **NAV implementation vintage.** The adapter's constructor now probes for `getRegisteredAsset(address)` and
  refuses to deploy against a NAVCalculator that cannot serve it, so a stale implementation fails loudly at deploy
  rather than silently reporting zero legs forever. The probe binds the deploy, **not** the lifetime: a later UUPS
  downgrade of the NAV implementation would not be caught.

## Operator-side bookkeeping

Periodically (weekly is fine):

- **Prune fully-claimed entries — covered by the steady-state GC pass, not a separate weekly job.** The per-cycle pass under Responsibilities already clears every cached token that reads 0, which includes fully-claimed ones (`cached.cumulativeAmount <= Distributor.claimed(account, token).amount`). Listed here only so the audit is complete; do **not** schedule it weekly instead, because at a weekly cadence stale entries can reach `MAX_TOKENS_PER_USER` (64) between runs and block every refresh.
- **Audit cache vs. API.** Run a one-shot job that compares the adapter's cache to the Merkl API for every tracked account. Flag drift > 1 cycle as a potential bot stall.
- **Verify root proofs end-to-end.** Independently fetch Merkl's IPFS-hosted tree (`Distributor.tree().ipfsHash`), reconstruct leaves locally, and confirm the cached values match. This is the "anyone can audit" property exercised internally.

## Double-counting analysis

A reasonable concern when adding a new balance source: does the Merkl adapter's reported amount overlap with anything the existing wallet/protocol adapters already report? The answer is **no — by construction — across all four reward shapes Merkl actually distributes to Karpatkey-tracked accounts**. The argument is the same in each case but it's worth walking through because the reward shapes differ.

The invariant that makes this work: pre-claim, the reward sits at the Distributor (off the user's balance sheet — only the Merkl adapter sees it via the cached proof). Post-claim, `claimed[user][token].amount` advances to match `cumulativeAmount` and the Merkl adapter reads zero, while the reward token has now arrived in the user's wallet (or onward staking position) and is picked up by whichever adapter covers that asset. The transition is exact: `cum - claimed = 0` precisely when the tokens are received.

| Reward shape | Pre-claim | Post-claim | Double count? |
|---|---|---|---|
| **Raw ERC20** (MORPHO, ARB, RPL, GEAR, …) | Merkl: `cum - claimed`. Wallet: 0. | Merkl: 0. Wallet: balance picked up by `ERC20DefaultBalanceAdapter`. | **No** — Merkl pays, wallet receives. |
| **stkGHO** (Aave SM stake token) | Merkl: `cum - claimed` of stkGHO. SM adapter: `previewRedeem(IStakeToken(stkGHO).balanceOf(user))` (reports the redeemable GHO underlying, not stkGHO itself) — does **not** include the unclaimed Merkl bag at the Distributor. | Merkl: 0. SM adapter: `balanceOf` now reflects the claimed stkGHO. | **No** — `balanceOf` is wallet-resident; Merkl tokens arrive there only after `claim`. |
| **aTokens** (`aEthRLUSD`, …) | Merkl: `cum - claimed` of the aToken. Aave V3 adapter: `getUserReserveData(RLUSD, user).aTokenBalance` — only the user's existing RLUSD supply on Aave, not Merkl-held aTokens. | Merkl: 0. Aave V3 adapter: increased aToken balance reflects the Merkl reward landing in the user's Aave position. | **No** — aTokens at the Distributor are not user-attributable on Aave's side until claim. |
| **LP tokens** (Aave-BPT, rETH-waEthWETH LP, …) | Merkl: `cum - claimed` of the LP. Wallet/Balancer adapters: only count what's in the user's wallet or staked in a known gauge — not what's at the Distributor. | Merkl: 0. The LP either lands in wallet (`ERC20DefaultBalanceAdapter`) or, if user stakes it, into the BalancerV3 adapter. | **No** — same invariant. |

Even the **root-rotation edge case** preserves this. If the user partially claims under root N, the bot then re-submits a proof under root N+1 with a higher cumulative, and `claimed[user][token].amount` still reflects the partial claim under N, the math is:

```text
NAV(Merkl) + NAV(wallet)
  = (cum_{N+1} - claimed_partial) + claimed_partial
  = cum_{N+1}
```

Which is correct: the user's true total is `cum_{N+1}`, the latest cumulative allocation. After a fresh claim under root N+1, `claimed = cum_{N+1}`, Merkl reports 0, wallet reports the full `cum_{N+1}`. Same total.

**The one shape that *could* double-count, and isn't on the table here**: if Merkl ever distributed AAVE directly (not stkGHO/stkAAVE — bare AAVE), and the Aave Safety Module adapter's reward leg also reported AAVE rewards earned via SM emissions, then a user holding stkGHO *and* receiving AAVE from Merkl would have NAV double-add the AAVE amount briefly between Merkl-claim and SM-claim, depending on timing. We do not see this in any of the test accounts, and Merkl's standing campaigns for Aave assets distribute the Aave-issued *receipt* tokens (stkGHO, aEthRLUSD) rather than bare AAVE — so this stays theoretical. If a campaign that distributes bare AAVE shows up, the operational fix is to exclude the AAVE token from what the bot caches; the trust-min property of the on-chain proof verification is unaffected.

**Operational rule for the bot**: there is no token-level filter required today. If a future campaign emits bare AAVE (or any other asset already double-counted by another adapter), exclude that token from the bot's submission set. Document the exclusion next to the bot's account list.

## What the bot must NOT do

- **Do NOT treat `clearAllocation` as manual-only.** An earlier revision of this guide said "do not call `clearAllocation` automatically"; that instruction is **withdrawn**, and following it walks an account into the `TooManyTokens` outage described under Responsibilities. GC is automatic and runs on the submit cadence. It is safe to automate precisely because it is stale-gated: a call against a still-live entry reverts `AllocationStillLive`, so an automated pass cannot suppress real value.
- There is no ownership to transfer. The adapter has no `Ownable`, no `AccessControl` and no admin — nothing to hand over, and no Safe involvement in its operation.
- Do not submit proofs for accounts that aren't in the operator's tracked list. Submitting for arbitrary external accounts is harmless on the adapter (the proof still verifies), but inflates per-user storage and confuses NAV consumers — the adapter is intended only for accounts whose NAV is computed by the OIV.
- Do not retry indefinitely on a single failed submission. One retry per cycle is enough; the next cycle will catch what was missed.

## Reference

- Adapter source: [`src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol`](../../src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol)
- Trust-model ADR: [`docs/decisions/0007-merkl-trust-minimized-cache.md`](../decisions/0007-merkl-trust-minimized-cache.md)
- Merkl Distributor source: <https://github.com/AngleProtocol/merkl-contracts/blob/main/contracts/Distributor.sol>
- Merkl API: <https://api.merkl.xyz/v4/users/{address}/rewards?chainId={cid}>
- Canonical Distributor address (every supported chain): `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`
