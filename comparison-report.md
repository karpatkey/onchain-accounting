# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-06 20:20 UTC  
Tolerance: 1%

Debank anchor: from `accounts.json.expected.<cid>.debankUsd` (captured at forge-snapshot time). Re-run with `--refresh-debank` to recapture against current chain state.  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25033963 |
| optimism (10) | 151223694 |
| gnosis (100) | 46030673 |
| base (8453) | 45628409 |
| arbitrum (42161) | 459884021 |

## Drift summary

**13 of 14 account-chain pairs within 1% tolerance.** ⚠ 1 over tolerance — see per-account section for breakdown.

| Account | Chain | NAV | Debank filtered | Drift |  |
|---|---|---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | $180.8266 | $180.0952 | +0.41% | ✅ |
| ACCOUNT_1 | gnosis | $5.0066 | $5.0048 | +0.04% | ✅ |
| ACCOUNT_1 | base | $9.9998 | $10.0023 | -0.03% | ✅ |
| ACCOUNT_1 | arbitrum | $10.0257 | $10.0256 | +0.00% | ✅ |
| ACCOUNT_2 | mainnet | $1.152M | $1.155M | -0.20% | ✅ |
| ACCOUNT_3 | mainnet | $277.9740 | $277.0304 | +0.34% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | $177,054.60 | $176,966.64 | +0.05% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | $8.143M | $8.144M | -0.01% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | $2.766M | $2.766M | +0.03% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | $2.059M | $2.060M | -0.02% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | $823,580.72 | $823,809.64 | -0.03% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | $17.551M | $18.074M | -2.90% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | $96.090M | $95.850M | +0.25% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | $5.036M | $5.028M | +0.17% | ✅ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $180.8266 | Debank filtered: $180.0952 | Drift: +0.41% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | $61.5765 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.085562 | $10.0866 | Morpho Vault | supply USDC 10.084988 | $10.0835 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.088899 | $10.0899 | Morpho Blue - cbBTC/USDC | supply USDC 10.088471 | $10.0870 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.038943 | $5.0383 | Morpho Blue - sUSDS/USDT | supply USDT 5.038717 | $5.0384 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1849 | Morpho Blue - wstUSR/USDC | supply USDC 17.241575 | $17.2390 |
| | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.089028 | $10.0900 | Morpho Blue - wstETH/USDC | supply USDC 10.088358 | $10.0868 |
| | | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.085761 | $10.0868 | Morpho Vault | supply USDC 10.084863 | $10.0834 |
| Aave V3 | `aave3` | $52.5576 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.9940 | Aave V3 Safety Module | supply GHO 10.000000 | $9.9982 |
| | | | Lending (`0x87870bca…`) | supply USDC 9.082988 + supply USDT 10.085840 + supply USDe 5.024260 + supply sUSDe 3.000000 + supply RLUSD 14.672233 + reward USDS 0.008929 | $42.5636 | Aave V3 Core | supply USDC 9.082470 | $9.0811 |
| | | | | | | Aave V3 Core | supply USDT 10.085217 | $10.0845 |
| | | | | | | Aave V3 Core | supply USDe 5.023932 | $5.0205 |
| | | | | | | Aave V3 Core | supply sUSDe 3.000000 | $3.6884 |
| | | | | | | Aave V3 Core | supply RLUSD 14.671723 | $14.6718 |
| Balancer V3 | `balancer3` | $7.0021 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.655245 + supply GHO 3.626983 + supply USDC 1.722050 | $7.0021 | Balancer V3 - Aave GHO/USDT/USDC | supply USDT 1.977702 | $1.9776 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply GHO 2.932516 | $2.9320 |
| | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply USDC 2.093617 | $2.0933 |
| cap | `capapp` | $5.0609 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.060470 | $5.0609 | — | — | — |
| Sky | `sky` | $5.0530 | Savings USDS (`0xa3931d71…`) | supply USDS 5.054053 | $5.0530 | price feed | sUSDS 4.612968 | $5.0517 |
| Ethena | `ethena` | $4.4854 | sUSDe (`0x9d39a5de…`) | supply USDe 4.487658 | $4.4854 | price feed | sUSDe 3.647417 | $4.4844 |
| Merkl | `merkl` | $0.3030 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.139163 + supply USDT 0.000056 + supply USDC 0.000058 | $0.3030 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | 8.905915 | $0.9994 | $8.9006 | price feed (wallet/Holding) | 8.905915 | $8.9043 |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | 0.999922 | $0.9995 | $0.9994 | price feed (wallet/Holding) | 0.999922 | $0.9992 |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.626826 | $1.0001 | $9.6278 | price feed (wallet/Holding) | 9.626826 | $9.6254 |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | 4.990006 | $1.0001 | $4.9905 | — | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 4.717667 | $0.9999 | $4.7171 | price feed (wallet/Holding) | 4.717667 | $4.7174 |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | 14.831886 | $0.9998 | $14.8289 | price feed (wallet/Holding) | 14.831886 | $14.8257 |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Cap / cUSD + stcUSD | USDC | 10.050103 | $10.0486 |

