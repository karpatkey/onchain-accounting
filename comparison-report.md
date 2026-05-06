# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-06 08:49 UTC  
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

---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $180.8266 | Debank filtered: $184.6547 | Drift: -2.07% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $61.5675 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.084686 | $10.0847 | Morpho Vault | supply USDC 10.084863 | $10.0834 |
| | | | | | | | Morpho Blue - wstETH/USDC | supply USDC 10.088358 | $10.0868 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.088206 | $10.0882 | Morpho Blue - cbBTC/USDC | supply USDC 10.088471 | $10.0870 |
| | | | | | | | Morpho Vault | supply USDC 10.084988 | $10.0835 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.038658 | $5.0383 | Morpho Blue - sUSDS/USDT | supply USDT 5.038717 | $5.0384 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1832 | Morpho Blue - wstUSR/USDC | supply USDC 17.241575 | $17.2390 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.088323 | $10.0883 | — | — | — |
| | | | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.084795 | $10.0848 | — | — | — |
| Aave V3 | `aave3` | ✅ | $52.5583 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $10.0000 | Aave V3 Safety Module | supply GHO 10.000000 | $9.9982 |
| | | | | Lending (`0x87870bca…`) | supply USDC 9.082349 + supply USDT 10.085052 + supply USDe 5.023880 + supply sUSDe 3.000000 + supply RLUSD 14.671598 + reward USDS 0.008929 | $42.5583 | Aave V3 Core | supply USDC 9.082470 | $9.0811 |
| | | | | | | | Aave V3 Core | supply USDT 10.085217 | $10.0845 |
| | | | | | | | Aave V3 Core | supply USDe 5.023932 | $5.0205 |
| | | | | | | | Aave V3 Core | supply sUSDe 3.000000 | $3.6884 |
| | | | | | | | Aave V3 Core | supply RLUSD 14.671723 | $14.6718 |
| Balancer V3 | `balancer3` | ✅ | $7.0038 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.928750 + supply GHO 2.862034 + supply USDC 2.213112 | $7.0038 | Balancer V3 - Aave GHO/USDT/USDC | supply USDT 1.977702 | $1.9776 |
| | | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply GHO 2.932516 | $2.9320 |
| | | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply USDC 2.093617 | $2.0933 |
| cap | `capapp` | ✅ | $5.0605 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.060023 | $5.0605 | — | — | — |
| Sky | `sky` | ✅ | $5.0527 | Savings USDS (`0xa3931d71…`) | supply USDS 5.053685 | $5.0527 | price feed | sUSDS 4.612968 | $5.0517 |
| Ethena | `ethena` | ✅ | $4.4847 | sUSDe (`0x9d39a5de…`) | supply USDe 4.487362 | $4.4847 | price feed | sUSDe 3.647417 | $4.4844 |
| Merkl | `merkl` | ✅ | $0.3036 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.139123 + supply USDT 0.000055 + supply USDC 0.000063 | $0.3036 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 8.905915 | $1.0000 | ✅ | $8.9059 | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | price feed | wallet / Holding | 8.905915 | $8.9043 |
| USDe | 0.999922 | $0.9994 | ✅ | $0.9993 | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | price feed | wallet / Holding | 0.999922 | $0.9992 |
| USDC | 9.626826 | $1.0000 | ✅ | $9.6268 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.626826 | $9.6254 |
| cUSD | 4.990006 | $1.0001 | ✅ | $4.9905 | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | — | — | — | — |
| USDT | 4.717667 | $0.9999 | ✅ | $4.7173 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 4.717667 | $4.7174 |
| USDS | 14.831886 | $0.9998 | ✅ | $14.8289 | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | price feed | wallet / Holding | 14.831886 | $14.8257 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| adapter | Cap / cUSD + stcUSD | USDC | 10.050103 | $10.0486 |

### Optimism (chain 10)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Gnosis (chain 100)

