# Merkl proof-submitter bot — operator's guide

The `MerklRewardsAssistedBalanceAdapter` adapter (`src/balances/AssistedBalanceAdapters/MerklRewardsAssistedBalanceAdapter.sol`) reports a portfolio's *unclaimed* Merkl rewards by reading an on-chain cache of `(user, token, cumulativeAmount)` tuples. The cache is populated by an off-chain bot that fetches merkle proofs from the Merkl API and submits them to the adapter, where they're verified against the live `Distributor.getMerkleRoot()` before being stored. The adapter cannot fabricate amounts; the bot cannot fabricate amounts; only Merkl's published merkle tree determines what the adapter reports. See [`docs/decisions/0007-merkl-trust-minimized-cache.md`](../decisions/0007-merkl-trust-minimized-cache.md) for the design rationale and trust model.

> **Access control:** this adapter is in the assisted balance-adapter family — submissions are gated by `ASSISTANT_ROLE` (granted/rotated by `DEFAULT_ADMIN_ROLE`); see [ADR 0015](../decisions/0015-assisted-balance-adapter-family.md). Where this guide says "owner"/"owner key" below, read it as the `ASSISTANT_ROLE` holder.

This document specifies what the bot must do, how often, with what inputs and what failure modes. It does **not** specify the language, framework, or deployment topology — those are operator choices. The bot lives outside this repo; this file is the contract between the on-chain adapter and whatever ops process keeps it fed.

---

## Responsibilities

Exactly two things, every cycle:

1. **For each (account, chain) pair the operator wants tracked**, fetch the current set of `(token, cumulativeAmount, proof, breakdowns)` allocations from Merkl's API.
2. **Submit each account's complete allocation set to the deployed `MerklRewardsAssistedBalanceAdapter` on that chain** via `submitProofs` (or the multi-account `submitProofsBatch`), signed by a key holding `ASSISTANT_ROLE`. Submission is **replace** semantics: each `submitProofs(user, allocs)` call drops the user's entire prior cached token set and stores the supplied list, so the bot submits the user's full current allocation list every cycle — not a delta.

That's the whole job. Garbage collection (`clearAllocation`) and ownership transfer are infrequent operator actions, not part of the steady-state loop.

## Inputs

The bot needs three pieces of operator-provided configuration:

| Input | Source | Notes |
|---|---|---|
| **Account list** | Operator config | One or more EVM addresses to track. Typically the OIV's per-chain accounts. |
| **Chain list** | Operator config | Subset of {1, 10, 100, 8453, 42161}. Merkl supports more chains; only those the OIV deploys to matter. |
| **Adapter address per chain** | `script/config/deployments/<id>.json` → `balanceAdapters.MerklRewardsAssisted` | Read at startup; refresh on redeploy. |
| **Assistant key** | Operator secret store | The key holding `ASSISTANT_ROLE` on each `MerklRewardsAssistedBalanceAdapter`. By default this is `chainConfig.admin` (the OIV Safe). The bot must be able to submit transactions as this owner — typically via a Safe Transaction Service / module / API client. Direct EOA ownership is not recommended for production. |

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

        # 2. Build the account's COMPLETE allocation list (replace semantics — submit
        #    every currently-allocated token, not a delta). Keep entries with a positive
        #    cumulative amount; an omitted token is dropped from the cache.
        allocs = [
            Allocation(
                token    = r.token.address,
                amount   = int(r.amount),            # per-token cumulative; proof-verified
                proof    = r.proofs,
                campaigns = [                        # optional; if non-empty MUST sum to amount
                    CampaignShare(b.campaignId, b.subCampaignId, int(b.amount))
                    for b in r.breakdowns
                ],
            )
            for r in rewards
            if int(r.amount) > 0
        ]

        # 3. Skip the submission entirely if nothing changed since the cache was last
        #    written against the current root (see below).
        if not changed(adapter, account, allocs): continue

        # 4. Submit the full list (one account) or batch across accounts.
        adapter.submitProofs(account, allocs)
        # or, across many accounts: adapter.submitProofsBatch(users[], allocs[][])
