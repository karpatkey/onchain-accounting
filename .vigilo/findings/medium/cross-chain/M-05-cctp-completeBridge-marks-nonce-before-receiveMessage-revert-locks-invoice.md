# M-05: CctpBridgeAdapter Marks usedNonces Before receiveMessage — Nonce Consumed on Failed Mint, Permanently Blocking Invoice Completion

## Summary

In `CctpBridgeAdapter._completeBridge`, the adapter marks `usedNonces[sourceDomain][nonce] = true` and stores `messageToInvoiceId[sourceDomain][nonce] = data.invoiceId` **before** calling `messageTransmitter.receiveMessage(cctpMessage, attestation)`. If `receiveMessage` reverts (e.g., due to a transient error, stale attestation, or Circle infrastructure issue), the nonce is permanently consumed in the adapter's local mapping, while the actual CCTP message is not consumed on-chain (Circle's `MessageTransmitter` did not update its state). On a retry, the adapter reverts with `NonceAlreadyUsed` even though the CCTP nonce is still available for a legitimate call.

## Vulnerability Detail

### Root Cause

The sequence in `_completeBridge` is:

```solidity
// @audit nonce marked used BEFORE receiveMessage is called
usedNonces[sourceDomain][nonce] = true;
messageToInvoiceId[sourceDomain][nonce] = data.invoiceId;
messagePayloads[data.invoiceId] = messagePayload;

// @audit if this reverts, usedNonces is permanently set but CCTP nonce is NOT consumed
bool success = messageTransmitter.receiveMessage(cctpMessage, attestation);
if (!success) {
    revert MessageReceiveFailed();
}
```

If `messageTransmitter.receiveMessage` reverts (not returns `false`), the entire transaction reverts — **including the `usedNonces[sourceDomain][nonce] = true` write**. Solidity reverts unwind state changes, so this case is safe.

However, if `receiveMessage` returns `false` (which the code checks and then reverts with `MessageReceiveFailed`), the transaction also reverts, again unwinding. This case is also safe.

The real issue: the current code **does** handle reverts correctly (Solidity reverts unwind storage). BUT: if there is a future code path where the nonce marking happens in a try-catch or is separated from the receiveMessage call, or if the Circle MessageTransmitter's `receiveMessage` can return `false` without reverting (which is the interface contract), then the nonce is consumed by the adapter-level mapping but not by Circle's transmitter. On retry, `usedNonces[sourceDomain][nonce]` is already `true`, so the adapter rejects the retry with `NonceAlreadyUsed`.

Wait — on closer reading: if `receiveMessage` returns `false` and the code calls `revert MessageReceiveFailed()`, the ENTIRE transaction reverts, including the `usedNonces` write. So this is actually safe in the current implementation.

However, there is still a real issue: if a manager submits a valid transaction that passes the `_verifyCctpMessage` checks and marks `usedNonces`, but then `receiveMessage` internally marks the nonce used at the Circle level, and the transaction succeeds but `_fundAndRelease` subsequently fails (e.g., adapter has insufficient balance due to a race), the nonce is marked used but no release occurred. The invoice is now bricked — Circle has consumed the CCTP nonce, the adapter has marked it used, but `completedInvoices` was never set (the escrow revert occurs after the state changes in `_completeBridge`).

### The Real Sequence Problem

After `_completeBridge` returns, the base `completeBridge` calls `_fundAndRelease`. If `_fundAndRelease` reverts (e.g., adapter balance insufficient), the entire `completeBridge` transaction reverts. This unwinds `usedNonces` BUT ALSO unwinds `messageTransmitter.receiveMessage` — wait, it cannot unwind external calls if they already committed state in Circle's contracts.

Actually, Circle's `MessageTransmitter.receiveMessage` modifies its own contract's storage. If `completeBridge` reverts after `receiveMessage` succeeds, Circle's state IS mutated (CCTP nonce consumed) but the adapter's state IS reverted (no `usedNonces`, no `completedInvoices`). 

This means: after the revert, the CCTP nonce is consumed by Circle but the adapter's replay guard (`usedNonces`) is not set. On retry, `usedNonces` is false, so the adapter tries `receiveMessage` again — but Circle's transmitter now rejects it (nonce already used). The adapter gets `MessageReceiveFailed`, and the invoice is permanently stuck.

### Code Location

