# M-01: GnosisBridgeAdapter Manager-Path Completion Reads AMB Sender Without Active AMB Message

## Summary

`GnosisBridgeAdapter._completeBridge` (the MANAGER-gated fallback path) calls `_authenticateSource`, which reads `amb.messageSender()` and `amb.messageSourceChainId()`. These AMB calls only return meaningful values during the execution of an active AMB message callback. When the manager calls `completeBridge` directly (not triggered by an AMB message), `amb.messageSender()` returns whatever the AMB contract stores as its "current message sender" — which is typically `address(0)` or a stale value from the last real AMB message. The source authentication therefore passes with a zero or wrong sender if the trusted remote was configured as `bytes32(0)` or if the stale sender matches a configured trusted remote by coincidence.

## Vulnerability Detail

### Root Cause

The Gnosis AMB pattern uses `messageSender()` as a contextual getter — it returns the sender of the message currently being processed by the AMB. Outside of an AMB execution context, the return value is implementation-defined (typically `address(0)` in most AMB implementations, or a stale value from the last processed message).

`_authenticateSource` is designed for use inside `onTokenTransfer` (the auto path, called by the Omnibridge during an AMB message delivery). It unconditionally reads live AMB context:

```solidity
// @audit reads AMB context — only valid during an active AMB message callback
function _authenticateSource(uint64 srcChainId) internal view {
    bytes32 expectedRemote = trustedRemoteAdapter[srcChainId];
    if (expectedRemote == bytes32(0)) revert InvalidBridgeData();
    // @audit amb.messageSender() is NOT the trusted remote when called from manager path
    if (_toBytes32(amb.messageSender()) != expectedRemote) revert InvalidBridgeData();
    if (amb.messageSourceChainId() != bytes32(uint256(srcChainId))) revert InvalidBridgeData();
}
```

When `_completeBridge` is called by the manager (not via an AMB callback), the AMB is not in an active message context. The call to `amb.messageSender()` will return whatever the AMB's internal state holds:

- In the common Gnosis AMB implementation, `messageSender()` reverts or returns `address(0)` when no message is being processed.
- If it reverts, the manager path always fails — making it impossible to recover stuck funds on Gnosis, which defeats the purpose of having a manager fallback.
- If it returns `address(0)`, and `trustedRemoteAdapter[srcChainId]` is non-zero, the check fails — correct behavior, but the manager cannot complete any bridge.

The `_completeBridge` fallback path is explicitly designed for the case when `onTokenTransfer` did NOT fire (e.g., AMB delivery failure, gas exhaustion). This is exactly the scenario where calling `amb.messageSender()` is meaningless.

### Code Location

- File: `src/bridge/adapters/GnosisBridgeAdapter.sol`
- Function: `_completeBridge()`
- Lines: 142–163

```solidity
// @audit manager-driven completion: no active AMB message, but _authenticateSource reads AMB context
function _completeBridge(
    bytes calldata messagePayload,
    bytes calldata /* protocolData */
) internal override {
    if (messagePayload.length == 0) revert InvalidCompletionData();
    InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

    // @audit this will always fail or produce wrong result in manager-path (no active AMB message)
    _authenticateSource(uint64(data.sourceChainId));
    ...
}
```

- File: `src/bridge/adapters/GnosisBridgeAdapter.sol`
- Function: `_authenticateSource()`
- Lines: 209–214

```solidity
// @audit reads live AMB execution context — invalid when called outside AMB callback
function _authenticateSource(uint64 srcChainId) internal view {
    bytes32 expectedRemote = trustedRemoteAdapter[srcChainId];
    if (expectedRemote == bytes32(0)) revert InvalidBridgeData();
    if (_toBytes32(amb.messageSender()) != expectedRemote) revert InvalidBridgeData();
    if (amb.messageSourceChainId() != bytes32(uint256(srcChainId))) revert InvalidBridgeData();
}
```

## Impact

- **Likelihood**: Medium — the manager path is the fallback for AMB delivery failures, which are uncommon but do occur (Gnosis AMB has historical delivery failures).
- **Impact**: Medium — two outcomes:
  - If `amb.messageSender()` reverts in non-callback context: manager completion is permanently bricked for Gnosis bridge failures. Stuck funds cannot be recovered via the manager path, forcing reliance on `recoverStuckAssets` only.
  - If `amb.messageSender()` returns a non-reverting stale value that happens to equal a configured trusted remote: unauthorized manager completion is possible (low probability for coincidence, but non-zero).
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- A Gnosis bridge transfer has failed at the AMB delivery step (tokens delivered to adapter, but `onTokenTransfer` never called due to AMB message failure).
- Tokens are stuck in the GnosisBridgeAdapter.
- Manager attempts to call `completeBridge(messagePayload, protocolData)` to recover.

### Attack Steps

1. Gnosis AMB fails to deliver an inbound message to `onTokenTransfer` (out-of-gas, bug, deliberate censorship).
2. Tokens are held in the GnosisBridgeAdapter (already delivered by Omnibridge).
3. Manager calls `adapter.completeBridge(messagePayload, "")` to trigger manual completion.
4. `completeBridge` calls `_completeBridge` → `_authenticateSource(srcChainId)`.
5. `_authenticateSource` calls `amb.messageSender()`. Outside an AMB callback, this either reverts (causing `_completeBridge` to revert, blocking manager recovery entirely) or returns `address(0)`.
6. `_toBytes32(address(0)) != expectedRemote` — authentication fails, manager path is bricked.
7. Tokens remain stuck in the adapter indefinitely.

### Expected Impact

- Permanent inability to use the manager recovery path for Gnosis bridge failures.
- Tokens bridged from Gnosis that fail at the AMB delivery step cannot be released via the manager path — only `recoverStuckAssets` (which requires separate authorization) can unstick them, with no automatic release to the intended recipient.

## Recommended Mitigation

For the manager path in `_completeBridge`, do not rely on live AMB context. Instead, accept the AMB transaction hash or message hash as part of `protocolData` and verify it against a separate source of truth:

```solidity
function _completeBridge(
    bytes calldata messagePayload,
    bytes calldata protocolData
) internal override {
    if (messagePayload.length == 0) revert InvalidCompletionData();
    InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

    // Manager path: verify provenance from protocolData (AMB message hash or transaction hash)
    // rather than live AMB context, which is not available outside an AMB callback.
    if (protocolData.length > 0) {
        bytes32 txHash = abi.decode(protocolData, (bytes32));
        // Verify against known-good transaction hash registry or require admin pre-registration
        require(txHash != bytes32(0), "Missing tx hash");
        // Optionally: check amb.deliveredMessageId(txHash) or a stored known-good hash
    }
    // ... rest of completion
}
```

Alternatively, in `_completeBridge`, skip the AMB source authentication entirely and rely solely on the adapter's balance verification (the adapter holds the tokens only if the Omnibridge actually delivered them) combined with the `completedInvoices` replay guard in the escrow.
