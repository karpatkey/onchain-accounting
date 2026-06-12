# NAV vs DeBank — Detailed Comparison Report

Generated: 2026-06-12 15:25 UTC  
Tolerance: 1%

DeBank anchor: read from `test/integration/debank-cache/` (no live API call).  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25301918 |
| optimism (10) | 152837480 |
| gnosis (100) | 46659874 |
| base (8453) | 47242195 |
| arbitrum (42161) | 472744995 |

## Drift summary

**10 of 15 account-chain pairs within 1% tolerance.** ⚠ 5 over tolerance — see per-account section for breakdown.

| Account | Chain | │ | NAV | │ | DeBank filtered | Drift |  |
|---|---|:---:|---:|:---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | │ | $202.4665 | │ | $180.1380 | +12.40% | ⚠️ |
| ACCOUNT_1 | gnosis | │ | $5.0081 | │ | $5.0102 | -0.04% | ✅ |
| ACCOUNT_1 | base | │ | $9.9986 | │ | $10.0094 | -0.11% | ✅ |
| ACCOUNT_1 | arbitrum | │ | $10.0392 | │ | $10.0459 | -0.07% | ✅ |
| ACCOUNT_2 | mainnet | │ | $528,422.85 | │ | $824,702.39 | -35.93% | ⚠️ |
| ACCOUNT_3 | mainnet | │ | $196.4385 | │ | $196.4939 | -0.03% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | │ | $12,583.18 | │ | $12,605.31 | -0.18% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | │ | $8.168M | │ | $8.172M | -0.05% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | │ | $2.771M | │ | $2.772M | -0.01% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | │ | $1.864M | │ | $1.866M | -0.10% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | │ | $746,858.58 | │ | $747,637.50 | -0.10% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | │ | $16.711M | │ | $17.144M | -2.53% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | │ | $78.192M | │ | $78.297M | -0.13% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | │ | $5.058M | │ | $5.422M | -6.71% | ⚠️ |
| ACCOUNT_12_MAINNET_UNISWAP_V3_LP | mainnet | │ | $31.8303 | │ | $40.9675 | -22.30% | ⚠️ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $202.4665 | DeBank filtered: $180.1380 | Drift: +12.40% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $61.7505 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.125544 | $10.1337 | │ | $84.1049 | Morpho | Supply USDC 10.126153 | $10.1230 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.127521 | $10.1356 | │ | | Morpho | Supply USDC 10.127848 | $10.1247 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.053787 | $5.0489 | │ | | Morpho | Supply USDT 5.053929 | $5.0484 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1962 | │ | | Morpho | Supply USDC 10.128063 | $10.1249 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.127235 | $10.1353 | │ | | Morpho | Supply USDC 10.092642 | $10.0895 |
| | │ | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.092642 | $10.1007 | │ | | Morpho | Supply USDC 38.606363 | $38.5944 |
| Aave V3<br>`aave3` | │ | $52.6571 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.9710 | │ | $52.6392 | Aave V3 | Supply GHO 10.000000 | $9.9886 |
| | │ | | Lending (`0x87870bca…`) | supply USDC 9.115708 + supply USDT 10.114159 + supply USDe 5.035401 + supply sUSDe 3.000000 + supply RLUSD 14.700688 + reward USDS 0.008929 | $42.6861 | │ | | Aave V3 | Collateral USDC 9.116162 | $9.1133 |
| | │ | | | | | │ | | Aave V3 | Collateral USDT 10.114552 | $10.1035 |
| | │ | | | | | │ | | Aave V3 | Collateral USDe 5.035509 | $5.0301 |
| | │ | | | | | │ | | Aave V3 | Collateral sUSDe 3.000000 | $3.7017 |
| | │ | | | | | │ | | Aave V3 | Supply RLUSD 14.701128 | $14.7020 |
| cap<br>`capapp` | │ | $5.0894 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.085883 | $5.0894 | │ | $10.0731 | Cap | Supply USDC 10.076231 | $10.0731 |
| Sky<br>`sky` | │ | $5.0715 | Savings USDS (`0xa3931d71…`) | supply USDS 5.071964 | $5.0715 | │ | — | — | — | — |
| Ethena<br>`ethena` | │ | $4.5047 | sUSDe (`0x9d39a5de…`) | supply USDe 4.505128 | $4.5047 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | │ | 8.905915 | $0.9971 | $8.8801 | │ | — | — | — |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | │ | 0.999922 | $0.9999 | $0.9998 | │ | — | — | — |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 9.626826 | $1.0008 | $9.6345 | │ | — | — | — |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | │ | 4.990006 | $1.0007 | $4.9934 | │ | ↑ aggregated (see protocol row) | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 4.717667 | $0.9990 | $4.7131 | │ | — | — | — |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | │ | 14.831886 | $0.9999 | $14.8304 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Balancer V3 (`balancer3`) | protocol | $7.0099 | supply USDT 1.668297 + supply GHO 4.542147 + supply USDC 0.813625 |
| Merkl (`merkl`) | protocol | $0.3433 | supply: RLUSD 0.113333 ($0.1134) + MORPHO 0.022386 ($0.0430) + GHO 0.186914 ($0.1864) + USDT 0.000329 ($0.0003) + USDC 0.000161 ($0.0002) → **$0.3433** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | USDC | 9.626826 | $9.6238 |
| adapter | Wallet | USDS | 14.831886 | $14.8271 |
| adapter | Wallet | USDT | 4.717667 | $4.7125 |
| adapter | Wallet | GHO | 8.905915 | $8.8957 |
| adapter | Wallet | USDe | 0.999922 | $0.9989 |
| adapter | Wallet | sUSDe | 3.647417 | $4.5006 |
| adapter | Wallet | sUSDS | 4.612968 | $5.0706 |
| adapter | Balancer V3 | USDT | 1.393022 | $1.3915 |
| adapter | Balancer V3 | GHO | 4.894110 | $4.8885 |
| adapter | Balancer V3 | USDC | 0.737160 | $0.7369 |

### Gnosis (chain 100)

**NAV: $5.0081 | DeBank filtered: $5.0102 | Drift: -0.04% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $2.0126 | Lending (`0xb5020155…`) | supply WXDAI 2.012836 | $2.0126 | │ | $2.0120 | Aave V3 | Collateral WXDAI 2.012879 | $2.0120 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | │ | 0.998493 | $0.9997 | $0.9982 | │ | — | — | — |
| xDai | `xdai` | │ | 1.999518 | $0.9999 | $1.9993 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | xDAI | 1.999518 | $1.9987 |
| adapter | Wallet | GHO | 0.998493 | $0.9973 |

### Base (chain 8453)

