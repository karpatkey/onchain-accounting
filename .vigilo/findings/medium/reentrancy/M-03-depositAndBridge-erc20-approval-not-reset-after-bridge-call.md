# M-03: `depositAndBridge` ERC20 Approval Not Reset After `adapter.bridge()` — Residual Allowance If Bridge Does Not Consume Full Amount

## Summary

`BridgeEscrow.depositAndBridge` calls `IERC20(asset).forceApprove(adapter, effectiveAmount)` before invoking `IBridgeAdapter(adapter).bridge(messagePayload)` (lines 186–189). There is no `forceApprove(adapter, 0)` reset after `bridge()` returns. All current adapters call `IERC20(asset).safeTransferFrom(bridgeEscrow, adapter, data.amount)` inside `_bridge()`, which consumes the full approved amount in normal operation. However, a future adapter, a fee-on-transfer token edge case, or an adapter that fails mid-execution (reverts from a downstream protocol call after consuming the approval partially) can leave a residual ERC20 allowance from the escrow to the adapter. That allowance persists on-chain and can be exploited in a subsequent transaction to pull additional tokens from the escrow without a corresponding deposit/invoice.

## Vulnerability Detail

### Root Cause

`depositAndBridge` approves the adapter and then calls it without resetting the approval afterward:

```solidity
// @audit approval set — effectiveAmount tokens approved to adapter
IERC20(asset).forceApprove(adapter, effectiveAmount);

// @audit external call — adapter is expected to consume the full approval here
IBridgeAdapter(adapter).bridge(messagePayload);

return invoiceHash;
// @audit no forceApprove(adapter, 0) here — if bridge() does not consume full allowance,
// @audit residual approval persists from escrow to adapter
```

Contrast with `_fundAndRelease` in `BridgeAdapter.sol`, which explicitly resets the approval:

```solidity
IERC20(asset).forceApprove(bridgeEscrow, amount);
IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);
IERC20(asset).forceApprove(bridgeEscrow, 0); // ← reset present here
```

The reset is present in `_fundAndRelease` but ABSENT in `depositAndBridge`.

### Scenario Where Residual Allowance Persists

1. **Fee-on-transfer token edge case**: The escrow approves `effectiveAmount` tokens. The adapter calls `safeTransferFrom(escrow, adapter, data.amount)` where `data.amount == effectiveAmount`. For a standard token this consumes exactly `effectiveAmount` from the allowance. For a fee-on-transfer token, the ERC-20 standard requires `transferFrom` to deduct the REQUESTED amount from the allowance, not the delivered amount. So allowance is reduced by `data.amount`, leaving allowance at 0. This case is safe.

2. **Adapter does not call `safeTransferFrom` for some code path**: If a new adapter's `_bridge()` uses a native push mechanism (e.g., the bridge protocol pulls directly from the escrow via a separate approval pathway, or the bridge protocol uses `permit`), the adapter's `_bridge()` might not call `transferFrom` at all. The `forceApprove` from line 186 then persists. After `depositAndBridge` returns, the adapter has a live allowance of `effectiveAmount` to pull tokens from the escrow.

3. **Partial consumption followed by internal revert that does NOT revert the `safeTransferFrom`**: If `_bridge()` calls `safeTransferFrom` (consuming the allowance), then calls a downstream protocol function that ITSELF reverts, Solidity propagates the revert UP through `bridge()` → `depositAndBridge()` → entire transaction reverts. The `safeTransferFrom` is also reverted. This case is safe.

4. **The real risk — future adapter**: A future adapter implementation (or an attacker who compromises adapter authorization and deploys a malicious adapter) could call `_bridge()` with a code path that does NOT consume the allowance. After `depositAndBridge` succeeds, the malicious adapter retains a live `effectiveAmount` allowance from the escrow. In a subsequent transaction, it can call `IERC20(asset).transferFrom(escrow, attacker, effectiveAmount)` to drain the approved amount from the escrow.

### Code Location

- File: `src/bridge/BridgeEscrow.sol`
- Function: `depositAndBridge()`
- Lines: 185–191