```

`Allocation` is `(address token, uint256 cumulativeAmount, bytes32[] proof, CampaignShare[] campaigns)` and `CampaignShare` is `(bytes32 campaignId, bytes32 subCampaignId, uint256 cumulativeAmount)`. The `campaigns` breakdown is optional: leave it empty for one untagged position per token, or supply it to split the token into per-campaign positions — if non-empty, the shares **must** sum to the token's `cumulativeAmount`, or the call reverts with `CampaignSumMismatch`. No more than `MAX_CAMPAIGNS_PER_TOKEN` (64) shares per token, or it reverts with `TooManyCampaigns`.

To decide whether a submission is worth the gas, read the current cache via `adapter.allocations(account, token)` — which returns `(uint256 cumulativeAmount, bytes32 root, uint64 submittedAt)` — for each token in the list. If, for every token, the API's `amount` equals the cache's `cumulativeAmount` *and* the cache's `root` equals `adapter.DISTRIBUTOR().getMerkleRoot()`, the cache is already current and the submission can be skipped. (Note that because each submit fully replaces the user's set, monotonicity is **not** enforced across submits — `AmountRegression` only catches a decreasing duplicate of the same token within a single list.)

## Why this is trust-minimized

Three properties hold by construction; the bot does not need to be trusted to maintain any of them:

1. **The bot cannot inflate amounts.** For each entry, `submitProofs` recomputes `keccak256(abi.encode(user, token, cumulativeAmount))`, runs Merkl's exact sorted-pair proof verification against `Distributor.getMerkleRoot()`, and reverts if the proof does not match. Submitting a fabricated amount fails on-chain. A per-campaign `breakdowns[]` split is not individually proof-backed, but the contract requires the shares to sum to the proof-verified per-token total — so the bot can mis-split value across campaigns but can never inflate the token total.
2. **The bot cannot suppress amounts past Merkl's own cycle.** If the bot stops running, the cache becomes stale on the next root rotation (~8h) and the adapter reports 0 for every cached entry. NAV under-counts; it never over-counts. Recovery is "start the bot again; cache reads correctly within one cycle."
3. **Anyone can audit.** Given the on-chain root, the adapter's cached `(cumulativeAmount, root)`, and `Distributor.claimed(account, token).amount`, anyone can verify the reported balance is exactly `cumulativeAmount - claimed` and verify the cached `cumulativeAmount` against the published merkle tree.

The bot's only privileged capability is *availability* — keeping the cache fresh. It cannot deceive readers.

## Cadence and root rotation

Merkl rotates the merkle root approximately every 8 hours, gated by a 1–2 hour dispute window. During the dispute window, `Distributor.getMerkleRoot()` returns `lastTree.merkleRoot` (the previous root). The adapter handles this transparently — proofs verifying against `lastTree.merkleRoot` are fine while the dispute window is open.

Operationally:

- **4-hour cadence is a good default.** Sub-cycle frequency tolerates one missed run without going stale.
- **Don't rely on hour-aligned scheduling.** Merkl's rotation isn't strictly periodic. If the bot's run aligns badly with a rotation, the next run picks up the new root.
- **Avoid running multiple submitters in parallel** for the same `(adapter, account)`. They will race; because each submit fully replaces the user's set, the later submission simply overwrites the earlier one, and in steady state it is wasted gas. Use a per-chain mutex / leader election if HA matters.

## Submission model

The owner of every deployed `MerklRewardsAssistedBalanceAdapter` is `chainConfig.admin` — the OIV Safe. The bot must produce signed transactions on behalf of the Safe. Two reasonable shapes:

| Model | How it works | When to pick it |
|---|---|---|
| **Safe module** | Deploy a small Safe module that whitelists `submitProofs` / `submitProofsBatch` selectors on the adapter. The bot signs with a hot key authorized by the module. | Production. Hot key is constrained to "submit Merkl proofs" only — cannot move funds, cannot transfer ownership, cannot call any other adapter. Limits blast radius if the bot key is compromised. |
| **Safe Transaction Service queue** | Bot proposes transactions; signers approve and execute manually or via automation. | Pre-production / low-volume. No hot key, but cadence depends on signer availability. |

Direct EOA ownership (no Safe) is **not recommended** because the owner key would have to live wherever the bot runs.

The adapter does not care which model is used — `onlyRole(ASSISTANT_ROLE)` is the only constraint. Whatever shape the bot uses must end with the submitter holding `ASSISTANT_ROLE`.

## Failure modes and what to do

| Symptom | Likely cause | Action |
|---|---|---|
| `submitProofs` reverts with `InvalidProof` | API returned a proof for a root that hasn't reached this chain yet, or returned a proof for `lastTree` after the dispute window closed | Re-fetch from API and retry once. If still failing, log and skip — the next cycle will recover. |
| `submitProofs` reverts with `UninitializedRoot` | Distributor's `tree.merkleRoot` is 0 (e.g., on a chain where Merkl is freshly deployed) | Disable the bot for that chain until Merkl publishes a root. |
| `submitProofs` reverts with `AmountRegression` | The list contains a duplicate token whose cumulative decreases within the same submission. Should not happen under Merkl's monotonicity invariant; suggests an API bug or campaign restructuring. | Page an operator. Do not auto-clear the cache. The assistant can call `clearAllocation` manually after investigating. |
| `submitProofs` reverts with `CampaignSumMismatch` | The per-campaign `breakdowns[]` shares for a token don't sum to that token's `cumulativeAmount` | Re-fetch and recompute the breakdown; submit an empty `campaigns` list (one untagged position) if the API's breakdown can't be reconciled. |
| `submitProofs` reverts with `AccessControlUnauthorizedAccount` | Bot's signer does not hold `ASSISTANT_ROLE` | Verify the Safe module wiring / owner address. Likely a deploy or ownership-transfer issue, not a routine failure. |
| Cache reads as 0 even though API shows non-zero `amount` | Cached `root` does not match current `Distributor.getMerkleRoot()`. Bot has not yet run since the last root rotation. | Wait for next bot cycle. If persistent, the bot is stopped — investigate. |
| Adapter not in NAV | Either `enabled: false` in chain config or `addBalanceAdapters` wasn't called | Check `NAVCalculator.isAdapterRegistered(adapter)`; if false, register via Safe. |

## Operator-side bookkeeping

Periodically (weekly is fine):

- **Prune fully-claimed entries.** For each `(account, token)` in the adapter's per-user list, if `cached.cumulativeAmount == Distributor.claimed(account, token).amount`, call `clearAllocation(account, token)`. This is housekeeping — leaving them in place is correct but wastes storage and read gas.
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

```
NAV(Merkl) + NAV(wallet)
  = (cum_{N+1} - claimed_partial) + claimed_partial
  = cum_{N+1}
