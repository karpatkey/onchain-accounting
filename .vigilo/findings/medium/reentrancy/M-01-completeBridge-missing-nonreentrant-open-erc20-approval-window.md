# M-01: `BridgeAdapter.completeBridge` Lacks `nonReentrant` — Open ERC20 Approval Enables Callback Re-Entry

## Summary

`BridgeAdapter.completeBridge` is the MANAGER-operated completion path present on all six bridge adapters. Unlike every auto-path callback (`ccipReceive`, `lzCompose`, `handleV3AcrossMessage`, `onTokenTransfer`, `completeDeposit`), `completeBridge` carries **no `nonReentrant` guard**. Inside `_fundAndRelease`, the adapter sets `forceApprove(bridgeEscrow, amount)` then calls `IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload)`. During `releaseByInvoiceId`, the escrow calls `IERC20(asset).safeTransferFrom(adapter, account, amount)`, which triggers an ERC-777 `tokensReceived` hook on `account`. At that moment, `forceApprove(bridgeEscrow, amount)` is still live on the ERC-777 token and `completeBridge`'s call frame is re-enterable. A `data.account` contract that has been granted `MANAGER_ROLE` — or whose hook dispatches to an entity with `MANAGER_ROLE` — can re-enter `completeBridge` with a second invoice payload while the first call is mid-flight and the adapter balance check has not yet been re-evaluated for the re-entrant invoice.

## Vulnerability Detail

### Root Cause

`completeBridge` in `BridgeAdapter.sol` (line 122) has no reentrancy guard:

```solidity
// @audit no nonReentrant modifier — unlike ccipReceive, lzCompose, handleV3AcrossMessage,
// @audit onTokenTransfer, and completeDeposit, all of which carry nonReentrant
function completeBridge(bytes calldata messagePayload, bytes calldata protocolData) external override {
    if (!hasRole(MANAGER_ROLE, msg.sender)) revert NotAuthorized();
    ...
    _completeBridge(messagePayload, protocolData);
    address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(...);
    _fundAndRelease(messagePayload, asset, data.amount);   // external call without guard
    emit BridgeCompleted(data.invoiceId);
}
```

`_fundAndRelease` for ERC20 assets:

```solidity
// @audit approval is open during the entire releaseByInvoiceId call
IERC20(asset).forceApprove(bridgeEscrow, amount);
IBridgeEscrow(bridgeEscrow).releaseByInvoiceId(messagePayload);   // @audit external call
// @audit if re-entry occurs before this line, forceApprove(0) is never called
IERC20(asset).forceApprove(bridgeEscrow, 0);
```

Inside `BridgeEscrow.releaseByInvoiceId` the funded pass-through transfer fires:

```solidity
// @audit completedInvoices set first (good CEI for this invoice)
completedInvoices[invoiceHash] = true;
...
// @audit ERC-777 hook fires here on account — completeBridge re-enterable at this point
IERC20(asset).safeTransferFrom(msg.sender, data.account, data.amount);
```

### State Timeline (re-entrant scenario)

```
T0: adapter holds amount_A + amount_B of ERC-777 asset
T1: MANAGER calls completeBridge(payloadA) — invoice A
T2: _completeBridge(A) runs (CCTP mints, etc.)
T3: forceApprove(escrow, amount_A) ← approval OPEN
T4: releaseByInvoiceId(payloadA) called
T5:   completedInvoices[hashA] = true
T6:   safeTransferFrom(adapter → accountA) triggers ERC-777 hook
T7:     [RE-ENTRY] accountA hook calls completeBridge(payloadB) — invoice B
T8:       _completeBridge(B) runs (CCTP mints again — or uses already-held balance)
T9:       forceApprove(escrow, amount_B) ← second approval (overrides A's)
T10:      releaseByInvoiceId(payloadB) called
T11:        completedInvoices[hashB] = true
T12:        safeTransferFrom(adapter → accountB) — amount_B transferred
T13:      forceApprove(escrow, 0) ← approval reset for B
T14:  T6 resumes: amount_A transferred to accountA
T15: forceApprove(escrow, 0) ← approval reset for A
```

At T9, the approval for A (`amount_A`) was clobbered by B's `forceApprove`. This means the escrow's `safeTransferFrom` at T14 still succeeds only because ERC-777's `safeTransferFrom` reads the allowance at execution time (T14), which was reset to 0 by T13. Whether `safeTransferFrom` at T14 succeeds or reverts depends on token implementation; for standard ERC-20 with ERC-777 hooks this fails, but `safeTransferFrom` reverts the outer tx only if `releaseByInvoiceId` also reverts — and `releaseByInvoiceId` is `nonReentrant`, so it does not permit the recursive invocation from T10. Wait — `releaseByInvoiceId` at T10 is called from the adapter (re-entering `completeBridge`), which is a different call frame from T4. OZ's `ReentrancyGuard` on `BridgeEscrow` uses a single `_status` variable shared across all `nonReentrant` functions on the same instance, so T10's call to `releaseByInvoiceId` IS blocked by the escrow's guard.

**Revised timeline after applying escrow's nonReentrant:**

The re-entrant `completeBridge(payloadB)` at T7 proceeds through `_completeBridge(B)` successfully, then calls `_fundAndRelease` → `forceApprove(escrow, amount_B)` → `releaseByInvoiceId(payloadB)` — but this REVERTS with `ReentrancyGuardReentrantCall` because the escrow's `nonReentrant` mutex is held by T4's `releaseByInvoiceId`.

The revert at T10 propagates upward, reverting T7–T13. The entire re-entrant `completeBridge(payloadB)` reverts. Control returns to T6.

**However**, the following asymmetry remains:

