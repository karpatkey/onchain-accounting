# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-07 01:25 UTC  
Tolerance: 1%

Debank anchor: from `accounts.json.expected.<cid>.debankUsd` (captured at forge-snapshot time). Re-run with `--refresh-debank` to recapture against current chain state.  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25039760 |
| optimism (10) | 151258581 |
| gnosis (100) | 46044289 |
| base (8453) | 45663295 |
| arbitrum (42161) | 460162633 |

## Drift summary

**13 of 15 account-chain pairs within 1% tolerance.** ⚠ 2 over tolerance — see per-account section for breakdown.

| Account | Chain | NAV | Debank filtered | Drift |  |
|---|---|---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | $181.1392 | $180.1047 | +0.57% | ✅ |
| ACCOUNT_1 | gnosis | $5.0067 | $5.0060 | +0.01% | ✅ |
| ACCOUNT_1 | base | $9.9998 | $10.0023 | -0.03% | ✅ |
| ACCOUNT_1 | arbitrum | $10.0258 | $10.0261 | -0.00% | ✅ |
| ACCOUNT_2 | mainnet | $1.132M | $1.126M | +0.53% | ✅ |
| ACCOUNT_3 | mainnet | $273.2606 | $273.3065 | -0.02% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | $176,769.77 | $176,760.42 | +0.01% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | $8.143M | $8.144M | -0.01% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | $2.766M | $2.766M | +0.02% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | $2.059M | $2.060M | -0.02% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | $823,658.24 | $823,806.75 | -0.02% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | $17.642M | $18.165M | -2.88% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | $94.548M | $94.624M | -0.08% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | $5.022M | $5.021M | +0.01% | ✅ |
| ACCOUNT_12_MAINNET_UNISWAP_V3_LP | mainnet | $856.2982 | $871.1153 | -1.70% | ⚠️ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $181.1392 | Debank filtered: $180.1047 | Drift: +0.57% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $61.5770 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.085683 | $10.0867 | Morpho Vault | supply USDC 10.085809 | $10.0838 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.089009 | $10.0900 | Morpho - wstETH/USDC | supply USDC 10.089114 | $10.0871 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.038999 | $5.0384 | Morpho - sUSDS/USDT | supply USDT 5.039074 | $5.0385 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1849 | Morpho - wstUSR/USDC | supply USDC 17.549478 | $17.5460 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.089129 | $10.0901 | Morpho - cbBTC/USDC | supply USDC 10.089231 | $10.0872 |
| | | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.085889 | $10.0869 | Morpho Vault | supply USDC 10.086028 | $10.0840 |
| Aave V3 | `aave3` | $52.5547 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.9920 | Aave V3 Safety Module | supply GHO 10.000000 | $9.9973 |
| | | | Lending (`0x87870bca…`) | supply USDC 9.083071 + supply USDT 10.085951 + supply USDe 5.024427 + supply sUSDe 3.000000 + supply RLUSD 14.672321 + reward USDS 0.008929 | $42.5627 | Aave V3 Core | supply USDC 9.083161 | $9.0813 |
| | | | | | | Aave V3 Core | supply USDT 10.086084 | $10.0849 |
| | | | | | | Aave V3 Core | supply USDe 5.024516 | $5.0226 |
| | | | | | | Aave V3 Core | supply sUSDe 3.000000 | $3.6898 |
| | | | | | | Aave V3 Core | supply RLUSD 14.672418 | $14.6730 |
| Balancer V3 | `balancer3` | $7.0015 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.670664 + supply GHO 3.603742 + supply USDC 1.729991 | $7.0015 | Balancer V3 - Aave GHO/USDT/USDC | supply USDT 1.691972 | $1.6918 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply GHO 3.601848 | $3.6009 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply USDC 1.710567 | $1.7102 |
| cap | `capapp` | $5.0610 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.060536 | $5.0610 | Cap | supply USDC 10.050654 | $10.0486 |
| Sky | `sky` | $5.0536 | Savings USDS (`0xa3931d71…`) | supply USDS 5.054104 | $5.0536 | price feed | sUSDS 4.612968 | $5.0517 |
| Ethena | `ethena` | $4.4855 | sUSDe (`0x9d39a5de…`) | supply USDe 4.487698 | $4.4855 | price feed | sUSDe 3.647417 | $4.4860 |
| Merkl | `merkl` | $0.3021 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.139162 + supply USDT 0.000056 + supply USDC 0.000058 | $0.3021 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | 8.905915 | $0.9992 | $8.8988 | price feed (wallet/Holding) | 8.905915 | $8.9035 |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | 0.999922 | $0.9995 | $0.9994 | price feed (wallet/Holding) | 0.999922 | $0.9995 |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.626826 | $1.0001 | $9.6278 | price feed (wallet/Holding) | 9.626826 | $9.6249 |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | 4.990006 | $1.0001 | $4.9905 | ↑ aggregated by Cap (see protocol row) | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 4.717667 | $0.9999 | $4.7171 | price feed (wallet/Holding) | 4.717667 | $4.7171 |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | 14.831886 | $0.9999 | $14.8304 | price feed (wallet/Holding) | 14.831886 | $14.8248 |

