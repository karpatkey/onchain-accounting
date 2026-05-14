# NAV vs DeBank — Detailed Comparison Report

Generated: 2026-05-12 01:37 UTC  
Tolerance: 1%

DeBank anchor: read from `test/integration/debank-cache/` (no live API call).  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25074767 |
| optimism (10) | 151467099 |
| gnosis (100) | 46125681 |
| base (8453) | 45871814 |
| arbitrum (42161) | 461826138 |

## Drift summary

**12 of 15 account-chain pairs within 1% tolerance.** ⚠ 3 over tolerance — see per-account section for breakdown.

| Account | Chain | │ | NAV | │ | DeBank filtered | Drift |  |
|---|---|:---:|---:|:---:|---:|---:|:---:|
| ACCOUNT_1 | mainnet | │ | $183.1643 | │ | $180.1814 | +1.66% | ⚠️ |
| ACCOUNT_1 | gnosis | │ | $5.0063 | │ | $5.0068 | -0.01% | ✅ |
| ACCOUNT_1 | base | │ | $9.9996 | │ | $10.0034 | -0.04% | ✅ |
| ACCOUNT_1 | arbitrum | │ | $10.0274 | │ | $10.0298 | -0.02% | ✅ |
| ACCOUNT_2 | mainnet | │ | $1.138M | │ | $1.140M | -0.20% | ✅ |
| ACCOUNT_3 | mainnet | │ | $275.1496 | │ | $275.2484 | -0.04% | ✅ |
| ACCOUNT_4_UMBRELLA | mainnet | │ | $177,050.41 | │ | $177,051.87 | -0.00% | ✅ |
| ACCOUNT_5_COMPOUND_MAINNET | mainnet | │ | $8.147M | │ | $8.149M | -0.03% | ✅ |
| ACCOUNT_6_COMPOUND_OPTIMISM | optimism | │ | $2.767M | │ | $2.768M | -0.03% | ✅ |
| ACCOUNT_7_COMPOUND_ARBITRUM | arbitrum | │ | $2.060M | │ | $2.060M | -0.03% | ✅ |
| ACCOUNT_8_COMPOUND_BASE | base | │ | $774,165.66 | │ | $774,421.40 | -0.03% | ✅ |
| ACCOUNT_9_MAINNET_DIVERSIFIED | mainnet | │ | $17.662M | │ | $18.231M | -3.12% | ⚠️ |
| ACCOUNT_10_MAINNET_LST_YIELD | mainnet | │ | $94.971M | │ | $94.989M | -0.02% | ✅ |
| ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | mainnet | │ | $7.157M | │ | $7.167M | -0.15% | ✅ |
| ACCOUNT_12_MAINNET_UNISWAP_V3_LP | mainnet | │ | $863.2851 | │ | $878.2033 | -1.70% | ⚠️ |


---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $183.1643 | DeBank filtered: $180.1814 | Drift: +1.66% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $61.6072 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.091366 | $10.0934 | │ | $64.9275 | Morpho | Supply USDC 10.091337 | $10.0891 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.094235 | $10.0963 | │ | | Morpho | Supply USDC 10.094210 | $10.0920 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.041019 | $5.0415 | │ | | Morpho | Supply USDT 5.041012 | $5.0402 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1865 | │ | | Morpho | Supply USDC 19.529472 | $19.5252 |
| | │ | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.094219 | $10.0962 | │ | | Morpho | Supply USDC 10.094193 | $10.0920 |
| | │ | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.091292 | $10.0933 | │ | | Morpho | Supply USDC 10.091268 | $10.0890 |
| Aave V3<br>`aave3` | │ | $52.6079 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $10.0190 | │ | $52.5626 | Aave V3 | Staking GHO 10.000000 | $9.9967 |
| | │ | | Lending (`0x87870bca…`) | supply USDC 9.087528 + supply USDT 10.091045 + supply USDe 5.027116 + supply sUSDe 3.000000 + supply RLUSD 14.676468 + reward USDS 0.008929 | $42.5889 | │ | | Aave V3 | Collateral USDC 9.087505 | $9.0855 |
| | │ | | | | | │ | | Aave V3 | Collateral USDT 10.091021 | $10.0895 |
| | │ | | | | | │ | | Aave V3 | Collateral USDe 5.027085 | $5.0237 |
| | │ | | | | | │ | | Aave V3 | Collateral sUSDe 3.000000 | $3.6905 |
| | │ | | | | | │ | | Aave V3 | Supply RLUSD 14.676445 | $14.6768 |
| Balancer V3<br>`balancer3` | │ | $7.0152 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.812290 + supply GHO 3.884852 + supply USDC 1.310195 | $7.0152 | │ | $7.0055 | Balancer V3 | Supply USDT 1.710839 | $1.7106 |
| | │ | | | | | │ | | Balancer V3 | Supply GHO 4.031644 | $4.0303 |
| | │ | | | | | │ | | Balancer V3 | Supply USDC 1.264873 | $1.2646 |
| cap<br>`capapp` | │ | $5.0656 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.064070 | $5.0656 | │ | $10.0519 | Cap | Supply USDC 10.054075 | $10.0519 |
| Sky<br>`sky` | │ | $5.0556 | Savings USDS (`0xa3931d71…`) | supply USDS 5.056579 | $5.0556 | │ | $5.0548 | price feed | sUSDS 4.612968 | $5.0548 |
| Ethena<br>`ethena` | │ | $4.4894 | sUSDe (`0x9d39a5de…`) | supply USDe 4.489897 | $4.4894 | │ | $4.4869 | price feed | sUSDe 3.647417 | $4.4869 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | │ | 8.905915 | $1.0019 | $8.9228 | │ | 8.905915 | $0.9997 | $8.9030 |
| USDe | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | │ | 0.999922 | $0.9999 | $0.9998 | │ | 0.999922 | $0.9993 | $0.9992 |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 9.626826 | $1.0002 | $9.6288 | │ | 9.626826 | $0.9998 | $9.6247 |
| cUSD | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | │ | 4.990006 | $1.0003 | $4.9915 | │ | ↑ aggregated (see protocol row) | — | — |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 4.717667 | $1.0001 | $4.7181 | │ | 4.717667 | $0.9998 | $4.7169 |
| USDS | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | │ | 14.831886 | $0.9998 | $14.8289 | │ | 14.831886 | $0.9997 | $14.8267 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Merkl (`merkl`) | protocol | $0.3119 | supply: RLUSD 0.113333 ($0.1134) + MORPHO 0.022386 ($0.0476) + GHO 0.150440 ($0.1507) + USDT 0.000134 ($0.0001) + USDC 0.000097 ($0.0001) → **$0.3119** |

### Gnosis (chain 100)

