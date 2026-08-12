# Onchain Accounting System (NAV) — Deployed Addresses

Canonical deployed-address reference for the Onchain Accounting System (NAV). The machine source of truth is `script/config/deployments/<chainId>.json` per chain (written by the deploy scripts); this file mirrors those records. The one exception is `UUPSPlaceholder` — a transient CREATE2 address used only during the atomic proxy deploy, identical everywhere and not persisted in the per-chain JSON; it is listed here for completeness.

Deployed across **24 chains**: 7 fully configured (custom price feeds + balance adapters) + 17 with the NAV implementation + proxy only.

- **Roles (current):** the deployer EOA `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` holds `DEFAULT_ADMIN_ROLE` + `MANAGER` on every chain. Handoff to the karpatkey security-council Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` (via `07_TransferAdminToSecurityCouncil`) is **deferred** until the operational handover — step 07 has not been run.
- **Bridge:** deployed-but-dormant — only the `BridgeEscrow` implementation is deployed (no proxy, adapters, or wiring).
- **Polygon zkEVM is intentionally excluded** — the network is being sunset by Polygon, so the system is not deployed there.

---

## Canonical layer (CREATE2 — identical on every chain)

Deployed via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), so each address is the same on all 24 chains.

| Contract | Address |
| --- | --- |
| **NAVCalculator proxy** | `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d` — the address every consumer should call |
| NAVCalculator implementation | `0x07bd077cFB40bBDa8A67d0D33ce41b974aB0F8a8` (ADR 0020; supersedes `0x1D3F6905FfAf2A776bD4D7Cfb821c4AAC75F06F6`) |
| PriceFeedLib | `0x450421a334DE63F75e1d47399d9713f755aaEfF2` (ADR 0020; supersedes `0x4041cC1C7Ffd69531B660acB7Bb9Fd1faa8d2e2B`) |
| NAVRegistryLib | `0x549f6fB0EC34E18A82A320b79C968a9Ca6e7b96b` |
| ERC20Default balance adapter | `0x41967559D0a20Ad102F6e27b7723b1963390aD75` (created inside `NAVCalculator.initialize`; identical everywhere) |
| UUPSPlaceholder | `0x85Ee38b0385D042918a59C01dB319b6eDdF7A8Cf` (temporary impl during atomic proxy deploy) |
| BridgeEscrow implementation | `0xe2237d9776041514b1AC66856407Ed344b480De0` (dormant; recorded on 23 chains — no record on HyperEVM (999)) |

> **Deployments-JSON keys** (for `jq` lookups in `script/config/deployments/<chainId>.json`): `NAVCalculatorProxy`, `NAVCalculatorImplementation`, `PriceFeedLib`, `NavRegistryLib` (mixed case — deliberate, to keep the library's CREATE2 salt stable), `BridgeEscrowImplementation`; the default adapter is at `.balanceAdapters.ERC20Default`.

---

## Chains (24)

| Chain | Chain ID | Scope | Custom price feeds | Balance adapters (excl. ERC20Default) |
| --- | --- | --- | --- | --- |
| Ethereum | 1 | full | 24 | 26 |
| Optimism | 10 | full | 0 | 2 |
| Arbitrum | 42161 | full | 8 | 7 |
| Base | 8453 | full | 4 | 6 |
| Gnosis | 100 | full | 3 | 3 |
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

The 17 impl+proxy chains run the canonical layer only; custom price feeds and balance adapters are registered as assets land on each.

---

## Balance adapters (per chain, plain CREATE)

> Assisted adapters (ether.fi, Nexus Mutual, StakeWise exit) report `$0` until the owner Safe delegatecalls the matching assistant (see [Assisted-adapter assistants](#assisted-adapter-assistants-per-chain-plain-create)) to populate the per-account coordinate cache.

### Ethereum (1)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x587Cf4f63b7E740BeC6b639DCB1FF7f641DD961A` |
| CompoundV3CometsMeta | `0x4a90DD3047e58cc2Ebf70a41F3d03c654FEB3F90` |
| SparkLend | `0xf22e3c516daf2463AcF3b1545aAD4565a18e2c9F` |
| AaveV3SafetyModule | `0x103f3EdeF6AcdF58256C9b5026f01a4dCd16d52f` |
| AaveUmbrella | `0x94910a2E35b8749529Dc9555Ed1599cd77E045bF` |
| Cap | `0x5B50A5FF1C80A178bB8da9fdfF077FBc3DD4e543` |
| MorphoVaultsMeta | `0x9C1eDecf558361a7b8A6E4D8F30E7B5Bf21F1d28` |
| MorphoMarketsMeta | `0xffe862626a408F8bBF3449A96D640f4bcC0c0053` |
| EulerVaultsMeta | `0x647F9c2715C665a65da1BD911d41F644B8957714` |
| GearboxV3MarketsMeta | `0x1cE2C056C2b1aCFe26aA0553B5767831c755a011` |
| BalancerV3PoolsMeta | `0xf6EB4692532FD540F2921E2746A218d819EA2069` |
| BalancerV3GaugesMeta | `0xdFeCC458e3afF31895D6780d89Fd70DF0eaBC2BA` |
| CurvePoolsMeta | `0x6aAf0164AE7f7945420C31E5fa0e92F16C38a579` |
| CurveGaugesMeta | `0xD09Ad6DA81562009a333059C52BFaCcA45364C55` |
| ConvexCurveLPStakingMeta | `0xaaa6Fff0d7a1576C006A00287e56FeFC03C5C15e` |
| FluidFTokensMeta | `0x678BE00a7530Aad2C944b76aaa43ef46C6213dA9` |
| FluidVaultsMeta | `0xa80305f86C4F7f35B7F55a4876F0B0f110AeE761` |
| StaderWithdrawalQueue | `0xC5dC98BC974CC70010be2Fc3784D1ffF5f354014` |
| KelpWithdrawalQueue | `0x7A02230b0b79e930C021E9874b330bCb486dc32B` |
| LidoWithdrawalQueue | `0x80FDC8B965E2a1Cf3274E126A287036f21a09E03` |
| EthenaCooldown | `0x3a1490aaf0fa98B890F73A5BD436c65cEe9Dcb95` |
| StakeWiseV3VaultsMeta | `0xa42c97f51DdD2A74C637775cCAc18Dc37fe6c607` |
| EtherFiWithdrawalQueueAssisted | `0xdCF0E047257A785d7A7Cd31d4A63eB6318aFba03` |
| NexusMutualStakingPoolsAssisted | `0x9b3ee866e030f9cfDA181e7ffd9BB0A49606ef0E` |
| StakeWiseV3ExitQueueAssisted | `0xcb97dA2c799cfc17463704EDb1caAd451c28A861` |
| UniswapV3PoolsMeta | `0x45CB28C78e5178699517734863c988022b312071` |

