# 0012 — Bridge: provable destination-side release (remove the escrow fallback dispatcher, authenticate the real protocol)

**Status:** accepted

## Context

The bridge subsystem (`src/bridge/`) — UUPS-upgradeable `BridgeEscrow` + six per-protocol adapters (Across, CCIP, CCTP, Stargate, Gnosis, Superchain) over a non-upgradeable `BridgeAdapter` base — was implemented with substantial unit-test coverage (194 passing tests) but never properly validated against its security model. A pre-deploy audit (Phase 1 of this effort; full register in the worktree under `scratchpad/audit/`) found **1 Critical, 14 High, 10 Medium, 8 Low/Info** findings. Two are committed as passing PoCs under `test/poc/`.

### The Critical (C1) — destination-side release is unauthenticated

On the destination chain, funds leave the escrow via `releaseByInvoiceId(messagePayload)` (`BridgeEscrow.sol:229`). Its only gates are:
1. `msg.sender ∈ _authorizedAdapters || hasRole(MANAGER)` (`:230`), and
2. `checksum24 == keccak256(invoiceId, amount, timestamp)` (`:248`) — a digest over **fully public** invoice data, carrying no secret.

The release path is reached through `BridgeEscrow.fallback()` (`:145`), which is **unauthenticated** and dispatches by selector to a registered adapter via `.call`. Each adapter's protocol callback (`handleAcrossMessage`/`ccipReceive`/`lzReceive`/`onTokenTransfer`) authenticates only `msg.sender == bridgeEscrow` — which the fallback satisfies on any caller's behalf. So the trust chain is:

```
anyone → escrow.fallback(selector, payload) → adapter.<callback> (sees msg.sender == escrow ✓)
        → escrow.releaseByInvoiceId(payload) (sees msg.sender == authorized adapter ✓, checksum ✓)
        → funds transferred to the (authorized) account
```

No step verifies that a genuine cross-chain message was delivered by the real protocol. The `msg.sender == router`/`endpoint` branches in `CcipBridgeAdapter.sol:241` and `StargateBridgeAdapter.sol:274` are **dead code** on the live escrow-forwarded path. The protocols' native dedup primitives (CCIP `messageId`, LZ `nonce`, CCTP `usedNonces`, AMB `messageId`, Optimism withdrawal hash) are stored in mappings but **never enforced** at release. PoC `test/poc/CRITICAL-bridge-escrow-fallback-spoof.t.sol` drains 750k USDC with a forged payload and no bridge transfer.

This is an architecture-level flaw: the "route every completion through `escrow.fallback()`" design discards `msg.sender`, which is the **only** provenance signal these bridges provide. An ACL on the fallback alone does not fix it — each adapter must authenticate the real protocol contract *and* the source chain/sender.

### Secondary themes from the audit