**NAV: $9.9986 | DeBank filtered: $10.0094 | Drift: -0.11% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | │ | 10.001207 | $1.0008 | $10.0092 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | USDC | 10.001207 | $9.9985 |

### Arbitrum (chain 42161)

**NAV: $10.0392 | DeBank filtered: $10.0459 | Drift: -0.07% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $2.0280 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.016001 | $1.0168 | │ | $2.0260 | Morpho | Supply USDC 1.016003 | $1.0158 |
| | │ | | Deposit (`0x6c247b1f…`) | supply USDC 1.010421 | $1.0112 | │ | | Morpho | Supply USDC 1.010422 | $1.0102 |
| Aave V3<br>`aave3` | │ | $1.0034 | Lending (`0x794a6135…`) | supply USDC 2.017933 + borrow GHO 1.017558 | $1.0034 | │ | $1.0010 | Aave V3 | Collateral USDC 2.017935 | $2.0175 |
| | │ | | | | | │ | | Aave V3 | Borrow GHO 1.017560 | $-1.0165 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| syrupUSDC | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | │ | 1.732523 | $1.1685 | $2.0244 | │ | — | — | — |
| GHO | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | │ | 0.956018 | $0.9986 | $0.9546 | │ | — | — | — |
| USDC | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | │ | 2.004327 | $1.0008 | $2.0059 | │ | — | — | — |
| USD₮0 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | │ | 2.031070 | $0.9990 | $2.0291 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | USDC | 2.004327 | $2.0039 |
| adapter | Wallet | USD₮0 | 2.031070 | $2.0291 |
| adapter | Wallet | GHO | 0.956018 | $0.9550 |
| adapter | Wallet | syrupUSDC | 1.732523 | $2.0238 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $528,422.85 | DeBank filtered: $824,702.39 | Drift: -35.93% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $494,843.18 | Lending (`0x87870bca…`) | supply WETH 0.011615 + supply rsETH 2,013.1002 + borrow WETH 1,866.2548 | $494,843.18 | │ | $491,417.16 | Aave V3 | Collateral WETH 0.011615 | $19.3463 |
| | │ | | | | | │ | | Aave V3 | Collateral rsETH 2,013.1002 | $3.600M |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 1,866.2603 | $-3.108M |
| Kelp DAO<br>`kelpdao` | │ | $294,601.39 | Locked (`0x62de59c0…`) | supply stETH 175.342255 | $292,567.26 | │ | — | — | — | — |
| Spark<br>`spark` | │ | $35,093.01 | Lending (`0xc13e21b6…`) | supply wstETH 129.900000 + borrow WETH 139.595081 | $35,093.01 | │ | $34,846.24 | Spark | Collateral wstETH 129.900000 | $267,356.43 |
| | │ | | | | | │ | | Spark | Borrow WETH 139.595459 | $-232,510.20 |
| LIDO<br>`lido` | │ | $125.5959 | wstETH (`0x7f39c581…`) | supply stETH 0.062375 | $104.0764 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GEAR | `0xba3335588d9403515223f109edc4eb7269a9ab5d` | │ | 91,169.3043 | $0.0004 | $34.9262 | │ | — | — | — |
| ETH | `eth` | │ | 0.002564 | $1,668.55 | $4.2787 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Kelp DAO (`kelpdao`) | protocol | $2,034.14 | supply ETH 1.218739 |
| LIDO (`lido`) | protocol | $21.5195 | supply ETH 0.012893 |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.002564 | $4.2711 |
| adapter | Wallet | wstETH | 0.050430 | $103.7945 |
| adapter | Wallet | rsETH | 1.135177 | $2,029.93 |
| adapter | Wallet | stETH | 0.012893 | $21.4547 |

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $196.4385 | DeBank filtered: $196.4939 | Drift: -0.03% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Balancer V3<br>`balancer3` | │ | $58.5847 | Farming (`0x62a66eb9…`) | supply WETH 0.017452 + supply ETH 0.017611 + reward BAL 0.757598 | $58.5847 | │ | $58.4808 | Balancer V3 | Supply WETH 0.017452 | $29.0682 |
| | │ | | | | | │ | | Balancer V3 | Supply BAL 0.757598 | $0.0794 |
| | │ | | | | | │ | | Balancer V3 | Supply rETH 0.015114 | $29.3333 |
| Aave V3<br>`aave3` | │ | $43.6136 | Lending (`0x4e033931…`) | supply wstETH 0.005001 + supply WETH 0.005027 + supply ezETH 0.005000 + borrow WETH 0.005036 | $19.3208 | │ | $43.4997 | Aave V3 | Collateral wstETH 0.005001 | $10.2922 |
| | │ | | | | | │ | | Aave V3 | Collateral WETH 0.005027 | $8.3735 |
| | │ | | | | | │ | | Aave V3 | Collateral ezETH 0.005000 | $8.9905 |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 0.005036 | $-8.3880 |
| | │ | | Lending (`0x87870bca…`) | supply WETH 0.002973 + supply wstETH 0.009367 | $24.2928 | │ | | Aave V3 | Collateral WETH 0.002973 | $4.9524 |
| | │ | | | | | │ | | Aave V3 | Collateral wstETH 0.009367 | $19.2791 |
| Convex<br>`convex` | │ | $21.4333 | Staked (`0x5411cc58…`) | supply WETH 0.002692 + supply ETH 0.010094 + reward CRV 0.399553 + reward CVX 0.000107 | $21.4333 | │ | $21.3833 | Convex | Supply WETH 0.002756 | $4.5904 |
| | │ | | | | | │ | | Convex | Supply CRV 0.399678 | $0.0973 |
| | │ | | | | | │ | | Convex | Supply CVX 0.000400 | $0.0005 |
| | │ | | | | | │ | | Convex | Supply weETH 0.009144 | $16.6951 |
| Aura Finance<br>`aurafinance` | │ | $0.0619 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.127894 | $0.0619 | │ | $0.0513 | Aura | Supply BAL 0.489289 | $0.0513 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 0.005056 | $1,668.55 | $8.4356 | │ | — | — | — |
| ETH | `eth` | │ | 0.007468 | $1,668.55 | $12.4613 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Rocket Pool (`rocketpool`) | protocol | $29.1376 | supply ETH 0.017463 |
| ether.fi (`etherfi`) | protocol | $15.0756 | supply ETH 0.009035 |
| Kelp DAO (`kelpdao`) | protocol | $7.6903 | supply ETH 0.004609 |
| Merkl (`merkl`) | protocol | $0.4048 | supply: WETH 0.000013 ($0.0216) + ETH 0.000013 ($0.0218) + GEAR 6.174863 ($0.0024) + RPL 0.260909 ($0.3590) → **$0.4048** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.007468 | $12.4392 |
| adapter | Wallet | WETH | 0.005056 | $8.4207 |
| adapter | Wallet | weETH | 0.008237 | $15.0389 |
| adapter | Wallet | rETH | 0.014986 | $29.0861 |
| adapter | Wallet | rsETH | 0.004293 | $7.6768 |
| adapter | Merkl | RPL | 0.260909 | $0.3616 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $12,583.18 | DeBank filtered: $12,605.31 | Drift: -0.18% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $12,604.05 | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.525956 + reward WETH 0.027935 | $12,604.05 | │ | $12,581.92 | Aave Umbrella | Supply WETH 7.525953 | $12,535.23 |
| | │ | | | | | │ | | Aave Umbrella | Supply WETH 0.028035 | $46.6947 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.000754 | $1,668.42 | $1.2586 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.000754 | $1.2564 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.168M | DeBank filtered: $8.172M | Drift: -0.05% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Fluid<br>`fluid` | │ | $8.172M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0623M | $5.057M | │ | $8.168M | Fluid | Supply USDT 5.0624M | $5.057M |
| | │ | | Fluid USD Coin (`0x9fb7b447…`) | supply USDC 3.1119M | $3.114M | │ | | Fluid | Supply USDC 3.1120M | $3.111M |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.085985 | $1,668.42 | $143.4589 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.085985 | $143.2164 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.771M | DeBank filtered: $2.772M | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $2.772M | Lending + Yield (`0x2e44e174…`) | supply USDC 758,827.8525 + reward COMP 38.421572 | $760,112.39 | │ | $2.771M | Compound V3 | Supply USDC 758,862.8708 | $758,620.03 |
| | │ | | | | | │ | | Compound V3 | Supply COMP 38.421572 | $676.4756 |
| | │ | | Lending + Yield (`0x995e394b…`) | supply USDT 2.0110M + reward COMP 138.982925 | $2.012M | │ | | Compound V3 | Supply USDT 2.0111M | $2.009M |
| | │ | | | | | │ | | Compound V3 | Supply COMP 138.982925 | $2,447.03 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `op` | │ | 0.049027 | $1,668.42 | $81.7979 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.049027 | $81.6057 |
| adapter | Compound V3 | COMP | 24.934844 | $439.0193 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $1.864M | DeBank filtered: $1.866M | Drift: -0.10% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $1.466M | Yield (`0x9c4ec768…`) | supply USDC 1.4646M | $1.466M | │ | $1.464M | Compound V3 | Supply USDC 1.4646M | $1.464M |
| Fluid<br>`fluid` | │ | $400,559.73 | Fluid USD Coin (`0x1a996cb5…`) | supply USDC 400,239.2793 | $400,559.73 | │ | $400,167.47 | Fluid | Supply USDC 400,249.5926 | $400,167.47 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `arb` | │ | 0.001287 | $1,668.42 | $2.1471 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Dolomite (`dolomite`) | protocol | $100,106.60 | supply: USDC 100,026.5103 ($100,106.60) → **$100,106.60** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.001287 | $2.1413 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $746,858.58 | DeBank filtered: $747,637.50 | Drift: -0.10% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $747,598.53 | Lending + Yield (`0xb125e668…`) | supply USDC 746,769.6632 + reward COMP 13.108705 | $747,598.53 | │ | $746,819.69 | Compound V3 | Supply USDC 746,794.4663 | $746,589.64 |
| | │ | | | | | │ | | Compound V3 | Supply COMP 13.108705 | $230.0583 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `base` | │ | 0.023355 | $1,668.42 | $38.9667 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| CASHW | wallet token | $2.0246 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.023355 | $38.8827 |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $16.711M | DeBank filtered: $17.144M | Drift: -2.53% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $7.570M | kpk USDC (`0x4ef53d2c…`) | supply USDC 6.1726M | $6.178M | │ | $7.561M | Morpho | Supply USDC 6.1726M | $6.171M |
| | │ | | kpk EURC (`0xa877d5bb…`) | supply EURC 1.2025M | $1.393M | │ | | Morpho | Supply EURC 1.2025M | $1.390M |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 0.000016 | $0.0274 | │ | | Morpho | Supply WETH 0.000016 | $0.0273 |
| LIDO<br>`lido` | │ | $1.859M | wstETH (`0x7f39c581…`) | supply stETH 213.164063 | $355,650.82 | │ | — | — | — | — |
| Aave V3<br>`aave3` | │ | $984,439.73 | Lending (`0x87870bca…`) | supply WETH 0.000024 + supply EURC 850,050.7828 | $984,439.73 | │ | $982,778.82 | Aave V3 | Collateral WETH 0.000024 | $0.0398 |
| | │ | | | | | │ | | Aave V3 | Supply EURC 850,051.7029 | $982,778.78 |
| StakeWise<br>`stakewise` | │ | $397.6721 | Lending (`0x15639e82…`) | supply ETH 0.389010 + borrow osETH 0.142307 | $397.6721 | │ | $406.4480 | StakeWise V3 | Supply ETH 0.389010 | $647.9346 |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.144985 | $-241.4865 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| EURC | `0x1abaea1f7c830bd89acc67ec4af516284b1bc33c` | │ | 149,000.0000 | $1.1581 | $172,556.18 | │ | — | — | — |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 6.1416M | $1.0008 | $6.146M | │ | — | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 152.306225 | $0.9990 | $152.1585 | │ | — | — | — |
| ETH | `eth` | │ | 0.500420 | $1,668.42 | $834.9102 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| LIDO (`lido`) | protocol | $1.503M | supply ETH 901.043302 |
| Sablier (`sablier`) | protocol | $1.061M | supply: COW 7.4031M ($1.061M) → **$1.061M** |
| Uniswap V3 (`uniswap3`) | protocol | $410,222.56 | supply WETH 82.536048 + supply COW 1.8745M + reward WETH 1.143029 + reward COW 13,903.5469 |
| COW | wallet token | $130,193.70 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.500420 | $833.4990 |
| adapter | Wallet | wstETH | 172.342940 | $354,711.27 |
| adapter | Wallet | USDC | 6.1416M | $6.140M |
| adapter | Wallet | stETH | 901.043302 | $1.499M |
| adapter | Wallet | USDT | 152.306225 | $152.1391 |
| adapter | Wallet | EURC | 149,000.0000 | $172,264.86 |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $78.192M | DeBank filtered: $78.297M | Drift: -0.13% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| StakeWise<br>`stakewise` | │ | $19.150M | Lending (`0xac0f906e…`) | supply ETH 11,477.8914 + borrow osETH 0.000006 | $19.150M | │ | $19.118M | StakeWise V3 | Supply ETH 11,477.8914 | $19.118M |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.000006 | $-0.0100 |
| Aave V3<br>`aave3` | │ | $13.361M | Lending (`0x87870bca…`) | supply USDC 13.3507M + reward USDS 0.435315 | $13.361M | │ | $13.347M | Aave V3 | Collateral USDC 13.3512M | $13.347M |
| Morpho<br>`morpho` | │ | $11.912M | kpk USDC (`0x4ef53d2c…`) | supply USDC 11.9029M | $11.912M | │ | $11.900M | Morpho | Supply USDC 11.9032M | $11.900M |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 0.000111 | $0.1856 | │ | | Morpho | Supply WETH 0.000111 | $0.1852 |
| Sky<br>`sky` | │ | $9.330M | Savings USDS (`0xa3931d71…`) | supply USDS 9.3311M | $9.330M | │ | — | — | — | — |
| Compound V3<br>`compound3` | │ | $395,961.58 | Lending + Yield (`0xc3d688b6…`) | supply USDC 395,632.5625 + reward COMP 0.695526 | $395,961.58 | │ | $395,536.27 | Compound V3 | Supply USDC 395,646.2280 | $395,523.58 |
| | │ | | | | | │ | | Compound V3 | Supply COMP 0.722540 | $12.6881 |
| LIDO<br>`lido` | │ | $251.5505 | wstETH (`0x7f39c581…`) | supply stETH 0.150770 | $251.5505 | │ | — | — | — | — |
| Fluid<br>`fluid` | │ | $3.0015 | Fluid Tether USD (`0x5c20b550…`) | supply USDT 1.768741 | $1.7670 | │ | $3.0002 | Fluid | Supply USDT 1.768842 | $1.7669 |
| | │ | | Fluid USD Coin (`0x9fb7b447…`) | supply USDC 1.233526 | $1.2345 | │ | | Fluid | Supply USDC 1.233660 | $1.2333 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Stader (`stader`) | protocol | $16.972M | supply ETH 10,172.4808 |
| ether.fi (`etherfi`) | protocol | $4.252M | supply ETH 2,548.6250 |
| Rocket Pool (`rocketpool`) | protocol | $2.923M | supply ETH 1,752.0099 |
| Uniswap V3 (`uniswap3`) | protocol | $31.6145 | supply WETH 0.006847 + supply ETH 0.010248 + reward WETH 0.000925 + reward ETH 0.000929 |
| Balancer V2 (`balancer2`) | protocol | $0.1020 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1020) → **$0.1020** |
| HEX | wallet token | $0.8479 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | wstETH | 0.121897 | $250.8859 |
| adapter | Wallet | eETH | 2,548.6852 | $4.242M |
| adapter | Wallet | rETH | 1,503.6269 | $2.918M |
| adapter | Wallet | sUSDS | 8.4865M | $9.328M |
| adapter | Wallet | ETHx | 9,325.6655 | $16.943M |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $5.058M | DeBank filtered: $5.422M | Drift: -6.71% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $2.053M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.0518M | $2.053M | │ | $2.051M | Morpho | Supply USDC 2.0518M | $2.051M |
| Aave V2<br>`aave2` | │ | $1.255M | Staked (`0x4da27a54…`) | supply AAVE 19,442.9617 + reward AAVE 1.919608 | $1.255M | │ | $1.248M | Aave V3 | Supply AAVE 19,442.9617 | $1.247M |
| | │ | | | | | │ | | Aave V3 | Supply AAVE 2.151317 | $138.0187 |
| | │ | | Lending (`0x7d2768de…`) | supply BAL 58.491558 | $6.1514 | │ | | Aave V2 | Collateral BAL 58.491558 | $6.1284 |
| Aave V3<br>`aave3` | │ | $756,797.74 | Lending (`0x87870bca…`) | supply USDC 722,304.4816 + supply BAL 320,272.8251 | $756,565.11 | │ | $755,644.51 | Aave V3 | Collateral USDC 722,311.8722 | $722,087.96 |
| | │ | | | | | │ | | Aave V3 | Supply BAL 320,273.1468 | $33,556.55 |
| | │ | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 233.300789 | $232.6242 | │ | | — | — | — |
| StakeWise<br>`stakewise` | │ | $621,444.48 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.6248 | │ | $620,387.13 | StakeWise V3 | Supply ETH 372.470659 | $620,387.13 |
| Spark<br>`spark` | │ | $351,386.39 | Spark Savings USDC (`0x28b3a8fb…`) | supply USDC 351,105.2791 | $351,386.39 | │ | — | — | — | — |
| Compound V3<br>`compound3` | │ | $79.7623 | Lending + Yield (`0xc3d688b6…`) | supply USDC 1.574326 + reward COMP 4.437382 | $79.7623 | │ | $79.4962 | Compound V3 | Supply USDC 1.574341 | $1.5739 |
| | │ | | | | | │ | | Compound V3 | Supply COMP 4.437382 | $77.9224 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | │ | 2.4916M | $0.1052 | $262,035.93 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| StakeWise (`stakewise`) | protocol | $621,437.50 | supply ETH 372.470659 |
| Rocket Pool (`rocketpool`) | protocol | $121,885.99 | supply ETH 73.054740 |
| Balancer V2 (`balancer2`) | protocol | $24,845.49 | supply: BAL 92,891.3577 ($9,769.16) + WETH 9.036290 ($15,076.33) → **$24,845.49** |
| Across V2 (`acrocc_v2`) | protocol | $8,741.56 | supply: BAL 83,120.2519 ($8,741.56) → **$8,741.56** |
| Polygon Staking (`polygon_staking`) | protocol | $7,867.52 | supply: POL 106,114.2338 ($7,855.70); rewards: POL 159.693337 ($11.8222) → **$7,867.52** |
| Merkl (`merkl`) | protocol | $7.8578 | supply: GHO 7.880685 ($7.8578) → **$7.8578** |
| StakeWise (`stakewise`) | protocol | $6.3622 | supply ETH 0.003813 |
| Uniswap V3 (`uniswap3`) | protocol | $3.5685 | supply WETH 0.000773 + supply ETH 0.001157 + reward WETH 0.000104 + reward ETH 0.000105 |
| Uniswap V3 (`uniswap3`) | protocol | $3.4377 | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 |
| Multichain (`multichain`) | protocol | $2.2258 | supply: BAL 21.164100 ($2.2258) → **$2.2258** |
| Compound (`compound`) | protocol | $1.8090 | supply: DAI 1.132199 ($1.1321) + AAVE 0.010451 ($0.6744); rewards: COMP 0.000146 ($0.0026) → **$1.8090** |
| COW | wallet token | $170,184.98 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.000041 | $0.0676 |
| adapter | Wallet | rETH | 62.694486 | $121,679.98 |
| adapter | Wallet | BAL | 2.4916M | $261,057.19 |
| adapter | ERC4626 | GHO | 233.301681 | $233.0346 |
| adapter | Uniswap V3 | WETH | 0.001972 | $3.2837 |
| adapter | Uniswap V3 | WBTC | 0.000002 | $0.1043 |
| adapter | Uniswap V3 | WETH | 0.000027 | $0.0442 |