### Optimism (10)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0xDf311222BFbb8f2bb1572Ff08e96936C3D22418B` |
| CompoundV3CometsMeta | `0x5ed372f3AC1f3039608180792cafFCACf000E11c` |

### Arbitrum (42161)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x34EA399D2fCfb70e3780229acb9a1B87Df50AC54` |
| CompoundV3CometsMeta | `0x4595A7d745299031363D5EB92f7DCe170a7F31D6` |
| MorphoVaultsMeta | `0x36e8819832fDA41F978448e67Ef1930705C32011` |
| MorphoMarketsMeta | `0xbC671d4af513B2A1d7967830AE96E82E9de4234e` |
| BalancerV3PoolsMeta | `0xE2AC3842Ed574fDCC6e3581f92Fa40b7196F0b3d` |
| BalancerV3GaugesMeta | `0xaAB3BbDEcCDe6800c33FEbB49Ce81a1cBB46dfdE` |
| FluidFTokensMeta | `0xDFA04A339046B8fAA45bc3E2535904B067863cdB` |

### Base (8453)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0xE682B511E4D2Ef7C6Ef40337ddfCeB29079F363C` |
| CompoundV3CometsMeta | `0x8E6F4175aA32fae1976ed7B1D50f4443a1654e6d` |
| MorphoMarketsMeta | `0xb81F966528605FC81d5b5d23D086504ED02f1F6A` |
| BalancerV3PoolsMeta | `0xD28cB431688fBe03013e0bB23dE493e105630f45` |
| BalancerV3GaugesMeta | `0x8cbAFEC5745AF6727b7be0829e507f58b3b3ce0d` |
| FluidFTokensMeta | `0xE1e163663961237C0955b665188864f0fD281020` |

