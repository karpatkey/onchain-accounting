# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-07 05:22 UTC  
Tolerance: 1%

Debank anchor: from `accounts.json.expected.<cid>.debankUsd` (captured at forge-snapshot time). Re-run with `--refresh-debank` to recapture against current chain state.  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25040931 |
| optimism (10) | 151265650 |
| gnosis (100) | 46047037 |
| base (8453) | 45670365 |
| arbitrum (42161) | 460218914 |

## Drift summary

**13 of 15 account-chain pairs within 1% tolerance.** ⚠ 2 over tolerance — see per-account section for breakdown.

| Account | Chain | NAV | Debank filtered | Drift |  |
|---|---|---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | $181.2039 | $180.0934 | +0.62% | ✅ |
| ACCOUNT_1 | gnosis | $5.0067 | $5.0055 | +0.02% | ✅ |
| ACCOUNT_1 | base | $10.0004 | $10.0014 | -0.01% | ✅ |
| ACCOUNT_1 | arbitrum | $10.0260 | $10.0253 | +0.01% | ✅ |
| ACCOUNT_2 | mainnet | $1.132M | $1.136M | -0.29% | ✅ |
| ACCOUNT_3 | mainnet | $273.3638 | $274.1547 | -0.29% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | $176,782.44 | $176,793.83 | -0.01% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | $8.143M | $8.144M | -0.01% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | $2.766M | $2.766M | +0.02% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | $2.059M | $2.059M | -0.01% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | $823,726.40 | $823,799.84 | -0.01% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | $17.642M | $18.172M | -2.91% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | $94.572M | $94.701M | -0.14% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | $5.022M | $5.023M | -0.02% | ✅ |
| ACCOUNT_12_MAINNET_UNISWAP_V3_LP | mainnet | $856.6604 | $871.8867 | -1.75% | ⚠️ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $181.2039 | Debank filtered: $180.0934 | Drift: +0.62% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $61.5713 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.085683 | $10.0857 | Morpho Vault | supply USDC 10.085994 | $10.0840 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.089009 | $10.0890 | Morpho - wstETH/USDC | supply USDC 10.089268 | $10.0873 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.038999 | $5.0383 | Morpho - sUSDS/USDT | supply USDT 5.039172 | $5.0386 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1832 | Morpho - wstUSR/USDC | supply USDC 17.612518 | $17.6090 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.089129 | $10.0891 | Morpho - cbBTC/USDC | supply USDC 10.089385 | $10.0874 |
| | | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.085889 | $10.0859 | Morpho Vault | supply USDC 10.086228 | $10.0842 |
| Aave V3 | `aave3` | $52.5528 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.9920 | Aave V3 Safety Module | supply GHO 10.000000 | $9.9973 |
| | | | Lending (`0x87870bca…`) | supply USDC 9.083071 + supply USDT 10.085951 + supply USDe 5.024427 + supply sUSDe 3.000000 + supply RLUSD 14.672321 + reward USDS 0.008929 | $42.5608 | Aave V3 Core | supply USDC 9.083295 | $9.0815 |
| | | | | | | Aave V3 Core | supply USDT 10.086272 | $10.0851 |
| | | | | | | Aave V3 Core | supply USDe 5.024571 | $5.0227 |
| | | | | | | Aave V3 Core | supply sUSDe 3.000000 | $3.6898 |
| | | | | | | Aave V3 Core | supply RLUSD 14.672560 | $14.6731 |
| Balancer V3 | `balancer3` | $7.0017 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.845033 + supply GHO 3.041964 + supply USDC 2.117412 | $7.0017 | Balancer V3 - Aave GHO/USDT/USDC | supply USDT 1.848764 | $1.8485 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply GHO 3.041964 | $3.0412 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply USDC 2.113681 | $2.1133 |
| cap | `capapp` | $5.0605 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.060536 | $5.0605 | Cap | supply USDC 10.050786 | $10.0488 |
| Sky | `sky` | $5.0531 | Savings USDS (`0xa3931d71…`) | supply USDS 5.054104 | $5.0531 | price feed | sUSDS 4.612968 | $5.0518 |
| Ethena | `ethena` | $4.4850 | sUSDe (`0x9d39a5de…`) | supply USDe 4.487698 | $4.4850 | price feed | sUSDe 3.647417 | $4.4861 |
| Merkl | `merkl` | $0.3011 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.139143 + supply USDT 0.000062 + supply USDC 0.000071 | $0.3011 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | 8.905915 | $0.9992 | $8.8988 | price feed (wallet/Holding) | 8.905915 | $8.9035 |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | 0.999922 | $0.9994 | $0.9993 | price feed (wallet/Holding) | 0.999922 | $0.9995 |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.626826 | $1.0000 | $9.6268 | price feed (wallet/Holding) | 9.626826 | $9.6249 |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | 4.990006 | $1.0000 | $4.9900 | ↑ aggregated by Cap (see protocol row) | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 4.717667 | $0.9999 | $4.7171 | price feed (wallet/Holding) | 4.717667 | $4.7171 |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | 14.831886 | $0.9998 | $14.8289 | price feed (wallet/Holding) | 14.831886 | $14.8248 |

