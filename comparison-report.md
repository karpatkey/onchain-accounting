# NAV vs DeBank — Detailed Comparison Report

Generated: 2026-08-12 03:14 UTC  
Tolerance: 1%

DeBank anchor: read from `test/integration/debank-cache/` (no live API call).  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25735412 |
| optimism (10) | 155448290 |
| gnosis (100) | 47678791 |
| base (8453) | 49853005 |
| arbitrum (42161) | 493597721 |

## Drift summary

**12 of 16 account-chain pairs within 1% tolerance.** ⚠ 4 over tolerance — see per-account section for breakdown.

| Account | Chain | │ | NAV | │ | DeBank filtered | Drift |  |
|---|---|:---:|---:|:---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | │ | $301.9765 | │ | $276.3203 | +9.28% | ⚠️ |
| ACCOUNT_1 | gnosis | │ | $5.0176 | │ | $5.0195 | -0.04% | ✅ |
| ACCOUNT_1 | base | │ | $9.9995 | │ | $10.0094 | -0.10% | ✅ |
| ACCOUNT_1 | arbitrum | │ | $10.0633 | │ | $10.0683 | -0.05% | ✅ |
| ACCOUNT_2 | mainnet | │ | $932,089.77 | │ | $933,136.28 | -0.11% | ✅ |
| ACCOUNT_2 | gnosis | │ | $0.0100 | │ | $0.0100 | -0.02% | ✅ |
| ACCOUNT_3 | mainnet | │ | $222.1509 | │ | $222.3934 | -0.11% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | │ | $14,333.10 | │ | $14,348.40 | -0.11% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | │ | $8.236M | │ | $8.240M | -0.04% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | │ | $3,387.91 | │ | $3,394.55 | -0.20% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | │ | $1.875M | │ | $1.877M | -0.09% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | │ | $576,230.58 | │ | $576,737.87 | -0.09% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | │ | $16.353M | │ | $16.628M | -1.66% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | │ | $77.320M | │ | $77.366M | -0.06% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | │ | $6.074M | │ | $6.438M | -5.65% | ⚠️ |
| ACCOUNT_12_MAINNET_UNISWAP_V3_LP | mainnet | │ | $35.6005 | │ | $45.2988 | -21.41% | ⚠️ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $301.9765 | DeBank filtered: $276.3203 | Drift: +9.28% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $157.8185 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.189400 | $10.1976 | │ | $183.2796 | Morpho | Supply USDC 10.188807 | $10.1868 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.187923 | $10.1961 | │ | | Morpho | Supply USDC 10.188723 | $10.1867 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.075110 | $5.0706 | │ | | Morpho | Supply USDT 5.075454 | $5.0705 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 111.967845 | $112.0575 | │ | | Morpho | Supply USDC 137.583801 | $137.5567 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.187836 | $10.1960 | │ | | Morpho | Supply USDC 10.190295 | $10.1883 |
| | │ | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.092642 | $10.1007 | │ | | Morpho | Supply USDC 10.092642 | $10.0907 |
| Aave V3<br>`aave3` | │ | $52.7713 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.8700 | │ | $52.8421 | Aave V3 | Staking GHO 10.000000 | $9.9853 |
| | │ | | Lending (`0x87870bca…`) | supply USDC 9.168181 + supply USDT 10.156879 + supply USDe 5.046732 + supply sUSDe 3.000000 + supply RLUSD 14.766989 + reward USDS 0.008929 | $42.9013 | │ | | Aave V3 | Collateral USDC 9.168869 | $9.1671 |
| | │ | | | | | │ | | Aave V3 | Collateral USDT 10.157473 | $10.1475 |
| | │ | | | | | │ | | Aave V3 | Collateral USDe 5.046935 | $5.0457 |
| | │ | | | | | │ | | Aave V3 | Collateral sUSDe 3.000000 | $3.7281 |
| | │ | | | | | │ | | Aave V3 | Supply RLUSD 14.767809 | $14.7685 |
| Balancer V3<br>`balancer3` | │ | $6.9943 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 2.050898 + supply GHO 4.222340 + supply USDC 0.777177 | $6.9943 | │ | $7.0420 | Balancer V3 | Supply USDT 2.064383 | $2.0624 |
| | │ | | | | | │ | | Balancer V3 | Supply GHO 4.208119 | $4.2019 |
| | │ | | | | | │ | | Balancer V3 | Supply USDC 0.777897 | $0.7777 |
| cap<br>`capapp` | │ | $5.1320 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.127930 | $5.1320 | │ | $4.9890 | Cap | Supply USDC 4.990009 | $4.9890 |
| Sky<br>`sky` | │ | $5.1009 | Savings USDS (`0xa3931d71…`) | supply USDS 5.101505 | $5.1009 | │ | — | — | — | — |
| Ethena<br>`ethena` | │ | $4.5371 | sUSDe (`0x9d39a5de…`) | supply USDe 4.533430 | $4.5371 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | │ | 8.905915 | $0.9870 | $8.7901 | │ | — | — | — |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | │ | 0.999922 | $1.0008 | $1.0007 | │ | — | — | — |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 9.626826 | $1.0008 | $9.6345 | │ | — | — | — |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | │ | 4.990006 | $1.0008 | $4.9939 | │ | ↑ aggregated (see protocol row) | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 4.717667 | $0.9991 | $4.7135 | │ | — | — | — |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | │ | 14.831886 | $0.9999 | $14.8302 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Merkl (`merkl`) | protocol | $0.3684 | supply: RLUSD 0.113333 ($0.1135) + MORPHO 0.022386 ($0.0443) + GHO 0.212845 ($0.2101) + USDT 0.000405 ($0.0004) + USDC 0.000153 ($0.0002) → **$0.3684** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | USDC | 9.626826 | $9.6249 |
| adapter | Wallet | USDS | 14.831886 | $14.8291 |
| adapter | Wallet | USDT | 4.717667 | $4.7130 |
| adapter | Wallet | GHO | 8.905915 | $8.8928 |
| adapter | Wallet | USDe | 0.999922 | $0.9997 |
| adapter | Wallet | sUSDe | 3.647417 | $4.5326 |
| adapter | Wallet | sUSDS | 4.612968 | $5.1008 |
| adapter | Cap | USDC | 5.128612 | $5.1276 |

### Gnosis (chain 100)

**NAV: $5.0176 | DeBank filtered: $5.0195 | Drift: -0.04% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $2.0221 | Lending (`0xb5020155…`) | supply WXDAI 2.022368 | $2.0221 | │ | $2.0218 | Aave V3 | Collateral WXDAI 2.022423 | $2.0218 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | │ | 0.998493 | $0.9995 | $0.9980 | │ | — | — | — |
| xDai | `xdai` | │ | 1.999518 | $0.9999 | $1.9993 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | xDAI | 1.999518 | $1.9989 |
| adapter | Wallet | GHO | 0.998493 | $0.9970 |

### Base (chain 8453)

