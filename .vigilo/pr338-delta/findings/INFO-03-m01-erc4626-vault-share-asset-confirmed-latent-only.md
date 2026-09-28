# INFO-03: M-01 (ERC-4626 vault SHARE registered as a priced asset while governed via the underlying) — confirmed LATENT ONLY, not reachable in current merged config on any of the 8 chains

## Summary
Per the audit brief, this confirms the reachability of the previously-identified M-01 issue: registering an
ERC-4626 vault's SHARE token as a separately-priced NAV asset while a vault-meta-adapter governs that same vault via
its UNDERLYING asset. Checked the currently merged configuration on all 8 chains
(1, 10, 56, 100, 137, 8453, 42161, 5042). **No vault/comet/spoke/pool instance coordinate governed by an
underlying-denominated meta-adapter is also separately registered as a priced NAV asset today.** The issue remains
architecturally latent (the guard's soundness genuinely depends on instance-coordinate == reported-asset identity,
which the "wallet-yield" family satisfies by construction but the "vault" families do not), but is not currently
exploitable against the live/deployed configuration.

## Vulnerability Detail (mechanism, for completeness)

### Root Cause
`includeAssetIfUnclaimed`'s only defense is `claimant[bytes32(uint256(uint160(asset)))]` — i.e. it treats the
*asset address itself* as if it were a meta-instance coordinate, and only refuses to arm the default adapter when
some meta-adapter has claimed **that exact address** as its OWN governed coordinate.

- For the **wallet-yield family** (`LidoStakedEthWalletMeta`, `SkySavingsWalletMeta`, etc. — see
  `script/config/nav-config/meta-balance-adapters/1.json:203-376`), the claimed instance coordinate IS the reported
  asset by construction (`_instanceAssets` returns `[instance]` itself — noted structurally in
  `SwapMetaAdapter.s.sol:174-176`), so the identity check is sound for this family: if the token is claimed, it
  is the SAME token that would otherwise get armed on the default adapter.
- For **vault-style meta-adapters** (e.g. `MorphoVaultsMetaBalanceAdapter`,
  `src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol:25-57`), the claimed instance coordinate is
  the **vault/share** address, but the reported `balanceAsset` in every emitted leg is the vault's **underlying**
  asset (`vault.asset()`, line 32; `_leg(assetInfo, amount, ...)` at line 55 where `assetInfo` describes the
  underlying, not the vault). The vault's own share-token address is never itself a `balanceAsset` the meta-adapter
  emits.
- If an operator were to separately `registerAsset(vaultShareAddress, sharePriceFeed, ...)` (e.g. to price the share
  token directly for some other purpose) AND, in a *release-then-rearm* window (`_release` no longer re-arms the
  default adapter — see the adjacent `_release` docstring, `NAVRegistryLib.sol:512-539` — so the intended repair is
  a MANAGER calling `includeAssetInDefaultAdapter(vaultShareAddress)`), the guard would check
  `claimant[vaultShareAddress]`. This is sound only as long as `claimant[vaultShareAddress]` is set whenever ANY
  live vault-meta-adapter currently governs that vault — which it is, as long as the vault is an active instance
  (the coordinate IS the vault address for every vault family checked). The genuinely latent risk is narrower than
  first framed: it requires the specific sequence release → separately register the share as an asset → re-arm via
  `includeAssetInDefaultAdapter` → re-claim by a (possibly different) meta-adapter, during which the `_excludeIfAsset`
  self-heal (`NAVRegistryLib.sol:490`) only fires again once the RE-CLAIM happens — there is a real window between
  the manual re-arm and the re-claim in which the default adapter double-reports the share's value alongside
  whatever else already reports the underlying for that account, if the underlying is independently held.

### Code Locations
- `includeAssetIfUnclaimed`: `src/nav/NAVRegistryLib.sol:586-599`
- `_release` (no-re-arm reversal + full rationale): `src/nav/NAVRegistryLib.sol:493-540`
- `_claim` (the self-heal `_excludeIfAsset` call on (re-)claim): `src/nav/NAVRegistryLib.sol:460-491`
- Example vault-family adapter reporting the underlying, not the share: `MorphoVaultsMetaBalanceAdapter._instancePositions`, `src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol:25-57`

## Reachability Check Performed
Cross-referenced every non-wallet-yield meta-adapter instance address configured across all 8 chains
(`script/config/nav-config/meta-balance-adapters/{1,10,56,100,137,8453,42161,5042}.json`) against every asset
address registered for pricing on the same chain
(`script/config/nav-config/assets-and-price-feeds/{same chainId}.json`):

| Chain | Families checked | Overlap found |
|---|---|---|
| 1 | AaveV3 providers, AaveV4 Spokes, MorphoVaults, Gearbox markets, Balancer V3 pools/gauges, Curve pools/gauges, Convex rewarders, Fluid fTokens, CompoundV3 comets, StakeWiseV3 vaults, Euler vaults, UniswapV3 pools, Symbiotic vault, Polygon staking share | None |
| 10 | AaveV3 provider, CompoundV3 comets | None |
| 100 | AaveV3 provider, StakeWiseV3 vaults, UniswapV3 pools | None |
| 42161 | AaveV3 provider, MorphoVaults, Balancer V3 pools/gauges, Fluid fTokens, CompoundV3 comets | None |
| 8453 | AaveV3 provider, Balancer V3 pools/gauges, Fluid fTokens, CompoundV3 comets | None |
| 56 | PancakeSwapV2 pools (disabled) | None |
| 137 | Fluid fTokens | None |
| 5042 | MorphoVaults | None |

No overlaps were found on any chain. (The wallet-yield family instances — e.g. wstETH, sDAI, weETH — are *expected*
and *safe* to also be registered assets, by the family's design; they were excluded from this check as
not-applicable, per the root-cause analysis above.)

## Impact
- **Likelihood**: Currently none (not reachable against live/merged config). Would require a future config change:
  registering a vault-family meta-adapter's own instance/share address as a separate priced NAV asset.
- **Impact**: High if it ever becomes reachable — two well-formed legs (one via the vault-meta-adapter denominated
  in the underlying, one via the default adapter denominated in the share) for economically the same holding, no
  health flag.
- **Severity**: Informational (confirmed latent, not live).

## Recommended Mitigation
- Process: before registering ANY new NAV asset, check it is not the instance-coordinate of an already-governed
  vault/pool/comet/spoke meta-adapter family (i.e. not merely checking `claimant[asset]`, which only catches an
  exact-address match with a *currently claimed* instance — a config-time linter over
  `nav-config/meta-balance-adapters/<chainId>.json` instance lists vs. `nav-config/assets-and-price-feeds/<chainId>.json`
  would catch this mechanically and is what produced the table above).
- Code: consider extending `includeAssetIfUnclaimed`'s check (or adding a parallel guard reachable from
  `registerAsset`) to reject registering an asset address that matches ANY currently-governed meta-instance
  coordinate across ALL families, not only ones where the claimed coordinate happens to equal the reported asset —
  today the check is coincidentally correct only for the wallet-yield family.
