# H-02: SuperchainBridgeAdapter Single CREATE2 Address Cannot Correctly Authenticate Both Optimism and Base

## Summary

`SuperchainBridgeAdapter` is deployed at the same address on all chains via CREATE2. On L1 (Ethereum), this single adapter must serve as the trusted remote for both Optimism (chain ID 10) and Base (chain ID 8453). However, `trustedRemoteAdapter[chainId]` maps one chain ID to one remote adapter address. Since both OP and Base siblings have the same address (CREATE2 same-address guarantee), any message claiming to originate from chain 10 or chain 8453 that carries the sibling adapter's address will pass the `trustedRemoteAdapter` check. This means a message forged on Base claiming source chain = Optimism will pass authentication on L1, or vice versa, creating a cross-L2 impersonation vector.

## Vulnerability Detail

### Root Cause

The Superchain adapter's L1 instance uses `trustedRemoteAdapter[srcChainId]` to authenticate the source sender. For the L1→L2 path, `completeDeposit` calls `_authenticateMessengerSource`:

```solidity
// @audit trustedRemoteAdapter maps chain ID to a bytes32 address
// @audit for OP (chainId=10) and Base (chainId=8453), the sibling is address(this) on both
function _authenticateMessengerSource(uint64 srcChainId) internal view {
    if (msg.sender != l2Messenger) revert NotAuthorized();
    bytes32 expected = trustedRemoteAdapter[srcChainId];
    if (expected == bytes32(0)) revert NotAuthorized();
    address xSender = ICrossDomainMessenger(l2Messenger).xDomainMessageSender();
    // @audit if OP and Base adapters have the same address, this check cannot distinguish between them
    if (_toBytes32(xSender) != expected) revert NotAuthorized();
}
```

For L2→L1 (withdrawal path via `_finalizeWithdrawal`), the binding is:

```solidity
// @audit ETH: withdrawalTx.target == address(this) — true for any L2's sibling
// @audit ERC20: no target/sender binding at all — relies entirely on portal proof
if (withdrawalTx.target != address(this)) revert InvalidWithdrawalFinalization();
```

The `withdrawalTx.target` is just `address(this)` — same on every chain. The portal Merkle proof verifies the withdrawal is included in a specific L2 output root, but the **L1 adapter does not verify which L2's output root the proof applies to**. The `optimismPortal` state variable is a single portal address. If the same portal (or a misconfigured portal) accepts output roots from either OP or Base, a withdrawal proven against Base's state could finalize via `proveWithdrawal` / `_finalizeWithdrawal` while claiming to settle an OP invoice.

### The Specific Superchain L1-Hub Problem

Per the project memory (MEMORY.md): "Superchain L1-hub design (one CREATE2 addr can't serve OP+Base on Ethereum)". This is precisely this issue. The L1 adapter is initialized with a **single** `l1Messenger`, `l1Bridge`, and `optimismPortal`. These point to one L2 (either OP or Base). The adapter cannot simultaneously authenticate inbound messages from both OP and Base, because:

- `l2Messenger` is a single address — L2→L1 deposits from the other L2 won't route through it
- `optimismPortal` is a single portal — withdrawals from the other L2 cannot be finalized through it

However, the `trustedRemoteAdapter` mapping accepts both chain IDs, and since both sibling adapters have the same address:

```
trustedRemoteAdapter[10]  = bytes32(uint256(uint160(address(this))))  // OP sibling
trustedRemoteAdapter[8453] = bytes32(uint256(uint160(address(this)))) // Base sibling
// Both are identical values
```

Any message from **either** OP or Base that arrives via the configured `l2Messenger` will authenticate as coming from a trusted source, regardless of whether the deposit actually came from chain 10 or chain 8453. The source chain ID in the invoice payload is attacker-controlled (part of the message), so an attacker on Base can craft a message claiming `sourceChainId = 10` (Optimism) and the adapter cannot distinguish it from a real Optimism deposit.

### Code Location

- File: `src/bridge/adapters/SuperchainBridgeAdapter.sol`
- Function: `_authenticateMessengerSource()`
- Lines: 287–293

```solidity
// @audit l2Messenger is a single address — cannot distinguish OP from Base messages
function _authenticateMessengerSource(uint64 srcChainId) internal view {
    if (msg.sender != l2Messenger) revert NotAuthorized();
    bytes32 expected = trustedRemoteAdapter[srcChainId];
    if (expected == bytes32(0)) revert NotAuthorized();
    address xSender = ICrossDomainMessenger(l2Messenger).xDomainMessageSender();
    // @audit xSender == address(this) for ANY configured L2 sibling
    if (_toBytes32(xSender) != expected) revert NotAuthorized();
}
```

