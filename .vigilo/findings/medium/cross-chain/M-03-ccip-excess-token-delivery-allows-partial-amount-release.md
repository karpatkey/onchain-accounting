# M-03: CcipBridgeAdapter Accepts Delivery With Amount Greater Than Invoice — Surplus Tokens Stranded

## Summary

`CcipBridgeAdapter.ccipReceive` verifies that delivered tokens satisfy `delivered_amount >= data.amount` (using `>=` not `==`). This is necessary because CCIP may deliver the exact amount, but the surplus (if any) remains in the adapter with no mechanism to recover it. More critically, if CCIP delivers more than the invoice amount (e.g., due to a routing quirk or future protocol change), only `data.amount` is released to the account via `_fundAndRelease`, and the excess tokens are permanently stranded in the adapter with no invoice to reference them.

Additionally, the check iterates `message.destTokenAmounts` and accepts the **first** token in the array that matches — it does not verify that no other tokens (unexpected tokens) were also delivered. An attacker who can send a CCIP message with extra unexpected tokens alongside the invoiced amount could cause token accumulation in the adapter.

## Vulnerability Detail

### Root Cause

```solidity
// @audit uses >= not == — surplus tokens stranded if CCIP delivers more than invoiced
bool delivered;
for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
    if (message.destTokenAmounts[i].token == asset && message.destTokenAmounts[i].amount >= data.amount) {
        delivered = true;
        break; // @audit stops at first match; doesn't verify no extra tokens
    }
}
if (!delivered) revert InvalidBridgeData();
```

When `delivered = true`, only `data.amount` is released:

```solidity
// @audit releases exactly data.amount, not the full delivered amount
_fundAndRelease(message.data, asset, data.amount);
```

The difference `destTokenAmounts[i].amount - data.amount` remains in the adapter. Since `recoverStuckAssets` requires `MANAGER_ROLE` and can only send to `bridgeEscrow` or an `authorizedAccount`, the surplus is not lost but requires manual admin intervention to recover — there is no automatic routing.

The more significant issue: `message.destTokenAmounts` can contain **multiple token entries**. The loop only verifies one entry matches the invoice. If CCIP delivers unexpected additional tokens (e.g., fee refunds, multi-token messages), they accumulate in the adapter silently.

### Code Location

- File: `src/bridge/adapters/CcipBridgeAdapter.sol`
- Function: `ccipReceive()`
- Lines: 243–251

```solidity
bool delivered;
for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
    // @audit >= allows over-delivery without routing the surplus
    if (message.destTokenAmounts[i].token == asset && message.destTokenAmounts[i].amount >= data.amount) {
        delivered = true;
        break;
    }
}
if (!delivered) revert InvalidBridgeData();
```

- File: `src/bridge/adapters/CcipBridgeAdapter.sol`
- Function: `ccipReceive()`
- Line: 253

```solidity
// @audit only releases data.amount, not the full delivered amount — surplus stranded
_fundAndRelease(message.data, asset, data.amount);
```

## Impact

- **Likelihood**: Low — CCIP typically delivers exactly the specified amount. Surplus delivery would require a protocol-level quirk.
- **Impact**: Medium — surplus tokens permanently require admin recovery; in edge cases involving CCIP protocol changes or multi-token messages, unexpected tokens accumulate silently.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions

- CCIP is configured to allow multi-token messages.
- A bridge operation is in-flight.

### Attack Steps

1. Attacker (or a CCIP quirk) delivers a CCIP message with `destTokenAmounts = [{token: USDC, amount: 100_001}]` for an invoice for 100_000 USDC.
2. `ccipReceive` finds `USDC amount (100_001) >= invoice amount (100_000)` — `delivered = true`.
3. `_fundAndRelease(payload, USDC, 100_000)` is called — releases only 100_000 to the account.
4. 1 USDC remains stranded in the adapter.
5. Over time, multiple such overdeliveries accumulate. Recovery requires manual `recoverStuckAssets` calls.

More serious variant: An attacker sends a CCIP message with `destTokenAmounts = [{token: USDC, amount: 100_000}, {token: WETH, amount: 5}]`. The loop finds the USDC match and stops. WETH is not verified, released, or rejected — it accumulates in the adapter and cannot be released via any invoice (no invoice references it).

### Expected Impact

- Minor ongoing token leakage from each over-delivery.
- Unexpected token accumulation from multi-token CCIP messages requires periodic admin intervention.
- In a worst case where the adapter accumulates a significant balance of a non-invoice token, `recoverStuckAssets` is the only path, which requires MANAGER action.

## Recommended Mitigation

1. Verify exact amount delivery (use `==` instead of `>=`):
```solidity
if (message.destTokenAmounts[i].token == asset && message.destTokenAmounts[i].amount == data.amount) {
```

2. Verify exactly one token was delivered and it is the expected one:
```solidity
if (message.destTokenAmounts.length != 1) revert InvalidBridgeData();
if (message.destTokenAmounts[0].token != asset) revert InvalidBridgeData();
if (message.destTokenAmounts[0].amount != data.amount) revert InvalidBridgeData();
```

This ensures no surplus and no unexpected tokens from a single CCIP message.
