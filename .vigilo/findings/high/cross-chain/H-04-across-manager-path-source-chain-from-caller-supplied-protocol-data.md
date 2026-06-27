# H-04: AcrossBridgeAdapter Manager-Path Source Chain ID Comes From Caller-Supplied protocolData — Manager Can Release Without Genuine Across Delivery

## Summary

`AcrossBridgeAdapter._completeBridge` extracts `sourceChainId` from caller-supplied `protocolData`, not from a verified message. The source authentication check (`_authenticateSource`) then verifies that this caller-supplied chain ID equals the `sourceChainId` in the caller-supplied `messagePayload`, and that the configured `trustedRemoteAdapter` for that chain ID equals the adapter's own address. A MANAGER who supplies a forged `messagePayload` plus matching `protocolData` passes both checks without any genuine Across delivery having occurred, enabling unauthorized release from the adapter's balance.

## Vulnerability Detail

### Root Cause

In `_completeBridge`, `sourceChainId` is decoded from `protocolData`, which is caller-supplied:

```solidity
// @audit sourceChainId extracted from caller-supplied protocolData
uint32 depositId = 0;
uint256 sourceChainId = 0;
if (protocolData.length >= 64) {
    (depositId, sourceChainId) = abi.decode(protocolData, (uint32, uint256));
}
// @audit sourceKey == uint64(sourceChainId) from protocolData
// @audit data.sourceChainId from messagePayload (also caller-supplied)
_authenticateSource(uint64(sourceChainId), data.sourceChainId);
```

`_authenticateSource` verifies:
1. `sourceKey != 0` (non-zero chain ID)
2. `sourceKey == claimedSourceChainId` (both from caller-controlled inputs — trivially satisfied by providing matching values)
3. `trustedRemoteAdapter[sourceKey] != bytes32(0)` (requires the chain to be configured)
4. `trustedRemoteAdapter[sourceKey] == _toBytes32(address(this))` (tautological: requires adapter's own address to be stored)

A MANAGER passes all four checks by providing:
- `messagePayload` with `sourceChainId = 1` (Ethereum — any configured chain)
- `protocolData = abi.encode(uint32(0), uint256(1))` (matching sourceChainId = 1)

Additionally, `_verifyDelivered` checks that the adapter holds at least `data.amount`:

```solidity
// @audit requires adapter to hold the tokens — but tokens may have accumulated from previous legitimate fills
address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
_verifyDelivered(asset, data.amount);
```

If the adapter has accumulated any balance (from a previous delivery where `handleV3AcrossMessage` did not trigger, or from a reward overpayment), the manager can release that balance to any authorized account with a forged payload.

### Comparison to Auto Path

In the auto path (`handleV3AcrossMessage`), `msg.sender == spokePool` is verified. The Across SpokePool is a genuine protocol contract that only calls `handleV3AcrossMessage` after actually filling a relay. This provides real provenance. 

In the manager path, there is **no protocol-contract verification** — the manager's word is the sole input. While MANAGER is a trusted role, the entire ADR 0012 re-architecture was motivated by eliminating trust in roles for the release path (CRITICAL finding C1 was that MANAGER could release without genuine delivery). The manager path for Across reintroduces a weakened version of this: a MANAGER can release any tokens the adapter holds to any authorized account.

### Code Location

- File: `src/bridge/adapters/AcrossBridgeAdapter.sol`
- Function: `_completeBridge()`
- Lines: 157–179

```solidity
// @audit sourceChainId from protocolData — caller-supplied, no protocol-contract verification
function _completeBridge(bytes calldata messagePayload, bytes calldata protocolData) internal override {
    if (messagePayload.length == 0) revert InvalidCompletionData();
    InvoiceDataLib.InvoiceData memory data = InvoiceDataLib.decode(messagePayload);

    uint32 depositId = 0;
    uint256 sourceChainId = 0;
    if (protocolData.length >= 64) {
        // @audit sourceChainId is what the MANAGER claims, not what Across proved
        (depositId, sourceChainId) = abi.decode(protocolData, (uint32, uint256));
    }
    // @audit sourceKey == data.sourceChainId is trivially true when both are manager-controlled
    _authenticateSource(uint64(sourceChainId), data.sourceChainId);

    address asset = IBridgeEscrow(bridgeEscrow).assetRegistry(InvoiceDataLib.bytes6ToStr(data.assetSymbol));
    // @audit verifies adapter holds tokens, but adapter may hold tokens from prior legitimate deliveries
    _verifyDelivered(asset, data.amount);
    ...
}
```

## Impact

- **Likelihood**: Low — requires a compromised or malicious MANAGER.
- **Impact**: High — MANAGER can release any tokens held by the adapter to any authorized account with a forged invoice payload, bypassing the provable-release guarantee.
- **Severity**: HIGH (unauthorized release from a trusted-role exploit, consistent with the ADR 0012 threat model)

## Attack Scenario

### Preconditions

- MANAGER role is compromised.
- AcrossBridgeAdapter holds any amount of a registered token (accumulated from a prior legitimate delivery or overpayment).
- MANAGER knows the address of an authorized account they control.

### Attack Steps

1. Attacker compromises the MANAGER role (or is a malicious insider).
2. Attacker constructs a forged `messagePayload` encoding `InvoiceData` with: `sourceChainId = 1` (Ethereum — configured), `account = attacker_authorized_account`, `amount = X` (whatever the adapter holds), valid `invoiceId` (not yet in `completedInvoices`), valid `checksum24` (computed offline since all inputs are public).
3. Attacker constructs `protocolData = abi.encode(uint32(0), uint256(1))`.
4. Attacker calls `adapter.completeBridge(forgedPayload, protocolData)`.
5. `_completeBridge`: `sourceChainId = 1`, `_authenticateSource(1, 1)` passes. `_verifyDelivered` passes (adapter holds X tokens).
6. Base `completeBridge` calls `_fundAndRelease(forgedPayload, asset, X)`. Escrow validates checksum (attacker computed correctly). `completedInvoices[hash]` is false. Escrow releases X tokens to `attacker_authorized_account`.

### Expected Impact

- Tokens held by the adapter released to attacker-controlled account without a genuine Across delivery.
- The forged invoice is recorded as completed, blocking the legitimate invoice from ever completing if it shares the same hash (unlikely but possible given 192-bit truncation).

## Recommended Mitigation

For the manager path, instead of relying on the caller's claimed `sourceChainId`, require the MANAGER to provide verifiable proof from the Across protocol:

1. **Require the Across deposit ID**: Store the deposit ID at deposit time (SpokePool emits a `FundsDeposited` event with the deposit ID). On the manager path, require the manager to provide the deposit ID and verify `spokePool.fillStatuses(depositId)` is `Filled`.

2. **Alternatively**: Remove the manager path for Across entirely. Across V3 fill failures are handled by the depositor (unfilled deposits are refunded to the depositor on the source chain after the fill deadline passes). The adapter should not hold the completed-delivery responsibility for the manager in this case.

3. **At minimum**: Require the manager path's `protocolData` to include an Across V3 fill proof (fill details that can be verified against the SpokePool's `fillStatuses` or `relayFills` mappings), and add that verification before allowing `_fundAndRelease`.