**NAV: $9.9995 | DeBank filtered: $10.0094 | Drift: -0.10% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | │ | 10.001207 | $1.0008 | $10.0092 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | USDC | 10.001207 | $9.9993 |

### Arbitrum (chain 42161)

**NAV: $10.0633 | DeBank filtered: $10.0683 | Drift: -0.05% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $2.0374 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.021131 | $1.0219 | │ | $2.0357 | Morpho | Supply USDC 1.021264 | $1.0211 |
| | │ | | Deposit (`0x6c247b1f…`) | supply USDC 1.014609 | $1.0154 | │ | | Morpho | Supply USDC 1.014698 | $1.0145 |
| Aave V3<br>`aave3` | │ | $1.0001 | Lending (`0x794a6135…`) | supply USDC 2.025974 + borrow GHO 1.027992 | $1.0001 | │ | $0.9992 | Aave V3 | Collateral USDC 2.026117 | $2.0258 |
| | │ | | | | | │ | | Aave V3 | Borrow GHO 1.028178 | $-1.0267 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| syrupUSDC | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | │ | 1.732523 | $1.1773 | $2.0397 | │ | — | — | — |
| GHO | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | │ | 0.956018 | $0.9995 | $0.9556 | │ | — | — | — |
| USDC | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | │ | 2.004327 | $1.0008 | $2.0059 | │ | — | — | — |
| USD₮0 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | │ | 2.031070 | $0.9991 | $2.0293 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | USDC | 2.004327 | $2.0040 |
| adapter | Wallet | USD₮0 | 2.031070 | $2.0292 |
| adapter | Wallet | GHO | 0.956018 | $0.9546 |
| adapter | Wallet | syrupUSDC | 1.732523 | $2.0403 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $932,089.77 | DeBank filtered: $933,136.28 | Drift: -0.11% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $559,272.27 | Lending (`0x87870bca…`) | supply WETH 0.011643 + supply rsETH 2,013.1002 + borrow WETH 1,872.7513 | $559,272.27 | │ | $558,446.91 | Aave V3 | Collateral WETH 0.011643 | $21.9033 |
| | │ | | | | | │ | | Aave V3 | Collateral rsETH 2,013.1002 | $4.082M |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 1,872.7824 | $-3.523M |
| Spark<br>`spark` | │ | $369,443.54 | Lending (`0xc13e21b6…`) | supply wstETH 825.705245 + borrow WETH 828.783955 | $369,443.54 | │ | $369,227.07 | Spark | Collateral wstETH 825.705245 | $1.928M |
| | │ | | | | | │ | | Spark | Borrow WETH 828.797258 | $-1.559M |
| LIDO<br>`lido` | │ | $1,746.16 | wstETH (`0x7f39c581…`) | supply stETH 0.927272 | $1,746.16 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.002564 | $1,883.32 | $4.8294 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Kelp DAO (`kelpdao`) | protocol | $2,669.48 | supply ETH 1.417432 |
| GEAR | wallet token | $29.1700 | `0xba3335588d9403515223f109edc4eb7269a9ab5d` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.002564 | $4.8241 |
| adapter | Wallet | wstETH | 0.746932 | $1,744.43 |
| adapter | Wallet | rsETH | 1.315177 | $2,666.54 |

### Gnosis (chain 100)