### Gnosis (chain 100)

**NAV: $5.0066 | Debank filtered: $5.0048 | Drift: +0.04% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $2.0085 | Lending (`0xb5020155…`) | supply WXDAI 2.008898 | $2.0085 | Aave V3 Gnosis | supply WXDAI 2.008829 | $2.0088 |
| Gnosis | `gnosis` | $0.0000 | — | — | — | price feed | sDAI 0.000014 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | 0.998493 | $0.9995 | $0.9980 | price feed (wallet/Holding) | 0.998493 | $0.9983 |
| xDai | `xdai` | 1.999518 | $0.9998 | $1.9991 | price feed (wallet/Holding) | 1.999518 | $1.9995 |

### Base (chain 8453)

**NAV: $9.9998 | Debank filtered: $10.0023 | Drift: -0.03% ✅**

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | 10.001207 | $1.0001 | $10.0022 | price feed (wallet/Holding) | 10.001207 | $9.9997 |

### Arbitrum (chain 42161)

**NAV: $10.0257 | Debank filtered: $10.0256 | Drift: +0.00% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | $2.0189 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.010979 | $1.0111 | Morpho Vault | supply USDC 1.010886 | $1.0108 |
| | | | Deposit (`0x6c247b1f…`) | supply USDC 1.007352 | $1.0075 | Morpho Blue - sUSDS/USDC | supply USDC 1.007308 | $1.0072 |
| Aave V3 | `aave3` | $1.0024 | Lending (`0x794a6135…`) | supply USDC 2.012319 + borrow GHO 1.009986 | $1.0024 | Aave V3 Arbitrum | supply USDC 2.012214 | $2.0120 |
| | | | | | | Aave V3 Arbitrum | borrow GHO 1.009910 | $-1.0097 |
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