- **Protocol-integration correctness (H3–H5, M4–M6):** the adapters target legacy/incorrect protocol APIs. Across uses legacy `deposit`/`handleAcrossMessage` rather than V3 `depositV3`/`handleV3AcrossMessage`; Stargate listens on bare `lzReceive` rather than the composer's `sgReceive`; CCIP and Gnosis never validate source-sender; CCTP never binds the message body to the invoice; Superchain fabricates a fake withdrawal hash. The trust-minimized callback path would not fire against real mainnet protocols.
- **Accounting/reentrancy (H2, H6, H7, H12–H14):** commingled shared-pool releases (invoice A payable from B's funds, `BridgeEscrow.sol:281`), in-transit cache desync feeding NAV (`:892`), cancel/release double-pay with no cross-escrow interlock (`:305`), `depositAndBridge`/`cancelInvoice` unguarded reentrancy, and invoice identity that is not unique per operation (no nonce).
- **Centralization/trust (H9–H11):** `releaseByInvoiceId` is directly MANAGER-callable; `emergencyWithdraw` and per-adapter `recoverStuckAssets` send to an arbitrary address.
- **Cross-chain address model (H8):** CCTP `mintRecipient`/`destinationCaller` and Superchain `receiver` assume the escrow/adapter share one address across chains, but the deploy flow uses plain CREATE (chain-specific addresses).
- **Deploy/privilege (M1):** `07_TransferAdminToSecurityCouncil` hands off roles on the NAV + Escrow **proxies** only; the six adapters keep `DEFAULT_ADMIN_ROLE`/`MANAGER` on the deployer EOA indefinitely.

The full adapter stack is being (re)deployed pre-launch, which is the window to fix the structure rather than patch around it.

## Decision

Re-architect destination-side completion so that **release is provable** — funds only move when the genuine protocol contract on the destination chain delivers an authenticated message from a known sibling adapter — and fix the integration, accounting, trust, and deploy findings in the same pass. Scope decisions confirmed with the owner:

- **Fix protocol integrations to the real APIs** (not auth-model-only).
- **Harden the high-impact centralization findings** (not accept-and-document).
- **CREATE2 same-address deployment** for escrow + adapters (keep the same-address assumption, make it true and asserted).
- **Add a per-account nonce** to invoice identity.

Additional scope confirmations (interactive walkthrough): the bridge is **pre-launch / not deployed anywhere**, so `BridgeEscrow` storage is **rewritten cleanly** (no slot-reservation / `_gap` gymnastics); it **stays UUPS-upgradeable** (council-gated, matches `NAVCalculator`). All **seven configured chains** (Ethereum, Optimism, Gnosis, Polygon, Arbitrum, BNB, Base) are in scope. Stargate targets **V2**. `emergencyWithdraw` is hardened by **recipient-restriction only** (no timelock — preserves emergency responsiveness). Destination fund accounting is **per-invoice** (bound to the D5 invoice record). Delivery is via **incremental stacked PRs** on `test-bridge-adapters` (core → per-adapter → deploy/config → tests).

### D1 — Remove the escrow fallback dispatcher; the adapter is the direct protocol receiver

Delete `BridgeEscrow.fallback()` (`:145`), `_callbackAdapters` (`:91`), `_adapterToCallbackSelector`, `authorizeAdapterWithCallback`, `updateAdapterConfig`, `getCallbackAdapter`, and the callback half of `getAuthorizedAdaptersWithCallbacks`. Keep `authorizeAdapter`/`revokeAdapter` (plain authorization, used by `releaseByInvoiceId`'s caller check). **Because the bridge is pre-launch (nothing deployed), `BridgeEscrow` storage is rewritten cleanly** — removed slots are simply dropped, new state laid out from scratch, and a fresh `_gap` sized for the final layout. (`BridgeEscrow` remains UUPS-upgradeable for post-launch recovery; the clean rewrite is a one-time pre-deploy liberty, after which the normal storage-append discipline applies.)

Each adapter becomes the on-chain recipient the protocol calls directly. In each `_bridge()` the destination recipient/receiver/`toAddress` changes from `bridgeEscrow` to `address(this)` — i.e. the sibling adapter on the destination chain (Across `:102`, CCIP `:172`, Stargate `:217`, Gnosis `:102`; CCTP/Superchain already adapter- or escrow-mediated, see per-protocol notes). Delivered tokens land on the adapter and are forwarded to the escrow via the existing `_transferTokensToEscrow` (`BridgeAdapter.sol:158`) before release — so release is naturally backed by tokens that actually arrived.

### D2 — Authenticate the real protocol contract + source chain + source sender, per adapter

Replace every `msg.sender == bridgeEscrow` callback check with a check against the genuine protocol contract, plus a source-sender allowlist. Add to the base/adapters a governed mapping `trustedRemoteAdapter[uint64 srcChainKey] → bytes32` (admin-set, where the key is the chain id / CCIP selector / CCTP domain / LZ chain id as appropriate) and validate it on every inbound message.

Authentic destination receiver per protocol:

| Protocol | Authentic inbound entry | Required `msg.sender` | Source authentication | Native dedup key |
|---|---|---|---|---|
| **CCIP** | `ccipReceive(Any2EVMMessage)` (CCIPReceiver) | `== router` | `selectorToChainId[msg.sourceChainSelector] == data.sourceChainId` **and** `abi.decode(message.sender) == trustedRemoteAdapter[selector]` | `message.messageId` |
| **Stargate (V2)** | composer `sgReceive`/`lzCompose` | `== endpoint`/composer | `_srcChainId` maps to expected source **and** `_srcAddress == trustedRemoteAdapter` | LZ `nonce` / guid |
| **Across (V3)** | `handleV3AcrossMessage(tokenSent, amount, relayer, message)` | `== spokePool` | cross-check `tokenSent`/`amount` vs decoded payload (Across gives no source sender directly — bind via the message we authored) | SpokePool fill dedup + `completedInvoices` |
| **Gnosis** | `onTokenTransfer` from Omnibridge mediator | `== omnibridge` | `amb.messageSender() == trustedRemoteMediator` **and** `amb.messageSourceChainId() == expected` | AMB `messageId` |
| **CCTP** | `MessageTransmitter.receiveMessage(message, attestation)` (manager-driven) | n/a (attestation-verified) | parse message body: `burnToken`/`amount`/`mintRecipient`/`sourceDomain` must match invoice; `domainToChainId[srcDomain] == data.sourceChainId` | CCTP `nonce` (`usedNonces`) |
| **Superchain** | L1→L2 via `L2CrossDomainMessenger`; L2→L1 via `OptimismPortal` | `== l2Messenger`/`l1Messenger` (+ `xDomainMessageSender == trustedRemoteAdapter`); withdrawals proof-gated | messenger xDomain sender; portal Merkle proof | real OP withdrawal hash |

`releaseByInvoiceId` keeps its checksum + `completedInvoices` replay guard as **defense-in-depth**, demoted from sole gate. Its caller check stays (`authorized adapter || MANAGER`) but now *means* something because (a) the adapter only calls it after the provenance check above, and (b) the adapter is no longer reachable through a public fallback.

### D3 — Fix protocol integrations to real mainnet APIs

- **Across → V3:** `depositV3` for sends; implement `handleV3AcrossMessage` for receives; register/route on the V3 selector. (`AcrossBridgeAdapter.sol`, `interfaces/IAcrossInterfaces.sol`.)
- **Stargate → V2:** standardize on Stargate **V2** (OFT-based, LayerZero V2 endpoint); implement the V2 send + `lzCompose`/`sgReceive` composer receive; remove the V1 `swap` ABI. (`StargateBridgeAdapter.sol`, `interfaces/IStargateInterfaces.sol`.)
- **CCIP:** implement the inbound source-sender/selector checks (D2); becomes a proper CCIPReceiver.
- **CCTP:** write `messageToInvoiceId` on send (or parse the message on receive) and bind the CCTP message body to the invoice; fix the **domain-0 sentinel** (H1) with a `domainConfigured` bool map instead of `domain == 0`.
- **Gnosis:** AMB sender/source-chain validation (D2).
- **Superchain:** compute the **real** OP withdrawal hash from the `MessagePassed`/`WithdrawalTransaction` data; add a `CrossDomainMessenger` interface (`xDomainMessageSender`) to `ISuperchainInterfaces.sol` for the deposit-completion check.

### D4 — Accounting & reentrancy fixes

- **Per-invoice fund segregation (H2):** each proven delivery (D1/D2) credits the **specific destination invoice record** (D5) with the tokens it brought in; `releaseByInvoiceId` draws exactly that invoice's arrived funds, never aggregate `balanceOf`. This closes cross-invoice payout completely (one invoice can never be paid from another's funds).
- **In-transit cache (H6):** remove the silent `>=` guard in `_updateInTransitBalance` (`:892`) so an underflow reverts (a real invariant breach) instead of desyncing; decrement both caches atomically.
- **Cancel/release interlock (H7):** add a `DISPATCHED` invoice state so `cancelInvoice` cannot race a live delivery; require proof-of-failure where the protocol supports it.
- **Reentrancy (H12/H13):** add `nonReentrant` to `depositAndBridge` and `cancelInvoice` (shared guard slot), and move `_removeActiveInvoice` before the external transfer in cancel (full CEI). Resolves read-only-reentrancy M8.
- **Fee-on-transfer (M7):** measure received balance-delta on deposit and record the delta; reject zero-delta. (Belt-and-suspenders with per-delivery segregation.)

### D5 — Invoice identity: per-account nonce

Add a monotonic per-account nonce to the `invoiceId`/checksum preimage and store a real invoice record on the destination (rather than relying on a 192-bit truncated checksum as the sole replay key). This touches `InvoiceDataLib.sol`, `BridgeEscrow._generateInvoiceId`/`_createAndStoreInvoice`, and the **position-identity schema docs** (`docs/howto/position-identity-schema.md`) since invoice identity is part of the cross-system reconciliation key. Document/validate the chain-id width (currently uint24-packed; reconcile with the uint64 `chainId`).

### D6 — Centralization hardening

- **H9:** scope MANAGER-initiated `releaseByInvoiceId` to a stored on-chain record (the destination invoice record from D5) rather than a self-computed public checksum.
- **H11:** constrain `recoverStuckAssets` `to` to `bridgeEscrow` or an authorized account (`BridgeAdapter.sol:190`).
- **H10:** restrict `emergencyWithdraw` `to` to an authorized account (or the council Safe) and reconcile in-transit caches on sweep. **No timelock** — it stays an instant council break-glass; recipient-restriction removes the arbitrary-address rug path while preserving emergency responsiveness. Emit a prominent event.

### D7 — CREATE2 same-address deployment

Deploy `BridgeEscrow` (proxy) and all adapters via CREATE2 with pinned salts so their addresses match across chains, and **assert** the expected address post-deploy. This makes the same-address assumption (CCTP `mintRecipient`/`destinationCaller`, Superchain `receiver`, and the D2 `trustedRemoteAdapter` defaults) true rather than implicit. Touches the deploy layer (`script/deploy/`, the proxy/atomic deployer, and `Create2Deployer`).

### D8 — Deploy privilege handoff (M1/M2)

Extend `07_TransferAdminToSecurityCouncil` (or add a step) to grant the security council `DEFAULT_ADMIN_ROLE` + `MANAGER` on every deployed adapter and renounce the deployer EOA's roles. Move adapter initialization into the constructor (or guard `initialize` to the deployer and require `admin_ != 0`) to close the front-run/grief window.

## Finding → fix map

| Finding | Addressed by |
|---|---|
| C1 (drain) | D1 + D2 (+ D4 segregation) |
| H1 (CCTP domain-0) | D3 |
| H2 (shared pool) | D4 |
| H3/H4/H5 (CCIP/Stargate/Across APIs) | D2 + D3 |
| H6 (cache desync) | D4 |
| H7 (cancel double-pay) | D4 |
| H8 (cross-chain addrs) | D7 |
| H9/H10/H11 (centralization) | D6 |
| H12/H13 (reentrancy/CEI) | D4 |
| H14 (identity) | D5 |
| M1/M2 (deploy privilege/init) | D8 |
| M3 (registerAsset repoint) | D4 (active-invoice guard) |
| M4/M5/M6 (CCTP bind / OP hash / Gnosis AMB) | D2 + D3 |
| M9 (blacklist lock) | pull-payment / per-invoice redirect (D6 recovery path) |
| M10 (stale router approval) | revoke-on-`setRouter` (D3) |
| L1–L8 | folded into the relevant adapter/escrow edits; doc/comment fixes (incl. the wrong "delegatecall" comment) |

## Consequences

- **Storage layout / upgrade:** because the bridge is pre-launch (nothing deployed), `BridgeEscrow` storage is **rewritten cleanly** — removed slots are dropped, the new state (`trustedRemoteAdapter`, per-asset claimable, invoice nonce, DISPATCHED status, destination invoice record) is laid out from scratch, and a fresh `_gap` is sized for the final layout. This matches decision D1 (the clean rewrite is a one-time pre-deploy liberty). `BridgeEscrow` stays UUPS-upgradeable for post-launch recovery; from the first deploy onward the normal append-only storage discipline (and a storage-layout diff check on upgrades) applies.
- **Adapters are non-upgradeable:** all adapter changes ship as fresh deployments (consistent with the immutability convention). CREATE2 salts must be chosen so addresses match across target chains.
- **Config/scripts:** the `authorizeAdapterWithCallback` flow is gone; deploy/config (`script/config/contracts-deployment-config/bridge-adapters/`) and `06_Configure`/`05_DeployBridgeAdapters` gain `trustedRemoteAdapter` setters and CREATE2 salts; `07` extended for adapter handoff. `script/config/CONFIG_GUIDE.md` and `script/deploy/README.md` updated.
- **Docs:** `src/bridge/BRIDGE_ADAPTERS.md` rewritten to the new completion model; `docs/howto/position-identity-schema.md` updated for the invoice nonce; this ADR records the rationale.
- **Tests:** the CRITICAL PoC flips from drain-succeeds to **revert** (kept as regression); unit tests rewritten to the new auth model; fork tests added for every adapter against the real protocol contracts (Phase 4).
- **Scope/risk:** this is the largest single change to the bridge. It is sequenced (escrow → base → per-adapter) with build + targeted tests green at each step, behind two approval gates (this ADR, and the audit register already reviewed).

## Alternatives considered

- **ACL the fallback only** (minimal patch): rejected — leaves source-sender unauthenticated and the dead-code protocol checks in place; does not make release provable.
- **Explicit per-dest-chain remote-address config instead of CREATE2** (H8 alternative): viable and robust to the existing plain-CREATE flow, but the owner chose CREATE2 same-address to keep the code's same-address assumption and simplify `trustedRemoteAdapter` defaults.
- **Defer identity nonce / accept-and-document trust findings:** rejected by scope decision — the redeploy window is the time to make identity correct and shrink the trusted blast radius.