**NAV: $0.0100 | DeBank filtered: $0.0100 | Drift: -0.02% ✅**

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $222.1509 | DeBank filtered: $222.3934 | Drift: -0.11% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Balancer V3<br>`balancer3` | │ | $66.3111 | Farming (`0x62a66eb9…`) | supply WETH 0.017229 + supply ETH 0.017939 + reward BAL 0.757598 | $66.3111 | │ | $66.2386 | Balancer V3 | Staking WETH 0.017229 | $32.4115 |
| | │ | | | | | │ | | Balancer V3 | Rewards BAL 0.757598 | $0.0793 |
| | │ | | | | | │ | | Balancer V3 | Staking rETH 0.015341 | $33.7478 |
| Aave V3<br>`aave3` | │ | $49.3819 | Lending (`0x4e033931…`) | supply wstETH 0.005001 + supply WETH 0.005039 + supply ezETH 0.005000 + borrow WETH 0.005053 | $21.8707 | │ | $49.3310 | Aave V3 | Collateral wstETH 0.005001 | $11.6799 |
| | │ | | | | | │ | | Aave V3 | Collateral WETH 0.005040 | $9.4807 |
| | │ | | | | | │ | | Aave V3 | Collateral ezETH 0.005000 | $10.1925 |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 0.005053 | $-9.5056 |
| | │ | | Lending (`0x87870bca…`) | supply WETH 0.002980 + supply wstETH 0.009367 | $27.5112 | │ | | Aave V3 | Collateral WETH 0.002980 | $5.6070 |
| | │ | | | | | │ | | Aave V3 | Collateral wstETH 0.009367 | $21.8765 |
| Convex<br>`convex` | │ | $24.3121 | Staked (`0x5411cc58…`) | supply WETH 0.005026 + supply ETH 0.007801 + reward CRV 0.557039 + reward CVX 0.000087 | $24.3121 | │ | $24.2836 | Convex | Staking WETH 0.005221 | $9.8219 |
| | │ | | | | | │ | | Convex | Rewards CRV 0.559046 | $0.1513 |
| | │ | | | | | │ | | Convex | Rewards CVX 0.000559 | $0.0009 |
| | │ | | | | | │ | | Convex | Staking weETH 0.006907 | $14.3095 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 0.005056 | $1,883.32 | $9.5214 | │ | — | — | — |
| ETH | `eth` | │ | 0.007468 | $1,883.32 | $14.0652 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Rocket Pool (`rocketpool`) | protocol | $33.0039 | supply ETH 0.017524 |
| ether.fi (`etherfi`) | protocol | $17.0840 | supply ETH 0.009071 |
| Kelp DAO (`kelpdao`) | protocol | $8.7137 | supply ETH 0.004627 |
| Merkl (`merkl`) | protocol | $0.8388 | supply: RPL 0.547182 ($0.7877) + WETH 0.000013 ($0.0241) + ETH 0.000013 ($0.0251) + GEAR 6.174863 ($0.0020) → **$0.8388** |
| Aura Finance (`aurafinance`) | protocol | $0.0707 | supply: WETH 0.000000 ($0.0000) + ETH 0.000000 ($0.0000); rewards: BAL 0.489289 ($0.0510) + AURA 1.127894 ($0.0198) → **$0.0707** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.007468 | $14.0498 |
| adapter | Wallet | WETH | 0.005056 | $9.5110 |
| adapter | Wallet | weETH | 0.008237 | $17.0652 |
| adapter | Wallet | rETH | 0.014986 | $32.9676 |
| adapter | Wallet | rsETH | 0.004293 | $8.7041 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $14,333.10 | DeBank filtered: $14,348.40 | Drift: -0.11% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $14,346.98 | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.543924 + reward WETH 0.073993 | $14,346.98 | │ | $14,331.68 | Aave V3 | Staking WETH 7.543922 | $14,191.99 |
| | │ | | | | | │ | | Aave V3 | Rewards WETH 0.074255 | $139.6919 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.000754 | $1,883.32 | $1.4207 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.000754 | $1.4191 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.236M | DeBank filtered: $8.240M | Drift: -0.04% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Fluid<br>`fluid` | │ | $8.240M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.1019M | $5.097M | │ | $8.236M | Fluid | Supply USDT 5.1020M | $5.097M |
| | │ | | Fluid USD Coin (`0x9fb7b447…`) | supply USDC 3.1397M | $3.142M | │ | | Fluid | Supply USDC 3.1398M | $3.139M |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.085792 | $1,883.32 | $161.5746 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.085792 | $161.3968 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $3,387.91 | DeBank filtered: $3,394.55 | Drift: -0.20% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| COMP | `0x7e7d4467112689329f7e06571ed0e8cbad4910ee` | │ | 202.339341 | $16.3200 | $3,302.18 | │ | — | — | — |
| ETH | `op` | │ | 0.049048 | $1,883.32 | $92.3739 | │ | — | — | — |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.049048 | $92.2942 |
| adapter | Wallet | COMP | 202.339341 | $3,295.62 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $1.875M | DeBank filtered: $1.877M | Drift: -0.09% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $1.472M | Yield (`0x9c4ec768…`) | supply USDC 1.4711M | $1.472M | │ | $1.471M | Compound V3 | Supply USDC 1.4711M | $1.471M |
| Fluid<br>`fluid` | │ | $404,228.59 | Fluid USD Coin (`0x1a996cb5…`) | supply USDC 403,905.2044 | $404,228.59 | │ | $403,853.02 | Fluid | Supply USDC 403,913.5872 | $403,853.02 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `arb` | │ | 0.001287 | $1,883.32 | $2.4237 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Dolomite (`dolomite`) | protocol | $100,813.54 | supply: USDC 100,732.8858 ($100,813.54) → **$100,813.54** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.001287 | $2.4191 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $576,230.58 | DeBank filtered: $576,737.87 | Drift: -0.09% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $576,693.92 | Lending + Yield (`0xb125e668…`) | supply USDC 576,018.8045 + reward COMP 13.108705 | $576,693.92 | │ | $576,186.68 | Compound V3 | Supply USDC 576,081.6901 | $575,973.17 |
| | │ | | | | | │ | | Compound V3 | Rewards COMP 13.108705 | $213.5091 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `base` | │ | 0.023337 | $1,883.32 | $43.9511 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| CASHW | wallet token | $2.2755 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.023337 | $43.9035 |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $16.353M | DeBank filtered: $16.628M | Drift: -1.66% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $7.035M | kpk USDC (`0x4ef53d2c…`) | supply USDC 7.0299M | $7.035M | │ | $7.028M | Morpho | Supply USDC 7.0299M | $7.028M |
| | │ | | kpk EURC (`0xa877d5bb…`) | supply EURC 0.510139 | $0.5893 | │ | | Morpho | Supply EURC 0.510139 | $0.5885 |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 0.000016 | $0.0310 | │ | | Morpho | Supply WETH 0.000016 | $0.0310 |
| Aave V3<br>`aave3` | │ | $6.519M | Lending (`0x87870bca…`) | supply WETH 0.000024 + supply EURC 2.2115M | $2.555M | │ | $2.551M | Aave V3 | Collateral WETH 0.000024 | $0.0451 |
| | │ | | | | | │ | | Aave V3 | Supply EURC 2.2115M | $2.551M |
| | │ | | sGho (`0xe1753f2e…`) | supply GHO 4.0165M | $3.964M | │ | | — | — | — |
| LIDO<br>`lido` | │ | $886,735.60 | wstETH (`0x7f39c581…`) | supply stETH 89.809488 | $169,121.15 | │ | — | — | — | — |
| StakeWise<br>`stakewise` | │ | $545,919.64 | Lending (`0x15639e82…`) | supply ETH 290.022580 + borrow osETH 0.142333 | $545,919.64 | │ | $545,333.55 | StakeWise V3 | Staking ETH 290.031820 | $545,621.90 |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.153272 | $-288.3418 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| DAI | `0x6b175474e89094c44da98b954eedeac495271d0f` | │ | 1,210.5384 | $0.9999 | $1,210.40 | │ | — | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 152.306225 | $0.9991 | $152.1722 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| ether.fi (`etherfi`) | protocol | $1.331M | supply ETH 706.845796 |
| LIDO (`lido`) | protocol | $717,614.45 | supply ETH 381.036918 |
| Sablier (`sablier`) | protocol | $687,293.38 | supply: COW 6.5770M ($687,293.38) → **$687,293.38** |
| Uniswap V3 (`uniswap3`) | protocol | $308,758.23 | supply WETH 77.194005 + supply COW 1.5597M + reward WETH 0.093504 + reward COW 2,011.3630 |
| COW | wallet token | $255,855.33 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | wstETH | 72.342940 | $168,953.96 |
| adapter | Wallet | weETH | 641.847909 | $1.330M |
| adapter | Wallet | stETH | 381.036918 | $716,825.09 |
| adapter | Wallet | USDT | 152.306225 | $152.1570 |
| adapter | Wallet | DAI | 1,210.5384 | $1,210.25 |
| adapter | Wallet | sGho | 3.9759M | $4.011M |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $77.320M | DeBank filtered: $77.366M | Drift: -0.06% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| StakeWise<br>`stakewise` | │ | $17.502M | Lending (`0xac0f906e…`) | supply ETH 9,292.9664 + borrow osETH 0.000006 | $17.502M | │ | $17.484M | StakeWise V3 | Staking ETH 9,293.5682 | $17.484M |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.000006 | $-0.0113 |
| Fluid<br>`fluid` | │ | $13.440M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 1.0155M | $1.015M | │ | $13.460M | Fluid | Supply USDT 1.0155M | $1.015M |
| | │ | | Fluid Gho Token (`0x6a29a46e…`) | supply GHO 2.5095M | $2.477M | │ | | Fluid | Supply GHO 2.5095M | $2.506M |
| | │ | | Fluid USD Coin (`0x9fb7b447…`) | supply USDC 9.9411M | $9.949M | │ | | Fluid | Supply USDC 9.9414M | $9.939M |
| Morpho<br>`morpho` | │ | $7.531M | kpk USDC (`0x4ef53d2c…`) | supply USDC 7.5246M | $7.531M | │ | $7.523M | Morpho | Supply USDC 7.5246M | $7.523M |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 0.000112 | $0.2101 | │ | | Morpho | Supply WETH 0.000112 | $0.2098 |
| Aave V3<br>`aave3` | │ | $2.503M | Lending (`0x87870bca…`) | supply USDC 2.5013M + reward USDS 0.435315 | $2.503M | │ | $2.501M | Aave V3 | Collateral USDC 2.5015M | $2.501M |
| Sky<br>`sky` | │ | $2.008M | Savings USDS (`0xa3931d71…`) | supply USDS 2.0084M | $2.008M | │ | — | — | — | — |
| LIDO<br>`lido` | │ | $1.931M | wstETH (`0x7f39c581…`) | supply stETH 0.151329 | $284.9683 | │ | — | — | — | — |
| Compound V3<br>`compound3` | │ | $1.502M | Lending + Yield (`0xc3d688b6…`) | supply USDC 1.5008M + reward COMP 2.892238 | $1.502M | │ | $1.501M | Compound V3 | Supply USDC 1.5008M | $1.501M |
| | │ | | | | | │ | | Compound V3 | Rewards COMP 2.887423 | $47.0367 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 195.800000 | $1,883.32 | $368,754.06 | │ | — | — | — |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | │ | 6.165847 | $0.9999 | $6.1652 | │ | — | — | — |
| ETH | `eth` | │ | 43.633973 | $1,883.32 | $82,176.73 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| ether.fi (`etherfi`) | protocol | $15.450M | supply ETH 8,203.4837 |
| Stader (`stader`) | protocol | $13.393M | supply ETH 7,111.5421 |
| LIDO (`lido`) | protocol | $1.930M | supply ETH 1,024.9069 |
| Stader (`stader`) | protocol | $1.655M | supply ETH 878.943314 |
| Merkl (`merkl`) | protocol | $4,127.69 | supply: GHO 4,182.0539 ($4,127.69) → **$4,127.69** |
| Uniswap V3 (`uniswap3`) | protocol | $35.7818 | supply WETH 0.000043 + supply ETH 0.017085 + reward WETH 0.000925 + reward ETH 0.000947 |
| Balancer V2 (`balancer2`) | protocol | $0.1010 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1010) → **$0.1010** |
| HEX | wallet token | $3.0408 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 43.633973 | $82,086.34 |
| adapter | Wallet | WETH | 195.800000 | $368,348.44 |
| adapter | Wallet | wstETH | 0.121897 | $284.6866 |
| adapter | Wallet | weETH | 7,449.1338 | $15.433M |
| adapter | Wallet | ETHx | 6,495.0655 | $13.379M |
| adapter | Wallet | stETH | 1,024.9682 | $1.928M |
| adapter | Wallet | USDS | 6.165847 | $6.1647 |
| adapter | Wallet | sUSDS | 1.8161M | $2.008M |
| adapter | Stader | WETH | 878.943314 | $1.654M |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $6.074M | DeBank filtered: $6.438M | Drift: -5.65% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $2.317M | kpk USDC (`0x4ef53d2c…`) | supply USDC 1.7507M | $1.752M | │ | $2.315M | Morpho | Supply USDC 1.7508M | $1.750M |
| | │ | | kpk USDC Yield (`0xd5cce260…`) | supply USDC 564,554.3817 | $565,006.39 | │ | | Morpho | Supply USDC 564,610.4261 | $564,499.12 |
| Aave V2<br>`aave2` | │ | $1.740M | Staked (`0x4da27a54…`) | supply AAVE 19,549.3993 + reward AAVE 24.915429 | $1.740M | │ | $1.760M | Aave V3 | Staking AAVE 19,549.3993 | $1.725M |
| | │ | | | | | │ | | Aave V3 | Rewards AAVE 25.159832 | $2,219.64 |
| | │ | | Lending (`0x7d2768de…`) | supply BAL 58.491559 | $6.0929 | │ | | Aave V3 | Supply BAL 320,440.6370 | $33,545.31 |
| Aave V3<br>`aave3` | │ | $511,701.78 | Lending (`0x87870bca…`) | supply USDC 4,809.7122 + supply BAL 320,439.2424 | $38,192.77 | │ | $4,809.01 | Aave V3 | Collateral USDC 4,809.9541 | $4,809.01 |
| | │ | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 233.805111 | $230.7656 | │ | | — | — | — |
| | │ | | sGho (`0xe1753f2e…`) | supply GHO 479,511.8999 | $473,278.25 | │ | | — | — | — |
| Spark<br>`spark` | │ | $353,422.92 | Spark Savings USDC (`0x28b3a8fb…`) | supply USDC 353,140.1822 | $353,422.92 | │ | — | — | — | — |
| StakeWise<br>`stakewise` | │ | $338,221.87 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.7053 | │ | $337,852.72 | StakeWise V3 | Staking ETH 179.589640 | $337,852.72 |
| Compound V3<br>`compound3` | │ | $74.0025 | Lending + Yield (`0xc3d688b6…`) | supply USDC 1.582937 + reward COMP 4.437398 | $74.0025 | │ | $73.8688 | Compound V3 | Supply USDC 1.583014 | $1.5827 |
| | │ | | | | | │ | | Compound V3 | Rewards COMP 4.437398 | $72.2861 |
| Uniswap V3<br>`uniswap3` | │ | $3.8676 | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $3.8676 | │ | $3.8637 | Uniswap V3 | Supply WETH 0.001972 | $3.7089 |
| | │ | | | | | │ | | Uniswap V3 | Fees WBTC 0.000002 | $0.1049 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.000027 | $0.0499 |
| | │ | | | | | │ | | Uniswap V3 | Supply WETH 0.000000 | $0.0000 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.000000 | $0.0000 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | │ | 2.4916M | $0.1042 | $259,542.89 | │ | — | — | — |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 27.593488 | $1,883.32 | $51,967.37 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| ether.fi (`etherfi`) | protocol | $727,620.29 | supply ETH 386.349793 |
| StakeWise (`stakewise`) | protocol | $338,213.99 | supply ETH 179.583918 |
| Rocket Pool (`rocketpool`) | protocol | $138,070.10 | supply ETH 73.312075 |
| Balancer V2 (`balancer2`) | protocol | $26,757.80 | supply: BAL 101,455.6738 ($10,568.34) + WETH 8.596238 ($16,189.47) → **$26,757.80** |
| Across V2 (`acrocc_v2`) | protocol | $8,659.41 | supply: BAL 83,130.0746 ($8,659.41) → **$8,659.41** |
| Polygon Staking (`polygon_staking`) | protocol | $8,017.17 | supply: POL 106,114.2338 ($7,970.78); rewards: POL 617.602725 ($46.3913) → **$8,017.17** |
| Merkl (`merkl`) | protocol | $7.7782 | supply: GHO 7.880685 ($7.7782) → **$7.7782** |
| StakeWise (`stakewise`) | protocol | $7.1816 | supply ETH 0.003813 |
| Uniswap V3 (`uniswap3`) | protocol | $4.0389 | supply WETH 0.000005 + supply ETH 0.001928 + reward WETH 0.000105 + reward ETH 0.000107 |
| Multichain (`multichain`) | protocol | $2.2046 | supply: BAL 21.164100 ($2.2046) → **$2.2046** |
| Compound (`compound`) | protocol | $2.0636 | supply: DAI 1.132199 ($1.1321) + AAVE 0.010451 ($0.9292); rewards: COMP 0.000146 ($0.0024) → **$2.0636** |
| COW | wallet token | $161,070.77 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |
| SAFE | wallet token | $76,981.53 | `0x5afe3855358e112b5647b952709e6165e1c1eeee` |
| HOPR | wallet token | $9,565.51 | `0xf5581dfefd8fb0e4aec526be659cfab1f8c781da` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | WETH | 27.593488 | $51,910.20 |
| adapter | Wallet | weETH | 350.823063 | $726,819.93 |
| adapter | Wallet | rETH | 62.694486 | $137,918.22 |
| adapter | Wallet | BAL | 2.4916M | $260,833.29 |
| adapter | Wallet | sGho | 474,691.1549 | $478,834.14 |