**NAV: $5.0066 | Debank filtered: $5.0054 | Drift: +0.02% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $2.0084 | Lending (`0xb5020155…`) | supply WXDAI 2.008813 | $2.0084 | Aave V3 Gnosis | supply WXDAI 2.008829 | $2.0088 |
| Gnosis | `gnosis` | ✅ | $0.0000 | — | — | — | price feed | sDAI 0.000014 | $0.0000 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 0.998493 | $0.9994 | ✅ | $0.9979 | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | price feed | wallet / Holding | 0.998493 | $0.9983 |
| xDai | 1.999518 | $0.9998 | ✅ | $1.9991 | `xdai` | price feed | wallet / Holding | 1.999518 | $1.9995 |

### Base (chain 8453)

**NAV: $9.9998 | Debank filtered: $10.0014 | Drift: -0.02% ✅**

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| USDC | 10.001207 | $1.0000 | ✅ | $10.0012 | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | price feed | wallet / Holding | 10.001207 | $9.9997 |

### Arbitrum (chain 42161)

**NAV: $10.0257 | Debank filtered: $10.0248 | Drift: +0.01% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $2.0185 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.010867 | $1.0109 | Morpho Vault | supply USDC 1.010886 | $1.0108 |
| | | | | | | | Morpho Blue - sUSDS/USDC | supply USDC 1.007308 | $1.0072 |
| | | | | Deposit (`0x6c247b1f…`) | supply USDC 1.007296 | $1.0073 | — | — | — |
| Aave V3 | `aave3` | ✅ | $1.0023 | Lending (`0x794a6135…`) | supply USDC 2.012189 + borrow GHO 1.009893 | $1.0023 | Aave V3 Arbitrum | supply USDC 2.012214 | $2.0120 |
| | | | | | | | Aave V3 Arbitrum | borrow GHO 1.009910 | $-1.0097 |
| Merkl | `merkl` | ❌ | $0.0004 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| syrupUSDC | 1.732523 | $1.1618 | ✅ | $2.0128 | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | price feed | wallet / Holding | 1.732523 | $2.0145 |
| GHO | 0.956018 | $1.0000 | ✅ | $0.9560 | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | price feed | wallet / Holding | 0.956018 | $0.9559 |
| USDC | 2.004327 | $1.0000 | ✅ | $2.0043 | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | price feed | wallet / Holding | 2.004327 | $2.0041 |
| USD₮0 | 2.031070 | $0.9999 | ✅ | $2.0309 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | price feed | wallet / Holding | 2.031070 | $2.0308 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.152M | Debank filtered: $1.163M | Drift: -0.93% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $1.163M | Lending (`0x87870bca…`) | supply WETH 0.011597 + supply rsETH 2,326.4202 + borrow WETH 2,001.4307 | $1.163M | Aave V3 Core | supply WETH 0.011597 | $27.4250 |
| | | | | | | | Aave V3 Core | supply rsETH 2,326.4202 | $5.885M |
| | | | | | | | Aave V3 Core | borrow WETH 2,001.4832 | $-4.733M |
| Kelp DAO | `kelpdao` | ✅ | $745.9259 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $745.9259 | price feed | rsETH 0.292977 | $741.0639 |
| Merkl | `merkl` | ✅ | $27.7552 | Rewards (`0x3ef3d8ba…`) | supply GEAR 91,169.3043 + supply ETH 0.000000 | $27.7552 | — | — | — |
| LIDO | `lido` | ✅ | $0.0059 | — | — | — | price feed | wstETH 0.000002 | $0.0058 |
| | | | | | | | price feed | stETH 0.000000 | $0.0000 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.002564 | $2,380.33 | ✅ | $6.1039 | `eth` | price feed | wallet / Holding | 0.002564 | $6.0641 |

### Optimism (chain 10)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Gnosis (chain 100)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Base (chain 8453)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Arbitrum (chain 42161)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

---

## ACCOUNT_3

**Address:** `0x408ea1bC71ec2562ABCB27520cf7077718403496`

### Mainnet (chain 1)