**NAV: $1.152M | Debank filtered: $1.155M | Drift: -0.20% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $1.146M | Lending (`0x87870bca…`) | supply WETH 0.011598 + supply rsETH 2,326.4202 + borrow WETH 2,001.5848 | $1.146M | Aave V3 Core | supply WETH 0.011597 | $27.4250 |
| | | | | | | Aave V3 Core | supply rsETH 2,326.4202 | $5.885M |
| | | | | | | Aave V3 Core | borrow WETH 2,001.4832 | $-4.733M |
| Kelp DAO | `kelpdao` | $737.2768 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $737.2768 | price feed | rsETH 0.292977 | $741.0639 |
| Merkl | `merkl` | $26.6638 | Rewards (`0x3ef3d8ba…`) | supply GEAR 91,169.3043 + supply ETH 0.000000 | $26.6638 | — | — | — |
| LIDO | `lido` | $0.0058 | — | — | — | price feed | wstETH 0.000002 | $0.0058 |
| | | | | | | price feed | stETH 0.000000 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.002564 | $2,352.73 | $6.0332 | price feed (wallet/Holding) | 0.002564 | $6.0641 |

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $277.9740 | Debank filtered: $277.0304 | Drift: +0.34% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Balancer V3 | `balancer3` | $82.4499 | Farming (`0x62a66eb9…`) | supply WETH 0.017517 + supply ETH 0.017477 + reward BAL 0.757598 | $82.4499 | Balancer V3 - rETH/Aave WETH | supply WETH 0.017348 | $41.0243 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply BAL 0.757598 | $0.1168 |
| | | | | | | Balancer V3 - rETH/Aave WETH | supply rETH 0.015174 | $41.7258 |
| Aave V3 | `aave3` | $68.6467 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005019 + supply ezETH 0.005000 + borrow WETH 0.005025 | $27.1752 | Aave V3 Prime | supply wstETH 0.005000 | $14.5883 |
| | | | | | | Aave V3 Prime | supply WETH 0.005019 | $11.8686 |
| | | | | | | Aave V3 Prime | supply ezETH 0.005000 | $12.7372 |
| | | | | | | Aave V3 Prime | borrow WETH 0.005025 | $-11.8821 |
| | | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.059712 + borrow WETH 0.059007 | $41.4714 | Aave V3 Core | supply WETH 0.002969 | $7.0205 |
| | | | | | | Aave V3 Core | supply wstETH 0.059712 | $174.2042 |
| | | | | | | Aave V3 Core | borrow WETH 0.059006 | $-139.5372 |
| Rocket Pool | `rocketpool` | $41.0019 | rETH (`0xae78736c…`) | supply ETH 0.017427 | $41.0019 | price feed | rETH 0.014986 | $41.2102 |
| Convex | `convex` | $30.0557 | Staked (`0x5411cc58…`) | supply WETH 0.001293 + supply ETH 0.011461 + reward CRV 0.187681 + reward CVX 0.000063 | $30.0557 | Convex | supply WETH 0.001260 | $2.9789 |
| | | | | | | Convex | supply CRV 0.186353 | $0.0456 |
| | | | | | | Convex | supply weETH 0.010506 | $27.1070 |
| | | | | | | Convex | supply CVX 0.000186 | $0.0003 |
| ether.fi | `etherfi` | $21.2044 | weETH (`0xcd5fe23c…`) | supply ETH 0.009013 | $21.2044 | price feed | weETH 0.008237 | $21.2532 |
| Kelp DAO | `kelpdao` | $10.8033 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.8033 | price feed | rsETH 0.004293 | $10.8588 |
| Merkl | `merkl` | $0.2249 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000007 + supply ETH 0.000007 + supply GEAR 6.174863 + supply RPL 0.098307 | $0.2249 | Merkl | supply RPL 0.096456 | $0.1873 |
| Aura Finance | `aurafinance` | $0.0956 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.130822 | $0.0956 | Aura | supply BAL 0.489289 | $0.0754 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.002000 | $2,352.73 | $4.7055 | price feed (wallet/Holding) | 0.002000 | $4.7296 |
| ETH | `eth` | 0.007468 | $2,352.73 | $17.5709 | price feed (wallet/Holding) | 0.007468 | $17.6612 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $177,054.60 | Debank filtered: $176,966.64 | Drift: +0.05% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | $176,962.48 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 46.766070 | $66,397.57 | Aave Umbrella | supply GHO 66,390.6641 | $66,378.85 |
| | | | | | | Aave Umbrella | supply GHO 42.782503 | $42.7749 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,197.0217 + reward USDC 14.777622 | $65,218.32 | Aave Umbrella | supply USDC 65,193.3125 | $65,183.53 |
| | | | | | | Aave Umbrella | supply USDC 13.474822 | $13.4728 |
| | | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,658.7152 + reward USDT 7.994772 | $27,663.39 | Aave Umbrella | supply USDT 27,657.0114 | $27,655.17 |
| | | | | | | Aave Umbrella | supply USDT 7.311099 | $7.3106 |
| | | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.514612 + reward WETH 0.001422 | $17,683.20 | Aave Umbrella | supply WETH 7.514219 | $17,769.74 |
| | | | | | | Aave Umbrella | supply WETH 0.001302 | $3.0779 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.000282 | $2,352.73 | $0.6637 | price feed (wallet/Holding) | 0.000282 | $0.6671 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.143M | Debank filtered: $8.144M | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Fluid | `fluid` | $5.047M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0475M | $5.047M | Fluid Lending | supply USDT 5.0474M | $5.047M |
| Compound V3 | `compound3` | $3.097M | Lending (`0xc3d688b6…`) | reward COMP 24.720004 | $581.4145 | Compound v3 USDC | supply COMP 24.659673 | $591.7382 |
| | | | Yield (`0xc3d688b6…`) | supply USDC 3.0959M | $3.096M | Compound v3 USDC | supply USDC 3.0958M | $3.095M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `eth` | 0.086040 | $2,352.73 | $202.4282 | price feed (wallet/Holding) | 0.086040 | $203.4680 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.766M | Debank filtered: $2.766M | Drift: +0.03% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $2.766M | Lending (`0x2e44e174…`) | reward COMP 38.421572 | $903.2912 | Compound v3 USDC | supply COMP 38.421572 | $918.4474 |
| | | | Yield (`0x2e44e174…`) | supply USDC 756,169.7730 | $756,245.40 | Compound v3 USDC | supply USDC 756,155.9060 | $756,040.65 |
| | | | Lending (`0x995e394b…`) | reward COMP 138.982925 | $3,267.49 | Compound v3 USDT | supply COMP 138.982925 | $3,322.31 |
| | | | Yield (`0x995e394b…`) | supply USDT 2.0055M | $2.005M | Compound v3 USDT | supply USDT 2.0055M | $2.005M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `op` | 0.049027 | $2,352.28 | $115.3257 | price feed (wallet/Holding) | 0.049027 | $115.6409 |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 WETH / Reward | COMP | 24.934844 | $596.0543 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.059M | Debank filtered: $2.060M | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $2.060M | Yield (`0x9c4ec768…`) | supply USDC 2.0593M | $2.060M | Compound v3 USDC | supply USDC 2.0593M | $2.059M |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `arb` | 0.001305 | $2,352.73 | $3.0705 | price feed (wallet/Holding) | 0.001305 | $3.0786 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,580.72 | Debank filtered: $823,809.64 | Drift: -0.03% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | $823,753.83 | Lending (`0xb125e668…`) | reward COMP 13.108705 | $308.3167 | Compound v3 USDC | supply COMP 13.108705 | $312.1135 |
| | | | Yield (`0xb125e668…`) | supply USDC 823,363.1658 | $823,445.51 | Compound v3 USDC | supply USDC 823,341.4289 | $823,213.59 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| ETH | `base` | 0.023361 | $2,352.73 | $54.9617 | price feed (wallet/Holding) | 0.023361 | $55.0154 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| CASHW | wallet token | $2.8785 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $17.551M | Debank filtered: $18.074M | Drift: -2.90% ⚠️**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | $5.766M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.6530M | $2.653M | Morpho Vault | supply USDC 2.6528M | $2.652M |
| | | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2006M | $2.587M | — | — | — |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 223.238257 | $525,219.34 | Morpho Vault | supply WETH 223.233044 | $527,904.86 |
| LIDO | `lido` | $2.119M | wstETH (`0x7f39c581…`) | supply stETH 212.629265 | $500,251.25 | price feed | wstETH 172.342940 | $502,793.98 |
| | | | stETH (`0xae7ab965…`) | supply ETH 687.904751 | $1.618M | price feed | stETH 687.856992 | $1.628M |
| Uniswap V3 | `uniswap3` | $527,481.89 | #1213124 (`0xfbb81382…`) | supply WETH 54.340018 + supply COW 2.2250M + reward WETH 0.174326 + reward COW 2,771.3584 | $527,481.89 | — | — | — |
| StakeWise | `stakewise` | $557.4167 | Lending (`0x15639e82…`) | supply ETH 0.388040 + borrow osETH 0.142290 | $557.4167 | — | — | — |
| Aave V3 | `aave3` | $0.0561 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0561 | Aave V3 Core | supply WETH 0.000024 | $0.0564 |
| Compound V3 | `compound3` | $0.0014 | — | — | — | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 9.6573M | $1.0001 | $9.658M | price feed (wallet/Holding) | 9.6573M | $9.656M |
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | 0.540302 | $2,352.73 | $1,271.19 | price feed (wallet/Holding) | 0.540302 | $1,277.72 |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 152.306225 | $0.9999 | $152.2879 | price feed (wallet/Holding) | 152.306225 | $152.2961 |
| ETH | `eth` | 56.546754 | $2,352.73 | $133,039.24 | — | — | — |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Sablier (`sablier`) | protocol | $1.417M | supply: COW 7.9090M ($1.417M) → **$1.417M** |
| COW | wallet token | $3.747M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $96.090M | Debank filtered: $95.850M | Drift: +0.25% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| Sky | `sky` | $29.604M | Savings USDS (`0xa3931d71…`) | supply USDS 29.6099M | $29.604M | price feed | sUSDS 27.0258M | $29.596M |
| StakeWise | `stakewise` | $23.935M | Lending (`0xac0f906e…`) | supply ETH 10,173.1327 + borrow osETH 0.000006 | $23.935M | Stakewise v3 | supply ETH 10,385.1012 | $24.559M |
| Stader | `stader` | $23.882M | ETHx (`0xa35b1b31…`) | supply ETH 10,150.8265 | $23.882M | — | — | — |
| Morpho | `morphoblue` | $13.747M | kpk USDC (`0x4ef53d2c…`) | supply USDC 5.0715M | $5.072M | Morpho Vault | supply USDC 5.0711M | $5.070M |
| | | | kpk ETH (`0xbb50a534…`) | supply WETH 3,687.4003 | $8.675M | Morpho Vault | supply WETH 3,449.8932 | $8.158M |
| Rocket Pool | `rocketpool` | $4.114M | rETH (`0xae78736c…`) | supply ETH 1,748.5441 | $4.114M | price feed | rETH 1,503.6269 | $4.135M |
| Merkl | `merkl` | $3,630.44 | Rewards (`0x3ef3d8ba…`) | supply MORPHO 1,611.6671 | $3,630.44 | — | — | — |
| Compound V3 | `compound3` | $1,658.80 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,658.66 | Compound v3 USDS | supply COMP 70.521281 | $1,692.24 |
| | | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1415 | Compound v3 USDC | supply COMP 0.006016 | $0.1444 |
| LIDO | `lido` | $353.8258 | wstETH (`0x7f39c581…`) | supply stETH 0.150392 | $353.8258 | price feed | wstETH 0.121897 | $355.6242 |
| Uniswap V3 | `uniswap3` | $44.5888 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.001364 + supply ETH 0.015757 + reward WETH 0.000907 + reward ETH 0.000925 | $44.5888 | — | — | — |
| Aave V3 | `aave3` | $0.4352 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4352 | — | — | — |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 3,043.7273 | $1.0001 | $3,044.03 | price feed (wallet/Holding) | 3,043.7273 | $3,043.27 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Balancer V2 (`balancer2`) | protocol | $0.1517 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1517) → **$0.1517** |
| HEX | wallet token | $1.1350 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 24.999996 | $59,120.37 |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $5.036M | Debank filtered: $5.028M | Drift: +0.17% ✅**