**NAV: $5.0063 | DeBank filtered: $5.0068 | Drift: -0.01% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $2.0097 | Lending (`0xb5020155…`) | supply WXDAI 2.010110 | $2.0097 | │ | $2.0094 | Aave V3 | Collateral WXDAI 2.010166 | $2.0094 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| GHO | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | │ | 0.998493 | $0.9996 | $0.9981 | │ | 0.998493 | $0.9997 | $0.9982 |
| xDai | `xdai` | │ | 1.999518 | $0.9998 | $1.9991 | │ | 1.999518 | $0.9996 | $1.9988 |

### Base (chain 8453)

**NAV: $9.9996 | DeBank filtered: $10.0034 | Drift: -0.04% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | │ | 10.001207 | $1.0002 | $10.0032 | │ | 10.001207 | $0.9998 | $9.9995 |

### Arbitrum (chain 42161)

**NAV: $10.0274 | DeBank filtered: $10.0298 | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $2.0199 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.011839 | $1.0120 | │ | $2.0196 | Morpho | Supply USDC 1.012106 | $1.0120 |
| | │ | | Deposit (`0x6c247b1f…`) | supply USDC 1.007655 | $1.0079 | │ | | Morpho | Supply USDC 1.007736 | $1.0076 |
| Aave V3<br>`aave3` | │ | $1.0018 | Lending (`0x794a6135…`) | supply USDC 2.013045 + borrow GHO 1.011396 | $1.0018 | │ | $1.0014 | Aave V3 | Collateral USDC 2.013205 | $2.0129 |
| | │ | | | | | │ | | Aave V3 | Borrow GHO 1.011777 | $-1.0115 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| syrupUSDC | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | │ | 1.732523 | $1.1630 | $2.0149 | │ | 1.732523 | $1.1635 | $2.0158 |
| GHO | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | │ | 0.956018 | $1.0002 | $0.9562 | │ | 0.956018 | $0.9998 | $0.9558 |
| USDC | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | │ | 2.004327 | $1.0002 | $2.0047 | │ | 2.004327 | $0.9999 | $2.0040 |
| USD₮0 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | │ | 2.031070 | $1.0001 | $2.0313 | │ | 2.031070 | $0.9998 | $2.0306 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.138M | DeBank filtered: $1.140M | Drift: -0.20% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $1.139M | Lending (`0x87870bca…`) | supply WETH 0.011600 + supply rsETH 2,326.4202 + borrow WETH 2,002.1925 | $1.139M | │ | $1.137M | Aave V3 | Collateral WETH 0.011601 | $27.1371 |
| | │ | | | | | │ | | Aave V3 | Collateral rsETH 2,326.4202 | $5.821M |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 2,002.2426 | $-4.684M |
| Kelp DAO<br>`kelpdao` | │ | $732.8238 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $732.8238 | │ | $733.0648 | price feed | rsETH 0.292977 | $733.0648 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.002564 | $2,338.52 | $5.9967 | │ | 0.002564 | $2,339.29 | $5.9987 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Merkl (`merkl`) | protocol | $28.1613 | supply: GEAR 91,169.3043 ($28.1613) + ETH 0.000000 ($0.0000) → **$28.1613** |

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $275.1496 | DeBank filtered: $275.2484 | Drift: -0.04% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Balancer V3<br>`balancer3` | │ | $81.9707 | Farming (`0x62a66eb9…`) | supply WETH 0.018006 + supply ETH 0.016997 + reward BAL 0.757598 | $81.9707 | │ | $81.9985 | Balancer V3 | Staking WETH 0.018005 | $42.1201 |
| | │ | | | | | │ | | Balancer V3 | Staking BAL 0.757598 | $0.1170 |
| | │ | | | | | │ | | Balancer V3 | Staking rETH 0.014613 | $39.7615 |
| Aave V3<br>`aave3` | │ | $61.0022 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005021 + supply ezETH 0.005000 + borrow WETH 0.005027 | $27.0209 | │ | $61.0152 | Aave V3 | Collateral wstETH 0.005000 | $14.4371 |
| | │ | | | | | │ | | Aave V3 | Collateral WETH 0.005021 | $11.7458 |
| | │ | | | | | │ | | Aave V3 | Collateral ezETH 0.005000 | $12.6017 |
| | │ | | | | | │ | | Aave V3 | Borrow WETH 0.005027 | $-11.7606 |
| | │ | | Lending (`0x87870bca…`) | supply WETH 0.002970 + supply wstETH 0.009367 | $33.9814 | │ | | Aave V3 | Collateral WETH 0.002970 | $6.9468 |
| | │ | | | | | │ | | Aave V3 | Collateral wstETH 0.009367 | $27.0444 |
| Rocket Pool<br>`rocketpool` | │ | $40.7652 | rETH (`0xae78736c…`) | supply ETH 0.017432 | $40.7652 | │ | $40.7786 | price feed | rETH 0.014986 | $40.7786 |
| Convex<br>`convex` | │ | $29.9006 | Staked (`0x5411cc58…`) | supply WETH 0.003318 + supply ETH 0.009441 + reward CRV 0.226578 + reward CVX 0.000074 | $29.9006 | │ | $29.9006 | Convex | Staking WETH 0.003321 | $7.7688 |
| | │ | | | | | │ | | Convex | Staking CRV 0.228841 | $0.0657 |
| | │ | | | | | │ | | Convex | Staking CVX 0.000229 | $0.0005 |
| | │ | | | | | │ | | Convex | Staking weETH 0.008623 | $22.0657 |
| ether.fi<br>`etherfi` | │ | $21.0834 | weETH (`0xcd5fe23c…`) | supply ETH 0.009016 | $21.0834 | │ | $21.0793 | price feed | weETH 0.008237 | $21.0793 |
| Kelp DAO<br>`kelpdao` | │ | $10.7381 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.7381 | │ | $10.7416 | price feed | rsETH 0.004293 | $10.7416 |
| Aura Finance<br>`aurafinance` | │ | $0.0917 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.127894 | $0.0917 | │ | $0.0756 | Aura | Staking BAL 0.489289 | $0.0756 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| WETH | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | │ | 0.005056 | $2,338.52 | $11.8228 | │ | 0.005056 | $2,339.29 | $11.8267 |
| ETH | `eth` | │ | 0.007468 | $2,338.52 | $17.4648 | │ | 0.007468 | $2,339.29 | $17.4706 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Merkl (`merkl`) | protocol | $0.3041 | supply: WETH 0.000009 ($0.0216) + ETH 0.000009 ($0.0204) + GEAR 6.174863 ($0.0019) + RPL 0.124613 ($0.2602) → **$0.3041** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Merkl / Rewards / Rewards | RPL | 0.126150 | $0.2630 |

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $177,050.41 | DeBank filtered: $177,051.87 | Drift: -0.00% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V3<br>`aave3` | │ | $177,214.58 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 119.119277 | $66,636.15 | │ | $177,050.00 | Aave V3 | Staking GHO 66,390.6641 | $66,368.63 |
| | │ | | | | | │ | | Aave V3 | Rewards GHO 126.609628 | $126.5676 |
| | │ | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,229.6668 + reward USDC 48.919124 | $65,291.64 | │ | | Aave V3 | Staking USDC 65,229.4511 | $65,215.09 |
| | │ | | | | | │ | | Aave V3 | Rewards USDC 52.891851 | $52.8802 |
| | │ | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,673.0124 + reward USDT 22.845089 | $27,698.63 | │ | | Aave V3 | Staking USDT 27,672.9276 | $27,668.71 |
| | │ | | | | | │ | | Aave V3 | Rewards USDT 24.433665 | $24.4299 |
| | │ | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.516474 + reward WETH 0.004139 | $17,588.16 | │ | | Aave V3 | Staking WETH 7.516468 | $17,583.19 |
| | │ | | | | | │ | | Aave V3 | Rewards WETH 0.004493 | $10.5093 |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000173 | $0.4056 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.147M | DeBank filtered: $8.149M | Drift: -0.03% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `eth` | │ | 0.086007 | $2,338.66 | $201.1405 | │ | 0.086007 | $2,339.29 | $201.1946 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Fluid (`fluid`) | protocol | $8.148M | supply: USDT 5.0497M ($5.050M) → **$5.050M**<br>supply: USDC 3.0972M ($3.098M) → **$3.098M** |
| Compound V3 (`compound3`) | protocol | $599.0692 | rewards: COMP 25.139287 ($599.0692) → **$599.0692** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Fluid / Lending / Supply | USDC | 3.0974M | $3.097M |
| adapter | Fluid / Lending / Supply | USDT | 5.0499M | $5.049M |
| adapter | Compound v3 / Lending / Rewards | COMP | 25.139287 | $598.4319 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.767M | DeBank filtered: $2.768M | Drift: -0.03% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `op` | │ | 0.049027 | $2,338.66 | $114.6579 | │ | 0.049027 | $2,343.65 | $114.9027 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Compound V3 (`compound3`) | protocol | $2.767M | rewards: COMP 38.421572 ($915.5861) → **$915.5861**<br>supply: USDC 756,542.6375 ($756,693.98) → **$756,693.98**<br>rewards: COMP 138.982925 ($3,311.96) → **$3,311.96**<br>supply: USDT 2.0063M ($2.006M) → **$2.006M** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 / Lending / Supply | USDC | 756,556.8320 | $756,438.90 |
| adapter | Compound v3 / Lending / Rewards | COMP | 38.421572 | $914.7863 |
| adapter | Compound v3 / Lending / Supply | USDT | 2.0063M | $2.005M |
| adapter | Compound v3 / Lending / Rewards | COMP | 138.982925 | $3,309.07 |
| adapter | Compound v3 / Lending / Rewards | COMP | 24.934844 | $593.6783 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.060M | DeBank filtered: $2.060M | Drift: -0.03% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `arb` | │ | 0.001305 | $2,338.93 | $3.0524 | │ | 0.001305 | $2,340.71 | $3.0548 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Compound V3 (`compound3`) | protocol | $2.060M | supply: USDC 2.0600M ($2.060M) → **$2.060M** |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 / Lending / Supply | USDC | 2.0601M | $2.060M |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $774,165.66 | DeBank filtered: $774,421.40 | Drift: -0.03% ✅**

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| ETH | `base` | │ | 0.023359 | $2,338.64 | $54.6276 | │ | 0.023359 | $2,341.19 | $54.6871 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Compound V3 (`compound3`) | protocol | $774,366.09 | rewards: COMP 13.108705 ($312.3804) → **$312.3804**<br>supply: USDC 773,898.8977 ($774,053.71) → **$774,053.71** |
| CASHW | wallet token | $2.8628 | `0x56d149dffd01564a0f472c4898b350a43439143d` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 / Lending / Supply | USDC | 773,936.0263 | $773,801.99 |
| adapter | Compound v3 / Lending / Rewards | COMP | 13.108705 | $313.4969 |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $17.662M | DeBank filtered: $18.231M | Drift: -3.12% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Morpho<br>`morpho` | │ | $7.742M | kpk USDC (`0x4ef53d2c…`) | supply USDC 4.6555M | $4.656M | │ | $7.737M | Morpho | Supply USDC 4.6556M | $4.655M |
| | │ | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2008M | $2.594M | │ | | Morpho | Supply EURC 2.2008M | $2.591M |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 210.299527 | $491,814.89 | │ | | Morpho | Supply WETH 210.300648 | $491,953.99 |
| LIDO<br>`lido` | │ | $2.107M | wstETH (`0x7f39c581…`) | supply stETH 212.706524 | $497,188.55 | │ | $2.105M | price feed | wstETH 172.342940 | $497,582.03 |
| | │ | | stETH (`0xae7ab965…`) | supply ETH 688.154701 | $1.609M | │ | | price feed | stETH 688.154701 | $1.607M |
| StakeWise<br>`stakewise` | │ | $554.1701 | Lending (`0x15639e82…`) | supply ETH 0.388184 + borrow osETH 0.142292 | $554.1701 | │ | $569.6890 | StakeWise V3 | Staking ETH 0.388198 | $908.1066 |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.144667 | $-338.4176 |
| Aave V3<br>`aave3` | │ | $0.0558 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0558 | │ | $0.0558 | Aave V3 | Collateral WETH 0.000024 | $0.0558 |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 7.6573M | $1.0002 | $7.659M | │ | 7.6573M | $0.9998 | $7.656M |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 152.306225 | $1.0001 | $152.3215 | │ | 152.306225 | $0.9998 | $152.2830 |
| ETH | `eth` | │ | 70.087057 | $2,338.64 | $163,908.39 | │ | 70.087057 | $2,339.29 | $163,953.88 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Sablier (`sablier`) | protocol | $1.527M | supply: COW 7.8383M ($1.527M) → **$1.527M** |
| Uniswap V3 (`uniswap3`) | protocol | $559,568.45 | supply WETH 75.284434 + supply COW 1.9605M + reward WETH 0.338506 + reward COW 4,166.0979 |
| COW | wallet token | $4.073M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $94.971M | DeBank filtered: $94.989M | Drift: -0.02% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Sky<br>`sky` | │ | $24.616M | Savings USDS (`0xa3931d71…`) | supply USDS 24.6211M | $24.616M | │ | $24.614M | price feed | sUSDS 22.4625M | $24.614M |
| StakeWise<br>`stakewise` | │ | $23.798M | Lending (`0xac0f906e…`) | supply ETH 10,176.0903 + borrow osETH 0.000006 | $23.798M | │ | $23.807M | StakeWise V3 | Staking ETH 10,176.8221 | $23.807M |
| | │ | | | | | │ | | StakeWise V3 | Borrow ETH 0.000006 | $-0.0141 |
| Stader<br>`stader` | │ | $23.746M | ETHx (`0xa35b1b31…`) | supply ETH 10,153.7414 | $23.746M | │ | $23.753M | price feed | ETHx 9,325.6655 | $23.753M |
| Morpho<br>`morpho` | │ | $18.706M | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.0781M | $10.080M | │ | $18.705M | Morpho | Supply USDC 10.0789M | $10.077M |
| | │ | | kpk ETH (`0xbb50a534…`) | supply WETH 3,688.2930 | $8.626M | │ | | Morpho | Supply WETH 3,688.3949 | $8.628M |
| Rocket Pool<br>`rocketpool` | │ | $4.090M | rETH (`0xae78736c…`) | supply ETH 1,749.0124 | $4.090M | │ | $4.091M | price feed | rETH 1,503.6269 | $4.091M |
| LIDO<br>`lido` | │ | $351.6596 | wstETH (`0x7f39c581…`) | supply stETH 0.150447 | $351.6596 | │ | $351.9379 | price feed | wstETH 0.121897 | $351.9379 |
| Aave V3<br>`aave3` | │ | $0.4352 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4352 | │ | — | — | — | — |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Merkl (`merkl`) | protocol | $3,429.14 | supply: MORPHO 1,611.6671 ($3,429.14) → **$3,429.14** |
| Compound V3 (`compound3`) | protocol | $1,680.67 | rewards: COMP 70.521281 ($1,680.52) → **$1,680.52**<br>rewards: COMP 0.006016 ($0.1434) → **$0.1434** |
| Uniswap V3 (`uniswap3`) | protocol | $44.3259 | supply WETH 0.001205 + supply ETH 0.015916 + reward WETH 0.000907 + reward ETH 0.000926 |
| Balancer V2 (`balancer2`) | protocol | $0.1486 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1486) → **$0.1486** |
| HEX | wallet token | $1.2039 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| adapter | Compound v3 / Lending / Rewards | COMP | 0.006016 | $0.1432 |
| adapter | Compound v3 / Lending / Rewards | COMP | 70.521281 | $1,678.73 |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $7.157M | DeBank filtered: $7.167M | Drift: -0.15% ✅**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Aave V2<br>`aave2` | │ | $1.965M | Staked (`0x4da27a54…`) | supply AAVE 19,442.9617 + reward AAVE 12.576799 | $1.965M | │ | $1.975M | Aave V3 | Staking AAVE 19,442.9617 | $1.973M |
| | │ | | | | | │ | | Aave V3 | Rewards AAVE 13.590784 | $1,379.48 |
| | │ | | Lending (`0x7d2768de…`) | supply BAL 58.491558 | $8.9607 | │ | | Aave V2 | Collateral BAL 58.491558 | $9.0329 |
| StakeWise<br>`stakewise` | │ | $869,384.56 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8760 | │ | $869,494.63 | StakeWise V3 | Staking ETH 371.691841 | $869,494.63 |
| Rocket Pool<br>`rocketpool` | │ | $170,577.46 | rETH (`0xae78736c…`) | supply ETH 72.925956 | $170,577.46 | │ | $170,594.89 | price feed | rETH 62.694486 | $170,594.89 |
| Aave V3<br>`aave3` | │ | $49,281.64 | Lending (`0x87870bca…`) | supply BAL 320,165.4406 | $49,048.17 | │ | $49,676.62 | Aave V3 | Supply BAL 320,167.5717 | $49,443.66 |
| | │ | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 233.034399 | $233.4772 | │ | | Aave V3 | Supply GHO 233.038520 | $232.9612 |
| Uniswap V3<br>`uniswap3` | │ | $4.8073 | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.8073 | │ | $4.8089 | Uniswap V3 | Supply WETH 0.001972 | $4.6119 |
| | │ | | | | | │ | | Uniswap V3 | Fees WBTC 0.000002 | $0.1349 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.000027 | $0.0621 |
| Compound<br>`compound` | │ | $2.1912 | Lending (`0x3d981921…`) | supply DAI 1.132199 + supply AAVE 0.010451 + reward COMP 0.000146 | $2.1912 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | │ | 3.7078M | $1.0002 | $3.709M | │ | 3.7078M | $0.9998 | $3.707M |
| BAL | `0xba100000625a3754423978a60c9317c58a424e3d` | │ | 2.4916M | $0.1532 | $381,704.41 | │ | 2.4916M | $0.1544 | $384,779.70 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| StakeWise (`stakewise`) | protocol | $869,374.76 | supply ETH 371.678571 |
| Balancer V2 (`balancer2`) | protocol | $35,343.58 | supply: BAL 92,051.1176 ($14,101.89) + WETH 9.081331 ($21,241.69) → **$35,343.58** |
| Across V2 (`acrocc_v2`) | protocol | $12,733.12 | supply: BAL 83,116.3798 ($12,733.12) → **$12,733.12** |
| Compound V3 (`compound3`) | protocol | $107.3127 | rewards: COMP 4.437374 ($105.7426) → **$105.7426**<br>supply: USDC 1.569731 ($1.5700) → **$1.5700** |
| StakeWise (`stakewise`) | protocol | $8.9195 | supply ETH 0.003813 |
| Uniswap V3 (`uniswap3`) | protocol | $5.0042 | supply WETH 0.000136 + supply ETH 0.001796 + reward WETH 0.000103 + reward ETH 0.000105 |
| Multichain (`multichain`) | protocol | $3.2423 | supply: BAL 21.164100 ($3.2423) → **$3.2423** |
| COW | wallet token | $231,347.06 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` |
| POL | wallet token | $9,419.43 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` |

