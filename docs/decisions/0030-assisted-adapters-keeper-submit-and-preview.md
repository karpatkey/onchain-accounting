# 0030 — Assisted adapters: keeper-fed `submitFor` + cache-free `previewPositions`

## Status

proposed (amends [0015](0015-assisted-balance-adapter-family.md) and [0018](0018-assistant-fed-assisted-balance-adapters.md))

## Context

The assisted family (ADR 0015 / 0018) caches position *coordinates* per account and values them live. Its only
feeder is the account itself: `submit` / `remove` are keyed on `msg.sender`, and the canonical caller is a
`BalanceAdapterAssistant` the owner Safe delegatecalls in the same transaction that opens or closes the position.

That leaves a gap the ADR 0018 design accepted at the time: **a position the account did not open through its
Assistant is invisible to the NAV.** That covers Safes that entered ether.fi, StakeWise or Nexus Mutual directly
(bespoke clients whose roles allow the protocol entrypoint, positions opened before the Assistants existed), and
the StakeWise remainder ticket a partial claim re-queues. The account could submit those itself, but for a client
Safe that is a signed transaction plus a roles-permission change per client, which does not happen in practice.

Two capabilities close the gap:

1. a **write** that files an already-existing position under its owner, without the owner sending the transaction;
2. a **read** that values a caller-supplied list of positions without touching the cache, for off-chain reporting
   and for checking what a submit would add.

## Decision

1. **`submitFor(account, coord)` / `submitForBatch(accounts, coords)`, gated by `SUBMITTER_ROLE`.** The coordinate
   goes through the same write-time validation as the owner path (`_validateCoord(account, coord)`), so it is filed
   only under the account the protocol says owns it. The family therefore carries OZ `AccessControl`;
   `IAssistedBalanceAdapter` is `IAccessControl`-based. `DEFAULT_ADMIN_ROLE` is the Security Council Safe, and the
   constructor grants nothing else: a deploy never creates a live submit right. The role cannot change any
   reported amount (see the table), so its end-state administration matches the Merkl adapter's (ADR 0022
   amendment) — the Council directly, not the NAV timelock: rotating a compromised keeper must not wait three days.
   A keeper-filed entry also emits `CoordSubmittedFor(account, id, submitter)`, so it is attributable on-chain.
2. **`removeFor(account, coord)` is permissionless and gated on definitive death**, not on a role. Same lesson as
   the attested family's audit finding L-02: a role-gated remove lets a compromised key delete LIVE positions,
   which is a targeted under-report. A remove that only succeeds once the protocol *proves* the position is gone
   (a successful read showing burned / transferred / zero-owed; a reverting read never counts as dead) is safe
   for any caller and lets anyone repair a cache. The owner-side `remove` / `clearAccount` are unchanged.
3. **`previewPositions(account, data)`**, `data = abi.encode(bytes[] coords)`: stateless, view-only, not on the NAV
   path. Every coordinate is length-checked, deduplicated, counted against the cache cap and run through the same
   `_validateCoord` as a submit, fail-loud (a bad coordinate reverts the preview instead of being skipped), then
   valued with the same `_valueCoord` the NAV read uses.
4. Owner `submit` / `remove` / `clearAccount`, coordinate encodings, identity (`protocolBrand` / `protocolId` /
   `protocolSubId` / `positionId`), legs and caps are **unchanged**, so reconciliation keys stay stable across the
   redeploy.

## Security concerns and how each is ruled out

The family invariant is unchanged: coordinates only, valued live, ownership re-verified on every read, credit legs
only → **a cache entry can under-report, never over-report**. The rows below are what the new surface adds.