#### Protocol positions

_Left side ↙ Debank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | Debank ID | Debank Σ USD | Debank item | Debank tokens | Debank $ | NAV adapter | NAV tokens | NAV $ |
|---|---|---:|---|---|---:|---|---|---:|
| StakeWise | `stakewise` | $874,104.93 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8810 | — | — | — |
| | | | Lending (`0xac0f906e…`) | supply ETH 371.541124 | $874,095.08 | Stakewise v3 | supply ETH 371.527015 | $878,592.68 |
| | | | Staked (`0xfe2e6372…`) | supply ETH 0.003813 | $8.9712 | — | — | — |
| Rocket Pool | `rocketpool` | $171,521.13 | rETH (`0xae78736c…`) | supply ETH 72.906430 | $171,521.13 | price feed | rETH 62.694486 | $172,400.58 |
| Aave V3 | `aave3` | $50,297.57 | Lending (`0x87870bca…`) | supply BAL 320,141.9860 | $50,064.75 | Aave V3 Core | supply BAL 320,141.6290 | $49,357.84 |
| | | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 232.961382 | $232.8216 | — | — | — |
| Compound V3 | `compound3` | $105.9362 | Lending (`0xc3d688b6…`) | reward COMP 4.437373 | $104.3670 | Compound v3 USDC | supply COMP 4.437373 | $106.4801 |
| | | | | | | Compound v3 USDC | supply USDC 1.569066 | $1.5688 |
| | | | Yield (`0xc3d688b6…`) | supply USDC 1.569076 | $1.5692 | — | — | — |
| Uniswap V3 | `uniswap3` | $9.8674 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.000154 + supply ETH 0.001778 + reward WETH 0.000102 + reward ETH 0.000104 | $5.0328 | Uniswap V3 | supply WETH 0.001972 | $4.6622 |
| | | | | | | Uniswap V3 | supply WETH 0.000027 | $0.0628 |
| | | | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.8346 | — | — | — |
| LIDO | `lido` | $0.0000 | — | — | — | price feed | stETH 0.000000 | $0.0000 |

