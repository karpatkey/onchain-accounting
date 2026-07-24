# Bridge Adapters: Architecture and Integration

This document describes the bridge escrow and adapter architecture as implemented (post [ADR 0012](../../docs/decisions/0012-bridge-provable-release-rearchitecture.md)): message format, flows, existing adapters, and how to implement and register a new adapter.

---

## 1. Overview

The bridge system consists of:

- **BridgeEscrow:** Holds in-transit accounting on the source chain, creates invoices on deposit, and on the destination chain releases assets to the account named by a validated payload. It is **not** the cross-chain message recipient — each adapter is. Only authorized accounts can deposit; release is callable **only by an authorized adapter** (there is no public dispatcher, and MANAGER cannot call release directly).
- **Bridge adapters:** Contracts that implement `IBridgeAdapter`. Each adapter integrates with one bridge protocol (Across, CCIP, CCTP, etc.). The adapter is the **direct on-chain recipient** of the inbound protocol message on the destination chain; it authenticates the message (genuine protocol contract + source chain + source sender) before releasing.

All adapters use a single **message payload** format (invoice data). Destination release is a **funded pass-through**: `BridgeEscrow.releaseByInvoiceId(messagePayload)` validates the payload and pulls the exact amount **from the calling adapter** (which holds the delivered funds), forwarding it to the account. The escrow never pays release from a standing balance, so one invoice can never be funded by another's tokens.

---

## 2. Token and data flow (depositAndBridge → completeBridge)

