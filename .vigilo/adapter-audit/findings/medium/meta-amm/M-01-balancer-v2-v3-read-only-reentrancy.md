# M-01: Balancer V2/V3 Adapters — Read-Only Reentrancy on Pool Reserves Reads

## Summary

`BalancerV2PoolLib.shares` reads pool token balances via `IBalancerV2Vault.getPoolTokens(poolId)`, and `BalancerV3PoolLib.poolBalanceOfIndexed` reads live pool balances via `IStablePool.getStablePoolDynamicData()`. Neither of these reads is gated behind the Balancer Vault's reentrancy lock. An on-chain consumer of the NAV read (e.g., a lending protocol accepting this NAV as collateral) that calls `getAccountNav` inside a Balancer Vault callback (flash loan, swap callback) would receive the mid-operation reserve snapshot, which can be transiently inconsistent (Balancer V2's re-entrancy desync pattern). This corroborates the prior M-13 finding from the automated audit.

## Vulnerability Detail

### Root Cause

Balancer V2 Vault's `getPoolTokens` is NOT protected by the Vault's internal reentrancy guard (`_enterNonReentrant`). Only state-mutating functions are guarded. This means that during a flash-loan or swap callback executing inside the Vault, an external call to `getPoolTokens` will return the pool's balance state AFTER the Vault has transferred tokens out but BEFORE the callback's repayment has restored them — a transiently deflated reserve snapshot. Similarly for Balancer V3, `getStablePoolDynamicData` reads `balancesLiveScaled18` which the Vault updates transactionally; a mid-V3-operation read returns the intermediate state.

The adapters are view-only and cannot themselves be re-entered. The risk is exclusively for **on-chain contracts** that use this NAV system as a pricing oracle and can be called inside a Balancer Vault callback.

### Code Locations

**BalancerV2PoolLib** (affects BalancerV2PoolsMetaBalanceAdapter AND BalancerV2GaugesMetaBalanceAdapter):
- File: `src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolLib.sol`
- Function: `shares`
- Lines: 51, 64

```solidity
// @audit reads Vault balances — not guarded by Vault reentrancy lock
(address[] memory all, uint256[] memory balances,) = IBalancerV2Vault(vault).getPoolTokens(poolId);
// ...
amounts[k] = (ts == 0 || bptAmount == 0) ? 0 : (balances[i] * bptAmount) / ts;
```

**BalancerV3PoolLib** (affects BalancerV3PoolsMetaBalanceAdapter AND BalancerV3GaugesMetaBalanceAdapter):
- File: `src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolLib.sol`
- Function: `poolBalanceOfIndexed`
- Lines: 46–52

```solidity
// @audit reads live pool balances from pool/Vault — potentially mid-operation snapshot
IStablePool.StablePoolDynamicData memory poolData = pool.getStablePoolDynamicData();
// ...
uint256 tokenBalance = poolData.balancesLiveScaled18[tokenIndex] * userBalance / totalSupply;
```

## Impact

- **Likelihood**: Low — requires (a) this NAV system to be integrated as an on-chain oracle by a lending/margin protocol, AND (b) the attacker to trigger the NAV read inside a Balancer Vault operation. The adapters are currently read-only accounting tools used off-chain; if they remain off-chain the risk is zero.
- **Impact**: Medium — an on-chain consumer that accepts inflated/deflated NAV as collateral could be manipulated into over-collateralized loans or forced liquidations depending on the direction of the manipulation.
- **Severity**: MEDIUM (corroborates prior M-13; no change to classification)

## Attack Scenario

### Preconditions

- A lending protocol (or similar on-chain contract) integrates this NAV system as a collateral oracle.
- The lending contract calls `NAVCalculator.getAccountNav(account, ...)` as part of a collateral check.
- The attacker has access to Balancer Vault flash loans.

### Attack Steps

1. Attacker initiates a Balancer Vault flash loan.
2. Inside the Vault's `receiveFlashLoan` callback, tokens have been sent out of the pool — pool reserves are temporarily deflated.
3. Attacker triggers the lending protocol's collateral check (e.g., by calling a function on the lending contract) from inside the callback.
4. The lending protocol calls `getAccountNav(account)`, which calls into `BalancerV2PoolsMetaBalanceAdapter._instancePositions`, which calls `BalancerV2PoolLib.shares`, which calls `IBalancerV2Vault.getPoolTokens(poolId)`.
5. `getPoolTokens` returns deflated balances (mid-flash-loan). The account's LP is valued lower than true value.
6. If the lending protocol accepts deflated NAV as under-collateralized, the account can be liquidated at an unfair price.
7. Alternatively, an attacker can temporarily inflate their own position's apparent value (by supplying tokens to a pool mid-operation before the Vault updates) to borrow more than their position warrants.

### Expected Impact

- On-chain consumers of the NAV read can be manipulated during Balancer Vault operations to make incorrect collateral decisions (either forced liquidation or over-collateralized borrowing).
- The adapters' reported values are transiently incorrect for the duration of the Vault operation.

## Recommended Mitigation

For on-chain usage, add a Balancer Vault reentrancy guard check before any pool reserve read. Balancer V2 exposes:

```solidity
// Check that we are not inside a Vault operation before reading pool state
IBalancerV2Vault(VAULT).manageUserBalance(new IBalancerV2Vault.UserBalanceOp[](0));
// This reverts if the Vault is locked (re-entrant context)
```

Balancer V2's canonical pattern is to call `vault.manageUserBalance([])` (a no-op that still goes through the reentrancy guard) before reading pool state. For Balancer V3, the equivalent is calling `vault.isUnlocked()` and reverting if false, or using the `VaultGuard` pattern.

Alternatively, document that this NAV system is NOT safe for on-chain use as a collateral oracle for protocols that interact with Balancer Vaults, and restrict integration to off-chain / trusted read contexts.

Note: This is the same as prior finding M-13 from the automated audit (2026-06-vigilo-remediation.md). The mitigation path (add `ensureNotInVaultContext`) remains deferred pending a focused adapter PR.