**NAV: $277.9740 | Debank filtered: $353.8447 | Drift: -21.44% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Balancer V3 | `balancer3` | ✅ | $83.4125 | Farming (`0x62a66eb9…`) | supply WETH 0.017348 + supply ETH 0.017645 + reward BAL 0.757598 | $83.4125 | Balancer V3 - rETH/Aave WETH | supply WETH 0.017348 | $41.0243 |
| | | | | | | | Balancer V3 - rETH/Aave WETH | supply BAL 0.757598 | $0.1168 |
| | | | | | | | Balancer V3 - rETH/Aave WETH | supply rETH 0.015174 | $41.7258 |
| Aave V3 | `aave3` | ✅ | $69.3352 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005019 + supply ezETH 0.005000 + borrow WETH 0.005024 | $27.4842 | Aave V3 Prime | supply wstETH 0.005000 | $14.5883 |
| | | | | | | | Aave V3 Prime | supply WETH 0.005019 | $11.8686 |
| | | | | | | | Aave V3 Prime | supply ezETH 0.005000 | $12.7372 |
| | | | | | | | Aave V3 Prime | borrow WETH 0.005025 | $-11.8821 |
| | | | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.059712 + borrow WETH 0.059002 | $41.8510 | Aave V3 Core | supply WETH 0.002969 | $7.0205 |
| | | | | | | | Aave V3 Core | supply wstETH 0.059712 | $174.2042 |
| | | | | | | | Aave V3 Core | borrow WETH 0.059006 | $-139.5372 |
| Rocket Pool | `rocketpool` | ✅ | $41.4806 | rETH (`0xae78736c…`) | supply ETH 0.017426 | $41.4806 | price feed | rETH 0.014986 | $41.2102 |
| Convex | `convex` | ✅ | $30.4054 | Staked (`0x5411cc58…`) | supply WETH 0.001229 + supply ETH 0.011526 + reward CRV 0.183834 + reward CVX 0.000062 | $30.4054 | Convex | supply WETH 0.001260 | $2.9789 |
| | | | | | | | Convex | supply CRV 0.186353 | $0.0456 |
| | | | | | | | Convex | supply weETH 0.010506 | $27.1070 |
| | | | | | | | Convex | supply CVX 0.000186 | $0.0003 |
| ether.fi | `etherfi` | ✅ | $21.4524 | weETH (`0xcd5fe23c…`) | supply ETH 0.009012 | $21.4524 | price feed | weETH 0.008237 | $21.2532 |
| Kelp DAO | `kelpdao` | ✅ | $10.9301 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.9301 | price feed | rsETH 0.004293 | $10.8588 |
| Merkl | `merkl` | ✅ | $0.2133 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000006 + supply ETH 0.000006 + supply GEAR 6.174863 + supply RPL 0.092808 | $0.2133 | Merkl | supply RPL 0.096456 | $0.1873 |
| Aura Finance | `aurafinance` | ✅ | $0.0946 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.130822 | $0.0946 | Aura | supply BAL 0.489289 | $0.0754 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| WETH | 0.002000 | $2,380.33 | ✅ | $4.7607 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.002000 | $4.7296 |
| ETH | 0.007468 | $2,380.33 | ✅ | $17.7771 | `eth` | price feed | wallet / Holding | 0.007468 | $17.6612 |

### Optimism (chain 10)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Gnosis (chain 100)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Base (chain 8453)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Arbitrum (chain 42161)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

---

## ACCOUNT_4_UMBRELLA

**Address:** `0x13Ce0C26A44C644cCEB29B1e5B437521095F86DF`

### Mainnet (chain 1)