The diagram shows how tokens and the message payload move from an account on the source chain to completion on the destination chain. Two completion paths exist: **auto** (the genuine protocol contract calls the adapter's authenticated receiver, which funds + releases) and **manager** (a manager calls `adapter.completeBridge`, e.g. for attestation/finalization protocols, which then funds + releases).

```mermaid
flowchart TB
    subgraph SOURCE["Source chain"]
        PS[Account]
        BE_S[BridgeEscrow]
        AD_S[Adapter]
        BC[Bridge protocol contract]

        PS -->|"1. depositAndBridge(..., adapter)<br/>ERC20: transferFrom / Native: msg.value"| BE_S
        BE_S -->|"2. Create invoice (BRIDGING), assign nonce<br/>approve adapter or transfer native"| BE_S
        BE_S -->|"3. bridge(messagePayload)"| AD_S
        AD_S -->|"4. Pull tokens (ERC20) / use value (native)"| BE_S
        AD_S -->|"5. Call protocol deposit with recipient = sibling adapter<br/>messagePayload in protocol message"| BC
    end

    subgraph CROSS["Cross-chain (protocol relayer / attestation)"]
        BC -.->|"6. Tokens + message to dest"| DEST
    end

    subgraph DEST["Destination chain"]
        AD_D[Adapter]
        BE_D[BridgeEscrow]
        PROTOCOL[Bridge protocol contract]

        PROTOCOL -->|"7a. Auto: deliver tokens to adapter,<br/>then call adapter's protocol receiver"| AD_D
        AD_D -->|"8a. Authenticate protocol + source chain + source sender"| AD_D
        AD_D -->|"9a. _fundAndRelease: approve escrow, releaseByInvoiceId"| BE_D
        BE_D -->|"10. Pull amount from adapter, transfer to account"| PS_D[Account]

        OP[Manager] -->|"7b. Manager: completeBridge(messagePayload, protocolData)"| AD_D
        AD_D -->|"8b. _completeBridge (verify attestation / finalize); adapter now holds funds"| AD_D
        AD_D -->|"9b. base _fundAndRelease → releaseByInvoiceId"| BE_D
        BE_D -->|"10. Pull amount from adapter, transfer to account"| PS_D
    end

    SOURCE --> CROSS
    CROSS --> DEST
```

- **Steps 1–5 (source):** Account deposits; escrow records the effective received amount (fee-on-transfer safe), assigns a per-account nonce, creates the `BRIDGING` invoice, hands tokens to the adapter, and calls `adapter.bridge(messagePayload)`. The adapter initiates the bridge with the **sibling adapter on the destination chain** (same address via CREATE2) as the recipient.
- **Step 6:** The protocol moves tokens and (where applicable) the message to the destination chain.
- **Path 7a–10 (auto):** The protocol delivers tokens to the adapter and calls the adapter's protocol receiver. The adapter authenticates `msg.sender == <real protocol contract>`, the source chain, and the source sender (`trustedRemoteAdapter`), then calls `_fundAndRelease`; the escrow pulls the amount from the adapter and transfers it to the account.
- **Path 7b–10 (manager):** For protocols whose provenance is an attestation/proof (CCTP, Superchain), a manager calls `adapter.completeBridge`. `_completeBridge` verifies the attestation/withdrawal so the adapter holds the funds; the base then funds + releases.

---

## 3. Invoice system

Invoices are created only on the **source chain** and track a single bridge operation from deposit until closure.

### 3.1 Invoice lifecycle

- **Creation:** When an authorized account calls `depositAndBridge`, the escrow assigns a **per-account nonce** (`bridgeNonce(account)`, monotonic) and creates an **invoice** with status `BRIDGING`. The invoice stores `invoiceId`, source/destination chain IDs, account, asset, amount, nonce, timestamp, adapter, and status. The invoice hash (storage key) is derived from the checksum (first 24 bytes of `keccak256(invoiceId, amount, timestamp, nonce)`). The nonce makes invoice identity unique per operation.
- **BRIDGING:** The invoice stays `BRIDGING` while in transit. The escrow maintains **in-transit** balance caches per account and asset (sum of `BRIDGING` invoice amounts). Decrements are unguarded — an underflow is an invariant breach and reverts rather than being silently swallowed. Active invoices for an account are in `_activeInvoices[account]`.
- **Completion on the destination chain:** Completion does **not** update the source-chain invoice. On the destination there is no stored invoice; the escrow validates the payload in `releaseByInvoiceId` (checksum incl. nonce, timestamp, destination chain, authorized account, registered asset) and sets `completedInvoices[invoiceHash] = true` on the **destination** escrow to prevent replay.
- **Closure on the source chain (markInvoiceCompleted):** Once a manager confirms destination completion, they call **`markInvoiceCompleted(invoiceHashes)`** on the **source** chain (MANAGER-gated). For each `BRIDGING` invoice it sets `COMPLETED`, sets `completedInvoices`, decrements in-transit caches, and removes the invoice from the active list. Missing/non-`BRIDGING` hashes are skipped and reported in `InvoiceCompletionFailed`.

### 3.2 Other outcomes

- **Cancellation:** A manager can call `cancelInvoice(invoiceHash)` on the source chain while the invoice is `BRIDGING` (full CEI, `nonReentrant`). The escrow returns the assets to the account, sets `CANCELLED`, decrements in-transit balances, and removes the invoice from the active list.

### 3.3 Operator notes & gotchas

- **`invoiceId` vs `invoiceHash`.** `invoiceId` is a **non-unique route/lane key** (`src｜dst｜account｜symbol`), reused by every transfer on that lane. `invoiceHash` (the checksum — includes amount + timestamp + nonce) is the **unique per-operation** identity and the key for `getInvoice`, `completedInvoices`, `isInvoiceCompleted`, `markInvoiceCompleted`, `cancelInvoice`. Querying any of those with an `invoiceId` returns empty/zero.
- **Statuses are source-only** (`BRIDGING=0`, `COMPLETED=1`, `CANCELLED=2`). `getInvoice` on a non-existent hash returns an all-zeros struct whose `status` reads `0` (`BRIDGING`) — so **existence is tested by `invoiceId != bytes32(0)`, never by `status`**.
- **No invoice struct on the destination.** `releaseByInvoiceId` only sets `completedInvoices[hash] = true` (+ emits `InvoiceCompleted`/`AssetsReleased`); it never stores an `Invoice`. So `getInvoice` on the destination is **always** empty (not "cleared on finalize" — never written). Read destination data from the events, or confirm delivery with `isInvoiceCompleted(hash)`.
- **Source vs destination `invoiceHash` diverge for fee bridges** (Stargate — see §4.1). Use the **source** (gross-amount) hash for `markInvoiceCompleted`/`getInvoice` on the source, and the **post-fee** hash for `isInvoiceCompleted` on the destination.
- **Asset custody & rollback.** Funds flow: account → escrow → adapter → bridge protocol (source), then bridge protocol → adapter → account (destination). Everything inside `depositAndBridge` is **atomic** — if the bridge send reverts, the whole tx reverts and the account keeps its funds; a `BRIDGING` invoice exists only *after* the value has committed to the bridge. After that there is **no escrow-level rollback**: the source escrow holds 0, and `cancelInvoice` requires it to currently hold `amount` (`balance >= amount`). So `cancelInvoice` is a **source-side recovery** for funds that came back to the escrow — it can never reverse an in-flight/delivered transfer, which is exactly what makes a source-refund + destination-release double-pay impossible.
- **Mid-bridge (in-transit) recovery.** The escrow adds **no** in-transit recovery — if delivery stalls in the vendor layer, only the vendor's own mechanics apply (CCTP: complete the mint anytime with the attestation; CCIP: manual re-execution; Stargate/LZ: run `lzCompose`; Gnosis: AMB re-request; Superchain: canonical, effectively guaranteed). For lock/burn bridges, recovery = get the funds to the **destination adapter**, then `recoverStuckAssets`. **Across is the exception** — an unfilled deposit refunds on the **source** before ever reaching the destination.
- **Settlement is an operator/keeper duty.** Source invoices stay `BRIDGING` until a MANAGER runs `markInvoiceCompleted` after confirming destination delivery. **No keeper ships in this repo** — the escrow only exposes the function. Without a reconciler running it, source in-transit balances (`getInTransitBalanceForAsset`) never clear, so any NAV/accounting consumer would double-count delivered funds. Treat "run a settlement keeper/reconciler" as an operational requirement of operating the escrow.

---

## 4. Message Payload Format

Payloads are produced and consumed by `InvoiceDataLib` in `src/bridge/InvoiceDataLib.sol`.

### 4.1 Encoded form

`messagePayload` is `abi.encode(invoiceId, amount, nonce, meta)` (4 slots) where:

- **invoiceId** (bytes32): Packed as `sourceChainId` (3 bytes) | `destinationChainId` (3 bytes) | `account` (20 bytes) | `assetSymbol` (6 bytes). Chain IDs are `uint24`; asset symbol is right-padded bytes6 (e.g. `"USDC  "`).
- **amount** (uint256): Amount being bridged (the effective received amount on deposit).
- **nonce** (uint256): Per-account monotonic nonce, unique per bridge operation.
- **meta** (bytes32): High 8 bytes = `timestamp` (uint64); low 24 bytes = **checksum24** (first 24 bytes of `keccak256(abi.encodePacked(invoiceId, amount, timestamp, nonce))`).

The checksum is an **integrity + replay** key, not an authenticator (all inputs are public). Provenance is enforced by the adapter layer (§7). BridgeEscrow generates the payload in `depositAndBridge` and validates checksum + timestamp in `releaseByInvoiceId`. Most adapters do not alter the payload — they pass it through to the protocol and, on completion, pass the **same** payload to `releaseByInvoiceId`, so the destination `invoiceHash` matches the source. **The exception is fee-taking bridges:** Stargate's OFT deducts a transfer fee, so `StargateBridgeAdapter` re-encodes the payload with the **post-fee** amount and recomputes the checksum — the destination `invoiceHash` therefore **differs** from the source one. This is immaterial to correctness: `invoiceId` excludes the amount (so route/account identity is unchanged), and `completedInvoices` replay protection is per-chain. See [ADR 0012](../../docs/decisions/0012-bridge-provable-release-rearchitecture.md) (post-fee model) and audit finding M-04.

### 4.2 Struct form

`InvoiceDataLib.InvoiceData` has: `invoiceId`, `sourceChainId`, `destinationChainId`, `account`, `assetSymbol`, `amount`, `nonce`, `timestamp`, `checksum24`. Use `InvoiceDataLib.decode(messagePayload)` / `InvoiceDataLib.encode(data)` to convert, and `InvoiceDataLib.calculateChecksum(invoiceId, amount, timestamp, nonce)` for the checksum (single source of truth).

---

## 5. BridgeEscrow

### 5.1 Roles and access

- **DEFAULT_ADMIN_ROLE:** Authorize/revoke accounts and adapters, pause/unpause, `emergencyWithdraw` (recipient-restricted to an authorized account, while paused), and authorize UUPS upgrades. (Asset register/unregister is MANAGER, not admin — see below.)
- **MANAGER:** `cancelInvoice`, `markInvoiceCompleted`, `registerAsset`/`unregisterAsset`. **MANAGER cannot call `releaseByInvoiceId`** — release is adapter-only.

### 5.2 Core flows

**Deposit and bridge (source chain)**

1. An authorized account calls `depositAndBridge(destinationChainId, assetSymbol, amount, adapter)` (payable for native; `msg.value` must be 0 for ERC20).
2. Escrow checks: account authorized, adapter authorized, asset registered, `destinationChainId != chainId`, `amount > 0`. For native, `msg.value == amount`; for ERC20 it pulls tokens and records the **effective received delta** (fee-on-transfer safe; rejects zero-delta).
3. Escrow assigns the per-account nonce, creates the invoice, updates in-transit balances, then transfers native to the adapter or approves the adapter for ERC20, and calls `IBridgeAdapter(adapter).bridge(messagePayload)`. `depositAndBridge` is `nonReentrant`.

**Release (destination chain) — funded pass-through**

1. Callable **only by an authorized adapter** (`nonReentrant`, `payable`). There is no fallback dispatcher and MANAGER cannot call it, so the path is unreachable to an attacker.
2. Escrow decodes the payload; validates timestamp (past), checksum (incl. nonce), `destinationChainId == chainId`, the account is authorized, the asset is registered, and the invoice hash is not already completed.
3. Escrow marks the invoice completed, then **pulls `amount` from the calling adapter** (ERC20: `safeTransferFrom(adapter, account)`; native: requires `msg.value == amount`, forwards to the account) and emits events. The escrow holds no standing pool for release.

### 5.3 Adapter authorization

- **authorizeAdapter(adapter):** Adds the adapter to the authorized set (verified via ERC165 `supportsInterface(IBridgeAdapter)`). Required before the adapter can be used in `depositAndBridge` or call `releaseByInvoiceId`.
- **revokeAdapter(adapter):** Removes the adapter from the authorized set.
- **getAuthorizedAdapters():** Returns the authorized adapter set.

There is **no callback/selector registration** on the escrow (the old `authorizeAdapterWithCallback` / `updateAdapterConfig` / `_callbackAdapters` / `fallback()` mechanism was removed in ADR 0012). Adapters receive protocol callbacks directly and authenticate them.

Assets must be registered per symbol via `registerAsset(symbol, assetAddress)` (native uses `address(0)`; re-pointing a symbol with active invoices is rejected).

---

## 6. BridgeAdapter Base

Adapters inherit `BridgeAdapter` in `src/bridge/BridgeAdapter.sol`.

### 6.1 Entry points (inherited)

- **bridge(messagePayload):** Only callable by `bridgeEscrow`. Decodes the payload, calls `_bridge(data)`, emits `BridgeInitiated`.
- **completeBridge(messagePayload, protocolData):** Only callable by `MANAGER`. Calls `_completeBridge(...)` (protocol verification; adapter must end holding the delivered funds), then resolves the asset via `escrow.assetRegistry(symbol)` and calls `_fundAndRelease`, then emits `BridgeCompleted`.

### 6.2 Provenance config + funding helper

- **trustedRemoteAdapter[uint64 sourceKey] → bytes32** + **setTrustedRemoteAdapter(sourceKey, remote)** (admin): the allowlist of trusted sibling adapters on remote chains. The `sourceKey` is the remote chain's **standard chain id** for every adapter — each adapter translates its protocol-specific source identifier (CCIP selector, LZ eid, CCTP domain, AMB/OP xDomain sender) back to the standard chain id internally before this lookup, so callers always key by the plain chain id. The value is the remote adapter identity (use `_toBytes32(addr)`; with CREATE2 same-address this equals the adapter's own address).
- **_fundAndRelease(messagePayload, asset, amount):** Hands the escrow exactly `amount` of `asset` and triggers release. ERC20: `forceApprove(escrow, amount)` → `releaseByInvoiceId` (escrow pulls) → reset approval to 0. Native: `releaseByInvoiceId{value: amount}`. The adapter must already hold the delivered funds.