---

## ACCOUNT_12_MAINNET_UNISWAP_V3_LP

**Address:** `0x8d27deb2405717d649346502f52b959aab4eb3af`

### Mainnet (chain 1)

**NAV: $31.8303 | DeBank filtered: $40.9675 | Drift: -22.30% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Convex<br>`convex` | │ | $9.0835 | Staked (`0x49b4d1df…`) | supply cvxFXS 62.684670 + reward FRAX 1.860052 + reward CVX 1.434995 | $9.0835 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 1.000004 | $1.0008 | $1.0008 | │ | — | — | — |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 0.003338 | $1,668.60 | $5.5697 | │ | — | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 1.714801 | $0.9990 | $1.7131 | │ | — | — | — |
| ETH | `eth` | │ | 0.014144 | $1,668.60 | $23.6004 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Layer3 (`layer3`) | protocol | $49.7052 | supply: L3 6,323.3042 ($42.3661); rewards: L3 1,095.3876 ($7.3391) → **$49.7052** |
| espresso (`espresso`) | protocol | $40.9590 | supply: ESP 625.520000 ($40.9590) → **$40.9590** |
| Ekubo (`ekubo`) | protocol | $12.7523 | supply: EKUBO 4.006297 ($1.9840) + gEKUBO-26Q2 6.674740 ($0.0000); rewards: EKUBO 0.140899 ($0.0698) + gEKUBO-26Q2 0.183029 ($0.0000) → **$2.0537**<br>supply: ETH 0.000000 ($0.0000) + EKUBO 21.604083 ($10.6985) → **$10.6985** |
| AEVO | wallet token | $6.3310 | `0xb528edbef013aff855ac3c50b381f253af13b997` |
| EKUBO | wallet token | $0.7046 | `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.014144 | $23.5580 |
| adapter | Wallet | WETH | 0.003338 | $5.5596 |
| adapter | Wallet | USDC | 1.000004 | $0.9997 |
| adapter | Wallet | USDT | 1.714801 | $1.7129 |

---

## Section 3 — Per-Adapter Granular Detail

_One table per adapter instance × account. **Amount drift** (Δ amt %) signals a balance-adapter issue. **Price drift** (Δ price %) signals a price-feed issue. If both are small but USD drift is large, check decimal/precision handling in the price computation._

_Severity: **OK** ≤1% · **WARN** 1–5% · **FAIL** >5%. Rows sorted by descending NAV USD._
_`nav_only` rows (no DeBank match) are listed in a separate subsection._

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 2.0518M | 2.0518M | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $2.051M | $2.053M | OK -0.11% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 11.9032M | 11.9029M | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $11.900M | $11.912M | OK -0.11% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 6.1726M | 6.1726M | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $6.171M | $6.178M | OK -0.11% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.126153 | 10.125544 | OK +0.01% | $0.9997 | $1.0008 | OK -0.11% | $10.1230 | $10.1337 | OK -0.10% |

### StakeWise V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Supply) | + | 372.470659 | 0.000374 | FAIL +99459458.52% | $1,665.60 | $1,668.42 | OK -0.17% | $620,387.13 | $0.6248 | FAIL +99291349.80% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Supply) | + | 11,477.8914 | 11,477.8914 | OK +0.00% | $1,665.60 | $1,668.42 | OK -0.17% | $19.118M | $19.150M | OK -0.17% |
| ETH (Borrow) | − | 0.000006 | 11,477.8914 | FAIL -100.00% | $1,665.60 | $1,668.42 | OK -0.17% | $-0.0100 | $19.150M | FAIL -100.00% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 722,311.8722 | 722,304.4816 | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $722,087.96 | $722,882.79 | OK -0.11% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 13.3512M | 13.3507M | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $13.347M | $13.361M | OK -0.11% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 9.116162 | 9.115708 | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $9.1133 | $9.1230 | OK -0.11% |

### Fluid — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 1.768842 | 1.768741 | OK +0.01% | $0.9989 | $0.9990 | OK -0.01% | $1.7669 | $1.7670 | OK -0.01% |

#### ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 5.0624M | 5.0623M | OK +0.00% | $0.9989 | $0.9990 | OK -0.01% | $5.057M | $5.057M | OK -0.01% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| rsETH (Collateral) | + | 2,013.1002 | 2,013.1002 | OK +0.00% | $1,788.21 | $1,793.10 | OK -0.27% | $3.600M | $3.610M | OK -0.27% |

### Fluid — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.233660 | 1.233526 | OK +0.01% | $0.9997 | $1.0008 | OK -0.11% | $1.2333 | $1.2345 | OK -0.10% |

#### ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 3.1120M | 3.1119M | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $3.111M | $3.114M | OK -0.11% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Collateral) | + | 0.002973 | 0.002973 | OK +0.00% | $1,665.60 | $1,668.55 | OK -0.18% | $4.9524 | $4.9612 | OK -0.18% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Collateral) | + | 0.000024 | 0.000024 | OK +0.00% | $1,665.60 | $1,668.42 | OK -0.17% | $0.0398 | $0.0399 | OK -0.17% |

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Borrow) | − | 1,866.2603 | 1,866.2548 | OK +0.00% | $1,665.60 | $1,669.05 | OK -0.21% | $-3.108M | $3.115M | FAIL -199.79% |
| WETH (Collateral) | + | 0.011615 | 0.011615 | OK +0.00% | $1,665.60 | $1,669.05 | OK -0.21% | $19.3463 | $19.3864 | OK -0.21% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| EURC (Supply) | + | 1.2025M | 1.2025M | OK +0.00% | $1.1561 | $1.1581 | OK -0.17% | $1.390M | $1.393M | OK -0.17% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| AAVE (Supply) | + | 19,442.9617 | 19,442.9617 | OK +0.00% | $64.1554 | $64.5300 | OK -0.58% | $1.247M | $1.255M | OK -0.58% |
| AAVE (Supply) | + | 2.151317 | 1.919608 | FAIL +12.07% | $64.1554 | $64.5300 | OK -0.58% | $138.0187 | $123.8723 | FAIL +11.42% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| EURC (Supply) | + | 850,051.7029 | 850,050.7828 | OK +0.00% | $1.1561 | $1.1581 | OK -0.17% | $982,778.78 | $984,439.69 | OK -0.17% |

### Compound V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| COMP (Supply) | + | 4.437382 | 4.437382 | OK +0.00% | $17.5604 | $17.6200 | OK -0.34% | $77.9224 | $78.1867 | OK -0.34% |
| USDC (Supply) | + | 1.574341 | 1.574326 | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $1.5739 | $1.5756 | OK -0.11% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 395,646.2280 | 395,632.5625 | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $395,523.58 | $395,949.32 | OK -0.11% |
| COMP (Supply) | + | 0.722540 | 0.695526 | WARN +3.88% | $17.5604 | $17.6200 | OK -0.34% | $12.6881 | $12.2552 | WARN +3.53% |

### Spark — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 129.900000 | 129.900000 | OK +0.00% | $2,058.17 | $2,063.77 | OK -0.27% | $267,356.43 | $268,084.19 | OK -0.27% |

### Spark — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Borrow) | − | 139.595459 | 139.595081 | OK +0.00% | $1,665.60 | $1,669.05 | OK -0.21% | $-232,510.20 | $232,991.17 | FAIL -199.79% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Supply) | + | 320,273.1468 | 320,272.8251 | OK +0.00% | $0.1048 | $0.1052 | OK -0.37% | $33,556.55 | $33,682.33 | OK -0.37% |

### Aave Umbrella — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_4_UMBRELLA (`0x13ce0c…5f86df`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 7.525953 | 7.525956 | OK -0.00% | $1,665.60 | $1,668.55 | OK -0.18% | $12,535.23 | $12,557.43 | OK -0.18% |
| WETH (Supply) | + | 0.028035 | 0.027935 | OK +0.36% | $1,665.60 | $1,668.55 | OK -0.18% | $46.6947 | $46.6117 | OK +0.18% |

### StakeWise V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Supply) | + | 0.389010 | 0.389010 | OK +0.00% | $1,665.60 | $1,668.42 | OK -0.17% | $647.9346 | $649.0316 | OK -0.17% |
| ETH (Borrow) | − | 0.144985 | 0.389010 | FAIL -62.73% | $1,665.60 | $1,668.42 | OK -0.17% | $-241.4865 | $649.0316 | FAIL -137.21% |

### Balancer V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| rETH (Supply) | + | 0.015114 | — | — | $1,940.84 | — | — | $29.3333 | — | — |
| WETH (Supply) | + | 0.017452 | 0.017452 | OK +0.00% | $1,665.60 | $1,668.55 | OK -0.18% | $29.0682 | $29.1196 | OK -0.18% |
| BAL (Supply) | + | 0.757598 | 0.757598 | OK -0.00% | $0.1048 | $0.1053 | OK -0.48% | $0.0794 | $0.0798 | OK -0.48% |

### Morpho — Mainnet (chain 1) — `0xd9e34b1eed…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 38.606363 | 10.092642 | FAIL +282.52% | $0.9997 | $1.0008 | OK -0.11% | $38.5944 | $10.1007 | FAIL +282.10% |

