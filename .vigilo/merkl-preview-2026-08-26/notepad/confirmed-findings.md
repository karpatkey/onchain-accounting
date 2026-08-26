# Merkl cache-free preview (PR #324) — audit conclusions 2026-08-26

Scope: MerklRewardsAttestedBalanceAdapter.sol + IAttestedBalanceAdapter.sol (worktree
/home/nicol/projects/oa-merkl-preview @ feat/merkl-reward-preview, f60fa648).

## Over-report analysis (family invariant: under-report only) — CLEAN
- Duplicate-token double-count: BLOCKED by `_revertOnDuplicateToken` (L725), run before
  the value loop over ALL entries (incl. unregistered), keyed on token address only, so
  two entries for the same token (even with different cumulatives) revert `DuplicateToken`.
- Campaign-split mulDiv amplification: `_buildTokenLegs` (L755) numerator is `unclaimed`,
  denominator `tokenCumulative`, and `_checkProofAndCampaigns` enforces
  Σ shares.cumulative == cumulative == tokenCumulative. Σ floor(unclaimed*share/cum)
  ≤ floor(unclaimed*Σshare/cum) = unclaimed. Sum of legs ≤ unclaimed. No amplification.
- cumulative-vs-unclaimed numerator: `_unclaimedFrom` = cumulative − live claimed, floored
  at 0 (L925). Correct real figure.
- mulDiv overflow: Math.mulDiv 512-bit intermediate; inputs bounded by proven cumulative.

## Proof-verification parity with submit — CONFIRMED
Both submit and preview call the SAME `_checkProofAndCampaigns` (L938):
leaf = keccak256(abi.encode(account, token, cumulativeAmount)); sorted-pair
`keccak256(abi.encode(a,b))` in `_verifyMerklProof` (L963); verified against live
`Distributor.getMerkleRoot()` (root fetched once at L687, non-zero enforced).
Preview omits only the cache-only `AmountRegression` monotonicity check — correct, as
preview writes nothing and the proven cumulative is the live-tree figure. Stale/≤claimed
→ 0 via `_unclaimedFrom`.

## Refactor behavior-preserving — CONFIRMED (git diff dd887c9b..HEAD)
- `_submitProof` delegates leaf+campaign checks to `_checkProofAndCampaigns`, keeps
  monotonicity inline. Only reordering: campaign-sum check now precedes AmountRegression;
  both revert, so the sole observable difference is which revert fires on a doubly-invalid
  entry (cosmetic). Valid entries and state transitions unchanged.
- `tokenLegsSelf` delegates to `_buildTokenLegs` with identical
  (allocations[..].cumulativeAmount, _campaigns[..]) inputs.
- `_unclaimed` delegates to `_unclaimedFrom(account, asset, a.cumulativeAmount)` — identical.

## Storage / NAV isolation — CONFIRMED
`previewPositions` + `previewPositionsSelf` are `view`; read only Distributor + registry,
NO adapter storage (allocations/_campaigns/_userTokens). No caller in src/ or script/
(portal-facing only); NAV path getAdapterPositions→buildPositionsSelf→tokenLegsSelf reads
the agent-fed cache exclusively. Preview cannot affect getAdapterPositions/getAccountNav.

## Immutability — CONFIRMED
No new admin/owner/upgrade/mutable state; only additive view fns + one error + one
private pure helper. DISTRIBUTOR/NAV_CALCULATOR still immutable.

## Findings
- INFO-01: dangling `{previewBalances}` NatSpec references (x4). Doc-only.

No Low/Medium/High/Critical. No PoC required.
