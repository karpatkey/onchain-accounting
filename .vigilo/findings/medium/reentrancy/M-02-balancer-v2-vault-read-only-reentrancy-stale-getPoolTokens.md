# M-02: Balancer V2 Vault `getPoolTokens` Read-Only Reentrancy — Stale Pool Balances Mid-Operation

## Summary

`BalancerV2PoolLib.shares()` calls `IBalancerV2Vault.getPoolTokens(poolId)` to determine the live balances of each pool token. The Balancer V2 Vault is a well-known read-only reentrancy target: during a multi-token join/exit or a flash-loan on the Vault, the Vault's internal state (token balances) is partially updated before all external transfers complete. Any `staticcall` to `getPoolTokens` during this window returns stale or mid-operation balances. If a downstream consumer of `getAccountNav()` or `getAdapterPositions()` is called during a Balancer Vault operation (e.g., inside a flash-loan callback or a join/exit hook), the reported NAV for Balancer V2 LP positions is computed from inconsistent pool state.

## Vulnerability Detail

### Root Cause

`BalancerV2PoolLib.shares()` at `src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolLib.sol:46–67` reads live pool state from the Balancer V2 Vault in a single call:

```solidity
// @audit reads live Vault state — susceptible to read-only reentrancy during Balancer operations
function shares(address vault, bytes32 poolId, address bpt, uint256 bptAmount)
    internal
    view
    returns (address[] memory tokens, uint256[] memory amounts)
{
    // @audit getPoolTokens returns balances that may be mid-update during Vault operations
    (address[] memory all, uint256[] memory balances,) = IBalancerV2Vault(vault).getPoolTokens(poolId);
    uint256 ts = effectiveSupply(bpt);
    ...
    amounts[k] = (ts == 0 || bptAmount == 0) ? 0 : (balances[i] * bptAmount) / ts;
    ...
}
```

The Balancer V2 Vault uses a transient-lock mechanism (`_setReentrancyGuard`) during flash loans and multi-operation batches. When the Vault's reentrancy guard is active:
- `getPoolTokens` can be called (it is a `view` and does not check the lock), but it may return mid-operation balances where one token has been withdrawn but others have not yet been deposited.
- The computed `amounts[k] = balances[i] * bptAmount / ts` reflects a partially drained pool, understating one token and overstating others.

The Balancer V3 adapter (`BalancerV3PoolLib.poolBalanceOfIndexed`) reads `getStablePoolDynamicData().balancesLiveScaled18`, which is similarly exposed.

### Attack Scenario (Read-Only Reentrancy Path)

A Balancer V2 flash loan or join/exit operation provides a callback window during which external view calls observe inconsistent Vault state. Any contract that (1) executes a Balancer operation and (2) calls `NAVCalculator.getAccountNav()` inside its callback reads stale Balancer LP values.

The risk is primarily to **downstream consumers** of this NAV oracle — e.g., a lending protocol that checks `getAccountNav()` to determine borrowing power, or a redemption contract that triggers payouts based on NAV. This system itself does not use NAV results in on-chain logic (no borrow limits, no on-chain share minting), so the impact is a **reporting integrity issue** that becomes exploitable at downstream integrators.

### Code Location

- File: `src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolLib.sol`
- Function: `shares()`
- Lines: 46–67

```solidity
function shares(address vault, bytes32 poolId, address bpt, uint256 bptAmount)
    internal
    view
    returns (address[] memory tokens, uint256[] memory amounts)
{
    // @audit Balancer V2 Vault is a known read-only reentrancy vector
    // @audit getPoolTokens returns stale balances when called during a Vault operation
    (address[] memory all, uint256[] memory balances,) = IBalancerV2Vault(vault).getPoolTokens(poolId);
    uint256 ts = effectiveSupply(bpt);
    ...
}
```

- File: `src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolLib.sol`
- Function: `poolBalanceOfIndexed()`
- Line: 46

```solidity
// @audit getStablePoolDynamicData() reads live balancesLiveScaled18 — also mid-operation stale
IStablePool.StablePoolDynamicData memory poolData = pool.getStablePoolDynamicData();
```

## Impact

- **Likelihood**: Low in isolation (requires a caller that queries NAV inside a Balancer callback). Elevated if downstream products use `getAccountNav()` as an on-chain oracle.
- **Impact**: Medium — stale Balancer LP balances in NAV calculation. In a partially-drained-pool scenario, one token leg may report near-zero while others report inflated amounts. If a downstream system uses this NAV to gate operations, it can be manipulated during a single transaction.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- An account holds Balancer V2 LP tokens (BPT) for a pool with at least two tokens.
- A downstream consumer (lending protocol, redemption contract, or similar) calls `NAVCalculator.getAccountNav()` inside a Balancer V2 flash-loan callback or join/exit callback.

### Attack Steps

1. Attacker initiates a Balancer V2 flash loan on the target pool (e.g., borrow all of token0 from the pool).
2. Balancer V2 Vault: partially drains token0 balance from `poolTokens`, Vault's internal state updated but external transfer not yet settled; calls attacker's `receiveFlashLoan(tokens, amounts, ...)` callback.
3. Inside the callback, attacker calls a downstream contract (e.g., a NAV-gated lending protocol) that internally calls `NAVCalculator.getAccountNav(victim, quoteAsset)`.
4. `BalancerV2PoolsMetaBalanceAdapter._instancePositions` → `BalancerV2PoolLib.shares()` → `getPoolTokens(poolId)`.
5. `getPoolTokens` returns: `balances[token0] = 0` (drained by flash loan), `balances[token1] = full`.
6. Pro-rata computation: victim's token0 LP share = 0, token1 share = inflated (full balance / totalSupply × bptAmount).
7. NAV for victim's Balancer position is grossly understated (token0 share is zero) or incorrectly distributed.
8. Downstream lending protocol undervalues victim's collateral → triggers liquidation or denies borrowing.
9. Attacker repays flash loan within the same transaction; pool state is restored. Only the NAV read was stale.

### Expected Impact

- Downstream systems using this NAV as a collateral oracle can be manipulated to trigger false liquidations or allow over-borrowing during the flash loan window.
- The system's own invariants are not violated (NAV is read-only), but protocol partners who integrate this NAV as a price oracle are exposed.

## Recommended Mitigation

1. **Check Balancer Vault reentrancy lock**: Before calling `getPoolTokens`, check if the Balancer V2 Vault's reentrancy guard is active. Balancer V2 Vault exposes `manageUserBalance` which reverts if called while locked; use this as a sentinel:

```solidity
// Check Balancer V2 Vault is not in a reentrant state
try IBalancerV2Vault(vault).manageUserBalance(new IBalancerV2Vault.UserBalanceOp[](0)) {}
catch {}
// If manageUserBalance reverts with reentrancy error, skip this pool
```

Alternatively, use `VaultReentrancyLib.ensureNotInVaultContext(vault)` from Balancer's helper library, which checks the Vault lock.

2. **Document the read-only reentrancy risk** for downstream integrators: any consumer that gates on-chain actions (lending, liquidations, redemptions) based on this NAV must either (a) not call it from within Balancer callbacks, or (b) add their own circuit-breaker.

3. **For Balancer V3**: `getStablePoolDynamicData()` has the same exposure. Balancer V3's Vault also has a reentrancy guard; verify whether V3 reverts on `staticcall` during operations (V3's read-only reentrancy protection behavior differs from V2).