### 6.3 What adapters implement

- **_bridge(InvoiceDataLib.InvoiceData memory data):** Initiate the transfer. Encode the payload, pull ERC20 from the escrow (already approved in `depositAndBridge`), and set the protocol's destination recipient to **`address(this)`** (the sibling adapter). Carry the payload in the protocol message.
- **_completeBridge(messagePayload, protocolData):** Manager-path protocol verification (e.g. CCTP attestation, Superchain finalize). Do not call `releaseByInvoiceId`/`_fundAndRelease` directly — the base funds + releases after `_completeBridge` returns. The auto path (the protocol receiver below) calls `_fundAndRelease` itself.
- **The protocol receiver** (e.g. `ccipReceive`, `handleV3AcrossMessage`, `lzCompose`, `onTokenTransfer`): authenticate `msg.sender == <real protocol contract>` + source chain + `trustedRemoteAdapter`, verify the delivered token/amount match the invoice, then `_fundAndRelease`. Mark it `nonReentrant`.

### 6.4 Roles

- **DEFAULT_ADMIN_ROLE:** Adapter configuration (protocol contracts, mappings, `setTrustedRemoteAdapter`).
- **MANAGER:** `completeBridge`, `recoverStuckAssets` (recipient restricted to the escrow or an authorized account). Granted to the security council at deploy by `07`.

