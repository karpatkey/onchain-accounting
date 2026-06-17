# NAV v2 — Production Deployment Addresses

> **Redeploy in progress (June 2026):** NAV v2 is being redeployed from scratch with new bytecode.
> Every deployed-contract address below is therefore `TBD` pending the redeploy — including the
> "Common (CREATE2)" entries, since the bytecode change moves even those addresses. The governance
> Safe (`DEFAULT_ADMIN_ROLE` / `MANAGER`) and the deployer EOA are unchanged and persist across the
> redeploy. This file is now a clean post-wipe registry/template; addresses will be filled back in as
> each chain is redeployed.

> **Meta-adapter migration note (June 2026):** The per-instance → meta-adapter migration tracked after
> PR #47 is now moot — everything is being redeployed fresh under the new meta-adapter + renamed-API
> architecture (PRs #65 / #69). There are no longer any per-instance adapters "remaining at their
> deployed addresses"; the full set is redeployed clean.

Source of truth for deployed addresses: `script/config/deployments/{chainId}.json` per chain, written by the deploy scripts. Per-tx broadcast logs are no longer committed.

---

## Common (CREATE2 — same address on every chain)

These contracts have identical bytecode + constructor input on every chain, so CREATE2 places them at the same address everywhere.

| Component | Address | Notes |
|---|---|---|
| NAVCalculator implementation (salt v2) | `TBD` | UUPS impl, immutable post-deploy. |
| NAVCalculator proxy (salt v3) | `TBD` | UUPS proxy, points at the impl above. The address every consumer should use. |
| ERC20Default balance adapter | `TBD` | Auto-deployed inside `NAVCalculator.initialize()`. Reports wallet balances for every registered ERC20 + the native sentinel. |
| `UUPSPlaceholder` impl (salt v3) | `TBD` | Used during atomic deploy as the temporary impl before `upgradeToAndCall(navImpl, initialize(...))`. Holds no state, no role. |

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
| NAVCalculator implementation | `TBD` |
| NAVCalculator proxy | `TBD` |
| ERC20Default balance adapter | `TBD` |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://etherscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (9)

| Adapter | Address |
|---|---|
| `eETH` | `TBD` |
| `ezETH` | `TBD` |
| `rETH` | `TBD` |
| `rsETH` | `TBD` |
| `sUSDS` | `TBD` |
| `sUSDe` | `TBD` |
| `syrupUSDC` | `TBD` |
| `weETH` | `TBD` |
| `wstETH` | `TBD` |

**Balance adapters** (35 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3SafetyModule_stkGHO` | `TBD` |
| `AaveV3_Core` | `TBD` |
| `AaveV3_Prime` | `TBD` |
| `Aura_GHO_USDT_USDC` | `TBD` |
| `Aura_rETH_WETH` | `TBD` |
| `BalancerV3_GHO_USDT_USDC` | `TBD` |
| `BalancerV3_rETH_WETH` | `TBD` |
| `Cap` | `TBD` |
| `Convex_RLUSD_USDC` | `TBD` |
| `Convex_crvUSD_USDC` | `TBD` |
| `Convex_crvUSD_USDT` | `TBD` |
| `Convex_weETH_WETH` | `TBD` |
| `Curve_RLUSD_USDC` | `TBD` |
| `Curve_crvUSD_USDC` | `TBD` |
| `Curve_crvUSD_USDT` | `TBD` |
| `Curve_weETH_WETH` | `TBD` |
| `GearboxMarket_kpkWETH` | `TBD` |
| `GearboxMarket_kpkwstETH` | `TBD` |
| `MorphoMarket_ETHPlus_USDC` | `TBD` |
| `MorphoMarket_ETHPlus_WETH` | `TBD` |
| `MorphoMarket_RLP_USDC` | `TBD` |
| `MorphoMarket_WBTC_USDC` | `TBD` |
| `MorphoMarket_cbBTC_USDC` | `TBD` |
| `MorphoMarket_rsETH_WETH` | `TBD` |
| `MorphoMarket_sUSDS_USDT` | `TBD` |
| `MorphoMarket_syrupUSDC_USDC` | `TBD` |
| `MorphoMarket_weETH_WETH` | `TBD` |
| `MorphoMarket_wstETH_USDC` | `TBD` |
| `MorphoMarket_wstETH_WETH` | `TBD` |
| `MorphoMarket_wstUSR_USDC` | `TBD` |
| `MorphoVault_kpkETHPrime_V1` | `TBD` |
| `MorphoVault_kpkETHPrime_V2` | `TBD` |
| `MorphoVault_kpkUSDCPrime_V1` | `TBD` |
| `MorphoVault_kpkUSDCPrime_V2` | `TBD` |
| `SparkLend` | `TBD` |

---

## Arbitrum One (chainId `42161`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | `TBD` |
| NAVCalculator proxy | `TBD` |
| ERC20Default balance adapter | `TBD` |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://arbiscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (5)

| Adapter | Address |
|---|---|
| `ezETH_L2` | `TBD` |
| `rsETH_L2` | `TBD` |
| `syrupUSDC_L2` | `TBD` |
| `weETH_L2` | `TBD` |
| `wstETH_L2` | `TBD` |

**Balance adapters** (6 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Arbitrum` | `TBD` |
| `Aura_GHO_USDC_USDT` | `TBD` |
| `BalancerV3_GHO_USDC_USDT` | `TBD` |
| `MorphoMarket_sUSDS_USDC` | `TBD` |
| `MorphoMarket_syrupUSDC_USDC` | `TBD` |
| `MorphoVault_kpkUSDCYieldV1` | `TBD` |

---

## Base (chainId `8453`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | `TBD` |
| NAVCalculator proxy | `TBD` |
| ERC20Default balance adapter | `TBD` |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://basescan.org/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (3)

| Adapter | Address |
|---|---|
| `cbETH_L2` | `TBD` |
| `weETH_L2` | `TBD` |
| `wstETH_L2` | `TBD` |

**Balance adapters** (7 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Base` | `TBD` |
| `Aura_GHO_USDC` | `TBD` |
| `BalancerV3_GHO_USDC` | `TBD` |
| `MorphoMarket_cbBTC_USDC` | `TBD` |
| `MorphoMarket_cbETH_USDC` | `TBD` |
| `MorphoMarket_weETH_WETH` | `TBD` |
| `MorphoMarket_wstETH_WETH` | `TBD` |

---

## OP Mainnet (chainId `10`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | `TBD` |
| NAVCalculator proxy | `TBD` |
| ERC20Default balance adapter | `TBD` |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://optimistic.etherscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters**

None — this chain uses Chainlink price feeds exclusively for Alpha-fund assets.

**Balance adapters** (1 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Optimism` | `TBD` |

---

## Gnosis Chain (chainId `100`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | `TBD` |
| NAVCalculator proxy | `TBD` |
| ERC20Default balance adapter | `TBD` |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://gnosisscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (2)

| Adapter | Address |
|---|---|
| `sXDAI` | `TBD` |
| `wstETH_L2` | `TBD` |

**Balance adapters** (1 excluding ERC20Default)

| Adapter | Address |
|---|---|
| `AaveV3_Gnosis` | `TBD` |

---

## Per-chain deploy commits in PR #15

| Chain | Commit |
|---|---|
| Gnosis (100) | [`f47d2e7`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/f47d2e7) |
| Optimism (10) | [`99ab2a3`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/99ab2a3) |
| Base (8453) | [`f7ad578`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/f7ad578) |
| Arbitrum (42161) | [`5a91b46`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/5a91b46) |
| Mainnet (1) | [`181900a`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/181900a) |
