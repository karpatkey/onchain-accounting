# M-05: Deploy Script 07 Does Not Strip Deployer Roles From AssistedBalanceAdapters

## Summary

`07_TransferAdminToSecurityCouncil.s.sol` transfers `DEFAULT_ADMIN_ROLE` and `MANAGER` from the deployer EOA to the security council on `NAVCalculatorProxy`, `BridgeEscrowProxy`, and the six bridge adapters. It does NOT perform the same handoff for the `AssistedBalanceAdapter` family (`MerklRewardsBalanceAdapter`, `EtherFiWithdrawalQueueBalanceAdapter`, `StakeWiseV3ExitQueueBalanceAdapter`). If the deployer EOA was passed as `admin_` during adapter construction (the `AssistedBalanceAdapter(admin_, assistant_)` constructor parameter), the deployer retains `DEFAULT_ADMIN_ROLE` on every assisted adapter after script 07 completes.

## Vulnerability Detail

### Root Cause

Script 07 explicitly processes only two proxy contracts and six bridge adapters:

```solidity
// script/deploy/07_TransferAdminToSecurityCouncil.s.sol:44-63
if (navProxy != address(0)) { _handoff(navProxy, ...); }
if (bridgeProxy != address(0)) { _handoff(bridgeProxy, ...); }
string[6] memory adapterNames = ["CCIP", "Across", "Stargate", "Gnosis", "CCTP", "Superchain"];
for (uint256 i = 0; i < adapterNames.length; i++) {
    address adapter = ConfigReader.readDeployedAdapterAddress(..., adapterNames[i]);
    // @audit Assisted balance adapters (Merkl, EtherFi, StakeWise) never processed here
    if (adapter == address(0) || adapter.code.length == 0) continue;
    _handoff(adapter, ...);
}
```

The assisted adapters are deployed by script `04_DeployBalanceAdapters.s.sol` with `admin_ = chainConfig.admin` (typically the deployer EOA during the deploy phase). After script 07, the deployer retains `DEFAULT_ADMIN_ROLE` on:

- `src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol`
- `src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueBalanceAdapter.sol`
- `src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBalanceAdapter.sol`

`DEFAULT_ADMIN_ROLE` on these adapters allows:
1. Granting `ASSISTANT_ROLE` to any address → submitting proofs / ids / coordinates
2. Revoking `ASSISTANT_ROLE` from the legitimate assistant → silencing NAV updates (griefing)

### AssistedBalanceAdapter Role Powers

```solidity
// src/balances/AssistedBalanceAdapter.sol:29-33
constructor(address admin, address assistant) {
    // @audit admin receives DEFAULT_ADMIN_ROLE — not stripped by script 07
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    if (assistant != address(0)) _grantRole(ASSISTANT_ROLE, assistant);
}
```

`DEFAULT_ADMIN_ROLE` is the admin of `ASSISTANT_ROLE` (OZ default), so the holder can:
- `grantRole(ASSISTANT_ROLE, anyAddress)` — add malicious assistants
- `revokeRole(ASSISTANT_ROLE, legitimateAssistant)` — disable legitimate assistant

## Impact

- **Likelihood**: Medium — the deployer EOA retaining admin on assisted adapters is a guaranteed post-deploy state if script 07 is not manually extended; confirmed by reading the script.
- **Impact**: Medium — a compromised deployer EOA (or malicious deployer) retains the ability to:
  - Grant `ASSISTANT_ROLE` to a malicious account, allowing submission of false Merkl allocations (limited by on-chain proof verification to under-reporting only, but can flood the cache with garbage entries)
  - Revoke the legitimate assistant's role, causing NAV to undercount rewards and withdrawal queue positions (NAV drift — no fund loss directly, but could trigger downstream management actions based on incorrect NAV)
  - Add themselves as `ASSISTANT_ROLE` holder and garbage-collect all user caches (cause zero-NAV for reward / withdrawal positions)

The "cannot over-report" invariant is preserved for Merkl (proof-verified), but cache manipulation and role revocation can cause operational NAV disruption.

## Attack Scenario

### Preconditions
- Deploy scripts 01–07 run with the deployer EOA.
- Script 07 completes successfully; council holds admin on NAVCalculator and BridgeEscrow.
- Deployer EOA still holds `DEFAULT_ADMIN_ROLE` on the three assisted adapters (not stripped by script 07).

### Steps
1. Deployer EOA key is compromised (e.g., via leaked private key or phishing).
2. Attacker calls `MerklRewardsBalanceAdapter.grantRole(ASSISTANT_ROLE, attackerAddr)`.
3. Attacker calls `MerklRewardsBalanceAdapter.clearAllocation(user, token)` for all users — wiping all cached Merkl reward allocations.
4. NAV reads for all users now return 0 for Merkl reward positions.
5. Portfolio management systems reading NAV see incorrect (understated) NAV values.
6. Alternatively, attacker calls `revokeRole(ASSISTANT_ROLE, legitimateAssistant)` — future legitimate proof submissions fail, leaving cache stale.

## Recommended Mitigation

Extend script `07_TransferAdminToSecurityCouncil.s.sol` to include all deployed assisted adapters in the handoff loop:

```solidity
// After the bridge adapter loop:
string[3] memory assistedAdapterNames = ["MerklRewards", "EtherFiWithdrawalQueue", "StakeWiseV3ExitQueue"];
for (uint256 i = 0; i < assistedAdapterNames.length; i++) {
    address adapter = ConfigReader.readDeployedAdapterAddress(vm, currentChainId, "balanceAdapters", assistedAdapterNames[i]);
    if (adapter == address(0) || adapter.code.length == 0) continue;
    _handoff(adapter, string(abi.encodePacked("AssistedAdapter:", assistedAdapterNames[i])), deployer, council);
}
```

Alternatively, construct the assisted adapters with `admin_ = address(0)` and grant `DEFAULT_ADMIN_ROLE` to the security council directly at deploy time via a separate initialization step — though this would require the council Safe to be available before construction, which may not always be the case in the current deploy sequence.
