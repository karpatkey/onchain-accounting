# NAV vs DeBank — Detailed Comparison Report

Generated: 2026-05-09 06:32 UTC  
Tolerance: 1%

DeBank anchor: read from `test/integration/debank-cache/` (no live API call).  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25055288 |
| optimism (10) | 151352010 |
| gnosis (100) | 46080734 |
| base (8453) | 45756725 |
| arbitrum (42161) | 460908100 |

## Drift summary

**12 of 15 account-chain pairs within 1% tolerance.** ⚠ 3 over tolerance — see per-account section for breakdown.

| Account | Chain | │ | NAV | │ | DeBank filtered | Drift |  |
|---|---|:---:|---:|:---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | │ | $182.0243 | │ | $180.1187 | +1.06% | ⚠️ |
| ACCOUNT_1 | gnosis | │ | $5.0062 | │ | $5.0061 | +0.00% | ✅ |
| ACCOUNT_1 | base | │ | $9.9998 | │ | $10.0003 | -0.01% | ✅ |
| ACCOUNT_1 | arbitrum | │ | $10.0268 | │ | $10.0252 | +0.02% | ✅ |
| ACCOUNT_2 | mainnet | │ | $1.128M | │ | $1.126M | +0.17% | ✅ |
| ACCOUNT_3 | mainnet | │ | $272.5186 | │ | $272.1334 | +0.14% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | │ | $176,813.53 | │ | $176,734.52 | +0.04% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | │ | $8.145M | │ | $8.144M | +0.02% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | │ | $2.767M | │ | $2.766M | +0.03% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | │ | $2.059M | │ | $2.059M | -0.00% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | │ | $823,876.87 | │ | $823,863.35 | +0.00% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | │ | $17.638M | │ | $18.174M | -2.95% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | │ | $94.404M | │ | $94.313M | +0.10% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | │ | $7.080M | │ | $7.064M | +0.23% | ✅ |
| ACCOUNT_12_MAINNET_UNISWAP_V3_LP | mainnet | │ | $856.2647 | │ | $869.2481 | -1.49% | ⚠️ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $182.0243 | DeBank filtered: $180.1187 | Drift: +1.06% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $61.5749 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.087890 | $10.0869 | │ | $63.7930 | Morpho | Supply USDC 10.088176 | $10.0870 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.091143 | $10.0901 | │ | | Morpho | Supply USDC 10.091407 | $10.0902 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.039935 | $5.0389 | │ | | Morpho | Supply USDT 5.040068 | $5.0394 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1816 | │ | | Morpho | Supply USDC 18.401201 | $18.3990 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.091148 | $10.0901 | │ | | Morpho | Supply USDC 10.091407 | $10.0902 |
| | │ | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.088181 | $10.0872 | │ | | Morpho | Supply USDC 10.088454 | $10.0872 |
| Aave V3<br>`aave3` | │ | $52.5597 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.9930 | │ | $52.5584 | Aave V3 | Staking GHO 10.000000 | $9.9989 |
| | │ | | Lending (`0x87870bca…`) | supply USDC 9.084768 + supply USDT 10.088213 + supply USDe 5.025485 + supply sUSDe 3.000000 + supply RLUSD 14.674080 + reward USDS 0.008929 | $42.5667 | │ | | Aave V3 | Collateral USDC 9.085063 | $9.0840 |
| | │ | | | | | │ | | Aave V3 | Collateral USDT 10.088521 | $10.0873 |
| | │ | | | | | │ | | Aave V3 | Collateral USDe 5.025642 | $5.0237 |
| | │ | | | | | │ | | Aave V3 | Collateral sUSDe 3.000000 | $3.6905 |
| | │ | | | | | │ | | Aave V3 | Supply RLUSD 14.674290 | $14.6740 |
| Balancer V3<br>`balancer3` | │ | $7.0033 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.899951 + supply GHO 2.553107 + supply USDC 2.552629 | $7.0033 | │ | $7.0049 | Balancer V3 | Supply USDT 1.836136 | $1.8359 |
| | │ | | | | | │ | | Balancer V3 | Supply GHO 2.551318 | $2.5510 |
| | │ | | | | | │ | | Balancer V3 | Supply USDC 2.618229 | $2.6179 |
| cap<br>`capapp` | │ | $5.0616 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.062161 | $5.0616 | │ | $10.0511 | Cap | Supply USDC 10.052274 | $10.0511 |
| Sky<br>`sky` | │ | $5.0546 | Savings USDS (`0xa3931d71…`) | supply USDS 5.055124 | $5.0546 | │ | $5.0529 | price feed | sUSDS 4.612968 | $5.0529 |
| Ethena<br>`ethena` | │ | $4.4859 | sUSDe (`0x9d39a5de…`) | supply USDe 4.488571 | $4.4859 | │ | $4.4870 | price feed | sUSDe 3.647417 | $4.4870 |
| Merkl<br>`merkl` | │ | $0.3119 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.150272 + supply USDT 0.000089 + supply USDC 0.000119 | $0.3119 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | │ | 8.905915 | $0.9993 | $8.8997 | │ | 8.905915 | $0.9999 | $8.9049 |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | │ | 0.999922 | $0.9994 | $0.9993 | │ | 0.999922 | $0.9996 | $0.9995 |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 9.626826 | $0.9999 | $9.6259 | │ | 9.626826 | $0.9999 | $9.6257 |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | │ | 4.990006 | $0.9999 | $4.9895 | │ | ↑ aggregated (see protocol row) | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 4.717667 | $0.9998 | $4.7167 | │ | 4.717667 | $0.9999 | $4.7171 |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | │ | 14.831886 | $0.9999 | $14.8304 | │ | 14.831886 | $0.9995 | $14.8250 |

### Gnosis (chain 100)

