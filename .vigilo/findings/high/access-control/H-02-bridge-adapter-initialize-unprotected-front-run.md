# H-02: Bridge Adapter `initialize()` Is Unprotected — Front-Running Enables Full Adapter Takeover

## Summary

Every `BridgeAdapter` concrete contract exposes an `external initialize()` function with no access-control modifier or deployer-only gate. The only protection is a boolean `_initialized` flag. Between the CREATE2 deploy transaction and the `initialize()` call, a front-runner can call `initialize()` first with a malicious `admin_`, `bridgeEscrow_`, and protocol addresses — taking ownership of the adapter before the legitimate deployer can.

## Vulnerability Detail

### Root Cause

`BridgeAdapter._initializeBridgeAdapter` uses a custom `_initialized` boolean flag rather than OpenZeppelin's `Initializable` (with `initializer` modifier). The concrete `initialize()` functions exposed by all six adapters carry no access restriction on who may call them:

- File: `src/bridge/BridgeAdapter.sol`
- Function: `_initializeBridgeAdapter()`
- Lines: 63-77

```solidity
// @audit No access modifier — any caller can initialize before the deployer does
function _initializeBridgeAdapter(
    address admin_,
    address bridgeEscrow_,
    string memory providerName_,
    string memory version_
) internal {
    require(!_initialized, "BridgeAdapter: already initialized");
    // ...
    _initialized = true;
    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    bridgeEscrow = bridgeEscrow_;
    // ...
}
```

Concrete adapters expose:
```solidity
// src/bridge/adapters/CcipBridgeAdapter.sol:67
// @audit external, no onlyRole, no modifier
function initialize(address admin_, address bridgeEscrow_, address router_, address feeToken_, string memory version_) external {
    super._initializeBridgeAdapter(admin_, bridgeEscrow_, "CCIP", version_);
    ...
}
```

Identical pattern at `AcrossBridgeAdapter:53`, `StargateBridgeAdapter:73`, `GnosisBridgeAdapter:53`, `CctpBridgeAdapter:75`, `SuperchainBridgeAdapter:85`.

### Deploy Flow Gap

The deploy script (`script/deploy/05_DeployBridgeAdapters.s.sol`) performs CREATE2 deploy and `initialize()` in the same `vm.startBroadcast()` session, but these are two separate on-chain transactions. On any EVM chain with a public mempool (all 7 target chains for these adapters), any observer can see the CREATE2 deploy in the mempool, predict the deterministic address, and submit an `initialize()` front-run transaction with higher gas before the legitimate `initialize()` lands.

## Impact

- **Likelihood**: Medium — requires active front-running at deploy time; on L2s with sequencer mempool protection this window is narrower but not zero.
- **Impact**: High — attacker gains `DEFAULT_ADMIN_ROLE` on the adapter, sets a malicious `bridgeEscrow` address, and controls all adapter functions including `completeBridge`, `recoverStuckAssets`, `setTrustedRemoteAdapter`, `setSpokePool`/`setRouter`/etc.

**Consequences of a compromised adapter after takeover:**
1. Attacker holds `DEFAULT_ADMIN_ROLE` and `MANAGER_ROLE` on the adapter.
2. Attacker can call `recoverStuckAssets` to drain any tokens the adapter holds.
3. Attacker can set `bridgeEscrow` to a malicious contract; when the genuine `BridgeEscrow` calls `adapter.bridge(messagePayload)`, the adapter's `_bridge` pulls tokens from the genuine escrow's approval via `safeTransferFrom(bridgeEscrow, ...)` — but the malicious `bridgeEscrow` address skips the legitimate escrow entirely.
4. Attacker can set `trustedRemoteAdapter` entries to attacker-controlled addresses, enabling forged inbound completions.

**Note:** Because the adapter's address is the same across all 7 chains (CREATE2 same-address guarantee), a successful takeover on one chain may be replicated on all other chains if the salt/bytecode is identical and front-running succeeds there too.

## Attack Scenario

### Preconditions
- Deploy script `05_DeployBridgeAdapters.s.sol` is run on mainnet or any supported L2.
- Attacker monitors the mempool.

### Attack Steps
1. Attacker observes the CREATE2 deploy transaction for `CcipBridgeAdapter` in the mempool.
2. Attacker computes the deterministic address using the known salt and creation code.
3. Before the deployer's `initialize()` call confirms, attacker submits `CcipBridgeAdapter(predictedAddr).initialize(attackerAddr, maliciousBridgeEscrow, legitimateRouter, address(0), "1.0.0")` with higher gas.
4. Attacker's `initialize()` confirms first, setting `DEFAULT_ADMIN_ROLE` to `attackerAddr` and `bridgeEscrow` to `maliciousBridgeEscrow`.
5. Deployer's subsequent `initialize()` reverts because `_initialized == true`.
6. Deployer's script may skip the adapter (idempotent `if (fresh)` block no longer triggered), leaving the attacker-initialized adapter at the predicted address.
7. If the deployer then calls `06_Configure.s.sol`, the attacker-controlled adapter gets authorized on `BridgeEscrow`.
8. Attacker now has `MANAGER_ROLE` on a `BridgeEscrow`-authorized adapter and can call `completeBridge` with forged payloads.

## Recommended Mitigation

Use the same CREATE2-aware constructor pattern as `NAVCalculator` and `BridgeEscrow`: call `_disableInitializers()` in the constructor and use OpenZeppelin `Initializable` with the `initializer` modifier on `initialize()`. This prevents any call to `initialize()` before the deployer does, because `_disableInitializers()` in the constructor would immediately lock the initializer if called before `initialize()`.

Alternatively, enforce that `initialize()` can only be called by the contract's CREATE2 deployer address (predictable from the salt) or incorporate the admin address into the constructor parameters (breaking the no-constructor-args CREATE2 same-address requirement, so the Initializable route is preferred).
