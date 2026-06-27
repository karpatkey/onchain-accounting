# 0015 — Assisted balance-adapter family (shared interface + AccessControl base)

Status: accepted

## Context

Most balance adapters are immutable and derive a position purely from on-chain state (see the immutability rule in `CLAUDE.md`). A minority cannot: the data needed to locate or value a position is not readable from a `view` without external help.

- **Merkl rewards** — allocations live in off-chain merkle trees; only cumulative *claimed* amounts are on-chain (ADR [0007](0007-merkl-trust-minimized-cache.md)).
- **ether.fi / StakeWise withdrawal queues** — requests are keyed by per-account coordinates the protocol does not index (ADR [0014](0014-agent-fed-cache-adapters-for-exit-queues.md)).
- **NFT-position protocols** (Uniswap V3, PancakeSwap V3, Nexus Mutual staking) — positions are held as **non-enumerable** NFTs; discovering an account's token ids by scanning every minted id on-chain is gas-prohibitive.

Each of these was (or would be) solved ad hoc: an `Ownable` adapter with `onlyOwner` mutators that cache the missing coordinates. The pattern is real and recurring, but it had no name, no shared interface, and no shared access-control surface — so each adapter reinvented it, and there was no on-chain way to identify "this adapter needs external assistance."

These adapters are the documented exceptions to the immutability rule. The trust model that makes them safe is invariant across all of them: **cache only position coordinates (never amounts), value every read live on-chain, and re-verify ownership per read**, so a faulty or compromised submitter can only **under-report, never over-report**.

## Decision

Introduce a third balance-adapter family, peer to plain `BalanceAdapter`s and meta-adapters (ADR [0010](0010-meta-balance-adapters.md)):

- **`IAssistedBalanceAdapter`** (`is IAccessControl, IBalanceAdapter`) — a minimal marker interface exposing `ASSISTANT_ROLE()`. It *identifies* the family and exposes the gating role; it deliberately does not prescribe a submit/verify surface, because each protocol's data shape differs (merkle proofs vs. request ids vs. NFT token ids). `IAccessControl` is listed first so the interface's C3 linearization matches `AccessControl`'s (OZ v5 `IAccessControl` is not `IERC165`; the reverse order does not compile).
- **`AssistedBalanceAdapter`** — an abstract base on OpenZeppelin `AccessControl` providing a two-role model: `DEFAULT_ADMIN_ROLE` administers (grants/revokes) `ASSISTANT_ROLE`, and `ASSISTANT_ROLE` is the role concrete adapters gate their submit/clear mutators with (`onlyRole(ASSISTANT_ROLE)`). The constructor requires a non-zero admin; the assistant is optional (grant later). The base only contributes access-control scaffolding — the family invariant above remains each concrete adapter's responsibility.

Role separation replaces the single `Ownable` owner: the **admin** (e.g. the security-council Safe) manages who can submit, and the **assistant** (an off-chain kpk-agents automation) holds only submission rights. The admin can rotate a compromised assistant without redeploying.

## Consequences

- The exception adapters get a named, consistent home. New assisted adapters extend one base instead of re-deriving the pattern.
- **Members.** All on the base: `MerklRewardsBalanceAdapter`, `EtherFiWithdrawalQueueBalanceAdapter`, `StakeWiseV3ExitQueueBalanceAdapter`, plus the NFT-`tokenId`-cached `UniswapV3PoolsBalanceAdapter` (and its `PancakeSwapV3PoolsBalanceAdapter` subclass) and `NexusMutualStakingPoolsBalanceAdapter`. Their off-chain submitters hold `ASSISTANT_ROLE` (granted/rotated by `DEFAULT_ADMIN_ROLE`). The NFT-position adapters completed the agent-fed discovery rework: instead of brute-force scanning every minted id, an assistant submits the account's NFT `tokenId`s via `submitTokenIds` — the write **reverts** (`NotTokenOwner`) on any id not owned by the account, and reads **discard** ids no longer owned — and each position is valued live (Uniswap/PancakeSwap LP off an oracle-reconstructed price, never `slot0`; Nexus stake via `StakingViewer.getTokens`), re-verifying ownership (`ownerOf` / `tokenInfo`) every read. Uniswap V3 / PancakeSwap V3 thereby moved from meta-adapters (ADR 0010) to this family. positionId is the **pool contract address** (Uniswap/PancakeSwap `factory.getPool(token0, token1, fee)`; Nexus `StakingViewer.stakingPool(poolId)`); the NFT id is carried as the last entry of an **adapter-supplied `PositionBalance.labels`** array (a new optional channel — the verbose reads prefer it over `positionLabels(positionId)`), since the pool-address positionId can't itself encode the per-NFT id.
- These members inherit this base. They remain the documented immutability exception — now expressed via AccessControl roles rather than `Ownable`.
- Supersedes the per-adapter framing in ADRs 0007 and 0014 only in that those adapters now have a shared family; their trust-model reasoning still stands.