**NAV: $5.0062 | DeBank filtered: $5.0061 | Drift: +0.00% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $2.0090 | Lending (`0xb5020155…`) | supply WXDAI 2.009190 | $2.0090 | │ | $2.0088 | Aave V3 | Collateral WXDAI 2.009289 | $2.0088 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | │ | 0.998493 | $0.9993 | $0.9978 | │ | 0.998493 | $0.9998 | $0.9983 |
| xDai | `xdai` | │ | 1.999518 | $0.9999 | $1.9993 | │ | 1.999518 | $0.9998 | $1.9990 |

### Base (chain 8453)

**NAV: $9.9998 | DeBank filtered: $10.0003 | Drift: -0.01% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | │ | 10.001207 | $0.9999 | $10.0002 | │ | 10.001207 | $0.9998 | $9.9997 |

### Arbitrum (chain 42161)

**NAV: $10.0268 | DeBank filtered: $10.0252 | Drift: +0.02% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $2.0186 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.011307 | $1.0112 | │ | $2.0186 | Morpho | Supply USDC 1.011322 | $1.0112 |
| | │ | | Deposit (`0x6c247b1f…`) | supply USDC 1.007518 | $1.0074 | │ | | Morpho | Supply USDC 1.007521 | $1.0074 |
| Aave V3<br>`aave3` | │ | $1.0016 | Lending (`0x794a6135…`) | supply USDC 2.012723 + borrow GHO 1.010989 | $1.0016 | │ | $1.0016 | Aave V3 | Collateral USDC 2.012734 | $2.0124 |
| | │ | | | | | │ | | Aave V3 | Borrow GHO 1.010996 | $-1.0109 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| syrupUSDC | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | │ | 1.732523 | $1.1622 | $2.0135 | │ | 1.732523 | $1.1632 | $2.0153 |
| GHO | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | │ | 0.956018 | $0.9999 | $0.9560 | │ | 0.956018 | $0.9999 | $0.9559 |
| USDC | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | │ | 2.004327 | $0.9999 | $2.0041 | │ | 2.004327 | $0.9999 | $2.0040 |
| USD₮0 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | │ | 2.031070 | $0.9998 | $2.0307 | │ | 2.031070 | $1.0000 | $2.0311 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.128M | DeBank filtered: $1.126M | Drift: +0.17% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $1.126M | Lending (`0x87870bca…`) | supply WETH 0.011599 + supply rsETH 2,326.4202 + borrow WETH 2,001.9287 | $1.126M | │ | $1.128M | Aave V3 | Collateral WETH 0.011599 | $26.8885 |
| | │ | | | | | │ | | Aave V3 | Collateral rsETH 2,326.4202 | $5.768M |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 2,001.9434 | $-4.641M |
| Kelp DAO<br>`kelpdao` | │ | $725.0616 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $725.0616 | │ | $726.4324 | price feed | rsETH 0.292977 | $726.4324 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.002564 | $2,313.75 | $5.9332 | │ | 0.002564 | $2,318.12 | $5.9444 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Merkl (`merkl`) | protocol | $26.9226 | supply GEAR 91,169.3043 + supply ETH 0.000000 |

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $272.5186 | DeBank filtered: $272.1334 | Drift: +0.14% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Balancer V3<br>`balancer3` | │ | $81.1083 | Farming (`0x62a66eb9…`) | supply WETH 0.017715 + supply ETH 0.017283 + reward BAL 0.757598 | $81.1083 | │ | $81.2506 | Balancer V3 | Staking WETH 0.017715 | $41.0646 |
| | │ | | | | | │ | | Balancer V3 | Staking BAL 0.757598 | $0.1217 |
| | │ | | | | | │ | | Balancer V3 | Staking rETH 0.014861 | $40.0644 |
| Aave V3<br>`aave3` | │ | $60.2949 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005020 + supply ezETH 0.005000 + borrow WETH 0.005025 | $26.7132 | │ | $60.4540 | Aave V3 | Collateral wstETH 0.005000 | $14.3036 |
| | │ | | | | | │ | | Aave V3 | Collateral WETH 0.005020 | $11.6373 |
| | │ | | | | | │ | | Aave V3 | Collateral ezETH 0.005000 | $12.4870 |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 0.005026 | $-11.6513 |
| | │ | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.009367 | $33.5817 | │ | | Aave V3 | Collateral WETH 0.002969 | $6.8831 |
| | │ | | | | | │ | | Aave V3 | Collateral wstETH 0.009367 | $26.7942 |
| Rocket Pool<br>`rocketpool` | │ | $40.3339 | rETH (`0xae78736c…`) | supply ETH 0.017429 | $40.3339 | │ | $40.4028 | price feed | rETH 0.014986 | $40.4028 |
| Convex<br>`convex` | │ | $29.5733 | Staked (`0x5411cc58…`) | supply WETH 0.001414 + supply ETH 0.011343 + reward CRV 0.200362 + reward CVX 0.000067 | $29.5733 | │ | $29.5712 | Convex | Staking WETH 0.001414 | $3.2776 |
| | │ | | | | | │ | | Convex | Staking CRV 0.204673 | $0.0523 |
| | │ | | | | | │ | | Convex | Staking CVX 0.000205 | $0.0004 |
| | │ | | | | | │ | | Convex | Staking weETH 0.010365 | $26.2409 |
| ether.fi<br>`etherfi` | │ | $20.8605 | weETH (`0xcd5fe23c…`) | supply ETH 0.009014 | $20.8605 | │ | $20.8533 | price feed | weETH 0.008237 | $20.8533 |
| Kelp DAO<br>`kelpdao` | │ | $10.6263 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.6263 | │ | $10.6444 | price feed | rsETH 0.004293 | $10.6444 |
| Merkl<br>`merkl` | │ | $0.2604 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000008 + supply ETH 0.000007 + supply GEAR 6.174863 + supply RPL 0.109194 | $0.2604 | │ | $0.2316 | Merkl | Rewards RPL 0.112713 | $0.2316 |
| Aura Finance<br>`aurafinance` | │ | $0.0933 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.127927 | $0.0933 | │ | $0.0786 | Aura | Staking BAL 0.489289 | $0.0786 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 0.005056 | $2,314.17 | $11.6997 | │ | 0.005056 | $2,318.12 | $11.7197 |
| ETH | `eth` | │ | 0.007468 | $2,314.17 | $17.2830 | │ | 0.007468 | $2,318.12 | $17.3125 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $176,813.53 | DeBank filtered: $176,734.52 | Drift: +0.04% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $176,733.86 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 83.509673 | $66,427.64 | │ | $176,812.87 | Aave V3 | Staking GHO 66,390.6641 | $66,383.37 |
| | │ | | | | | │ | | Aave V3 | Rewards GHO 87.064859 | $87.0553 |
| | │ | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,211.9894 + reward USDC 29.354205 | $65,234.82 | │ | | Aave V3 | Staking USDC 65,211.9234 | $65,204.10 |
| | │ | | | | | │ | | Aave V3 | Rewards USDC 31.218313 | $31.2146 |
| | │ | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,666.1013 + reward USDT 15.016499 | $27,672.81 | │ | | Aave V3 | Staking USDT 27,666.0711 | $27,662.65 |
| | │ | | | | | │ | | Aave V3 | Rewards USDT 15.836303 | $15.8343 |
| | │ | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.515603 + reward WETH 0.002680 | $17,398.59 | │ | | Aave V3 | Staking WETH 7.515600 | $17,422.09 |
| | │ | | | | | │ | | Aave V3 | Rewards WETH 0.002828 | $6.5549 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.000282 | $2,314.17 | $0.6528 | │ | 0.000282 | $2,318.12 | $0.6539 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.145M | DeBank filtered: $8.144M | Drift: +0.02% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Fluid<br>`fluid` | │ | $8.143M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0485M | $5.047M | │ | $8.144M | Fluid | Supply USDT 5.0488M | $5.048M |
| | │ | | Fluid USD Coin (`0x9fb7b447…`) | supply USDC 3.0964M | $3.096M | │ | | Fluid | Supply USDC 3.0966M | $3.096M |
| Compound V3<br>`compound3` | │ | $586.4996 | Lending (`0xc3d688b6…`) | reward COMP 25.139287 | $586.4996 | │ | $587.8187 | Compound v3 | Rewards COMP 25.139287 | $587.8187 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.086007 | $2,314.17 | $199.0342 | │ | 0.086007 | $2,318.12 | $199.3743 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.767M | DeBank filtered: $2.766M | Drift: +0.03% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $2.766M | Lending + Yield (`0x2e44e174…`) | supply USDC 756,332.5636 + reward COMP 38.421572 | $757,153.31 | │ | $2.766M | Compound v3 | Supply USDC 756,353.6751 | $756,232.66 |
| | │ | | | | | │ | | Compound v3 | Rewards COMP 38.421572 | $896.2984 |
| | │ | | Lending + Yield (`0x995e394b…`) | supply USDT 2.0059M + reward COMP 138.982925 | $2.009M | │ | | Compound v3 | Supply USDT 2.0059M | $2.005M |
| | │ | | | | | │ | | Compound v3 | Rewards COMP 138.982925 | $3,242.19 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `op` | │ | 0.049027 | $2,314.17 | $113.4572 | │ | 0.049027 | $2,314.50 | $113.4735 |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 / Lending / Rewards | COMP | 24.934844 | $581.6800 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.059M | DeBank filtered: $2.059M | Drift: -0.00% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $2.059M | Yield (`0x9c4ec768…`) | supply USDC 2.0597M | $2.059M | │ | $2.059M | Compound v3 | Supply USDC 2.0597M | $2.059M |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `arb` | │ | 0.001305 | $2,313.44 | $3.0192 | │ | 0.001305 | $2,311.44 | $3.0166 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,876.87 | DeBank filtered: $823,863.35 | Drift: +0.00% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Compound V3<br>`compound3` | │ | $823,809.31 | Lending + Yield (`0xb125e668…`) | supply USDC 823,585.9612 + reward COMP 13.108705 | $823,809.31 | │ | $823,822.84 | Compound v3 | Supply USDC 823,642.1765 | $823,517.04 |
| | │ | | | | | │ | | Compound v3 | Rewards COMP 13.108705 | $305.7999 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `base` | │ | 0.023361 | $2,313.44 | $54.0438 | │ | 0.023361 | $2,312.70 | $54.0266 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| CASHW | wallet token | $2.8304 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $17.638M | DeBank filtered: $18.174M | Drift: -2.95% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $7.763M | kpk USDC (`0x4ef53d2c…`) | supply USDC 4.6541M | $4.654M | │ | $7.762M | Morpho | Supply USDC 4.6541M | $4.654M |
| | │ | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2007M | $2.592M | │ | | Morpho | Supply EURC 2.2007M | $2.590M |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 223.271945 | $516,689.24 | │ | | Morpho | Supply WETH 223.272841 | $517,574.17 |
| LIDO<br>`lido` | │ | $2.084M | wstETH (`0x7f39c581…`) | supply stETH 212.663214 | $491,381.20 | │ | $2.087M | price feed | wstETH 172.342940 | $492,979.73 |
| | │ | | stETH (`0xae7ab965…`) | supply ETH 688.014584 | $1.592M | │ | | price feed | stETH 688.014584 | $1.594M |
| StakeWise<br>`stakewise` | │ | $548.6461 | Lending (`0x15639e82…`) | supply ETH 0.388114 + borrow osETH 0.142291 | $548.6461 | │ | $564.4152 | StakeWise V3 | Staking ETH 0.388114 | $899.6954 |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.144634 | $-335.2802 |
| Aave V3<br>`aave3` | │ | $0.0552 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0552 | │ | $0.0553 | Aave V3 | Collateral WETH 0.000024 | $0.0553 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 7.6573M | $0.9999 | $7.657M | │ | 7.6573M | $0.9999 | $7.656M |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 0.540302 | $2,314.17 | $1,250.35 | │ | 0.540302 | $2,318.12 | $1,252.49 |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 152.306225 | $0.9998 | $152.2758 | │ | 152.306225 | $0.9999 | $152.2874 |
| ETH | `eth` | │ | 56.546754 | $2,314.17 | $130,858.80 | │ | 56.546754 | $2,318.12 | $131,082.40 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Sablier (`sablier`) | protocol | $1.460M | supply: COW 7.8748M ($1.460M) → **$1.460M** |
| Uniswap V3 (`uniswap3`) | protocol | $538,592.27 | supply WETH 67.834160 + supply COW 2.0517M + reward WETH 0.256517 + reward COW 3,388.4007 |
| COW | wallet token | $3.876M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $94.404M | DeBank filtered: $94.313M | Drift: +0.10% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Sky<br>`sky` | │ | $24.613M | Savings USDS (`0xa3931d71…`) | supply USDS 24.6154M | $24.613M | │ | $24.605M | price feed | sUSDS 22.4625M | $24.605M |
| StakeWise<br>`stakewise` | │ | $23.546M | Lending (`0xac0f906e…`) | supply ETH 10,174.6160 + borrow osETH 0.000006 | $23.546M | │ | $23.586M | StakeWise V3 | Staking ETH 10,174.6160 | $23.586M |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.000006 | $-0.0139 |
| Stader<br>`stader` | │ | $23.494M | ETHx (`0xa35b1b31…`) | supply ETH 10,152.0225 | $23.494M | │ | $23.534M | price feed | ETHx 9,325.6655 | $23.534M |
| Morpho<br>`morpho` | │ | $18.609M | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.0754M | $10.074M | │ | $18.624M | Morpho | Supply USDC 10.0757M | $10.075M |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 3,687.8811 | $8.534M | │ | | Morpho | Supply WETH 3,687.9323 | $8.549M |
| Rocket Pool<br>`rocketpool` | │ | $4.047M | rETH (`0xae78736c…`) | supply ETH 1,748.7148 | $4.047M | │ | $4.054M | price feed | rETH 1,503.6269 | $4.054M |
| Compound V3<br>`compound3` | │ | $1,645.40 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,645.26 | │ | $1,649.10 | Compound v3 | Rewards COMP 70.521281 | $1,648.96 |
| | │ | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1404 | │ | | Compound v3 | Rewards COMP 0.006016 | $0.1407 |
| LIDO<br>`lido` | │ | $347.5520 | wstETH (`0x7f39c581…`) | supply stETH 0.150416 | $347.5520 | │ | $348.6827 | price feed | wstETH 0.121897 | $348.6827 |
| Aave V3<br>`aave3` | │ | $0.4353 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4353 | │ | — | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Merkl (`merkl`) | protocol | $3,468.79 | supply MORPHO 1,611.6671 |
| Uniswap V3 (`uniswap3`) | protocol | $43.8591 | supply WETH 0.001363 + supply ETH 0.015758 + reward WETH 0.000907 + reward ETH 0.000925 |
| Balancer V2 (`balancer2`) | protocol | $0.1507 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1507) → **$0.1507** |
| HEX | wallet token | $1.1380 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $7.080M | DeBank filtered: $7.064M | Drift: +0.23% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V2<br>`aave2` | │ | $1.890M | Staked (`0x4da27a54…`) | supply AAVE 19,442.9617 + reward AAVE 7.244603 | $1.890M | │ | $1.890M | Aave V3 | Staking AAVE 19,442.9617 | $1.889M |
| | │ | | | | | │ | | Aave V3 | Rewards AAVE 7.789115 | $756.9229 |
| | │ | | Lending (`0x7d2768de…`) | supply BAL 58.491558 | $9.0916 | │ | | Aave V2 | Collateral BAL 58.491558 | $9.3938 |
| StakeWise<br>`stakewise` | │ | $859,981.33 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8666 | │ | $861,441.05 | StakeWise V3 | Staking ETH 371.611265 | $861,441.05 |
| Rocket Pool<br>`rocketpool` | │ | $168,734.35 | rETH (`0xae78736c…`) | supply ETH 72.913550 | $168,734.35 | │ | $169,022.66 | price feed | rETH 62.694486 | $169,022.66 |
| Aave V3<br>`aave3` | │ | $49,995.74 | Lending (`0x87870bca…`) | supply BAL 320,154.1256 | $49,762.90 | │ | $51,417.49 | Aave V3 | Supply BAL 320,155.2866 | $51,417.49 |
| | │ | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 233.000436 | $232.8373 | │ | | — | — | — |
| Compound V3<br>`compound3` | │ | $105.0932 | Lending + Yield (`0xc3d688b6…`) | supply USDC 1.569401 + reward COMP 4.437373 | $105.0932 | │ | $105.3260 | Compound v3 | Supply USDC 1.569432 | $1.5692 |
| | │ | | | | | │ | | Compound v3 | Rewards COMP 4.437373 | $103.7568 |
| Uniswap V3<br>`uniswap3` | │ | $4.7553 | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.7553 | │ | $4.7645 | Uniswap V3 | Supply WETH 0.001972 | $4.5702 |
| | │ | | | | | │ | | Uniswap V3 | Fees WBTC 0.000002 | $0.1327 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.000027 | $0.0615 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 3.7078M | $0.9999 | $3.707M | │ | 3.7078M | $0.9999 | $3.707M |
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | │ | 2.4916M | $0.1554 | $387,280.34 | │ | 2.4916M | $0.1606 | $400,155.71 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| StakeWise (`stakewise`) | protocol | $859,971.64 | supply ETH 371.611265 |
| Balancer V2 (`balancer2`) | protocol | $35,319.42 | supply: BAL 90,822.8821 ($14,116.98) + WETH 9.162007 ($21,202.44) → **$35,319.42** |
| Across V2 (`acrocc_v2`) | protocol | $12,917.38 | supply: BAL 83,105.1188 ($12,917.38) → **$12,917.38** |
| StakeWise (`stakewise`) | protocol | $8.8246 | supply ETH 0.003813 |
| Uniswap V3 (`uniswap3`) | protocol | $4.9507 | supply WETH 0.000154 + supply ETH 0.001778 + reward WETH 0.000103 + reward ETH 0.000105 |
| Multichain (`multichain`) | protocol | $3.2896 | supply: BAL 21.164100 ($3.2896) → **$3.2896** |
| Compound (`compound`) | protocol | $2.1510 | supply: DAI 1.132199 ($1.1321) + AAVE 0.010451 ($1.0155); rewards: COMP 0.000146 ($0.0034) → **$2.1510** |
| COW | wallet token | $220,183.50 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |
| POL | wallet token | $9,437.39 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000041 | $0.0941 |
| price feed | wallet / Holding | waEthLidoGHO | 224.862945 | $232.9785 |

