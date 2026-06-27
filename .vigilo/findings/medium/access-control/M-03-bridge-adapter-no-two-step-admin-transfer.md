# M-03: Bridge Adapters Lack Two-Step Admin Transfer — Single-Transaction Handoff Can Strand Admin

## Summary

`BridgeAdapter` uses OpenZeppelin `AccessControl` for role management. The `DEFAULT_ADMIN_ROLE` is granted in `_initializeBridgeAdapter` and transferred to the security council in deploy script `07_TransferAdminToSecurityCouncil.s.sol` via a single `grantRole` + `renounceRole` sequence. There is no two-step accept mechanism. If the security council Safe address is misconfigured in `chainConfig.securityCouncil`, or the Safe itself is not deployed yet on that chain, the `DEFAULT_ADMIN_ROLE` is irrevocably handed to an address that cannot accept it, leaving the adapter permanently without a functional admin.

## Vulnerability Detail

### Root Cause

The handoff is a single atomic sequence: grant → revoke/renounce.

- File: `script/deploy/07_TransferAdminToSecurityCouncil.s.sol`
- Function: `_handoff()`
- Lines: 70-111

```solidity
// @audit Single-step: if council is wrong address, admin is permanently transferred to wrong account
IAccessControl(target).grantRole(DEFAULT_ADMIN_ROLE, council);
// ...
IAccessControl(target).revokeRole(MANAGER, deployer);
IAccessControl(target).renounceRole(DEFAULT_ADMIN_ROLE, deployer); // irreversible
```

The script validates `council != address(0)` and `council != deployer`, but does not validate that `council` is a live Safe with signers or that it has a `hasRole` acceptance mechanism.

For bridge adapters (non-upgradeable `AccessControl`, not `AccessControlUpgradeable`), once the deployer renounces `DEFAULT_ADMIN_ROLE`, there is no recovery path — the admin role holder is whoever it was last granted to, with no further recourse if that address cannot sign transactions.

### Comparison to NAVCalculator

`NAVCalculator` and `BridgeEscrow` are UUPS-upgradeable, so a misconfigured admin can theoretically be recovered by upgrading to a new implementation that adjusts roles. Bridge adapters are not upgradeable — there is no upgrade path, and a mis-handed admin is permanent.

## Impact

- **Likelihood**: Low — misconfigured Safe address is a deployment-time mistake, not an on-chain vulnerability.
- **Impact**: High — if realized, `DEFAULT_ADMIN_ROLE` on the adapter is permanently held by an unusable address:
  - `setTrustedRemoteAdapter` becomes uncallable (only `DEFAULT_ADMIN_ROLE`), so the trusted remote sibling list is frozen.
  - Protocol-config setters (`setRouter`, `setSpokePool`, `setEndpoint`, `setTokenMessenger`, `setFeeToken`, etc.) are all `onlyRole(DEFAULT_ADMIN_ROLE)` — all frozen.
  - Adapter can still process bridges (automatic paths work), but no administrative recovery or rotation is possible.

## Attack Scenario

This is a deployment failure scenario, not an active attack.

### Preconditions
- Security council Safe address in `chainConfig.securityCouncil` is misconfigured (wrong address, or the Safe has not been deployed on this chain yet).
- Deploy script 07 is run and the EOA renounces.

### Steps
1. Deployer runs `07_TransferAdminToSecurityCouncil.s.sol` with `securityCouncil = wrongAddress`.
2. `grantRole(DEFAULT_ADMIN_ROLE, wrongAddress)` succeeds.
3. `renounceRole(DEFAULT_ADMIN_ROLE, deployer)` succeeds.
4. `wrongAddress` now holds `DEFAULT_ADMIN_ROLE` on all six bridge adapters.
5. If `wrongAddress` is not a Safe with live signers (e.g., wrong chain, undeployed Safe, typo), no one can call `setTrustedRemoteAdapter` or any admin function.
6. The bridge is in production with a permanently frozen admin configuration.

## Recommended Mitigation

Use OpenZeppelin's `AccessControlDefaultAdminRules` extension, which adds a two-step `beginDefaultAdminTransfer(newAdmin)` / `acceptDefaultAdminTransfer()` pattern. The new admin must explicitly accept before the old admin's role is revoked. This prevents irrevocable mis-transfers.

If the full extension is not desired, the deploy script should at minimum verify post-handoff that `IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, council)` returns `true` and `IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, deployer)` returns `false` before proceeding to the next adapter — and should halt rather than continue if the council cannot be confirmed as holding the role.
