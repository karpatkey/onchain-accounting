# Vigilo Audit — Remediation Triage

**Date:** 2026-06-27
**Companion to:** [`2026-06-vigilo-automated-audit.md`](2026-06-vigilo-automated-audit.md) (findings) — read that first.
**Scope of this doc:** disposition of every audit finding — what was fixed in code, and what was deliberately *not* (with the reason).

The audit report already discounted 8 of 9 raw "Highs" via adversarial verification. Closer code reading during remediation refuted several more Mediums outright. The net code change is a small, high-confidence bridge-hardening set; the remainder are either already-defended, invalid on inspection, operational, or valuation-semantics changes that need product sign-off + integration-snapshot regeneration.

---

## Fixed in this PR

| ID | Finding | Change | Test |
|---|---|---|---|
| **M-12a** | `completeBridge` lacks `nonReentrant` (only completion entrypoint without it) | Added `nonReentrant` to `BridgeAdapter.completeBridge` | covered by existing `test/bridge/**` (219 pass) |
| **M-12b** | `depositAndBridge` leaves a residual adapter approval | Reset ERC20 allowance to 0 after `adapter.bridge()` in `BridgeEscrow.depositAndBridge` (mirrors `_fundAndRelease`'s approve→use→reset) | `test_depositAndBridge_resetsAdapterAllowance` |
| **M-10b** | `revokeAdapter` has no active-invoice guard (asymmetric with `revokeAccount`) | Added `_hasActiveInvoicesForAdapter` guard + `AdapterHasActiveInvoices` error; revoke now reverts while the adapter has in-flight (BRIDGING) invoices | `test_revokeAdapter_revertsWithActiveInvoices`, `test_revokeAdapter_succeedsAfterInvoiceCompleted` |

All bridge unit tests pass (`forge test --match-path "test/bridge/**"` → 219, plus 3 new). No NAV/price/balance code touched, so integration snapshots are unaffected.

---

## Refuted on closer inspection (no change — finding does not hold)

| ID | Finding | Why no change |
|---|---|---|
| **M-8** | `answeredInRound` not checked → incomplete Chainlink round passes staleness gate | A round with `updatedAt == 0` already fails the heartbeat gate: `block.timestamp - min(0, …) ≥ heartbeat` is always true → feed skipped (`PriceFeedLib.sol:131-133`). `answeredInRound` is legacy/unset on modern OCR feeds; adding it risks rejecting healthy feeds for no gain. |
| **M-10e** | CCTP marks `usedNonces` before `receiveMessage` → invoice bricks on revert | EVM reverts are atomic across contracts: if `_fundAndRelease` reverts, Circle's `receiveMessage` state change reverts in the **same** transaction. No cross-tx stranding is possible (`CctpBridgeAdapter.sol:212-221`). |
| **M-14** | Deploy script 07 doesn't strip deployer admin from the 3 assisted adapters | The assisted adapters are constructed with `chainConfig.admin` (the OIV Safe) as admin — **not** the deployer EOA (`04_DeployBalanceAdapters.s.sol:721,746,788`). The deployer never holds a role on them; nothing to strip. |
| **H-1** (partial) | Superchain single L1 adapter ↔ dual-L2 confusion | The L1 withdrawal-completion path is **portal-bound**: `optimismPortal` is a single L2-specific contract that verifies proofs against that L2's output root, so it cannot finalize the other L2's withdrawals. The L2→L1-deposit path only ever has L1 as a source. A `setTrustedRemoteAdapter` guard would also break the *legitimate* multi-remote wiring shared with Across/CCIP. → handled operationally (see below), not in code. |

(The original "High" front-run findings — proxy `initialize`, SafeCast DoS, sUSDe share-unit — were already refuted in the audit report's "Refuted / already-fixed" section.)

---

## Deferred — need product sign-off and/or integration-snapshot regeneration

These are **legitimate accuracy improvements** but they change reported NAV/valuation, so they require a maintainer decision on the intended semantics and a refreshed integration snapshot (`script/test/refresh-integration-snapshot.sh`). They are intentionally *not* bundled into this hardening PR.

| ID | Finding | Decision needed |
|---|---|---|
| **M-2** | LST/keeper feeds lack rate-reasonableness / freshness bounds (ankrETH `ratio()`, ezETH_L2 keeper rate, ezETH `calculateTVLs`) | Choose bound values / which feeds get a freshness gate. Most underlying rates are live-computed (no timestamp), so "staleness" only applies to keeper/bridged rates. |
| **M-4** | ERC4626 valuation uses `convertToAssets` (ignores redeem fee) instead of `previewRedeem` | Confirm intended valuation basis (NAV vs exit-value). Identical for current fee-less vaults; switching changes value only if a vault adds a redeem fee. |
| **M-5** | NAV double-count when a wrapper is registered in both a wrap adapter and a direct feed | Decide whether to add a registration-time invariant on `NAVCalculator` (risks rejecting valid configs) vs. keep the existing config-level discipline (RWIV already disabled manually). |
| **M-6** | Lido withdrawal queue overstates non-finalized requests after a negative rebase | Confirm the cap formula (mirror Lido's finalization share-rate cap) and regenerate snapshots. |
| **M-7** | Convex CVX rewards overstated by time-of-check cliff | Accept as documented upper-bound estimate vs. apply a conservative cliff margin. |
| **M-9** | Stale asset price silently zeroed with no per-asset stale flag in the verbose response | Interface change to `Position`/verbose NAV — coordinate with downstream consumers. |
| **M-15** | Cap adapter per-leg vs combined burn-quote inconsistency | Confirm the fee model (proportional vs fixed) before changing the quote path. |

---

## Deferred — operational / process (no code change is the correct fix)

| ID | Finding | Action owner |
|---|---|---|
| **H-1** | Superchain dual-L2 | **Deploy a separate L1 `SuperchainBridgeAdapter` instance per L2** (distinct CREATE2 salt), each wired to exactly one portal/messenger. This is the documented design intent; the portal binding already prevents fund loss if it is ever misconfigured. Track in the deploy runbook. |
| **M-1** | Across source-auth weakness / MANAGER path trusts caller-supplied source chain | The planned **adapter-provenance follow-up PR** (referenced in `BridgeAdapter`/`BridgeEscrow` NatSpec and ADR 0012) is the real fix. Trust-bounded today (requires compromised MANAGER; bounded by funded pass-through + authorized-account allowlist). |
| **M-10a/c/d**, **M-11** | `cancelInvoice` ERC20 refund path; CCIP over-delivery surplus; Stargate post-fee checksum; Gnosis MANAGER-path AMB context | Entangled with the cross-chain in-flight recovery model — needs maintainer intent on the intended recovery flow before changing. Documented for the bridge-provenance follow-up. |
| **M-13** | Balancer V2/V3 read-only reentrancy on valuation reads | Add the Balancer Vault reentrancy guard (`ensureNotInVaultContext`) before pool reads; deferred as it touches an immutable meta-adapter and warrants its own focused PR + fork test. |

---

## Lows

Deferred as a batch (defense-in-depth / footguns): two-step admin on non-upgradeable adapters, widen the 192-bit replay key to 256-bit (already 2^192-safe), feed-registration price-sanity validation, register-asset TOCTOU, CCTP balance preflight, bridge-adapter `initialize` front-run griefing (funds safe; redeploy via salt bump). None is a fund-loss vector; fold into a future hardening pass.