### Gnosis (chain 100)

**NAV: $5.0067 | Debank filtered: $5.0060 | Drift: +0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $2.0087 | Lending (`0xb5020155…`) | supply WXDAI 2.008910 | $2.0087 | Aave V3 Gnosis | supply WXDAI 2.008923 | $2.0089 |
| Gnosis | `gnosis` | $0.0000 | — | — | — | price feed | sDAI 0.000014 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | 0.998493 | $0.9995 | $0.9980 | price feed (wallet/Holding) | 0.998493 | $0.9982 |
| xDai | `xdai` | 1.999518 | $0.9999 | $1.9993 | price feed (wallet/Holding) | 1.999518 | $1.9995 |

### Base (chain 8453)

**NAV: $9.9998 | Debank filtered: $10.0023 | Drift: -0.03% ✅**

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | 10.001207 | $1.0001 | $10.0022 | price feed (wallet/Holding) | 10.001207 | $9.9997 |

### Arbitrum (chain 42161)

**NAV: $10.0258 | Debank filtered: $10.0261 | Drift: -0.00% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $2.0189 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.011000 | $1.0111 | Morpho Vault | supply USDC 1.011022 | $1.0109 |
| | | | Deposit (`0x6c247b1f…`) | supply USDC 1.007357 | $1.0075 | Morpho - sUSDS/USDC | supply USDC 1.007363 | $1.0072 |
| Aave V3 | `aave3` | $1.0024 | Lending (`0x794a6135…`) | supply USDC 2.012337 + borrow GHO 1.010053 | $1.0024 | Aave V3 Arbitrum | supply USDC 2.012356 | $2.0121 |
| | | | | | | Aave V3 Arbitrum | borrow GHO 1.010114 | $-1.0099 |
| Merkl | `merkl` | $0.0004 | — | — | — | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| syrupUSDC | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | 1.732523 | $1.1619 | $2.0130 | price feed (wallet/Holding) | 1.732523 | $2.0145 |
| GHO | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | 0.956018 | $1.0001 | $0.9561 | price feed (wallet/Holding) | 0.956018 | $0.9559 |
| USDC | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | 2.004327 | $1.0001 | $2.0045 | price feed (wallet/Holding) | 2.004327 | $2.0041 |
| USD₮0 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | 2.031070 | $0.9999 | $2.0308 | price feed (wallet/Holding) | 2.031070 | $2.0308 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.132M | Debank filtered: $1.126M | Drift: +0.53% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $1.127M | Lending (`0x87870bca…`) | supply WETH 0.011598 + supply rsETH 2,326.4202 + borrow WETH 2,001.5848 | $1.127M | Aave V3 Core | supply WETH 0.011598 | $26.9580 |
| | | | | | | Aave V3 Core | supply rsETH 2,326.4202 | $5.784M |
| | | | | | | Aave V3 Core | borrow WETH 2,001.6461 | $-4.653M |
| Kelp DAO | `kelpdao` | $729.0352 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $729.0352 | price feed | rsETH 0.292977 | $728.3957 |
| Merkl | `merkl` | $26.3597 | Rewards (`0x3ef3d8ba…`) | supply GEAR 91,169.3043 + supply ETH 0.000000 | $26.3597 | — | — | — |
| LIDO | `lido` | $0.0057 | — | — | — | price feed | wstETH 0.000002 | $0.0057 |
| | | | | | | price feed | stETH 0.000000 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.002564 | $2,326.43 | $5.9657 | price feed (wallet/Holding) | 0.002564 | $5.9605 |

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $273.2606 | Debank filtered: $273.3065 | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Balancer V3 | `balancer3` | $81.5342 | Farming (`0x62a66eb9…`) | supply WETH 0.017517 + supply ETH 0.017477 + reward BAL 0.757598 | $81.5342 | Balancer V3 - rETH/Aave WETH | supply WETH 0.017517 | $40.7167 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply BAL 0.757598 | $0.1178 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply rETH 0.015029 | $40.6235 |
| Aave V3 | `aave3` | $67.4861 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005019 + supply ezETH 0.005000 + borrow WETH 0.005025 | $26.8255 | Aave V3 Prime | supply wstETH 0.005000 | $14.3399 |
| | | | | | | Aave V3 Prime | supply WETH 0.005019 | $11.6663 |
| | | | | | | Aave V3 Prime | supply ezETH 0.005000 | $12.5195 |
| | | | | | | Aave V3 Prime | borrow WETH 0.005025 | $-11.6798 |
| | | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.059712 + borrow WETH 0.059007 | $40.6606 | Aave V3 Core | supply WETH 0.002969 | $6.9009 |
| | | | | | | Aave V3 Core | supply wstETH 0.059712 | $171.2382 |
| | | | | | | Aave V3 Core | borrow WETH 0.059010 | $-137.1630 |
| Rocket Pool | `rocketpool` | $40.5464 | rETH (`0xae78736c…`) | supply ETH 0.017427 | $40.5464 | price feed | rETH 0.014986 | $40.5080 |
| Convex | `convex` | $29.7211 | Staked (`0x5411cc58…`) | supply WETH 0.001413 + supply ETH 0.011342 + reward CRV 0.187681 + reward CVX 0.000063 | $29.7211 | Convex | supply WETH 0.001413 | $3.2843 |
| | | | | | | Convex | supply CRV 0.190810 | $0.0469 |
| | | | | | | Convex | supply weETH 0.010366 | $26.2922 |
| | | | | | | Convex | supply CVX 0.000191 | $0.0003 |
| ether.fi | `etherfi` | $20.9691 | weETH (`0xcd5fe23c…`) | supply ETH 0.009013 | $20.9691 | price feed | weETH 0.008237 | $20.8931 |
| Kelp DAO | `kelpdao` | $10.6833 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.6833 | price feed | rsETH 0.004293 | $10.6732 |
| Merkl | `merkl` | $0.2228 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000007 + supply ETH 0.000007 + supply GEAR 6.174863 + supply RPL 0.098307 | $0.2228 | Merkl | supply RPL 0.100168 | $0.1985 |
| Aura Finance | `aurafinance` | $0.0944 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.130822 | $0.0944 | Aura | supply BAL 0.489289 | $0.0761 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.002000 | $2,326.59 | $4.6532 | price feed (wallet/Holding) | 0.002000 | $4.6488 |
| ETH | `eth` | 0.007468 | $2,326.59 | $17.3757 | price feed (wallet/Holding) | 0.007468 | $17.3593 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $176,769.77 | Debank filtered: $176,760.42 | Drift: +0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $176,755.03 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 46.766070 | $66,384.28 | Aave Umbrella | supply GHO 66,390.6641 | $66,373.01 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,198.3443 + reward USDC 14.777622 | $65,219.64 | Aave Umbrella | supply USDC 65,198.2727 | $65,185.23 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,659.4291 + reward USDT 7.994772 | $27,664.10 | Aave Umbrella | supply USDT 27,659.3893 | $27,656.11 |
| | | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.514727 + reward WETH 0.001422 | $17,487.00 | Aave Umbrella | supply WETH 7.514721 | $17,467.14 |
| | | | | | | Aave Umbrella | supply USDC 17.859338 | $17.8558 |
| | | | | | | Aave Umbrella | supply USDT 9.606604 | $9.6055 |
| | | | | | | Aave Umbrella | supply WETH 0.001706 | $3.9660 |
| | | | | | | Aave Umbrella | supply GHO 56.203727 | $56.1888 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.000282 | $2,326.59 | $0.6563 | price feed (wallet/Holding) | 0.000282 | $0.6557 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.143M | Debank filtered: $8.144M | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Fluid | `fluid` | $5.047M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0478M | $5.047M | Fluid Lending | supply USDT 5.0478M | $5.047M |
| Compound V3 | `compound3` | $3.097M | Lending (`0xc3d688b6…`) | reward COMP 25.052532 | $586.7303 | Compound v3 USDC | supply COMP 25.062677 | $587.5100 |
| | | | Yield (`0xc3d688b6…`) | supply USDC 3.0960M | $3.096M | Compound v3 USDC | supply USDC 3.0960M | $3.095M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.086040 | $2,326.59 | $200.1791 | price feed (wallet/Holding) | 0.086040 | $199.9898 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.766M | Debank filtered: $2.766M | Drift: +0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $2.766M | Lending (`0x2e44e174…`) | reward COMP 38.421572 | $899.8332 | Compound v3 USDC | supply COMP 38.421572 | $901.1011 |
| | | | Yield (`0x2e44e174…`) | supply USDC 756,169.7730 | $756,245.40 | Compound v3 USDC | supply USDC 756,209.6002 | $756,112.01 |
| | | | Lending (`0x995e394b…`) | reward COMP 138.982925 | $3,254.98 | Compound v3 USDT | supply COMP 138.982925 | $3,259.57 |
| | | | Yield (`0x995e394b…`) | supply USDT 2.0055M | $2.005M | Compound v3 USDT | supply USDT 2.0056M | $2.005M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `op` | 0.049027 | $2,326.59 | $114.0662 | price feed (wallet/Holding) | 0.049027 | $113.7477 |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 WETH / Lending | COMP | 24.934844 | $584.7969 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.059M | Debank filtered: $2.060M | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $2.060M | Yield (`0x9c4ec768…`) | supply USDC 2.0593M | $2.060M | Compound v3 USDC | supply USDC 2.0594M | $2.059M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `arb` | 0.001305 | $2,327.64 | $3.0377 | price feed (wallet/Holding) | 0.001305 | $3.0282 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,658.24 | Debank filtered: $823,806.75 | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $823,752.39 | Lending (`0xb125e668…`) | reward COMP 13.108705 | $306.8748 | Compound v3 USDC | supply COMP 13.108705 | $306.1669 |
| | | | Yield (`0xb125e668…`) | supply USDC 823,363.1658 | $823,445.51 | Compound v3 USDC | supply USDC 823,425.6770 | $823,297.82 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `base` | 0.023361 | $2,327.64 | $54.3755 | price feed (wallet/Holding) | 0.023361 | $54.2523 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| CASHW | wallet token | $2.8462 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $17.642M | Debank filtered: $18.165M | Drift: -2.88% ⚠️**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $5.759M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.6530M | $2.653M | Morpho Vault | supply USDC 2.6531M | $2.653M |
| | | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2006M | $2.586M | Morpho Vault | supply EURC 2.2006M | $2.590M |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 223.238257 | $519,618.30 | Morpho Vault | supply WETH 223.244779 | $518,907.81 |
| LIDO | `lido` | $2.095M | wstETH (`0x7f39c581…`) | supply stETH 212.629265 | $493,894.21 | price feed | wstETH 172.342940 | $494,233.22 |
| | | | stETH (`0xae7ab965…`) | supply ETH 687.904751 | $1.601M | price feed | stETH 687.904751 | $1.598M |
| Uniswap V3 | `uniswap3` | $520,990.15 | #1213124 (`0xfbb81382…`) | supply WETH 54.340018 + supply COW 2.2250M + reward WETH 0.174326 + reward COW 2,771.3584 | $520,990.15 | — | — | — |
| StakeWise | `stakewise` | $552.0570 | Lending (`0x15639e82…`) | supply ETH 0.388040 + borrow osETH 0.142290 | $552.0570 | — | — | — |
| Aave V3 | `aave3` | $0.0555 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0555 | Aave V3 Core | supply WETH 0.000024 | $0.0554 |
| Compound V3 | `compound3` | $0.0014 | — | — | — | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.6573M | $1.0001 | $9.658M | price feed (wallet/Holding) | 9.6573M | $9.655M |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.540302 | $2,327.64 | $1,257.63 | price feed (wallet/Holding) | 0.540302 | $1,255.87 |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 152.306225 | $0.9999 | $152.2879 | price feed (wallet/Holding) | 152.306225 | $152.2882 |
| ETH | `eth` | 56.546754 | $2,327.64 | $131,620.49 | price feed (wallet/Holding) | 56.546754 | $131,436.68 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Sablier (`sablier`) | protocol | $1.398M | supply: COW 7.9040M ($1.398M) → **$1.398M** |
| COW | wallet token | $3.699M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $94.548M | Debank filtered: $94.624M | Drift: -0.08% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Sky | `sky` | $29.607M | Savings USDS (`0xa3931d71…`) | supply USDS 29.6099M | $29.607M | price feed | sUSDS 27.0258M | $29.596M |
| StakeWise | `stakewise` | $23.679M | Lending (`0xac0f906e…`) | supply ETH 10,173.1327 + borrow osETH 0.000006 | $23.679M | Stakewise v3 | supply ETH 10,173.1327 | $23.646M |
| Stader | `stader` | $23.627M | ETHx (`0xa35b1b31…`) | supply ETH 10,150.8265 | $23.627M | — | — | — |
| Morpho | `morpho` | $13.655M | kpk USDC (`0x4ef53d2c…`) | supply USDC 5.0715M | $5.072M | Morpho Vault | supply USDC 5.0716M | $5.071M |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 3,687.4003 | $8.583M | Morpho Vault | supply WETH 3,687.4688 | $8.571M |
| Rocket Pool | `rocketpool` | $4.070M | rETH (`0xae78736c…`) | supply ETH 1,748.5441 | $4.070M | price feed | rETH 1,503.6269 | $4.064M |
| Merkl | `merkl` | $3,571.78 | Rewards (`0x3ef3d8ba…`) | supply MORPHO 1,611.6671 | $3,571.78 | — | — | — |
| Compound V3 | `compound3` | $1,651.75 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,651.61 | Compound v3 USDS | supply COMP 70.521281 | $1,653.13 |
| | | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1409 | Compound v3 USDC | supply COMP 0.006016 | $0.1410 |
| LIDO | `lido` | $349.3295 | wstETH (`0x7f39c581…`) | supply stETH 0.150392 | $349.3295 | price feed | wstETH 0.121897 | $349.5693 |
| Uniswap V3 | `uniswap3` | $44.1133 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.001364 + supply ETH 0.015757 + reward WETH 0.000907 + reward ETH 0.000925 | $44.1133 | — | — | — |
| Aave V3 | `aave3` | $0.4353 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4353 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 3,043.7273 | $1.0001 | $3,044.03 | price feed (wallet/Holding) | 3,043.7273 | $3,043.12 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Balancer V2 (`balancer2`) | protocol | $0.1498 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1498) → **$0.1498** |
| HEX | wallet token | $1.1275 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETHx | 9,325.6655 | $23.594M |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $5.022M | Debank filtered: $5.021M | Drift: +0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| StakeWise | `stakewise` | $864,860.89 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8717 | — | — | — |
| | | | Lending (`0xac0f906e…`) | supply ETH 371.557091 | $864,851.15 | Stakewise v3 | supply ETH 371.557091 | $863,643.38 |
| | | | Staked (`0xfe2e6372…`) | supply ETH 0.003813 | $8.8760 | — | — | — |
| Rocket Pool | `rocketpool` | $169,699.92 | rETH (`0xae78736c…`) | supply ETH 72.906430 | $169,699.92 | price feed | rETH 62.694486 | $169,462.94 |
| Aave V3 | `aave3` | $49,673.82 | Lending (`0x87870bca…`) | supply BAL 320,145.0508 | $49,441.04 | Aave V3 Core | supply BAL 320,145.3426 | $49,770.45 |
| | | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 232.970494 | $232.7841 | — | — | — |
| Compound V3 | `compound3` | $105.4926 | Lending (`0xc3d688b6…`) | reward COMP 4.437373 | $103.9233 | Compound v3 USDC | supply COMP 4.437373 | $104.0193 |
| | | | | | | Compound v3 USDC | supply USDC 1.569165 | $1.5689 |
| | | | Yield (`0xc3d688b6…`) | supply USDC 1.569158 | $1.5693 | — | — | — |
| Uniswap V3 | `uniswap3` | $9.7632 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.000154 + supply ETH 0.001778 + reward WETH 0.000102 + reward ETH 0.000104 | $4.9794 | Uniswap V3 | supply WETH 0.001972 | $4.5825 |
| | | | | | | Uniswap V3 | supply WETH 0.000027 | $0.0617 |
| | | | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.7839 | — | — | — |
| LIDO | `lido` | $0.0000 | — | — | — | price feed | stETH 0.000000 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 3.5520M | $1.0001 | $3.552M | price feed (wallet/Holding) | 3.5520M | $3.551M |
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | 2.4916M | $0.1544 | $384,786.36 | price feed (wallet/Holding) | 2.4916M | $387,349.74 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Aave V2 (`aave2`) | protocol | $1.813M | supply: AAVE 19,442.9617 ($1.812M); rewards: AAVE 2.979255 ($277.6964) → **$1.813M**<br>supply: BAL 58.491558 ($9.0330) → **$9.0330** |
| Balancer V2 (`balancer2`) | protocol | $35,351.38 | supply: BAL 90,968.5381 ($14,048.57) + WETH 9.152109 ($21,302.82) → **$35,351.38** |
| Across V2 (`acrocc_v2`) | protocol | $12,834.19 | supply: BAL 83,105.1188 ($12,834.19) → **$12,834.19** |
| Multichain (`multichain`) | protocol | $3.2684 | supply: BAL 21.164100 ($3.2684) → **$3.2684** |
| Compound (`compound`) | protocol | $2.1096 | supply: DAI 1.132199 ($1.1321) + AAVE 0.010451 ($0.9741); rewards: COMP 0.000146 ($0.0034) → **$2.1096** |
| COW | wallet token | $210,088.78 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |
| POL | wallet token | $9,039.76 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000041 | $0.0943 |
| adapter | Aave V2 / Lending | BAL | 58.491558 | $9.0932 |