### Gnosis (100)

| Adapter | Address |
| --- | --- |
| AaveV3InstancesMeta | `0x537E83dc59b2Ee2C7bD46B2f4801c5DF3B3f8aD1` |
| StakeWiseV3VaultsMeta | `0xEDDbc540eD724aB3cC95B1C419c6f9D6348a373b` |
| StakeWiseV3ExitQueueAssisted | `0x04E39d917E0D515384B3C027658a8b2f401ECEb0` |

### Polygon (137)

| Adapter | Address |
| --- | --- |
| FluidFTokensMeta | `0x2182Ec30EFF0f213c6662E5b45D6799ff7de5793` |

---

## Assisted-adapter assistants (per chain, plain CREATE)

> Stateless delegatecall helpers — one per assisted adapter — that the owner Safe `delegatecall`s to feed the adapter's per-account coordinate cache (a direct call reverts `NotDelegateCall`). Deployed by `04_DeployBalanceAdapters` alongside their adapters.

### Ethereum (1)

| Assistant | Address |
| --- | --- |
| EtherFiWithdrawalQueueAssistant | `0xd45cB5B6791156f657D682b3c70689980f4fe8D5` |
| NexusMutualStakingPoolsAssistant | `0x8a887C7Fa17dbba626497024833778354785c580` |
| StakeWiseV3ExitQueueAssistant | `0x13845Fc9DFfDf1AFb8B1Cf22eA298C01C8d7F71B` |

### Gnosis (100)

| Assistant | Address |
| --- | --- |
| StakeWiseV3ExitQueueAssistant | `0xEb43828383320802dc78dCC1DEFB1f39051c6607` |

---

## Custom price feeds (per chain, plain CREATE)

### Ethereum (1)

| Token | Feed address |
| --- | --- |
| wstETH | `0x4bD901001Bf32B6AB522859A0ea00Cf9007C2C02` |
| stETH | `0x11a357DcDF5630ACef657D838c00953819CEa38D` |
| lsETH | `0x5692d68882197B3975a22be25115a51a6d771Ef9` |
| rETH | `0xBfb05bD1d9A9b0b86661708920281d1a20B34751` |
| rETH (CrossRate) | `0x09cd6a20ddD9DB835ceb60154c1B9a41Af79f8C8` |
| weETH | `0xC41711ED9Bf44fc072c1F7D9aDecDedb830cC4bB` |
| eETH | `0x758dCC8a419f82d1D48Ca30F3C8878B69e35a33a` |
| ezETH | `0x3BA87ED5C3Fbc2deE8F909a777D1F3c2360B777E` |
| ezETH (CrossRate) | `0x41918B7d85aAEa56FC1b8f14A632211b3ddeCBF1` |
| rsETH | `0xf24347fdf8797C210F40E52f604e36c7a2474d71` |
| ETHx | `0x2714149d8DAa1A71Daf48843c12A7fcf773a7811` |
| ETHx (CrossRate) | `0xE9b348d0c0Aa97da22FB1D2e171cEC0415cc2742` |
| osETH | `0xFcC11A91F87c2507E00520e843827689895C91F0` |
| osETH (CrossRate) | `0xfD6CeB9E6eE4D8Ff9Da2f21617A496595B50C3F2` |
| sUSDe | `0x6Ac6D52fa049b3e13b6eB4ebD073558666F7eE79` |
| sUSDS | `0x3F4421D004fab23ced494DB37b23Ff829b2B63fa` |
| syrupUSDC | `0x32b558072759F26792e890a531334Db42025F7DF` |
| RWIV | `0x01147052bCc24Ff24a1758eD30B343e80ABE19Fd` |
| sGHO | `0x7030835F6Eb93f3fDfC7A54b89e3cFe9478F5149` |
| LDO | `0x16B1607457D0aA6DD6cd6Bd7980d126DE6479580` |
| OETH *(RETIRED — see note below)* | `0xE59C72C9DdAA728010F92e8Df8d2c6ac0DfF57Bc` |
| ankrETH | `0x237657576a422a1ab3f4A82834574b5ed2ea8687` |

