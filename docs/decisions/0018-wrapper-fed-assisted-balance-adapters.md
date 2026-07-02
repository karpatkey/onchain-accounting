# 0018 — Permissionless wrapper-fed assisted balance-adapter family

## Status

accepted (supersedes the per-protocol drafts once numbered 0018/0019/0020 for Nexus, StakeWise, ether.fi, Stader — folded into this single family ADR)

## Context

ADR [0015](0015-assisted-balance-adapter-family.md) named the **assisted** family: adapters that cannot derive a position from on-chain state alone and must be fed the missing *coordinates* by a trusted party, upholding the invariant **cache coordinates only (never amounts), value every read live on-chain, re-verify ownership per read → under-report only**. Its members were fed by an **off-chain agent** holding `ASSISTANT_ROLE`, which submits the full candidate set (`submitTokenIds`) for many accounts.

A second feeding pattern then recurred for on-chain, per-position flows — Nexus Mutual staking, StakeWise V3 exit queue, ether.fi and Stader withdrawal queues. Here the position is created/destroyed by a transaction the position owner itself sends, so the coordinate can be fed **on-chain, atomically, in that same transaction** — no off-chain agent, no staleness window. Four PRs each built this independently and diverged gratuitously: three trust models (`SUBMITTER_ROLE` / `WRAPPER_ROLE` / permissionless), two delegatecall-guard error names (`OnlyDelegateCall` / `NotDelegateCall`), and duplicated foundation contracts + ADRs. They could not merge side by side.

## Decision

Introduce a **permissionless, wrapper-fed** variant of the assisted family, with one shared foundation. The two most recent implementations converged on it and it is the canonical model going forward.

**Trust model — permissionless, `msg.sender`-keyed.** The adapter's `submit`/`remove` take **no `account` argument and no role**: they derive the account from `msg.sender`, so a caller can only ever mutate its OWN cached set. The invariant of ADR 0015 is preserved by live re-verification alone (values read on-chain, ownership re-checked per read), so a role adds nothing — a faulty feeder can only under-report regardless. This drops all post-deploy role grants.

**Feeder — a delegatecall action wrapper.** The canonical feeder is a stateless wrapper (`src/balances/AssistedBalanceAdapters/wrappers/`) the owner Safe `delegatecall`s. Under `delegatecall` `address(this)` is the Safe, so the protocol sees `msg.sender = Safe` (the position owner) and the adapter's `msg.sender`-keyed cache records against that same Safe. No custody, no asset-forwarding, no role. A wrapper's own deployed address is pinned at construction (`SELF`); a direct (non-delegatecall) call is rejected fail-loud with the canonical `NotDelegateCall` (`src/errors.sol`).

**Shared foundation.**
- **`IAssistedBalanceAdapter`** (reclaimed): minimal marker `is IBalanceAdapter` exposing only `clearAccount()` (self-service GC). No `IAccessControl`, no role getter. The prior ASSISTANT_ROLE marker/base were renamed to **`IAssistantFedBalanceAdapter`** / **`AssistantFedBalanceAdapter`** (still used by the off-chain-agent members, e.g. Merkl).
- **`AssistedCoordCache`** — the **single** cache base. A coordinate is an opaque `bytes` blob, so one cache serves every member regardless of shape: a bare `uint256` NFT tokenId / requestId (`abi.encode(id)`) or a tuple (StakeWise `abi.encode(vault, positionTicket, timestamp)`). Provides the `msg.sender`-keyed `submit`/`remove`/`clearAccount` (blobs deduped by `keccak256`, cap + fail-loud `CoordinateCacheFull`/`CoordinateNotOwned`), the single-underlying-asset `IBalanceAdapter` getter surface, and a per-coordinate fail-open self-`staticcall` valuation fan-out (so a revert-prone valuation like Nexus's `StakingViewer.getTokens` isolates to that one coordinate). Concrete adapters implement `_validateCoord` / `_removable` / `_valueCoord` / `_coordId` / `_maxCoords` / `_maxLegsPerCoord` and expose a typed `submit`/`remove` that `abi.encode`s their coordinate. (An earlier draft split this into a `uint256`-only `AssistedNftIdCache` + `AssistedNftIdValuation` plus a tuple `AssistedCoordCache`; collapsed to one base since a `bytes` coordinate subsumes both.)
- **`IBalanceAdapterWrapper`** / **`BalanceAdapterWrapper`** — wrapper marker + abstract base contributing `SELF`, `ADAPTER`, and the `onlyDelegateCall` guard.

## Consequences

- **Members** (all rebased onto the foundation): `NexusMutualStakingPoolsAssistedBalanceAdapter`, `StakeWiseV3ExitQueueAssistedBalanceAdapter`, `EtherFiWithdrawalQueueAssistedBalanceAdapter`, `StaderWithdrawalQueueBalanceAdapter`, each paired with a `…Wrapper`. Each shrinks to protocol-specifics (the per-id/coord valuation, the `_ownerOf`, the labels, the forward calls).
- Adding the next wrapper-fed protocol is a small adapter + wrapper extending the bases — no re-derivation of the cache, valuation fan-out, delegatecall guard, or trust model.
- **EOA depositors cannot use a wrapper** (an EOA cannot `delegatecall`); the intended feeders are Safe/Avatar accounts, gated at the Safe/Zodiac layer.
- The off-chain-agent (`ASSISTANT_ROLE`) members are unaffected beyond the interface/base rename; their migration off `IAssistantFedBalanceAdapter` is a separate follow-up.
- Supersedes the per-protocol framing that was drafted separately for Nexus/StakeWise/ether.fi/Stader; ADRs 0014/0015 still stand (this refines 0015's feeding model, it does not replace the family or its invariant).
