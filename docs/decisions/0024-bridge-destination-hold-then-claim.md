# 0024 — Bridge destination: hold-then-claim (escrow custody + explicit `claim`)

**Status:** proposed (supersedes the destination-release half of [ADR 0012](0012-bridge-provable-release-rearchitecture.md); several parameters below are open and flagged for sign-off)

## Context

Under ADR 0012 ("funded pass-through") the destination completion is a single atomic step: an authorized
adapter authenticates the inbound protocol message and calls `BridgeEscrow.releaseByInvoiceId(payload)`,
supplying the exact funds in the same call; the escrow forwards them **straight to the account** and never
holds a standing balance. Safety props H2 ("one invoice can never be funded by another's tokens") and H9 ("a
release cannot drain pre-existing funds") rest structurally on *the escrow holding no balance*.

That design gives us **no control over *when* funds enter the safe** on the auto-completing routes
(Across / CCIP / Stargate, and Gnosis ETH→GC): the bridge itself triggers the adapter callback, which
releases to the safe in the same transaction, on the bridge's own schedule. Consequences:

- **NAV correctness.** The safe's balance can change at an arbitrary block outside our control. Even a
  keeper watching the delivery event reacts several blocks late, so there is a window where NAV is wrong
  (the value is neither cleanly "in transit" nor cleanly "in the safe" for the consumer).
- **Non-uniform completion.** Auto routes release without any of our transactions; manual routes
  (CCTP / Superchain L2→L1 / Gnosis GC→ETH) require a keeper. Each bridge behaves differently at the finish.

We want the destination to **hold** the delivered funds and release them to the safe only via an explicit,
**uniform** `claim` — so we control the exact block value transitions into the safe, and every bridge
finishes the same way. This deliberately reintroduces a "destination custody record" that ADR 0012's
implementation notes recorded as *considered and dropped* (funded pass-through made it unnecessary); the
justification for reversing that is precisely the NAV-timing-control + uniform-completion requirement, which
funded pass-through cannot provide.

## Decision

Keep every **adapter as the authenticated recipient exactly as today** — all per-protocol provenance
(the bridge is the real protocol contract, the source is a `trustedRemoteAdapter`, token+amount match the
invoice) stays where it is proven. Change only the **final step**:

1. **`recordDelivery` (replaces the destination role of `releaseByInvoiceId`).** After authenticating, the
   adapter hands the delivered funds to the escrow, which **measures the balance-delta actually received**,
   writes a **per-invoice destination custody record**, and **holds the funds**. It does *not* pay the
   account.
2. **`claim(invoiceHash)` (new, uniform).** Moves a held delivery from the escrow to the account recorded in
   the custody record — and to no one else. This is the single completion surface for all six bridges.

Because every completion route in all six adapters funnels through one base helper
`BridgeAdapter._fundAndRelease`, the adapter-layer change is a **single retarget** of that helper's escrow
call (`releaseByInvoiceId` → `recordDelivery`), inherited by all six adapters and by both the auto-callback
and MANAGER `completeBridge` paths — no per-adapter logic changes. This also, for the first time, gates the
Gnosis ETH→GC auto path (today the one route that auto-delivers to the safe with zero control).

### Custody state (`BridgeEscrow`)

```solidity
struct DestinationCustody {
    address account;     // authenticated payee from the invoice; claim pays ONLY this
    address asset;       // resolved at delivery; claim does not re-resolve the registry
    uint256 amount;      // MEASURED balance-delta received (fee-on-transfer / Stargate post-fee safe)
    address adapter;     // msg.sender at recordDelivery — provenance stamp
    uint64  deliveredAt; // audit + optional min-hold / NAV snapshot alignment
    bool    claimed;     // false = held; true = moved to safe (terminal)
}
mapping(bytes32 invoiceHash => DestinationCustody) public destinationCustody;
mapping(address asset => uint256) private _heldClaimable;                                // Σ unclaimed per asset
mapping(address account => mapping(address asset => uint256)) private _heldByAccount;     // per-account NAV attribution
```

`recordDelivery` is adapter-only, runs the same validation as today (checksum, dest-chain, authorized
account, registered asset), replay-guards on record-existence, pulls + measures the funds (the existing
`depositAndBridge` balance-delta pattern), writes the record, and bumps the aggregates. `claim` is CEI:
require record exists and `!claimed`, flip `claimed`, decrement aggregates, transfer exactly `amount` of
`asset` to the recorded `account`.

### Invariants (replace "escrow never holds a standing balance")

- **I1 Custody conservation:** for every asset, `balanceOf(asset) >= _heldClaimable[asset]`, and
  `_heldClaimable[asset] == Σ (unclaimed records).amount == Σ_account _heldByAccount[account][asset]`.
- **I2 Delivery authenticity:** a custody record can be created *only* by `recordDelivery`, which reverts
  unless `msg.sender` is an authorized adapter. The invoice checksum is integrity/replay only, never an
  authenticator — provenance remains in the adapter (unchanged from ADR 0012).
- **I3 No double-claim:** `claimed` flips `false→true` once; aggregates decrement once.
- **I4 Claim pays only the recorded account,** exactly `amount` of the recorded `asset`; no argument redirects it.
- **I5 Cancel/claim non-interference:** source-side `cancelInvoice` (touches `invoices`/in-transit) and
  destination `claim` (touches custody) are different maps on different chains/instances — they cannot
  double-spend one balance.
- **I6 Stray funds are never claimable:** funds arriving other than via `recordDelivery` (open `receive()`,
  direct transfer, surplus above the exact pull) are in `balanceOf` but not in `_heldClaimable`; only the
  paused, recipient-restricted `emergencyWithdraw` can move them. (Hence `>=`, not `==`, in I1.)
- **I7 Recorded amount ≤ received:** `amount` is the measured delta, so claimable can never exceed what
  actually arrived, even under fee-on-transfer tokens.

I1 is the direct replacement for the old no-standing-balance property H2/H9 rested on: instead of "balance
is always 0," it is "balance always backs the sum of unclaimed records, and only those are payable."

## Alternative considered and rejected: literal "bridge recipient = escrow"

Santi's original framing was to set the destination **token recipient = escrow** in the bridge calldata and
carry the invoice in the bridge message. Rejected: on Across / CCIP / Stargate the protocol invokes its
message callback **on the token recipient itself** (single `recipient`/`receiver`/`SendParam.to` field), and
Gnosis `relayTokensAndCall` fires `onTokenTransfer` on the recipient — so making the escrow the recipient
forces the **escrow** to implement all four protocol receiver callbacks and their provenance auth (and
Across exposes no source-sender, weakening authentication; Stargate re-encodes a post-fee amount). That
re-homes the proven trust surface into the escrow for no functional gain. The decided approach achieves the
identical "hold + uniform claim + controlled timing" outcome while leaving every adapter's authentication
untouched. (Source side — `depositAndBridge`, `_bridge`, recipient = sibling adapter — is unchanged either way.)

## Consequences

- **Positive:** we control the exact block funds enter the safe (NAV stays continuous across the hop);
  completion is one uniform `claim` for every bridge; the Gnosis auto path gains gating; the adapter diff is
  one line; provenance is unchanged and re-proven by the existing fork suite.
- **Negative / cost:** the escrow now holds a standing destination balance, so H2/H9 move from a structural
  guarantee to explicit accounting (I1–I7) that must be invariant-tested; a keeper (or the account) must call
  `claim`, so delivered funds are not in the safe until claimed (they remain safe and claimable indefinitely;
  `emergencyWithdraw` is the break-glass). Manual routes still need their proof step to get funds out of the
  bridge into the escrow — only the final escrow→safe step is unified.
- **NAV hook (follow-up):** a destination getter `getHeldBalanceForAsset(asset, account)` + a
  `BridgeHeldBalanceAdapter` (`IBalanceAdapter`) lets NAV count held-but-unclaimed value. Windows **destination
  held → safe balance** are disjoint on the destination chain (`claim` is the single transition). But **source
  in-transit is NOT disjoint from destination held**: `recordDelivery` starts the held position while source
  in-transit clears only at the later `markInvoiceCompleted`, so a cross-chain NAV summing both escrows
  double-counts during that settlement gap. Closing it needs read-time netting (source `getActiveInvoices` ×
  dest `isInvoiceCompleted`) or a prompt settlement keeper — the same source-side reconciliation the
  pass-through model already required; hold-then-claim does not remove it.

## Open questions (sign-off needed — several are Santi's call)

1. **`claim` authorization:** `MANAGER`/keeper (recommended — since `claim` can only pay the recorded
   account, the gate controls *timing only*, which is the whole goal) vs account-self-claim vs permissionless
   (rejected: removes the timing control).
2. **Pause semantics for `claim`:** block `whenNotPaused` (recommended) vs allow while paused so a pause
   can't strand deliverable funds (`emergencyWithdraw` already covers the frozen case).
3. **`completedInvoices` meaning-shift:** on the destination it currently means "released to account"; under
   this design it becomes "delivered into custody." Redefine + document (recommended) vs add a separate
   `deliveredInvoices` map and reserve `completedInvoices` for claimed — affects `isInvoiceCompleted`
   consumers.
4. **Cross-chain cancel/claim residual:** ADR 0012 dropped the DISPATCHED interlock; accept operational
   mitigation (only cancel on provable bridge failure; the delivered→claim window aids detection) vs
   reintroduce a source-side interlock in this pass.
5. **Reward/dust surplus:** leave on the adapter for `recoverStuckAssets` (recommended, keeps
   `recordDelivery` exact-amount) vs pull the full delivered balance into custody.
6. **Batch `claim(bytes32[])`** for keeper gas, and an **optional min-hold** using `deliveredAt` for NAV
   snapshot alignment: include now vs defer.

## Review remediation (PR #289)

The first implementation pass shipped `claim(bytes32)` + `claim(bytes32[])`, the `BridgeHeldBalanceAdapter`,
and the invariant suite. Code review then surfaced points resolved as follows:

- **Batch `claim` is deliberately strict/all-or-nothing** (a bad hash reverts the whole batch), unlike
  `markInvoiceCompleted`'s tolerant per-item batching — because `claim` MOVES funds, so an atomic batch is
  auditable and never leaves a keeper guessing which subset settled. Keepers simulate first or fall back to
  per-hash `claim`. Documented on the function.
- **`recordDelivery` now rejects a zero-amount delivery symmetrically** for native + ERC20 (the ERC20 branch
  already reverted on `measured == 0`; native previously wrote a "completed" but permanently-unclaimable
  record). A genuine payload never has `amount == 0`; the guard is defense-in-depth.
- **`unregisterAsset` now also blocks while destination custody still holds the asset**, mirroring the
  existing source-side active-invoice guard, so held-but-claimable funds can't be hidden from `getHeldBalance*`.
- **Deploy wiring for `BridgeHeldBalanceAdapter` is a deliberate follow-up**, not part of this PR. It is not yet
  dispatched by `04_DeployBalanceAdapters` / registered by `06_Configure`, because its constructor needs the
  per-chain `BridgeEscrow` address and the hold-then-claim escrow is itself not yet in the production numbered
  deploy flow (it deploys via the separate bridge track, and this model is pre-merge). It is registered as an
  explicit step during the on-chain test campaign; the 04/06 + per-chain-config wiring lands when the
  hold-then-claim escrow is promoted to a production deploy. Tracked so it is not silently forgotten (the
  "deployed-but-never-registered" gap class).
- **`emergencyWithdraw` is capped to the surplus over held custody** (`balanceOf(asset) - _heldClaimable[asset]`),
  so a break-glass withdrawal can only move stray/surplus funds and never the funds backing outstanding
  `destinationCustody` records — I1 holds through the emergency path, held records stay claimable after unpause,
  and NAV never over-reports. Held custody is not stuck (`claim` releases it after unpause; a UUPS upgrade is
  the true last resort if the escrow must be abandoned). Both reviewers flagged the earlier
  reconciles-nothing behavior; this is the adopted fix.
