# INFO-04: New `ERC4626VaultRatePriceFeed` family (sUSDe/sUSDS/sGHO/syrupUSDC/RWIV/…) prices vault SHARES directly — confirmed to stay inside the "safe" wallet-yield pattern, no double-count path found

## Summary
This delta's `ERC4626VaultRatePriceFeed` (`src/prices/ERC4626VaultRatePriceFeed.sol`) is a new shared base for
custom price feeds that price an ERC-4626 vault **share token itself** (`VAULT`, returned by
`underlyingAssetSupported()`) as `rate × NAV base/USD`. This is architecturally the exact shape item 1 of the audit
brief warns about — an asset whose price feed targets the vault's share coordinate rather than its underlying — so it
was checked specifically against the M-01 double-count shape (`INFO-03`) which had examined only the
*underlying-denominated* vault-family meta-adapters (Morpho/Euler/Fluid/CompoundV3/StakeWiseV3), not this new
price-feed type. **Result: every vault priced through this feed family is governed exclusively by its own dedicated
"wallet-yield" meta-adapter, whose claimed instance coordinate is the share address itself and whose reported
`balanceAsset` is that same share address — the family INFO-03 already established is sound by construction. No
vault priced via `ERC4626VaultRatePriceFeed` is also claimed by an underlying-denominated vault-family meta-adapter.
No double-count path found.**

## Verification

### The new feed prices the share, not the underlying
- File: `src/prices/ERC4626VaultRatePriceFeed.sol:41-49`
```solidity
/// @notice The ERC-4626 vault share token this feed prices (returned by `underlyingAssetSupported`).
address public immutable VAULT;
...
/// @notice The base asset (the vault's underlying) whose USD price is read from the NAV (e.g. USDe, GHO).
address public immutable override BASE_ASSET;
```
`underlyingAssetSupported()` (line 108-110) returns `VAULT` — i.e. this feed is registered as the price feed *for the
share token's own address* (`sUSDe`, `sUSDS`, `sGHO`, `syrupUSDC`, `RWIV`, …), confirmed by every subclass, e.g.:
- `src/prices/protocols/sUSDe_CustomPriceFeed.sol:13-18` — `constructor(address sUsde_, ...) ERC4626VaultRatePriceFeed(sUsde_, ...)`.

### Every such share is governed by its own wallet-yield meta-adapter, coordinate == reported asset
- `script/config/nav-config/assets-and-price-feeds/1.json:488-501` (sUSDe), `:566-582` (sUSDS), `:583-597`
  (syrupUSDC), `:667-682` (RWIV), `:683-697` (sGHO) each register the share address with `"type": "Custom"` pointing
  at the matching `ERC4626VaultRatePriceFeed` subclass.
- `script/config/nav-config/meta-balance-adapters/1.json:223-230` (`EthenaSavingsWalletMeta` → `sUSDe`), `:331-340`
  (`SkySavingsWalletMeta` → `sUSDS`), `:277-286` (`MapleSavingsWalletMeta` → `syrupUSDC`), `:291-298`
  (`NexusMutualVaultsWalletMeta` → `RWIV`), `:203-210` (`AaveSavingsWalletMeta` → `sGHO`) — each names the SAME
  address as the meta-adapter's governed instance.
- `src/balances/MetaBalanceAdapters/walletYield/EthenaSavingsWalletMetaBalanceAdapter.sol:20-27` confirms the
  mechanism: `_positionKind() = PositionKind.Staking` and (via `WalletTokenMetaBalanceAdapterBase`, shared by the
  whole `walletYield/` family) the instance coordinate *is* the token address and the emitted `balanceAsset` *is*
  that same token — i.e. `claimant[sUSDeAddress]` is set by the meta-adapter that also reports `sUSDe` itself, so
  `includeAssetIfUnclaimed`'s `claimant[asset]` check (`NAVRegistryLib.sol:594-599`) is sound for this coordinate:
  the guard's only blind spot (per `INFO-03`) is when the claimed coordinate and the reported asset **differ**,
  which does not happen here.

### No overlap with an underlying-denominated vault-family meta-adapter
Cross-checked the five share addresses above (sUSDe, sUSDS, syrupUSDC, RWIV, sGHO) against every instance coordinate
configured for `MorphoVaultsMeta`, `EulerVaultsMeta`, `FluidFTokensMeta`, `CompoundV3CometsMeta`, `StakeWiseV3VaultsMeta`
on mainnet (`script/config/nav-config/meta-balance-adapters/1.json`) — none of these five addresses appears as an
instance of any of those families. They are single-purpose external vaults (Ethena, Sky, Maple, Nexus Mutual RWI,
Aave GHO savings), not Morpho/Euler/Fluid/Compound/StakeWise vaults, so there is no protocol-level reason to expect
an overlap, and the config confirms none exists today.

## Impact
- **Likelihood**: N/A — no double-count path exists in the current code/config for this feed family.
- **Severity**: Informational (confirmatory finding; documents that the new price-feed type introduced by this delta
  does not create a new instance of the M-01 shape).

## Recommended Mitigation
None required. Process note: if a future `ERC4626VaultRatePriceFeed` subclass is added for a vault that IS ALSO a
governed instance of an underlying-denominated vault-family meta-adapter (e.g. pricing a Morpho vault's own share
token directly, rather than relying on `MorphoVaultsMetaBalanceAdapter`'s underlying-denominated leg), re-run the
`INFO-03` reachability check before registering it as a NAV asset — that is exactly the scenario `INFO-03` flags as
latent-but-not-currently-reachable, and this new feed type is the kind of change that could make it reachable if
pointed at the wrong vault.
