# L-05: `BridgeAdapter.completeBridge` Manager Path Does Not Verify Adapter Holds Funds Before Calling `_completeBridge`

## Summary

`BridgeAdapter.completeBridge` (the MANAGER fallback completion path) calls `_completeBridge(messagePayload, protocolData)` first, then calls `_fundAndRelease`. `_fundAndRelease` reverts if the adapter does not hold the required `amount` of `asset`. However, `_completeBridge` for some adapters (e.g., `CctpBridgeAdapter`) mutates state (marks `usedNonces`, stores `messageToInvoiceId`, calls `messageTransmitter.receiveMessage`) before the balance check in `_fundAndRelease`. If `receiveMessage` succeeds but the adapter somehow does not hold the expected balance afterward, the nonce is consumed and cannot be used for a valid retry.

## Vulnerability Detail

### Root Cause

The call sequence in `BridgeAdapter.completeBridge`:

```solidity
// src/bridge/BridgeAdapter.sol:122-130
function completeBridge(bytes calldata messagePayload, bytes calldata protocolData) external override {
    if (!hasRole(MANAGER_ROLE, msg.sender)) revert NotAuthorized();
    // ...
    _completeBridge(messagePayload, protocolData); // @audit state mutations happen here
    address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(...);
    _fundAndRelease(messagePayload, asset, data.amount); // @audit balance check happens here
}
```

In `CctpBridgeAdapter._completeBridge`:

```solidity
// src/bridge/adapters/CctpBridgeAdapter.sol:191-229
function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
    // ...
    usedNonces[sourceDomain][nonce] = true; // @audit state written BEFORE balance check
    messageToInvoiceId[sourceDomain][nonce] = data.invoiceId;
    messagePayloads[data.invoiceId] = messagePayload;
    bool success = messageTransmitter.receiveMessage(cctpMessage, attestation); // @audit external call mints USDC
    if (!success) revert MessageReceiveFailed();
    // adapter now holds USDC — but _fundAndRelease hasn't run yet
}
```

If `messageTransmitter.receiveMessage` successfully mints USDC to the adapter but the subsequent `_fundAndRelease` → `IERC20(asset).balanceOf(address(this)) < data.amount` check somehow fails (e.g., due to fee-on-transfer token behavior or asset mis-mapping), the nonce is marked used and the USDC is stranded in the adapter.

## Impact

- **Likelihood**: Very Low — requires a fee-on-transfer USDC or asset registry misconfiguration; USDC is not fee-on-transfer.
- **Impact**: Low — CCTP nonce is consumed but can be recovered via `recoverStuckAssets` (MANAGER-gated on the adapter). Funds not permanently lost, but require manual intervention.

## Recommended Mitigation

Add a pre-flight balance snapshot before `_completeBridge` and verify the delta equals `data.amount` after it completes, before calling `_fundAndRelease`. This ensures the balance increase is attributable to the CCTP mint and not to pre-existing adapter funds.
