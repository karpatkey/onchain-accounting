# INFO-02: `includeAssetIfUnclaimed`'s guard is blind to plain adapters that report a different asset than they read (pre-existing, already documented; restated as an operational review item)

## Summary
`includeAssetInDefaultAdapter` / `includeAssetIfUnclaimed`'s only defense against double-arming an asset is the
`claimant` map, which tracks **meta-instance coordinates only**. Three existing *plain* balance adapters read one
token's balance but report a *different* token as the asset
(`CapStablecoinBalanceAdapter`, `AaveV3SafetyModuleBalanceAdapter`, `AaveUmbrellaBalanceAdapter`). A MANAGER calling
`includeAssetInDefaultAdapter` on the asset one of these three reports would pass the `claimant` check (that asset
is not a meta coordinate) and arm the default adapter for it — creating two reporters for the same economic
exposure. This is **not new in this delta** and is extensively self-documented at the exact place it matters
(`NAVRegistryLib._release`, lines 512-539, explicitly names this as the reason the auto-re-arm was removed). It is
restated here only because it is directly adjacent to, and the stated rationale for, code that *is* in the audited
delta (`_release`'s no-re-arm reversal), and because item 3 of this audit's brief (`includeAssetIfUnclaimed`) points
at the same guard function.

## Vulnerability Detail

### Code Location
- File: `src/nav/NAVRegistryLib.sol`
- Function: `includeAssetIfUnclaimed`
- Lines: 586-599

```solidity
function includeAssetIfUnclaimed(
    mapping(bytes32 => address) storage claimant,
    address erc20DefaultBalanceAdapter,
    address asset,
    bool revertIfClaimed
) external {
    bytes32 coord = bytes32(uint256(uint160(asset)));
    address holder = claimant[coord];
    // @audit `claimant` only ever gets written by `_claim`, which only meta-adapter instance registration calls.
    // A PLAIN adapter that reads token X's balanceOf but reports token Y as the asset (Cap/AaveV3
    // SafetyModule/AaveUmbrella) never touches `claimant[Y]`. So arming the default adapter for Y here cannot
    // see that Y is already reported by one of those three, even though economically it is.
    if (holder != address(0)) {
        if (revertIfClaimed) revert IBalances.MetaInstanceClaimedByAnotherAdapter(coord, holder);
        return;
    }
    ERC20DefaultBalanceAdapter(erc20DefaultBalanceAdapter).addSupportedAsset(asset);
}
```

The exact risk and its rejected fixes are already documented in-repo at `NAVRegistryLib.sol:512-539` (`_release`'s
docstring), which is why this is filed as Informational rather than a fresh finding — it is a known, accepted,
already-mitigated-by-process risk, not a newly discovered gap.

## Impact
- **Likelihood**: Low — requires a MANAGER to call `includeAssetInDefaultAdapter` specifically on an asset that is
  ALSO the reported (not read) asset of `CapStablecoinBalanceAdapter`/`AaveV3SafetyModuleBalanceAdapter`/
  `AaveUmbrellaBalanceAdapter`, i.e. USDC (Cap) or the relevant underlying(s) for the two Aave wrapper adapters.
- **Impact**: High if triggered — two well-formed, non-debt legs for the same underlying holding, no health flag.
- **Severity**: Informational here (procedural, already documented and guarded by convention, not by this delta),
  but flagged because it is the direct rationale for code that IS in the delta.

## Attack Scenario
Not a novel attack path for this delta — see `_release`'s own docstring for the full analysis. Operationally: before
any future `includeAssetInDefaultAdapter(asset)` call, confirm `asset` is not the *reported* asset (as opposed to
the *read* token) of `CapStablecoinBalanceAdapter`, `AaveV3SafetyModuleBalanceAdapter`, or `AaveUmbrellaBalanceAdapter`.

## Recommended Mitigation
No code change recommended (the in-repo docstring already explains why the two candidate fixes were rejected as
unsafe/unaffordable). Recommend adding this specific runbook check — "before `includeAssetInDefaultAdapter(asset)`,
grep the three wrapper-style plain adapters for `asset` as a reported (not read) token" — to whatever operational
checklist governs MANAGER actions, since the code itself cannot make this check.