---

## ACCOUNT_12_MAINNET_UNISWAP_V3_LP

**Address:** `0x8d27deb2405717d649346502f52b959aab4eb3af`

### Mainnet (chain 1)

**NAV: $35.6005 | DeBank filtered: $45.2988 | Drift: -21.41% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Convex<br>`convex` | │ | $9.6610 | Staked (`0x49b4d1df…`) | supply cvxFXS 62.684670 + reward FRAX 1.860052 + reward CVX 1.434995 | $9.6610 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultBalanceAdapter` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 1.000004 | $1.0008 | $1.0008 | │ | — | — | — |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 0.003338 | $1,883.32 | $6.2864 | │ | — | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 1.714801 | $0.9991 | $1.7133 | │ | — | — | — |
| ETH | `eth` | │ | 0.014144 | $1,883.32 | $26.6374 | │ | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| espresso (`espresso`) | protocol | $46.2697 | supply: ESP 625.520000 ($46.2697) → **$46.2697** |
| Layer3 (`layer3`) | protocol | $32.7645 | supply: L3 6,323.3042 ($27.5194); rewards: L3 1,205.2075 ($5.2451) → **$32.7645** |
| Ekubo (`ekubo`) | protocol | $11.1111 | supply: EKUBO 4.006297 ($1.7286) + gEKUBO-26Q2 6.674740 ($0.0000); rewards: EKUBO 0.140899 ($0.0608) + gEKUBO-26Q2 0.183029 ($0.0000) → **$1.7894**<br>supply: ETH 0.000000 ($0.0000) + EKUBO 21.604083 ($9.3217) → **$9.3217** |
| AEVO | wallet token | $6.5718 | `0xb528edbef013aff855ac3c50b381f253af13b997` |
| EKUBO | wallet token | $0.6139 | `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Wallet | ETH | 0.014144 | $26.6081 |
| adapter | Wallet | WETH | 0.003338 | $6.2795 |
| adapter | Wallet | USDC | 1.000004 | $0.9998 |
| adapter | Wallet | USDT | 1.714801 | $1.7131 |