### Convex — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| weETH (Supply) | + | 0.009144 | — | — | $1,825.76 | — | — | $16.6951 | — | — |
| WETH (Supply) | + | 0.002756 | 0.002692 | WARN +2.38% | $1,665.60 | $1,668.55 | OK -0.18% | $4.5904 | $4.4918 | WARN +2.20% |
| CRV (Supply) | + | 0.399678 | 0.399553 | OK +0.03% | $0.2433 | $0.2468 | WARN -1.40% | $0.0973 | $0.0986 | WARN -1.37% |
| CVX (Supply) | + | 0.000400 | 0.000107 | FAIL +272.87% | $1.3595 | $1.3585 | OK +0.08% | $0.0005 | $0.0001 | FAIL +273.15% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.009367 | 0.009367 | OK +0.00% | $2,058.17 | $2,063.77 | OK -0.27% | $19.2791 | $19.3316 | OK -0.27% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Borrow) | − | 0.005036 | 0.005036 | OK +0.00% | $1,665.60 | $1,668.55 | OK -0.18% | $-8.3880 | $8.4029 | FAIL -199.82% |
| WETH (Collateral) | + | 0.005027 | 0.005027 | OK +0.00% | $1,665.60 | $1,668.55 | OK -0.18% | $8.3735 | $8.3883 | OK -0.18% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| RLUSD (Supply) | + | 14.701128 | 14.700688 | OK +0.00% | $1.0001 | $1.0006 | OK -0.05% | $14.7020 | $14.7095 | OK -0.05% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.005001 | 0.005001 | OK +0.00% | $2,058.17 | $2,063.77 | OK -0.27% | $10.2922 | $10.3203 | OK -0.27% |