---

## ACCOUNT_12_MAINNET_UNISWAP_V3_LP

**Address:** `0x8d27deb2405717d649346502f52b959aab4eb3af`

### Mainnet (chain 1)

**NAV: $856.2647 | DeBank filtered: $869.2481 | Drift: -1.49% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Uniswap V3<br>`uniswap3` | │ | $772.9789 | #1276763 (`0x4e68ccd3…`) | supply WETH 0.125413 + supply USDT 0.000000 + reward WETH 0.000360 + reward USDT 0.463805 | $291.5232 | │ | $773.9212 | Uniswap V3 | Supply WETH 0.125413 | $290.7230 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.000360 | $0.8338 |
| | │ | | | | | │ | | Uniswap V3 | Fees USDT 0.463805 | $0.4637 |
| | │ | | #1231724 (`0x88e6a0c2…`) | supply USDC 271.428954 + supply WETH 0.086313 + reward USDC 5.155648 + reward WETH 0.002228 | $481.4557 | │ | | Uniswap V3 | Supply USDC 264.778817 | $264.7470 |
| | │ | | | | | │ | | Uniswap V3 | Supply WETH 0.089186 | $206.7454 |
| | │ | | | | | │ | | Uniswap V3 | Fees USDC 5.198665 | $5.1980 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.002248 | $5.2102 |
| Convex<br>`convex` | │ | $14.0545 | Staked (`0x49b4d1df…`) | supply cvxFXS 62.684670 + reward FRAX 1.860052 + reward CVX 1.434995 | $14.0545 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 7.152868 | $0.9998 | $7.1514 | │ | 7.152868 | $0.9999 | $7.1520 |
| ETH | `eth` | │ | 0.032436 | $2,314.17 | $75.0632 | │ | 0.032436 | $2,318.12 | $75.1915 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Layer3 (`layer3`) | protocol | $83.0927 | supply: L3 6,323.3042 ($71.2415); rewards: L3 1,051.8991 ($11.8512) → **$83.0927** |
| espresso (`espresso`) | protocol | $46.7952 | supply: ESP 625.520000 ($46.7952) → **$46.7952** |
| Ekubo (`ekubo`) | protocol | $12.2133 | supply: EKUBO 4.006297 ($1.9001) + gEKUBO-26Q2 6.674740 ($0.0000); rewards: EKUBO 0.140899 ($0.0668) + gEKUBO-26Q2 0.183029 ($0.0000) → **$1.9669**<br>supply: ETH 0.000000 ($0.0000) + EKUBO 21.604083 ($10.2464) → **$10.2464** |
| AEVO | wallet token | $9.9798 | `0xb528edbef013aff855ac3c50b381f253af13b997` |
| EKUBO | wallet token | $0.6748 | `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` |