---

## Section 3 — Per-Adapter Granular Detail

_One table per adapter instance × account. **Amount drift** (Δ amt %) signals a balance-adapter issue. **Price drift** (Δ price %) signals a price-feed issue. If both are small but USD drift is large, check decimal/precision handling in the price computation._

_Severity: **OK** ≤1% · **WARN** 1–5% · **FAIL** >5%. Rows sorted by descending NAV USD._
_`nav_only` rows (no DeBank match) are listed in a separate subsection._

### StakeWise V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 179.589640 | 0.000374 | FAIL +47955103.64% | $1,881.25 | $1,883.32 | OK -0.11% | $337,852.72 | $0.7053 | FAIL +47902354.24% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 9,293.5682 | 9,292.9664 | OK +0.01% | $1,881.25 | $1,883.32 | OK -0.11% | $17.484M | $17.502M | OK -0.10% |
| ETH (Borrow) | − | 0.000006 | 9,292.9664 | FAIL -100.00% | $1,881.25 | $1,883.32 | OK -0.11% | $-0.0113 | $17.502M | FAIL -100.00% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.7508M | 1.7507M | OK +0.01% | $0.9998 | $1.0008 | OK -0.10% | $1.750M | $1.752M | OK -0.09% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 7.5246M | 7.5246M | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $7.523M | $7.531M | OK -0.10% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 7.0299M | 7.0299M | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $7.028M | $7.035M | OK -0.10% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.190295 | 10.187836 | OK +0.02% | $0.9998 | $1.0008 | OK -0.10% | $10.1883 | $10.1960 | OK -0.08% |

### Fluid — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 9.9414M | 9.9411M | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $9.939M | $9.949M | OK -0.10% |

#### ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 3.1398M | 3.1397M | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $3.139M | $3.142M | OK -0.10% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Supply) | + | 320,440.6370 | 58.491559 | FAIL +547740.82% | $0.1047 | $0.1042 | OK +0.50% | $33,545.31 | $6.0929 | FAIL +550464.60% |
| USDC (Collateral) | + | 4,809.9541 | 4,809.7122 | OK +0.01% | $0.9998 | $1.0008 | OK -0.10% | $4,809.01 | $4,813.56 | OK -0.09% |

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.009367 | 0.009367 | OK +0.00% | $2,335.46 | $2,337.77 | OK -0.10% | $21.8765 | $21.8982 | OK -0.10% |
| WETH (Collateral) | + | 0.002980 | 0.002980 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $5.6070 | $5.6130 | OK -0.11% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 2.5015M | 2.5013M | OK +0.01% | $0.9998 | $1.0008 | OK -0.10% | $2.501M | $2.503M | OK -0.09% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| EURC (Supply) | + | 2.2115M | 2.2115M | OK +0.00% | $1.1536 | $1.1551 | OK -0.13% | $2.551M | $2.555M | OK -0.13% |
| WETH (Collateral) | + | 0.000024 | 0.000024 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $0.0451 | $0.0451 | OK -0.11% |

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| rsETH (Collateral) | + | 2,013.1002 | 2,013.1002 | OK +0.00% | $2,027.52 | $2,029.82 | OK -0.11% | $4.082M | $4.086M | OK -0.11% |
| WETH (Borrow) | − | 1,872.7824 | 1,872.7513 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $-3.523M | $3.527M | FAIL -199.89% |
| WETH (Collateral) | + | 0.011643 | 0.011643 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $21.9033 | $21.9272 | OK -0.11% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| RLUSD (Supply) | + | 14.767809 | 14.766989 | OK +0.01% | $1.0000 | $1.0013 | OK -0.13% | $14.7685 | $14.7862 | OK -0.12% |
| USDT (Collateral) | + | 10.157473 | 10.156879 | OK +0.01% | $0.9990 | $0.9991 | OK -0.01% | $10.1475 | $10.1479 | OK -0.00% |
| USDC (Collateral) | + | 9.168869 | 9.168181 | OK +0.01% | $0.9998 | $1.0008 | OK -0.10% | $9.1671 | $9.1755 | OK -0.09% |
| USDe (Collateral) | + | 5.046935 | 5.046732 | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $5.0457 | $5.0508 | OK -0.10% |
| sUSDe (Collateral) | + | 3.000000 | 3.000000 | OK +0.00% | $1.2427 | $1.2440 | OK -0.10% | $3.7281 | $3.7320 | OK -0.10% |

