# 0026 — Superchain adapter: fault-proof (OP2) reconciliation + per-L2 messengers

Status: accepted (PR #154)

## Context

`SuperchainBridgeAdapter`'s L2→L1 withdrawal path was written against the **legacy pre-fault-proof
`OptimismPortal`**: a single-key `provenWithdrawals(bytes32) → bool` proven check and a `proveWithdrawalTransaction`
that passed an `l2OutputIndex`. On-chain ground truth (verified with `cast` against the live mainnet portals) shows
both the OP (`v5.6.1`) and Base (`v5.2.0`) portals are the **fault-proof system (OptimismPortal2)**, where:

- `provenWithdrawals(bytes32 withdrawalHash, address proofSubmitter) → (address disputeGameProxy, uint64 timestamp)`
  — keyed by `(hash, submitter)`, proven ⟺ `disputeGameProxy != 0`. The legacy single-key getter **reverts**.
- proving takes a **dispute-game index**, not an L2 output index.
- `finalizeWithdrawalTransaction(tx)` uses `msg.sender` as the proof submitter and internally enforces
  proof-maturity + dispute-game resolution + the finality air-gap.

So the withdrawal path could **never complete on today's chains**. The gap survived because the tests mocked the
legacy shape — only a fork test against the live portal is authoritative. Two further issues surfaced in the same
whole-file re-audit: the L1→L2 deposit-completion message used a **single `l1Messenger`** although the one L1 adapter
serves multiple L2s whose L1CrossDomainMessengers differ (OP `0x25ace7…`, Base `0x866E82a6…`); and the front-run
idempotency branch could settle from stray funds / be reused because the messenger's delivery flag is permanent.

## Decision

Reconcile the adapter to the fault-proof portals and ground every fix in fork tests against the live contracts:

- **Proven check** = `provenWithdrawals(hash, address(this)).disputeGameProxy != 0` (the adapter is the proof
  submitter). `proveWithdrawal`'s second argument is the dispute-game index. Finalize defers maturity /
  resolution / air-gap to the portal; the adapter keeps only proven-check → idempotent finalize → delivered-amount
  binding.
- **Per-L2 messengers.** `l1MessengerForL2[l2ChainId]` (+ setter) routes the authenticated `completeDeposit` message
  through the *destination* L2's L1CrossDomainMessenger; the single `l1Messenger` stays only as the inbound L2 identity
  for `_authenticateMessengerSource`. A dedicated `completeDepositGasLimit` (500k) sizes that relay.
- **Delivery-bound, one-shot finalize.** The already-finalized (front-run) branch requires the destination
  messenger's `successfulMessages(keccak256(withdrawalTx.data))` (the v1 versioned hash equals the relayMessage
  calldata the portal delivered) to confirm the relay actually paid this adapter, and a per-withdrawal-hash
  consumption guard makes settlement one-shot — so a withdrawal filed under two invoice hashes cannot settle twice.
- **Configurable L1 id.** `chainId == l1ChainId` (an init argument, not `block.chainid == 1`) selects the L1 role, so
  the adapter works on any L1 host; L1 mode fails closed if given L2-only contracts.

## Consequences

- The withdrawal path is correct against the real fault-proof portals; fork tests assert the adapter decodes the live
  OP + Base portals without reverting and that deposits route through the real per-L2 messengers.
- Operators must supply the dispute-game index at prove time and wire `l1MessengerForL2` per L2.
- **Deploy gate:** the fault-proof finalize cannot be fully fork-e2e'd (it needs a real proven + dispute-resolved +
  air-gapped withdrawal to the adapter), so the Superchain lane stays do-not-deploy until a real L2→L1 finalize is
  exercised end-to-end on the throwaway. Augments [ADR 0021](0021-bridge-adapter-provenance-and-deploy-hardening.md)
  and [ADR 0024](0024-bridge-destination-hold-then-claim.md); does not supersede them.