### 6.5 Native tokens

`_isNativeToken(token)` returns true for `address(0)` and `NATIVE_ADDRESS_ERC7528` (0xEeee…).

---

## 7. Completion Flows: per-protocol provenance

On the source chain every adapter sets the protocol's destination recipient to its **sibling adapter** (`address(this)`, same address across chains via CREATE2). On the destination chain the adapter authenticates the inbound message before releasing.

| Protocol | Authentic destination entry | Authenticated `msg.sender` | Source authentication |
|---|---|---|---|
| **CCIP** | `ccipReceive(Any2EVMMessage)` | `== router` | `selectorToChainId[sourceChainSelector]` + `message.sender == trustedRemoteAdapter` |
| **Across (V3)** | `handleV3AcrossMessage(tokenSent, amount, relayer, message)` | `== spokePool` | `tokenSent`/`amount` bound to the invoice; `trustedRemoteAdapter` per source chain |
| **Stargate (V2)** | `lzCompose(from, guid, message, …)` | `== endpoint` | `srcEid` + `composeFrom == trustedRemoteAdapter` |
| **Gnosis** | `onTokenTransfer(from, value, data)` (ERC677) | `== omnibridge` | `amb.messageSender() == trustedMediator[srcChainId]` (the SOURCE Omnibridge mediator, NOT the sibling adapter) + `amb.messageSourceChainId()`. The auto path records `authenticatedInvoice`; the MANAGER fallback completes only recorded invoices (see [ADR 0020](../../docs/decisions/0020-bridge-adapter-provenance-and-deploy-hardening.md)) |
| **CCTP** | manager `completeBridge`; `messageTransmitter.receiveMessage` | n/a (Circle attestation) | body mintRecipient (bytes 184-216) == adapter; header recipient (bytes 76-108) == configured TokenMessenger (NOT the adapter); burnToken/amount/sourceDomain bound to invoice; nonce dedup |
| **Superchain** | L1→L2 via `L2CrossDomainMessenger`; L2→L1 via `OptimismPortal` (both **per destination/source L2 chain id** — one L1 adapter serves OP+Base, ADR 0020) | `== l2Messenger` (+ `xDomainMessageSender == trustedRemoteAdapter`); withdrawals proof-gated | messenger xDomain sender; portal Merkle proof + real OP withdrawal hash. `proveWithdrawal`/finalize/view take an `l2ChainId` selecting `optimismPortalForL2` |