> **`OETH` is a RETIRED FEED at a LIVE ADDRESS — the row above is kept deliberately.** The contract is
> still deployed at `0xE59C72C9DdAA728010F92e8Df8d2c6ac0DfF57Bc` and will stay there; this file and
> `deployments/<id>.json` record what IS deployed, not what is in service, so deleting the row would
> leave the repo unable to recognise its own address in a trace, an explorer view or an old NAV read.
> What was removed is INTENT: OETH is gone from `nav-config/assets-and-price-feeds/1.json` and from
> `contracts-deployment-config/custom-price-feeds/1.json`, because Chainlink is sunsetting the
> `OETH/ETH` rate feed `0x703118C4CbccCBF2AB31913e0f8075fbbb15f563` that this `CrossRateCustomPriceFeed`
> consumes as its `RATE_FEED`. **We hold no OETH, so this is a planned retirement and not an incident.**
>
> **Expected after the redeploy:** `03_DeployPriceFeeds` is config-gated, so it will not redeploy this
> feed. Its record therefore keeps the OLD address, whose immutable `NAV()` still points at the OLD
> proxy — so `bytecode_audit.py` will report `STALE_NAV` for it (`bytecode_audit.py:254`). That is
> correct behaviour on a correct state, not an anomaly. A `retiredCustomPriceFeeds` section that removes
> the need to remember this is planned as a follow-up, deliberately deferred until #300 lands because it
> is rewriting which sections of `deployments/<id>.json` are expected.

| NXM | `0xF0D44e332395762f5A93271DcA0De587B10703CC` |
| wNXM | `0x11382AbB9FF238a4f4E7fAc9CCe084F038aab78f` |

### Arbitrum (42161)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0xA6f5fcC13199d6bbf1363EFdb10AE4e7d85D59EF` |
| weETH (L2) | `0xBEF120B82415F113F8997Ff1C17360c678359187` |
| weETH (CrossRate) | `0xF044b3C75DA32b3D5C6e31a911E420CBC97A546a` |
| rsETH (L2) | `0x8b9f7493100fbd1D2B70f873cE270c586D49FE45` |
| rsETH (CrossRate) | `0xC499c86acC30FE11B9309B4Df9011bc74fD6374a` |
| ezETH (L2) | `0xC3b09C9a8B7c7bCe3442c22A834069dF737713Ad` |
| ezETH (CrossRate) | `0xf6ca4D2761b575630ee77DeBCc423D25C0eB7109` |
| syrupUSDC (L2) | `0x6E23b1f1447c95E50e06c0F40C64F3f7ff717Eea` |

### Base (8453)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0x13735cb0BDB3E62efFff3C08eB07e374D02a43e4` |
| weETH (L2) | `0x0e8f43219139018987bF73Dc7e47326e934fd6F1` |
| weETH (CrossRate) | `0xDa36cdd5Df99152124d4fFecF2560173c0aFA3c4` |
| cbETH (L2) | `0xfD47E87fd39aCCE5E42eCC41e75011990eB84F8C` |

### Gnosis (100)

| Token | Feed address |
| --- | --- |
| sXDAI | `0xD4c941d3Fe951d4df2fc1022a55A172639e3fECc` |
| wstETH (L2) | `0x953C750BDeFa4E1Ca7F00422131a037f91D8F1d3` |
| osGNO | `0xa801150C79932d4bE5c318821cCd1a4279528518` |