#### NAV positions with no DeBank counterpart row

_NAV reports these but DeBank either doesn't surface them at all, or surfaces them under a DeBank shape the matcher couldn't pair (e.g. the Cap adapter aggregates cUSD+stcUSD into a USDC `PositionBalance` on the NAV side, while DeBank reports the Cap protocol as a cUSD entry plus a separate cUSD wallet token). Their dollar value IS counted in the headline NAV total — only the per-row pairing failed._

| NAV source | Detail | Asset | NAV amount | NAV $ |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000041 | $0.0949 |
| adapter | Compound v3 / Lending / Supply | USDC | 1.569797 | $1.5695 |
| adapter | Compound v3 / Lending / Rewards | COMP | 4.437374 | $105.6301 |

---

## ACCOUNT_12_MAINNET_UNISWAP_V3_LP

**Address:** `0x8d27deb2405717d649346502f52b959aab4eb3af`

### Mainnet (chain 1)

**NAV: $863.2851 | DeBank filtered: $878.2033 | Drift: -1.70% ⚠️**

#### Protocol positions

_Left side ↙ DeBank's view (from /v1/user/all_complex_protocol_list). Right side ↘ NAV's view (from registered balance adapters)._

| Protocol | │ | DeBank Σ USD | DeBank item | DeBank tokens | DeBank $ | │ | NAV Σ USD | NAV adapter | NAV tokens | NAV $ |
|---|:---:|---:|---|---|---:|:---:|---:|---|---|---:|
| Uniswap V3<br>`uniswap3` | │ | $780.3215 | #1276763 (`0x4e68ccd3…`) | supply WETH 0.125413 + supply USDT 0.000000 + reward WETH 0.000477 + reward USDT 0.740253 | $295.2024 | │ | $780.2553 | Uniswap V3 | Supply WETH 0.125413 | $293.3774 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.000477 | $1.1148 |
| | │ | | | | | │ | | Uniswap V3 | Fees USDT 0.740253 | $0.7401 |
| | │ | | #1231724 (`0x88e6a0c2…`) | supply USDC 318.200606 + supply WETH 0.066221 + reward USDC 5.960025 + reward WETH 0.002565 | $485.1191 | │ | | Uniswap V3 | Supply USDC 321.654554 | $321.5837 |
| | │ | | | | | │ | | Uniswap V3 | Supply WETH 0.064745 | $151.4583 |
| | │ | | | | | │ | | Uniswap V3 | Fees USDC 5.971814 | $5.9705 |
| | │ | | | | | │ | | Uniswap V3 | Fees WETH 0.002569 | $6.0105 |
| Convex<br>`convex` | │ | $14.6558 | Staked (`0x49b4d1df…`) | supply cvxFXS 62.684670 + reward FRAX 1.860052 + reward CVX 1.434995 | $14.6558 | │ | — | — | — | — |