In all cases the protocol delivers the tokens to the adapter, the adapter authenticates, and `_fundAndRelease` hands the escrow the exact amount and releases to the account. The checksum + `completedInvoices` replay guard remain as defense-in-depth.

> **Stargate deploy note:** the `lzCompose` auto-release only fires if each destination lane's `composeOptions[dstEid]` carries an lzCompose executor gas option — `_bridge` forwards it as the send's `extraOptions`. `06_Configure._wireStargateComposeOptions` sets this per configured remote lane; if it is empty the OFT still delivers the tokens but the executor is never paid to run `lzCompose`, so the funded pass-through never auto-completes (the delivered tokens sit in the adapter until a manual `endpoint.lzCompose` or MANAGER `completeBridge`).

---

## 8. Implemented Adapters

| Adapter | Protocol | Dest recipient | Auto receiver | Provenance |
|---|---|---|---|---|
| AcrossBridgeAdapter | Across V3 | adapter (self) | `handleV3AcrossMessage` | spokePool + token/amount binding |
| CcipBridgeAdapter | CCIP | adapter (self) | `ccipReceive` | router + selector + source sender |
| StargateBridgeAdapter | Stargate V2 | adapter (self) | `lzCompose` | endpoint + srcEid + composeFrom |
| GnosisBridgeAdapter | Gnosis Omnibridge | adapter (self) | `onTokenTransfer` (ERC677) | omnibridge + AMB source **mediator** (`trustedMediator`) + source chain; record-gated MANAGER fallback |
| CctpBridgeAdapter | CCTP (Circle) | adapter (self) | — (manager) | Circle attestation; body mintRecipient == adapter + header == TokenMessenger; nonce dedup |
| SuperchainBridgeAdapter | Optimism/Base L1↔L2 | adapter (self) | `completeDeposit` (L1→L2) | xDomainMessageSender; per-L2 `optimismPortalForL2` proof + real OP hash (L2→L1) |