---

## Section 3 — Per-Adapter Granular Detail

_One table per adapter instance × account. **Amount drift** (Δ amt %) signals a balance-adapter issue. **Price drift** (Δ price %) signals a price-feed issue. If both are small but USD drift is large, check decimal/precision handling in the price computation._

_Severity: **OK** ≤1% · **WARN** 1–5% · **FAIL** >5%. Rows sorted by descending NAV USD._
_`nav_only` rows (no DeBank match) are listed in a separate subsection._

### StakeWise V3 — Mainnet (chain 1) — `0xAC0F906E43…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 371.611265 | 0.000374 | FAIL +99229977.62% | $2,318.12 | $2,314.17 | OK +0.17% | $861,441.05 | $0.8666 | FAIL +99399529.39% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 10,174.6160 | 10,174.6160 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $23.586M | $23.546M | OK +0.17% |
| ETH (Borrow) | − | 0.000006 | 10,174.6160 | FAIL -100.00% | $2,318.12 | $2,314.17 | OK +0.17% | $-0.0139 | $23.546M | FAIL -100.00% |

### Morpho — Mainnet (chain 1) — `0x4Ef53d2cAa…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.0757M | 10.0754M | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $10.075M | $10.074M | OK +0.00% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 4.6541M | 4.6541M | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $4.654M | $4.654M | OK -0.00% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.088176 | 10.087890 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $10.0870 | $10.0869 | OK +0.00% |

