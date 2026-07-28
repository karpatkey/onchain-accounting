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
| BridgeEscrow implementation | `0xe2237d9776041514b1AC66856407Ed344b480De0` (dormant) |

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
| wstETH | `0x84e0dF859f9442505eF576C3635B67D719c78ed5` |
| stETH | `0x79d15dfD9223424656f683daC6224B9C59515645` |
| lsETH | `0xffD2E0ef6DAfaefb76634434faAC9D180D58ff59` |
| rETH | `0x44006163F43CaE780D71af73Ffec74b4b6fe1815` |
| rETH (CrossRate) | `0x23D4d7eAdd23f1f1bFBe1f35C64E15B6E9957074` |
| weETH | `0xc37E9eE82eb1920401Db78A3B2D1F518964ccbd4` |
| eETH | `0x5c12cA070F4D472756647a35Eb9B0cF2dD00A09e` |
| ezETH | `0x1e2496c43D1dC5cBb213bc982cf978335590D434` |
| ezETH (CrossRate) | `0x2eBE0e858EC7860dD22E23Dd09765c0dbe5F0560` |
| rsETH | `0xd1cA43E1a9c1aC594F22f12AD1bfb12eeF6ffe8d` |
| ETHx | `0xf4B0a386a39f3e9a67Cebb4Cc8b11383a5b1788a` |
| ETHx (CrossRate) | `0xC11b5dF5B6Ffa9D1c83C1F7267e17Ce261361486` |
| osETH | `0x32dee9b94DA8b25841f009C4419CCeAdb3Dd246B` |
| osETH (CrossRate) | `0x9CD8465223B6a304f41eEBb319Ef4cEACDB2D789` |
| sUSDe | `0x2c488B9f773b29e6c9fb5b2428b79962F01d2051` |
| sUSDS | `0x41792634Def77fB35856b9a3cD9E8087828a7e68` |
| syrupUSDC | `0x550d7555AA2aa40a4e2eaE127cA040E827C80619` |
| RWIV | `0x09295B414600B75F5C173f75d85b924B57D46781` |
| sGHO | `0x7823eD364eBF1Cc7DaD3fc2c99F7BD9Ec19C330c` |
| LDO | `0xbE87B9232113e4c5fdafeb165caf7f2bD208c887` |
| OETH | `0x129637A37f92C6b5961Fc259B5713116c5b65ef5` |
| ankrETH | `0x9480397097D896188C0f93Ef4d4BF7b8D1F24223` |
| NXM | `0xdBdEF36429566A1E1341B1E14633dEe67952Bd95` |
| wNXM | `0x3C99Fec0Fc1D2637a68ca7Aa5eE4A63b854CE3B8` |

### Arbitrum (42161)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0x37e19Bbc036b11FAE7Ce8081B8B03E322469CcCe` |
| weETH (L2) | `0xe3aB5E270193Bc7639527325Cbc2dc6e9fe0495e` |
| weETH (CrossRate) | `0xb728CA2B544BE0BcAE08a1697db08B0D47800C69` |
| rsETH (L2) | `0xf63321f5D995e1581eDeb6fA3CFD0925FcE2d8eA` |
| rsETH (CrossRate) | `0x3E51f7D4B3e2aF63aD9E5C2bE0cA2f72AAB5396B` |
| ezETH (L2) | `0x0710d2dAab1E9AccEE65b66eDed745d3B852898C` |
| ezETH (CrossRate) | `0xeed32CdF2F6a14f7A8E9c2d0C624c397C31CF99E` |
| syrupUSDC (L2) | `0xE444Fd7e8D2C83436cdD3018e1dB235bf2B6813f` |

### Base (8453)

| Token | Feed address |
| --- | --- |
| wstETH (L2) | `0x988153565608688F6f860799FFD47BB92C12d8E2` |
| weETH (L2) | `0x6311E800e42b5085255238E346B475975B0D3b20` |
| weETH (CrossRate) | `0xE1A52191523486968478aEEC81016625BE7b0c5E` |
| cbETH (L2) | `0xAC7a6A184Fb8B4ab31fda742d0090bb7d4d66737` |

### Gnosis (100)

| Token | Feed address |
| --- | --- |
| sXDAI | `0x6837d6a2F1335fffBb6B21b51d24D34F12a02DaA` |
| wstETH (L2) | `0x618207B0650cE45C241760CE0b6E560167EcC1AA` |
| osGNO | `0xAF28F8E8E24B6B23f6BB667f868b9bAFFBEfd8B6` |
