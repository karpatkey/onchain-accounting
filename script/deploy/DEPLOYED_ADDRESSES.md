# Onchain Accounting System (NAV) — Deployed Addresses

Canonical deployed-address reference for the Onchain Accounting System (NAV). The machine source of truth is `script/config/deployments/<chainId>.json` per chain (written by the deploy scripts); this file mirrors those records. The one exception is `UUPSPlaceholder` — a transient CREATE2 address used only during the atomic proxy deploy, identical everywhere and not persisted in the per-chain JSON; it is listed here for completeness.

Deployed across **24 chains**: 5 fully configured (custom price feeds + balance adapters) + 19 with the NAV implementation + proxy only.

- **Roles:** `DEFAULT_ADMIN_ROLE` + `MANAGER` are held by the karpatkey security-council Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` on every chain (granted by `07_TransferAdminToSecurityCouncil`).
- **Bridge:** deployed-but-dormant — only the `BridgeEscrow` implementation is deployed (no proxy, adapters, or wiring).
- **Polygon zkEVM is intentionally excluded** — the network is being sunset by Polygon, so the system is not deployed there.

---

## Canonical layer (CREATE2 — identical on every chain)

Deployed via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), so each address is the same on all 24 chains.

| Contract | Address |
| --- | --- |
| **NAVCalculator proxy** | `0x42aC265991163Af2b0B9E59a222d31d201E39f91` — the address every consumer should call |
| NAVCalculator implementation | `0x875b878d38f13F81ab344FBAC43f1DE2eB7b79A2` |
| PriceFeedLib | `0xD13245D3382b86aa0964eF838e1BC2Ac8754A900` |
| NAVRegistryLib | `0x549f6fB0EC34E18A82A320b79C968a9Ca6e7b96b` |
| ERC20Default balance adapter | `0xB9b4C2fCA8C09ea6268e4e1158b84C6550385909` (created inside `NAVCalculator.initialize`; identical everywhere) |
| UUPSPlaceholder | `0x85Ee38b0385D042918a59C01dB319b6eDdF7A8Cf` (temporary impl during atomic proxy deploy) |
| BridgeEscrow implementation | `0xe2237d9776041514b1AC66856407Ed344b480De0` (dormant) |

> **Deployments-JSON keys** (for `jq` lookups in `script/config/deployments/<chainId>.json`): `NAVCalculatorProxy`, `NAVCalculatorImplementation`, `PriceFeedLib`, `NavRegistryLib` (mixed case — deliberate, to keep the library's CREATE2 salt stable), `BridgeEscrowImplementation`; the default adapter is at `.balanceAdapters.ERC20Default`.

---

## Chains (24)

| Chain | Chain ID | Scope | Custom price feeds | Balance adapters (excl. ERC20Default) |
| --- | --- | --- | --- | --- |
| Ethereum | 1 | full | 24 | 26 |
| Optimism | 10 | full | 0 | 2 |
| Arbitrum | 42161 | full | 5 | 7 |
| Base | 8453 | full | 3 | 6 |
| Gnosis | 100 | full | 3 | 3 |
| BSC | 56 | impl + proxy | — | — |
| Polygon | 137 | impl + proxy | — | — |
| Berachain | 80094 | impl + proxy | — | — |
| HyperEVM | 999 | impl + proxy | — | — |
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

The 19 impl+proxy chains run the canonical layer only; custom price feeds and balance adapters are registered as assets land on each. HyperEVM required its big-blocks mode for the implementation deploy.

---

## Balance adapters (per chain, plain CREATE)

> Assisted adapters (ether.fi, StakeWise exit) report `$0` until their off-chain submitter populates the per-account cache.

### Ethereum (1)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x59F9676D8B589a449C818cA63D2b48cAA975D049` |
| CompoundV3CometsMeta | `0xbfe4b2fCcB9AC0f2610354B6Fb837cF3CD27ccdE` |
| SparkLend | `0x1a963867dFF9270Dc9a34Bbd1B8E1Cdc8Ea560d2` |
| AaveV3SafetyModule | `0xC4939734b5B532c6373D317017a749a6c0c90DB5` |
| AaveUmbrella | `0x6e5BeBc726CdA556dc956a8D06d81247b1fbC797` |
| Cap | `0x80adD8f89bDf5D4c1F1eD9952e51C567E4EB3430` |
| MorphoVaultsMeta | `0xDe49FB1096Bb3B2A631183779482441c5505dAf8` |
| MorphoMarketsMeta | `0x034f278E15BCBb56793EDA32C0032AD3c1cf63F6` |
| EulerVaultsMeta | `0xfC21CE9965b9750262b9DF180a2115db16b4F023` |
| GearboxV3MarketsMeta | `0xD301d0a41eF61cE0111242AB0B41A4599f7c9864` |
| BalancerV3PoolsMeta | `0x3CD89267db5bEF78268647bBBb41A9DB7403474E` |
| BalancerV3GaugesMeta | `0x00DF7d31e36b53D156A73068851d7AF3C6545F7F` |
| CurvePoolsMeta | `0xAE48D64D045ea56557e4Af12a7564e727ae1E080` |
| CurveGaugesMeta | `0xE69a3fC77e40e74872D31973A477520ad20e000c` |
| ConvexCurveLPStakingMeta | `0x823FCF30B4a76A75DE402af08c0C9D04bBfBe95F` |
| FluidFTokensMeta | `0xaCBE56d6d844fC62d3bF2cd0FAa911853916D434` |
| FluidVaultsMeta | `0xEb7eDaE4bdEb9170F722B312a8D64104E1F0aD45` |
| StaderWithdrawalQueue | `0xe43BdCeb764971b1CEd97dA8612815DaEF23E423` |
| KelpWithdrawalQueue | `0x56c246DA9dAACE268D8B4583aF20d2E9957be8c1` |
| LidoWithdrawalQueue | `0x6147A0220C790e6B5294fFE9AD6B27bc1AA2F674` |
| EthenaCooldown | `0xc9dBccbFb847Dcf41189F77AEd9e60E292789EC8` |
| StakeWiseV3VaultsMeta | `0x1598188996DBB5E3d42Db7f1FaF706Cb6cbdE0B8` |
| EtherFiWithdrawalQueueAssisted | `0xb0a8A75618925e0A53EE820529Ad1A2F6a18bF12` |
| NexusMutualStakingPoolsAssisted | `0xB73b3a6B65B1465D305870F7933aF8CC140d3C0B` |
| StakeWiseV3ExitQueueAssisted | `0xb9A7A8ac57383969703f67f61d48fa7142640815` |
| UniswapV3PoolsMeta | `0x1eb0Ce47a196D7BE9ba3F2B7ED78299751c80287` |