### Aave V3 — Mainnet (chain 1) — `0x87870Bca3F…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Supply) | + | 320,155.2866 | 320,154.1256 | OK +0.00% | $0.1606 | $0.1554 | WARN +3.32% | $51,417.49 | $49,762.90 | WARN +3.32% |

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.009367 | 0.009367 | OK +0.00% | $2,860.46 | $2,851.52 | OK +0.31% | $26.7942 | $26.7105 | OK +0.31% |
| WETH (Collateral) | + | 0.002969 | 0.002969 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $6.8831 | $6.8712 | OK +0.17% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Collateral) | + | 0.000024 | 0.000024 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $0.0553 | $0.0552 | OK +0.17% |

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| rsETH (Collateral) | + | 2,326.4202 | 2,326.4202 | OK +0.00% | $2,479.49 | $2,474.88 | OK +0.19% | $5.768M | $5.758M | OK +0.19% |
| WETH (Borrow) | − | 2,001.9434 | 2,001.9287 | OK +0.00% | $2,318.12 | $2,313.75 | OK +0.19% | $-4.641M | $4.632M | FAIL -200.19% |
| WETH (Collateral) | + | 0.011599 | 0.011599 | OK +0.00% | $2,318.12 | $2,313.75 | OK +0.19% | $26.8885 | $26.8376 | OK +0.19% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| RLUSD (Supply) | + | 14.674290 | 14.674080 | OK +0.00% | $1.0000 | $1.0001 | OK -0.01% | $14.6740 | $14.6755 | OK -0.01% |
| USDT (Collateral) | + | 10.088521 | 10.088213 | OK +0.00% | $0.9999 | $0.9998 | OK +0.01% | $10.0873 | $10.0862 | OK +0.01% |
| USDC (Collateral) | + | 9.085063 | 9.084768 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $9.0840 | $9.0839 | OK +0.00% |
| USDe (Collateral) | + | 5.025642 | 5.025485 | OK +0.00% | $0.9996 | $0.9994 | OK +0.02% | $5.0237 | $5.0225 | OK +0.03% |
| sUSDe (Collateral) | + | 3.000000 | 3.000000 | OK +0.00% | $1.2302 | $1.2299 | OK +0.02% | $3.6905 | $3.6897 | OK +0.02% |