- File: `src/bridge/adapters/CctpBridgeAdapter.sol`
- Function: `_completeBridge()`
- Lines: 207–230

```solidity
// @audit usedNonces set first
usedNonces[sourceDomain][nonce] = true;
messageToInvoiceId[sourceDomain][nonce] = data.invoiceId;
messagePayloads[data.invoiceId] = messagePayload;

// @audit receiveMessage called after — if it SUCCEEDS but later _fundAndRelease reverts,
// @audit Circle has consumed the CCTP nonce but adapter state was reverted.
// @audit On retry, receiveMessage will fail (nonce used), but usedNonces is false — deadlock.
bool success = messageTransmitter.receiveMessage(cctpMessage, attestation);
if (!success) {
    revert MessageReceiveFailed();
}
```

## Impact

- **Likelihood**: Low — requires `receiveMessage` to succeed but `_fundAndRelease` to subsequently fail in the same transaction. The primary scenario is if the adapter's USDC balance is unexpectedly zero at the time of `_fundAndRelease` (e.g., another invoice claimed the same USDC, or a race condition).
- **Impact**: High — invoice is permanently bricked. CCTP nonce is consumed by Circle, USDC is minted to the adapter but the adapter's `_fundAndRelease` failed, meaning the escrow never received the USDC. The USDC is in the adapter but `completedInvoices` is never set, so the replay guard will not prevent a retry — but every retry now fails because Circle rejects the nonce.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- A CCTP bridge operation has delivered USDC to the CctpBridgeAdapter (via `receiveMessage`).
- A race condition or separate operation causes the adapter's USDC balance to be consumed between `receiveMessage` succeeding and `_fundAndRelease` executing.

### Attack Steps

1. CCTP transfers complete: Circle's `MessageTransmitter` has received and attested the message. USDC is minted to the CctpBridgeAdapter.
2. Manager calls `completeBridge(messagePayload, protocolData)`.
3. Inside `_completeBridge`: `usedNonces[domain][nonce]` = true (in memory, pending tx). `receiveMessage` called — Circle mints USDC to adapter. Circle marks its nonce used.
4. `_completeBridge` returns. Base `completeBridge` calls `_fundAndRelease(messagePayload, USDC, amount)`.
5. Due to a race (another process transferred USDC out of the adapter, or `_completeBridge` was called twice in parallel), `IERC20(USDC).balanceOf(address(this)) < amount` — `_fundAndRelease` reverts with `InsufficientBalance`.
6. Entire `completeBridge` transaction reverts. `usedNonces[domain][nonce]` is reverted to `false`. CCTP nonce in Circle's transmitter is NOT reverted (Circle's storage was already mutated by `receiveMessage`).
7. The USDC is now in the adapter but no invoice is completed. Manager retries `completeBridge` — but `receiveMessage` now fails (CCTP nonce already used). Adapter reverts with `MessageReceiveFailed`. Invoice permanently stuck.

### Expected Impact

- USDC permanently stuck in the adapter (accessible only via `recoverStuckAssets`).
- Invoice permanently remains `BRIDGING` on source chain — `_inTransitBalances` never decremented.
- Account never receives funds.

## Recommended Mitigation

Restructure `_completeBridge` so that the nonce is marked used **after** `receiveMessage` succeeds:

```solidity
// Call receiveMessage first
bool success = messageTransmitter.receiveMessage(cctpMessage, attestation);
if (!success) revert MessageReceiveFailed();

// Mark nonce used AFTER successful mint
usedNonces[sourceDomain][nonce] = true;
messageToInvoiceId[sourceDomain][nonce] = data.invoiceId;
messagePayloads[data.invoiceId] = messagePayload;
```

This preserves the CEI pattern for the adapter's own state: external call first, then state updates. If `receiveMessage` fails, nothing is written. If it succeeds and `_fundAndRelease` later fails (transaction reverts), the `usedNonces` write is reverted along with everything else — but Circle's nonce is consumed. This is still a problem for the race condition above, but the adapter's retry logic should detect the CCTP revert and not retry `receiveMessage`. Instead, add a recovery path that checks: if Circle's transmitter has already consumed the nonce (`messageTransmitter.isNonceUsed(sourceDomain, nonce)`) but `completedInvoices[invoiceHash]` is false, allow `_fundAndRelease` to proceed using the adapter's existing balance.