#### Wallet tokens

_Left side ↙ DeBank's `/v1/user/token_list`. Right side ↘ NAV's wallet sweep via `ERC20DefaultOracle` and registered Custom price feeds._

| Symbol | Address | │ | DeBank amount | DeBank price | DeBank $ | │ | NAV amount | NAV price | NAV $ |
|---|---|:---:|---:|---:|---:|:---:|---:|---:|---:|
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | │ | 7.152868 | $1.0001 | $7.1536 | │ | 7.152868 | $0.9998 | $7.1518 |
| ETH | `eth` | │ | 0.032436 | $2,339.05 | $75.8703 | │ | 0.032436 | $2,339.29 | $75.8780 |

#### Untracked by design

_DeBank reports these but NAV doesn't (deliberately). See `accounts.json.chains.<id>.$untracked_by_design` for the full rationale._

| Source | Type | $ value | Detail |
|---|---|---:|---|
| Layer3 (`layer3`) | protocol | $82.8260 | supply: L3 6,323.3042 ($70.9772); rewards: L3 1,055.6029 ($11.8488) → **$82.8260** |
| espresso (`espresso`) | protocol | $47.0641 | supply: ESP 625.520000 ($47.0641) → **$47.0641** |
| Ekubo (`ekubo`) | protocol | $13.4787 | supply: EKUBO 4.006297 ($2.0970) + gEKUBO-26Q2 6.674740 ($0.0000); rewards: EKUBO 0.140899 ($0.0737) + gEKUBO-26Q2 0.183029 ($0.0000) → **$2.1707**<br>supply: ETH 0.000000 ($0.0000) + EKUBO 21.604083 ($11.3080) → **$11.3080** |
| AEVO | wallet token | $10.2207 | `0xb528edbef013aff855ac3c50b381f253af13b997` |
| EKUBO | wallet token | $0.7447 | `0x04c46e830bb56ce22735d5d8fc9cb90309317d0f` |