---

## ACCOUNT_12_MAINNET_UNISWAP_V3_LP

**Address:** `0x8d27deb2405717d649346502f52b959aab4eb3af`

### Mainnet (chain 1)

**NAV: $856.2982 | Debank filtered: $871.1153 | Drift: -1.70% ⚠️**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Uniswap V3 | `uniswap3` | $774.5393 | #1276763 (`0x4e68ccd3…`) | supply WETH 0.125413 + supply USDT 0.000000 + reward WETH 0.000360 + reward USDT 0.463805 | $293.2174 | Uniswap V3 | supply WETH 0.125413 | $291.5088 |
| | | | | | | Uniswap V3 | supply WETH 0.000360 | $0.8360 |
| | | | | | | Uniswap V3 | supply USDT 0.463805 | $0.4638 |
| | | | #1231724 (`0x88e6a0c2…`) | supply USDC 329.408450 + supply WETH 0.061437 + reward USDC 4.438156 + reward WETH 0.001907 | $481.3219 | Uniswap V3 | supply USDC 4.480173 | $4.4793 |
| | | | | | | Uniswap V3 | supply WETH 0.001933 | $4.4922 |
| | | | | | | Uniswap V3 | supply USDC 281.950792 | $281.8944 |
| | | | | | | Uniswap V3 | supply WETH 0.081775 | $190.0771 |
| Convex | `convex` | $14.1210 | Staked (`0x49b4d1df…`) | supply cvxFXS 62.684670 + reward FRAX 1.860052 + reward CVX 1.434995 | $14.1210 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 7.152868 | $0.9999 | $7.1520 | price feed (wallet/Holding) | 7.152868 | $7.1520 |
| ETH | `eth` | 0.032436 | $2,327.64 | $75.5002 | price feed (wallet/Holding) | 0.032436 | $75.3947 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Layer3 (`layer3`) | protocol | $82.9419 | supply: L3 6,323.3042 ($71.1372); rewards: L3 1,049.3095 ($11.8047) → **$82.9419** |
| espresso (`espresso`) | protocol | $43.6676 | supply: ESP 625.520000 ($43.6676) → **$43.6676** |
| Ekubo (`ekubo`) | protocol | $12.4211 | supply: EKUBO 4.006297 ($1.9324) + gEKUBO-26Q2 6.674740 ($0.0000); rewards: EKUBO 0.140899 ($0.0680) + gEKUBO-26Q2 0.183029 ($0.0000) → **$2.0004**<br>supply: ETH 0.000000 ($0.0000) + EKUBO 21.604083 ($10.4207) → **$10.4207** |
| AEVO | wallet token | $9.4525 | `0xb528edbef013aff855ac3c50b381f253af13b997` |
| EKUBO | wallet token | $0.6863 | `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` |