All adapters take a single `expectedInitializer` constructor arg (baked into `creationCode` by `05`, identical per chain so the CREATE2 address is preserved) that pins who may call `initialize` — closing the deploy→initialize front-run window (ADR 0020).

Each adapter's `trustedRemoteAdapter` must be configured per source chain so inbound messages are authenticated.

---

## 9. How to Create a New Adapter

1. Inherit `BridgeAdapter` and (optionally) a protocol-specific interface. Add storage for protocol contracts and correlation mappings.
2. Implement `initialize(...)` that calls `super._initializeBridgeAdapter(admin_, bridgeEscrow_, providerName_, version_)`, sets protocol contracts, and configures chain mappings.
3. Implement **`_bridge(InvoiceDataLib.InvoiceData memory data)`:** encode the payload (`InvoiceDataLib.encode`), resolve the asset (`IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol))`), pull ERC20 from the escrow, set the protocol recipient to **`address(this)`**, and call the protocol with the payload in its message.
4. Implement the **protocol receiver** (auto path): authenticate `msg.sender == <protocol contract>` + source chain + `trustedRemoteAdapter`, verify delivered token/amount vs the invoice, then `_fundAndRelease(messagePayload, asset, amount)`. Mark it `nonReentrant`. Override `supportsInterface` if you implement a protocol receiver interface.
5. Implement **`_completeBridge(messagePayload, protocolData)`** (manager path) for attestation/proof protocols: verify and ensure the adapter holds the funds; do **not** call release (the base funds + releases after).
6. Expose view functions your UI/managers need (e.g. `getMessagePayload`). Use shared errors/constants from `src/errors.sol` / `src/constants.sol`.

Adapters are **non-upgradeable**: deployed via the canonical CREATE2 deployer (`0x4e59…4956C`) in `05_DeployBridgeAdapters.s.sol`, so each adapter's address is **identical on every chain** (ADR 0012 D7 — the same-address guarantee `trustedRemoteAdapter` relies on); the script asserts the on-chain address equals the predicted deterministic address. They are initialized once via the base `_initialized` boolean guard (args passed to `initialize`, so the creation bytecode carries no per-chain data). No constructor `_disableInitializers` / `initializer` modifier. (BridgeEscrow itself is UUPS-upgradeable, `_authorizeUpgrade` gated by `DEFAULT_ADMIN_ROLE`.)

