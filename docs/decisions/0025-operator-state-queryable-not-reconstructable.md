# 0025 — Operator state must be queryable, not reconstructable (held-invoice enumeration + stored withdrawal tx)

**Status:** accepted — implemented in PR #154. Augments [ADR 0024](0024-bridge-destination-hold-then-claim.md) (hold-then-claim) and [ADR 0021](0021-bridge-adapter-provenance-and-deploy-hardening.md) (Superchain provenance/deploy); supersedes neither.

## Context

Under hold-then-claim (ADR 0024) the off-chain settlement operator must, every cycle, answer two questions on
the destination side:

1. **Which delivered invoices are still unclaimed for an account?** — to build the `claim` batch.
2. **What is the exact `WithdrawalTransaction` for an already-proven Superchain L2→L1 withdrawal?** — to
   `finalize` it after the ~7-day challenge window.

Neither is answerable from a single on-chain read. The escrow's destination reads are all **hash-keyed**
(`destinationCustody(hash)`, `isInvoiceCompleted(hash)`) or **totals** (`getHeldBalanceForAsset`,
`getHeldBalancesForAccount`) — there is **no enumeration of held invoice hashes** (`getActiveInvoices` covers
only the *source* side, and a delivered invoice's `getInvoice` is empty on the destination). And
`SuperchainBridgeAdapter` stores the withdrawal *hash* (`invoiceToWithdrawalHash`) but not the
`WithdrawalTransaction` struct that `finalize` needs.

So the operator had to **reconstruct** both from event logs — walking `DeliveryRecorded` back over a bounded
block window to find held invoices, and re-deriving the withdrawal tx from the source L2 `MessagePassed` log
over a >7-day horizon. That "a bounded window reconstructing state that outlives it" pattern was the root cause
of **four separate keeper bugs** (a page cap that was a horizon in disguise; a search floor shorter than the
finality window; each fix leaving a smaller version behind). The sharp edge that makes it dangerous rather than
merely slow: an invoice can be **delivered, marked-complete on the source, yet still unclaimed** in destination
custody — at which point it is gone from `getActiveInvoices` and its **only** on-chain trace is an event log, so
a too-short window makes held funds silently invisible, never settled.

This is a **read-surface gap**, not a correctness bug (the accounting and invariants I1–I7 hold). Storing
enumerable lists on-chain costs gas on every write, and "index the events off-chain" is a standard, defensible
v1 tradeoff — but here it pushed a fragile, safety-relevant reconstruction onto the operator, and the operator
kept getting it subtly wrong.

## Decision

Make the operator's state **queryable, not reconstructable** — two small, precedented additions:

- **`BridgeEscrow`:** maintain a per-account enumerable set of held (delivered-but-unclaimed) invoice hashes,
  exposed by **`getHeldInvoices(address account) → bytes32[]`**. A hash is added on `recordDelivery` and removed
  on `_claim` — the only path that clears held custody. The set mirrors the existing source-side
  `_activeInvoices`/`_activeInvoicesSet` swap-pop machinery exactly. Invariant: `getHeldInvoices(account)` equals
  precisely the `destinationCustody` records for `account` with `amount > 0 && !claimed`.
- **`SuperchainBridgeAdapter`:** store the full `Types.WithdrawalTransaction` at prove time keyed by invoice id,
  exposed by **`getWithdrawalTransaction(bytes32 invoiceId)`** (an explicit struct getter — the backing mapping is
  `private` because a `public` auto-getter silently drops the struct's dynamic `data` member).

The operator then discovers claimable invoices in one call and finalizes without any historical log access.

## Consequences

- **The bounded-window bug class becomes unrepresentable** for the two reconstruction paths: the keeper deletes
  its `DeliveryRecorded` log-scan (and the associated page/window guards + the "unaccounted held" tripwire) and
  its `MessagePassed` re-read for finalize. (The first-time *prove* leg and the CCTP burn-attestation scan still
  read logs — those windows are short and stay.)
- **Modest, bounded gas cost on infrequent paths:** one extra set write on `recordDelivery` and on `claim`; one
  struct store on `proveWithdrawal`. No hot-path cost; `getHeldInvoices` shares the same (per-account, drained on
  claim) bound as the long-shipped `getActiveInvoices`, so it introduces no new DoS surface.
- **Storage:** `BridgeEscrow`'s two new mappings consume 2 slots — the upgrade gap shrinks `_gap[47] → _gap[45]`,
  keeping UUPS upgrades of the live proxy layout-safe. `SuperchainBridgeAdapter` is non-upgradeable (fresh CREATE2
  deploy), so no gap concern.
- **No operator/roles change:** both additions are views or writes inside already-`MANAGER`-scoped functions
  (`recordDelivery` is adapter-only; `claim`/`proveWithdrawal` already gated). The settlement selector set the
  Zodiac Roles Modifier scopes is unchanged.
- **Cross-repo sequencing:** the helper-bearing escrow/adapter must be deployed before the keeper relies on the
  fast path. The keeper keeps a fallback so it tolerates a helper-less escrow during rollout and flips per-chain.
- **Principle, going forward:** any state an operator must act on should be exposed as a first-class read, not
  left to off-chain reconstruction over a window that can outlive the state.