### Fluid — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 1.0155M | 1.0155M | OK +0.00% | $0.9990 | $0.9991 | OK -0.01% | $1.015M | $1.015M | OK -0.01% |

#### ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 5.1020M | 5.1019M | OK +0.00% | $0.9990 | $0.9991 | OK -0.01% | $5.097M | $5.097M | OK -0.01% |

### Spark — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 825.705245 | 825.705245 | OK +0.00% | $2,335.46 | $2,337.77 | OK -0.10% | $1.928M | $1.930M | OK -0.10% |
| WETH (Borrow) | − | 828.797258 | 828.783955 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $-1.559M | $1.561M | FAIL -199.89% |

### Fluid — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Supply) | + | 2.5095M | 2.5095M | OK +0.00% | $0.9985 | $0.9870 | WARN +1.17% | $2.506M | $2.477M | WARN +1.17% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| AAVE (Staking) | + | 19,549.3993 | 19,549.3993 | OK +0.00% | $88.2214 | $88.9100 | OK -0.77% | $1.725M | $1.738M | OK -0.77% |
| AAVE (Rewards) | + | 25.159832 | 24.915429 | OK +0.98% | $88.2214 | $88.9100 | OK -0.77% | $2,219.64 | $2,215.23 | OK +0.20% |

### Compound V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| COMP (Rewards) | + | 4.437398 | 4.437398 | OK +0.00% | $16.2902 | $16.3200 | OK -0.18% | $72.2861 | $72.4183 | OK -0.18% |
| USDC (Supply) | + | 1.583014 | 1.582937 | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $1.5827 | $1.5842 | OK -0.09% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.5008M | 1.5008M | OK -0.00% | $0.9998 | $1.0008 | OK -0.10% | $1.501M | $1.502M | OK -0.10% |
| COMP (Rewards) | + | 2.887423 | 2.892238 | OK -0.17% | $16.2902 | $16.3200 | OK -0.18% | $47.0367 | $47.2013 | OK -0.35% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 564,610.4261 | 564,554.3817 | OK +0.01% | $0.9998 | $1.0008 | OK -0.10% | $564,499.12 | $565,006.39 | OK -0.09% |

### StakeWise V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 290.031820 | 290.022580 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $545,621.90 | $546,205.33 | OK -0.11% |
| ETH (Borrow) | − | 0.153272 | 290.022580 | FAIL -99.95% | $1,881.25 | $1,883.32 | OK -0.11% | $-288.3418 | $546,205.33 | FAIL -100.05% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_4_UMBRELLA (`0x13ce0c…5f86df`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Staking) | + | 7.543922 | 7.543924 | OK -0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $14,191.99 | $14,207.62 | OK -0.11% |
| WETH (Rewards) | + | 0.074255 | 0.073993 | OK +0.35% | $1,881.25 | $1,883.32 | OK -0.11% | $139.6919 | $139.3517 | OK +0.24% |

### Morpho — Mainnet (chain 1) — `0xd9e34b1eed…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 137.583801 | 111.967845 | FAIL +22.88% | $0.9998 | $1.0008 | OK -0.10% | $137.5567 | $112.0575 | FAIL +22.76% |

### Balancer V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| rETH (Staking) | + | 0.015341 | — | — | $2,199.85 | — | — | $33.7478 | — | — |
| WETH (Staking) | + | 0.017229 | 0.017229 | OK -0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $32.4115 | $32.4473 | OK -0.11% |
| BAL (Rewards) | + | 0.757598 | 0.757598 | OK -0.00% | $0.1047 | $0.1042 | OK +0.50% | $0.0793 | $0.0789 | OK +0.50% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.005001 | 0.005001 | OK +0.00% | $2,335.46 | $2,337.77 | OK -0.10% | $11.6799 | $11.6914 | OK -0.10% |
| ezETH (Collateral) | + | 0.005000 | 0.005000 | OK +0.00% | $2,038.50 | $2,040.82 | OK -0.11% | $10.1925 | $10.2041 | OK -0.11% |
| WETH (Borrow) | − | 0.005053 | 0.005053 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $-9.5056 | $9.5157 | FAIL -199.89% |
| WETH (Collateral) | + | 0.005040 | 0.005039 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $9.4807 | $9.4909 | OK -0.11% |

### Convex — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| weETH (Staking) | + | 0.006907 | — | — | $2,071.76 | — | — | $14.3095 | — | — |
| WETH (Staking) | + | 0.005221 | 0.005026 | WARN +3.87% | $1,881.25 | $1,883.32 | OK -0.11% | $9.8219 | $9.4660 | WARN +3.76% |
| CRV (Rewards) | + | 0.559046 | 0.557039 | OK +0.36% | $0.2707 | $0.2763 | WARN -2.04% | $0.1513 | $0.1539 | WARN -1.69% |
| CVX (Rewards) | + | 0.000559 | 0.000087 | FAIL +546.16% | $1.6860 | $1.7042 | WARN -1.07% | $0.0009 | $0.0001 | FAIL +539.25% |

### Morpho — Mainnet (chain 1) — `0xb323495f7e…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.188807 | 10.189400 | OK -0.01% | $0.9998 | $1.0008 | OK -0.10% | $10.1868 | $10.1976 | OK -0.11% |

### Morpho — Mainnet (chain 1) — `0x64d65c9a2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.188723 | 10.187923 | OK +0.01% | $0.9998 | $1.0008 | OK -0.10% | $10.1867 | $10.1961 | OK -0.09% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.092642 | 10.092642 | OK +0.00% | $0.9998 | $1.0008 | OK -0.10% | $10.0907 | $10.1007 | OK -0.10% |

### Aave V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Staking) | + | 10.000000 | 10.000000 | OK +0.00% | $0.9985 | $0.9870 | WARN +1.17% | $9.9853 | $9.8700 | WARN +1.17% |

### Balancer V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Supply) | + | 4.208119 | 4.222340 | OK -0.34% | $0.9985 | $0.9870 | WARN +1.17% | $4.2019 | $4.1675 | OK +0.83% |
| USDT (Supply) | + | 2.064383 | 2.050898 | OK +0.66% | $0.9990 | $0.9991 | OK -0.01% | $2.0624 | $2.0491 | OK +0.65% |
| USDC (Supply) | + | 0.777897 | 0.777177 | OK +0.09% | $0.9998 | $1.0008 | OK -0.10% | $0.7777 | $0.7778 | OK -0.01% |

### Morpho — Mainnet (chain 1) — `0x3274643db7…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 5.075454 | 5.075110 | OK +0.01% | $0.9990 | $0.9991 | OK -0.01% | $5.0705 | $5.0706 | OK -0.00% |

### Cap — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 4.990009 | — | — | $0.9998 | — | — | $4.9890 | $5.1320 | WARN -2.79% |