### Morpho — Mainnet (chain 1) — `0xBb50A53413…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 3,687.9323 | 3,687.8811 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $8.549M | $8.534M | OK +0.17% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 223.272841 | 223.271945 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $517,574.17 | $516,689.24 | OK +0.17% |

### Fluid — Mainnet (chain 1) — `0x5C20B55081…`

#### ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 5.0488M | 5.0485M | OK +0.01% | $0.9999 | $0.9997 | OK +0.02% | $5.048M | $5.047M | OK +0.02% |

### Fluid — Mainnet (chain 1) — `0x9Fb7b44775…`

#### ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 3.0966M | 3.0964M | OK +0.01% | $0.9999 | $0.9999 | OK -0.00% | $3.096M | $3.096M | OK +0.00% |

### Morpho — Mainnet (chain 1) — `0xa877d5BB02…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| EURC (Supply) | + | 2.2007M | 2.2007M | OK +0.00% | $1.1771 | $1.1780 | OK -0.08% | $2.590M | $2.592M | OK -0.08% |

### Aave V3 — Mainnet (chain 1) — `0x4da27a545c…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| AAVE (Staking) | + | 19,442.9617 | 19,442.9617 | OK +0.00% | $97.1770 | $97.1700 | OK +0.01% | $1.889M | $1.889M | OK +0.01% |
| AAVE (Rewards) | + | 7.789115 | 7.244603 | FAIL +7.52% | $97.1770 | $97.1700 | OK +0.01% | $756.9229 | $703.9581 | FAIL +7.52% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Staking) | + | 10.000000 | 10.000000 | OK +0.00% | $0.9999 | $0.9993 | OK +0.06% | $9.9989 | $9.9930 | OK +0.06% |

### Aave V3 — Mainnet (chain 1) — `0x4655Ce3D62…`

#### ACCOUNT_4_UMBRELLA (`0x13ce0c…5f86df`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Staking) | + | 66,390.6641 | 66,390.6641 | OK +0.00% | $0.9999 | $0.9993 | OK +0.06% | $66,383.37 | $66,344.19 | OK +0.06% |
| USDC (Staking) | + | 65,211.9234 | 65,211.9894 | OK -0.00% | $0.9999 | $0.9999 | OK -0.00% | $65,204.10 | $65,205.47 | OK -0.00% |
| USDT (Staking) | + | 27,666.0711 | 27,666.1013 | OK -0.00% | $0.9999 | $0.9997 | OK +0.02% | $27,662.65 | $27,657.80 | OK +0.02% |
| WETH (Staking) | + | 7.515600 | 7.515603 | OK -0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $17,422.09 | $17,392.38 | OK +0.17% |
| GHO (Rewards) | + | 87.064859 | 83.509673 | WARN +4.26% | $0.9999 | $0.9993 | OK +0.06% | $87.0553 | $83.4512 | WARN +4.32% |
| USDC (Rewards) | + | 31.218313 | 29.354205 | FAIL +6.35% | $0.9999 | $0.9999 | OK -0.00% | $31.2146 | $29.3513 | FAIL +6.35% |
| USDT (Rewards) | + | 15.836303 | 15.016499 | FAIL +5.46% | $0.9999 | $0.9997 | OK +0.02% | $15.8343 | $15.0120 | FAIL +5.48% |
| WETH (Rewards) | + | 0.002828 | 0.002680 | FAIL +5.51% | $2,318.12 | $2,314.17 | OK +0.17% | $6.5549 | $6.2022 | FAIL +5.69% |

### Compound v3 — Mainnet (chain 1) — `0x5D409e56D8…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| COMP (Rewards) | + | 70.521281 | 70.521281 | OK +0.00% | $23.3825 | $23.3300 | OK +0.22% | $1,648.96 | $1,645.26 | OK +0.22% |

### StakeWise V3 — Mainnet (chain 1) — `0x15639e82d2…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 0.388114 | 0.388114 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $899.6954 | $898.1607 | OK +0.17% |
| ETH (Borrow) | − | 0.144634 | 0.388114 | FAIL -62.73% | $2,318.12 | $2,314.17 | OK +0.17% | $-335.2802 | $898.1607 | FAIL -137.33% |

### Compound v3 — Mainnet (chain 1) — `0xc3d688B667…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| COMP (Rewards) | + | 4.437373 | 4.437373 | OK +0.00% | $23.3825 | $23.3300 | OK +0.22% | $103.7568 | $103.5239 | OK +0.22% |
| USDC (Supply) | + | 1.569432 | 1.569401 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $1.5692 | $1.5692 | OK -0.00% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| COMP (Rewards) | + | 0.006016 | 0.006016 | OK +0.00% | $23.3825 | $23.3300 | OK +0.22% | $0.1407 | $0.1404 | OK +0.22% |

#### ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| COMP (Rewards) | + | 25.139287 | 25.139287 | OK +0.00% | $23.3825 | $23.3300 | OK +0.22% | $587.8187 | $586.4996 | OK +0.22% |

### Uniswap V3 — Mainnet (chain 1) — `0x88e6A0c2dD…`

#### ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 264.778817 | 271.428954 | WARN -2.45% | $0.9999 | $0.9999 | OK -0.00% | $264.7470 | $271.4018 | WARN -2.45% |
| WETH (Supply) | + | 0.089186 | 0.086313 | WARN +3.33% | $2,318.12 | $2,314.17 | OK +0.17% | $206.7454 | $199.7429 | WARN +3.51% |
| WETH (Fees) | + | 0.002248 | 0.002228 | OK +0.88% | $2,318.12 | $2,314.17 | OK +0.17% | $5.2102 | $5.1559 | WARN +1.05% |
| USDC (Fees) | + | 5.198665 | 5.155648 | OK +0.83% | $0.9999 | $0.9999 | OK -0.00% | $5.1980 | $5.1551 | OK +0.83% |

### Uniswap V3 — Mainnet (chain 1) — `0x4e68Ccd3E8…`

#### ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.125413 | 0.125413 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $290.7230 | $290.2271 | OK +0.17% |
| WETH (Fees) | + | 0.000360 | 0.000360 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $0.8338 | $0.8323 | OK +0.17% |
| USDT (Fees) | + | 0.463805 | 0.463805 | OK +0.00% | $0.9999 | $0.9998 | OK +0.01% | $0.4637 | $0.4637 | OK +0.01% |

### Balancer V3 — Mainnet (chain 1) — `0x1ea5870f7C…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Staking) | + | 0.017715 | 0.017715 | OK -0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $41.0646 | $40.9945 | OK +0.17% |
| rETH (Staking) | + | 0.014861 | — | — | $2,695.97 | — | — | $40.0644 | — | — |
| BAL (Staking) | + | 0.757598 | 0.757598 | OK -0.00% | $0.1606 | $0.1554 | WARN +3.32% | $0.1217 | $0.1178 | WARN +3.32% |

### Aave V3 — Mainnet (chain 1) — `0x4e033931ad…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.005000 | 0.005000 | OK +0.00% | $2,860.46 | $2,851.52 | OK +0.31% | $14.3036 | $14.2588 | OK +0.31% |
| ezETH (Collateral) | + | 0.005000 | 0.005000 | OK +0.00% | $2,497.41 | $2,493.62 | OK +0.15% | $12.4870 | $12.4681 | OK +0.15% |
| WETH (Borrow) | − | 0.005026 | 0.005025 | OK +0.01% | $2,318.12 | $2,314.17 | OK +0.17% | $-11.6513 | $11.6299 | FAIL -200.18% |
| WETH (Collateral) | + | 0.005020 | 0.005020 | OK +0.01% | $2,318.12 | $2,314.17 | OK +0.17% | $11.6373 | $11.6161 | OK +0.18% |

### Convex — Mainnet (chain 1) — `0x5411CC583f…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| weETH (Staking) | + | 0.010365 | — | — | $2,531.64 | — | — | $26.2409 | — | — |
| WETH (Staking) | + | 0.001414 | 0.001414 | OK -0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $3.2776 | $3.2720 | OK +0.17% |
| CRV (Staking) | + | 0.204673 | 0.200362 | WARN +2.15% | $0.2556 | $0.2553 | OK +0.12% | $0.0523 | $0.0512 | WARN +2.27% |
| CVX (Staking) | + | 0.000205 | 0.000067 | FAIL +206.95% | $1.7819 | $1.7844 | OK -0.14% | $0.0004 | $0.0001 | FAIL +206.52% |

### Morpho — Mainnet (chain 1) — `0xd9e34b1eed…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 18.401201 | 16.183234 | FAIL +13.71% | $0.9999 | $0.9999 | OK -0.00% | $18.3990 | $16.1816 | FAIL +13.70% |

### Morpho — Mainnet (chain 1) — `0xb323495f7e…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.091407 | 10.091143 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $10.0902 | $10.0901 | OK +0.00% |

### Morpho — Mainnet (chain 1) — `0x64d65c9a2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.091407 | 10.091148 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $10.0902 | $10.0901 | OK +0.00% |

### Morpho — Mainnet (chain 1) — `0xe108fbc048…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.088454 | 10.088181 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $10.0872 | $10.0872 | OK +0.00% |

### Cap — Mainnet (chain 1) — `0x88887bE419…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.052274 | — | — | $0.9999 | — | — | $10.0511 | $5.0616 | FAIL +98.57% |

### Aave V2 — Mainnet (chain 1) — `0x7d2768dE32…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Collateral) | + | 58.491558 | 58.491558 | OK +0.00% | $0.1606 | $0.1554 | WARN +3.32% | $9.3938 | $9.0916 | WARN +3.32% |

### Balancer V3 — Mainnet (chain 1) — `0x85B2b559bC…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 2.618229 | 2.552629 | WARN +2.57% | $0.9999 | $0.9999 | OK -0.00% | $2.6179 | $2.5524 | WARN +2.57% |
| GHO (Supply) | + | 2.551318 | 2.553107 | OK -0.07% | $0.9999 | $0.9993 | OK +0.06% | $2.5510 | $2.5513 | OK -0.01% |
| USDT (Supply) | + | 1.836136 | 1.899951 | WARN -3.36% | $0.9999 | $0.9998 | OK +0.01% | $1.8359 | $1.8996 | WARN -3.35% |

### Morpho — Mainnet (chain 1) — `0x3274643db7…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 5.040068 | 5.039935 | OK +0.00% | $0.9999 | $0.9998 | OK +0.01% | $5.0394 | $5.0389 | OK +0.01% |

