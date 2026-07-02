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
| Ethereum | 1 | full | 24 | 27 |
| Optimism | 10 | full | 0 | 3 |
| Arbitrum | 42161 | full | 5 | 8 |
| Base | 8453 | full | 3 | 7 |
| Gnosis | 100 | full | 3 | 4 |
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

> Assisted adapters (Merkl, ether.fi, StakeWise exit) report `$0` until their off-chain submitter populates the per-account cache.

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
| StaderWithdrawalQueue | `0x98c1C89b34aed91191c447C96fe947782FDF866c` |
| KelpWithdrawalQueue | `0x9CB4DBD309b89cf6BB457AB507e85F56FbbC5C61` |
| LidoWithdrawalQueue | `0xe1C20772f74304cf278AaBe844231A3bD9c35f6E` |
| EthenaCooldown | `0xc9dBccbFb847Dcf41189F77AEd9e60E292789EC8` |
| StakeWiseV3VaultsMeta | `0x1598188996DBB5E3d42Db7f1FaF706Cb6cbdE0B8` |
| MerklRewardsAssisted | `0x0b8c4954ceb7B4795D479801D829Fc1f5F2E7Da7` |
| EtherFiWithdrawalQueueAssisted | `0xa290B8b24e7ed169fB16F9A35d86a5ED01d173D2` |
| NexusMutualStakingPoolsAssisted | `0x8D0237436A4Be679Bf059DCC177e09EA1f6C3094` |
| StakeWiseV3ExitQueueAssisted | `0xa7aCE959c28686c22E239c2Eb8AC79cf7B6FF7e1` |
| UniswapV3PoolsMeta | `0x1eb0Ce47a196D7BE9ba3F2B7ED78299751c80287` |

### Optimism (10)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x3C8469a05676eC07e70274223396fc7c4A4D9ede` |
| CompoundV3CometsMeta | `0x907fB3fC09E3891ab78447ab3C4FF659d87c4a78` |
| MerklRewardsAssisted | `0x12133cA6532cda38510Ae3a6242e36011aD18efB` |

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
| MerklRewardsAssisted | `0xdC1a1d15163aaad6B8f3094ee03b25AF915781f6` |

### Base (8453)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x68984eE23341a8364C12550B028Ebe1A549841F1` |
| CompoundV3CometsMeta | `0x892F7BC61215e684067C2e35E27CA9b312e767fa` |
| MorphoMarketsMeta | `0x92f9C53E620250a30023921FD6c406cfAFcF0ACC` |
| BalancerV3PoolsMeta | `0xA13D70Bbf822e35a28eea8630484739767331038` |
| BalancerV3GaugesMeta | `0xb83a41c655f0cE39366bf7Ce3FC186E30A1a22c5` |
| FluidFTokensMeta | `0x282F02eF700D9112F18b26518C6aB8CD25976A92` |
| MerklRewardsAssisted | `0x9342c17c7fc7FE5BE167a0342745BE6f3e6Efef8` |

### Gnosis (100)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x17f949AfC509E4976C16Cc7e0E5f76390663976F` |
| StakeWiseV3VaultsMeta | `0x8F52EcC9D084CAa0c335373bB54Ee5Dae8BC10E8` |
| MerklRewardsAssisted | `0x9B9d51C2aFCB0e0080509C98CEDd349b54790258` |
| StakeWiseV3ExitQueueAssisted | `0x1BFe0952d4176640b817540cEf9571595962dA42` |

---

## Custom price feeds (per chain, plain CREATE)

### Ethereum (1)

| Token | Feed address |
| --- | --- |
| wstETH | `0xF140B75db6F10ee6276F6d5A2a91c434e72fF7EC` |
| stETH | `0x16fcb0e5Fb44E8cF54D433245a09E2db650458c8` |
| lsETH | `0x0DE789dd1EcBaf1dA7A242b92ad720f92d3618fd` |
| rETH | `0x4137477a27668f636bbFD4F01a67E42e79CA87e7` |
| weETH | `0x105dBd8d772D2e68eAB691e9b635166f0B7A17E9` |
| eETH | `0x5731d36A273DD934E703dd72B617e907879cb193` |
| ezETH | `0x1Eec1612C00057B525F9f342b0dF474370cc7cdd` |
| ezETH (CrossRate) | `0xb9210b8311EA6Cee6cc9D1f8D4c29371fDA23495` |
| rsETH | `0xcf359A24511f6CEBE19125FE733338FCAe28Fc2E` |
| ETHx | `0xB2c4Ed08C1b8D5ee6C2c845D9eF6a10540F6aeDd` |
| ETHx (CrossRate) | `0xb52F84861b2A631f49Fc14e71d1449973b8Bb4f8` |
| osETH | `0x970235365D812812262e1838071D97928f51347f` |
| osETH (CrossRate) | `0x3bdec7EBf6C7bF879a6F1A87875b34EC63e16ea9` |
| sUSDe | `0x9C45400EC105b2AC72F5a5d2CE585aa831E76B09` |
| sUSDS | `0x1e2800893fdD965E0502Ef01D746Ce6838a72842` |
| syrupUSDC | `0x71259BF62FF00f562749101CF00Fb5CcD0714c87` |
| RWIV | `0x4645FdD4A87f3D3D239739DE488e3417030D67A0` |
| sGHO | `0x7788dB1684DB9d19bE2518B78D69DD64B7b9EB80` |
| LDO | `0x796D244b5c8c830B47cA34c30b7F09B142b75f57` |
| OETH | `0x27b92AD567dD21543a60976578481f62b2D37bB0` |
| ankrETH | `0x68dA22D5c021c018B7abdF35fBa79075b6B34282` |
| NXM | `0xedE67f248eED27e871019496992A51a1D5472752` |
| wNXM | `0x7e321cc0436e2DeE1800C7D70E6f5aD56f1263C5` |
| ETHPlus | `0x15007679f32A86Ae1c3C79b04FFb914f03b23f1B` (deployed but **unused** — ETH+ is priced via the Chainlink "Calculated ETH+/USD" feed `0x66Ab900341C98de949EC31d11b3C4180743844F1`) |

### Arbitrum (42161)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0x7c8E265909b232cEe5Ecb94FCEb9794Ae638aFE6` |
| weETH (L2) | `0x3441C0Dac83E0BbaA07855372D18194caD89e5BA` |
| rsETH (L2) | `0xFdDa26b2d434d2EC6899b6766eaD49E6e233A0a5` |
| ezETH (L2) | `0x68984eE23341a8364C12550B028Ebe1A549841F1` |
| syrupUSDC (L2) | `0x892F7BC61215e684067C2e35E27CA9b312e767fa` |

### Base (8453)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0xE15897E48926538De3af6BA84f1B6C0Cb3948473` |
| weETH (L2) | `0x012aA2d97B1989218b7f9Ba2FdFC228a71b86682` |
| cbETH (L2) | `0x94961f712aD4c3C2B0a80f833Cf5A20687c55446` |

### Gnosis (100)

| Token | Feed address |
| --- | --- |
| sXDAI | `0x749E255659C1Db8ED5C12c0C5E88F5da217B53Dd` |
| wstETH (L2) | `0xaA7E7f7F09f2C12b91245e2E761D4f9c62F7Db1d` |
| osGNO | `0x02D6b6613952dB1ae1294C81f443F03195762BBA` |
