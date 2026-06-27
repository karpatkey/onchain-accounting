# H-01: AcrossBridgeAdapter Source Authentication Is Tautological — No Real Sibling Verification

## Summary

`AcrossBridgeAdapter._authenticateSource` verifies that `trustedRemoteAdapter[sourceKey] == address(this)`. Because the adapter has the same CREATE2 address on every chain, this check simply asserts that the admin set a non-zero entry equal to the adapter's own address for that chain ID — it does **not** verify that the Across relayer on the destination chain received a fill that was originated by the sibling adapter on the source chain. A malicious Across relayer (or any entity that can call `handleV3AcrossMessage` after the SpokePool transfers tokens) can craft a message payload claiming any source chain ID and any account, pass the tautological check, and trigger a release for an invoice that was never deposited.

## Vulnerability Detail

### Root Cause

`_authenticateSource` in `AcrossBridgeAdapter` is:

```solidity
// @audit sourceKey and claimedSourceChainId are BOTH derived from data.sourceChainId in the payload
// @audit the check only verifies trustedRemoteAdapter[sourceKey] == address(this), i.e. self-reference
function _authenticateSource(uint64 sourceKey, uint24 claimedSourceChainId) internal view {
    if (sourceKey == 0 || uint256(sourceKey) != uint256(claimedSourceChainId)) revert InvalidBridgeData();
    bytes32 trusted = trustedRemoteAdapter[sourceKey];
    if (trusted == bytes32(0) || trusted != _toBytes32(address(this))) revert InvalidBridgeData();
}
```

Both parameters (`sourceKey` and `claimedSourceChainId`) are derived from the same field — `data.sourceChainId` extracted from the attacker-supplied `message` payload. The comparison `uint256(sourceKey) != uint256(claimedSourceChainId)` is therefore always true (equal) for any valid source chain ID. The only condition that matters is:

```solidity
trustedRemoteAdapter[sourceKey] != bytes32(0) && trustedRemoteAdapter[sourceKey] == _toBytes32(address(this))
```

For every chain that the admin has configured (via `setTrustedRemoteAdapter`), this check passes as long as the admin stored the adapter's own address. This is the expected configuration for CREATE2 same-address deployments, so it will be true for all configured chains. The check is therefore satisfied for any `sourceChainId` that the admin has configured — regardless of whether any genuine deposit ever happened on that chain.

The call site in `handleV3AcrossMessage`:

```solidity
// @audit data.sourceChainId comes directly from the attacker-supplied message parameter
_authenticateSource(uint64(data.sourceChainId), data.sourceChainId);
```

There is no cross-chain binding: Across delivers tokens to the adapter and calls `handleV3AcrossMessage` with a message that the **relayer** (not the source chain adapter) supplied. A malicious relayer can craft `message` with a fabricated invoice payload pointing to any authorized account and any amount, as long as the `sourceChainId` field encodes a chain that the adapter has configured.

### Code Location

- File: `src/bridge/adapters/AcrossBridgeAdapter.sol`
- Function: `_authenticateSource()`
- Lines: 254–258

```solidity
// @audit both args derive from data.sourceChainId — comparing x == x is always true
function _authenticateSource(uint64 sourceKey, uint24 claimedSourceChainId) internal view {
    if (sourceKey == 0 || uint256(sourceKey) != uint256(claimedSourceChainId)) revert InvalidBridgeData();
    bytes32 trusted = trustedRemoteAdapter[sourceKey];
    // @audit this checks adapter == address(this), which is always true for any configured chain
    if (trusted == bytes32(0) || trusted != _toBytes32(address(this))) revert InvalidBridgeData();
}
```

- File: `src/bridge/adapters/AcrossBridgeAdapter.sol`
- Function: `handleV3AcrossMessage()`
- Line: 216

```solidity
// @audit sourceKey == data.sourceChainId == claimedSourceChainId: all three are the same value
_authenticateSource(uint64(data.sourceChainId), data.sourceChainId);
```