### Optimism (10)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x3C8469a05676eC07e70274223396fc7c4A4D9ede` |
| CompoundV3CometsMeta | `0x907fB3fC09E3891ab78447ab3C4FF659d87c4a78` |

### Arbitrum (42161)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x04c13a4c7ca6350fE006A6784822012b09d0361F` |
| CompoundV3CometsMeta | `0xDf311222BFbb8f2bb1572Ff08e96936C3D22418B` |
| MorphoVaultsMeta | `0x5ed372f3AC1f3039608180792cafFCACf000E11c` |
| MorphoMarketsMeta | `0x3bA6936Ff18a6d04Bc98A03d9f657A46cBEb9a07` |
| BalancerV3PoolsMeta | `0xe0Bd18970d051310871a1bE19E9457692573a55C` |
| BalancerV3GaugesMeta | `0x89352Ad9Fa6f35d127c0Fc26300A2Cb55e50E625` |
| FluidFTokensMeta | `0xBD9C499907f69dD2d5C90D7FFD55f9748B59A04a` |

### Base (8453)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x68984eE23341a8364C12550B028Ebe1A549841F1` |
| CompoundV3CometsMeta | `0x892F7BC61215e684067C2e35E27CA9b312e767fa` |
| MorphoMarketsMeta | `0x92f9C53E620250a30023921FD6c406cfAFcF0ACC` |
| BalancerV3PoolsMeta | `0xA13D70Bbf822e35a28eea8630484739767331038` |
| BalancerV3GaugesMeta | `0xb83a41c655f0cE39366bf7Ce3FC186E30A1a22c5` |
| FluidFTokensMeta | `0x282F02eF700D9112F18b26518C6aB8CD25976A92` |

