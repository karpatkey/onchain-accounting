# INFO-08: `ERC4626VaultRatePriceFeed` — `convertToAssets` cannot be substituted for a spot price, decimals composition verified, reverting/stale base fails closed, no bug found

## Summary
Per audit brief item 3: reviewed `src/prices/ERC4626VaultRatePriceFeed.sol` in full plus its base/USD dependency
`src/prices/NavBaseUsdLib.sol` and its call site in `PriceFeedLib._selectFeedCore`
(`src/prices/PriceFeedLib.sol:124-146`). No bug found.

## Verification

### Rate source is `convertToAssets`, not a manipulable spot read, and a revert there fails closed (not open)
- File: `src/prices/ERC4626VaultRatePriceFeed.sol:96-99`
```solidity
uint256 assetsPerShare = IERC4626(VAULT).convertToAssets(_shareUnit);
price = assetsPerShare.mulDiv(base8, _assetUnit, Math.Rounding.Floor);
```
`convertToAssets` is a direct (unguarded) external view call with **no `try`/`catch` at this layer** — but that is
correct, not a gap: the call site that reads this feed, `PriceFeedLib._selectFeedCore`
(`src/prices/PriceFeedLib.sol:127-132`), wraps the ENTIRE `ICustomPriceFeed(cfg.priceFeed).getLatestPrice()` call
(which internally invokes `_compute()` → `convertToAssets`) in its own `try`/`catch`:
```solidity
try ICustomPriceFeed(cfg.priceFeed).getLatestPrice() returns (uint256 p, bool s) {
    customPrice = p;
    internalStale = s;
} catch {
    continue; // @audit a reverting convertToAssets() (paused vault, etc.) is treated as an unhealthy feed, not
              // propagated as a whole-transaction revert — fails closed to "this feed contributed nothing",
              // consistent with every other feed type in the same loop.
}
```
So a vault that reverts on `convertToAssets` (e.g. paused, or in some abnormal state) degrades that asset's pricing
to "this feed is unhealthy" — contributing to `stale = true` if it is the asset's only feed — rather than reverting
the caller's whole read or, worse, silently reporting a stale/zero price as valid. Confirmed fail-closed.

### Decimals composition verified correct, including the decimals-offset case
- File: `src/prices/ERC4626VaultRatePriceFeed.sol:54-59, 74-75, 96-99`
```solidity
uint256 private immutable _shareUnit; // 10 ** shareDecimals — amount passed TO convertToAssets
uint256 private immutable _assetUnit; // 10 ** assetDecimals — the CORRECT divisor for convertToAssets' OUTPUT
```
`convertToAssets(10**shareDecimals)` (one whole share) returns a value denominated in the underlying **asset's**
decimals per the ERC-4626 spec — not the share's decimals — so dividing by `_assetUnit` (not `_shareUnit`) is
correct and is explicitly called out as deliberate in the docstring (lines 24-27) for vaults using a decimals
offset (18-decimal shares over 6-decimal USDC-style underlyings). Traced the full unit algebra:
`assetsPerShare` (asset-decimals) `* base8` (NAV_DECIMALS) `/ 10**assetDecimals` → cancels the asset-decimals term,
leaving a `NAV_DECIMALS`-scaled result — confirmed correct for every configured subclass (sUSDe/USDe, sUSDS/USDS,
sGHO/GHO, syrupUSDC/USDC, RWIV, sXDAI/WXDAI — 18- and 6-decimal underlyings both covered by the same formula since
the underlying's own decimals are read live from `IERC20Metadata(underlying).decimals()` at construction, line 75).

### Constructor pins the base asset to the vault's own `asset()`, rejecting any mismatch
- File: `src/prices/ERC4626VaultRatePriceFeed.sol:68-72`
```solidity
address underlying = IERC4626(vault_).asset();
if (baseAsset_ != underlying) revert BaseAssetMismatch(underlying, baseAsset_);
```
Prevents the class of error the brief's oracle checklist calls "decimal mismatch / wrong feed source" at
registration time — a deploy-config typo pointing a vault feed at the wrong base asset (e.g. an ETH/USD base for a
USDC-underlying vault) cannot compile through registration.

### Reverting/stale base (NAV-sourced leg) fails closed
- File: `src/prices/NavBaseUsdLib.sol:37-59`
```solidity
try nav.getPriceDataNoDivergence(baseAsset) returns (INAVCalculator.PriceFeedData memory pd) {
    bool baseStale = pd.stale && !pd.sequencerDown;
    if (baseStale || pd.price <= 0) return (0, true, pd.updatedAt);
    ...
    if (price8 == 0) return (0, true, pd.updatedAt);
    return (price8, false, pd.updatedAt);
} catch {
    return (0, true, 0);
}
```
Every failure mode — a reverting NAV read (e.g. base not registered), a stale base feed, a non-positive base price,
or a scaled result that floors to zero — returns `stale = true` with `price8 = 0`. `ERC4626VaultRatePriceFeed
._compute()` (lines 93-95) immediately propagates that: `if (stale) return (0, true, 0, 0, updatedAt, 0);` — the
vault's `convertToAssets` call is never even reached once the base leg is known-stale, so a stale/zero base can
never be silently multiplied through into a plausible-looking nonzero price. Confirmed fail-closed on every path.

### Sequencer-down handling matches the direct-feed path (deliberately, and correctly, NOT double-penalized)
`NavBaseUsdLib.baseUsd` explicitly un-folds `pd.sequencerDown` from `pd.stale` (`baseStale = pd.stale &&
!pd.sequencerDown`) so a base asset priced by a genuinely fresh direct feed during L2 sequencer downtime is not
spuriously treated as feed-stale here — the sequencer-down condition is surfaced once, at the top-level
`nav.sequencerDown` flag, rather than cascading into every NAV-sourced custom feed's own `stale` bit (rationale
documented at `NavBaseUsdLib.sol:30-36`). This is architecturally consistent with how `Prices.latestPrice`
computes `stale = sequencerDown || feedStale` for direct-feed positions — both paths ultimately expose sequencer
status once, not per-leg.

## Impact
- **Severity**: Informational — no defect found in rate-manipulation resistance, decimals composition, or
  fail-closed behavior on a reverting/stale/zero base or vault. `convertToAssets` is a share-price rate rather than
  a spot AMM price, and this base correctly treats any inability to compute it as "unhealthy feed", never as "zero
  is a valid price".

## Recommended Mitigation
None required for the checklist items in the brief. Separate, lower-priority observation (not a bug, out of the
brief's explicit scope, noted for completeness): `convertToAssets` itself has no in-contract sanity/circuit-breaker
against a single-block rate swing (e.g. a donation-style inflation attack on a low-liquidity vault) — this is a
non-issue for the vaults currently wired to this base (sUSDe, sUSDS, sGHO, syrupUSDC, RWIV — all high-TVL,
established ERC-4626 implementations where such an attack is not economically rational), but should be re-examined
if this shared base is ever pointed at a newly-launched or low-liquidity vault.
