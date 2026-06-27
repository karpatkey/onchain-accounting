# M-06: ERC4626WrapBalanceAdapter Double-Counts NAV When Wrapper Token Is Also in ERC20DefaultBalanceAdapter

## Summary

`ERC4626WrapBalanceAdapter` reports the underlying value of an ERC4626 wrapper token position. When the wrapper token itself is ALSO registered as a NAV asset (with its own price feed), the `ERC20DefaultBalanceAdapter` simultaneously reports the wrapper token's wallet balance. Both positions represent the same economic value; including both inflates NAV by the full value of the position. The configuration comment for RWIV in `script/config/nav-config/balance-adapters/1.json` confirms this pattern already caused a near-double-count in production.

## Vulnerability Detail

### Root Cause

- File: `src/balances/BalanceAdapters/ERC4626WrapBalanceAdapter.sol`
- Function: `_calculateBalance(address account)`
- Line: 190
- File: `src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol` (auto-included for all registered assets)

```solidity
// ERC4626WrapBalanceAdapter:
// @audit Reports underlying value = WRAPPER.convertToAssets(WRAPPER.balanceOf(account))
// Denominated in ASSET (the underlying token)
function _calculateBalance(address account) internal view returns (uint256) {
    return WRAPPER.convertToAssets(WRAPPER.balanceOf(account));
}
```

When the wrapper token (e.g., RWIV, sGHO, syrupUSDC) is ALSO registered in NAVCalculator (so it appears in the `ERC20DefaultBalanceAdapter` inclusion list), the NAV computation includes:

- **Position A** (from ERC20DefaultBalanceAdapter): `wrapper_balance` valued at `wrapper/USD` price
- **Position B** (from ERC4626WrapBalanceAdapter): `convertToAssets(wrapper_balance)` valued at `underlying/USD` price

Since `wrapper/USD ≈ convertToAssets(1 share) × underlying/USD` by construction (the custom price feed computes the wrapper price this way), `A ≈ B` economically. Both positions add to NAV, effectively counting the same holding twice.

### Evidence from Configuration

`script/config/nav-config/balance-adapters/1.json` lines 36–39:

```json
"ERC4626Wrap_RWIV": {
  "enabled": false,
  "$comment": "DISABLED — superseded by the RWIV custom price feed (RWIV_CustomPriceFeed). RWIV is now a registered
  priced asset … the wallet adapter already reports the direct RWIV holding at RWIV/USD (same convertToAssets value
  this wrap produced as USDC). Keeping this wrap enabled would DOUBLE-COUNT the Nexus Safe's ~$250k direct RWIV."
}
```

The team identified and manually disabled the RWIV ERC4626Wrap adapter after recognizing the double-count. The same situation exists for any other ERC4626 wrapper token that has BOTH:
1. A custom price feed registered in NAVCalculator (e.g., `sGHO_CustomPriceFeed`, `sUSDe_CustomPriceFeed`, `syrupUSDC_CustomPriceFeed`)  
2. An `ERC4626WrapBalanceAdapter` deployed for the same wrapper

The six ERC4626-based custom price feeds (M-05 wave-1 context) are: sGHO, sUSDe, syrupUSDC, RWIV, sXDAI, sUSDS. If any of these is ALSO covered by an `ERC4626WrapBalanceAdapter`, double-counting occurs.

### No Adapter-Level Guard

Neither `ERC4626WrapBalanceAdapter` nor the NAVCalculator `registerAsset`/`addBalanceAdapters` flow enforces exclusivity between the ERC20 wallet-level tracking and the ERC4626 wrapper adapter. There is no on-chain check that prevents enabling both simultaneously. The protection is entirely operational (human-review of configuration).

## Impact

- **Likelihood**: Medium — The RWIV case shows this already occurred once. Any future addition of an ERC4626 wrapper token as both a registered asset and an ERC4626Wrap adapter instance will reproduce it.
- **Impact**: High — The entire position value is counted twice in NAV. For a large sGHO or sUSDS holding, this could overstate NAV by the full position value.
- **Severity**: MEDIUM (configuration-trigger; no on-chain attacker action required; human governance error)

## Attack Scenario

### Preconditions
- sUSDS is registered as a NAV asset with `sUSDS_CustomPriceFeed` (its price = `convertToAssets(1e18)` × USDS/USD).
- An `ERC4626WrapBalanceAdapter` is deployed for sUSDS with USDS as the underlying asset.
- A MANAGER transaction adds the ERC4626Wrap adapter to NAVCalculator.

### Attack Steps
1. Portfolio account holds 1,000,000 sUSDS.
2. `ERC20DefaultBalanceAdapter` reports: `sUSDS`, amount = 1,000,000 (wallet balance), priced at `sUSDS_CustomPriceFeed` → ~$1,050,000.
3. `ERC4626WrapBalanceAdapter` for sUSDS reports: `USDS`, amount = `sUSDS.convertToAssets(1,000,000)` ≈ 1,050,000 USDS, priced at USDS/USD → ~$1,050,000.
4. NAVCalculator sums both: reported NAV ≈ $2,100,000 for what is truly a ~$1,050,000 position.
5. Downstream risk systems, rebalancing logic, or any consumer of NAV uses the 2x overstated value.

### Expected Impact
- Portfolio NAV is overstated by 100% of any position in the double-registered wrapper token.
- Could mask solvency issues, trigger incorrect rebalancing, or misrepresent the portfolio to external parties.

## Recommended Mitigation

1. **Adapter-level guard**: Modify `ERC4626WrapBalanceAdapter.getAdapterPositions` to check whether the WRAPPER token itself is registered in NAVCalculator (i.e., it appears in `getRegisteredAssets()`). If the wrapper token is registered, return an empty array (the ERC20Default adapter covers it):

```solidity
// @audit-fix: guard against double-count with ERC20Default
// If the wrapper token itself is a registered NAV asset, the ERC20Default adapter
// already reports its value; return empty to avoid double-counting.
for (uint256 i = 0; i < reg.length; i++) {
    if (reg[i].asset == address(WRAPPER)) {
        return new INAVCalculator.PositionBalance[](0);
    }
}
```

2. **Constructor guard**: Alternatively, revert in the constructor if the WRAPPER token is already registered in NAVCalculator (making the misconfiguration loud at deploy time, not silently at runtime).

3. **Process**: Document the mutual exclusivity requirement in the adapter's NatSpec and deploy checklist. The CLAUDE.md conventions could explicitly state: "An ERC4626Wrap adapter must NOT be added when the wrapper token is a registered NAV asset."