### Morpho — Mainnet (chain 1) — `0xb323495f7e…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.128063 | 16.183234 | FAIL -37.42% | $0.9997 | $1.0008 | OK -0.11% | $10.1249 | $16.1962 | FAIL -37.49% |

### Morpho — Mainnet (chain 1) — `0x64d65c9a2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.127848 | 10.127521 | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $10.1247 | $10.1356 | OK -0.11% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Collateral) | + | 10.114552 | 10.114159 | OK +0.00% | $0.9989 | $0.9990 | OK -0.01% | $10.1035 | $10.1044 | OK -0.01% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.092642 | 10.127235 | OK -0.34% | $0.9997 | $1.0008 | OK -0.11% | $10.0895 | $10.1353 | OK -0.45% |

### Cap — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.076231 | — | — | $0.9997 | — | — | $10.0731 | $5.0894 | FAIL +97.92% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Supply) | + | 10.000000 | 10.000000 | OK +0.00% | $0.9989 | $0.9971 | OK +0.18% | $9.9886 | $9.9710 | OK +0.18% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ezETH (Collateral) | + | 0.005000 | 0.005000 | OK +0.00% | $1,798.09 | $1,803.02 | OK -0.27% | $8.9905 | $9.0151 | OK -0.27% |

### Aave V2 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Collateral) | + | 58.491558 | 58.491558 | OK +0.00% | $0.1048 | $0.1052 | OK -0.37% | $6.1284 | $6.1514 | OK -0.37% |

