# 0019 — StakeWise V3 exit-queue wrapper-fed adapter (delegatecall feeder, self-submit)

Status: accepted

## Context

StakeWise V3 exit-queue positions are not enumerable: a position is identified only by a `positionTicket` emitted in `ExitQueueEntered`, with no owner→tickets view, so a pure-view adapter cannot discover them. ADR [0014](0014-agent-fed-cache-adapters-for-exit-queues.md) surfaces them to NAV with `StakeWiseV3ExitQueueAssistedBalanceAdapter`, fed by an **off-chain** `ASSISTANT_ROLE` agent that scrapes the events and submits `(vault, positionTicket, timestamp)` tuples — leaving a staleness window between the on-chain enter/exit and the agent's next submission.

ADR [0018](0018-wrapper-fed-assisted-balance-adapters.md) added a **wrapper-fed** variant to the assisted family (ADR [0015](0015-assisted-balance-adapter-family.md)): an on-chain wrapper holding `WRAPPER_ROLE` pushes/pops coordinates atomically as it forwards deposits/withdrawals. Its first member (Nexus Mutual staking) uses a **normally-called** wrapper: it `transferFrom`s the depositor's (transferable) NXM, forwards to the pool, and Nexus's **permissionless** `withdraw` routes funds to the NFT owner — so one shared wrapper contract can hold `WRAPPER_ROLE` and act for every depositor.

**StakeWise does not fit that shape.** Two protocol constraints break the normally-called model:

1. `claimExitedAssets(positionTicket, timestamp, exitQueueIndex)` is keyed on `msg.sender` — only the address that was the `receiver` at `enterExitQueue` time can claim. A shared wrapper called normally would be `msg.sender`, so only it could claim; the depositor could not.
2. StakeWise V3 vault shares are internal, non-transferable balances — a wrapper cannot `transferFrom` a depositor's shares to enter the queue on its behalf.

## Decision

Feed the StakeWise exit-queue adapter through a **delegatecall** wrapper, with the adapter gated by **role-gated self-submit** rather than a single-wrapper `WRAPPER_ROLE`. Same family invariant as ADR 0015/0018 (cache coordinates only, value live, re-verify ownership per read → the feeder can only under-report).

- **`StakeWiseV3ExitQueueWrapper`** (`src/balances/wrappers/`) — a stateless **delegatecall action** contract the depositor Safe delegatecalls. Because it runs in the Safe's context, `address(this)` is the Safe: the vault sees `msg.sender = Safe`, the exit position is owned by the Safe (`receiver` is forced to `address(this)`), the Safe can later claim, and claimed assets are paid directly to the Safe — no custody or asset-forwarding logic. `enterExitQueue(vault, shares, receiver)` calls the vault then `submit`s the returned ticket for `address(this)`; `claimExitedAssets(vault, positionTicket, timestamp, exitQueueIndex)` claims then `remove`s the ticket. Signatures mirror the vault's, with `vault` prepended.
  - **Delegatecall consequences, handled:** it performs **no storage writes** on these paths (a write would corrupt Safe storage), and its `DEPOSITOR_ROLE` gate cannot use the inherited `onlyRole` (that reads Safe storage). Instead it checks the role against the wrapper **singleton's own** storage via an immutable `SELF` (`IAccessControl(SELF).hasRole(DEPOSITOR_ROLE, address(this))` — "is the executing Safe an approved depositor?"). Admins grant/revoke `DEPOSITOR_ROLE` by calling the singleton directly.
- **`StakeWiseV3ExitQueueBalanceAdapter`** (`src/balances/AssistedBalanceAdapters/`) — the wrapper-fed peer of the ADR-0014 assisted adapter. Extends `AccessControl` with a `DEPOSITOR_ROLE`; `submit(account, vault, positionTicket, timestamp)` / `remove(...)` require the caller to hold `DEPOSITOR_ROLE` **and** to pass `account == msg.sender` (a depositor can only track its OWN tickets), fed one ticket at a time. Under delegatecall the wrapper calls the adapter with `msg.sender = account = the Safe`, so the self-submit guard holds. The cache + live valuation mirror the assisted adapter (per-ticket claimable/locked split on `EXIT_CLAIM_DELAY`, live ownership re-verification via `calculateExitedAssets(account, …)`, `positionId = abi.encode(vault)`, `positionInstanceId = bytes32(positionTicket)`, `["Exit Queue", "<receiptSymbol>"]` labels). For now the adapter is kept as a **single self-contained contract**; the cache + valuation shared with the assistant-fed adapter may be abstracted into a common base in a follow-up.

**Why not reuse `WrapperFedBalanceAdapter` (ADR 0018).** That base grants `WRAPPER_ROLE` to a single normally-called wrapper contract. Under StakeWise's required delegatecall model the adapter's caller is each depositor Safe, not one wrapper address, so the correct gate is a per-Safe `DEPOSITOR_ROLE` self-submit, not one `WRAPPER_ROLE` grant. The two express the same trust model; the role plumbing differs because the feeder topology differs.

## Consequences

- StakeWise exit-queue tracking gains an on-chain, atomically-maintained path for managed Safes; the assistant-fed adapter (ADR 0014) is **kept** alongside it — both coexist, and which is registered on `NAVCalculator` is a config decision.
- The depositor→ticket attribution is enforced on-chain and atomically by the delegatecalled wrapper (it submits the exact executing Safe), and every read re-verifies ownership against `receiver = account`, so a faulty depositor can only under-report.
- The wrapper is a documented immutability exception (assisted family), expressed through the adapter's `DEPOSITOR_ROLE`. It is **delegatecall-only** by design; a direct call would set `receiver = the singleton` and revert (the singleton holds no vault shares).
- Deploy-script / config-JSON wiring is deferred to a follow-up (as for ADR 0018's first member).
- This extends ADR 0015/0018 with a second feeder topology (delegatecall + self-submit); it supersedes nothing.