---

## Section 3 — Per-Adapter Granular Detail

_One table per adapter instance × account. **Amount drift** (Δ amt %) signals a balance-adapter issue. **Price drift** (Δ price %) signals a price-feed issue. If both are small but USD drift is large, check decimal/precision handling in the price computation._

_Severity: **OK** ≤1% · **WARN** 1–5% · **FAIL** >5%. Rows sorted by descending NAV USD._
_`nav_only` rows (no DeBank match) are listed in a separate subsection._

### StakeWise V3 — Mainnet (chain 1) — `0xAC0F906E43…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 371.691841 | 0.000374 | FAIL +99251493.52% | $2,339.29 | $2,339.05 | OK +0.01% | $869,494.63 | $0.8760 | FAIL +99261633.68% |

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 10,176.8221 | 10,176.0903 | OK +0.01% | $2,339.29 | $2,338.64 | OK +0.03% | $23.807M | $23.798M | OK +0.03% |
| ETH (Borrow) | − | 0.000006 | 10,176.0903 | FAIL -100.00% | $2,339.29 | $2,338.64 | OK +0.03% | $-0.0141 | $23.798M | FAIL -100.00% |

### Morpho — Mainnet (chain 1) — `0x4Ef53d2cAa…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.0789M | 10.0781M | OK +0.01% | $0.9998 | $1.0002 | OK -0.04% | $10.077M | $10.080M | OK -0.03% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 4.6556M | 4.6555M | OK +0.00% | $0.9998 | $1.0002 | OK -0.04% | $4.655M | $4.656M | OK -0.04% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.091337 | 10.091366 | OK -0.00% | $0.9998 | $1.0002 | OK -0.04% | $10.0891 | $10.0934 | OK -0.04% |

### Aave V3 — Mainnet (chain 1) — `0x87870Bca3F…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Supply) | + | 320,167.5717 | 320,165.4406 | OK +0.00% | $0.1544 | $0.1532 | OK +0.81% | $49,443.66 | $49,048.17 | OK +0.81% |

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.009367 | 0.009367 | OK +0.00% | $2,887.16 | $2,886.37 | OK +0.03% | $27.0444 | $27.0369 | OK +0.03% |
| WETH (Collateral) | + | 0.002970 | 0.002970 | OK +0.00% | $2,339.29 | $2,338.52 | OK +0.03% | $6.9468 | $6.9444 | OK +0.03% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Collateral) | + | 0.000024 | 0.000024 | OK +0.00% | $2,339.29 | $2,338.64 | OK +0.03% | $0.0558 | $0.0558 | OK +0.03% |