### Uniswap V3 — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.001972 | 0.001972 | OK -0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $3.7089 | $3.7130 | OK -0.11% |
| WBTC (Fees) | + | 0.000002 | 0.000002 | OK +0.61% | $63,555.26 | $63,779.02 | OK -0.35% | $0.1049 | $0.1046 | OK +0.26% |
| WETH (Fees) | + | 0.000027 | 0.000027 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $0.0499 | $0.0500 | OK -0.11% |
| WETH (Supply) | + | 0.000000 | 0.000027 | FAIL -100.00% | $1,881.25 | $1,883.32 | OK -0.11% | $0.0000 | $0.0500 | FAIL -100.00% |
| WETH (Fees) | + | 0.000000 | 0.000027 | FAIL -100.00% | $1,881.25 | $1,883.32 | OK -0.11% | $0.0000 | $0.0500 | FAIL -100.00% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| EURC (Supply) | + | 0.510139 | 0.510139 | OK +0.00% | $1.1536 | $1.1551 | OK -0.13% | $0.5885 | $0.5893 | OK -0.13% |

### Morpho — Mainnet (chain 1) — `0x0000000000…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.000112 | 0.000112 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $0.2098 | $0.2101 | OK -0.11% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.000016 | 0.000016 | OK +0.00% | $1,881.25 | $1,883.32 | OK -0.11% | $0.0310 | $0.0310 | OK -0.11% |

### Aave V3 — Gnosis (chain 100) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WXDAI (Collateral) | + | 2.022423 | 2.022368 | OK +0.00% | $0.9997 | $0.9999 | OK -0.02% | $2.0218 | $2.0221 | OK -0.02% |

### Compound V3 — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.4711M | 1.4711M | OK +0.00% | $0.9999 | $1.0008 | OK -0.09% | $1.471M | $1.472M | OK -0.09% |

### Fluid — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 403,913.5872 | 403,905.2044 | OK +0.00% | $0.9999 | $1.0008 | OK -0.09% | $403,853.02 | $404,228.59 | OK -0.09% |

### Aave V3 — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 2.026117 | 2.025974 | OK +0.01% | $0.9999 | $1.0008 | OK -0.09% | $2.0258 | $2.0276 | OK -0.09% |
| GHO (Borrow) | − | 1.028178 | 1.027992 | OK +0.02% | $0.9985 | $0.9995 | OK -0.10% | $-1.0267 | $1.0275 | FAIL -199.92% |

### Morpho — Arbitrum (chain 42161) — `0x0000000000…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.021264 | 1.021131 | OK +0.01% | $0.9999 | $1.0008 | OK -0.09% | $1.0211 | $1.0219 | OK -0.08% |

### Morpho — Arbitrum (chain 42161) — `0x77fe2f7c2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.014698 | 1.014609 | OK +0.01% | $0.9999 | $1.0008 | OK -0.09% | $1.0145 | $1.0154 | OK -0.09% |

### Compound V3 — Base (chain 8453) — `0x0000000000…`

#### ACCOUNT_8_COMPOUND_BASE (`0xa46680…623314`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 576,081.6901 | 576,018.8045 | OK +0.01% | $0.9998 | $1.0008 | OK -0.10% | $575,973.17 | $576,479.99 | OK -0.09% |
| COMP (Rewards) | + | 13.108705 | 13.108705 | OK +0.00% | $16.2876 | $16.3200 | OK -0.20% | $213.5091 | $213.9341 | OK -0.20% |

### NAV-only positions (no DeBank counterpart matched)

_These adapter positions are counted in the headline NAV but have no DeBank row. See Section 2 inline tables for rationale._

| Chain | Account | Protocol | Leg | NAV amount | NAV unit $ | NAV USD |
|---|---|---|---|---:|---:|---:|
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | weETH (Wallet) | 7,449.1338 | $2,071.76 | $15.433M |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | ETHx (Wallet) | 6,495.0655 | $2,059.81 | $13.379M |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | sGho (Wallet) | 3.9759M | $1.0087 | $4.011M |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | sUSDS (Wallet) | 1.8161M | $1.1058 | $2.008M |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | stETH (Wallet) | 1,024.9682 | $1,881.25 | $1.928M |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Stader | WETH (Supply) | 878.943314 | $1,881.25 | $1.654M |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | weETH (Wallet) | 641.847909 | $2,071.76 | $1.330M |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | weETH (Wallet) | 350.823063 | $2,071.76 | $726,819.93 |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | stETH (Wallet) | 381.036918 | $1,881.25 | $716,825.09 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | sGho (Wallet) | 474,691.1549 | $1.0087 | $478,834.14 |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | WETH (Wallet) | 195.800000 | $1,881.25 | $368,348.44 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | BAL (Wallet) | 2.4916M | $0.1047 | $260,833.29 |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | wstETH (Wallet) | 72.342940 | $2,335.46 | $168,953.96 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | rETH (Wallet) | 62.694486 | $2,199.85 | $137,918.22 |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | ETH (Wallet) | 43.633973 | $1,881.25 | $82,086.34 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Wallet | WETH (Wallet) | 27.593488 | $1,881.25 | $51,910.20 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Wallet | COMP (Wallet) | 202.339341 | $16.2876 | $3,295.62 |
| mainnet (1) | ACCOUNT_2 (`0x99b9f5…23768b`) | Wallet | rsETH (Wallet) | 1.315177 | $2,027.52 | $2,666.54 |
| mainnet (1) | ACCOUNT_2 (`0x99b9f5…23768b`) | Wallet | wstETH (Wallet) | 0.746932 | $2,335.46 | $1,744.43 |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | DAI (Wallet) | 1,210.5384 | $0.9998 | $1,210.25 |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | wstETH (Wallet) | 0.121897 | $2,335.46 | $284.6866 |
| mainnet (1) | ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`) | Wallet | ETH (Wallet) | 0.085792 | $1,881.25 | $161.3968 |
| mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`) | Wallet | USDT (Wallet) | 152.306225 | $0.9990 | $152.1570 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Wallet | ETH (Wallet) | 0.049048 | $1,881.69 | $92.2942 |
| base (8453) | ACCOUNT_8_COMPOUND_BASE (`0xa46680…623314`) | Wallet | ETH (Wallet) | 0.023337 | $1,881.28 | $43.9035 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | rETH (Wallet) | 0.014986 | $2,199.85 | $32.9676 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | ETH (Wallet) | 0.014144 | $1,881.25 | $26.6081 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | weETH (Wallet) | 0.008237 | $2,071.76 | $17.0652 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDS (Wallet) | 14.831886 | $0.9998 | $14.8291 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | ETH (Wallet) | 0.007468 | $1,881.25 | $14.0498 |
| base (8453) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDC (Wallet) | 10.001207 | $0.9998 | $9.9993 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDC (Wallet) | 9.626826 | $0.9998 | $9.6249 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | WETH (Wallet) | 0.005056 | $1,881.25 | $9.5110 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | GHO (Wallet) | 8.905915 | $0.9985 | $8.8928 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Wallet | rsETH (Wallet) | 0.004293 | $2,027.52 | $8.7041 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | WETH (Wallet) | 0.003338 | $1,881.25 | $6.2795 |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Wallet | USDS (Wallet) | 6.165847 | $0.9998 | $6.1647 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Cap | USDC (Staking) | 5.128612 | $0.9998 | $5.1276 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | sUSDS (Wallet) | 4.612968 | $1.1058 | $5.1008 |
| mainnet (1) | ACCOUNT_2 (`0x99b9f5…23768b`) | Wallet | ETH (Wallet) | 0.002564 | $1,881.25 | $4.8241 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDT (Wallet) | 4.717667 | $0.9990 | $4.7130 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | sUSDe (Wallet) | 3.647417 | $1.2427 | $4.5326 |
| arbitrum (42161) | ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`) | Wallet | ETH (Wallet) | 0.001287 | $1,879.81 | $2.4191 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | syrupUSDC (Wallet) | 1.732523 | $1.1776 | $2.0403 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USD₮0 (Wallet) | 2.031070 | $0.9991 | $2.0292 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDC (Wallet) | 2.004327 | $0.9999 | $2.0040 |
| gnosis (100) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | xDAI (Wallet) | 1.999518 | $0.9997 | $1.9989 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | USDT (Wallet) | 1.714801 | $0.9990 | $1.7131 |
| mainnet (1) | ACCOUNT_4_UMBRELLA (`0x13ce0c…5f86df`) | Wallet | ETH (Wallet) | 0.000754 | $1,881.25 | $1.4191 |
| mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`) | Wallet | USDC (Wallet) | 1.000004 | $0.9998 | $0.9998 |
| mainnet (1) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | USDe (Wallet) | 0.999922 | $0.9998 | $0.9997 |
| gnosis (100) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | GHO (Wallet) | 0.998493 | $0.9985 | $0.9970 |
| arbitrum (42161) | ACCOUNT_1 (`0xa57f12…fcdbc6`) | Wallet | GHO (Wallet) | 0.956018 | $0.9985 | $0.9546 |

