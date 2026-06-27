# L-03: `BridgeEscrow.registerAsset` Allows Re-pointing a Symbol to a Different Address When No Active Invoices — Race Condition in Multi-Invoice Scenario

## Summary

`BridgeEscrow.registerAsset` allows changing the `asset` address for an already-registered symbol if there are no active invoices referencing it. The check `_hasActiveInvoicesForAsset(sym)` iterates only authorized accounts' active invoice lists. Between the check and the storage write, if a concurrent `depositAndBridge` call creates an invoice for that symbol, the asset address is changed under an in-flight invoice. The in-flight invoice's `invoice.asset` is already written (it was looked up at `depositAndBridge` time), but any subsequent reads by `cancelInvoice` use `invoice.asset` directly — so the risk is limited. However, the `releaseByInvoiceId` path resolves the asset from `_assetRegistry[sym]` at release time, not from the stored invoice, which creates an inconsistency.

## Vulnerability Detail

### Root Cause

In `releaseByInvoiceId`:

```solidity
// src/bridge/BridgeEscrow.sol:224-226
// @audit Asset address resolved from registry AT RELEASE TIME, not from stored invoice
address asset = _assetRegistry[data.assetSymbol];
if (_registeredSymbolsIndex[data.assetSymbol] == 0) revert InvalidArguments();
```

In `registerAsset`:

```solidity
// src/bridge/BridgeEscrow.sol:322-335
// @audit MANAGER can re-point symbol to new address if no active invoices found at check time
function registerAsset(string calldata symbol, address asset) external onlyRole(MANAGER_ROLE) {
    bytes6 sym = InvoiceDataLib.strToBytes6(symbol);
    if (_registeredSymbolsIndex[sym] != 0) {
        if (_assetRegistry[sym] != asset && _hasActiveInvoicesForAsset(sym)) {
            revert AssetHasActiveInvoices(symbol);
        }
        _assetRegistry[sym] = asset; // @audit written even if invoices appear between check and write
    }
    ...
}
```

If `_hasActiveInvoicesForAsset` returns false but an invoice is created in the same block after the check (TOCTOU), `_assetRegistry[sym]` is updated. The invoice created between the check and the update would then have its asset resolved to the new address on release.

## Impact

- **Likelihood**: Very Low — requires same-block MANAGER+user action sequencing in a specific order on Ethereum L1; more plausible on L2s with sequencer manipulation.
- **Impact**: Low — in the worst case, a release resolves to a different `asset` address than the deposited asset, causing the escrow to pull the wrong token from the adapter or fail with InsufficientBalance. No fund theft (the escrow pulls from the adapter, not a pool), but may cause release failure or a wrong-token transfer if the new asset is coincidentally held by the adapter.

## Recommended Mitigation

Resolve the asset address from the stored `invoice.asset` in `releaseByInvoiceId` rather than re-reading from `_assetRegistry` at release time:

```solidity
// Instead of: address asset = _assetRegistry[data.assetSymbol];
// Use the invoice's stored asset (set atomically at deposit time):
// This requires either storing asset in the messagePayload or a separate mapping invoiceHash→asset.
```

Alternatively, document that `MANAGER` must not call `registerAsset` (re-point) while any bridge operation is in flight, and require the same check as `unregisterAsset` (which already blocks if active invoices exist).