#### ACCOUNT_2 (`0x99b9f5…23768b`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| rsETH (Collateral) | + | 2,326.4202 | 2,326.4202 | OK +0.00% | $2,502.13 | $2,502.28 | OK -0.01% | $5.821M | $5.821M | OK -0.01% |
| WETH (Borrow) | − | 2,002.2426 | 2,002.1925 | OK +0.00% | $2,339.29 | $2,338.52 | OK +0.03% | $-4.684M | $4.682M | FAIL -200.04% |
| WETH (Collateral) | + | 0.011601 | 0.011600 | OK +0.00% | $2,339.29 | $2,338.52 | OK +0.03% | $27.1371 | $27.1277 | OK +0.03% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| RLUSD (Supply) | + | 14.676445 | 14.676468 | OK -0.00% | $1.0000 | $1.0002 | OK -0.02% | $14.6768 | $14.6794 | OK -0.02% |
| USDT (Collateral) | + | 10.091021 | 10.091045 | OK -0.00% | $0.9998 | $1.0001 | OK -0.03% | $10.0895 | $10.0921 | OK -0.03% |
| USDC (Collateral) | + | 9.087505 | 9.087528 | OK -0.00% | $0.9998 | $1.0002 | OK -0.04% | $9.0855 | $9.0893 | OK -0.04% |
| USDe (Collateral) | + | 5.027085 | 5.027116 | OK -0.00% | $0.9993 | $0.9999 | OK -0.06% | $5.0237 | $5.0266 | OK -0.06% |
| sUSDe (Collateral) | + | 3.000000 | 3.000000 | OK +0.00% | $1.2302 | $1.2309 | OK -0.06% | $3.6905 | $3.6926 | OK -0.06% |

### Morpho — Mainnet (chain 1) — `0xBb50A53413…`

#### ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 3,688.3949 | 3,688.2930 | OK +0.00% | $2,339.29 | $2,338.64 | OK +0.03% | $8.628M | $8.626M | OK +0.03% |

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 210.300648 | 210.299527 | OK +0.00% | $2,339.29 | $2,338.64 | OK +0.03% | $491,953.99 | $491,814.89 | OK +0.03% |

### Morpho — Mainnet (chain 1) — `0xa877d5BB02…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| EURC (Supply) | + | 2.2008M | 2.2008M | OK +0.00% | $1.1772 | $1.1785 | OK -0.11% | $2.591M | $2.594M | OK -0.11% |

### Aave V3 — Mainnet (chain 1) — `0x4da27a545c…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| AAVE (Staking) | + | 19,442.9617 | 19,442.9617 | OK +0.00% | $101.5014 | $101.0200 | OK +0.48% | $1.973M | $1.964M | OK +0.48% |
| AAVE (Rewards) | + | 13.590784 | 12.576799 | FAIL +8.06% | $101.5014 | $101.0200 | OK +0.48% | $1,379.48 | $1,270.51 | FAIL +8.58% |

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Staking) | + | 10.000000 | 10.000000 | OK +0.00% | $0.9997 | $1.0019 | OK -0.22% | $9.9967 | $10.0190 | OK -0.22% |

### Aave V3 — Mainnet (chain 1) — `0x4655Ce3D62…`

#### ACCOUNT_4_UMBRELLA (`0x13ce0c…5f86df`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Staking) | + | 66,390.6641 | 66,390.6641 | OK +0.00% | $0.9997 | $1.0019 | OK -0.22% | $66,368.63 | $66,516.81 | OK -0.22% |
| USDC (Staking) | + | 65,229.4511 | 65,229.6668 | OK -0.00% | $0.9998 | $1.0002 | OK -0.04% | $65,215.09 | $65,242.72 | OK -0.04% |
| USDT (Staking) | + | 27,672.9276 | 27,673.0124 | OK -0.00% | $0.9998 | $1.0001 | OK -0.03% | $27,668.71 | $27,675.78 | OK -0.03% |
| WETH (Staking) | + | 7.516468 | 7.516474 | OK -0.00% | $2,339.29 | $2,338.66 | OK +0.03% | $17,583.19 | $17,578.48 | OK +0.03% |
| GHO (Rewards) | + | 126.609628 | 119.119277 | FAIL +6.29% | $0.9997 | $1.0019 | OK -0.22% | $126.5676 | $119.3456 | FAIL +6.05% |
| USDC (Rewards) | + | 52.891851 | 48.919124 | FAIL +8.12% | $0.9998 | $1.0002 | OK -0.04% | $52.8802 | $48.9289 | FAIL +8.08% |
| USDT (Rewards) | + | 24.433665 | 22.845089 | FAIL +6.95% | $0.9998 | $1.0001 | OK -0.03% | $24.4299 | $22.8474 | FAIL +6.93% |
| WETH (Rewards) | + | 0.004493 | 0.004139 | FAIL +8.55% | $2,339.29 | $2,338.66 | OK +0.03% | $10.5093 | $9.6792 | FAIL +8.58% |

### StakeWise V3 — Mainnet (chain 1) — `0x15639e82d2…`

#### ACCOUNT_9_MAINNET_DIVERSIFIED (`0x616de5…9f0669`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| ETH (Staking) | + | 0.388198 | 0.388184 | OK +0.00% | $2,339.29 | $2,338.64 | OK +0.03% | $908.1066 | $907.8222 | OK +0.03% |
| ETH (Borrow) | − | 0.144667 | 0.388184 | FAIL -62.73% | $2,339.29 | $2,338.64 | OK +0.03% | $-338.4176 | $907.8222 | FAIL -137.28% |

### Uniswap V3 — Mainnet (chain 1) — `0x88e6A0c2dD…`

#### ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 321.654554 | 318.200606 | WARN +1.09% | $0.9998 | $1.0002 | OK -0.04% | $321.5837 | $318.2643 | WARN +1.04% |
| WETH (Supply) | + | 0.064745 | 0.066221 | WARN -2.23% | $2,339.29 | $2,339.05 | OK +0.01% | $151.4583 | $154.8943 | WARN -2.22% |
| WETH (Fees) | + | 0.002569 | 0.002565 | OK +0.17% | $2,339.29 | $2,339.05 | OK +0.01% | $6.0105 | $5.9994 | OK +0.19% |
| USDC (Fees) | + | 5.971814 | 5.960025 | OK +0.20% | $0.9998 | $1.0002 | OK -0.04% | $5.9705 | $5.9612 | OK +0.16% |

### Uniswap V3 — Mainnet (chain 1) — `0x4e68Ccd3E8…`

#### ACCOUNT_12_MAINNET_UNISWAP_V3_LP (`0x8d27de…4eb3af`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.125413 | 0.125413 | OK +0.00% | $2,339.29 | $2,339.05 | OK +0.01% | $293.3774 | $293.3474 | OK +0.01% |
| WETH (Fees) | + | 0.000477 | 0.000477 | OK +0.00% | $2,339.29 | $2,339.05 | OK +0.01% | $1.1148 | $1.1147 | OK +0.01% |
| USDT (Fees) | + | 0.740253 | 0.740253 | OK +0.00% | $0.9998 | $1.0001 | OK -0.03% | $0.7401 | $0.7403 | OK -0.03% |

### Aave V3 — Mainnet (chain 1) — `0xC71Ea051a5…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Supply) | + | 233.038520 | 233.034399 | OK +0.00% | $0.9997 | $1.0019 | OK -0.22% | $232.9612 | $233.4772 | OK -0.22% |

