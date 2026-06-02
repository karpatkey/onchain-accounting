# NAV v2 — Production Deployment Addresses

All addresses listed below were deployed on 2026-04-29 / 2026-04-30 as part of the production rollout tracked in [PR #15](https://github.com/karpatkey/onchain-accounting/pull/15). Each address is linked to its respective block-explorer page.

> **Post-PR #47 migration note (June 2026):** The balance adapter architecture was refactored to use
> **meta-adapters** (ADR 0010). Per-instance adapters listed below (e.g. `AaveV3_Core`,
> `MorphoVault_*`, `Convex_*`) remain at their deployed addresses but are now **disabled** in the
> chain configs (`"enabled": false`) and superseded by meta-adapters (`AaveV3InstancesMeta`,
> `MorphoVaultsMeta`, etc.). The new meta-adapters have `"deployed": ""` in chain config and are
> **pending deployment** in the next production deploy session. Until then, the disabled per-instance
> adapters continue to report positions correctly if manually re-enabled.

Source of truth: `script/config/chains/{chainId}.json` per chain. Per-tx broadcast logs live in `broadcast/<script>/<chainId>/run-latest.json`.

---

## Common (CREATE2 — same address on every chain)

These contracts have identical bytecode + constructor input on every chain, so CREATE2 places them at the same address everywhere.

| Component | Address | Notes |
|---|---|---|
| NAVCalculator implementation (salt v2) | `0xc572dd1F36E50E9b9551838df8916Ac81200af62` | UUPS impl, immutable post-deploy. |
| NAVCalculator proxy (salt v3) | `0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19` | UUPS proxy, points at the impl above. The address every consumer should use. |
| ERC20Default balance oracle | `0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39` | Auto-deployed inside `NAVCalculator.initialize()`. Reports wallet balances for every registered ERC20 + the native sentinel. |
| `UUPSPlaceholder` impl (salt v3) | `0xE8CfE5bCD2dC7e8cBF5eF2B5cf8bD8EE259A4953` | Used during atomic deploy as the temporary impl before `upgradeToAndCall(navImpl, initialize(...))`. Holds no state, no role. |

---

## Roles (final state on every NAV proxy, after Phase 6 handoff)

| Role | Holder | Type |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://app.safe.global/home?safe=eth:0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) | Safe (5/N threshold, same address on all 5 chains) |
| `MANAGER` | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://app.safe.global/home?safe=eth:0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) | Safe |
| Deployer EOA (post-handoff) | `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` | EOA — holds **no** privileged role on any NAV proxy. |

---

## Ethereum Mainnet (chainId `1`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | [`0xc572dd1F36E50E9b9551838df8916Ac81200af62`](https://etherscan.io/address/0xc572dd1F36E50E9b9551838df8916Ac81200af62) |
| NAVCalculator proxy | [`0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19`](https://etherscan.io/address/0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19) |
| ERC20Default balance oracle | [`0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39`](https://etherscan.io/address/0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39) |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://etherscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (9)

| Adapter | Address |
|---|---|
| `eETH` | [`0x9C2eA278A490284D775BDd7899972a35e86f9713`](https://etherscan.io/address/0x9C2eA278A490284D775BDd7899972a35e86f9713) |
| `ezETH` | [`0x305bdB829066C9cE15d5A2aF0c4267B326C8a1cF`](https://etherscan.io/address/0x305bdB829066C9cE15d5A2aF0c4267B326C8a1cF) |
| `rETH` | [`0x99690D21EB64cA7941e974691455Be41D558441B`](https://etherscan.io/address/0x99690D21EB64cA7941e974691455Be41D558441B) |
| `rsETH` | [`0x52d718a68b4f385da5C67BE94d42851777F22e85`](https://etherscan.io/address/0x52d718a68b4f385da5C67BE94d42851777F22e85) |
| `sUSDS` | [`0x76752e33050f2011cAcd3edBbB8125eE1e49C140`](https://etherscan.io/address/0x76752e33050f2011cAcd3edBbB8125eE1e49C140) |
| `sUSDe` | [`0xDE04bb0a8fd927C137547401F30213FCc7607D63`](https://etherscan.io/address/0xDE04bb0a8fd927C137547401F30213FCc7607D63) |
| `syrupUSDC` | [`0xc73Ed3f07e2d1d6C59294936C12048daE2b8CbE7`](https://etherscan.io/address/0xc73Ed3f07e2d1d6C59294936C12048daE2b8CbE7) |
| `weETH` | [`0xAb5A2dB56e6608De7FE12a447B26d349a10fb037`](https://etherscan.io/address/0xAb5A2dB56e6608De7FE12a447B26d349a10fb037) |
| `wstETH` | [`0xc3E04720338BC8AddC335764914b7602DD11e79f`](https://etherscan.io/address/0xc3E04720338BC8AddC335764914b7602DD11e79f) |

**Balance adapters** (35 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3SafetyModule_stkGHO` | [`0x191d6b8EdD19167e90419347d586081E2B01D8dD`](https://etherscan.io/address/0x191d6b8EdD19167e90419347d586081E2B01D8dD) |
| `AaveV3_Core` | [`0x1aee401c41bAE2a02aE39d9c969De44dbD8ca449`](https://etherscan.io/address/0x1aee401c41bAE2a02aE39d9c969De44dbD8ca449) |
| `AaveV3_Prime` | [`0x14b1E2E6577f49C6242533119452c3CA092fC9B1`](https://etherscan.io/address/0x14b1E2E6577f49C6242533119452c3CA092fC9B1) |
| `Aura_GHO_USDT_USDC` | [`0x76bB2C593A4b1081DA59899A579Adf815f52Bbac`](https://etherscan.io/address/0x76bB2C593A4b1081DA59899A579Adf815f52Bbac) |
| `Aura_rETH_WETH` | [`0x45006c280bF3dC44D7D370C9a801c95eC501aA3E`](https://etherscan.io/address/0x45006c280bF3dC44D7D370C9a801c95eC501aA3E) |
| `BalancerV3_GHO_USDT_USDC` | [`0x380f9912a659D7AFd1C9b5f88f62c06b4309FA80`](https://etherscan.io/address/0x380f9912a659D7AFd1C9b5f88f62c06b4309FA80) |
| `BalancerV3_rETH_WETH` | [`0x854BC9A5445495396De4cc228A5f945C680c2d4A`](https://etherscan.io/address/0x854BC9A5445495396De4cc228A5f945C680c2d4A) |
| `Cap` | [`0xb812cc304Cb417B635470681160e75CfFb0006b0`](https://etherscan.io/address/0xb812cc304Cb417B635470681160e75CfFb0006b0) |
| `Convex_RLUSD_USDC` | [`0xB1297920Da8e204Aa8E34D60AD56fdfe07000905`](https://etherscan.io/address/0xB1297920Da8e204Aa8E34D60AD56fdfe07000905) |
| `Convex_crvUSD_USDC` | [`0x5F598A4B588766c41b0dE5A93B91E03f00C60A77`](https://etherscan.io/address/0x5F598A4B588766c41b0dE5A93B91E03f00C60A77) |
| `Convex_crvUSD_USDT` | [`0x69BCa825DDCd25394BBF3DA313ece4e63642898d`](https://etherscan.io/address/0x69BCa825DDCd25394BBF3DA313ece4e63642898d) |
| `Convex_weETH_WETH` | [`0x0c2582167fB2c636eBa3b63fff1c4b186E643956`](https://etherscan.io/address/0x0c2582167fB2c636eBa3b63fff1c4b186E643956) |
| `Curve_RLUSD_USDC` | [`0x18dddd49116deB8ed90fdD7a2236a06F83127dd5`](https://etherscan.io/address/0x18dddd49116deB8ed90fdD7a2236a06F83127dd5) |
| `Curve_crvUSD_USDC` | [`0x9eFcd3aE461a4F5769365B25673053FB08cc76B9`](https://etherscan.io/address/0x9eFcd3aE461a4F5769365B25673053FB08cc76B9) |
| `Curve_crvUSD_USDT` | [`0xf49CE162a6aD084a2e71C1Bf3ced3eC8fDAa16cc`](https://etherscan.io/address/0xf49CE162a6aD084a2e71C1Bf3ced3eC8fDAa16cc) |
| `Curve_weETH_WETH` | [`0xAF8A9F7b37925973615Eaa787AefA3f388D32101`](https://etherscan.io/address/0xAF8A9F7b37925973615Eaa787AefA3f388D32101) |
| `GearboxMarket_kpkWETH` | [`0x04E39d917E0D515384B3C027658a8b2f401ECEb0`](https://etherscan.io/address/0x04E39d917E0D515384B3C027658a8b2f401ECEb0) |
| `GearboxMarket_kpkwstETH` | [`0x5a81F5574c165a7b231E2F6c2B89AF3dE3D4E941`](https://etherscan.io/address/0x5a81F5574c165a7b231E2F6c2B89AF3dE3D4E941) |
| `MorphoMarket_ETHPlus_USDC` | [`0x3F7182ED9ab40fbBa43a53b9468cd3DE2C0957c2`](https://etherscan.io/address/0x3F7182ED9ab40fbBa43a53b9468cd3DE2C0957c2) |
| `MorphoMarket_ETHPlus_WETH` | [`0x618207B0650cE45C241760CE0b6E560167EcC1AA`](https://etherscan.io/address/0x618207B0650cE45C241760CE0b6E560167EcC1AA) |
| `MorphoMarket_RLP_USDC` | [`0x9970D0D8932051d21883C854fC42eb67a54348FF`](https://etherscan.io/address/0x9970D0D8932051d21883C854fC42eb67a54348FF) |
| `MorphoMarket_WBTC_USDC` | [`0xe1CE19c8C668cD3659f2AE64E2C9D078c71Ef8F6`](https://etherscan.io/address/0xe1CE19c8C668cD3659f2AE64E2C9D078c71Ef8F6) |
| `MorphoMarket_cbBTC_USDC` | [`0x8b0F047127D58692C869033a551872c4Fe55e758`](https://etherscan.io/address/0x8b0F047127D58692C869033a551872c4Fe55e758) |
| `MorphoMarket_rsETH_WETH` | [`0xEDDbc540eD724aB3cC95B1C419c6f9D6348a373b`](https://etherscan.io/address/0xEDDbc540eD724aB3cC95B1C419c6f9D6348a373b) |
| `MorphoMarket_sUSDS_USDT` | [`0x6837d6a2F1335fffBb6B21b51d24D34F12a02DaA`](https://etherscan.io/address/0x6837d6a2F1335fffBb6B21b51d24D34F12a02DaA) |
| `MorphoMarket_syrupUSDC_USDC` | [`0x7A7e9F5562C0126fb2bCC2f29D1098b60A452431`](https://etherscan.io/address/0x7A7e9F5562C0126fb2bCC2f29D1098b60A452431) |
| `MorphoMarket_weETH_WETH` | [`0x537E83dc59b2Ee2C7bD46B2f4801c5DF3B3f8aD1`](https://etherscan.io/address/0x537E83dc59b2Ee2C7bD46B2f4801c5DF3B3f8aD1) |
| `MorphoMarket_wstETH_USDC` | [`0x4A68C3dA533fF7527CD67390f80d87ca6a95551d`](https://etherscan.io/address/0x4A68C3dA533fF7527CD67390f80d87ca6a95551d) |
| `MorphoMarket_wstETH_WETH` | [`0xAF28F8E8E24B6B23f6BB667f868b9bAFFBEfd8B6`](https://etherscan.io/address/0xAF28F8E8E24B6B23f6BB667f868b9bAFFBEfd8B6) |
| `MorphoMarket_wstUSR_USDC` | [`0xD03D46409Cb95DcE7F9eBBa0cBDfA480758D8d42`](https://etherscan.io/address/0xD03D46409Cb95DcE7F9eBBa0cBDfA480758D8d42) |
| `MorphoVault_kpkETHPrime_V1` | [`0x4d9E4f4Ebd360d5a557bE59459FcDcFFF1892FA7`](https://etherscan.io/address/0x4d9E4f4Ebd360d5a557bE59459FcDcFFF1892FA7) |
| `MorphoVault_kpkETHPrime_V2` | [`0x6fC390Bcc0f83fb7E16c0eA54743b321143d0512`](https://etherscan.io/address/0x6fC390Bcc0f83fb7E16c0eA54743b321143d0512) |
| `MorphoVault_kpkUSDCPrime_V1` | [`0x07978693C01f70373e89d196DfcfcA18a6C02d6C`](https://etherscan.io/address/0x07978693C01f70373e89d196DfcfcA18a6C02d6C) |
| `MorphoVault_kpkUSDCPrime_V2` | [`0xBF19e8568cbA837d3922a987f9E001787385575f`](https://etherscan.io/address/0xBF19e8568cbA837d3922a987f9E001787385575f) |
| `SparkLend` | [`0x9b9e74cfd807Dfae4F9333Afbd44EFE719354c39`](https://etherscan.io/address/0x9b9e74cfd807Dfae4F9333Afbd44EFE719354c39) |

---

## Arbitrum One (chainId `42161`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | [`0xc572dd1F36E50E9b9551838df8916Ac81200af62`](https://arbiscan.io/address/0xc572dd1F36E50E9b9551838df8916Ac81200af62) |
| NAVCalculator proxy | [`0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19`](https://arbiscan.io/address/0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19) |
| ERC20Default balance oracle | [`0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39`](https://arbiscan.io/address/0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39) |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://arbiscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (5)

| Adapter | Address |
|---|---|
| `ezETH_L2` | [`0x286Ae1f0Ee0BE577acE2F087ad98c2F3C71ddDb0`](https://arbiscan.io/address/0x286Ae1f0Ee0BE577acE2F087ad98c2F3C71ddDb0) |
| `rsETH_L2` | [`0x8d5Cb8F0C1DAa3fd45Aeb8Af220AF74F621fe8c0`](https://arbiscan.io/address/0x8d5Cb8F0C1DAa3fd45Aeb8Af220AF74F621fe8c0) |
| `syrupUSDC_L2` | [`0xE35e9caF8d91d45372f3FA40bda073bD81FeDA09`](https://arbiscan.io/address/0xE35e9caF8d91d45372f3FA40bda073bD81FeDA09) |
| `weETH_L2` | [`0xD38f98F51778C4E7eaD36ade9E2594fF91d49c2f`](https://arbiscan.io/address/0xD38f98F51778C4E7eaD36ade9E2594fF91d49c2f) |
| `wstETH_L2` | [`0xDdBb3444421a4c4F142fE9544bf7Cd404663745e`](https://arbiscan.io/address/0xDdBb3444421a4c4F142fE9544bf7Cd404663745e) |

**Balance adapters** (6 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Arbitrum` | [`0x503514123e25696304E82beb393DEEb72729a550`](https://arbiscan.io/address/0x503514123e25696304E82beb393DEEb72729a550) |
| `Aura_GHO_USDC_USDT` | [`0xF0163C3CabFA53c613B94fb2b95313Ecc1964892`](https://arbiscan.io/address/0xF0163C3CabFA53c613B94fb2b95313Ecc1964892) |
| `BalancerV3_GHO_USDC_USDT` | [`0x70AC1F4ddbD431Dd022f70f759F06a470663DeeB`](https://arbiscan.io/address/0x70AC1F4ddbD431Dd022f70f759F06a470663DeeB) |
| `MorphoMarket_sUSDS_USDC` | [`0xd6dFb63356C38d14ee4e48dCF31D2eA98b15990d`](https://arbiscan.io/address/0xd6dFb63356C38d14ee4e48dCF31D2eA98b15990d) |
| `MorphoMarket_syrupUSDC_USDC` | [`0xE4785f2A6590C589Ea36ba59A1Eb57A1FdC0e74e`](https://arbiscan.io/address/0xE4785f2A6590C589Ea36ba59A1Eb57A1FdC0e74e) |
| `MorphoVault_kpkUSDCYieldV1` | [`0x77f1E73A81189C8e67C997aBF908E8f7aB20447F`](https://arbiscan.io/address/0x77f1E73A81189C8e67C997aBF908E8f7aB20447F) |

---

## Base (chainId `8453`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | [`0xc572dd1F36E50E9b9551838df8916Ac81200af62`](https://basescan.org/address/0xc572dd1F36E50E9b9551838df8916Ac81200af62) |
| NAVCalculator proxy | [`0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19`](https://basescan.org/address/0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19) |
| ERC20Default balance oracle | [`0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39`](https://basescan.org/address/0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39) |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://basescan.org/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (3)

| Adapter | Address |
|---|---|
| `cbETH_L2` | [`0xf48B71F3a234EEd583a4B1b883e02FeEa505841F`](https://basescan.org/address/0xf48B71F3a234EEd583a4B1b883e02FeEa505841F) |
| `weETH_L2` | [`0xfCdaC9e666D65b63D38f1E20c05FA199Ab6ad55E`](https://basescan.org/address/0xfCdaC9e666D65b63D38f1E20c05FA199Ab6ad55E) |
| `wstETH_L2` | [`0x009E7D763b4F7Ded74C7f6B6aB329c25aE481477`](https://basescan.org/address/0x009E7D763b4F7Ded74C7f6B6aB329c25aE481477) |

**Balance adapters** (7 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Base` | [`0xbf7d1dd7aedE0841f563584E39cA8b69F4Ca29B1`](https://basescan.org/address/0xbf7d1dd7aedE0841f563584E39cA8b69F4Ca29B1) |
| `Aura_GHO_USDC` | [`0x286Ae1f0Ee0BE577acE2F087ad98c2F3C71ddDb0`](https://basescan.org/address/0x286Ae1f0Ee0BE577acE2F087ad98c2F3C71ddDb0) |
| `BalancerV3_GHO_USDC` | [`0x8d5Cb8F0C1DAa3fd45Aeb8Af220AF74F621fe8c0`](https://basescan.org/address/0x8d5Cb8F0C1DAa3fd45Aeb8Af220AF74F621fe8c0) |
| `MorphoMarket_cbBTC_USDC` | [`0x2F77a41C17C7cAb30cc320112b649ab8B070617E`](https://basescan.org/address/0x2F77a41C17C7cAb30cc320112b649ab8B070617E) |
| `MorphoMarket_cbETH_USDC` | [`0xD38f98F51778C4E7eaD36ade9E2594fF91d49c2f`](https://basescan.org/address/0xD38f98F51778C4E7eaD36ade9E2594fF91d49c2f) |
| `MorphoMarket_weETH_WETH` | [`0xDdBb3444421a4c4F142fE9544bf7Cd404663745e`](https://basescan.org/address/0xDdBb3444421a4c4F142fE9544bf7Cd404663745e) |
| `MorphoMarket_wstETH_WETH` | [`0xd96Af38c9685B724b9C7e0646D7Ea19e13402867`](https://basescan.org/address/0xd96Af38c9685B724b9C7e0646D7Ea19e13402867) |

---

## OP Mainnet (chainId `10`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | [`0xc572dd1F36E50E9b9551838df8916Ac81200af62`](https://optimistic.etherscan.io/address/0xc572dd1F36E50E9b9551838df8916Ac81200af62) |
| NAVCalculator proxy | [`0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19`](https://optimistic.etherscan.io/address/0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19) |
| ERC20Default balance oracle | [`0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39`](https://optimistic.etherscan.io/address/0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39) |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://optimistic.etherscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters**

None — this chain uses Chainlink price feeds exclusively for Alpha-fund assets.

**Balance adapters** (1 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Optimism` | [`0xa6AA9bFC2257347C7c7041Ac1037410C55f4C806`](https://optimistic.etherscan.io/address/0xa6AA9bFC2257347C7c7041Ac1037410C55f4C806) |

---

## Gnosis Chain (chainId `100`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | [`0xc572dd1F36E50E9b9551838df8916Ac81200af62`](https://gnosisscan.io/address/0xc572dd1F36E50E9b9551838df8916Ac81200af62) |
| NAVCalculator proxy | [`0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19`](https://gnosisscan.io/address/0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19) |
| ERC20Default balance oracle | [`0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39`](https://gnosisscan.io/address/0x081DDcf1b94c7a037DAaA690f3b8687ADa64dC39) |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://gnosisscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (2)

| Adapter | Address |
|---|---|
| `sXDAI` | [`0xeFD0F9a25CE259979C68206BeC8d9Ec20FB5c6F5`](https://gnosisscan.io/address/0xeFD0F9a25CE259979C68206BeC8d9Ec20FB5c6F5) |
| `wstETH_L2` | [`0x17A50CCeCCD6E168Fcea22A3B5830a2cB389E557`](https://gnosisscan.io/address/0x17A50CCeCCD6E168Fcea22A3B5830a2cB389E557) |

**Balance adapters** (1 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Gnosis` | [`0xcFdAC8a9EA51f8dd598FbeaBFe3D4fCBAf61DBAa`](https://gnosisscan.io/address/0xcFdAC8a9EA51f8dd598FbeaBFe3D4fCBAf61DBAa) |

---

## Per-chain deploy commits in PR #15

| Chain | Commit |
|---|---|
| Gnosis (100) | [`f47d2e7`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/f47d2e7) |
| Optimism (10) | [`99ab2a3`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/99ab2a3) |
| Base (8453) | [`f7ad578`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/f7ad578) |
| Arbitrum (42161) | [`5a91b46`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/5a91b46) |
| Mainnet (1) | [`181900a`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/181900a) |
