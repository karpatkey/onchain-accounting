# M-07: `UUPSProxy._unsafeAllowUninitialized()` Returns True — Uninitialized Proxy Window Exposes ERC-1967 Storage Slot

## Summary

`UUPSProxy` overrides `_unsafeAllowUninitialized()` to return `true`, allowing the proxy to be deployed with a placeholder implementation and no initialization data. Between proxy deployment (script 02) and initialization (same or subsequent script), the proxy is in an uninitialized state where the ERC-1967 implementation slot points to the placeholder implementation. If an attacker observes the proxy deployment and calls `initialize()` on the placeholder before the deployer does, and the placeholder has an `initialize()` function that does not check `DEFAULT_ADMIN_ROLE` (or has none), the attacker could front-run the initialization.

## Vulnerability Detail

### Root Cause

```solidity
// src/proxy/UUPSProxy.sol:21-23
// @audit Returns true — proxy deployed without checking that implementation is initialized
function _unsafeAllowUninitialized() internal pure override returns (bool) {
    return true;
}
```

The OpenZeppelin UUPS pattern typically requires the implementation to call `_disableInitializers()` in its constructor to prevent direct calls on the implementation. `NAVCalculator` does this correctly:

```solidity
// src/nav/NAVCalculator.sol:53-55
constructor() {
    _disableInitializers(); // @audit correct — prevents implementation calls
}
```

However, the *proxy* is deployed in an uninitialized state with a placeholder implementation. The proxy's `initialize()` is callable by anyone until it is called by the legitimate deployer.

### Attack Window

The deploy flow comment states: "initialization is performed by Safe via 02b_InitializeProxies." This means the proxy is deployed (script 02a) and initialization happens in a *separate* script run (02b) or transaction, creating a window — potentially across multiple blocks — where the proxy is deployed but uninitialized.

### Comparison to BridgeEscrow

`BridgeEscrow.initialize` also uses `initializer` modifier:
```solidity
// src/bridge/BridgeEscrow.sol:113-118
function initialize(...) external initializer {
    if (admin_ == address(0)) revert InvalidArguments();
    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    ...
}
```

If an attacker calls `BridgeEscrow.initialize(attackerAddress, chainId, [], [])` before the deployer, the attacker sets themselves as `DEFAULT_ADMIN_ROLE` holder, can authorize their own adapter, and gain full control of the bridge escrow.

## Impact

- **Likelihood**: Medium — requires front-running between script 02a (deploy) and 02b (initialize); on L1 this window could span blocks; on L2s with permissioned sequencers it is harder but not impossible.
- **Impact**: Critical if exploited for NAVCalculator or BridgeEscrow — attacker gains `DEFAULT_ADMIN_ROLE` on the core contracts:
  - On `NAVCalculator`: Can upgrade to a malicious implementation (UUPS `_authorizeUpgrade` is `DEFAULT_ADMIN_ROLE`-gated).
  - On `BridgeEscrow`: Can authorize malicious adapters and authorized accounts; call `emergencyWithdraw` to drain any deposited funds.

## Attack Scenario

### Preconditions
- Deploy script 02a deploys the `BridgeEscrowProxy` in a mempool-visible transaction.
- Script 02b (initialize) is a separate transaction in a subsequent block.

### Steps
1. Attacker monitors the mempool for `UUPSProxy` deployments.
2. Observes deployment of `BridgeEscrowProxy` pointing to `BridgeEscrow` implementation.
3. Calls `BridgeEscrowProxy.initialize(attackerAddr, chainId, [], [])` with higher gas before the deployer's initialization transaction confirms.
4. `BridgeEscrow.initialize` executes: `DEFAULT_ADMIN_ROLE` is granted to `attackerAddr`.
5. Deployer's `initialize` call reverts with `InvalidInitialization` (already initialized).
6. Attacker now has `DEFAULT_ADMIN_ROLE` on `BridgeEscrowProxy`.
7. Attacker calls `authorizeAccount(attackerAddr)`, `authorizeAdapter(maliciousAdapter)`.
8. Attacker's malicious adapter can call `releaseByInvoiceId` to drain future deposits.

## Recommended Mitigation

Initialize the proxy atomically in the constructor using a `data` argument rather than a separate transaction:

```solidity
// Deploy and initialize in one transaction:
new UUPSProxy(implementation, abi.encodeCall(NAVCalculator.initialize, (admin, sequencerFeed, nativeSymbol)));
```

If the two-step deploy is required (e.g., for cross-chain address prediction), use a deployer contract that atomically deploys and initializes in a single transaction, eliminating the window.

Additionally, the placeholder implementation should also call `_disableInitializers()` in its constructor so it cannot be directly initialized.
