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
| ERC20Default balance adapter | `TBD` | Auto-deployed inside `NAVCalculator.initialize()` via `NAVRegistryLib.deployDefaultAdapter` (plain CREATE from the proxy, not CREATE2 — but identical across chains because the proxy address and its deploy nonce match everywhere). Reports wallet balances for every registered ERC20 + the native sentinel. |
| `UUPSPlaceholder` impl (salt v3) | `TBD` | Used during atomic deploy as the temporary impl before `upgradeToAndCall(navImpl, initialize(...))`. Holds no state, no role. |

---

## Roles (final state on every NAV proxy, after the `07_TransferAdminToSecurityCouncil` handoff)

| Role | Holder | Type |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://app.safe.global/home?safe=eth:0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) | Safe (multisig, same address on all 5 chains) |
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

**Custom price-feed adapters** (17)

| Adapter | Address |
|---|---|
| `ETHPlus` | `TBD` |
| `ETHx` | `TBD` |
| `NXM` | `TBD` |
| `OETH` | `TBD` |
| `ankrETH` | `TBD` |
| `eETH` | `TBD` |
| `ezETH` | `TBD` |
| `osETH` | `TBD` |
| `rETH` | `TBD` |
| `rsETH` | `TBD` |
| `sUSDS` | `TBD` |
| `sUSDe` | `TBD` |
| `stETH` | `TBD` |
| `syrupUSDC` | `TBD` |
| `wNXM` | `TBD` |
| `weETH` | `TBD` |
| `wstETH` | `TBD` |

**Balance adapters** (26 excluding ERC20Default: 9 plain + 17 meta-adapters)

Plain (single-instance) adapters:

| Adapter | Address |
|---|---|
| `AaveUmbrella` | `TBD` |
| `AaveV3SafetyModule` | `TBD` |
| `Cap` | `TBD` |
| `ERC4626Wrap_sGHO` | `TBD` |
| `ERC4626Wrap_waEthLidoGHO` | `TBD` |
| `KelpWithdrawalQueue` | `TBD` |
| `LidoWithdrawalQueue` | `TBD` |
| `SparkLend` | `TBD` |
| `StaderWithdrawalQueue` | `TBD` |

Meta-adapters (one immutable contract per protocol class; active instances governed on `NAVCalculator` — see ADR 0010):

| Adapter | Address |
|---|---|
| `AaveV2InstancesMeta` | `TBD` |
| `AaveV3InstancesMeta` | `TBD` |
| `BalancerV3GaugesMeta` | `TBD` |
| `BalancerV3PoolsMeta` | `TBD` |
| `CompoundV3CometsMeta` | `TBD` |
| `ConvexRewardsMeta` | `TBD` |
| `CurveGaugesMeta` | `TBD` |
| `CurvePoolsMeta` | `TBD` |
| `EulerVaultsMeta` | `TBD` |
| `FluidFTokensMeta` | `TBD` |
| `FluidVaultsMeta` | `TBD` |
| `GearboxMarketsMeta` | `TBD` |
| `MorphoMarketsMeta` | `TBD` |
| `MorphoVaultsMeta` | `TBD` |
| `StakeWiseV3VaultsMeta` | `TBD` |
| `UniswapV3PoolsMeta` | `TBD` |

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

**Balance adapters** (8 excluding ERC20Default: all meta-adapters)

| Adapter | Address |
|---|---|
| `AaveV3InstancesMeta` | `TBD` |
| `BalancerV3GaugesMeta` | `TBD` |
| `BalancerV3PoolsMeta` | `TBD` |
| `CompoundV3CometsMeta` | `TBD` |
| `FluidFTokensMeta` | `TBD` |
| `MorphoMarketsMeta` | `TBD` |
| `MorphoVaultsMeta` | `TBD` |

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

**Balance adapters** (7 excluding ERC20Default: all meta-adapters)

| Adapter | Address |
|---|---|
| `AaveV3InstancesMeta` | `TBD` |
| `BalancerV3GaugesMeta` | `TBD` |
| `BalancerV3PoolsMeta` | `TBD` |
| `CompoundV3CometsMeta` | `TBD` |
| `FluidFTokensMeta` | `TBD` |
| `MorphoMarketsMeta` | `TBD` |

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

**Balance adapters** (2 excluding ERC20Default: all meta-adapters)

| Adapter | Address |
|---|---|
| `AaveV3InstancesMeta` | `TBD` |
| `CompoundV3CometsMeta` | `TBD` |

---

## Gnosis Chain (chainId `100`)

**NAV core**

| Component | Address |
|---|---|
| NAVCalculator implementation | `TBD` |
| NAVCalculator proxy | `TBD` |
| ERC20Default balance adapter | `TBD` |
| Final admin / manager (Safe) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://gnosisscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) |

**Custom price-feed adapters** (3)

| Adapter | Address |
|---|---|
| `osGNO` | `TBD` |
| `sXDAI` | `TBD` |
| `wstETH_L2` | `TBD` |

**Balance adapters** (1 excluding ERC20Default: meta-adapter)

| Adapter | Address |
|---|---|
| `AaveV3InstancesMeta` | `TBD` |

---

## Per-chain deploy commits in PR #15

| Chain | Commit |
|---|---|
| Gnosis (100) | [`f47d2e7`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/f47d2e7) |
| Optimism (10) | [`99ab2a3`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/99ab2a3) |
| Base (8453) | [`f7ad578`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/f7ad578) |
| Arbitrum (42161) | [`5a91b46`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/5a91b46) |
| Mainnet (1) | [`181900a`](https://github.com/karpatkey/onchain-accounting/pull/15/commits/181900a) |