### Morpho — Mainnet (chain 1) — `0x3274643db7…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 5.053929 | 5.053787 | OK +0.00% | $0.9989 | $0.9990 | OK -0.01% | $5.0484 | $5.0489 | OK -0.01% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDe (Collateral) | + | 5.035509 | 5.035401 | OK +0.00% | $0.9989 | $0.9999 | OK -0.10% | $5.0301 | $5.0349 | OK -0.09% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| sUSDe (Collateral) | + | 3.000000 | 3.000000 | OK +0.00% | $1.2339 | $1.2351 | OK -0.10% | $3.7017 | $3.7053 | OK -0.10% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.000111 | 0.000111 | OK +0.00% | $1,665.60 | $1,668.42 | OK -0.17% | $0.1852 | $0.1856 | OK -0.17% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.000016 | 0.000016 | OK +0.00% | $1,665.60 | $1,668.42 | OK -0.17% | $0.0273 | $0.0274 | OK -0.17% |

### Aura — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Supply) | + | 0.489289 | 0.489289 | OK +0.00% | $0.1048 | $0.1053 | OK -0.48% | $0.0513 | $0.0515 | OK -0.48% |

### Compound V3 — Optimism (chain 10) — `0x0000000000…`

#### ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 2.0111M | 2.0110M | OK +0.00% | $0.9990 | $0.9990 | OK +0.00% | $2.009M | $2.009M | OK +0.01% |
| COMP (Supply) | + | 138.982925 | 138.982925 | OK +0.00% | $17.6067 | $17.6200 | OK -0.08% | $2,447.03 | $2,448.88 | OK -0.08% |

