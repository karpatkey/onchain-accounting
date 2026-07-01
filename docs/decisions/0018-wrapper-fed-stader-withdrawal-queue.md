# 0018 — Self-fed Stader withdrawal-queue adapter (msg.sender-keyed cache, delegatecalled wrapper)

Status: accepted

## Context

The assisted balance-adapter family (ADR [0015](0015-assisted-balance-adapter-family.md)) covers adapters that cannot
derive a position from on-chain state cheaply/safely and instead take a trusted party's submission of position
*coordinates* (never amounts), which the adapter then values live and re-verifies per read — so the feeder can only
under-report. Stader's ETH withdrawal queue is such a case, for a subtle reason.

When a user unstakes, Stader's `UserWithdrawalManager.requestWithdraw(_ethXAmount, _owner)` burns ETHx and records a
sequential `requestId` owned by `_owner`; the queued ETH is invisible to a wallet/receipt-token scan until claimed. The
manager *does* expose `requestIdsByUserAddress(user, i)`, so the position is technically enumerable — the previous
`StaderWithdrawalQueueBalanceAdapter` did exactly that. But that enumeration is **griefable**: `requestWithdraw` lets
anyone set `_owner` to a victim, so an attacker can push junk request ids into a victim's array to bloat it past the
adapter's probe cap (making real requests beyond the cap invisible) or toward an OOG on the NAV read (which is **not**
caught by NAVCalculator's try/catch). A cache **keyed on `msg.sender`** — where an account can only ever add ids to its
*own* entry — counts only requests the account tracked for itself, removing the grief vector and keeping the read
gas-bounded, without needing any role or trusted feeder.

### The Stader-specific constraint (why the wrapper is delegatecalled)

Verified against the live mainnet contract (`UserWithdrawalManager` `0x9F0491…93A7`, impl `0x678f0d5…`):

- `requestWithdraw(uint256 _ethXAmount, address _owner)` pulls `_ethXAmount` ETHx from `msg.sender` and records the
  request owned by `_owner`.
- `claim(uint256 _requestId)` does `if (msg.sender != userRequest.owner) revert CallerNotAuthorizedToRedeem();` and
  sends the ETH **to `userRequest.owner`**. **There is no permissionless claim-on-behalf.**

Because the adapter caches per `msg.sender` and Stader's claim is owner-only, the account that owns the Stader request
must be the one that both feeds the cache and claims. The wrapper is therefore **delegatecalled by the owning Safe** for
*both* entrypoints: under delegatecall `address(this)` is the Safe, so the Safe is simultaneously the ETHx holder, the
Stader request owner, the adapter's `msg.sender`, and the ETH recipient — everything lines up on one address with no
roles and no custody. (A normal CALL can't achieve this: the wrapper would be `msg.sender`/owner, so it could neither
feed the caller's cache nor claim the caller's owner-only request.)

## Decision

Replace the plain enumerating `StaderWithdrawalQueueBalanceAdapter` with a **self-fed** adapter of the same name, plus a
`StaderWithdrawalQueueWrapper`. Same family invariant as ADR 0015 (cache coordinates only, value live, re-verify
ownership per read → the cache can only under-report), but fed by **each account itself** (`msg.sender`-keyed) rather
than by a role-holding feeder. Both contracts are single, self-contained files (the shared `WrapperFed*` bases are
intentionally deferred — see Consequences), and neither holds any role, admin, or funds.

- **`StaderWithdrawalQueueBalanceAdapter`** — the single-asset getter triad (WETH) + an `EnumerableSet.UintSet`-per-
  account request-id cache, **keyed on `msg.sender`** with no access control. `submit(requestId)` adds an id to the
  caller's own cache (fail-loud `NotTokenOwner` if the caller doesn't own it / `TokenIdCacheFull` at the cap);
  `remove(requestId)` drops an id from the caller's cache **only if** it is provably no longer owned by the caller
  (claimed → the manager deletes the request, so its owner reads back as `address(0)`) — it can only ever remove a dead
  entry, never a live position. There is no admin and no bulk clear: because only the account can grow its own cache and
  can always `remove` its own stale ids, none is needed. Valuation is unchanged from the plain adapter (`ethFinalized`
  once finalized, else the rate-converted `ethExpected`; `isLocked = !finalized`), emitting one `Supplied` leg per owned
  cached request under the static `positionId = abi.encode(USER_WITHDRAWAL_MANAGER)`, with the request id in the typed
  `positionInstanceId`.
- **`StaderWithdrawalQueueWrapper`** — a stateless, role-free helper **DELEGATECALLed by the owning Safe** for both
  entrypoints (under delegatecall `address(this)` is the Safe; the immutables are read from the wrapper's bytecode):
  - `requestWithdraw(_ethXAmount, _owner)` — `forceApprove`s the manager for the ETHx (from the Safe, which holds it —
    no `transferFrom` from a separate depositor), forwards to `requestWithdraw(_ethXAmount, _owner)`, and `submit`s the
    returned `requestId` (cached for `msg.sender` == the Safe). `_owner` mirrors Stader's signature and is pinned to
    `address(this)` (the Safe), so the request owner, the tracked account, and the adapter's `msg.sender` are all the
    same Safe.
  - `claim(_requestId)` — forwards to `claim` (`msg.sender` == the Safe == owner ✓, ETH to the Safe) and calls the
    adapter's `remove(_requestId)` to drop the now-deleted (provably-stale) id from the Safe's cache.

## Consequences

- The plain enumerating adapter is **removed** (not kept alongside): the self-fed path is strictly the safer source of
  the same positions, and the grief vector on the enumerating version is a real reason not to leave it registered.
- Both wrapper entrypoints are **DELEGATECALL-only**. karpatkey Zodiac Roles configure the Safe to delegatecall the
  wrapper per-function. Invoked as a normal CALL each fails safe: `requestWithdraw` requires `_owner == address(this)`
  (the wrapper) and then reverts pulling ETHx from the fund-less wrapper; `claim` forwards with `msg.sender == wrapper
  != owner` and reverts inside the manager (`CallerNotAuthorizedToRedeem`). **EOAs cannot delegatecall**, so the
  intended callers are Safe/Avatar accounts (an EOA would use Stader directly).
- The cache needs **no role and no admin**: it is keyed on `msg.sender`, so an account can only add ids it owns to its
  own entry, and `remove` only ever drops the caller's own provably-stale ids. NAV correctness never depends on `remove`
  — the adapter re-verifies ownership per read, so a claimed id already values to 0 whether or not it's been removed.
- The adapter remains a documented immutability exception (assisted family): it stores per-account coordinates rather
  than deriving them purely from a view. The family invariant is unchanged (can only under-report), now enforced by
  `msg.sender`-keying instead of a role.
- **Deploy/config wiring is deferred** to a follow-up. When wired: deploy the adapter → deploy the wrapper (needs the
  adapter address) → register the adapter on `NAVCalculator`. There are no roles to grant on either contract; accounts
  feed the cache by delegatecalling the wrapper. The deploy script (`04_DeployBalanceAdapters`) constructs the adapter
  with the original `(userWithdrawalManager, underlyingToken, navCalculator)` signature.
- The shared `WrapperFed*` bases (`IWrapperFedBalanceAdapter` / `WrapperFedBalanceAdapter` / `WrapperFedNftCacheAdapter`)
  introduced by the ether.fi and Nexus wrapper-fed work are intentionally **not** used here — this PR keeps one
  self-contained contract per concern per the request ("abstract stuff later"). Those use a `WRAPPER_ROLE` feeder; this
  adapter's `msg.sender`-keyed model is a different (role-free) point in the same design space.
