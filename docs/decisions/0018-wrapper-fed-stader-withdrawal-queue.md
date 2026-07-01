# 0018 — Wrapper-fed Stader withdrawal-queue adapter (`SUBMITTER_ROLE`, delegatecalled claim)

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
caught by NAVCalculator's try/catch). A `SUBMITTER_ROLE`-gated cache counts only requests a trusted wrapper actually
created for that account, removing the grief vector and keeping the read gas-bounded.

### The Stader-specific constraint (why the claim is delegatecalled)

Verified against the live mainnet contract (`UserWithdrawalManager` `0x9F0491…93A7`, impl `0x678f0d5…`):

- `requestWithdraw(uint256 _ethXAmount, address _owner)` pulls `_ethXAmount` ETHx from `msg.sender` and records the
  request owned by `_owner`.
- `claim(uint256 _requestId)` does `if (msg.sender != userRequest.owner) revert CallerNotAuthorizedToRedeem();` and
  sends the ETH **to `userRequest.owner`**. **There is no permissionless claim-on-behalf.**

This is the same shape as ether.fi's owner-only claim: a `SUBMITTER_ROLE` wrapper contract can never be the request
owner *and* the tracked account at once without either owning every depositor's request (which breaks per-account
ownership re-verification) or being able to claim a request it does not own (which the protocol forbids). Delegatecall
cannot be bridged around this — running the wrapper's code under delegatecall executes in the caller's storage (breaking
the wrapper's own roles) and does not change what the *manager* sees as `msg.sender`.

## Decision

Replace the plain enumerating `StaderWithdrawalQueueBalanceAdapter` with a **wrapper-fed** adapter of the same name, plus
a `StaderWithdrawalQueueWrapper`. Same trust model and family invariant as ADR 0015 (cache coordinates only, value live,
re-verify ownership per read → the feeder can only under-report), fed by an **on-chain contract holding
`SUBMITTER_ROLE`**, with an **incremental** single add/remove submit surface. Both contracts are single, self-contained
files (the shared `WrapperFed*` bases are intentionally deferred — see Consequences).

- **`StaderWithdrawalQueueBalanceAdapter`** — `AccessControl` (`DEFAULT_ADMIN_ROLE` administers `SUBMITTER_ROLE`) +
  the single-asset getter triad (WETH) + an `EnumerableSet.UintSet`-per-account request-id cache. `submit(account,
  requestId)` is `onlyRole(SUBMITTER_ROLE)` (fail-loud `NotTokenOwner` / `TokenIdCacheFull`); an admin `clearAccount`
  rescues a mis-fed account; and a **permissionless `remove(account, requestId)`** drops an id **only if** it is
  provably no longer owned by the account (claimed → the manager deletes the request, so its owner reads back as
  `address(0)`) — it can only ever remove a dead entry, never a live position. Valuation is unchanged from the plain
  adapter (`ethFinalized` once finalized, else the
  rate-converted `ethExpected`; `isLocked = !finalized`), emitting one `Supplied` leg per owned cached request under the
  static `positionId = abi.encode(USER_WITHDRAWAL_MANAGER)`, with the request id in the typed `positionInstanceId`.
- **`StaderWithdrawalQueueWrapper`** — a **permissionless** forwarder (no roles, holds no funds) used in **two execution
  modes**:
  - `requestWithdraw(_ethXAmount, _owner)` — a **normal CALL**. Pulls the exact ETHx from the caller, `forceApprove`s
    it to the manager, forwards to `requestWithdraw(_ethXAmount, _owner = msg.sender)` (so the request is owned by the
    caller, matching the adapter's ownership re-verification), and `submit`s the returned `requestId` for the caller.
    `_owner` is pinned to `msg.sender` to keep Stader's exact signature while ensuring a permissionless caller can only
    ever affect its own cache entry — it cannot create a request owned by / tracked for a third party (no victim
    cache-bloat).
  - `claim(_requestId)` — **DELEGATECALLed by the owning Safe**, so `msg.sender` seen by the manager is the Safe
    (== owner) and the ETH flows straight to the Safe. Immutables are readable under delegatecall; the function takes no
    role guard and touches no wrapper storage (both would be the Safe's under delegatecall). It cleans the cache via the
    adapter's permissionless `remove(address(this), _requestId)` — which succeeds only because the claim just
    deleted the request.

## Consequences

- The plain enumerating adapter is **removed** (not kept alongside): the wrapper-fed path is strictly the safer source
  of the same positions, and the grief vector on the enumerating version is a real reason not to leave it registered.
- The wrapper is deliberately dual-mode: **CALL** `requestWithdraw`, **DELEGATECALL** `claim`. karpatkey Zodiac Roles
  can be configured per-function accordingly. A direct CALL to `claim` by a non-owner fails safe (reverts inside the
  manager with `CallerNotAuthorizedToRedeem`). **EOA callers cannot use the delegatecalled claim** (an EOA cannot
  delegatecall) — they claim directly on Stader; the intended claimers are Safe/Avatar accounts.
- On-claim cache cleanup relies on the permissionless, provably-stale-only `remove` rather than a `SUBMITTER_ROLE`
  `remove`, because the claim runs outside the wrapper's role context. NAV correctness never depends on it — the adapter
  re-verifies ownership per read, so a claimed id already values to 0.
- The wrapper-fed adapter remains a documented immutability exception (assisted family), expressed through
  `SUBMITTER_ROLE`. The family invariant is unchanged, so the safety argument (feeder can only under-report) carries
  over verbatim.
- **Deploy/config wiring is deferred** to a follow-up. When wired: deploy the adapter (`submitter = address(0)`) → deploy
  the wrapper (needs the adapter address) → admin `grantRole(SUBMITTER_ROLE, wrapper)` → register the adapter on
  `NAVCalculator`. The wrapper itself is permissionless, so there are no depositor roles to grant. The deploy script
  (`04_DeployBalanceAdapters`) already constructs the adapter
  with `admin = chainConfig.admin` and `submitter = address(0)`.
- The shared `WrapperFed*` bases (`IWrapperFedBalanceAdapter` / `WrapperFedBalanceAdapter` / `WrapperFedNftCacheAdapter`)
  introduced by the ether.fi and Nexus wrapper-fed work are intentionally **not** used here — this PR keeps one
  self-contained contract per concern per the request ("abstract stuff later"). When those bases land on `main`, this
  adapter should be reconciled onto them (its `SUBMITTER_ROLE` maps to that family's `WRAPPER_ROLE`).