### Gnosis (chain 100)

**NAV: $5.0067 | Debank filtered: $5.0055 | Drift: +0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $2.0085 | Lending (`0xb5020155…`) | supply WXDAI 2.008910 | $2.0085 | Aave V3 Gnosis | supply WXDAI 2.008941 | $2.0090 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | 0.998493 | $0.9994 | $0.9979 | price feed (wallet/Holding) | 0.998493 | $0.9982 |
| xDai | `xdai` | 1.999518 | $0.9998 | $1.9991 | price feed (wallet/Holding) | 1.999518 | $1.9995 |

### Base (chain 8453)

**NAV: $10.0004 | Debank filtered: $10.0014 | Drift: -0.01% ✅**

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | 10.001207 | $1.0000 | $10.0012 | price feed (wallet/Holding) | 10.001207 | $10.0003 |

### Arbitrum (chain 42161)

**NAV: $10.0260 | Debank filtered: $10.0253 | Drift: +0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $2.0184 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.011000 | $1.0110 | Morpho Vault | supply USDC 1.011049 | $1.0109 |
| | | | Deposit (`0x6c247b1f…`) | supply USDC 1.007357 | $1.0074 | Morpho - sUSDS/USDC | supply USDC 1.007373 | $1.0072 |
| Aave V3 | `aave3` | $1.0023 | Lending (`0x794a6135…`) | supply USDC 2.012337 + borrow GHO 1.010053 | $1.0023 | Aave V3 Arbitrum | supply USDC 2.012385 | $2.0121 |
| | | | | | | Aave V3 Arbitrum | borrow GHO 1.010187 | $-1.0100 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| syrupUSDC | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | 1.732523 | $1.1618 | $2.0128 | price feed (wallet/Holding) | 1.732523 | $2.0148 |
| GHO | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | 0.956018 | $1.0000 | $0.9560 | price feed (wallet/Holding) | 0.956018 | $0.9558 |
| USDC | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | 2.004327 | $1.0000 | $2.0043 | price feed (wallet/Holding) | 2.004327 | $2.0040 |
| USD₮0 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | 2.031070 | $0.9999 | $2.0308 | price feed (wallet/Holding) | 2.031070 | $2.0308 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.132M | Debank filtered: $1.136M | Drift: -0.29% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $1.135M | Lending (`0x87870bca…`) | supply WETH 0.011598 + supply rsETH 2,326.4202 + borrow WETH 2,001.5848 | $1.135M | Aave V3 Core | supply WETH 0.011598 | $26.9687 |
| | | | | | | Aave V3 Core | supply rsETH 2,326.4202 | $5.786M |
| | | | | | | Aave V3 Core | borrow WETH 2,001.6740 | $-4.654M |
| Kelp DAO | `kelpdao` | $730.1382 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $730.1382 | price feed | rsETH 0.292977 | $728.6759 |
| Merkl | `merkl` | $26.4281 | Rewards (`0x3ef3d8ba…`) | supply GEAR 91,169.3043 + supply ETH 0.000000 | $26.4281 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.002564 | $2,329.95 | $5.9747 | price feed (wallet/Holding) | 0.002564 | $5.9628 |

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $273.3638 | Debank filtered: $274.1547 | Drift: -0.29% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Balancer V3 | `balancer3` | $81.6525 | Farming (`0x62a66eb9…`) | supply WETH 0.017517 + supply ETH 0.017477 + reward BAL 0.757598 | $81.6525 | Balancer V3 - rETH/Aave WETH | supply WETH 0.017517 | $40.7328 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply BAL 0.757598 | $0.1178 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply rETH 0.015029 | $40.6391 |
| Aave V3 | `aave3` | $68.0506 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005019 + supply ezETH 0.005000 + borrow WETH 0.005025 | $26.9173 | Aave V3 Prime | supply wstETH 0.005000 | $14.3454 |
| | | | | | | Aave V3 Prime | supply WETH 0.005019 | $11.6709 |
| | | | | | | Aave V3 Prime | supply ezETH 0.005000 | $12.5243 |
| | | | | | | Aave V3 Prime | borrow WETH 0.005025 | $-11.6844 |
| | | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.059712 + borrow WETH 0.059011 | $41.1332 | Aave V3 Core | supply WETH 0.002969 | $6.9036 |
| | | | | | | Aave V3 Core | supply wstETH 0.059712 | $171.3040 |
| | | | | | | Aave V3 Core | borrow WETH 0.059011 | $-137.2177 |
| Rocket Pool | `rocketpool` | $40.6049 | rETH (`0xae78736c…`) | supply ETH 0.017427 | $40.6049 | price feed | rETH 0.014986 | $40.5236 |
| Convex | `convex` | $29.7652 | Staked (`0x5411cc58…`) | supply WETH 0.001422 + supply ETH 0.011333 + reward CRV 0.191426 + reward CVX 0.000064 | $29.7652 | Convex | supply WETH 0.001422 | $3.3067 |
| | | | | | | Convex | supply CRV 0.191712 | $0.0470 |
| | | | | | | Convex | supply weETH 0.010357 | $26.2812 |
| | | | | | | Convex | supply CVX 0.000192 | $0.0003 |
| ether.fi | `etherfi` | $20.9993 | weETH (`0xcd5fe23c…`) | supply ETH 0.009013 | $20.9993 | price feed | weETH 0.008237 | $20.9011 |
| Kelp DAO | `kelpdao` | $10.6987 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.6987 | price feed | rsETH 0.004293 | $10.6773 |
| Merkl | `merkl` | $0.2231 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000007 + supply ETH 0.000007 + supply GEAR 6.174863 + supply RPL 0.098307 | $0.2231 | Merkl | supply RPL 0.102030 | $0.1981 |
| Aura Finance | `aurafinance` | $0.0946 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.130822 | $0.0946 | Aura | supply BAL 0.489289 | $0.0761 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.002000 | $2,329.95 | $4.6599 | price feed (wallet/Holding) | 0.002000 | $4.6506 |
| ETH | `eth` | 0.007468 | $2,329.95 | $17.4008 | price feed (wallet/Holding) | 0.007468 | $17.3660 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $176,782.44 | Debank filtered: $176,793.83 | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $176,794.52 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 58.072093 | $66,395.58 | Aave Umbrella | supply GHO 66,390.6641 | $66,373.01 |
| | | | | | | Aave Umbrella | supply GHO 58.937799 | $58.9221 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,199.2253 + reward USDC 18.467973 | $65,217.69 | Aave Umbrella | supply USDC 65,199.2351 | $65,186.20 |
| | | | | | | Aave Umbrella | supply USDC 18.750070 | $18.7463 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,659.8977 + reward USDT 9.922894 | $27,666.22 | Aave Umbrella | supply USDT 27,659.9022 | $27,656.63 |
| | | | | | | Aave Umbrella | supply USDT 10.069183 | $10.0680 |
| | | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.514804 + reward WETH 0.001762 | $17,515.03 | Aave Umbrella | supply WETH 7.514805 | $17,474.05 |
| | | | | | | Aave Umbrella | supply WETH 0.001788 | $4.1582 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.000282 | $2,330.19 | $0.6573 | price feed (wallet/Holding) | 0.000282 | $0.6560 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.143M | Debank filtered: $8.144M | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Fluid | `fluid` | $8.143M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0479M | $5.047M | Fluid Lending | supply USDT 5.0479M | $5.047M |
| | | | Fluid USD Coin (`0x9fb7b447…`) | supply USDC 3.0961M | $3.096M | Fluid Lending | supply USDC 3.0961M | $3.095M |
| Compound V3 | `compound3` | $584.2370 | Lending (`0xc3d688b6…`) | reward COMP 25.139287 | $584.2370 | Compound v3 USDC | supply COMP 25.139287 | $582.2299 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.086007 | $2,330.19 | $200.4120 | price feed (wallet/Holding) | 0.086007 | $199.9900 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.766M | Debank filtered: $2.766M | Drift: +0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $2.766M | Lending (`0x2e44e174…`) | reward COMP 38.421572 | $892.9173 | Compound v3 USDC | supply COMP 38.421572 | $891.0297 |
| | | | Yield (`0x2e44e174…`) | supply USDC 756,169.7730 | $756,169.77 | Compound v3 USDC | supply USDC 756,220.4810 | $756,122.89 |
| | | | Lending (`0x995e394b…`) | reward COMP 138.982925 | $3,229.96 | Compound v3 USDT | supply COMP 138.982925 | $3,223.13 |
| | | | Yield (`0x995e394b…`) | supply USDT 2.0055M | $2.005M | Compound v3 USDT | supply USDT 2.0056M | $2.005M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `op` | 0.049027 | $2,330.19 | $114.2426 | price feed (wallet/Holding) | 0.049027 | $114.0885 |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 WETH / Lending | COMP | 24.934844 | $578.2607 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.059M | Debank filtered: $2.059M | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $2.059M | Yield (`0x9c4ec768…`) | supply USDC 2.0593M | $2.059M | Compound v3 USDC | supply USDC 2.0594M | $2.059M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `arb` | 0.001305 | $2,330.19 | $3.0410 | price feed (wallet/Holding) | 0.001305 | $3.0382 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,726.40 | Debank filtered: $823,799.84 | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $823,745.15 | Lending (`0xb125e668…`) | reward COMP 13.108705 | $304.6463 | Compound v3 USDC | supply COMP 13.108705 | $304.5377 |
| | | | Yield (`0xb125e668…`) | supply USDC 823,440.5020 | $823,440.50 | Compound v3 USDC | supply USDC 823,441.6207 | $823,367.51 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `base` | 0.023361 | $2,330.19 | $54.4351 | price feed (wallet/Holding) | 0.023361 | $54.3524 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| CASHW | wallet token | $2.8523 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $17.642M | Debank filtered: $18.172M | Drift: -2.91% ⚠️**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $5.759M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.6530M | $2.653M | Morpho Vault | supply USDC 2.6531M | $2.653M |
| | | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2006M | $2.586M | Morpho Vault | supply EURC 2.2006M | $2.590M |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 223.238257 | $520,187.55 | Morpho Vault | supply WETH 223.247270 | $519,113.21 |
| LIDO | `lido` | $2.099M | wstETH (`0x7f39c581…`) | supply stETH 212.629265 | $495,594.74 | price feed | wstETH 172.342940 | $494,423.34 |
| | | | stETH (`0xae7ab965…`) | supply ETH 687.904751 | $1.603M | price feed | stETH 687.904751 | $1.597M |
| StakeWise | `stakewise` | $552.1898 | Lending (`0x15639e82…`) | supply ETH 0.388040 + borrow osETH 0.142290 | $552.1898 | — | — | — |
| Aave V3 | `aave3` | $0.0556 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0556 | Aave V3 Core | supply WETH 0.000024 | $0.0555 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.6573M | $1.0000 | $9.657M | price feed (wallet/Holding) | 9.6573M | $9.655M |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.540302 | $2,330.19 | $1,259.01 | price feed (wallet/Holding) | 0.540302 | $1,256.36 |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 152.306225 | $0.9999 | $152.2864 | price feed (wallet/Holding) | 152.306225 | $152.2882 |
| ETH | `eth` | 56.546754 | $2,330.19 | $131,764.68 | price feed (wallet/Holding) | 56.546754 | $131,487.24 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Sablier (`sablier`) | protocol | $1.405M | supply: COW 7.9040M ($1.405M) → **$1.405M** |
| Uniswap V3 (`uniswap3`) | protocol | $523,134.20 | supply WETH 54.340018 + supply COW 2.2250M + reward WETH 0.174326 + reward COW 2,771.3584 |
| COW | wallet token | $3.718M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Stakewise v3 / Vault | ETH | 0.243445 | $566.0779 |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $94.572M | Debank filtered: $94.701M | Drift: -0.14% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Sky | `sky` | $29.604M | Savings USDS (`0xa3931d71…`) | supply USDS 29.6099M | $29.604M | price feed | sUSDS 27.0258M | $29.597M |
| StakeWise | `stakewise` | $23.702M | Lending (`0xac0f906e…`) | supply ETH 10,173.1327 + borrow osETH 0.000006 | $23.702M | Stakewise v3 | supply ETH 10,173.1327 | $23.655M |
| Stader | `stader` | $23.650M | ETHx (`0xa35b1b31…`) | supply ETH 10,150.8265 | $23.650M | — | — | — |
| Morpho | `morpho` | $13.663M | kpk USDC (`0x4ef53d2c…`) | supply USDC 5.0715M | $5.071M | Morpho Vault | supply USDC 5.0717M | $5.071M |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 3,687.4003 | $8.591M | Morpho Vault | supply WETH 3,687.5099 | $8.575M |
| Rocket Pool | `rocketpool` | $4.074M | rETH (`0xae78736c…`) | supply ETH 1,748.5441 | $4.074M | price feed | rETH 1,503.6269 | $4.066M |
| Merkl | `merkl` | $3,499.25 | Rewards (`0x3ef3d8ba…`) | supply MORPHO 1,611.6671 | $3,499.25 | — | — | — |
| Compound V3 | `compound3` | $1,639.05 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,638.91 | Compound v3 USDS | supply COMP 70.521281 | $1,633.28 |
| | | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1398 | Compound v3 USDC | supply COMP 0.006016 | $0.1393 |
| LIDO | `lido` | $350.5323 | wstETH (`0x7f39c581…`) | supply stETH 0.150392 | $350.5323 | price feed | wstETH 0.121897 | $349.7037 |
| Uniswap V3 | `uniswap3` | $44.1558 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.001364 + supply ETH 0.015757 + reward WETH 0.000907 + reward ETH 0.000925 | $44.1558 | — | — | — |
| Aave V3 | `aave3` | $0.4352 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4352 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 3,043.7273 | $1.0000 | $3,043.73 | price feed (wallet/Holding) | 3,043.7273 | $3,043.12 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Balancer V2 (`balancer2`) | protocol | $0.1500 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1500) → **$0.1500** |
| HEX | wallet token | $1.1226 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETHx | 9,325.6655 | $23.604M |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $5.022M | Debank filtered: $5.023M | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| StakeWise | `stakewise` | $865,693.19 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8725 | — | — | — |
| | | | Lending (`0xac0f906e…`) | supply ETH 371.557091 | $865,683.43 | Stakewise v3 | supply ETH 371.557091 | $863,975.61 |
| | | | Staked (`0xfe2e6372…`) | supply ETH 0.003813 | $8.8845 | — | — | — |
| Rocket Pool | `rocketpool` | $169,863.23 | rETH (`0xae78736c…`) | supply ETH 72.906430 | $169,863.23 | price feed | rETH 62.694486 | $169,528.13 |
| Aave V3 | `aave3` | $49,763.27 | Lending (`0x87870bca…`) | supply BAL 320,145.0508 | $49,530.49 | Aave V3 Core | supply BAL 320,146.0949 | $49,770.57 |
| | | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 232.970494 | $232.7841 | — | — | — |
| Compound V3 | `compound3` | $104.6937 | Lending (`0xc3d688b6…`) | reward COMP 4.437373 | $103.1245 | Compound v3 USDC | supply COMP 4.437373 | $102.7703 |
| | | | | | | Compound v3 USDC | supply USDC 1.569186 | $1.5689 |
| | | | Yield (`0xc3d688b6…`) | supply USDC 1.569158 | $1.5692 | — | — | — |
| Uniswap V3 | `uniswap3` | $9.7724 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.000154 + supply ETH 0.001778 + reward WETH 0.000102 + reward ETH 0.000104 | $4.9842 | Uniswap V3 | supply WETH 0.001972 | $4.5843 |
| | | | | | | Uniswap V3 | supply WETH 0.000027 | $0.0617 |
| | | | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.7882 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 3.5520M | $1.0000 | $3.552M | price feed (wallet/Holding) | 3.5520M | $3.551M |
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | 2.4916M | $0.1547 | $385,482.51 | price feed (wallet/Holding) | 2.4916M | $387,349.74 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Aave V2 (`aave2`) | protocol | $1.809M | supply: AAVE 19,442.9617 ($1.809M); rewards: AAVE 2.979255 ($277.1899) → **$1.809M**<br>supply: BAL 58.491558 ($9.0494) → **$9.0494** |
| Balancer V2 (`balancer2`) | protocol | $35,397.30 | supply: BAL 90,968.5381 ($14,073.98) + WETH 9.152109 ($21,323.32) → **$35,397.30** |
| Across V2 (`acrocc_v2`) | protocol | $12,857.41 | supply: BAL 83,105.1188 ($12,857.41) → **$12,857.41** |
| Multichain (`multichain`) | protocol | $3.2744 | supply: BAL 21.164100 ($3.2744) → **$3.2744** |
| Compound (`compound`) | protocol | $2.1077 | supply: DAI 1.132199 ($1.1320) + AAVE 0.010451 ($0.9723); rewards: COMP 0.000146 ($0.0034) → **$2.1077** |
| COW | wallet token | $211,157.64 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |
| POL | wallet token | $9,101.12 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` |

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

**NAV: $856.6604 | Debank filtered: $871.8867 | Drift: -1.75% ⚠️**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Uniswap V3 | `uniswap3` | $774.9295 | #1276763 (`0x4e68ccd3…`) | supply WETH 0.125413 + supply USDT 0.000000 + reward WETH 0.000360 + reward USDT 0.463805 | $293.4991 | Uniswap V3 | supply WETH 0.125413 | $291.6209 |
| | | | | | | Uniswap V3 | supply WETH 0.000360 | $0.8363 |
| | | | | | | Uniswap V3 | supply USDT 0.463805 | $0.4638 |
| | | | #1231724 (`0x88e6a0c2…`) | supply USDC 329.408450 + supply WETH 0.061437 + reward USDC 4.438156 + reward WETH 0.001907 | $481.4304 | Uniswap V3 | supply USDC 4.558511 | $4.5576 |
| | | | | | | Uniswap V3 | supply WETH 0.001964 | $4.5675 |
| | | | | | | Uniswap V3 | supply USDC 294.978076 | $294.9191 |
| | | | | | | Uniswap V3 | supply WETH 0.076171 | $177.1194 |
| Convex | `convex` | $14.1465 | Staked (`0x49b4d1df…`) | supply cvxFXS 62.684670 + reward FRAX 1.860052 + reward CVX 1.434995 | $14.1465 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 7.152868 | $0.9999 | $7.1519 | price feed (wallet/Holding) | 7.152868 | $7.1520 |
| ETH | `eth` | 0.032436 | $2,329.88 | $75.5728 | price feed (wallet/Holding) | 0.032436 | $75.4237 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Layer3 (`layer3`) | protocol | $82.0572 | supply: L3 6,323.3042 ($70.3784); rewards: L3 1,049.3095 ($11.6788) → **$82.0572** |
| espresso (`espresso`) | protocol | $43.8677 | supply: ESP 625.520000 ($43.8677) → **$43.8677** |
| Ekubo (`ekubo`) | protocol | $12.3883 | supply: EKUBO 4.006297 ($1.9273) + gEKUBO-26Q2 6.674740 ($0.0000); rewards: EKUBO 0.140899 ($0.0678) + gEKUBO-26Q2 0.183029 ($0.0000) → **$1.9951**<br>supply: ETH 0.000000 ($0.0000) + EKUBO 21.604083 ($10.3932) → **$10.3932** |
| AEVO | wallet token | $9.5372 | `0xb528edbef013aff855ac3c50b381f253af13b997` |
| EKUBO | wallet token | $0.6845 | `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` |

