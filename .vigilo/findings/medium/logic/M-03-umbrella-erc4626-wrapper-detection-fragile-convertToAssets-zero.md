# M-03: AaveUmbrellaBalanceAdapter uses `convertToAssets(0) == 0` as ERC4626 wrapper detection; non-standard implementations bypass the check

## Summary

`AaveUmbrellaBalanceAdapter._isErc4626Wrapper` identifies whether an intermediate token (e.g. a waToken) is an ERC4626 wrapper by probing `convertToAssets(0) == 0`. EIP-4626 does not guarantee that converting zero shares yields zero assets; implementations that round up small amounts or have non-zero virtual offsets (e.g. to mitigate inflation attacks) may return a non-zero value. When the check fails for a real wrapper, the adapter returns the user's balance in the wrong denomination — wrapped-token units instead of bare-reserve units — which, if the wrapped token is itself registered as a priced asset, can over-report the position value.

## Vulnerability Detail

### Root Cause

```solidity
// @audit non-standard ERC4626 vaults may return != 0 for convertToAssets(0)
function _isErc4626Wrapper(address token) internal view returns (bool) {
    address inner = _safeAsset(token);
    if (inner == address(0)) return false;
    (bool ok, bytes memory ret) =
        token.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("convertToAssets(uint256)", uint256(0)));
    if (!ok || ret.length < 32) return false;
    return abi.decode(ret, (uint256)) == 0;  // @audit assumes convertToAssets(0) == 0
}
```

EIP-4626 specifies that `convertToAssets` MUST NOT revert, but the specification does not mandate that the result for zero shares is exactly zero. Some implementations deliberately add a virtual offset to prevent share-inflation attacks (e.g. ERC4626 with `_decimalsOffset > 0`), or apply ceiling rounding for the zero case. In those implementations `convertToAssets(0)` returns a non-zero value, causing `_isErc4626Wrapper` to return `false`.

When `_isErc4626Wrapper` returns `false` for a real ERC4626 wrapper (e.g. a waToken), two functions are affected:

1. **`_resolveBareReserve`** returns `firstLevel` (the waToken address) instead of `firstLevel.asset()` (the bare reserve). This changes which asset the position is reported under.

2. **`_stakedUnderlying`** returns `amount` in waToken units without the final `convertToAssets` hop, yielding shares-denominated quantity instead of bare-reserve quantity.

```solidity
// @audit if _isErc4626Wrapper is false for a real wrapper:
// amount is in waToken (wrapped) units, not bare-reserve units
// _resolveBareReserve returned waToken address, so the position
// is reported under the waToken's asset address
if (_isErc4626Wrapper(firstLevel)) {
    return IERC4626Like(firstLevel).convertToAssets(amount); // skipped
}
return amount; // @audit wrong denomination for a real wrapper
```

### Code Location

- File: `src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol`
- Function: `_isErc4626Wrapper()`, `_stakedUnderlying()`, `_resolveBareReserve()`
- Lines: 331-339 (`_isErc4626Wrapper`), 271-286 (`_stakedUnderlying`), 314-324 (`_resolveBareReserve`)

## Impact

- **Likelihood**: Low — current Aave waToken implementations (StataTokenV2) do implement `convertToAssets(0) == 0`; this issue manifests only if a future waToken or ERC4626 wrapper added to the Umbrella module uses an implementation with a virtual offset or ceiling rounding.
- **Impact**: High — if the waToken is registered in NAVCalculator with its own price feed AND the share price diverges from 1:1 versus the bare reserve, the position value is computed against the wrong unit, potentially over-reporting NAV.
- **Severity**: MEDIUM (Low likelihood, High impact)

## Attack Scenario

### Preconditions

- A new Umbrella stake token is added whose intermediate waToken uses a `_decimalsOffset > 0` ERC4626 implementation (causing `convertToAssets(0) > 0`).
- The waToken address is registered in NAVCalculator with a price feed (separate from the bare-reserve feed).
- The waToken's price feed values waToken shares at a premium (e.g. 1.05x the bare reserve price) because shares have accrued yield.

### Attack Steps

1. `_isErc4626Wrapper(waToken)` returns `false` because `waToken.convertToAssets(0) != 0`.
2. `_resolveBareReserve(stakeToken)` returns `waToken` address (not the bare reserve).
3. `_stakedUnderlying(stakeToken, account)` returns `stakeToken.convertToAssets(userShares)` in waToken units, not bare-reserve units.
4. The position is reported as `(waToken, waToken_amount)`.
5. NAVCalculator prices `waToken_amount` using the waToken price feed.
6. If waToken's price is 1.05x the bare reserve per waToken unit, and `convertToAssets(shares)` already accounts for the yield (i.e. the waToken amount IS in bare-reserve-equivalent units), then the position is priced at 1.05x the correct value — over-reporting NAV.

### Expected Impact

- Staked Umbrella positions are over-valued in NAV by the waToken share-price premium versus the bare reserve.
- The "assistant can only under-report, never over-report" invariant for the Umbrella adapter is violated for non-standard ERC4626 intermediate tokens.

## Recommended Mitigation

Replace the `convertToAssets(0) == 0` heuristic with a more robust check. The presence of an `asset()` returning a non-zero contract address is sufficient evidence that a token is an ERC4626 wrapper — the ERC4626 standard mandates `asset()` returns the underlying token address. Remove the `convertToAssets(0)` probe:

```solidity
function _isErc4626Wrapper(address token) internal view returns (bool) {
    // asset() returning a non-zero contract is sufficient evidence of an ERC4626 wrapper.
    // The convertToAssets(0) == 0 probe is not mandated by EIP-4626 and fails for vaults
    // that use _decimalsOffset > 0 or ceiling rounding.
    address inner = _safeAsset(token);
    if (inner == address(0)) return false;
    // Verify `inner` is itself a contract (non-zero code length).
    uint256 size;
    assembly { size := extcodesize(inner) }
    return size > 0;
}
```