- File: `src/bridge/adapters/SuperchainBridgeAdapter.sol`
- Function: `initialize()`
- Lines: 99–116

```solidity
// @audit on L1, only ONE l1Bridge, ONE l1Messenger, ONE optimismPortal is stored
// @audit but trustedRemoteAdapter can hold entries for both chain 10 and chain 8453
if (chainId == 1) {
    l1Bridge = IL1StandardBridge(l1Bridge_);
    l1Messenger = l1Messenger_;
    optimismPortal = IOptimismPortal(optimismPortal_);
}
```

## Impact

- **Likelihood**: Medium — requires a compromised or malicious L2 (or a misconfiguration where the OP portal is pointed to a portal that accepts Base output roots).
- **Impact**: High — cross-L2 impersonation: a Base-chain-sourced message can satisfy L1 authentication as an Optimism invoice, allowing unauthorized release on L1 for a Base operation that didn't happen, or settlement of an Optimism invoice from a Base chain delivery.
- **Severity**: HIGH

## Attack Scenario

### Preconditions

- SuperchainBridgeAdapter is deployed on L1 (Ethereum) at the same CREATE2 address as on OP and Base.
- Admin has called `setTrustedRemoteAdapter(10, adapter_address)` and `setTrustedRemoteAdapter(8453, adapter_address)`.
- An authorized account has a legitimate BRIDGING invoice on L1 for an Optimism withdrawal (large amount).
- Attacker controls an address on Base.

### Attack Steps

1. Attacker on Base initiates a legitimate Base→L1 withdrawal of a small amount, specifying the L1 SuperchainBridgeAdapter as the target/receiver, and crafting the withdrawal `data` as a `completeDeposit(messagePayload)` call where `messagePayload` encodes an InvoiceData with `sourceChainId = 10` (Optimism), `account = victim_account`, `amount = large_amount`.
2. After the 7-day challenge period, attacker calls `proveWithdrawal` on L1 with the real Base withdrawal transaction (which has a valid portal proof against Base's output root).
3. L1 manager (or attacker with `MANAGER_ROLE`) calls `completeBridge(messagePayload, protocolData)` where `protocolData` is the finalized withdrawal transaction.
4. Inside `_completeBridge` → `_finalizeWithdrawal`: `withdrawalTx.target == address(this)` passes (Base sibling == L1 adapter == same CREATE2 address). The portal proof for the Base withdrawal is valid. Portal delivers the small amount to the L1 adapter.
5. The base `completeBridge` calls `_fundAndRelease` with `data.amount = large_amount`, but `_fundAndRelease` checks `address(this).balance >= large_amount` — this fails unless the adapter has accumulated balance from previous operations.

Variation for the `completeDeposit` (L1→L2) path: attacker sends a message from Base claiming source = OP. The `l2Messenger` on Base and OP may differ, but if the same L1 adapter serves both, the `msg.sender != l2Messenger` check will only match one of them, not both — this is the config inconsistency that the project memory identified.

### Expected Impact

- A single L1 SuperchainBridgeAdapter cannot correctly authenticate inbound messages from two different L2s simultaneously. Depending on which L2 the `optimismPortal` / `l2Messenger` points to, the other L2's messages are either all accepted without correct source validation, or all rejected — leaving one L2 corridor entirely unsupported or insecure.

## Recommended Mitigation

Deploy **separate** `SuperchainBridgeAdapter` instances for Optimism and Base on L1 (using different CREATE2 salts). Each L1 adapter is configured with the portal and messenger for exactly one L2:

- `SuperchainBridgeAdapter_OP` (L1): `optimismPortal = OP_portal`, `l1Messenger = OP_l1Messenger`, `trustedRemoteAdapter[10] = adapter_address_on_OP`
- `SuperchainBridgeAdapter_Base` (L1): `optimismPortal = Base_portal`, `l1Messenger = Base_l1Messenger`, `trustedRemoteAdapter[8453] = adapter_address_on_Base`

Authorize both on the L1 `BridgeEscrow`. This requires abandoning the strict same-CREATE2-address model for L1↔multi-L2 Superchain paths, or using a dispatcher pattern on L1 that routes by source chain before forwarding to the chain-specific adapter.