### Gnosis (100)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x17f949AfC509E4976C16Cc7e0E5f76390663976F` |
| StakeWiseV3VaultsMeta | `0x8F52EcC9D084CAa0c335373bB54Ee5Dae8BC10E8` |
| StakeWiseV3ExitQueueAssisted | `0xE333a72EB00A937b6BE4e77dD10141C64C06DEE8` |

---

## Custom price feeds (per chain, plain CREATE)

### Ethereum (1)

| Token | Feed address |
| --- | --- |
| wstETH | `0x6e139FF9D134376ec0C2899C12A1fFB4b327d284` |
| stETH | `0x33C29376fbf93AEc8223EefE93c322227F02C7b5` |
| lsETH | `0x4128a0Bf149FE6750a02410Cc73814A544AD0961` |
| rETH | `0x421E3a5F4a7D6f7623C07e6Bde73f573fBb4Bffd` |
| weETH | `0x37752a1902Be34066DCDC22572Bb2496Bd1136eB` |
| eETH | `0xDE5C22e16e0CB686D5C1F07E2C0a971DfcCC9aeF` |
| ezETH | `0xa4A6b844afD83b323BeBB79529f0bc14630E033d` |
| ezETH (CrossRate) | `0x40CFD8f5A145b5dAfF7c96882031Ac03a9536F5B` |
| rsETH | `0x1021f43B502524d5e4e0f68bA284771996E0F25C` |
| ETHx | `0x8CaCa3F3408721f096C9739eda6C44A44AE205c9` |
| ETHx (CrossRate) | `0x4CdAB97d28F097b5a66E91CC76bd4846B5Ce4ABd` |
| osETH | `0x082ae9f59fBeDc58d0189dB7F2E6DC78569dc448` |
| osETH (CrossRate) | `0x92cf99A78ce9B7A0BBa7cE7724CF4Cdf9A6d4F31` |
| sUSDe | `0xbB07683cf459B85C39Ef71A264Af6311d9C9813c` |
| sUSDS | `0x734ae4e728f958d21BeF9a4c558b712520c62854` |
| syrupUSDC | `0xdC2bE878c68A0064270eaB33a823bF72B06f9F2C` |
| RWIV | `0xcF68c23c31566784CfB177C9FcF7D447307d78c3` |
| sGHO | `0x4912f95141EEE9c29C48417c912BFEC1621E1b5F` |
| LDO | `0x4780A24F9b425ba9Aa2a56CEf6e3fEA04A46cFA9` |
| OETH | `0x9b384F5A0731cc441657F149c406e324de03dE8B` |
| ankrETH | `0x243432a1938dF7378Ba26e801DA12D48D6b19C6b` |
| NXM | `0xc9b96D0e1d6544F34cE292f74C9C14A5C514d599` |
| wNXM | `0xbe6943b50F0bCD56CB938533fbCC1eaED8D7bCbb` |
| ETHPlus | `0x15007679f32A86Ae1c3C79b04FFb914f03b23f1B` (deployed but **unused** — ETH+ is priced via the Chainlink "Calculated ETH+/USD" feed `0x66Ab900341C98de949EC31d11b3C4180743844F1`) |

### Arbitrum (42161)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0xAb5A2dB56e6608De7FE12a447B26d349a10fb037` |
| weETH (L2) | `0x52d718a68b4f385da5C67BE94d42851777F22e85` |
| rsETH (L2) | `0x9C2eA278A490284D775BDd7899972a35e86f9713` |
| ezETH (L2) | `0x305bdB829066C9cE15d5A2aF0c4267B326C8a1cF` |
| syrupUSDC (L2) | `0x1aee401c41bAE2a02aE39d9c969De44dbD8ca449` |

### Base (8453)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0x89352Ad9Fa6f35d127c0Fc26300A2Cb55e50E625` |
| weETH (L2) | `0xBD9C499907f69dD2d5C90D7FFD55f9748B59A04a` |
| cbETH (L2) | `0xdC1a1d15163aaad6B8f3094ee03b25AF915781f6` |

### Gnosis (100)

| Token | Feed address |
| --- | --- |
| sXDAI | `0x1872D803592919443b4A151e6128F276f589101E` |
| wstETH (L2) | `0x95CCee1E490Ad10e4Ea04769b6Bc6d463b16128F` |
| osGNO | `0xD480a2d0a9c91C3049915F3c6EF15D25fB978141` |
