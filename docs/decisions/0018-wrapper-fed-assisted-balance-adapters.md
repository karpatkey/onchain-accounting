# 0018 — Wrapper-fed assisted balance adapters (on-chain feeder, `SUBMITTER_ROLE`)

Status: accepted

## Context

The assisted balance-adapter family (ADR [0015](0015-assisted-balance-adapter-family.md)) covers adapters that cannot derive a position from on-chain state alone and need a trusted party to submit position *coordinates* (never amounts), which the adapter then values live and re-verifies per read — so the feeder can only under-report. Every existing member is fed by an **off-chain** `ASSISTANT_ROLE` agent (kpk-agents automation) that watches chain state and submits the account's coordinates via periodic transactions.

For Nexus Mutual staking, the coordinates are `StakingNFT` token ids that are created/destroyed at a very specific, observable moment: when the position is opened or closed. An off-chain agent submitting a full-set `submitTokenIds` on a polling cadence is one way to keep the cache current, but it leaves a window between the on-chain deposit/withdraw and the agent's next submission during which NAV is stale, and it depends on an off-chain process staying live.

If deposits and withdrawals are routed through a **wrapper contract**, that wrapper already knows the token id the pool returned at exactly the moment it changes — it can push/pop the id into the adapter **atomically, in the same transaction**, with no off-chain component and no staleness window.

## Decision

Add a **wrapper-fed variant** to the assisted family: same trust model and family invariant as ADR 0015 (cache coordinates only, value live, re-verify ownership per read → the feeder can only under-report), but the feeder is an **on-chain contract holding `SUBMITTER_ROLE`** instead of an off-chain agent holding `ASSISTANT_ROLE`, and the submit surface is **incremental** (single add / single remove) rather than a full-set replace.

**Sole Nexus member.** `NexusMutualStakingPoolsAssistedBalanceAdapter` — the Nexus Mutual staking adapter. It **replaces** the earlier off-chain-assistant-fed Nexus adapter (removed) and keeps the canonical `…Assisted` name. Same Nexus valuation (per-NFT NXM `Staking` + `Rewards` legs, live ownership re-verification via `StakingNFT.tokenInfo`, positionId = `StakingViewer.stakingPool(poolId)`, `positionInstanceId` = tokenId, `["Staking Pools", "Pool #<id>"]` labels), but on OZ `AccessControl`: `DEFAULT_ADMIN_ROLE` administers `SUBMITTER_ROLE`, and `SUBMITTER_ROLE` (held by the wrapper) gates `submit(account, tokenId)` (ownership-checked, fail-loud) and `remove(account, tokenId)` (idempotent), plus an admin `clearAccount` rescue. There is no per-account cap: `submit` only adds ids the caller owns via a real Nexus deposit, so the cache is bounded by the account's own deposits, and a pathological large read is self-inflicted and fail-opens per-adapter in NAVCalculator (never affecting other accounts).

**Fed by `NexusMutualStakingPoolsWrapper`** (`src/balances/wrappers/`) — a thin, `DEPOSITOR_ROLE`-gated forwarder around Nexus staking pools: `depositTo` pulls the NXM `amount` from the caller (`transferFrom`), approves the Nexus `TokenController`, forwards to the pool, and `submit`s the returned tokenId for the caller in the same tx; `withdraw` forwards and `remove`s it. `depositTo` hardcodes the pool's `destination` to `msg.sender` (and omits the parameter), so the NFT is always owned by the tracked account. Nexus routes withdrawn stake + rewards to `StakingNFT.ownerOf(tokenId)` (the depositor) and `withdraw` is permissionless, so the funds flow directly to the caller and the wrapper needs no NFT-operator approval.

**Implementation note — single contract for now.** `NexusMutualStakingPoolsAssistedBalanceAdapter` is deliberately a **single self-contained contract**: the id cache, the per-id fail-open valuation fan-out, the `SUBMITTER_ROLE` access-control scaffolding, the Nexus valuation, and the single-asset getters are all inlined rather than composed from shared bases. It shares the cache/valuation *pattern* with the assistant-fed adapters (which compose it from `AssistedBalanceAdapter` / `AssistedNftCacheAdapter` / `AssistedNftValuationAdapter`) but not the code. Factoring the common machinery out into role-agnostic bases shared by both feeder variants is a **deferred refactor**, to be done once the wrapper-fed shape has settled.

## Consequences

- Nexus staking moves to an on-chain, atomically-maintained tracking path; it **replaces** the earlier assistant-fed Nexus adapter (removed) under the same `NexusMutualStakingPoolsAssistedBalanceAdapter` name. The other assistant-fed adapters (Merkl, ether.fi, StakeWise, Uniswap V3, PancakeSwap V3) are untouched.
- The wrapper-fed adapter remains a documented immutability exception (assisted family), now expressed through `SUBMITTER_ROLE` rather than `ASSISTANT_ROLE`. The family invariant is unchanged, so the safety argument (feeder can only under-report) carries over verbatim.
- Because `withdraw` pops the id unconditionally and Nexus does not burn the `StakingNFT` on withdraw, a **partial** withdrawal stops tracking any remaining stake until the next deposit re-adds the id — a safe under-report, consistent with the invariant.
- The inlined single-contract form trades some duplication (vs. the assistant-fed bases) for a smaller, self-contained review surface; the shared-base extraction is tracked as follow-up work. Supersedes nothing in ADR 0015; extends it with a second feeder mechanism.
