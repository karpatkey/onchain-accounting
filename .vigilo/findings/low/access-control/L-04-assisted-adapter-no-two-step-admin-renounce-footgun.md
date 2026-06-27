# L-04: `AssistedBalanceAdapter` Has No Two-Step Admin Transfer — Admin Can Renounce Without Replacement

## Summary

`AssistedBalanceAdapter` uses OpenZeppelin `AccessControl` without the `AccessControlDefaultAdminRules` extension. The `DEFAULT_ADMIN_ROLE` holder can call `renounceRole(DEFAULT_ADMIN_ROLE, self)` directly, permanently removing admin from the adapter. Since the adapter is not upgradeable (unlike `NAVCalculator`/`BridgeEscrow`), there is no recovery path if `DEFAULT_ADMIN_ROLE` is renounced or granted to an unusable address.

## Vulnerability Detail

### Root Cause

OpenZeppelin `AccessControl.renounceRole` allows any holder to renounce their own role:

```solidity
// OZ AccessControl.sol
function renounceRole(bytes32 role, address callerConfirmation) public virtual {
    if (callerConfirmation != _msgSender()) revert AccessControlBadConfirmation();
    _revokeRole(role, callerConfirmation);
}
```

There is no check that `DEFAULT_ADMIN_ROLE` still has at least one holder after renounce. If the security council Safe EOA key is compromised and renounces:

```solidity
// No guard against last-admin renounce in AssistedBalanceAdapter
_grantRole(DEFAULT_ADMIN_ROLE, admin); // src/balances/AssistedBalanceAdapter.sol:31
```

Consequences of admin loss on an assisted adapter:
1. `ASSISTANT_ROLE` cannot be rotated (key rotation requires `DEFAULT_ADMIN_ROLE` to grant the new assistant).
2. If the assistant key is compromised, there is no way to revoke it.
3. The adapter continues to function for reads (NAV still works) and for the existing assistant (existing `ASSISTANT_ROLE` grants persist), but any administrative change is impossible.

## Impact

- **Likelihood**: Low — requires inadvertent or malicious admin renounce; governance multi-sig (Safe) makes this unlikely in normal operation.
- **Impact**: Medium — loss of `DEFAULT_ADMIN_ROLE` means the `ASSISTANT_ROLE` cannot be rotated. If the assistant's private key is then compromised, there is no recovery: the compromised assistant can flood the cache with garbage entries, clear allocations, or submit stale proofs (always bounded to under-report, never over-report, per the adapter's security model).

## Recommended Mitigation

Use `AccessControlDefaultAdminRules` from OpenZeppelin, which:
1. Enforces a two-step `beginDefaultAdminTransfer / acceptDefaultAdminTransfer` pattern.
2. Prevents the last admin from renouncing without a pending transfer.
3. Adds a time-lock on admin transfers.

Alternatively, document the risk explicitly and ensure the security council Safe has a minimum quorum that prevents a single signer from renouncing on behalf of the Safe.