#### Wallet tokens

_Left side ↙ Debank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | Debank amount | Debank price | Debank $ | NAV source | NAV amount | NAV $ |
|---|---|---:|---:|---:|---|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 3.5520M | $1.0001 | $3.552M | price feed (wallet/Holding) | 3.5520M | $3.551M |
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | 2.4916M | $0.1564 | $389,644.21 | price feed (wallet/Holding) | 2.4916M | $384,142.90 |

#### Untracked by design

_Debank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Aave V2 (`aave2`) | protocol | $1.831M | supply: AAVE 19,442.9617 ($1.831M); rewards: AAVE 1.522670 ($143.4051) → **$1.831M**<br>supply: BAL 58.491558 ($9.1471) → **$9.1471** |
| Balancer V2 (`balancer2`) | protocol | $35,757.54 | supply: BAL 90,845.0696 ($14,206.62) + WETH 9.160394 ($21,550.93) → **$35,757.54** |
| Across V2 (`acrocc_v2`) | protocol | $12,996.22 | supply: BAL 83,105.1188 ($12,996.22) → **$12,996.22** |
| Multichain (`multichain`) | protocol | $3.3097 | supply: BAL 21.164100 ($3.3097) → **$3.3097** |
| Compound (`compound`) | protocol | $2.1197 | supply: DAI 1.132199 ($1.1320) + AAVE 0.010451 ($0.9843); rewards: COMP 0.000146 ($0.0034) → **$2.1197** |
| COW | wallet token | $212,820.30 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |
| POL | wallet token | $9,036.00 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` |

#### NAV positions with no Debank counterpart row

_NAV reports these but Debank either doesn't surface them at all, or surfaces them under a Debank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while Debank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000041 | $0.0959 |
| adapter | Aave V2 / Collateral | BAL | 58.491558 | $9.0179 |

