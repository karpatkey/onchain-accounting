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
  The branch further binds the withdrawal to the genuine messenger (`withdrawalTx.target == l1MessengerForL2[l2ChainId]`,
  so the `successfulMessages` flag isn't read from an attacker-authored target) and, for ETH, binds the delivered amount
  (`withdrawalTx.value >= amount` — the portal delivers `value` to the adapter), matching the normal branch's delta
  guard.
- **Keys derived on-chain, not operator-supplied.** `proveWithdrawal` takes the encoded invoice `messagePayload` and
  derives both keys on-chain — `invoiceId = data.invoiceId`, `invoiceHash = bytes32(uint256(uint192(data.checksum24)))`,
  the exact derivation `_completeBridge` uses. This removes the operator-supplied-key class entirely: a caller cannot
  file the stored `WithdrawalTransaction` under a typo'd/mismatched hash that overwrites another operation's tx (which
  would let that operation mis-settle without self-detecting). New selector `0x98011b26`.
- **Configurable L1 id.** `chainId == l1ChainId` (an init argument, not `block.chainid == 1`) selects the L1 role, so
  the adapter works on any L1 host; L1 mode fails closed if given L2-only contracts.
- **CREATE2 initializer pinned independent of `DEPLOY_ADMIN`.** `05` bakes the adapter's anti-front-run
  `expectedInitializer` (ADR 0021 §3) into the CREATE2 creation code, so the deterministic address depends on it. It is
  now the committed, cross-chain-identical `DeploySalts.BRIDGE_ADAPTER_INITIALIZER` (not the `DEPLOY_ADMIN`-overridable
  `chainConfig.admin`), and `05` asserts the broadcaster equals it — so a runtime role override can no longer diverge
  the adapter address across chains and silently break the same-address invariant (Superchain sibling / CCTP recipient /
  `trustedRemoteAdapter`). `DEPLOY_ADMIN` still overrides only the post-init admin *role*.

## Consequences

- The withdrawal path is correct against the real fault-proof portals; fork tests assert the adapter decodes the live
  OP + Base portals without reverting and that deposits route through the real per-L2 messengers.
- Operators supply the dispute-game index + the invoice `messagePayload` at prove time (both keys are derived on-chain
  from the payload, so there is no operator-supplied-key to mis-set); broadcast every bridge-adapter deploy from
  `DeploySalts.BRIDGE_ADAPTER_INITIALIZER` (a single global EOA — changing it shifts all adapter addresses); and wire
  `l1MessengerForL2` for every L2 the adapter serves in **either** direction (deposit destination *and* withdrawal
  source), since the finalize skip-branch binds the withdrawal target to it — a portal-only config reverts
  `MessengerNotConfigured` on a front-run completion. The `05` deploy seeds portal + messenger index-aligned.
- **Deploy gate:** the fault-proof finalize cannot be fully fork-e2e'd (it needs a real proven + dispute-resolved +
  air-gapped withdrawal to the adapter), so the Superchain lane stays do-not-deploy until a real L2→L1 finalize is
  exercised end-to-end on the throwaway. Augments [ADR 0021](0021-bridge-adapter-provenance-and-deploy-hardening.md)
  and [ADR 0024](0024-bridge-destination-hold-then-claim.md); does not supersede them.
- **Known residual (deferred to that e2e):** the already-finalized (front-run) branch binds the ETH *amount* via
  `withdrawalTx.value` and rejects a *failed* relay via `successfulMessages`, but does **not** bind the withdrawal's
  inner **recipient** (nor the ERC20 amount) to this adapter — those live inside the relayMessage→`finalizeBridge{ETH,ERC20}`
  calldata (`to`, and for ERC20 the amount, with `value == 0`), and `successfulMessages` proves the relay reached its
  *encoded* recipient, not necessarily this adapter. Decoding them on-chain is OP-version-brittle and unverifiable on a
  fork without a real proven withdrawal. Consequence (super-review Low, CONFIRMED): a MANAGER mis-pairing an invoice to a
  genuine third-party-paying withdrawal, while the adapter holds another invoice's funds, could settle it from those
  funds (cross-invoice **misallocation**, not exfiltration). Bounded: MANAGER-gated, no theft, one-shot, and only the
  front-run branch (the normal branch's measured balance delta binds delivery). Superchain is ETH-primary + ERC20
  deposits fail-closed; the recipient/ERC20 binding is validated at the real L2→L1 e2e before the lane deploys.
