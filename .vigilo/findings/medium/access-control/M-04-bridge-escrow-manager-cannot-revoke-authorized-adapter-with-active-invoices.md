# M-04: `BridgeEscrow.revokeAdapter` Has No Guard on In-Flight Invoices — MANAGER Can Strand In-Transit Funds

## Summary

`BridgeEscrow.revokeAdapter` removes an adapter from the authorized set without checking whether any active (BRIDGING) invoices were created via that adapter. If the adapter is revoked while a cross-chain transfer is in flight, the destination-side call to `releaseByInvoiceId` (which requires `_authorizedAdapters.contains(msg.sender)`) will revert, permanently locking the funds in transit.

## Vulnerability Detail

### Root Cause

`revokeAccount` correctly guards against active invoices:

```solidity
// src/bridge/BridgeEscrow.sol:499-503
function revokeAccount(address safe) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_activeInvoices[safe].length > 0) revert AccountHasActiveInvoices(safe); // @audit guard present
    _authorizedAccounts.remove(safe);
}
```

But `revokeAdapter` has no analogous check:

```solidity
// src/bridge/BridgeEscrow.sol:511-514
// @audit No check for active invoices created via this adapter
function revokeAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _authorizedAdapters.remove(adapter);
    emit AdapterRevoked(adapter);
}
```

The `invoices` mapping stores the adapter address for each invoice (`invoice.adapter`), so the data to perform this check exists on-chain.

### Affected Paths

When `releaseByInvoiceId` is called on the destination chain by the (now-revoked) adapter:

```solidity
// src/bridge/BridgeEscrow.sol:203
function releaseByInvoiceId(bytes calldata messagePayload) external payable nonReentrant whenNotPaused {
    // @audit Reverts if adapter was revoked since invoice creation
    if (!_authorizedAdapters.contains(msg.sender)) revert NotAuthorized();
    ...
}
```

The release fails permanently. Funds are delivered to the adapter but cannot be forwarded to the account. The adapter holds the funds. `cancelInvoice` on the source chain cannot help because the source-chain invoice is in BRIDGING state and the funds have already left the source chain.

## Impact

- **Likelihood**: Low — requires an operational error (admin revokes adapter while bridging is active) or deliberate misuse of MANAGER powers.
- **Impact**: High — user funds are permanently locked in the destination adapter. No recovery path exists unless the adapter is re-authorized, funds are recovered via `recoverStuckAssets` (MANAGER-gated on the adapter), and then manually returned to the user.

The `recoverStuckAssets` path in `BridgeAdapter` only delivers to `bridgeEscrow` or escrow-authorized accounts, so an authorized account can receive the stuck funds — but this is a manual out-of-band recovery, not an on-chain invariant.

## Attack Scenario

### Preconditions
- An active bridge invoice exists (status BRIDGING) for a user via `CcipBridgeAdapter`.
- The bridge message is in transit (has left the source chain, not yet delivered on destination).

### Steps
1. `DEFAULT_ADMIN_ROLE` holder calls `BridgeEscrow.revokeAdapter(ccipAdapterAddress)` — perhaps as routine adapter rotation or due to an emergency pause decision.
2. The CCIP protocol delivers the bridged tokens to `CcipBridgeAdapter` on the destination chain and calls `ccipReceive`.
3. `ccipReceive` calls `_fundAndRelease` → `BridgeEscrow.releaseByInvoiceId`.
4. `releaseByInvoiceId` checks `_authorizedAdapters.contains(msg.sender)` → returns false (adapter revoked) → reverts with `NotAuthorized`.
5. The user does not receive their funds.
6. The adapter now holds the bridged tokens with no automatic refund path.
7. MANAGER must manually call `adapter.recoverStuckAssets(asset, amount, authorizedAccount)` and then arrange an out-of-band refund to the user.

## Recommended Mitigation

Add an active-invoice check to `revokeAdapter`, mirroring the `revokeAccount` guard:

```solidity
function revokeAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
    // Check no active invoices were created via this adapter
    if (_hasActiveInvoicesForAdapter(adapter)) revert AdapterHasActiveInvoices(adapter);
    _authorizedAdapters.remove(adapter);
    emit AdapterRevoked(adapter);
}

function _hasActiveInvoicesForAdapter(address adapter) internal view returns (bool) {
    uint256 safeCount = _authorizedAccounts.length();
    for (uint256 i = 0; i < safeCount; i++) {
        address safe = _authorizedAccounts.at(i);
        bytes32[] memory activeInvoiceHashes = _activeInvoices[safe];
        for (uint256 j = 0; j < activeInvoiceHashes.length; j++) {
            if (invoices[activeInvoiceHashes[j]].adapter == adapter) return true;
        }
    }
    return false;
}
```

Alternatively, document that adapter revocation must be preceded by a `cancelInvoice` for all active invoices using that adapter, and emit a warning in the contract if it is revoked with no pre-check.