### Balancer V3 — Mainnet (chain 1) — `0x1ea5870f7C…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Staking) | + | 0.018005 | 0.018006 | OK -0.00% | $2,339.29 | $2,338.52 | OK +0.03% | $42.1201 | $42.1063 | OK +0.03% |
| rETH (Staking) | + | 0.014613 | — | — | $2,721.05 | — | — | $39.7615 | — | — |
| BAL (Staking) | + | 0.757598 | 0.757598 | OK -0.00% | $0.1544 | $0.1532 | OK +0.81% | $0.1170 | $0.1161 | OK +0.81% |

### Aave V3 — Mainnet (chain 1) — `0x4e033931ad…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| wstETH (Collateral) | + | 0.005000 | 0.005000 | OK +0.00% | $2,887.16 | $2,886.37 | OK +0.03% | $14.4371 | $14.4332 | OK +0.03% |
| ezETH (Collateral) | + | 0.005000 | 0.005000 | OK +0.00% | $2,520.34 | $2,520.50 | OK -0.01% | $12.6017 | $12.6025 | OK -0.01% |
| WETH (Borrow) | − | 0.005027 | 0.005027 | OK +0.00% | $2,339.29 | $2,338.52 | OK +0.03% | $-11.7606 | $11.7566 | FAIL -200.03% |
| WETH (Collateral) | + | 0.005021 | 0.005021 | OK +0.00% | $2,339.29 | $2,338.52 | OK +0.03% | $11.7458 | $11.7418 | OK +0.03% |

### Convex — Mainnet (chain 1) — `0x5411CC583f…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| weETH (Staking) | + | 0.008623 | — | — | $2,559.07 | — | — | $22.0657 | — | — |
| WETH (Staking) | + | 0.003321 | 0.003318 | OK +0.11% | $2,339.29 | $2,338.52 | OK +0.03% | $7.7688 | $7.7581 | OK +0.14% |
| CRV (Staking) | + | 0.228841 | 0.226578 | OK +1.00% | $0.2869 | $0.2836 | WARN +1.16% | $0.0657 | $0.0643 | WARN +2.17% |
| CVX (Staking) | + | 0.000229 | 0.000074 | FAIL +208.28% | $1.9818 | $1.9641 | OK +0.90% | $0.0005 | $0.0001 | FAIL +211.06% |

### Morpho — Mainnet (chain 1) — `0xd9e34b1eed…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 19.529472 | 16.183234 | FAIL +20.68% | $0.9998 | $1.0002 | OK -0.04% | $19.5252 | $16.1865 | FAIL +20.63% |

### Morpho — Mainnet (chain 1) — `0xb323495f7e…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.094210 | 10.094235 | OK -0.00% | $0.9998 | $1.0002 | OK -0.04% | $10.0920 | $10.0963 | OK -0.04% |

### Morpho — Mainnet (chain 1) — `0x64d65c9a2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.094193 | 10.094219 | OK -0.00% | $0.9998 | $1.0002 | OK -0.04% | $10.0920 | $10.0962 | OK -0.04% |

### Morpho — Mainnet (chain 1) — `0xe108fbc048…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.091268 | 10.091292 | OK -0.00% | $0.9998 | $1.0002 | OK -0.04% | $10.0890 | $10.0933 | OK -0.04% |

### Cap — Mainnet (chain 1) — `0x88887bE419…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 10.054075 | — | — | $0.9998 | — | — | $10.0519 | $5.0656 | FAIL +98.44% |

### Aave V2 — Mainnet (chain 1) — `0x7d2768dE32…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Collateral) | + | 58.491558 | 58.491558 | OK +0.00% | $0.1544 | $0.1532 | OK +0.81% | $9.0329 | $8.9607 | OK +0.81% |

### Balancer V3 — Mainnet (chain 1) — `0x85B2b559bC…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| GHO (Supply) | + | 4.031644 | 3.884852 | WARN +3.78% | $0.9997 | $1.0019 | OK -0.22% | $4.0303 | $3.8922 | WARN +3.55% |
| USDT (Supply) | + | 1.710839 | 1.812290 | FAIL -5.60% | $0.9998 | $1.0001 | OK -0.03% | $1.7106 | $1.8125 | FAIL -5.62% |
| USDC (Supply) | + | 1.264873 | 1.310195 | WARN -3.46% | $0.9998 | $1.0002 | OK -0.04% | $1.2646 | $1.3105 | WARN -3.50% |

### Morpho — Mainnet (chain 1) — `0x3274643db7…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDT (Supply) | + | 5.041012 | 5.041019 | OK -0.00% | $0.9998 | $1.0001 | OK -0.03% | $5.0402 | $5.0415 | OK -0.03% |

### Uniswap V3 — Mainnet (chain 1) — `0xCBCdF9626b…`

#### ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WETH (Supply) | + | 0.001972 | 0.001972 | OK +0.00% | $2,339.29 | $2,339.05 | OK +0.01% | $4.6119 | $4.6114 | OK +0.01% |
| WBTC (Fees) | + | 0.000002 | 0.000002 | OK +0.61% | $81,731.41 | $81,549.90 | OK +0.22% | $0.1349 | $0.1337 | OK +0.83% |
| WETH (Fees) | + | 0.000027 | 0.000027 | OK +0.00% | $2,339.29 | $2,339.05 | OK +0.01% | $0.0621 | $0.0621 | OK +0.01% |

### Aura — Mainnet (chain 1) — `0x1ea5870f7C…`

#### ACCOUNT_3 (`0x408ea1…403496`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| BAL (Staking) | + | 0.489289 | 0.489289 | OK +0.00% | $0.1544 | $0.1532 | OK +0.81% | $0.0756 | $0.0750 | OK +0.81% |

### Aave V3 — Gnosis (chain 100) — `0xb50201558B…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| WXDAI (Collateral) | + | 2.010166 | 2.010110 | OK +0.00% | $0.9996 | $0.9998 | OK -0.02% | $2.0094 | $2.0097 | OK -0.02% |

### Aave V3 — Arbitrum (chain 42161) — `0x794a61358D…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Collateral) | + | 2.013205 | 2.013045 | OK +0.01% | $0.9999 | $1.0002 | OK -0.03% | $2.0129 | $2.0134 | OK -0.03% |
| GHO (Borrow) | − | 1.011777 | 1.011396 | OK +0.04% | $0.9998 | $1.0002 | OK -0.05% | $-1.0115 | $1.0116 | FAIL -199.99% |

### Morpho — Arbitrum (chain 42161) — `0x2C609d9CfC…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.012106 | 1.011839 | OK +0.03% | $0.9999 | $1.0002 | OK -0.03% | $1.0120 | $1.0120 | OK -0.01% |

