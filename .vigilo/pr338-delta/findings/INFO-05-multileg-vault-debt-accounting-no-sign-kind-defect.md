# INFO-05: Multi-leg vault/credit accounting (StakeWise osToken debt, Gearbox credit accounts) — no sign/kind/netting defect found; both fail closed on partial reads

## Summary
Per item 3 of the audit brief, reviewed the multi-leg vault-style adapters that emit both a credit and a debt leg
for the same instance — `StakeWiseV3VaultsMetaBalanceAdapter` (Staking vs Borrowed osToken debt) and
`GearboxV3CreditAccountsMetaBalanceAdapter` (Collateral vs Borrowed) — for whether this delta's changes to the
shared `MetaBalanceAdapter` base (the gas-metered `_assetsForInstances`/`_positionsForInstances` fan-out) could flip
a leg's sign/kind or cause a debt leg to be dropped while its offsetting credit leg is kept (the over-report
direction). **Neither adapter has a reachable defect: both are structured to drop the WHOLE instance (all legs) on
any read that cannot be reported in full, never a partial one that keeps collateral/credit and silently loses debt.**

## Verification

### StakeWiseV3VaultsMetaBalanceAdapter — independent per-leg reads, correct signs
- File: `src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol`, `_instancePositions`, lines 66-101.
```solidity
if (vaultAssets > 0) {
    temp[count++] = _leg(asset, vaultAssets, false, pid, PositionKind.Staking);   // isDebt = false
}
if (mintedOs > 0) {
    temp[count++] = _leg(asset, mintedOs, true, pid, PositionKind.Borrowed);      // isDebt = true
}
```
Both `vault.convertToAssets(vault.getShares(account))` and `OS_TOKEN_VAULT_CONTROLLER.convertToAssets(...)` are
plain `view` calls with no `try`/`catch` in this function — if either read reverts, the whole `instancePositions`
external call reverts, which is caught by `MetaBalanceAdapter._positionsForInstances`'s per-instance `try`/`catch`
(`MetaBalanceAdapter.sol:374-385`) and — assuming the revert is not classified as gas-exhaustion — the WHOLE
instance (both legs) is dropped, not just one. There is no code path that reports the `Staking` credit leg while
silently dropping the `Borrowed` osToken debt leg for the same vault, or vice versa: both come from the same
un-isolated function body, so a revert on either read takes down both.

### GearboxV3CreditAccountsMetaBalanceAdapter — explicit whole-account drop, documented invariant
- File: `src/balances/MetaBalanceAdapters/GearboxV3CreditAccountsMetaBalanceAdapter.sol:67-78`
```solidity
(bool debtOk, uint256 debt) = _debtOf(cm, ca);
if (!debtOk) return new INAVCalculator.PositionBalance[](0);   // @audit whole account dropped, not just the debt leg
...
if (debt > 0 && !_debtReportable(cm)) return new INAVCalculator.PositionBalance[](0);  // same for unregistered underlying
```
This is the opposite of the dangerous shape: the adapter computes debt FIRST and drops the entire account (both the
`Collateral` legs and the `Borrowed` leg) if debt cannot be read or cannot be priced, specifically to avoid reporting
collateral without its offsetting debt (documented at lines 37-44, 67-78). Individual collateral tokens may still be
dropped independently (unregistered/zero balance, lines 117-129) — that is a legitimate under-report of the credit
side only, never a case where debt is dropped while collateral is kept.

### The delta's gas-metering interacts safely with both
`_positionsForInstances`'s gas classification (`MetaBalanceAdapter.sol:363-395`, the in-scope delta) treats a
per-instance revert as either `InstanceGasExhausted` (reverts the whole NAV read) or an ordinary revert (drops the
WHOLE instance's legs, `perInstance[i] = new PositionBalance[](0)`) — in both outcomes, StakeWise's Staking+Borrowed
pair and Gearbox's Collateral+Borrowed set are dropped or kept TOGETHER, never split. Neither adapter's
`_instancePositions` internally swallows a partial failure that would let this per-instance atomicity be defeated
from inside (StakeWise has no internal `try`/`catch` at all in this function; Gearbox's internal `try`/`catch`s are
all on the credit/debt-read side and explicitly documented as "drop the whole account").

## Impact
- **Likelihood**: N/A — no defect found.
- **Severity**: Informational (confirmatory finding for item 3 of the audit brief; documents NO double-count / no
  dropped-debt-while-credit-kept path in these two multi-leg adapters, including under the delta's new gas-metered
  fan-out).

## Recommended Mitigation
None required. If a future multi-leg adapter is added to this family, preserve the same invariant demonstrated here:
either read the debt/borrow leg(s) FIRST and drop the whole instance on failure (Gearbox's pattern), or ensure no
internal `try`/`catch` inside `_instancePositions` can silently keep a credit leg while dropping its offsetting debt
leg for the same instance.
