# M-04: Stargate Post-Fee Payload Re-Encodes Invoice With New Checksum — Source and Destination Checksums Diverge, Hindering Off-Chain Reconciliation and Enabling Partial Cross-Invoice Replay

## Summary

`StargateBridgeAdapter._bridge` re-encodes the invoice payload with the post-fee amount and a freshly recomputed `checksum24` before sending it as the Stargate compose message. The source-chain escrow stores the invoice under the **gross** checksum, while the destination escrow marks `completedInvoices` under the **post-fee** checksum. These are different `invoiceHash` values. A manager calling `markInvoiceCompleted` on the source chain must use the gross hash, but an indexer tracking destination completion events will observe the post-fee hash. This asymmetry can cause source-chain invoices to remain permanently in `BRIDGING` state even after successful destination completion, inflating the `_inTransitBalances` indefinitely.

More critically: if the source chain and destination chain have independent `completedInvoices` maps keyed by different checksums, the source-chain guard (`completedInvoices[grossHash]`) cannot prevent a second destination release using a different (crafted) post-fee payload that produces the same `invoiceId` but a different amount — because the destination tracks its own post-fee hash, not the gross hash.

## Vulnerability Detail

### Root Cause

In `_bridge`, the post-fee invoice is re-encoded with a new checksum:

```solidity
// @audit postFeeData.checksum24 is freshly computed for receivedAmount, not data.amount
InvoiceDataLib.InvoiceData memory postFeeData = InvoiceDataLib.InvoiceData({
    invoiceId: data.invoiceId,
    ...
    amount: receivedAmount,
    ...
    checksum24: InvoiceDataLib.calculateChecksum(data.invoiceId, receivedAmount, data.timestamp, data.nonce)
});
sendParam.composeMsg = InvoiceDataLib.encode(postFeeData);
```

The source-chain escrow stores the invoice under the gross `checksum24`:
```
grossHash = bytes32(uint256(uint192(calculateChecksum(invoiceId, grossAmount, ts, nonce))))
invoices[grossHash] = Invoice{amount: grossAmount, ...}
```

The destination escrow marks completion under the post-fee `checksum24`:
```
postFeeHash = bytes32(uint256(uint192(calculateChecksum(invoiceId, postFeeAmount, ts, nonce))))
completedInvoices[postFeeHash] = true
```

`grossHash != postFeeHash` because `grossAmount != postFeeAmount`.

When the manager calls `markInvoiceCompleted([grossHash])` on the source chain, it works correctly. But if the manager does not perform this step, or uses the post-fee hash instead of the gross hash, the source-chain invoice remains `BRIDGING` and `_inTransitBalances` is never decremented.

### Bidirectional Hash Mismatch Issue

On the **destination** chain, `completedInvoices` is keyed by the post-fee hash. On the **source** chain, `invoices` and `completedInvoices` are keyed by the gross hash. There is no cross-chain enforcement linking these two. A second delivery attempt using a different post-fee amount (e.g., if Stargate fees change between attempts) would produce yet another hash, and the destination would accept it as a new (not-yet-completed) invoice, as long as the source-chain invoice was not yet marked `COMPLETED` by the manager.

This creates a scenario where the same `invoiceId` could be completed twice on the destination with different amounts, if:
1. First attempt: fee = F1, post-fee hash H1, destination marks `completedInvoices[H1] = true`
2. Second attempt: fee = F2 (e.g., fee decreased), post-fee hash H2 != H1, destination marks `completedInvoices[H2] = true`

Both releases succeed because H1 and H2 are different keys. The account receives funds twice.

### Code Location

- File: `src/bridge/adapters/StargateBridgeAdapter.sol`
- Function: `_bridge()`
- Lines: 182–194

```solidity
// @audit postFeeData gets a new checksum — different from source-chain invoice checksum
InvoiceDataLib.InvoiceData memory postFeeData = InvoiceDataLib.InvoiceData({
    invoiceId: data.invoiceId,
    sourceChainId: data.sourceChainId,
    destinationChainId: data.destinationChainId,
    account: data.account,
    assetSymbol: data.assetSymbol,
    amount: receivedAmount,               // @audit post-fee amount
    nonce: data.nonce,
    timestamp: data.timestamp,
    checksum24: InvoiceDataLib.calculateChecksum(data.invoiceId, receivedAmount, data.timestamp, data.nonce) // @audit new checksum
});
```

## Impact

- **Likelihood**: Medium — every Stargate bridge involves a fee (or potential reward), so the checksum mismatch is structural, not edge-case.
- **Impact**: Medium — source-chain `_inTransitBalances` inflation (NAV overcounting) if `markInvoiceCompleted` is not called; in the double-completion scenario, unauthorized double-payout.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- A Stargate bridge operation completes on the destination chain.
- Due to a fee change between the original send and a theoretical re-send (or two parallel fills with different fee structures), two post-fee payloads with different checksums are delivered.

### Attack Steps

1. Account bridges 1,000 USDC via Stargate. At time T1, fee = 1%, so `receivedAmount = 990`. Destination checksum H1 is computed for (invoiceId, 990, T, N). `completedInvoices[H1] = true` on destination.
2. Source-chain manager fails to call `markInvoiceCompleted([grossHash])` promptly. The `_inTransitBalances` for the account continues to include 1,000 USDC, overcounting NAV.
3. Attacker (if they can trigger a second Stargate compose message with the same `invoiceId` but a different `receivedAmount`) sends a crafted compose message with `receivedAmount = 980` (fee = 2%), producing checksum H2 != H1.
4. Destination `completedInvoices[H2]` is false — not yet seen. Checksum validation passes. Destination releases 980 USDC to the account. `completedInvoices[H2] = true`.
5. Account has received both 990 and 980 USDC — double-payout.

Note: Step 3 requires the attacker to be able to send a valid Stargate compose message, which requires access to the Stargate pool. This is gated by Stargate's own authentication (endpoint, lzCompose), so practical difficulty is high — but the vulnerability is structural.

### Expected Impact

- NAV overcounting on source chain until manager explicitly calls `markInvoiceCompleted`.
- In the double-completion scenario: recipient receives more tokens than deposited (protocol loss).

## Recommended Mitigation

1. Use a **nonce-based** or **invoiceId-based** deduplication key on the destination that is independent of the amount. A `completedInvoiceIds[invoiceId] = true` mapping (keyed by `invoiceId`, not by the checksum) would prevent any two deliveries for the same `invoiceId` from both completing:

```solidity
// @audit use invoiceId as primary dedup key, not checksum24
if (completedInvoiceIds[data.invoiceId]) revert InvoiceAlreadyCompleted();
completedInvoiceIds[data.invoiceId] = true;
```

2. Include the post-fee amount in the source-chain invoice record, and require the manager's `markInvoiceCompleted` to match the post-fee hash (emitted in the `StargateBridgeInitiated` event).

3. Add a check in `lzCompose` that verifies the `invoiceId` was never previously completed (in addition to the checksum check):

```solidity
if (completedInvoiceIds[data.invoiceId]) revert InvoiceAlreadyCompleted();
```