### Uniswap V3 — Mainnet (chain 1) — `0xCBCdF9626b…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.001972 | 0.001972 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $4.5702 | $4.5624 | OK +0.17% |
| WBTC (Fees) | + | 0.000002 | 0.000002 | OK +0.61% | $80,441.90 | $80,179.21 | OK +0.33% | $0.1327 | $0.1315 | OK +0.94% |
| WETH (Fees) | + | 0.000027 | 0.000027 | OK +0.00% | $2,318.12 | $2,314.17 | OK +0.17% | $0.0615 | $0.0614 | OK +0.17% |

### Merkl — Mainnet (chain 1) — `0x3Ef3D8bA38…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| RPL (Rewards) | + | 0.112713 | 0.109194 | WARN +3.22% | $2.0544 | $2.0477 | OK +0.33% | $0.2316 | $0.2236 | WARN +3.56% |

### Aura — Mainnet (chain 1) — `0x1ea5870f7C…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Staking) | + | 0.489289 | 0.489289 | OK +0.00% | $0.1606 | $0.1554 | WARN +3.32% | $0.0786 | $0.0761 | WARN +3.32% |

### Compound v3 — Optimism (chain 10) — `0x995E394b8B…`

#### ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 2.0059M | 2.0059M | OK +0.00% | $0.9998 | $0.9997 | OK +0.01% | $2.005M | $2.005M | OK +0.01% |
| COMP (Rewards) | + | 138.982925 | 138.982925 | OK +0.00% | $23.3280 | $23.3300 | OK -0.01% | $3,242.19 | $3,242.47 | OK -0.01% |

### Compound v3 — Optimism (chain 10) — `0x2e44e174f7…`

#### ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 756,353.6751 | 756,332.5636 | OK +0.00% | $0.9998 | $0.9999 | OK -0.01% | $756,232.66 | $756,256.94 | OK -0.00% |
| COMP (Rewards) | + | 38.421572 | 38.421572 | OK +0.00% | $23.3280 | $23.3300 | OK -0.01% | $896.2984 | $896.3753 | OK -0.01% |

### Aave V3 — Gnosis (chain 100) — `0xb50201558B…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WXDAI (Collateral) | + | 2.009289 | 2.009190 | OK +0.00% | $0.9998 | $0.9999 | OK -0.01% | $2.0088 | $2.0090 | OK -0.01% |

### Compound v3 — Arbitrum (chain 42161) — `0x9c4ec768c2…`

#### ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 2.0597M | 2.0597M | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $2.059M | $2.059M | OK -0.00% |

### Aave V3 — Arbitrum (chain 42161) — `0x794a61358D…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 2.012734 | 2.012723 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $2.0124 | $2.0125 | OK -0.00% |
| GHO (Borrow) | − | 1.010996 | 1.010989 | OK +0.00% | $0.9999 | $0.9999 | OK -0.01% | $-1.0109 | $1.0109 | FAIL -200.00% |

### Morpho — Arbitrum (chain 42161) — `0x2C609d9CfC…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.011322 | 1.011307 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $1.0112 | $1.0112 | OK -0.00% |

### Morpho — Arbitrum (chain 42161) — `0x77fe2f7c2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.007521 | 1.007518 | OK +0.00% | $0.9999 | $0.9999 | OK -0.00% | $1.0074 | $1.0074 | OK -0.00% |

### Compound v3 — Base (chain 8453) — `0xb125E6687d…`

#### ACCOUNT_8_COMPOUND_BASE (`0xa46680…623314`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 823,642.1765 | 823,585.9612 | OK +0.01% | $0.9998 | $0.9999 | OK -0.01% | $823,517.04 | $823,503.61 | OK +0.00% |
| COMP (Rewards) | + | 13.108705 | 13.108705 | OK +0.00% | $23.3280 | $23.3200 | OK +0.03% | $305.7999 | $305.6950 | OK +0.03% |

### NAV-only positions (no DeBank counterpart matched)

_These adapter positions are counted in the headline NAV but have no DeBank row. See Section 2 inline tables for rationale._

| Chain | Account | Protocol | Leg | NAV amount | NAV unit $ | NAV USD |
|---|---|---|---|---:|---:|---:|
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Compound v3 | COMP (Rewards) | 24.934844 | $23.3280 | $581.6800 |

---

## Section 4 — Coverage Gaps

_Use this section to identify missing adapter registrations, unregistered tokens, or missing price feeds._

### 4.1 — DeBank protocols with value not in `supportedDeBankProtocols`

_These show non-zero DeBank balance but are absent from the per-chain allowlist in `accounts.json`. If an NAV adapter exists for the protocol, consider adding it to `supportedDeBankProtocols` and registering the adapter on that chain._

| Chain | Account | Protocol | DeBank ID | Value | NAV adapter? |
|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Sablier | `sablier` | $1.460M | Yes (`Sablier`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $859,971.64 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Uniswap V3 | `uniswap3` | $538,592.27 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Balancer V2 | `balancer2` | $35,319.42 | Yes (`Balancer V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Across V2 | `acrocc_v2` | $12,917.38 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Merkl | `merkl` | $3,468.79 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Layer3 | `layer3` | $83.0927 | No |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | espresso | `espresso` | $46.7952 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Uniswap V3 | `uniswap3` | $43.8591 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_2 | Merkl | `merkl` | $26.9226 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Ekubo | `ekubo` | $12.2133 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $8.8246 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Uniswap V3 | `uniswap3` | $4.9507 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Multichain | `multichain` | $3.2896 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Compound | `compound` | $2.1510 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Balancer V2 | `balancer2` | $0.1507 | Yes (`Balancer V3`) |

### 4.2 — Supported protocol items with no NAV match

_The protocol IS in `supportedDeBankProtocols` but no NAV position matched the item. Possible causes: adapter not deployed on this chain, token not in NAV registry, price feed missing, or account has zero balance in this market._

| Chain | Account | Protocol | DeBank ID | Item | Value | Hint |
|---|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Aave V3 | `aave3` | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | $232.8373 | Adapter registered but no matching position (zero balance or positionDetail mismatch) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Convex | `convex` | Staked (`0x49b4d1df…`) | $14.0545 | No NAV adapter/feed registered for `convex` on chain 1 |