```solidity
// @audit forceApprove sets approval from escrow to adapter
IERC20(asset).forceApprove(adapter, effectiveAmount);
// @audit bridge() is called — all current implementations consume the full approval via safeTransferFrom
IBridgeAdapter(adapter).bridge(messagePayload);
// @audit no forceApprove(adapter, 0) reset here — if bridge() leaves partial or full approval, it persists
return invoiceHash;
```

### Comparison: `_fundAndRelease` in BridgeAdapter.sol (approval reset PRESENT)

```solidity
// File: src/bridge/BridgeAdapter.sol, lines 144-146
// @audit reset is present here — approved exactly amount, then reset to 0 after releaseByInvoiceId
IERC20(asset).forceApprove(bridgeEscrow, amount);
IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);
IERC20(asset).forceApprove(bridgeEscrow, 0); // ← present in _fundAndRelease
```

The `_fundAndRelease` pattern is correct and consistent. `depositAndBridge` inconsistently omits the reset.

## Impact

- **Likelihood**: Low with current adapters — all six current adapter implementations (`CcipBridgeAdapter`, `CctpBridgeAdapter`, `AcrossBridgeAdapter`, `StargateBridgeAdapter`, `GnosisBridgeAdapter`, `SuperchainBridgeAdapter`) call `safeTransferFrom(bridgeEscrow, this, data.amount)` in `_bridge()`, fully consuming the approval. The risk is triggered only if a new adapter is deployed that does not fully consume the approval, or if an attacker gains `DEFAULT_ADMIN_ROLE` and authorizes a malicious adapter.
- **Impact**: High — if triggered (residual approval persists), the adapter can drain the escrow's ERC20 balance for the approved token in a subsequent transaction, with no invoice, no recipient validation, and bypassing all replay/checksum guards.
- **Severity**: MEDIUM (low likelihood + high impact)

## Attack Scenario

### Preconditions

- A new adapter is deployed and authorized that does NOT call `safeTransferFrom(bridgeEscrow, ...)` in `_bridge()`.
- Alternatively, the MANAGER/admin is compromised and authorizes a malicious adapter.
- The escrow holds ERC20 balance for a registered asset (e.g., USDC from prior operations or a direct donation).

### Attack Steps

1. Attacker deploys a malicious adapter that implements `IBridgeAdapter` and `ERC165` but whose `_bridge()` does NOT call `IERC20(asset).safeTransferFrom(bridgeEscrow, ...)`.
2. Compromised admin calls `escrow.authorizeAdapter(maliciousAdapter)`.
3. Authorized account calls `depositAndBridge(dstChain, "USDC", 100_000e6, maliciousAdapter)`.
4. Escrow: records invoice, calls `forceApprove(maliciousAdapter, 100_000e6)`, calls `maliciousAdapter.bridge(payload)`.
5. `maliciousAdapter._bridge()` does NOT call `safeTransferFrom` — it just records the payload and returns.
6. `depositAndBridge` returns successfully. Escrow-to-maliciousAdapter allowance = 100,000 USDC still open.
7. In a subsequent transaction, attacker calls `IERC20(USDC).transferFrom(escrow, attacker, 100_000e6)` — succeeds using the residual allowance.
8. 100,000 USDC drained from the escrow without any legitimate release.

### Expected Impact

- Residual ERC20 allowance exploited to drain escrow balance for the approved asset.
- No invoice is marked completed; `_inTransitBalances` remains inflated; in-transit tracking desynchronized.

## Recommended Mitigation

Add a `forceApprove` reset after `bridge()` returns in `depositAndBridge`, mirroring the pattern in `_fundAndRelease`:

```solidity
// Hand funds to the adapter to dispatch.
if (_isNativeToken(asset)) {
    (bool success,) = adapter.call{value: effectiveAmount}("");
    if (!success) revert TransferFailed();
} else {
    IERC20(asset).forceApprove(adapter, effectiveAmount);
}

IBridgeAdapter(adapter).bridge(messagePayload);

// @fix add reset to clear any unconsumed approval (defensive CEI — mirrors _fundAndRelease)
if (!_isNativeToken(asset)) {
    IERC20(asset).forceApprove(adapter, 0);
}

return invoiceHash;
```

This ensures that if a future adapter does not fully consume the approval, the residual allowance is cleared before `depositAndBridge` returns.