| # | Concern | Rule |
|---|---|---|
| S1 | A keeper files a position under the wrong account (over-report). | `submitFor` validates ownership against `account` exactly like the owner path; every read re-checks ownership against the queried account. A wrong-owner entry reverts at submit and would value 0 on read anyway. |
| S2 | The same position counted twice through a different byte encoding of its coordinate (the generic `bytes` entry). | Each member fixes its coordinate length (32 bytes for ether.fi / Nexus, 96 for StakeWise); any other length reverts before decoding. `abi.decode` rejects dirty address bits. The dedup key is the hash of that single canonical form. |
| S3 | StakeWise: a valid ticket under a wrong timestamp. | StakeWise keys a request on `keccak256(receiver, timestamp, ticket)`; a wrong timestamp reads 0, fails the `owed > 0` check at submit, and values 0. |
| S4 | The same position cached for two accounts. | Ownership is re-checked per read, so only the current owner's read counts it. |
| S5 | Keeper key compromise. | The role cannot raise any amount. Worst case: dust coordinates in caches (cap and read-gas pressure; see S13 for what a FULL cache does). The Council revokes the role; owners keep `clearAccount`. |
| S6 | A caller removes a live position (under-report). | `removeFor` requires definitive death from a successful protocol read (per member, below). A reverting read never counts as dead. |
| S7 | Read-gas DoS through many coordinates. | Unchanged cap of 256 per account, per-coordinate gas stipend, and `CoordinateGasExhausted` on a starved coordinate (never a silent partial total). |
| S8 | New mutable state in an "immutable" adapter. | The only admin power is granting / revoking `SUBMITTER_ROLE`. No amounts, no configuration, no upgrade. An extension of the ADR 0015 coordinate-cache exception, not a new kind. |
| S9 | Preview abuse with caller-supplied coordinates. | Same length, dedup, cap and ownership validation as a submit, fail-loud; StakeWise's vault-registry check happens in validation (the valuation alone would call any vault address), so validation is mandatory, not optional. View-only, never on the NAV path. |
| S10 | Gap after the swap (new caches start empty). | Seed the new adapters with `submitForBatch` before the timelock executes the swap, and again right before execution. |
| S11 | Completeness for Assistant users (the roles-level half). | Holds only if the Safes' roles allow-list points at the **new** Assistants before the swap. Outside this repo; a deployment prerequisite. The keeper becomes a second, off-chain completeness source for positions not opened through an Assistant. |
| S12 | Entries that can never be removed keep cap slots. | ether.fi: an invalidated request the owner still holds becomes owner-removable. `removeFor` stays strict: invalidation is reversible. |
| S13 | Anyone can create a position *owned by* a victim (`requestWithdraw(recipient)`, `enterExitQueue(receiver)`, `depositTo(destination)`); an honest keeper that submits everything it discovers would fill the victim's cache with dust. At the 256 cap the cache rejects new entries, and because the Assistants' own `submit` is not caught, the Safe's Assistant path (withdraw request / exit-queue entry / staking deposit) then REVERTS until the owner runs `clearAccount`. | Keeper policy, off-chain: submit only positions the account itself executed (the creating transaction's receipt carries a Safe `ExecutionSuccess` / `ExecutionFromModuleSuccess` log emitted by the account — true for its own transactions, Zodiac Roles module executions and the Assistant path), only for allow-listed client Safes, and never fill an account past a headroom below the cap. `seed_assisted.py` enforces the provenance rule. Contract escape hatch: the owner's `clearAccount` plus re-submit. Residual: under-report, read cost, and a blocked Assistant path until `clearAccount`; never over-report. |
| S14 | Reentrancy, including read-only. | Every protocol call in validation and valuation is a `view` interface call (STATICCALL). `submitFor` / `removeFor` make no state-changing external call. |
| S15 | Double count while both the old and the new adapter are registered. | The swap is ONE timelock operation (`removeBalanceAdapters([old])` + `addBalanceAdapters([new])`), never two. If ever split, remove first. |

### Definitive death, per member (`removeFor`)

- **ether.fi:** `ownerOf(id)` succeeds with an owner other than `account`, or `ownerOf` reverts (burned) AND
  `getRequest(id)` succeeds with a zeroed request (a claim burns the NFT and deletes the request). A request
  `account` still owns is never dead; `isValid == false` is not death.
- **StakeWise:** `getExitQueueIndex` and `calculateExitedAssets` both succeed and return all zeros
  (`leftTickets`, `exitedTickets`, `exitedAssets`) — StakeWise's reply when no request exists under
  `(account, timestamp, ticket)`.
- **Nexus Mutual:** `tokenInfo(id)` succeeds with an owner other than `account`, or it succeeds with `account` as
  owner and `getTokens` succeeds with zero active stake, expired stake and rewards. A `tokenInfo` revert is not death.

## Rollout (per chain: 1, and 100 for StakeWise)

1. Deploy the three adapters and their Assistants (`04`, admin = the chain's Security Council). Verify on every explorer.
2. Ops move the Safes' roles allow-list to the NEW Assistants (S11). The new caches fill while unregistered (NAV-neutral).
3. In ONE Council Safe transaction: `grantRole(SUBMITTER_ROLE, keeper)` on each new adapter, and schedule the swap on
   the NAV timelock as ONE operation (`removeBalanceAdapters([old…]) + addBalanceAdapters([new…])`, S15).
4. Seed: `script/deploy/preflight/seed_assisted.py` per member → the keeper sends each `submitForBatch` chunk.
   A chunk is all-or-nothing, so keep chunks small and re-run the script right before sending.
5. Re-seed right before the timelock delay ends; anyone executes the swap; check the NAV per account before vs after.

## Consequences

- New contracts: the three adapters and their Assistants are redeployed (Assistants pin `ADAPTER`), then swapped on
  the NAV through the timelock. The Safes' roles allow-list must move to the new Assistants (outside this repo).
- A privileged key appears in a family that had none. It protects which positions occupy the cache, never their
  value. Liveness depends on it only for positions not opened through an Assistant.
- `type(IAssistedBalanceAdapter).interfaceId` changes; no on-chain consumer reads it.
- ADR 0018's "no roles, no `IAccessControl`" statement is superseded on that point only; its delegatecall
  Assistant design and the roles-level completeness argument stand.