1. For adapters that call `messageTransmitter.receiveMessage` (CCTP) inside `_completeBridge`: if re-entry gets far enough to invoke `receiveMessage`, Circle's nonce is consumed even if the outer tx reverts (see M-05 cross-chain finding). In a re-entrant scenario, `_completeBridge(B)` at T8 may have called `receiveMessage`, consuming invoice B's CCTP nonce permanently before the revert unwinds the adapter's state.

2. The `forceApprove(escrow, amount_B)` at T9 (inside re-entrant `completeBridge`) overwrites the approval set at T3 (`amount_A`). When T14 executes (`safeTransferFrom` for invoice A), the allowance is 0 (reset to 0 by T13 if T9's revert did NOT unwind it — but it did because T10 reverted, which cascades). ERC-20 reverts cascade, so T9's `forceApprove` is unwound. This path is safe.

3. **Real risk**: If an adapter's `_completeBridge` involves a non-reverting external state mutation (e.g., nonce consumption at Circle, LayerZero endpoint state) and the re-entrant `completeBridge` gets that far before the escrow's `nonReentrant` blocks the release, that nonce may be permanently consumed with no corresponding release.

### Code Location

- File: `src/bridge/BridgeAdapter.sol`
- Function: `completeBridge()`
- Lines: 122–130

```solidity
// @audit missing nonReentrant — every auto-path callback has it; this manager path does not
function completeBridge(bytes calldata messagePayload, bytes calldata protocolData) external override {
    if (!hasRole(MANAGER_ROLE, msg.sender)) revert NotAuthorized();
    if (messagePayload.length == 0) revert InvalidCompletionData();
    InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);
    _completeBridge(messagePayload, protocolData);
    address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
    _fundAndRelease(messagePayload, asset, data.amount);
    emit BridgeCompleted(data.invoiceId);
}
```

## Impact

- **Likelihood**: Low — requires MANAGER to be a contract whose execution flow can be influenced by `data.account` (e.g., MANAGER is a multisig or keeper contract that dispatches based on callbacks), AND the bridged asset must support ERC-777 `tokensReceived` hooks or equivalent (or the adapter's `_completeBridge` must trigger re-entry through the protocol layer).
- **Impact**: Medium — the direct exploit (double-release) is blocked by the escrow's `nonReentrant`. The residual impact is: (a) externally irreversible protocol state mutations (CCTP nonce, LZ endpoint) may be consumed without a corresponding release, permanently locking the invoice; (b) incomplete approval cleanup leaves a transient `forceApprove` window that other contracts observing the adapter's state can detect.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- A CCTP bridge operation is completing via the MANAGER path.
- The `data.account` in the invoice is a contract with an ERC-777 `tokensReceived` hook.
- The MANAGER is a contract that can be triggered by the `data.account` hook (e.g., a keeper that dispatches upon receiving tokens).

### Attack Steps

1. Authorized account deposits USDC (ERC-777 supported) and a CCTP bridge operation creates invoice A with `data.account = maliciousContract`.
2. A second CCTP invoice B also has `data.account` pointing to `maliciousContract` or a related address.
3. MANAGER calls `CctpBridgeAdapter.completeBridge(payloadA, protocolDataA)`.
4. Inside `_completeBridge(A)`: `usedNonces[A.domain][A.nonce] = true`, `receiveMessage` mints USDC to adapter (Circle nonce A consumed).
5. `_fundAndRelease`: `forceApprove(escrow, amount_A)` → `releaseByInvoiceId(payloadA)`.
6. Escrow marks `completedInvoices[hashA] = true`, calls `safeTransferFrom(adapter, maliciousContract, amount_A)`.
7. `maliciousContract.tokensReceived` fires. It calls `CctpBridgeAdapter.completeBridge(payloadB, protocolDataB)` (MANAGER role check — assume MANAGER contract forwards).
8. Inside re-entrant `_completeBridge(B)`: `usedNonces[B.domain][B.nonce] = true`, `receiveMessage` called — Circle nonce B consumed.
9. `_fundAndRelease`: `forceApprove(escrow, amount_B)` → `releaseByInvoiceId(payloadB)` — REVERTS with `ReentrancyGuardReentrantCall` (escrow's nonReentrant mutex is held).
10. Entire re-entrant `completeBridge(B)` reverts: `usedNonces[B.domain][B.nonce]` unwound to false. BUT Circle's nonce B is NOT unwound (irreversible external mutation).
11. Future retries of `completeBridge(payloadB, protocolDataB)` call `receiveMessage` again, which Circle rejects (nonce B already used). `MessageReceiveFailed` revert. Invoice B permanently stuck.

### Expected Impact

- Invoice B permanently bricked: Circle nonce consumed but adapter state reverted.
- USDC for invoice B potentially stranded in the adapter (Circle minted to adapter at step 8 — if `receiveMessage` succeeded before the revert propagated, USDC is in adapter but the tx reverts mean the USDC was never received either — actually, EVM reverts do not unwind external contract state mutations, so if Circle's `receiveMessage` succeeded and minted USDC before the revert, the USDC IS in the adapter and Circle's nonce IS consumed, but the adapter's local state is reverted. Recovery requires `recoverStuckAssets`).

## Recommended Mitigation

Add `nonReentrant` to `completeBridge` in `BridgeAdapter.sol`:

```solidity
function completeBridge(bytes calldata messagePayload, bytes calldata protocolData)
    external
    override
    nonReentrant   // add this
{
    if (!hasRole(MANAGER_ROLE, msg.sender)) revert NotAuthorized();
    ...
}
```

This aligns `completeBridge` with all auto-path callbacks (`ccipReceive`, `lzCompose`, `handleV3AcrossMessage`, `onTokenTransfer`, `completeDeposit`) which already carry `nonReentrant`.