### Compound V3 — Optimism (chain 10) — `0x0000000000…`

#### ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 758,862.8708 | 758,827.8525 | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $758,620.03 | $759,435.40 | OK -0.11% |
| COMP (Supply) | + | 38.421572 | 38.421572 | OK +0.00% | $17.6067 | $17.6200 | OK -0.08% | $676.4756 | $676.9881 | OK -0.08% |

### Aave V3 — Gnosis (chain 100) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WXDAI (Collateral) | + | 2.012879 | 2.012836 | OK +0.00% | $0.9996 | $0.9999 | OK -0.03% | $2.0120 | $2.0126 | OK -0.03% |

### Compound V3 — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.4646M | 1.4646M | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $1.464M | $1.466M | OK -0.10% |

### Fluid — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 400,249.5926 | 400,239.2793 | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $400,167.47 | $400,559.73 | OK -0.10% |

### Aave V3 — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 2.017935 | 2.017933 | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $2.0175 | $2.0195 | OK -0.10% |

### Aave V3 — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Borrow) | − | 1.017560 | 1.017558 | OK +0.00% | $0.9989 | $0.9986 | OK +0.04% | $-1.0165 | $1.0161 | FAIL -200.04% |

### Morpho — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.016003 | 1.016001 | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $1.0158 | $1.0168 | OK -0.10% |

### Morpho — Arbitrum (chain 42161) — `0x77fe2f7c2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.010422 | 1.010421 | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $1.0102 | $1.0112 | OK -0.10% |

### Compound V3 — Base (chain 8453) — `0x0000000000…`

#### ACCOUNT_8_COMPOUND_BASE (`0xa46680…623314`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 746,794.4663 | 746,769.6632 | OK +0.00% | $0.9997 | $1.0008 | OK -0.11% | $746,589.64 | $747,367.56 | OK -0.10% |
| COMP (Supply) | + | 13.108705 | 13.108705 | OK +0.00% | $17.5500 | $17.6200 | OK -0.40% | $230.0583 | $230.9754 | OK -0.40% |

### NAV-only positions (no DeBank counterpart matched)

_These adapter positions are counted in the headline NAV but have no DeBank row. See Section 2 inline tables for rationale._

| Chain | Account | Protocol | Leg | NAV amount | NAV unit $ | NAV USD |
|---|---|---|---|---:|---:|---:|
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | ETHx (Wallet) | 9,325.6655 | $1,816.84 | $16.943M |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | sUSDS (Wallet) | 8.4865M | $1.0992 | $9.328M |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | USDC (Wallet) | 6.1416M | $0.9997 | $6.140M |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | eETH (Wallet) | 2,548.6852 | $1,664.48 | $4.242M |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | rETH (Wallet) | 1,503.6269 | $1,940.84 | $2.918M |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | stETH (Wallet) | 901.043302 | $1,664.03 | $1.499M |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | wstETH (Wallet) | 172.342940 | $2,058.17 | $354,711.27 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | BAL (Wallet) | 2.4916M | $0.1048 | $261,057.19 |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | EURC (Wallet) | 149,000.0000 | $1.1561 | $172,264.86 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | rETH (Wallet) | 62.694486 | $1,940.84 | $121,679.98 |
| mainnet (1) | ACCOUNT_2 (`0x99b9f5…23768b`) | Wallet | rsETH (Wallet) | 1.135177 | $1,788.21 | $2,029.93 |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | ETH (Wallet) | 0.500420 | $1,665.60 | $833.4990 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Compound V3 | COMP (Supply) | 24.934844 | $17.6067 | $439.0193 |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | wstETH (Wallet) | 0.121897 | $2,058.17 | $250.8859 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | ERC4626 | GHO (Supply) | 233.301681 | $0.9989 | $233.0346 |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | USDT (Wallet) | 152.306225 | $0.9989 | $152.1391 |
| mainnet (1) | ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`) | Wallet | ETH (Wallet) | 0.085985 | $1,665.60 | $143.2164 |
| mainnet (1) | ACCOUNT_2 (`0x99b9f5…23768b`) | Wallet | wstETH (Wallet) | 0.050430 | $2,058.17 | $103.7945 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Wallet | ETH (Wallet) | 0.049027 | $1,664.50 | $81.6057 |
| base (8453) | ACCOUNT_8_COMPOUND_BASE (`0xa46680…623314`) | Wallet | ETH (Wallet) | 0.023355 | $1,664.82 | $38.8827 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | rETH (Wallet) | 0.014986 | $1,940.84 | $29.0861 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | ETH (Wallet) | 0.014144 | $1,665.60 | $23.5580 |
| mainnet (1) | ACCOUNT_2 (`0x99b9f5…23768b`) | Wallet | stETH (Wallet) | 0.012893 | $1,664.03 | $21.4547 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | weETH (Wallet) | 0.008237 | $1,825.76 | $15.0389 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDS (Wallet) | 14.831886 | $0.9997 | $14.8271 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | ETH (Wallet) | 0.007468 | $1,665.60 | $12.4392 |
| base (8453) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDC (Wallet) | 10.001207 | $0.9997 | $9.9985 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDC (Wallet) | 9.626826 | $0.9997 | $9.6238 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | GHO (Wallet) | 8.905915 | $0.9989 | $8.8957 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | WETH (Wallet) | 0.005056 | $1,665.60 | $8.4207 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | rsETH (Wallet) | 0.004293 | $1,788.21 | $7.6768 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | WETH (Wallet) | 0.003338 | $1,665.60 | $5.5596 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | sUSDS (Wallet) | 4.612968 | $1.0992 | $5.0706 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Balancer V3 | GHO (Supply) | 4.894110 | $0.9989 | $4.8885 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDT (Wallet) | 4.717667 | $0.9989 | $4.7125 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | sUSDe (Wallet) | 3.647417 | $1.2339 | $4.5006 |
| mainnet (1) | ACCOUNT_2 (`0x99b9f5…23768b`) | Wallet | ETH (Wallet) | 0.002564 | $1,665.60 | $4.2711 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Uniswap V3 | WETH (Supply) | 0.001972 | $1,665.60 | $3.2837 |
| arbitrum (42161) | ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`) | Wallet | ETH (Wallet) | 0.001287 | $1,663.93 | $2.1413 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USD₮0 (Wallet) | 2.031070 | $0.9990 | $2.0291 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | syrupUSDC (Wallet) | 1.732523 | $1.1681 | $2.0238 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDC (Wallet) | 2.004327 | $0.9998 | $2.0039 |
| gnosis (100) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | xDAI (Wallet) | 1.999518 | $0.9996 | $1.9987 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | USDT (Wallet) | 1.714801 | $0.9989 | $1.7129 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Balancer V3 | USDT (Supply) | 1.393022 | $0.9989 | $1.3915 |
| mainnet (1) | ACCOUNT_4_UMBRELLA (`0x13ce0c…5f86df`) | Wallet | ETH (Wallet) | 0.000754 | $1,665.60 | $1.2564 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | USDC (Wallet) | 1.000004 | $0.9997 | $0.9997 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDe (Wallet) | 0.999922 | $0.9989 | $0.9989 |
| gnosis (100) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | GHO (Wallet) | 0.998493 | $0.9988 | $0.9973 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | GHO (Wallet) | 0.956018 | $0.9989 | $0.9550 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Balancer V3 | USDC (Supply) | 0.737160 | $0.9997 | $0.7369 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Merkl | RPL (Supply) | 0.260909 | $1.3860 | $0.3616 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Uniswap V3 | WBTC (Supply) | 0.000002 | $63,194.62 | $0.1043 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | ETH (Wallet) | 0.000041 | $1,665.60 | $0.0676 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Uniswap V3 | WETH (Supply) | 0.000027 | $1,665.60 | $0.0442 |