### Morpho — Arbitrum (chain 42161) — `0x77fe2f7c2d…`

#### ACCOUNT_1 (`0xa57f12…fcdbc6`)

| Leg | Side | NAV amount | DB amount | Δ amt % | NAV unit $ | DB unit $ | Δ price % | NAV USD | DB USD | Δ USD % |
|---|:---:|---:|---:|---|---:|---:|---|---:|---:|---|
| USDC (Supply) | + | 1.007736 | 1.007655 | OK +0.01% | $0.9999 | $1.0002 | OK -0.03% | $1.0076 | $1.0079 | OK -0.03% |

### NAV-only positions (no DeBank counterpart matched)

_These adapter positions are counted in the headline NAV but have no DeBank row. See Section 2 inline tables for rationale._

| Chain | Account | Protocol | Leg | NAV amount | NAV unit $ | NAV USD |
|---|---|---|---|---:|---:|---:|
| mainnet (1) | ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`) | Fluid | USDT (Supply) | 5.0499M | $0.9998 | $5.049M |
| mainnet (1) | ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`) | Fluid | USDC (Supply) | 3.0974M | $0.9998 | $3.097M |
| arbitrum (42161) | ACCOUNT_7_COMPOUND_ARBITRUM (`0x530bfd…24936d`) | Compound v3 | USDC (Supply) | 2.0601M | $0.9999 | $2.060M |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Compound v3 | USDT (Supply) | 2.0063M | $0.9996 | $2.005M |
| base (8453) | ACCOUNT_8_COMPOUND_BASE (`0xa46680…623314`) | Compound v3 | USDC (Supply) | 773,936.0263 | $0.9998 | $773,801.99 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Compound v3 | USDC (Supply) | 756,556.8320 | $0.9998 | $756,438.90 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Compound v3 | COMP (Rewards) | 138.982925 | $23.8092 | $3,309.07 |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Compound v3 | COMP (Rewards) | 70.521281 | $23.8046 | $1,678.73 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Compound v3 | COMP (Rewards) | 38.421572 | $23.8092 | $914.7863 |
| mainnet (1) | ACCOUNT_5_COMPOUND_MAINNET (`0x9c1b8c…465a73`) | Compound v3 | COMP (Rewards) | 25.139287 | $23.8046 | $598.4319 |
| optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM (`0xd20e00…962953`) | Compound v3 | COMP (Rewards) | 24.934844 | $23.8092 | $593.6783 |
| base (8453) | ACCOUNT_8_COMPOUND_BASE (`0xa46680…623314`) | Compound v3 | COMP (Rewards) | 13.108705 | $23.9152 | $313.4969 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Compound v3 | COMP (Rewards) | 4.437374 | $23.8046 | $105.6301 |
| mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP (`0x0efccb…32fc89`) | Compound v3 | USDC (Supply) | 1.569797 | $0.9998 | $1.5695 |
| mainnet (1) | ACCOUNT_3 (`0x408ea1…403496`) | Merkl | RPL (Rewards) | 0.126150 | $2.0852 | $0.2630 |
| mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD (`0x4f2083…f7fe64`) | Compound v3 | COMP (Rewards) | 0.006016 | $23.8046 | $0.1432 |

---

## Section 4 — Coverage Gaps

_Use this section to identify missing adapter registrations, unregistered tokens, or missing price feeds._

### 4.1 — DeBank protocols with value not in `supportedDeBankProtocols`

_These show non-zero DeBank balance but are absent from the per-chain allowlist in `accounts.json`. If an NAV adapter exists for the protocol, consider adding it to `supportedDeBankProtocols` and registering the adapter on that chain._

| Chain | Account | Protocol | DeBank ID | Value | NAV adapter? |
|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_5_COMPOUND_MAINNET | Fluid | `fluid` | $8.148M | Yes (`Fluid`) |
| Optimism (10) | ACCOUNT_6_COMPOUND_OPTIMISM | Compound V3 | `compound3` | $2.767M | Yes (`Compound v3`) |
| Arbitrum (42161) | ACCOUNT_7_COMPOUND_ARBITRUM | Compound V3 | `compound3` | $2.060M | Yes (`Compound v3`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Sablier | `sablier` | $1.527M | Yes (`Sablier`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $869,374.76 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Base (8453) | ACCOUNT_8_COMPOUND_BASE | Compound V3 | `compound3` | $774,366.09 | Yes (`Compound v3`) |
| Mainnet (1) | ACCOUNT_9_MAINNET_DIVERSIFIED | Uniswap V3 | `uniswap3` | $559,568.45 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Balancer V2 | `balancer2` | $35,343.58 | Yes (`Balancer V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Across V2 | `acrocc_v2` | $12,733.12 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Merkl | `merkl` | $3,429.14 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Compound V3 | `compound3` | $1,680.67 | Yes (`Compound v3`) |
| Mainnet (1) | ACCOUNT_5_COMPOUND_MAINNET | Compound V3 | `compound3` | $599.0692 | Yes (`Compound v3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Compound V3 | `compound3` | $107.3127 | Yes (`Compound v3`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Layer3 | `layer3` | $82.8260 | No |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | espresso | `espresso` | $47.0641 | No |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Uniswap V3 | `uniswap3` | $44.3259 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_2 | Merkl | `merkl` | $28.1613 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Ekubo | `ekubo` | $13.4787 | No |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | StakeWise | `stakewise` | $8.9195 | Yes (`Stakewise v3`, `StakeWise V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Uniswap V3 | `uniswap3` | $5.0042 | Yes (`Uniswap V3`) |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Multichain | `multichain` | $3.2423 | No |
| Mainnet (1) | ACCOUNT_1 | Merkl | `merkl` | $0.3119 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_3 | Merkl | `merkl` | $0.3041 | Yes (`Merkl`) |
| Mainnet (1) | ACCOUNT_10_MAINNET_LST_YIELD | Balancer V2 | `balancer2` | $0.1486 | Yes (`Balancer V3`) |

### 4.2 — Supported protocol items with no NAV match

_The protocol IS in `supportedDeBankProtocols` but no NAV position matched the item. Possible causes: adapter not deployed on this chain, token not in NAV registry, price feed missing, or account has zero balance in this market._

| Chain | Account | Protocol | DeBank ID | Item | Value | Hint |
|---|---|---|---|---|---:|---|
| Mainnet (1) | ACCOUNT_12_MAINNET_UNISWAP_V3_LP | Convex | `convex` | Staked (`0x49b4d1df…`) | $14.6558 | No NAV adapter/feed registered for `convex` on chain 1 |
| Mainnet (1) | ACCOUNT_11_MAINNET_COMPOUND_UNISWAP | Compound | `compound` | Lending (`0x3d981921…`) | $2.1912 | No NAV adapter/feed registered for `compound` on chain 1 |