```

Which is correct: the user's true total is `cum_{N+1}`, the latest cumulative allocation. After a fresh claim under root N+1, `claimed = cum_{N+1}`, Merkl reports 0, wallet reports the full `cum_{N+1}`. Same total.

**The one shape that *could* double-count, and isn't on the table here**: if Merkl ever distributed AAVE directly (not stkGHO/stkAAVE — bare AAVE), and the Aave Safety Module adapter's reward leg also reported AAVE rewards earned via SM emissions, then a user holding stkGHO *and* receiving AAVE from Merkl would have NAV double-add the AAVE amount briefly between Merkl-claim and SM-claim, depending on timing. We do not see this in any of the test accounts, and Merkl's standing campaigns for Aave assets distribute the Aave-issued *receipt* tokens (stkGHO, aEthRLUSD) rather than bare AAVE — so this stays theoretical. If a campaign that distributes bare AAVE shows up, the operational fix is to exclude the AAVE token from what the bot caches; the trust-min property of the on-chain proof verification is unaffected.

**Operational rule for the bot**: there is no token-level filter required today. If a future campaign emits bare AAVE (or any other asset already double-counted by another adapter), exclude that token from the bot's submission set. Document the exclusion next to the bot's account list.

## What the bot must NOT do

- Do not call `clearAllocation` automatically — it's a manual operator action triggered by either pruning (above) or an `AmountRegression` investigation.
- Do not transfer ownership of the adapter. Ownership transfers happen via the Safe, not the bot.
- Do not submit proofs for accounts that aren't in the operator's tracked list. Submitting for arbitrary external accounts is harmless on the adapter (the proof still verifies), but inflates per-user storage and confuses NAV consumers — the adapter is intended only for accounts whose NAV is computed by the OIV.
- Do not retry indefinitely on a single failed submission. One retry per cycle is enough; the next cycle will catch what was missed.

## Reference

- Adapter source: [`src/balances/AssistedBalanceAdapters/MerklRewardsAssistedBalanceAdapter.sol`](../../src/balances/AssistedBalanceAdapters/MerklRewardsAssistedBalanceAdapter.sol)
- Trust-model ADR: [`docs/decisions/0007-merkl-trust-minimized-cache.md`](../decisions/0007-merkl-trust-minimized-cache.md)
- Merkl Distributor source: <https://github.com/AngleProtocol/merkl-contracts/blob/main/contracts/Distributor.sol>
- Merkl API: <https://api.merkl.xyz/v4/users/{address}/rewards?chainId={cid}>
- Canonical Distributor address (every supported chain): `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`
