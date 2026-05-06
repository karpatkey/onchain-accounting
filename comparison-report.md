# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-06 21:52 UTC  
Tolerance: 1%

Debank anchor: from `accounts.json.expected.<cid>.debankUsd` (captured at forge-snapshot time). Re-run with `--refresh-debank` to recapture against current chain state.  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25038439 |
| optimism (10) | 151250626 |
| gnosis (100) | 46041192 |
| base (8453) | 45655341 |
| arbitrum (42161) | 460099462 |

## Drift summary

**13 of 15 account-chain pairs within 1% tolerance.** ⚠ 2 over tolerance — see per-account section for breakdown.

| Account | Chain | NAV | Debank filtered | Drift |  |
|---|---|---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | $181.0635 | $180.0946 | +0.54% | ✅ |
| ACCOUNT_1 | gnosis | $5.0067 | $5.0060 | +0.01% | ✅ |
| ACCOUNT_1 | base | $9.9998 | $10.0014 | -0.02% | ✅ |
| ACCOUNT_1 | arbitrum | $10.0258 | $10.0251 | +0.01% | ✅ |
| ACCOUNT_2 | mainnet | $1.144M | $1.147M | -0.25% | ✅ |
| ACCOUNT_3 | mainnet | $276.1118 | $276.3041 | -0.07% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | $176,945.55 | $176,912.98 | +0.02% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | $8.143M | $8.143M | +0.00% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | $2.766M | $2.766M | +0.02% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | $2.059M | $2.060M | -0.02% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | $823,641.75 | $823,808.45 | -0.02% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | $17.673M | $18.199M | -2.89% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | $95.175M | $95.212M | -0.04% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | $5.032M | $5.036M | -0.07% | ✅ |
| ACCOUNT_12_MAINNET_UNISWAP_V3_LP | mainnet | $861.7481 | $876.2098 | -1.65% | ⚠️ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $181.0635 | Debank filtered: $180.0946 | Drift: +0.54% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $61.5759 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.085562 | $10.0866 | Morpho Vault | supply USDC 10.085596 | $10.0836 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.088899 | $10.0899 | Morpho Blue - wstETH/USDC | supply USDC 10.088941 | $10.0869 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.038943 | $5.0378 | Morpho Blue - sUSDS/USDT | supply USDT 5.038969 | $5.0384 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1849 | Morpho Blue - wstUSR/USDC | supply USDC 17.478788 | $17.4753 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.089028 | $10.0900 | Morpho Blue - cbBTC/USDC | supply USDC 10.089059 | $10.0870 |
| | | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.085761 | $10.0868 | Morpho Vault | supply USDC 10.085797 | $10.0838 |
| Aave V3 | `aave3` | $52.5600 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.9960 | Aave V3 Safety Module | supply GHO 10.000000 | $9.9973 |
| | | | Lending (`0x87870bca…`) | supply USDC 9.082988 + supply USDT 10.085840 + supply USDe 5.024260 + supply sUSDe 3.000000 + supply RLUSD 14.672233 + reward USDS 0.008929 | $42.5640 | Aave V3 Core | supply USDC 9.083011 | $9.0812 |
| | | | | | | Aave V3 Core | supply USDT 10.085871 | $10.0847 |
| | | | | | | Aave V3 Core | supply USDe 5.024307 | $5.0209 |
| | | | | | | Aave V3 Core | supply sUSDe 3.000000 | $3.6886 |
| | | | | | | Aave V3 Core | supply RLUSD 14.672258 | $14.6728 |
| Balancer V3 | `balancer3` | $7.0027 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.698655 + supply GHO 3.480730 + supply USDC 1.824903 | $7.0027 | Balancer V3 - Aave GHO/USDT/USDC | supply USDT 1.716134 | $1.7159 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply GHO 3.481146 | $3.4802 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply USDC 1.806988 | $1.8066 |
| cap | `capapp` | $5.0609 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.060470 | $5.0609 | Cap | supply USDC 10.050517 | $10.0485 |
| Sky | `sky` | $5.0535 | Savings USDS (`0xa3931d71…`) | supply USDS 5.054053 | $5.0535 | price feed | sUSDS 4.612968 | $5.0520 |
| Ethena | `ethena` | $4.4854 | sUSDe (`0x9d39a5de…`) | supply USDe 4.487658 | $4.4854 | price feed | sUSDe 3.647417 | $4.4846 |
| Merkl | `merkl` | $0.3028 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.139158 + supply USDT 0.000057 + supply USDC 0.000061 | $0.3028 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | 8.905915 | $0.9996 | $8.9024 | price feed (wallet/Holding) | 8.905915 | $8.9035 |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | 0.999922 | $0.9995 | $0.9994 | price feed (wallet/Holding) | 0.999922 | $0.9992 |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.626826 | $1.0001 | $9.6278 | price feed (wallet/Holding) | 9.626826 | $9.6249 |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | 4.990006 | $1.0001 | $4.9905 | ↑ aggregated by Cap (see protocol row) | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 4.717667 | $0.9998 | $4.7166 | price feed (wallet/Holding) | 4.717667 | $4.7171 |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | 14.831886 | $0.9999 | $14.8304 | price feed (wallet/Holding) | 14.831886 | $14.8257 |