## Impact

- **Likelihood**: High — any entity that can get the Across SpokePool to transfer tokens to the adapter and call `handleV3AcrossMessage` with a crafted message can trigger this. Across relayers are permissionless; any relayer can fill a deposit and craft the message.
- **Impact**: High — unauthorized release of funds. An attacker who seeds the adapter with any small amount of the target token can trigger `releaseByInvoiceId` for an arbitrary authorized account with any amount that the adapter's balance covers.
- **Severity**: HIGH

## Attack Scenario

### Preconditions

- AcrossBridgeAdapter is deployed on destination chain (e.g., Base).
- `trustedRemoteAdapter[1]` (Ethereum) is set to `address(this)` (normal configuration).
- The escrow on the destination chain has an authorized account with a pending or future invoice.
- Attacker has a small amount of the bridgeable token.

### Attack Steps

1. Attacker deposits a small amount of USDC (e.g., 1 wei) into the Across SpokePool on the destination chain, specifying the AcrossBridgeAdapter as the output recipient and crafting the `message` field as an encoded `InvoiceData` with: `sourceChainId = 1` (Ethereum, a configured chain), `account = victim_authorized_account`, `amount = X` (any amount the adapter has or will have from the legitimate fill).
2. A real legitimate Across relayer (or attacker as relayer) fills the deposit, causing the SpokePool to transfer `1 wei` USDC to the adapter and call `handleV3AcrossMessage(USDC, 1 wei, relayer, crafted_message)`.
3. Inside `handleV3AcrossMessage`: `msg.sender == spokePool` passes. `tokenSent == USDC` (matches registered asset). `amount (1) >= data.amount (1)` passes.
4. `_authenticateSource(1, 1)` is called. `sourceKey (1) != 0` and `sourceKey == claimedSourceChainId` — first check passes. `trustedRemoteAdapter[1] == _toBytes32(address(this))` — passes because admin configured it this way.
5. `_verifyDelivered` checks adapter balance >= 1 — passes (SpokePool just delivered 1 wei).
6. `_fundAndRelease` is called. Escrow validates the crafted payload's checksum (the attacker computed a valid checksum offline since all inputs are public). `completedInvoices[invoiceHash]` is false (fresh payload). Escrow calls `safeTransferFrom(adapter, victim_account, 1)` — 1 wei USDC is released.

Variation: If a legitimate invoice for a large amount is in-flight on Across, attacker crafts a message with the real invoice fields but substitutes their own account (if the account was authorized) or uses a separate legitimate invoice's data. The `completedInvoices` replay guard on the **destination** escrow prevents reuse, but a first-time crafted invoice bypasses it entirely.

### Expected Impact

- Unauthorized release of any amount the adapter holds to any authorized account, without a corresponding source-chain deposit.
- In the worst case, if tokens accumulate in the adapter between fills, attacker can drain the accumulated balance.

## Recommended Mitigation

Across V3 does not expose the source-chain depositor on the fill. The only binding between source and destination in Across is the message content itself. To harden this, the adapter must ensure the message was authored by the genuine source-chain sibling. Options:

1. **Bind the deposit ID into the payload and verify with the SpokePool**: Across V3 `depositV3` returns a deposit ID (emitted in `FundsDeposited` event). On the destination, the SpokePool's `fillV3Relay` emits the same deposit ID. Store a mapping of expected `(sourceChainId, depositId) → invoiceId` on the source chain and include `depositId` in the cross-chain message, then on the destination call `spokePool.fillStatuses(depositId)` to verify the fill matches the expected deposit.
2. **Require a signed payload**: Encode the invoice as the Across deposit's `message` and include a signature from the source-chain escrow/adapter. The destination verifies the signature against the known source-chain address.
3. **At minimum, validate the payload against source-chain invoice data through a separate oracle or relay before releasing**.