---

## Section 4 — Coverage Gaps

_Use this section to identify missing adapter registrations, unregistered tokens, or missing price feeds._

### 4.1 — DeBank protocols with value not in `supportedDeBankProtocols`

_These show non-zero DeBank balance but are absent from the per-chain allowlist in `accounts.json`. If an NAV adapter exists for the protocol, consider adding it to `supportedDeBankProtocols` and registering the adapter on that chain._

| Chain | Account | Protocol | DeBank ID | Value | NAV adapter? |
|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Stader | `stader` | $16.972M | Yes (`Stader`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | ether.fi | `etherfi` | $4.252M | Yes (`ether.fi`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Rocket Pool | `rocketpool` | $2.923M | Yes (`Rocket Pool`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | LIDO | `lido` | $1.503M | Yes (`Lido`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Sablier | `sablier` | $1.061M | Yes (`Sablier`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $621,437.50 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Uniswap V3 | `uniswap3` | $410,222.56 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Rocket Pool | `rocketpool` | $121,885.99 | Yes (`Rocket Pool`) |
| Arbitrum (42161) | ACCOUNT_7_COMPOUND_ARBITRUM | Dolomite | `dolomite` | $100,106.60 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Balancer V2 | `balancer2` | $24,845.49 | Yes (`Balancer V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Across V2 | `acrocc_v2` | $8,741.56 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Polygon Staking | `polygon_staking` | $7,867.52 | No |
| Mainnet (1) | ACCOUNT_2 | Kelp DAO | `kelpdao` | $2,034.14 | Yes (`Kelp DAO`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Layer3 | `layer3` | $49.7052 | No |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | espresso | `espresso` | $40.9590 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Uniswap V3 | `uniswap3` | $31.6145 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_3 | Rocket Pool | `rocketpool` | $29.1376 | Yes (`Rocket Pool`) |
| Mainnet (1) | ACCOUNT_2 | LIDO | `lido` | $21.5195 | Yes (`Lido`) |
| Mainnet (1) | ACCOUNT_3 | ether.fi | `etherfi` | $15.0756 | Yes (`ether.fi`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Ekubo | `ekubo` | $12.7523 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Merkl | `merkl` | $7.8578 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_3 | Kelp DAO | `kelpdao` | $7.6903 | Yes (`Kelp DAO`) |
| Mainnet (1) | ACCOUNT_1 | Balancer V3 | `balancer3` | $7.0099 | Yes (`Balancer V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $6.3622 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Uniswap V3 | `uniswap3` | $3.5685 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Uniswap V3 | `uniswap3` | $3.4377 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Multichain | `multichain` | $2.2258 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Compound | `compound` | $1.8090 | No |
| Mainnet (1) | ACCOUNT_3 | Merkl | `merkl` | $0.4048 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_1 | Merkl | `merkl` | $0.3433 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Balancer V2 | `balancer2` | $0.1020 | Yes (`Balancer V3`) |

### 4.2 — Supported protocol items with no NAV match

_The protocol IS in `supportedDeBankProtocols` but no NAV position matched the item. Possible causes: adapter not deployed on this chain, token not in NAV registry, price feed missing, or account has zero balance in this market._

| Chain | Account | Protocol | DeBank ID | Item | Value | Hint |
|---|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Sky | `sky` | Savings USDS (`0xa3931d71…`) | $9.330M | No `sky` protocol adapter, but USDS is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | LIDO | `lido` | wstETH (`0x7f39c581…`) | $355,650.82 | No `lido` protocol adapter, but stETH is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Spark | `spark` | Spark Savings USDC (`0x28b3a8fb…`) | $351,386.39 | No `spark` protocol adapter, but USDC is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_2 | Kelp DAO | `kelpdao` | Locked (`0x62de59c0…`) | $292,567.26 | No `kelpdao` protocol adapter, but stETH is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | LIDO | `lido` | wstETH (`0x7f39c581…`) | $251.5505 | No `lido` protocol adapter, but stETH is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Aave V3 | `aave3` | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | $232.6242 | Adapter registered but no matching position (zero balance or position identity mismatch) |
| Mainnet (1) | ACCOUNT_2 | LIDO | `lido` | wstETH (`0x7f39c581…`) | $104.0764 | No `lido` protocol adapter, but stETH is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Convex | `convex` | Staked (`0x49b4d1df…`) | $9.0835 | No NAV adapter/feed registered for `convex` on chain 1 |
| Mainnet (1) | ACCOUNT_1 | Sky | `sky` | Savings USDS (`0xa3931d71…`) | $5.0715 | No `sky` protocol adapter, but USDS is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_1 | Ethena | `ethena` | sUSDe (`0x9d39a5de…`) | $4.5047 | No `ethena` protocol adapter, but USDe is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |

