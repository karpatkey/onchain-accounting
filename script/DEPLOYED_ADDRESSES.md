# Onchain Accounting System — Production Deployment Addresses

> **Deployed 2026-06-26** — fresh full redeploy across all 5 production chains (new bytecode / new
> address generation). Every contract below is **deployed and explorer-verified**. The previous
> deployment generation is superseded; consumers (the OIV / share layer and anything referencing the
> NAVCalculator) must repoint to the proxy address below.
>
> **Roles:** `DEFAULT_ADMIN_ROLE` + `MANAGER` are currently held by the **deployer EOA**
> `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` on every chain. The
> `07_TransferAdminToSecurityCouncil` handoff to the security-council Safe is **intentionally deferred**
> and will run later. **Bridge is out of scope** — no `BridgeEscrow` is deployed. **BSC (56) / Polygon (137)
> are not deployed.**

**Source of truth:** `script/config/deployments/<chainId>.json` per chain (`.customPriceFeeds`,
`.balanceAdapters`, and the canonical impl/proxy/library entries), written by the deploy scripts. This
file mirrors that, grouped for humans, and is kept in sync with the Notion "Onchain Accounting System
Deployment" reference. Per-tx broadcast logs are not committed.

---

## Common (CREATE2 — same address on every chain)

Identical bytecode + constructor input on all chains, so the canonical CREATE2 deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`) places these at the same address everywhere.

| Component | Address | Notes |
|---|---|---|
| **NAVCalculator proxy** | `0x29fD97910baf7E9502B5a561F0c04Cf2555535c4` | UUPS proxy — **the address every consumer should use.** |
| NAVCalculator implementation | `0x5E65f6b4d3bAb60fd943E12Cb9Bd680Ed07A72A7` | UUPS impl, immutable post-deploy. |
| `PriceFeedLib` | `0x66642d5E374dc87B858955B236F720c2E7368a3f` | External library (pinned in `foundry.toml`). |
| `NAVRegistryLib` | `0x2F1F6c17D64bE96F583D390be212aFCF8D0F102a` | External library (pinned in `foundry.toml`). |
| `ERC20Default` balance adapter | `0x06400f2AAe00692Bf71b3BCb7E26D74adf9749cC` | Auto-deployed inside `NAVCalculator.initialize()`. Reports wallet balances for every registered ERC20 + the native sentinel. Plain adapter (default wallet adapter). |
| `UUPSPlaceholder` impl | `0x85Ee38b0385D042918a59C01dB319b6eDdF7A8Cf` | Temporary impl during atomic deploy before `upgradeToAndCall`. Holds no state, no role. |
| `BridgeEscrow` | *not deployed — out of scope* | |

---

## Roles (current, on every NAV proxy)

| Role | Holder | Type |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` | Deployer EOA (handoff deferred) |
| `MANAGER` | `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` | Deployer EOA (handoff deferred) |
| Security-council Safe (future admin) | `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` | Safe — **does not yet hold any role**; receives both via `07_TransferAdminToSecurityCouncil` later. |

---

## Ethereum Mainnet (chainId `1`)

**Custom price feeds (20)**

| Asset | Adapter address |
|---|---|
| LDO | `0xeBa2177dD069a3BCa2D6bea3085a702d9a1C47dC` |
| sUSDS | `0x81229DC207eAe57A2e2906b567945c81d91f2270` |
| sUSDe | `0xED743692fDdb75e44066d4be1ec72529B592F4B2` |
| syrupUSDC | `0x8Eb858292487A49fA2791EE0BF7355f608DeEF5d` |
| RWIV | `0xFD4da0AAa9A8416fAF564E76200D64c2eF7fE7aa` |
| wstETH | `0x37e19Bbc036b11FAE7Ce8081B8B03E322469CcCe` |
| stETH | `0xe3aB5E270193Bc7639527325Cbc2dc6e9fe0495e` |
| lsETH | `0xf63321f5D995e1581eDeb6fA3CFD0925FcE2d8eA` |
| rETH | `0x0710d2dAab1E9AccEE65b66eDed745d3B852898C` |
| weETH | `0xE444Fd7e8D2C83436cdD3018e1dB235bf2B6813f` |
| rsETH | `0xb728CA2B544BE0BcAE08a1697db08B0D47800C69` |
| eETH | `0xeed32CdF2F6a14f7A8E9c2d0C624c397C31CF99E` |
| ezETH | `0x3E51f7D4B3e2aF63aD9E5C2bE0cA2f72AAB5396B` |
| ETHx | `0x34EA399D2fCfb70e3780229acb9a1B87Df50AC54` |
| ETH+ (`ETHPlus`) | `0x4595A7d745299031363D5EB92f7DCe170a7F31D6` |
| osETH | `0x36e8819832fDA41F978448e67Ef1930705C32011` |
| OETH | `0xbC671d4af513B2A1d7967830AE96E82E9de4234e` |
| ankrETH | `0xE2AC3842Ed574fDCC6e3581f92Fa40b7196F0b3d` |
| NXM | `0xaAB3BbDEcCDe6800c33FEbB49Ce81a1cBB46dfdE` |
| wNXM | `0xDFA04A339046B8fAA45bc3E2535904B067863cdB` |

**Balance adapters — plain (14, incl. canonical ERC20Default)**

| Adapter | Address |
|---|---|
| ERC20Default | `0x06400f2AAe00692Bf71b3BCb7E26D74adf9749cC` |
| SparkLend | `0xF044b3C75DA32b3D5C6e31a911E420CBC97A546a` |
| AaveV3SafetyModule | `0xf6ca4D2761b575630ee77DeBCc423D25C0eB7109` |
| AaveUmbrella | `0xC499c86acC30FE11B9309B4Df9011bc74fD6374a` |
| Cap | `0x356C0FaFBF187D0aE2b125dB55e0627f9a552f70` |
| ERC4626Wrap_waEthLidoGHO | `0xA996288b8B70744d51CAC8b72fE5f751db92430D` |
| ERC4626Wrap_sGHO | `0x2A52578a516b5A20bDd365d4C5789a94849BD577` |
| StaderWithdrawalQueue | `0x20661Eb4116fA0a8196133feEE661383B180598D` |
| KelpWithdrawalQueue | `0x18737d37D0E18F6d44aC703Bdeda16c3940c5f7e` |
| LidoWithdrawalQueue | `0x496E0781C1A33C880e1A17D8D5345b187fe2CbF6` |
| EthenaCooldown | `0x21b11f9f18430ec50fF73DD2dC0e72eCa482fd38` |
| EtherFiWithdrawals | `0x6692a76b7fd10D22546e875E77DDE10c88b6b637` |
| NexusStakedNxm | `0xde4F9Bd6500A170CAd20fF9b0E4D5F7A4f388468` |
| StakeWiseExitQueue | `0x1062709c03Ae060f1491fa4D170E3562d6114046` |

> EtherFiWithdrawals + StakeWiseExitQueue are ADR-0014 agent-fed cache adapters — they report `$0`
> until the off-chain submitter bots populate their per-account request caches.

**Meta balance adapters (17)**

| Meta adapter | Address |
|---|---|
| AaveV3InstancesMeta | `0x8b9f7493100fbd1D2B70f873cE270c586D49FE45` |
| AaveV2InstancesMeta | `0xC3b09C9a8B7c7bCe3442c22A834069dF737713Ad` |
| CompoundV3CometsMeta | `0x6E23b1f1447c95E50e06c0F40C64F3f7ff717Eea` |
| MorphoVaultsMeta | `0x4761ab7B70bF30c9Ee138f1f41522Fb6D69B4579` |
| MorphoMarketsMeta | `0x814EC09B98191F3b1eF09b1f92c29F803255755a` |
| EulerVaultsMeta | `0xa188ad0aB0F3C77AC2D3F75B5F92E0751A62Fe7d` |
| GearboxMarketsMeta | `0x86ea82a47f8A5A2c8d6bBf8e557c7B1061355388` |
| BalancerV3PoolsMeta | `0xCBF901B2796055C11C871017B1146130D40627c6` |
| BalancerV3GaugesMeta | `0xe1B2585595523052A477bc2C7b0197fAb758F9f3` |
| AuraRewardsMeta | `0xeBdFCA4230B5b1D54478Bb1f08a5447590FdaDFe` |
| CurvePoolsMeta | `0x7C9Ec6B1F253349887f5d43890C8Db0B4B93Bc25` |
| CurveGaugesMeta | `0x708aCF7b393bE46FFC5A1Bb8a1aB1583bbDd7F70` |
| ConvexRewardsMeta | `0x833D990f86e438Eb359B2Cc689551f891deF1f81` |
| FluidFTokensMeta | `0xdc8D67A1b5b1233634ceFf550bF5edEE3D71ad0b` |
| FluidVaultsMeta | `0x8B6EE0BB357A07D2d0e3D29901826d9FF7C7a25C` |
| StakeWiseV3VaultsMeta | `0xD17FB5854616a810fB5dfe5C6348Cd12aE46603A` |
| UniswapV3PoolsMeta | `0x1B14531Cc63730d28F46183Fe2f437Db5500B3c6` |

---

## Optimism (chainId `10`)

**Custom price feeds:** none.

**Balance adapters — plain (1)**

| Adapter | Address |
|---|---|
| ERC20Default | `0x06400f2AAe00692Bf71b3BCb7E26D74adf9749cC` |

**Meta balance adapters (2)**

| Meta adapter | Address |
|---|---|
| AaveV3InstancesMeta | `0x286Ae1f0Ee0BE577acE2F087ad98c2F3C71ddDb0` |
| CompoundV3CometsMeta | `0xE35e9caF8d91d45372f3FA40bda073bD81FeDA09` |

---

## Gnosis (chainId `100`)

**Custom price feeds (3)**