---

## Section 4 — Coverage Gaps

_Use this section to identify missing adapter registrations, unregistered tokens, or missing price feeds._

### 4.1 — DeBank protocols with value not in `supportedDeBankProtocols`

_These show non-zero DeBank balance but are absent from the per-chain allowlist in `accounts.json`. If an NAV adapter exists for the protocol, consider adding it to `supportedDeBankProtocols` and registering the adapter on that chain._

| Chain | Account | Protocol | DeBank ID | Value | NAV adapter? |
|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | ether.fi | `etherfi` | $15.450M | Yes (`ether.fi`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Stader | `stader` | $13.393M | Yes (`Stader`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | LIDO | `lido` | $1.930M | Yes (`Lido`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Stader | `stader` | $1.655M | Yes (`Stader`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | ether.fi | `etherfi` | $1.331M | Yes (`ether.fi`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | ether.fi | `etherfi` | $727,620.29 | Yes (`ether.fi`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | LIDO | `lido` | $717,614.45 | Yes (`Lido`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Sablier | `sablier` | $687,293.38 | Yes (`Sablier`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $338,213.99 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Uniswap V3 | `uniswap3` | $308,758.23 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Rocket Pool | `rocketpool` | $138,070.10 | Yes (`Rocket Pool`) |
| Arbitrum (42161) | ACCOUNT_7_COMPOUND_ARBITRUM | Dolomite | `dolomite` | $100,813.54 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Balancer V2 | `balancer2` | $26,757.80 | Yes (`Balancer V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Across V2 | `acrocc_v2` | $8,659.41 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Polygon Staking | `polygon_staking` | $8,017.17 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Merkl | `merkl` | $4,127.69 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_2 | Kelp DAO | `kelpdao` | $2,669.48 | Yes (`Kelp DAO`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | espresso | `espresso` | $46.2697 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Uniswap V3 | `uniswap3` | $35.7818 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_3 | Rocket Pool | `rocketpool` | $33.0039 | Yes (`Rocket Pool`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Layer3 | `layer3` | $32.7645 | No |
| Mainnet (1) | ACCOUNT_3 | ether.fi | `etherfi` | $17.0840 | Yes (`ether.fi`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Ekubo | `ekubo` | $11.1111 | No |
| Mainnet (1) | ACCOUNT_3 | Kelp DAO | `kelpdao` | $8.7137 | Yes (`Kelp DAO`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Merkl | `merkl` | $7.7782 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $7.1816 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Uniswap V3 | `uniswap3` | $4.0389 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Multichain | `multichain` | $2.2046 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Compound | `compound` | $2.0636 | No |
| Mainnet (1) | ACCOUNT_3 | Merkl | `merkl` | $0.8388 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_1 | Merkl | `merkl` | $0.3684 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Balancer V2 | `balancer2` | $0.1010 | Yes (`Balancer V3`) |
| Mainnet (1) | ACCOUNT_3 | Aura Finance | `aurafinance` | $0.0707 | No |

### 4.2 — Supported protocol items with no NAV match

_The protocol IS in `supportedDeBankProtocols` but no NAV position matched the item. Possible causes: adapter not deployed on this chain, token not in NAV registry, price feed missing, or account has zero balance in this market._

| Chain | Account | Protocol | DeBank ID | Item | Value | Hint |
|---|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Aave V3 | `aave3` | sGho (`0xe1753f2e…`) | $3.964M | Adapter registered but no matching position (zero balance or position identity mismatch) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Sky | `sky` | Savings USDS (`0xa3931d71…`) | $2.008M | No `sky` protocol adapter, but USDS is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Aave V3 | `aave3` | sGho (`0xe1753f2e…`) | $473,278.25 | Adapter registered but no matching position (zero balance or position identity mismatch) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Spark | `spark` | Spark Savings USDC (`0x28b3a8fb…`) | $353,422.92 | No `spark` protocol adapter, but USDC is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | LIDO | `lido` | wstETH (`0x7f39c581…`) | $169,121.15 | No `lido` protocol adapter, but stETH is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_2 | LIDO | `lido` | wstETH (`0x7f39c581…`) | $1,746.16 | No `lido` protocol adapter, but stETH is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | LIDO | `lido` | wstETH (`0x7f39c581…`) | $284.9683 | No `lido` protocol adapter, but stETH is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Aave V3 | `aave3` | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | $230.7656 | Adapter registered but no matching position (zero balance or position identity mismatch) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Convex | `convex` | Staked (`0x49b4d1df…`) | $9.6610 | No NAV adapter/feed registered for `convex` on chain 1 |
| Mainnet (1) | ACCOUNT_1 | Sky | `sky` | Savings USDS (`0xa3931d71…`) | $5.1009 | No `sky` protocol adapter, but USDS is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |
| Mainnet (1) | ACCOUNT_1 | Ethena | `ethena` | sUSDe (`0x9d39a5de…`) | $4.5371 | No `ethena` protocol adapter, but USDe is/are NAV-priced: the value is already in the NAV total when held in-wallet (see this account's wallet-token rows) — a true gap only if locked in the protocol contract (withdrawal queue / savings vault) |

