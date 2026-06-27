# H-03: Invoice Replay Guard Keyed by 192-Bit Truncated Hash — Top 8 Bytes Discarded, Reduced Collision Resistance

## Summary

The `completedInvoices` replay guard in `BridgeEscrow` is keyed by `invoiceHash`, which is derived by **discarding the top 8 bytes** of `checksum24` (itself already a 24-byte truncation of a 32-byte keccak256). The net result is that both `invoices` (source chain) and `completedInvoices` (destination chain) are keyed by a **192-bit value**, not 256-bit. Two distinct bridge operations that produce different full keccak256 hashes but share the same lower 192 bits will collide on the `completedInvoices` mapping, causing one to be incorrectly blocked as a replay.

More critically: the replay guard key `invoiceHash` used in `completedInvoices` is the **same 192-bit value** used as the `invoices` mapping key on the **source** chain. If an attacker can engineer two distinct invoice payloads with the same 192-bit `invoiceHash`, the destination treats the second as a replay of the first, blocking legitimate completion.

## Vulnerability Detail

### Root Cause

`checksum24` is defined as the first 24 bytes (192 bits) of keccak256:

```solidity
// @audit 32-byte keccak256 is truncated to 24 bytes — 8 bytes discarded
function calculateChecksum(bytes32 invoiceId, uint256 amount, uint64 timestamp, uint256 nonce)
    internal pure returns (bytes24 checksum24)
{
    bytes32 fullHash = keccak256(abi.encodePacked(invoiceId, amount, timestamp, nonce));
    return bytes24(fullHash); // top 24 bytes, bottom 8 discarded
}
```

Then `invoiceHash` discards another level — it zero-extends the 24-byte value back into a 32-byte slot:

```solidity
// @audit invoiceHash is bytes32(uint256(uint192(checksum24)))
// @audit uint192 masks to 192 bits; bytes32 zero-pads. Net key = 192 bits.
bytes32 invoiceHash = bytes32(uint256(uint192(data.checksum24)));
```

So `invoiceHash` is a bytes32 where the top 8 bytes are always zero. Two distinct invoices whose keccak256 preimages yield the same lower 192 bits will have the same `invoiceHash`.

The `invoices` mapping on the source chain uses the same key:

```solidity
// @audit source chain: stores invoice under 192-bit key
invoiceHash = bytes32(uint256(uint192(checksum24)));
if (invoices[invoiceHash].invoiceId != bytes32(0)) revert InvoiceAlreadyExists();
```

And the destination uses it for replay:

```solidity
// @audit destination: rejects as replay if same 192-bit key
if (completedInvoices[invoiceHash]) revert InvoiceAlreadyExists();
```

### Collision Space

The security margin for the replay guard is 192 bits, not 256. While a birthday attack on 192 bits requires ~2^96 operations (currently infeasible), there are two practical concerns:

1. **Griefing via collision**: An attacker who can precompute a second invoice whose lower 192 bits of keccak256 match a legitimate pending invoice can cause the destination escrow to reject the legitimate completion as a "replay". This requires ~2^96 operations but creates a structural fragility.

2. **Source-chain storage collision**: If two different invoices have the same 192-bit `invoiceHash`, the second `depositAndBridge` call reverts with `InvoiceAlreadyExists` at line 622, even though the two invoices are genuinely distinct bridge operations. This is a DoS against the source chain.

3. **The `checksum24` field in the payload is only 24 bytes (192 bits)**. An attacker who can observe the checksum in the payload and find a second preimage for those 192 bits can submit a crafted payload that: (a) passes the checksum validation (`data.checksum24 == expectedChecksum`), and (b) is not yet in `completedInvoices`. If the crafted payload has a different `amount`, `account`, or `destinationChainId`, the escrow would still process it as a valid release.

### Code Location

- File: `src/bridge/InvoiceDataLib.sol`
- Function: `calculateChecksum()`
- Lines: 112–122

```solidity
// @audit 8 bytes (64 bits) of entropy discarded from keccak256
bytes32 fullHash = keccak256(abi.encodePacked(invoiceId, amount, timestamp, nonce));
return bytes24(fullHash); // top 24 bytes only
```

- File: `src/bridge/BridgeEscrow.sol`
- Function: `releaseByInvoiceId()`
- Line: 218

```solidity
// @audit second truncation: uint192 masks to 192 bits, further discarding no new bits
// @audit but the effective key width is bytes24 (192 bits) stored in bytes32 with top 8 zero
bytes32 invoiceHash = bytes32(uint256(uint192(data.checksum24)));
```

- File: `src/bridge/BridgeEscrow.sol`
- Function: `_createAndStoreInvoice()`
- Line: 619

```solidity
// @audit same 192-bit key used for source-chain invoice storage
invoiceHash = bytes32(uint256(uint192(checksum24)));
```

## Impact

- **Likelihood**: Low (requires birthday-attack-level computation at 192 bits) for collision attacks, but the structural weakness means the replay key is not full 256-bit keccak256.
- **Impact**: Medium — a hash collision on the replay guard allows:
  - A second distinct invoice being blocked as a replay (DoS on legitimate completion)
  - If a preimage with a different account/amount but same 192-bit checksum is found, unauthorized release
- **Severity**: HIGH (due to unauthorized release potential)

## Attack Scenario

### Preconditions

- The system has processed many invoices over time.
- An attacker with substantial compute resources (nation-state level) wants to cause unauthorized release.

### Attack Steps

1. Attacker observes a pending legitimate invoice with `invoiceId = X`, `amount = 100_000 USDC`, `timestamp = T`, `nonce = N`. The checksum24 is `keccak256(X, 100_000, T, N)[0:24]`.
2. Attacker searches for values `(X', amount', T', N')` such that the lower 24 bytes of `keccak256(X', amount', T', N')` equal those of the legitimate invoice's checksum24, but `amount' = 0` (or a different amount) and `account' = attacker_controlled_authorized_account`.
3. This requires finding a 192-bit preimage collision: approximately 2^96 operations.
4. If found, attacker submits a release with the crafted payload. Checksum validation passes (same lower 192 bits). `completedInvoices[invoiceHash]` is false (fresh). Destination chain releases `amount'` to `account'`.
5. Simultaneously, the legitimate invoice's `invoiceHash` collides with the crafted one, so the legitimate completion is now rejected as a replay.

### Expected Impact

- Unauthorized release to attacker's controlled account.
- Legitimate invoice completion permanently blocked (collision in `completedInvoices`).

## Recommended Mitigation

Use the full 256-bit keccak256 hash as the replay guard key. The `invoiceHash` should be:

```solidity
// Use full 32-byte hash, not a 192-bit truncation
bytes32 invoiceHash = keccak256(abi.encodePacked(invoiceId, amount, timestamp, nonce));
```

Store `checksum24` only for the wire-format payload (cross-chain message size), but use the full hash internally for storage keys. Alternatively, store both `invoiceId` and the full `keccak256` hash in the `completedInvoices` mapping value so collisions can be detected.