**NAV: $177,054.60 | Debank filtered: $177,190.74 | Drift: -0.08% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $177,181.36 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 35.184884 | $66,425.85 | Aave Umbrella | supply GHO 66,390.6641 | $66,378.85 |
| | | | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,194.0396 + reward USDC 10.995750 | $65,205.04 | Aave Umbrella | supply USDC 65,193.3125 | $65,183.53 |
| | | | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,657.3368 + reward USDT 6.010076 | $27,661.41 | Aave Umbrella | supply USDT 27,657.0114 | $27,655.17 |
| | | | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.514299 + reward WETH 0.001072 | $17,889.06 | Aave Umbrella | supply WETH 7.514219 | $17,769.74 |
| | | | | | | | Aave Umbrella | supply USDC 13.474822 | $13.4728 |
| | | | | | | | Aave Umbrella | supply USDT 7.311099 | $7.3106 |
| | | | | | | | Aave Umbrella | supply WETH 0.001302 | $3.0779 |
| | | | | | | | Aave Umbrella | supply GHO 42.782503 | $42.7749 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.000282 | $2,380.33 | ✅ | $0.6715 | `eth` | price feed | wallet / Holding | 0.000282 | $0.6671 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.143M | Debank filtered: $8.144M | Drift: -0.01% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Fluid | `fluid` | ✅ | $5.047M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0475M | $5.047M | Fluid Lending | supply USDT 5.0474M | $5.047M |
| Compound V3 | `compound3` | ✅ | $3.096M | Lending (`0xc3d688b6…`) | reward COMP 24.720004 | $596.9881 | Compound v3 USDC | supply COMP 24.659673 | $591.7382 |
| | | | | Yield (`0xc3d688b6…`) | supply USDC 3.0959M | $3.096M | Compound v3 USDC | supply USDC 3.0958M | $3.095M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.086040 | $2,380.33 | ✅ | $204.8029 | `eth` | price feed | wallet / Holding | 0.086040 | $203.4680 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.766M | Debank filtered: $2.766M | Drift: +0.02% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $2.766M | Lending (`0x2e44e174…`) | reward COMP 38.421572 | $927.8810 | Compound v3 USDC | supply COMP 38.421572 | $918.4474 |
| | | | | Yield (`0x2e44e174…`) | supply USDC 756,121.3101 | $756,121.31 | Compound v3 USDC | supply USDC 756,155.9060 | $756,040.65 |
| | | | | Lending (`0x995e394b…`) | reward COMP 138.982925 | $3,356.44 | Compound v3 USDT | supply COMP 138.982925 | $3,322.31 |
| | | | | Yield (`0x995e394b…`) | supply USDT 2.0054M | $2.005M | Compound v3 USDT | supply USDT 2.0055M | $2.005M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.049027 | $2,380.33 | ✅ | $116.7009 | `op` | price feed | wallet / Holding | 0.049027 | $115.6409 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| adapter | Compound v3 WETH / Reward | COMP | 24.934844 | $596.0543 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.059M | Debank filtered: $2.059M | Drift: -0.01% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $2.059M | Yield (`0x9c4ec768…`) | supply USDC 2.0592M | $2.059M | Compound v3 USDC | supply USDC 2.0593M | $2.059M |
| Vertex | `vertex` | ❌ | $0.0004 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.001305 | $2,380.65 | ✅ | $3.1069 | `arb` | price feed | wallet / Holding | 0.001305 | $3.0786 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,580.72 | Debank filtered: $823,664.88 | Drift: -0.01% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $823,610.16 | Lending (`0xb125e668…`) | reward COMP 13.108705 | $316.5752 | Compound v3 USDC | supply COMP 13.108705 | $312.1135 |
| | | | | Yield (`0xb125e668…`) | supply USDC 823,293.5855 | $823,293.59 | Compound v3 USDC | supply USDC 823,341.4289 | $823,213.59 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| CASHW | 420,069.0000 | $0.0000 | ❌ | $2.9189 | `0x56d149dffd01564a0f472c4898b350a43439143d` | — | — | — | — |
| ETH | 0.023361 | $2,380.65 | ✅ | $55.6139 | `base` | price feed | wallet / Holding | 0.023361 | $55.0154 |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $14.969M | Debank filtered: $20.238M | Drift: -26.04% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $5.767M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.6529M | $2.653M | Morpho Vault | supply USDC 2.6528M | $2.652M |
| | | | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2006M | $2.583M | — | — | — |
| | | | | kpk ETH (`0xbb50a534…`) | supply WETH 223.234087 | $531,442.23 | Morpho Vault | supply WETH 223.233044 | $527,904.86 |
| LIDO | `lido` | ✅ | $2.143M | wstETH (`0x7f39c581…`) | supply stETH 212.614503 | $505,587.07 | price feed | wstETH 172.342940 | $502,793.98 |
| | | | | stETH (`0xae7ab965…`) | supply ETH 687.856992 | $1.638M | price feed | stETH 687.856992 | $1.628M |
| Sablier | `sablier` | ❌ | $1.405M | SAB-LOCKUP:sender#1173 (`0xcf8ce57f…`) | supply COW 7.9134M | $1.405M | — | — | — |
| Uniswap V3 | `uniswap3` | ✅ | $525,353.17 | #1213124 (`0xfbb81382…`) | supply WETH 52.622455 + supply COW 2.2479M + reward WETH 0.160749 + reward COW 2,648.0313 | $525,353.17 | — | — | — |
| StakeWise | `stakewise` | ✅ | $564.0764 | Lending (`0x15639e82…`) | supply ETH 0.388040 + borrow osETH 0.142290 | $564.0764 | — | — | — |
| Aave V3 | `aave3` | ✅ | $0.0568 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0568 | Aave V3 Core | supply WETH 0.000024 | $0.0564 |
| Compound V3 | `compound3` | ✅ | $0.0014 | — | — | — | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.0000 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| USDC | 9.6573M | $1.0000 | ✅ | $9.657M | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.6573M | $9.656M |
| WETH | 0.540302 | $2,380.65 | ✅ | $1,286.27 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.540302 | $1,277.72 |
| USDT | 152.306225 | $0.9999 | ✅ | $152.2956 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 152.306225 | $152.2961 |
| COW | 20.9085M | $0.1776 | ❌ | $3.713M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` | — | — | — | — |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $71.582M | Debank filtered: $155.005M | Drift: -53.82% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Sky | `sky` | ✅ | $29.602M | Savings USDS (`0xa3931d71…`) | supply USDS 29.6075M | $29.602M | price feed | sUSDS 27.0258M | $29.596M |
| StakeWise | `stakewise` | ✅ | $24.723M | Lending (`0xac0f906e…`) | supply ETH 10,385.1012 + borrow osETH 0.000006 | $24.723M | Stakewise v3 | supply ETH 10,385.1012 | $24.559M |
| Stader | `stader` | ✅ | $24.672M | ETHx (`0xa35b1b31…`) | supply ETH 10,363.3953 | $24.672M | — | — | — |
| Morpho | `morphoblue` | ✅ | $13.284M | kpk USDC (`0x4ef53d2c…`) | supply USDC 5.0710M | $5.071M | Morpho Vault | supply USDC 5.0711M | $5.070M |
| | | | | kpk ETH (`0xbb50a534…`) | supply WETH 3,449.8432 | $8.213M | Morpho Vault | supply WETH 3,449.8932 | $8.158M |
| Rocket Pool | `rocketpool` | ✅ | $4.162M | rETH (`0xae78736c…`) | supply ETH 1,748.4463 | $4.162M | price feed | rETH 1,503.6269 | $4.135M |
| Merkl | `merkl` | ✅ | $3,674.60 | Rewards (`0x3ef3d8ba…`) | supply MORPHO 1,611.6671 | $3,674.60 | — | — | — |
| Compound V3 | `compound3` | ✅ | $1,703.23 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,703.09 | Compound v3 USDS | supply COMP 70.521281 | $1,692.24 |
| | | | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1453 | Compound v3 USDC | supply COMP 0.006016 | $0.1444 |
| LIDO | `lido` | ✅ | $357.5998 | wstETH (`0x7f39c581…`) | supply stETH 0.150381 | $357.5998 | price feed | wstETH 0.121897 | $355.6242 |
| Uniswap V3 | `uniswap3` | ✅ | $45.1180 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.001364 + supply ETH 0.015757 + reward WETH 0.000907 + reward ETH 0.000925 | $45.1180 | — | — | — |
| Aave V3 | `aave3` | ✅ | $0.4352 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4352 | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.1493 | Farming (`0xc592c33e…`) | supply WETH 0.000000 + supply osETH 0.000000 + reward BAL 0.969753 | $0.1493 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| HEX | 1,895.0000 | $0.0006 | ❌ | $1.1383 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` | — | — | — | — |
| USDC | 3,043.7273 | $1.0000 | ✅ | $3,043.73 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 3,043.7273 | $3,043.27 |
| ETH | 24.999996 | $2,380.65 | ✅ | $59,516.24 | `eth` | price feed | wallet / Holding | 24.999996 | $59,120.37 |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $5.036M | Debank filtered: $7.072M | Drift: -28.79% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V2 | `aave2` | ✅ | $1.852M | Staked (`0x4da27a54…`) | supply AAVE 19,442.9617 + reward AAVE 1.522670 | $1.852M | — | — | — |
| | | | | Lending (`0x7d2768de…`) | supply BAL 58.491558 | $9.0028 | Aave V2 | supply BAL 58.491558 | $9.0179 |
| StakeWise | `stakewise` | ✅ | $884,519.35 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8915 | — | — | — |
| | | | | Lending (`0xac0f906e…`) | supply ETH 371.541124 | $884,509.38 | Stakewise v3 | supply ETH 371.527015 | $878,592.68 |
| | | | | Staked (`0xfe2e6372…`) | supply ETH 0.003813 | $9.0781 | — | — | — |
| Rocket Pool | `rocketpool` | ✅ | $173,564.69 | rETH (`0xae78736c…`) | supply ETH 72.906430 | $173,564.69 | price feed | rETH 62.694486 | $172,400.58 |
| Aave V3 | `aave3` | ✅ | $49,507.98 | Lending (`0x87870bca…`) | supply BAL 320,141.9860 | $49,275.02 | Aave V3 Core | supply BAL 320,141.6290 | $49,357.84 |
| | | | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 232.961382 | $232.9614 | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $35,782.08 | Liquidity Pool (`0xc5c91aea…`) | supply BAL 92,313.6397 + supply WETH 9.062029 | $35,782.08 | — | — | — |
| Across V2 | `acrocc_v2` | ❌ | $12,788.72 | Liquidity Pool (`0xfacd2ec4…`) | supply BAL 83,088.8503 | $12,788.72 | — | — | — |
| Compound V3 | `compound3` | ✅ | $108.7316 | Lending (`0xc3d688b6…`) | reward COMP 4.437373 | $107.1626 | Compound v3 USDC | supply COMP 4.437373 | $106.4801 |
| | | | | | | | Compound v3 USDC | supply USDC 1.569066 | $1.5688 |
| | | | | Yield (`0xc3d688b6…`) | supply USDC 1.569076 | $1.5691 | — | — | — |
| Uniswap V3 | `uniswap3` | ✅ | $9.9833 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.000154 + supply ETH 0.001778 + reward WETH 0.000102 + reward ETH 0.000104 | $5.0928 | Uniswap V3 | supply WETH 0.001972 | $4.6622 |
| | | | | | | | Uniswap V3 | supply WETH 0.000027 | $0.0628 |
| | | | | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.8905 | — | — | — |
| Multichain | `multichain` | ❌ | $3.2575 | anyBAL (`0xcb9d0b8c…`) | supply BAL 21.164100 | $3.2575 | — | — | — |
| Compound | `compound` | ❌ | $2.1311 | Lending (`0x3d981921…`) | supply DAI 1.132199 + supply AAVE 0.010451 + reward COMP 0.000146 | $2.1311 | — | — | — |
| LIDO | `lido` | ✅ | $0.0000 | — | — | — | price feed | stETH 0.000000 | $0.0000 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| POL | 91,874.4838 | $0.0992 | ❌ | $9,116.33 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` | — | — | — | — |
| USDC | 3.5520M | $1.0000 | ✅ | $3.552M | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 3.5520M | $3.551M |
| BAL | 2.4916M | $0.1539 | ✅ | $383,497.92 | `0xba100000625a3754423978a60c9317c58a424e3d` | price feed | wallet / Holding | 2.4916M | $384,142.90 |
| COW | 1.1876M | $0.1776 | ❌ | $210,920.11 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` | — | — | — | — |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000041 | $0.0959 |