### Gnosis (chain 100)

**NAV: $5.0067 | Debank filtered: $5.0060 | Drift: +0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $2.0087 | Lending (`0xb5020155…`) | supply WXDAI 2.008898 | $2.0087 | Aave V3 Gnosis | supply WXDAI 2.008901 | $2.0089 |
| Gnosis | `gnosis` | $0.0000 | — | — | — | price feed | sDAI 0.000014 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | 0.998493 | $0.9995 | $0.9980 | price feed (wallet/Holding) | 0.998493 | $0.9982 |
| xDai | `xdai` | 1.999518 | $0.9999 | $1.9993 | price feed (wallet/Holding) | 1.999518 | $1.9995 |

### Base (chain 8453)

**NAV: $9.9998 | Debank filtered: $10.0014 | Drift: -0.02% ✅**

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | 10.001207 | $1.0001 | $10.0022 | price feed (wallet/Holding) | 10.001207 | $9.9997 |

### Arbitrum (chain 42161)

**NAV: $10.0258 | Debank filtered: $10.0251 | Drift: +0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $2.0189 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.010979 | $1.0111 | Morpho Vault | supply USDC 1.010985 | $1.0109 |
| | | | Deposit (`0x6c247b1f…`) | supply USDC 1.007352 | $1.0075 | Morpho Blue - sUSDS/USDC | supply USDC 1.007353 | $1.0072 |
| Aave V3 | `aave3` | $1.0024 | Lending (`0x794a6135…`) | supply USDC 2.012319 + borrow GHO 1.009986 | $1.0024 | Aave V3 Arbitrum | supply USDC 2.012324 | $2.0121 |
| | | | | | | Aave V3 Arbitrum | borrow GHO 1.010012 | $-1.0098 |
| Merkl | `merkl` | $0.0004 | — | — | — | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| syrupUSDC | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | 1.732523 | $1.1619 | $2.0130 | price feed (wallet/Holding) | 1.732523 | $2.0145 |
| GHO | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | 0.956018 | $1.0001 | $0.9561 | price feed (wallet/Holding) | 0.956018 | $0.9559 |
| USDC | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | 2.004327 | $1.0001 | $2.0045 | price feed (wallet/Holding) | 2.004327 | $2.0041 |
| USD₮0 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | 2.031070 | $0.9998 | $2.0306 | price feed (wallet/Holding) | 2.031070 | $2.0308 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.144M | Debank filtered: $1.147M | Drift: -0.25% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $1.148M | Lending (`0x87870bca…`) | supply WETH 0.011598 + supply rsETH 2,326.4202 + borrow WETH 2,001.5848 | $1.148M | Aave V3 Core | supply WETH 0.011598 | $27.2392 |
| | | | | | | Aave V3 Core | supply rsETH 2,326.4202 | $5.844M |
| | | | | | | Aave V3 Core | borrow WETH 2,001.6145 | $-4.701M |
| Kelp DAO | `kelpdao` | $737.7155 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $737.7155 | price feed | rsETH 0.292977 | $736.0035 |
| Merkl | `merkl` | $26.6727 | Rewards (`0x3ef3d8ba…`) | supply GEAR 91,169.3043 + supply ETH 0.000000 | $26.6727 | — | — | — |
| LIDO | `lido` | $0.0058 | — | — | — | price feed | wstETH 0.000002 | $0.0058 |
| | | | | | | price feed | stETH 0.000000 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.002564 | $2,354.13 | $6.0367 | price feed (wallet/Holding) | 0.002564 | $6.0227 |

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $276.1118 | Debank filtered: $276.3041 | Drift: -0.07% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Balancer V3 | `balancer3` | $82.4989 | Farming (`0x62a66eb9…`) | supply WETH 0.017517 + supply ETH 0.017477 + reward BAL 0.757598 | $82.4989 | Balancer V3 - rETH/Aave WETH | supply WETH 0.017517 | $41.1415 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply BAL 0.757598 | $0.1178 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply rETH 0.015029 | $41.0477 |
| Aave V3 | `aave3` | $68.6693 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005019 + supply ezETH 0.005000 + borrow WETH 0.005025 | $27.1911 | Aave V3 Prime | supply wstETH 0.005000 | $14.4897 |
| | | | | | | Aave V3 Prime | supply WETH 0.005019 | $11.7880 |
| | | | | | | Aave V3 Prime | supply ezETH 0.005000 | $12.6503 |
| | | | | | | Aave V3 Prime | borrow WETH 0.005025 | $-11.8016 |
| | | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.059712 + borrow WETH 0.059007 | $41.4782 | Aave V3 Core | supply WETH 0.002969 | $6.9729 |
| | | | | | | Aave V3 Core | supply wstETH 0.059712 | $173.0267 |
| | | | | | | Aave V3 Core | borrow WETH 0.059009 | $-138.5934 |
| Rocket Pool | `rocketpool` | $41.0263 | rETH (`0xae78736c…`) | supply ETH 0.017427 | $41.0263 | price feed | rETH 0.014986 | $40.9311 |
| Convex | `convex` | $30.0739 | Staked (`0x5411cc58…`) | supply WETH 0.001293 + supply ETH 0.011461 + reward CRV 0.187681 + reward CVX 0.000063 | $30.0739 | Convex | supply WETH 0.001293 | $3.0379 |
| | | | | | | Convex | supply CRV 0.189793 | $0.0472 |
| | | | | | | Convex | supply weETH 0.010475 | $26.8473 |
| | | | | | | Convex | supply CVX 0.000190 | $0.0003 |
| ether.fi | `etherfi` | $21.2170 | weETH (`0xcd5fe23c…`) | supply ETH 0.009013 | $21.2170 | price feed | weETH 0.008237 | $21.1113 |
| Kelp DAO | `kelpdao` | $10.8098 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.8098 | price feed | rsETH 0.004293 | $10.7847 |
| Merkl | `merkl` | $0.2242 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000007 + supply ETH 0.000007 + supply GEAR 6.174863 + supply RPL 0.098307 | $0.2242 | Merkl | supply RPL 0.100168 | $0.1985 |
| Aura Finance | `aurafinance` | $0.0956 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.130822 | $0.0956 | Aura | supply BAL 0.489289 | $0.0761 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.002000 | $2,354.13 | $4.7083 | price feed (wallet/Holding) | 0.002000 | $4.6973 |
| ETH | `eth` | 0.007468 | $2,354.13 | $17.5814 | price feed (wallet/Holding) | 0.007468 | $17.5406 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $176,945.55 | Debank filtered: $176,912.98 | Drift: +0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $176,983.87 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 46.766070 | $66,410.86 | Aave Umbrella | supply GHO 66,390.6641 | $66,373.01 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,197.3878 + reward USDC 14.777622 | $65,218.69 | Aave Umbrella | supply USDC 65,197.1956 | $65,184.16 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,658.9019 + reward USDT 7.994772 | $27,660.53 | Aave Umbrella | supply USDT 27,658.8034 | $27,655.53 |
| | | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.514643 + reward WETH 0.001422 | $17,693.80 | Aave Umbrella | supply WETH 7.514627 | $17,649.35 |
| | | | | | | Aave Umbrella | supply USDC 16.857278 | $16.8539 |
| | | | | | | Aave Umbrella | supply USDT 9.083086 | $9.0820 |
| | | | | | | Aave Umbrella | supply WETH 0.001614 | $3.7907 |
| | | | | | | Aave Umbrella | supply GHO 53.126070 | $53.1119 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.000282 | $2,354.13 | $0.6641 | price feed (wallet/Holding) | 0.000282 | $0.6626 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.143M | Debank filtered: $8.143M | Drift: +0.00% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Fluid | `fluid` | $5.046M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0475M | $5.046M | Fluid Lending | supply USDT 5.0477M | $5.047M |
| Compound V3 | `compound3` | $3.097M | Lending (`0xc3d688b6…`) | reward COMP 24.720004 | $581.4145 | Compound v3 USDC | supply COMP 24.971137 | $585.8832 |
| | | | Yield (`0xc3d688b6…`) | supply USDC 3.0959M | $3.096M | Compound v3 USDC | supply USDC 3.0960M | $3.095M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.086040 | $2,354.13 | $202.5486 | price feed (wallet/Holding) | 0.086040 | $202.0786 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.766M | Debank filtered: $2.766M | Drift: +0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $2.765M | Lending (`0x2e44e174…`) | reward COMP 38.421572 | $903.6754 | Compound v3 USDC | supply COMP 38.421572 | $900.9416 |
| | | | Yield (`0x2e44e174…`) | supply USDC 756,169.7730 | $756,245.40 | Compound v3 USDC | supply USDC 756,197.3562 | $756,082.09 |
| | | | Lending (`0x995e394b…`) | reward COMP 138.982925 | $3,268.88 | Compound v3 USDT | supply COMP 138.982925 | $3,258.99 |
| | | | Yield (`0x995e394b…`) | supply USDT 2.0055M | $2.005M | Compound v3 USDT | supply USDT 2.0056M | $2.005M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `op` | 0.049027 | $2,354.13 | $115.4164 | price feed (wallet/Holding) | 0.049027 | $115.1178 |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 WETH / Reward | COMP | 24.934844 | $584.6934 |

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
| ETH | `arb` | 0.001305 | $2,353.84 | $3.0719 | price feed (wallet/Holding) | 0.001305 | $3.0614 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,641.75 | Debank filtered: $823,808.45 | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $823,753.83 | Lending (`0xb125e668…`) | reward COMP 13.108705 | $308.3167 | Compound v3 USDC | supply COMP 13.108705 | $307.8664 |
| | | | Yield (`0xb125e668…`) | supply USDC 823,363.1658 | $823,445.51 | Compound v3 USDC | supply USDC 823,406.9367 | $823,279.09 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `base` | 0.023361 | $2,353.84 | $54.9876 | price feed (wallet/Holding) | 0.023361 | $54.7938 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| CASHW | wallet token | $2.8813 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $17.673M | Debank filtered: $18.199M | Drift: -2.89% ⚠️**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morpho` | $5.765M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.6530M | $2.653M | Morpho Vault | supply USDC 2.6530M | $2.652M |
| | | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2006M | $2.587M | Morpho Vault | supply EURC 2.2006M | $2.590M |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 223.238257 | $525,467.14 | Morpho Vault | supply WETH 223.241644 | $524,320.18 |
| LIDO | `lido` | $2.120M | wstETH (`0x7f39c581…`) | supply stETH 212.629265 | $500,442.88 | price feed | wstETH 172.342940 | $499,395.24 |
| | | | stETH (`0xae7ab965…`) | supply ETH 687.904751 | $1.619M | price feed | stETH 687.904751 | $1.617M |
| Uniswap V3 | `uniswap3` | $527,319.62 | #1213124 (`0xfbb81382…`) | supply WETH 54.340018 + supply COW 2.2250M + reward WETH 0.174326 + reward COW 2,771.3584 | $527,319.62 | — | — | — |
| StakeWise | `stakewise` | $557.5533 | Lending (`0x15639e82…`) | supply ETH 0.388040 + borrow osETH 0.142290 | $557.5533 | — | — | — |
| Aave V3 | `aave3` | $0.0561 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0561 | Aave V3 Core | supply WETH 0.000024 | $0.0560 |
| Compound V3 | `compound3` | $0.0014 | — | — | — | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.6573M | $1.0001 | $9.658M | price feed (wallet/Holding) | 9.6573M | $9.655M |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.540302 | $2,353.84 | $1,271.79 | price feed (wallet/Holding) | 0.540302 | $1,268.99 |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 152.306225 | $0.9998 | $152.2712 | price feed (wallet/Holding) | 152.306225 | $152.2882 |
| ETH | `eth` | 56.546754 | $2,353.84 | $133,102.01 | price feed (wallet/Holding) | 56.546754 | $132,809.47 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Sablier (`sablier`) | protocol | $1.416M | supply: COW 7.9090M ($1.416M) → **$1.416M** |
| COW | wallet token | $3.745M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $95.175M | Debank filtered: $95.212M | Drift: -0.04% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Sky | `sky` | $29.607M | Savings USDS (`0xa3931d71…`) | supply USDS 29.6099M | $29.607M | price feed | sUSDS 27.0258M | $29.598M |
| StakeWise | `stakewise` | $23.946M | Lending (`0xac0f906e…`) | supply ETH 10,173.1327 + borrow osETH 0.000006 | $23.946M | Stakewise v3 | supply ETH 10,173.1327 | $23.893M |
| Stader | `stader` | $23.893M | ETHx (`0xa35b1b31…`) | supply ETH 10,150.8265 | $23.893M | — | — | — |
| Morpho | `morpho` | $13.752M | kpk USDC (`0x4ef53d2c…`) | supply USDC 5.0715M | $5.072M | Morpho Vault | supply USDC 5.0715M | $5.070M |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 3,687.4003 | $8.680M | Morpho Vault | supply WETH 3,687.4170 | $8.661M |
| Rocket Pool | `rocketpool` | $4.116M | rETH (`0xae78736c…`) | supply ETH 1,748.5441 | $4.116M | price feed | rETH 1,503.6269 | $4.107M |
| Merkl | `merkl` | $3,615.45 | Rewards (`0x3ef3d8ba…`) | supply MORPHO 1,611.6671 | $3,615.45 | — | — | — |
| Compound V3 | `compound3` | $1,658.80 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,658.66 | Compound v3 USDS | supply COMP 70.521281 | $1,654.60 |
| | | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1415 | Compound v3 USDC | supply COMP 0.006016 | $0.1411 |
| LIDO | `lido` | $353.9613 | wstETH (`0x7f39c581…`) | supply stETH 0.150392 | $353.9613 | price feed | wstETH 0.121897 | $353.2203 |
| Uniswap V3 | `uniswap3` | $44.6099 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.001364 + supply ETH 0.015757 + reward WETH 0.000907 + reward ETH 0.000925 | $44.6099 | — | — | — |
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
| Balancer V2 (`balancer2`) | protocol | $0.1516 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1516) → **$0.1516** |
| HEX | wallet token | $1.1447 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETHx | 9,325.6655 | $23.841M |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $5.032M | Debank filtered: $5.036M | Drift: -0.07% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| StakeWise | `stakewise` | $874,554.50 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8815 | — | — | — |
| | | | Lending (`0xac0f906e…`) | supply ETH 371.541124 | $874,544.64 | Stakewise v3 | supply ETH 371.557091 | $872,663.70 |
| | | | Staked (`0xfe2e6372…`) | supply ETH 0.003813 | $8.9758 | — | — | — |
| Rocket Pool | `rocketpool` | $171,609.34 | rETH (`0xae78736c…`) | supply ETH 72.906430 | $171,609.34 | price feed | rETH 62.694486 | $171,232.89 |
| Aave V3 | `aave3` | $50,268.55 | Lending (`0x87870bca…`) | supply BAL 320,141.9860 | $50,035.68 | Aave V3 Core | supply BAL 320,144.4958 | $49,770.32 |
| | | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 232.961382 | $232.8682 | — | — | — |
| Compound V3 | `compound3` | $105.9362 | Lending (`0xc3d688b6…`) | reward COMP 4.437373 | $104.3670 | Compound v3 USDC | supply COMP 4.437373 | $104.1115 |
| | | | | | | Compound v3 USDC | supply USDC 1.569143 | $1.5688 |
| | | | Yield (`0xc3d688b6…`) | supply USDC 1.569076 | $1.5692 | — | — | — |
| Uniswap V3 | `uniswap3` | $9.8722 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.000154 + supply ETH 0.001778 + reward WETH 0.000102 + reward ETH 0.000104 | $5.0354 | Uniswap V3 | supply WETH 0.001972 | $4.6304 |
| | | | | | | Uniswap V3 | supply WETH 0.000027 | $0.0623 |
| | | | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.8368 | — | — | — |
| LIDO | `lido` | $0.0000 | — | — | — | price feed | stETH 0.000000 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 3.5520M | $1.0001 | $3.552M | price feed (wallet/Holding) | 3.5520M | $3.551M |
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | 2.4916M | $0.1563 | $389,418.01 | price feed (wallet/Holding) | 2.4916M | $387,349.74 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Aave V2 (`aave2`) | protocol | $1.835M | supply: AAVE 19,442.9617 ($1.835M); rewards: AAVE 1.522670 ($143.7096) → **$1.835M**<br>supply: BAL 58.491558 ($9.1418) → **$9.1418** |
| Balancer V2 (`balancer2`) | protocol | $35,760.21 | supply: BAL 90,940.4880 ($14,213.29) + WETH 9.153987 ($21,546.93) → **$35,760.21** |
| Across V2 (`acrocc_v2`) | protocol | $12,988.68 | supply: BAL 83,105.1188 ($12,988.68) → **$12,988.68** |
| Multichain (`multichain`) | protocol | $3.3078 | supply: BAL 21.164100 ($3.3078) → **$3.3078** |
| Compound (`compound`) | protocol | $2.1219 | supply: DAI 1.132199 ($1.1321) + AAVE 0.010451 ($0.9863); rewards: COMP 0.000146 ($0.0034) → **$2.1219** |
| COW | wallet token | $212,701.53 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |
| POL | wallet token | $9,057.01 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000041 | $0.0953 |
| adapter | Aave V2 / Collateral | BAL | 58.491558 | $9.0932 |

---

## ACCOUNT_12_MAINNET_UNISWAP_V3_LP

**Address:** `0x8d27deb2405717d649346502f52b959aab4eb3af`

### Mainnet (chain 1)

**NAV: $861.7481 | Debank filtered: $876.2098 | Drift: -1.65% ⚠️**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Uniswap V3 | `uniswap3` | $779.4922 | #1276763 (`0x4e68ccd3…`) | supply WETH 0.125413 + supply USDT 0.000000 + reward WETH 0.000360 + reward USDT 0.463805 | $296.5113 | — | — | — |
| | | | #1231724 (`0x88e6a0c2…`) | supply USDC 329.408450 + supply WETH 0.061437 + reward USDC 4.438156 + reward WETH 0.001907 | $482.9809 | — | — | — |
| Convex | `convex` | $14.1761 | Staked (`0x49b4d1df…`) | supply cvxFXS 62.684670 + reward FRAX 1.860052 + reward CVX 1.434995 | $14.1761 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 7.152868 | $0.9998 | $7.1512 | price feed (wallet/Holding) | 7.152868 | $7.1520 |
| ETH | `eth` | 0.032436 | $2,353.83 | $76.3497 | price feed (wallet/Holding) | 0.032436 | $76.1822 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Layer3 (`layer3`) | protocol | $83.3105 | supply: L3 6,323.3042 ($71.4533); rewards: L3 1,049.3095 ($11.8572) → **$83.3105** |
| espresso (`espresso`) | protocol | $43.8239 | supply: ESP 625.520000 ($43.8239) → **$43.8239** |
| Ekubo (`ekubo`) | protocol | $12.2217 | supply: EKUBO 4.006297 ($1.9014) + gEKUBO-26Q2 6.674740 ($0.0000); rewards: EKUBO 0.140899 ($0.0669) + gEKUBO-26Q2 0.183029 ($0.0000) → **$1.9683**<br>supply: ETH 0.000000 ($0.0000) + EKUBO 21.604083 ($10.2534) → **$10.2534** |
| AEVO | wallet token | $9.6348 | `0xb528edbef013aff855ac3c50b381f253af13b997` |
| EKUBO | wallet token | $0.6753 | `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` |

