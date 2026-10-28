# Onchain Accounting System (NAV) — Deployed Addresses

Canonical deployed-address reference for the Onchain Accounting System (NAV). The machine source of truth is `script/config/deployments/<chainId>.json` per chain (written by the deploy scripts); this file mirrors those records. The one exception is `UUPSPlaceholder` — a transient CREATE2 address used only during the atomic proxy deploy, identical everywhere and not persisted in the per-chain JSON; it is listed here for completeness.

Deployed across **25 chains**: 8 fully configured (custom price feeds + balance adapters) + 17 with the NAV implementation + proxy only.

- **Roles (current, 2026-10-09 — PR #338 timelock handoff complete):** on all 25 chains `DEFAULT_ADMIN_ROLE` + `MANAGER` on the NAV are held by the `TimelockController` `0xAB92EA75D07792915eB1f29259354866B880dFC2` and the security-council Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` (5-of-8 on every chain); `AssetKindRegistry` holds `MANAGER` only, by design. The deployer EOA `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` holds no role. The Merkl rewards adapter `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` is administered by the security-council Safe only. Step list: `script/deploy/PR338_EXECUTION_SHEET.md`; tx record: `script/deploy/PR338_DEPLOY_LOG.md`.
- **Bridge:** deployed-but-dormant — only the `BridgeEscrow` implementation is deployed (no proxy, adapters, or wiring).
- **Polygon zkEVM is intentionally excluded** — the network is being sunset by Polygon, so the system is not deployed there.

---

## Canonical layer (CREATE2 — identical on every chain)

Deployed via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), so each address is the same on all 25 chains.

**Redeployed 2026-08-18 — every address below changed.** The previous generation is listed under
*Superseded* at the end of this section; it is **abandoned in place**, still answering but no longer
maintained, so it will drift from the funds' true NAV as new assets and feeds land only on the new
stack. Consumers must move to `0x54EaD2A1…`.

