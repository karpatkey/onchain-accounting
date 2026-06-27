# M-06: `AcrossBridgeAdapter` Source Authentication Binds Only Source Chain ID, Not a Sender — Weaker Provenance Than Other Adapters

## Summary

`AcrossBridgeAdapter._authenticateSource` verifies that the source chain id maps to a configured `trustedRemoteAdapter` entry that equals `address(this)` (the CREATE2 same-address sibling). However, because Across V3 does not surface the original depositor/sender on the fill callback (`handleV3AcrossMessage`), the adapter cannot verify that the message was sent by the correct source-chain sibling adapter — it only verifies that *some* SpokePool fill arrived from a known source chain. An attacker on the source chain who can craft a valid Across V3 deposit with an arbitrary `message` payload (containing a crafted invoice) can trigger a legitimate release on the destination for an invoice they never deposited into the BridgeEscrow.

## Vulnerability Detail

### Root Cause

The `_authenticateSource` function in `AcrossBridgeAdapter`:

```solidity
// src/bridge/adapters/AcrossBridgeAdapter.sol:254-258
// @audit Only verifies source chain has a trusted entry == address(this). No sender verification.
function _authenticateSource(uint64 sourceKey, uint24 claimedSourceChainId) internal view {
    if (sourceKey == 0 || uint256(sourceKey) != uint256(claimedSourceChainId)) revert InvalidBridgeData();
    bytes32 trusted = trustedRemoteAdapter[sourceKey];
    if (trusted == bytes32(0) || trusted != _toBytes32(address(this))) revert InvalidBridgeData();
}
```

The trusted remote check requires `trusted == _toBytes32(address(this))` — meaning the `trustedRemoteAdapter` for the source chain must be the adapter's own address. This is the CREATE2 same-address model. But critically, there is no check that the Across fill was *submitted by* the source-chain adapter. The invoice `message` payload in the Across fill is caller-controlled (any Across depositor can set an arbitrary `message` field).

Compare to `CcipBridgeAdapter._authenticateSource`:

```solidity
// src/bridge/adapters/CcipBridgeAdapter.sol:259-263
function _authenticateSource(uint64 sourceChainSelector, bytes memory sender) internal view {
    uint64 srcChainId = selectorToChainId[sourceChainSelector];
    if (srcChainId == 0) revert UnsupportedChain(sourceChainSelector);
    address remote = abi.decode(sender, (address));
    // @audit CCIP authenticates the actual sender address against trustedRemoteAdapter
    if (_toBytes32(remote) != trustedRemoteAdapter[srcChainId]) revert InvalidBridgeData();
}
```

CCIP can verify the actual `message.sender` because CCIP carries source sender provenance. Across V3 does not provide a source depositor address in the fill callback, so the adapter resorts to the chain-level check only.

### Attack Path

The `handleV3AcrossMessage` callback:

```solidity
// src/bridge/adapters/AcrossBridgeAdapter.sol:187-224
function handleV3AcrossMessage(address tokenSent, uint256 amount, address, bytes memory message) external override nonReentrant {
    if (msg.sender != address(spokePool)) revert MessageReceiveFailed(); // spokePool check: correct
    // ...
    _authenticateSource(uint64(data.sourceChainId), data.sourceChainId); // chain-only check
    // ...
    _fundAndRelease(message, asset, data.amount);
}
```

An attacker on the source chain who:
1. Has access to a valid invoice payload (the invoice `message` payload is emitted on-chain in `depositAndBridge` events)
2. Can deposit the same asset into the Across SpokePool with the replayed invoice payload as the `message` field

...would cause the destination adapter to release funds for an invoice it already processed, OR fabricate an invoice for a transfer they initiated outside BridgeEscrow.

However: the `completedInvoices[invoiceHash]` replay guard in `BridgeEscrow.releaseByInvoiceId` prevents re-release of the *same* invoice hash. The `invoiceHash` is derived from `calculateChecksum(invoiceId, amount, timestamp, nonce)`, and the per-account nonce makes each legitimate invoice unique. An attacker cannot replay an existing invoice hash.

The remaining concern is fabricated invoices: an attacker deposits into Across with a crafted `message` payload carrying a fresh `invoiceId`/`nonce`/`checksum` — the BridgeEscrow's checksum validation in `releaseByInvoiceId` will verify that `calculateChecksum(invoiceId, amount, timestamp, nonce) == checksum24`. A fabricated checksum would fail unless the attacker can produce a valid one.

**The checksum is 24 bytes of keccak256** — not forgeable without the preimage. And the BridgeEscrow also checks `_authorizedAccounts.contains(data.account)` — the target account must be an authorized Safe.

**Net assessment:** The Across source authentication is weaker than CCIP/Stargate/Gnosis in that it cannot bind the fill to a specific source sender, but the BridgeEscrow's own checksum + account authorization defenses mean a pure forgery is not achievable without cracking keccak256. The real risk is a compromised or malicious *relayer* on Across who can observe legitimate payloads and replay them in a different order, or who can construct fills for legitimate invoices that have already been processed via another path (but the replay guard handles this).

## Impact

- **Likelihood**: Low — requires keccak256-preimage forgery for a new invoice, or relies on a compromised Across relayer to replay.
- **Impact**: Medium — the weaker provenance means the funded pass-through model relies more heavily on the BridgeEscrow's own defenses than on adapter-level source binding. A relayer that can deliver to the destination adapter with an arbitrary `message` payload relies entirely on BridgeEscrow guards.

## Attack Scenario

### Preconditions
- A legitimate BridgeEscrow-authorized account deposits funds via `AcrossBridgeAdapter`.
- The `messagePayload` is public in the `BridgeInitiated` event.
- A malicious Across relayer intercepts the V3 deposit.

### Steps
1. User calls `BridgeEscrow.depositAndBridge(destChain, "USDC", 1000e6, acrossAdapterAddress)`.
2. Event `BridgeInitiated(invoiceId, amount)` is emitted on source chain; messagePayload is public.
3. Malicious relayer attempts to call `handleV3AcrossMessage` on destination with the same `message` payload, different `amount`.
4. BridgeEscrow checks `completedInvoices[invoiceHash]` → hash depends on `amount` → if `amount` differs, hash differs, check passes.
5. BridgeEscrow checks `checksum24 == calculateChecksum(invoiceId, amount, timestamp, nonce)` → checksum was computed for original amount → mismatch → revert.
6. Attack fails at step 5 due to checksum mismatch.

**Key insight:** The BridgeEscrow's checksum makes forgery infeasible. The finding is a defense-in-depth gap (missing sender binding), not an exploitable vulnerability with the current checksum scheme.

## Recommended Mitigation

Document the weaker source authentication in the `AcrossBridgeAdapter` contract comments. If Across V3 adds source depositor information in future versions (or via the `exclusiveRelayer` mechanism), bind it to `trustedRemoteAdapter`. Consider requiring `exclusiveRelayer == trustedRemoteAdapter[sourceChainId]` in the `SpokePool.depositV3` call to ensure only the source-chain sibling adapter can fill the order, providing sender-level binding analogous to CCIP.