| Asset | Adapter address |
|---|---|
| sXDAI | `0x170651f7834062cb6C00d4590970f6b4C8793d45` |
| wstETH (L2) | `0x83F09987a81cC24497f8811ADC14573C54EAcD27` |
| osGNO | `0x7E6366A015e7C72d238E0E289e1652eaa06f962E` |

**Balance adapters — plain (1)**

| Adapter | Address |
|---|---|
| ERC20Default | `0x06400f2AAe00692Bf71b3BCb7E26D74adf9749cC` |

**Meta balance adapters (2)**

| Meta adapter | Address |
|---|---|
| AaveV3InstancesMeta | `0xfa4500641C2004600d6547cADfD3DcAC5529D9fe` |
| StakeWiseV3VaultsMeta | `0x75aB0a3cd3E42cb1da6a908FA935CD8beBeAACd3` |

---

## Arbitrum (chainId `42161`)

**Custom price feeds (5)**

| Asset | Adapter address |
|---|---|
| wstETH (L2) | `0xaA7E7f7F09f2C12b91245e2E761D4f9c62F7Db1d` |
| weETH (L2) | `0x02D6b6613952dB1ae1294C81f443F03195762BBA` |
| rsETH (L2) | `0xCd8c62D7AbB46dc57e4a56BF9704B69A93BD0480` |
| ezETH (L2) | `0x1e5dF3037180015fad132f01317eDa09C899FE48` |
| syrupUSDC (L2) | `0xF01acf7989fc3707C241A0eDe32A94f67F3b69c5` |

**Balance adapters — plain (1)**

| Adapter | Address |
|---|---|
| ERC20Default | `0x06400f2AAe00692Bf71b3BCb7E26D74adf9749cC` |

**Meta balance adapters (8)**

| Meta adapter | Address |
|---|---|
| AaveV3InstancesMeta | `0x66F252d40E56bb088D02b9E1DDbBfCA1F690e439` |
| CompoundV3CometsMeta | `0x39b6c6aEb0B641c71153De0cF6727032d7A95dC7` |
| MorphoVaultsMeta | `0xE333a72EB00A937b6BE4e77dD10141C64C06DEE8` |
| MorphoMarketsMeta | `0xEb43828383320802dc78dCC1DEFB1f39051c6607` |
| BalancerV3PoolsMeta | `0xcab1bBcA974A0ceF02A1941A482876046e928a21` |
| BalancerV3GaugesMeta | `0xE15897E48926538De3af6BA84f1B6C0Cb3948473` |
| AuraRewardsMeta | `0x012aA2d97B1989218b7f9Ba2FdFC228a71b86682` |
| FluidFTokensMeta | `0x94961f712aD4c3C2B0a80f833Cf5A20687c55446` |

---

## Base (chainId `8453`)

**Custom price feeds (3)**

| Asset | Adapter address |
|---|---|
| wstETH (L2) | `0xc5c8843f4B18EB31B579a13153968400d1c4438a` |
| weETH (L2) | `0xDfbC64C95D848E0e1345aaFAa6460c4656F4dfbF` |
| cbETH (L2) | `0xA6850560aBd2ae34Bd5fcb259D50740366433Aa1` |

**Balance adapters — plain (1)**

| Adapter | Address |
|---|---|
| ERC20Default | `0x06400f2AAe00692Bf71b3BCb7E26D74adf9749cC` |

**Meta balance adapters (7)**

| Meta adapter | Address |
|---|---|
| AaveV3InstancesMeta | `0x9b93CD2199457ff3250CbA23C3C0EdCf569B7e13` |
| CompoundV3CometsMeta | `0xfB07Dd93424dff6A07AABb2BaaE24f3d42f0bD17` |
| MorphoMarketsMeta | `0x5911300C7E1e42B77d80C7E11Bd47E5Fbe20B6b5` |
| BalancerV3PoolsMeta | `0x55CA69ED98F01dB32523A59E699cC036DCC501C4` |
| BalancerV3GaugesMeta | `0xB6Ab1DB3eaC03490C3936B499CA2441Ec92C50cf` |
| AuraRewardsMeta | `0x59A27458b2a73Cab477a2BcaC56f833c441C5983` |
| FluidFTokensMeta | `0xE76553acAf6C68Bc6c5360041c98893d3F0c4ACF` |

> `PancakeSwapV3PoolsMeta` is intentionally **not deployed** on Base (disabled in config — tied to the
> deferred COW price feed).

---

## Intentional deferrals (not gaps)

- **COW** price feed — on hold (≈$6.7M COW-denominated across wallet / Sablier / LPs). `PancakeSwapV3PoolsMeta`
  (Base) and the Sablier adapter are left disabled pending the COW-feed decision.
- **kUSD / kETH** fund-share pricing — [ADR 0013](../docs/decisions/0013-kusd-keth-oiv-share-pricing.md)
  on hold (likely an external Chainlink cross-chain-NAV oracle).
- **`07` security-council handoff** — deferred; roles remain on the deployer EOA until then.
