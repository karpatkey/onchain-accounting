# 0015 — Assisted balance-adapter family (shared interface + AccessControl base)

Status: accepted

> **Amendment (2026-07):** Uniswap V3 and PancakeSwap V3 were **reverted to meta-adapters** (ADR [0010](0010-meta-balance-adapters.md)). They were mistakenly placed in this family on the premise that their position NFTs are non-enumerable; in fact the Uniswap/PancakeSwap `NonfungiblePositionManager` is `ERC721Enumerable`, so an account's `tokenId`s are fully discoverable on-chain (`balanceOf` + `tokenOfOwnerByIndex` + `positions`) with no off-chain assistant. The `…PoolsAssistedBalanceAdapter` contracts were deleted; the reinstated meta-adapters (`UniswapV3PoolsMetaBalanceAdapter` / `PancakeSwapV3PoolsMetaBalanceAdapter`) keep the same live-`slot0` valuation (ADR [0017](0017-lp-valuation-instantaneous-amounts.md)) — only the family/classification changed. The rest of this ADR reads as originally accepted; **Nexus Mutual staking remains the sole NFT-position member** of this family.

## Context

Most balance adapters are immutable and derive a position purely from on-chain state (see the immutability rule in `CLAUDE.md`). A minority cannot: the data needed to locate or value a position is not readable from a `view` without external help.

- **Merkl rewards** — allocations live in off-chain merkle trees; only cumulative *claimed* amounts are on-chain (ADR [0007](0007-merkl-trust-minimized-cache.md)).
- **ether.fi / StakeWise withdrawal queues** — requests are keyed by per-account coordinates the protocol does not index (ADR [0014](0014-agent-fed-cache-adapters-for-exit-queues.md)).
- **NFT-position protocols** (Nexus Mutual staking) — positions are held as NFTs the protocol does not expose a per-account enumeration for, so discovering an account's token ids on-chain needs external help. (Uniswap V3 / PancakeSwap V3 were briefly placed here too, but their `NonfungiblePositionManager` *is* `ERC721Enumerable` — see the amendment above — so they reverted to meta-adapters.)

Each of these was (or would be) solved ad hoc: an `Ownable` adapter with `onlyOwner` mutators that cache the missing coordinates. The pattern is real and recurring, but it had no name, no shared interface, and no shared access-control surface — so each adapter reinvented it, and there was no on-chain way to identify "this adapter needs external assistance."

These adapters are the documented exceptions to the immutability rule. The trust model that makes them safe is invariant across all of them: **cache only position coordinates (never amounts), value every read live on-chain, and re-verify ownership per read**, so a faulty or compromised submitter can only **under-report, never over-report**.

## Decision

Introduce a third balance-adapter family, peer to plain `BalanceAdapter`s and meta-adapters (ADR [0010](0010-meta-balance-adapters.md)):

- **`IAssistedBalanceAdapter`** (`is IAccessControl, IBalanceAdapter`) — a minimal marker interface exposing `ASSISTANT_ROLE()`. It *identifies* the family and exposes the gating role; it deliberately does not prescribe a submit/verify surface, because each protocol's data shape differs (merkle proofs vs. request ids vs. NFT token ids). `IAccessControl` is listed first so the interface's C3 linearization matches `AccessControl`'s (OZ v5 `IAccessControl` is not `IERC165`; the reverse order does not compile).
- **`AssistedBalanceAdapter`** — an abstract base on OpenZeppelin `AccessControl` providing a two-role model: `DEFAULT_ADMIN_ROLE` administers (grants/revokes) `ASSISTANT_ROLE`, and `ASSISTANT_ROLE` is the role concrete adapters gate their submit/clear mutators with (`onlyRole(ASSISTANT_ROLE)`). The constructor requires a non-zero admin; the assistant is optional (grant later). The base only contributes access-control scaffolding — the family invariant above remains each concrete adapter's responsibility.

Role separation replaces the single `Ownable` owner: the **admin** (e.g. the security-council Safe) manages who can submit, and the **assistant** (an off-chain kpk-agents automation) holds only submission rights. The admin can rotate a compromised assistant without redeploying.

## Consequences

- The exception adapters get a named, consistent home. New assisted adapters extend one base instead of re-deriving the pattern.
- **Members.** All on the base: `MerklRewardsAssistedBalanceAdapter`, `EtherFiWithdrawalQueueAssistedBalanceAdapter`, `StakeWiseV3ExitQueueAssistedBalanceAdapter`, plus the NFT-`tokenId`-cached `NexusMutualStakingPoolsAssistedBalanceAdapter`. Their off-chain submitters hold `ASSISTANT_ROLE` (granted/rotated by `DEFAULT_ADMIN_ROLE`). The NFT-position adapter uses agent-fed discovery: instead of brute-force scanning every minted id, an assistant submits the account's NFT `tokenId`s via `submitTokenIds` — the write **reverts** (`NotTokenOwner`) on any id not owned by the account, and reads **discard** ids no longer owned — and each position is valued live (Nexus stake via `StakingViewer.getTokens`), re-verifying ownership (`ownerOf` / `tokenInfo`) every read. positionId is the **staking-pool contract address** (Nexus `StakingViewer.stakingPool(poolId)`); the NFT id is carried in the typed `PositionBalance.positionInstanceId` (the ephemeral per-item coordinate), since the pool-address positionId can't itself encode the per-NFT id. Human-readable labels are derived separately and lazily via `IPositionDescribable.positionLabels(positionId)` (display only; not part of identity).
- These members inherit this base. They remain the documented immutability exception — now expressed via AccessControl roles rather than `Ownable`.
- Supersedes the per-adapter framing in ADRs 0007 and 0014 only in that those adapters now have a shared family; their trust-model reasoning still stands.
