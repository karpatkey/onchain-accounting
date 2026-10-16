# 0027 — Standalone, permissionless, ownership-validated position indexes for non-enumerable position managers

- Status: proposed

## Context

Two of the venues on Robinhood Chain (chain id 4663) cannot answer "which positions does this holder
have?" from chain state:

- **Uniswap V4.** The `PositionManager` is a Solmate ERC721 with no enumeration extension.
  `balanceOf(holder)` works; `tokenOfOwnerByIndex` **reverts** (MEASURED on 4663). A holder's tokenIds
  exist only in `Transfer` logs, and an adapter answering a `view` call on the NAV hot path cannot read
  logs.
- **Fables** (a hook-pooled range product on Uniswap V4). A position is an ERC-6909 balance in the hook.
  v4-core's ERC6909 is a bare `mapping(address => mapping(uint256 => uint256))` with no enumeration and —
  unlike ERC-721 — **no count either**. There is no number anywhere on chain that says how many ranges a
  holder has.

This repo already has a family for adapters that cannot derive a position from on-chain state alone: the
assisted family (ADR 0015), fed permissionlessly by `msg.sender`-keyed submissions through a delegatecall
assistant (ADR 0018). `AssistedCoordCache` is both the cache and the adapter, caches **coordinates only**,
values live, and re-verifies ownership on every read, so it can only under-report.

Two properties of the 4663 case do not fit that mould:

1. **The holder cannot conveniently transact.** The position is owned by a vfat Sickle (ADR 0026), which
   executes only through vfat's own router under the fund's Zodiac Roles policy. `msg.sender`-keying would
   require routing a NAV-bookkeeping call through the fund's execution path on every re-centre.
2. **Ownership is directly verifiable at write time.** `PositionManager.ownerOf(tokenId)` and
   `hook.balanceOf(holder, rangeId)` are exactly the authority a submission needs. Keying by `msg.sender`
   would be a *weaker* statement than asking the protocol who owns the thing.

The failure this machinery exists to prevent is measured, not hypothetical: on 17 Sep 2026 a single
unindexed v4 tokenId hid **29.5 % of the fund** from its share price, and the gap stood from 17 to 20 Sep
2026 (MEASURED; the NAV reports an unseen position as zero, with no error).

## Decision

Ship the discovery index as a **standalone, permissionless, ownership-validated contract** next to the
adapter that reads it — `V4PositionIndex` (`MetaBalanceAdapters/uniswap/v4/`) and `FablesRangeIndex`
(`MetaBalanceAdapters/fables/`) — rather than as a member of the assisted family.

Rules, identical in both:

- **`index(...)` takes nothing on the caller's word.** It asks the protocol — `ownerOf(tokenId)` for v4,
  `hook.balanceOf(holder, rangeId)` plus `hook.rangeKey(rangeId).set` for Fables — and files the entry
  under whatever the protocol says. There is no argument that attributes a position to a holder who does
  not hold it, so there is nothing an owner or an allowlist would protect, and the operator never becomes
  a bottleneck.
- **The index is a hint, never an authority.** The adapter re-verifies ownership before valuing anything,
  so a stale entry (every re-centre burns an NFT or zeroes a range) and a deliberately poisoned one are
  the same thing to it: skipped. An index can therefore only ever fail to grow the NAV, never inflate it.
- **`prune(holder, ...)` is permissionless too, and refuses to remove an entry the protocol still backs**
  (`EntryStillValid`). Pruning is not a privilege; it reclaims storage the chain has already invalidated.
- **Incompleteness is surfaced as data, not as a revert.** Each adapter exposes
  `coverage(holder)` — `(indexedLive, heldTotal)` for v4, `(live, filed)` for Fables, where no held-total
  exists — for an off-chain gate to assert on before settlement. Reverting instead would be strictly
  worse: `PriceFeedLib._getAdapterPositions` reads an adapter revert as "nothing to report", so an adapter
  that reverted to signal "my index is behind" would price the entire fund at zero.
- **Entries are bucketed per (holder, protocol-instance source).** `FablesRangeIndex` keys entries by
  `(holder, hook)` and the adapter loads only the bucket named by the governed pool's own `PoolKey`. This
  is not cosmetic: the first build called every filed entry's hook before checking anything, so a stranger
  could file an entry naming a contract that answers the index (and therefore cannot be pruned) but
  reverts for the adapter, which blinded that holder's read for **every** instance. Found in review of
  APE-robinhood PR #46 and reproduced on a live fork, 24 Sep 2026.

## Consequences

**Positive**

- Discovery works for holders that cannot submit on their own behalf, without adding a privileged key to
  the NAV read path.
- The trust statement is "the protocol says this holder owns this", checked twice (at write, and again at
  read), which is strictly stronger than "someone claimed this for themselves".
- The index is shared: operator tooling, monitoring, and the adapter read the same contract, and
  `coverage` gives the off-chain settlement gate one number to assert on.

**Negative**

- A **fourth** shape in a repo that already has plain, meta and assisted/attested families. It is
  deliberately not an adapter and holds no `PositionBalance` logic, but a reader looking for the cache in
  `AssistedBalanceAdapters/` will not find it there.
- **Completeness is not provable on-chain for Fables.** With no held-total, `coverage` can only report
  `(live, filed)`; "is anything missing?" is answerable only off-chain, by walking `Transfer`/ledger logs.
  This is the same residual exposure ADR 0015 accepts, and the same mitigation applies: the off-chain gate
  runs before any settlement, never after.
- Anyone can grow a holder's entry list, which is bounded in effect by the adapter's own per-holder scan
  cap and by `MetaBalanceAdapter`'s per-instance gas stipend, but does mean an index bucket is attacker-
  growable storage.