**Upgraded in place 2026-09-29/30 (PR #338).** The proxy did not move; the implementation, both libraries and
every meta balance adapter did (the shared `MetaBalanceAdapter` base changed), and 17 wallet-yield meta adapters
were added. Superseded (still on-chain, unused): implementation `0x40e4134849308d53F85A8B685324E2189b13ff7D`,
PriceFeedLib `0x713e69954e11c2eD19dBB84950674D6a68DBfebc`, NAVRegistryLib
`0x55b6AA29D296Eb2Ee0e7b76686eaA2e479CA3511`; the old meta-adapter addresses are in
`script/config/deployments/<chainId>.pre-swap.json`. Per-transaction record: `script/deploy/PR338_DEPLOY_LOG.md`.
The throwaway 1/1 ops Safe `0xEEd8dC3c034Be12ff66646cCaAf07D35C43E8AA1` that executed the swaps holds no role.

| Contract | Address |
| --- | --- |
| **NAVCalculator proxy** | `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214` — the address every consumer should call |
| NAVCalculator implementation | `0x1D7a950730620795434216827B8D15B6Fc37e79a` (ADR 0029, deployed 2026-10-28 on all 25 + Robinhood; becomes live on each chain when its Council batch executes `upgradeToAndCall` — until then the proxy still runs the previous `0xA7243DCDF7e4D6f8FA20A9F022186C0d0778C2b6`. Tx list: `script/deploy/ADR0029_DEPLOY_LOG.md`) |
| PriceFeedLib | `0xaBCC2526a6ebCFE637EB2B660410adff60eCFB73` (linked into the implementation above; previous `0x0f913658d70BB19b7B42eF9926c3df7c70fafCf2`) |
| NAVRegistryLib | `0x3D5369B0b2044d62a8f643bf9a2b8CC03775934D` |
| ERC20Default balance adapter | `0x4Bc39Dce61245F5A63189d1FA03E6D76646f1EE6` (created inside `NAVCalculator.initialize`; identical everywhere) |
| UUPSPlaceholder | `0x85Ee38b0385D042918a59C01dB319b6eDdF7A8Cf` (temporary impl during atomic proxy deploy) |
| TimelockController | `0xAB92EA75D07792915eB1f29259354866B880dFC2` — OpenZeppelin `TimelockController` (CREATE2, identical on all 25 chains). `minDelay` 0, proposer + canceller = the security-council Safe, open executor, self-administered. Holds `DEFAULT_ADMIN_ROLE` + `MANAGER` on the NAV (PR #338) |
| BridgeEscrow implementation | `0xe2237d9776041514b1AC66856407Ed344b480De0` (dormant; recorded on 23 chains — no record on HyperEVM (999) or Arc (5042), the two in-scope chains brought up without the bridge layer) |

**Superseded 2026-08-18** (do not call): proxy `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d`,
implementation `0x07bd077cFB40bBDa8A67d0D33ce41b974aB0F8a8`, PriceFeedLib
`0x450421a334DE63F75e1d47399d9713f755aaEfF2`, NAVRegistryLib
`0x549f6fB0EC34E18A82A320b79C968a9Ca6e7b96b`, ERC20Default
`0x41967559D0a20Ad102F6e27b7723b1963390aD75`.

### `AssetKindRegistry` — same address on every chain

| Contract | Address |
| --- | --- |
| `AssetKindRegistry` | `0xf60467a88C2b4d0f46C0c41C3Ba0C74da3d3CCD0` (all 25 chains) |

Deployed via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with salt
version `DeploySalts.ASSET_KIND_REGISTRY = 2`. Its only constructor argument is the NAV proxy, which is
itself CREATE2-identical fleet-wide, so the init-code hash is the same on every chain and the salt
yields one address everywhere. It holds `MANAGER` on the NAV and is the path through which assets are
registered, classified and labelled in one transaction.

**Superseded generation 1** (deployed 2026-08-18 with plain `CREATE`, so the address followed the
deployer's nonce and came out as **14 distinct addresses across the 24 chains**, several colliding only
because their nonces happened to match). Those contracts are still on-chain but are wired to nothing:
`setAssetKindRegistry` was repointed at the CREATE2 address and their `MANAGER` role on the NAV was
revoked. Do not read them, and do not carry a per-chain registry address out of an old record —
`.AssetKindRegistry` in `script/config/deployments/<chainId>.json` now holds the same value for every
chain. The salt is version `2`, not `1`, precisely so a gen-1 address can never be mistaken for it.

### NAV-only balance adapters — also one address on every chain

These adapters take the NAV proxy as their **only** constructor argument. The NAV proxy is itself
CREATE2-identical fleet-wide, so each has the same init-code hash everywhere and one salt yields one address:

| Adapter | Address | Chains |
| --- | --- | --- |
| `AaveV3InstancesMeta` | `0xa1b3c695A768A6Ce571fF699F463224CB32260C1` | 1, 10, 100, 8453, 42161 |
| `AaveV4SpokesMeta` | `0xAd5b905ad5BB13909aE658a1910bC4cdFcD81dE3` | 1 |
| `AaveV3SafetyModule` | `0xa356717027B5d4010a7449904545E5aFb355Bdc9` | 1 |
| `BalancerV3PoolsMeta` | `0x8AE70624CB7729B0408C8f0ce8ffdac9974FE33A` | 1, 8453, 42161 |
| `CurvePoolsMeta` | `0x4c25B00401d28d5F6FC65a7Af8386b239FA5e735` | 1 |
| `EulerVaultsMeta` | `0x331566e8F7b48Fa683fE865403Cf4311b50A7710` | 1 |
| `FluidFTokensMeta` | `0xb1a03cDD28cAA91f409C417C9f56ab53bc9d7ae9` | 1, 137, 8453, 42161 |
| `GearboxV3MarketsMeta` | `0xE338E5d4F7adF34107239D59828DEAD2fa2cfD86` | 1 |
| `MorphoVaultsMeta` | `0x72a012B30b240458C3f79fd20E5c2A907d77e54f` | 1, 42161 |
| `SymbioticVaultsMeta` | `0x320699dE0693d71C28f5559a68635495AdA0826c` | 1 |
| `AaveSavingsWalletMeta` | `0x36A3F6424FB9AA5B1a3cDD33B2cE09C0c5035D8F` | 1 |
| `AnkrStakedEthWalletMeta` | `0xc157f1dF063b161Ec9a89aE25aeBc6fB95b6E90e` | 1 |
| `CoinbaseStakedEthWalletMeta` | `0x91d437752463B60103d515c16680d0a17C1c91F9` | 8453 |
| `EthenaSavingsWalletMeta` | `0x51970009da25B52048ACBBB850B11aa198bdC64B` | 1 |
| `EtherFiStakedEthWalletMeta` | `0x8a6fde256DD9B262596A22BC4a6c8292Fc3a5D65` | 1, 8453, 42161 |
| `KelpRestakedEthWalletMeta` | `0xc0A8E9FA22F28bDE931624c6A454DE649a790273` | 1, 42161 |
| `LidoStakedEthWalletMeta` | `0x7ED4F12798ea3f26AE02a6521eE84702CE5f8f90` | 1, 10, 100, 8453, 42161 |
| `LiquidCollectiveStakedEthWalletMeta` | `0x1473445103673F89Af909387eB905B4328D522D3` | 1 |
| `MapleSavingsWalletMeta` | `0xDeE2BcC847DFc113ec70296C5D31e055a6cd902b` | 1, 42161 |
| `NexusMutualVaultsWalletMeta` | `0xeA71c3af5127f7fC0F791FE0bFfF9826Ea589060` | 1 |
| `RenzoRestakedEthWalletMeta` | `0x9145A559108426e1eA429A2A6441e2A875f069ec` | 1, 42161 |
| `ReserveBasketsWalletMeta` | `0x11e68edfBc0449b1c863e11b866B7aF4290F8469` | 1 |
| `RocketPoolStakedEthWalletMeta` | `0x75D1cB3040Dc0322C3f747807360A1Ec03A80eB4` | 1 |
| `SkySavingsWalletMeta` | `0xb967b206445ca58445d09b6CE9878add5Bb14dd4` | 1, 100 |
| `SparkSavingsWalletMeta` | `0xd848BE8B5f580C7F8a7f93256DD218cf06CAcd3f` | 1 |
| `StaderStakedEthWalletMeta` | `0x30c6A35827E3dC294f410073C305C8b3f91f1a4a` | 1 |
| `StakeWiseV3OsTokenWalletMeta` | `0x818dD183121641B09752891bB7E971b0FE29e101` | 1, 100 |

Each is registered at this address on every chain listed, with no exceptions. The address is a pure function
of (creation code, NAV proxy, salt version), so it can be re-derived rather than trusted — see
`test/nav/Create2FleetWideAddresses.t.sol`, which pins the original ten and asserts they do not vary by chain. The 17
wallet-yield adapters (added 2026-09-29 by PR #338) are NAV-only too, and are confirmed identical across every chain
that deploys them by `published_addresses_guard.py` against the records.

**Every other balance adapter and all custom price feeds remain plain CREATE, and correctly so:** their
constructors take chain-specific protocol addresses, so their init code genuinely differs per chain and CREATE2
could not give them a shared address. Read those per-chain from the deployment records.

> **Deployments-JSON keys** (for `jq` lookups in `script/config/deployments/<chainId>.json`): `NAVCalculatorProxy`, `NAVCalculatorImplementation`, `PriceFeedLib`, `NavRegistryLib` (mixed case — deliberate, to keep the library's CREATE2 salt stable), `BridgeEscrowImplementation`; the default adapter is at `.balanceAdapters.ERC20Default`.

---

## Chains (25)

| Chain | Chain ID | Scope | Custom price feeds | Balance adapters (excl. ERC20Default) |
| --- | --- | --- | --- | --- |
| Ethereum | 1 | full | 34 | 42 |
| Optimism | 10 | full | 0 | 3 |
| Arbitrum | 42161 | full | 8 | 12 |
| Base | 8453 | full | 4 | 9 |
| Gnosis | 100 | full | 3 | 6 |
| BSC | 56 | full | 0 | 0 |
| Polygon | 137 | full | 0 | 1 |
| Berachain | 80094 | impl + proxy | — | — |
| Ink | 57073 | impl + proxy | — | — |
| Linea | 59144 | impl + proxy | — | — |
| opBNB | 204 | impl + proxy | — | — |
| Sonic | 146 | impl + proxy | — | — |
| Unichain | 130 | impl + proxy | — | — |
| Scroll | 534352 | impl + proxy | — | — |
| X Layer | 196 | impl + proxy | — | — |
| Celo | 42220 | impl + proxy | — | — |
| Avalanche | 43114 | impl + proxy | — | — |
| Mantle | 5000 | impl + proxy | — | — |
| World Chain | 480 | impl + proxy | — | — |
| Monad | 143 | impl + proxy | — | — |
| Plasma | 9745 | impl + proxy | — | — |
| Hemi | 43111 | impl + proxy | — | — |
| 0G | 16661 | impl + proxy | — | — |
| HyperEVM | 999 | impl + proxy | — | — |
| Arc | 5042 | impl + proxy + assets | 1 | 1 |

The 17 impl+proxy chains run the canonical layer only; custom price feeds and balance adapters are registered as assets land on each.

---

## Balance adapters (per chain)

Entries marked † are **deployed but NOT registered on the NAV Calculator**. The contract exists at its CREATE2
address and is verified, but the NAV does not call it, so it contributes nothing to any reading and costs nothing
on the read path. They are pre-provisioned so that onboarding a pool or market later is a single
`addMetaBalanceAdapter` transaction instead of a deploy plus a registration. They are deliberately absent from
`nav-config/`, which is the tree `06_Configure` reads — adding them there is what activates one.


Generated from `script/config/deployments/<chainId>.json`, the only place deployed addresses live. Entries
marked ★ are the CREATE2 adapters listed above, identical on every chain; the rest are plain `CREATE` and
unique per chain because their constructors take chain-specific protocol addresses. `ERC20Default` is
omitted: it is minted inside `initialize()` and appears in the canonical layer above.

Entries marked ☆ are CREATE2 too, but with a **weaker** guarantee than ★: they take one chain-specific
protocol address alongside the NAV, so they share a single address across the chains that share that protocol
address, and take a different — still deterministic — address where it differs.

`Deployed on` is where the adapter actually exists today; `would reuse` is where a future deployment would land
on the same address. They are different claims and are kept in separate columns — CREATE2 fixes *where* a contract
lands, not *whether* it exists, and an adapter is deployed on a chain only when the funds hold that protocol's
positions there.

| Adapter | Address | Deployed on | Would reuse this address on | Because |
| --- | --- | --- | --- | --- |
| UniswapV3PoolsMeta ☆ | `0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52` | 1 | 10, 137, 42161 | those chains host the canonical NonfungiblePositionManager at `0xC36442…FE88` |
| UniswapV3PoolsMeta ☆ | `0xaC47D9Cbe8B3EDc9c9d1a6c8092054299bBC1adE` | 100 | — | Gnosis hosts its OWN Uniswap V3: NPM `0xAE8fbE…9FA3`, factory `0xe32F7d…89B1`. A different constructor arg, so a different address — it is not part of the row above |
| MorphoMarketsMeta ☆ | `0x08e590BcFc753fC6383aFE327253558C962D3EB6` | **1, 8453** | — | both host Morpho at `0xBBBB…FFCb`, so both already answer at this one address |
| MorphoMarketsMeta ☆ | `0xCFf47e28B51a7f4599150f73c348E1a155A93437` | 42161 | — | Arbitrum's Morpho is a separate deployment at `0x6c247b1F…8F5e` |
| FluidVaultsMeta ☆ | `0x161EB6952Ffc4319a05bd8FEBB1B90283F267005` | 1 | 56, 137, 8453, 9745, 42161 | Fluid deploys its VaultResolver deterministically at `0xA5C3E165…95cC` on all six |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` | **1, 10, 56, 100, 137, 8453, 42161** | — | Merkl deploys its Distributor deterministically at `0x3Ef3D8bA…D9Ae` on all seven, so all three constructor args (distributor, NAV, admin) are fleet-identical and one salt yields one address. **The admin is a constructor arg**, so changing it would move this address on every chain at once — hand admin over with `grantRole`/`renounceRole`, never by redeploying |

Membership of the Uniswap V3 list is decided by **calling** `name()`/`factory()` on the candidate chain, never
by checking that the address has code: several chains carry unrelated code at `0xC36442…FE88`, and Base's real
position manager is at a different address entirely.

### Ethereum (1)

| Adapter | Address |
| --- | --- |
| AaveSavingsWalletMeta ★ | `0x36A3F6424FB9AA5B1a3cDD33B2cE09C0c5035D8F` |
| AaveUmbrella | `0x7299757E188000ca576c4197E1Ed1c53A04AC995` |
| AaveV3InstancesMeta ★ | `0xa1b3c695A768A6Ce571fF699F463224CB32260C1` |
| AaveV3SafetyModule ★ | `0xa356717027B5d4010a7449904545E5aFb355Bdc9` |
| AaveV4SpokesMeta ★ | `0xAd5b905ad5BB13909aE658a1910bC4cdFcD81dE3` |
| AnkrStakedEthWalletMeta ★ | `0xc157f1dF063b161Ec9a89aE25aeBc6fB95b6E90e` |
| BalancerV3GaugesMeta | `0x1EE1b9dA14225B8a6Dd8D87d1052eC4D37A6E362` |
| BalancerV3PoolsMeta ★ | `0x8AE70624CB7729B0408C8f0ce8ffdac9974FE33A` |
| CapSavings | `0xEc605FC2521792f2018dF92Bb5aDBf85EB417cb6` |
| CapStablecoin | `0x121583E21C671e9B1193FE478ec9dc9D73D73a3F` |
| CompoundV3CometsMeta | `0xDf85833a69B74e86e38160405a12bA7356AcdCdf` |
| ConvexCurveLPStakingMeta | `0xB41E5A6F34FdD511716Ee455cb6047D1Fcc171F6` |
| CurveGaugesMeta | `0xC0c22b89E9cC80a3891dF0ceF1e81b78b865F646` |
| CurvePoolsMeta ★ | `0x4c25B00401d28d5F6FC65a7Af8386b239FA5e735` |
| EthenaCooldown | `0x3F12f2baf245eeF00F6b0C5C2173Df990FFBa796` |
| EthenaSavingsWalletMeta ★ | `0x51970009da25B52048ACBBB850B11aa198bdC64B` |
| EtherFiStakedEthWalletMeta ★ | `0x8a6fde256DD9B262596A22BC4a6c8292Fc3a5D65` |
| EtherFiWithdrawalQueueAssisted | `0x5c5c1A98CdF07c9D9B4664933AF98a30e36F3618` |
| EulerVaultsMeta ★ | `0x331566e8F7b48Fa683fE865403Cf4311b50A7710` |
| FluidFTokensMeta ★ | `0xb1a03cDD28cAA91f409C417C9f56ab53bc9d7ae9` |
| FluidVaultsMeta ☆ | `0x161EB6952Ffc4319a05bd8FEBB1B90283F267005` |
| GearboxV3MarketsMeta ★ | `0xE338E5d4F7adF34107239D59828DEAD2fa2cfD86` |
| KelpRestakedEthWalletMeta ★ | `0xc0A8E9FA22F28bDE931624c6A454DE649a790273` |
| KelpWithdrawalQueue | `0x136439b0CA2Ff5e9Ec8dC472222248E3A57CeF43` |
| LidoStakedEthWalletMeta ★ | `0x7ED4F12798ea3f26AE02a6521eE84702CE5f8f90` |
| LidoWithdrawalQueue | `0xD32d7db9c94E0A08ef354D73d618B86b8215A2cF` |
| LiquidCollectiveStakedEthWalletMeta ★ | `0x1473445103673F89Af909387eB905B4328D522D3` |
| MapleSavingsWalletMeta ★ | `0xDeE2BcC847DFc113ec70296C5D31e055a6cd902b` |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` |
| MorphoMarketsMeta ☆ | `0x08e590BcFc753fC6383aFE327253558C962D3EB6` |
| MorphoVaultsMeta ★ | `0x72a012B30b240458C3f79fd20E5c2A907d77e54f` |
| NexusMutualStakingPoolsAssisted | `0x25Be749999683381703c7346462503a5EFFFd184` |
| NexusMutualVaultsWalletMeta ★ | `0xeA71c3af5127f7fC0F791FE0bFfF9826Ea589060` |
| PolygonStakingMeta | `0x905c04819dd4DB75590663658B7cd635aD67B151` |
| RenzoRestakedEthWalletMeta ★ | `0x9145A559108426e1eA429A2A6441e2A875f069ec` |
| ReserveBasketsWalletMeta ★ | `0x11e68edfBc0449b1c863e11b866B7aF4290F8469` |
| RocketPoolStakedEthWalletMeta ★ | `0x75D1cB3040Dc0322C3f747807360A1Ec03A80eB4` |
| SkySavingsWalletMeta ★ | `0xb967b206445ca58445d09b6CE9878add5Bb14dd4` |
| SparkLend | `0x9ad8dDaAD5166f2f0Fe4e883aFe78902f8BF0CAE` |
| SparkSavingsWalletMeta ★ | `0xd848BE8B5f580C7F8a7f93256DD218cf06CAcd3f` |
| StaderStakedEthWalletMeta ★ | `0x30c6A35827E3dC294f410073C305C8b3f91f1a4a` |
| StaderWithdrawalQueue | `0xCB975897AfA295C8fAEB0C33B333C77B95195094` |
| StakeWiseV3ExitQueueAssisted | `0x83375fDE808F6388c85fC0A1dA86a69492a20798` |
| StakeWiseV3OsTokenWalletMeta ★ | `0x818dD183121641B09752891bB7E971b0FE29e101` |
| StakeWiseV3VaultsMeta | `0xE97bE4B11EE8D65A123dD99bDdec7a4fDcA6359E` |
| SymbioticVaultsMeta ★ | `0x320699dE0693d71C28f5559a68635495AdA0826c` |
| UniswapV3PoolsMeta ☆ | `0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52` |

### Optimism (10)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta ★ | `0xa1b3c695A768A6Ce571fF699F463224CB32260C1` |
| CompoundV3CometsMeta | `0xc4422B74ddb9057fcFc9DB64EF7ce166eD6862CA` |
| LidoStakedEthWalletMeta ★ | `0x7ED4F12798ea3f26AE02a6521eE84702CE5f8f90` |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` |
| UniswapV3PoolsMeta ☆ † | `0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52` |

### Arbitrum (42161)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta ★ | `0xa1b3c695A768A6Ce571fF699F463224CB32260C1` |
| BalancerV3GaugesMeta | `0xDe49FB1096Bb3B2A631183779482441c5505dAf8` |
| BalancerV3PoolsMeta ★ | `0x8AE70624CB7729B0408C8f0ce8ffdac9974FE33A` |
| CompoundV3CometsMeta | `0x84e2a1205e0bB6F4ECe35c5383948c4607eceEB0` |
| EtherFiStakedEthWalletMeta ★ | `0x8a6fde256DD9B262596A22BC4a6c8292Fc3a5D65` |
| FluidFTokensMeta ★ | `0xb1a03cDD28cAA91f409C417C9f56ab53bc9d7ae9` |
| KelpRestakedEthWalletMeta ★ | `0xc0A8E9FA22F28bDE931624c6A454DE649a790273` |
| LidoStakedEthWalletMeta ★ | `0x7ED4F12798ea3f26AE02a6521eE84702CE5f8f90` |
| MapleSavingsWalletMeta ★ | `0xDeE2BcC847DFc113ec70296C5D31e055a6cd902b` |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` |
| MorphoMarketsMeta ☆ | `0xCFf47e28B51a7f4599150f73c348E1a155A93437` |
| MorphoVaultsMeta ★ | `0x72a012B30b240458C3f79fd20E5c2A907d77e54f` |
| RenzoRestakedEthWalletMeta ★ | `0x9145A559108426e1eA429A2A6441e2A875f069ec` |
| UniswapV3PoolsMeta ☆ † | `0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52` |

### Base (8453)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta ★ | `0xa1b3c695A768A6Ce571fF699F463224CB32260C1` |
| BalancerV3GaugesMeta | `0xb9210b8311EA6Cee6cc9D1f8D4c29371fDA23495` |
| BalancerV3PoolsMeta ★ | `0x8AE70624CB7729B0408C8f0ce8ffdac9974FE33A` |
| CoinbaseStakedEthWalletMeta ★ | `0x91d437752463B60103d515c16680d0a17C1c91F9` |
| CompoundV3CometsMeta | `0xcf359A24511f6CEBE19125FE733338FCAe28Fc2E` |
| EtherFiStakedEthWalletMeta ★ | `0x8a6fde256DD9B262596A22BC4a6c8292Fc3a5D65` |
| FluidFTokensMeta ★ | `0xb1a03cDD28cAA91f409C417C9f56ab53bc9d7ae9` |
| LidoStakedEthWalletMeta ★ | `0x7ED4F12798ea3f26AE02a6521eE84702CE5f8f90` |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` |
| MorphoMarketsMeta ☆ | `0x08e590BcFc753fC6383aFE327253558C962D3EB6` |

### Gnosis (100)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta ★ | `0xa1b3c695A768A6Ce571fF699F463224CB32260C1` |
| LidoStakedEthWalletMeta ★ | `0x7ED4F12798ea3f26AE02a6521eE84702CE5f8f90` |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` |
| SkySavingsWalletMeta ★ | `0xb967b206445ca58445d09b6CE9878add5Bb14dd4` |
| StakeWiseV3ExitQueueAssisted | `0xE1e163663961237C0955b665188864f0fD281020` |
| StakeWiseV3OsTokenWalletMeta ★ | `0x818dD183121641B09752891bB7E971b0FE29e101` |
| StakeWiseV3VaultsMeta | `0x04f7a5Faaa9da0a163814e8C30ED7435F159A8eC` |
| UniswapV3PoolsMeta ☆ | `0xaC47D9Cbe8B3EDc9c9d1a6c8092054299bBC1adE` |

### Polygon (137)

| Adapter | Address |
| --- | --- |
| FluidFTokensMeta ★ | `0xb1a03cDD28cAA91f409C417C9f56ab53bc9d7ae9` |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` |
| UniswapV3PoolsMeta ☆ † | `0x2F7e8f78FD8EE977F6D53752b03A79c77012Ba52` |

### BNB Chain (56)

| Adapter | Address |
| --- | --- |
| MerklRewards ☆ | `0xFf2D5A8bf801191eD1292E6DD6792F5D03c5aFBF` |
| MorphoMarketsMeta ☆ † | `0x08e590BcFc753fC6383aFE327253558C962D3EB6` |

### Arc (5042)

| Adapter | Address |
| --- | --- |
| MorphoVaultsMeta ★ | `0x72a012B30b240458C3f79fd20E5c2A907d77e54f` |

## Assisted-adapter assistants (per chain, plain CREATE)

Delegatecall action modules for the assisted adapters. They are **not** registered on the NAV Calculator —
the owner Safe delegatecalls them, so the adapter sees `msg.sender = Safe`. Recorded at the top level of
`script/config/deployments/<chainId>.json`, not under `balanceAdapters`.

### Ethereum (1)

| Assistant | Address |
| --- | --- |
| EtherFiWithdrawalQueueAssistant | `0x03663a1BC7adf766a98421c5C1C1E4E01d45c476` |
| NexusMutualStakingPoolsAssistant | `0xC528664DA4B972cCc6c39649da1388a1e756bf91` |
| StakeWiseV3ExitQueueAssistant | `0x28bA4320CF3936964268C82F198CAB0626b7d1aD` |

### Gnosis (100)

| Assistant | Address |
| --- | --- |
| StakeWiseV3ExitQueueAssistant | `0xB111B929f443Fd48bD40a6e1e4E064a878096B6C` |

## Custom price feeds (per chain)

Plain `CREATE`, so unique per chain — each feed's constructor takes chain-specific token and oracle
addresses. Chains not listed have no custom feeds; their assets use direct feeds registered on the NAV.

### Ethereum (1)

| Token | Feed address |
| --- | --- |
| ETHx | `0x21BAd3b9B08D256639099f6932d93684e1a3C759` |
| ETHxCrossRate | `0x4483406b4cF91FF76d007198392ABb8C9852EEF2` |
| LBTC | `0x91FF9E29C489350a977570adF94f67361f0cE52F` |
| LBTCCrossRateMarket | `0x558eC1E928a5b9cDbb3ae8d254f1A7ee0f760520` |
| LDO | `0x1c876c765e7E0A60Fe6C637B6fef93415e6a60AF` |
| NXM | `0x8D5B6d7aD70a71663a1d7A0552E904b1DDBF1dC3` |
| RWIV | `0x668738cdCA8ab586d5BBA7D0a41441b84B42C4B4` |
| ankrETH | `0x410004373F97fc53145BCD3D72D94BF0BEC69148` |
| eETH | `0xc81C4777a2A6CA69AE42558cB22e821d5114FdAF` |
| ezETH | `0x692b06246bA895D2b7e82c635Cec6F2C3B32302b` |
| ezETHCrossRate | `0x632c5204147c5AacB6E4D859C42A5e9060837EbF` |
| ezETHCrossRateMarket | `0xa52d9675F2d58858AC72f5889f13211CbEF37055` |
| lsETH | `0x746749660345B1EcB570Af44111eb91a5A8e9d45` |
| osETH | `0x6470d36F9daC1e52993FA7690f7561773ca79D6C` |
| osETHCrossRate | `0x34c148a4E8878547E5D4061B5edc0683a0A6DEf4` |
| rETH | `0x28998b0BE5Dc06525FB0d5585Dc7eD7cEa448DF7` |
| rETHCrossRate | `0xd6ceD2c5B2F19Bb6781d1bf8bfB0978e199de2Be` |
| rsETH | `0x39d4D331BbEd4c3Eca4c80f7F674e3268b93b6c3` |
| sDAI | `0x84eDa44d3ab2982692804b153D4bE88A0AfD533C` |
| sGHO | `0x6c258D6B0e7b934cA96e8eA0CF5543FEF045B8c2` |
| sUSDS | `0x1581d5Cecb71fEca102C61572924CC33859714DA` |
| sUSDe | `0x901cBc08fAc7296200cF69F27a904D1d218c8D90` |
| stETHCrossRate | `0xa5Ea631C2100D1B38666aCDDE215bf37b1813B69` |
| stETHFundamental | `0x1F707cA1Ffd99ae3215f223f6a41571e0d3a4F47` |
| spETH | `0x93E408dF0A0BEb203e24163bE513e25ca6EF983B` |
| spUSDC | `0x571cB9069eb2ad434d8A5bB4853602eb6D2a6d43` |
| spUSDT | `0xA41107cb75012A399358482cC850630D9dD8672A` |
| syrupUSDC | `0xB88B09725A2d8c3D05f77d0D4225b5DAE673Dfeb` |
| syrupUSDG | `0x99b00DC4a17eE195a691B9c2281Ea5928e923e41` |
| syrupUSDT | `0xfA25d9C240bA0d43b71672c1E04De882E324cFA9` |
| wARS | `0xbAcb08665c68b5798D6C6138cA02471e7c704931` |
| wNXM | `0x9e032A4536Bd09cF253ec1097d1c4D9540d4273A` |
| weETH | `0x9E435B56E0e210342Db30d30cafeb5855F73c5A4` |
| wstETH | `0x1Da18b841caB327C850854dA964D08F1F0ef7EA6` |

### Arbitrum (42161)

| Token | Feed address |
| --- | --- |
| ezETHCrossRate | `0xCEbB97a1c4aA99EbA63b3885e5BbB76a4893C090` |
| ezETH_L2 | `0xc8FDD6D339864eEd91Ea94f9018439Ff5c98f5EC` |
| rsETHCrossRate | `0x4531e81ce4193071311D0De838412cAfCCc0000C` |
| rsETH_L2 | `0x500b6920248eAFbB2a11Eaa79193A0C5Cd219c5E` |
| syrupUSDC_L2 | `0x925194Ba011f5907943BC1A1CbF7bCaee806aeb5` |
| weETHCrossRate | `0xA99bE398df4eab668585d5eeC5de7c80f4bB634f` |
| weETH_L2 | `0xE641c8cD8e3f7C31C0312b30cB20620bc80749Ef` |
| wstETH_L2 | `0x24ACa7b73dda9f4f6Fbd366f0537b70C491FEe30` |

### Base (8453)

| Token | Feed address |
| --- | --- |
| cbETH_L2 | `0x0E415360A30dFd38aC50EB6F32C27b2A3a181DE1` |
| weETHCrossRate | `0x6b9c230245cf9c149BF133120710E4f74dc38536` |
| weETH_L2 | `0x02C628215643cBa80C96C620cB935eD808AABDDC` |
| wstETH_L2 | `0xD4583b75B09f40E6a39F508afD502249E4bfEb48` |

### Gnosis (100)

| Token | Feed address |
| --- | --- |
| osGNO | `0xd0e852a932490290B5bAACe8DafF04D9ec19c164` |
| sXDAI | `0x513F159f9a2a65fec8AC61d16203450fDC7cA893` |
| wstETH_L2 | `0x2A0Fa71f5923f720c4a622cD4Da0b7837C466612` |

### Arc (5042)

| Token | Feed address |
| --- | --- |
| wARS | `0xC67360B2Cf8d23849ad2b7F3E79AB813D64A94C5` |
