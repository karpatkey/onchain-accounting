# M-02: cancelInvoice Requires Escrow to Hold the Bridged Amount, But Funded Pass-Through Forwards Funds to the Adapter

## Summary

`BridgeEscrow.cancelInvoice` checks that the escrow contract itself holds sufficient balance before returning funds to the depositor. However, under the funded pass-through model (ADR 0012), when `depositAndBridge` is called, the escrow immediately forwards the deposited funds to the bridge adapter (lines 182–188). By the time a manager calls `cancelInvoice`, the escrow holds no ERC20 tokens for that invoice — the funds are in the bridge adapter or already in the bridge protocol. The balance check at line 262 will fail with `InsufficientBalance`, making ERC20 invoice cancellation permanently impossible.

## Vulnerability Detail

### Root Cause

In `depositAndBridge`, after recording the invoice, the escrow hands funds to the adapter:

```solidity
// @audit after depositAndBridge, tokens are in the adapter, NOT in the escrow
if (_isNativeToken(asset)) {
    (bool success,) = adapter.call{value: effectiveAmount}("");
    if (!success) revert TransferFailed();
} else {
    IERC20(asset).forceApprove(adapter, effectiveAmount);
}
IBridgeAdapter(adapter).bridge(messagePayload);
```

For ERC20 tokens: `forceApprove(adapter, effectiveAmount)` approves the adapter, and `adapter.bridge(messagePayload)` immediately calls `IERC20(asset).safeTransferFrom(bridgeEscrow, address(this), data.amount)` inside `_bridge`. After `depositAndBridge` returns, the ERC20 tokens are in the adapter's balance, not the escrow's.

Then in `cancelInvoice`:

```solidity
// @audit checks escrow's own balance — but tokens are in the adapter, not here
uint256 balance = _isNativeToken(asset) ? address(this).balance : IERC20(asset).balanceOf(address(this));
if (balance < amount) revert InsufficientBalance(asset, amount, balance);
```

For ERC20, `IERC20(asset).balanceOf(address(this))` is 0 (or less than `amount`), so the check reverts with `InsufficientBalance`. The cancellation is impossible.

For native ETH, `depositAndBridge` sends ETH to the adapter via `.call{value: effectiveAmount}`, so the escrow also has no ETH balance for the invoice — same problem.

After the adapter's `bridge()` call, funds are typically already in the bridge protocol (SpokePool, CCIP router, Stargate pool, etc.), so the adapter itself also has no balance. Neither the escrow nor the adapter holds the funds once bridging is initiated.

### Code Location

- File: `src/bridge/BridgeEscrow.sol`
- Function: `cancelInvoice()`
- Lines: 250–280

```solidity
// @audit checks escrow balance, but funds left escrow when depositAndBridge was called
function cancelInvoice(bytes32 invoiceHash) external override onlyRole(MANAGER_ROLE) nonReentrant {
    ...
    uint256 balance = _isNativeToken(asset) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    // @audit this will be 0 for ERC20 (funds are in the bridge protocol), causing revert
    if (balance < amount) revert InsufficientBalance(asset, amount, balance);
    ...
    // Interaction: transfer from escrow to account
    IERC20(asset).safeTransfer(account, amount);
}
```

- File: `src/bridge/BridgeEscrow.sol`
- Function: `depositAndBridge()`
- Lines: 182–189

```solidity
// @audit funds leave the escrow here — after this, escrow has no tokens for the invoice
if (_isNativeToken(asset)) {
    (bool success,) = adapter.call{value: effectiveAmount}("");
    if (!success) revert TransferFailed();
} else {
    IERC20(asset).forceApprove(adapter, effectiveAmount);
}
IBridgeAdapter(adapter).bridge(messagePayload); // adapter pulls tokens from escrow here
```

## Impact

- **Likelihood**: High — any ERC20 bridge operation that is cancelled will hit this code path. The funded pass-through model is the design for all ERC20 bridges.
- **Impact**: Medium — cancellation is permanently bricked for ERC20 invoices. Users cannot recover funds from failed bridge operations through the cancel path. The manager must use `recoverStuckAssets` on the adapter (if funds are stuck there) or a separate process, and then manually return funds — which is not atomic and requires additional trust.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- An authorized account has a `BRIDGING` ERC20 invoice that needs to be cancelled (e.g., bridge failure, wrong parameters, user request).
- Funds have been deposited and forwarded to the bridge adapter/protocol.

### Attack Steps

1. User calls `BridgeEscrow.depositAndBridge(destinationChainId, "USDC", 100_000e6, acrossAdapter)`.
2. Escrow: records invoice, approves adapter, calls `adapter.bridge(payload)`. AcrossBridgeAdapter pulls 100,000 USDC from escrow, deposits into SpokePool.
3. The Across deposit fails to fill (relayer not available, deadline passed).
4. Manager calls `BridgeEscrow.cancelInvoice(invoiceHash)` to refund the user.
5. `cancelInvoice` reaches line 262: `uint256 balance = IERC20(USDC).balanceOf(address(escrow))` → `balance = 0`.
6. `balance < amount` → `revert InsufficientBalance(USDC, 100_000e6, 0)`.
7. Cancellation fails. User cannot recover funds through `cancelInvoice`.

### Expected Impact

- Stuck funds: user's bridged tokens cannot be refunded via the `cancelInvoice` mechanism.
- Operational burden: manager must recover funds through `recoverStuckAssets` on the adapter (which first requires the adapter to hold the funds — only possible if the bridge protocol returned them) and then coordinate a separate transfer back to the user.
- The `_inTransitBalances` cache remains inflated (never decremented), causing NAV to overcount the in-transit balance for the affected account.

## Recommended Mitigation

`cancelInvoice` should not attempt to transfer from the escrow's own balance. The funded pass-through model requires a different cancel path:

1. **For protocols that support deposit cancellation** (e.g., Across: unfilled deposit can be speed-up or refunded via `speedUpV3Deposit`/SpokePool), expose a protocol-specific cancel function on the adapter that retrieves funds from the bridge protocol and returns them to the escrow, then call `cancelInvoice` with the escrow now holding the funds.

2. **Alternatively**: remove the balance check from `cancelInvoice` entirely and instead require the manager to pre-fund the escrow with the cancellation amount (via `recoverStuckAssets` or direct transfer) before calling `cancelInvoice`. Document this two-step process.

3. **Simplest fix**: Add a `recoverAndCancel(invoiceHash)` function on the adapter that: (a) retrieves funds from the bridge protocol if possible, (b) transfers to the escrow, (c) calls `escrow.cancelInvoice(invoiceHash)`. Gate it with `MANAGER_ROLE`.