---

## 10. How to Configure an Adapter in BridgeEscrow

> Per-chain bridge-adapter deploy config (`enabled`, `initialize` args) lives in `script/config/contracts-deployment-config/bridge-adapters/<chainId>.json`, read by `05_DeployBridgeAdapters.s.sol`. In the numbered deploy flow, steps 2 (authorize adapter + wire trusted remotes) and 4 (register assets) below, plus account authorization, are done by `06_Configure.s.sol` from `bridge-adapters/<chainId>.json` (`remoteChains`) and `bridge-escrow/<chainId>.json` (`accounts[]` → `authorizeAccount`, `assets.<symbol>` → `registerAsset`) — the manual steps here describe the underlying calls.

1. **Deploy the adapter** and run `initialize(...)`.
2. **Authorize on the escrow:** `BridgeEscrow.authorizeAdapter(adapter)` (admin) — enables `depositAndBridge` and lets the adapter call `releaseByInvoiceId`.
3. **Configure trusted remotes:** for each source chain, `adapter.setTrustedRemoteAdapter(sourceKey, remoteAdapterIdentity)` (admin) so inbound messages are authenticated. With CREATE2 same-address deployment the remote identity is the adapter's own address.
4. **Register assets** on both source and destination escrows: `BridgeEscrow.registerAsset(symbol, assetAddress)`.
5. **Roles:** `07_TransferAdminToSecurityCouncil` hands each adapter's `DEFAULT_ADMIN_ROLE` + `MANAGER` to the security council and renounces the deployer. The council's adapter `MANAGER` gates `completeBridge`, `recoverStuckAssets`, and (Superchain) `proveWithdrawal`/`finalizeWithdrawal`.

After this, accounts call `depositAndBridge(..., adapter)`; on the destination chain either the authenticated protocol receiver (auto) or a manager calling `adapter.completeBridge(messagePayload, protocolData)` triggers the funded release.

### 10.1 Route availability rules (a route can silently strand funds if these are violated)

A route `(srcChain → dstChain, asset, adapter)` is only *completable* when all of the following hold. `06_Configure._validateBridgeRoutes` enforces the symbol rule at deploy time (fail-fast); the token/vendor rules are not machine-checkable and are enforced by config discipline + these docs.

- **Same logical symbol on both ends.** The invoice carries the **source chain's** logical symbol (e.g. `"USDC"`) unchanged; the destination escrow resolves that *same* symbol via `assetRegistry`. So both escrows must register the symbol under the **identical string**, each mapped to its own local token. The symbol is a routing label, **not** the token's on-chain ticker — a token whose `symbol()` is `"USDC.e"` is still registered under the logical `"USDC"` if that's the lane's symbol. (This is why Gnosis registers its bridged-USDC token `0x2a22f9c3` under `"USDC"`, not `"USDCe"`.)
- **The vendor must deliver the exact token the destination registers.** A bridge that delivers a *different* token than `assetRegistry[symbol]` will fail the adapter's delivered-token check and strand the funds on the destination adapter (MANAGER-recoverable). This bites when a chain has multiple representations of the "same" asset.
- **Gnosis USD is Stargate-only.** On Gnosis, `"USDC"` is ambiguous: **Stargate delivers `USDC.e` (`0x2a22f9c3`)**, the **Gnosis omnibridge delivers the legacy `USD//C on xDai` (`0xDDAfbb50`)**, and **CCIP has no Gnosis USD token pool** (its lane reverts at `ccipSend`). The escrow registers `"USDC" → 0x2a22f9c3` (the Stargate token), so route USD↔Gnosis **only via Stargate**; the omnibridge (Gnosis adapter) carries **WETH only**, and CCIP is disabled on Gnosis. WETH is a single token across all bridges, so WETH↔Gnosis is unambiguous.

**Roles note (deploy window):** `07` grants the security council adapter MANAGER for steady state, but a canary/validation run *before* `07` needs the deploy EOA to hold adapter MANAGER to exercise CCTP/Superchain `completeBridge`. `06._ensureAdapterManager` grants that during `06`; `07` later revokes the deployer and grants the council.
