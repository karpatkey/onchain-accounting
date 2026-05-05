# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-05 21:32 UTC  
Tolerance: 1%

Debank anchor: from `accounts.json.expected.<cid>.debankUsd` (captured at forge-snapshot time). Re-run with `--refresh-debank` to recapture against current chain state.  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25030560 |
| optimism (10) | 151203237 |
| gnosis (100) | 46022713 |
| base (8453) | 45607952 |
| arbitrum (42161) | 459721381 |

---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $180.5867 | Debank filtered: $184.6383 | Drift: -2.19% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $61.5711 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.084225 | $10.0852 | Morpho Vault | supply USDC 10.084292 | $10.0828 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.087831 | $10.0888 | Morpho Blue - wstETH/USDC | supply USDC 10.087889 | $10.0864 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.038497 | $5.0379 | Morpho Blue - sUSDS/USDT | supply USDT 5.038546 | $5.0380 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1849 | Morpho Blue - wstUSR/USDC | supply USDC 17.063582 | $17.0610 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.087943 | $10.0890 | Morpho Blue - cbBTC/USDC | supply USDC 10.087997 | $10.0865 |
| | | | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.084285 | $10.0853 | Morpho Vault | supply USDC 10.084362 | $10.0828 |
| Aave V3 | `aave3` | ✅ | $52.5587 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $10.0030 | Aave V3 Safety Module | supply GHO 10.000000 | $9.9983 |
| | | | | Lending (`0x87870bca…`) | supply USDC 9.081970 + supply USDT 10.084632 + supply USDe 5.023696 + supply sUSDe 3.000000 + supply RLUSD 14.671267 + reward USDS 0.008929 | $42.5557 | Aave V3 Core | supply RLUSD 14.671317 | $14.6700 |
| Balancer V3 | `balancer3` | ✅ | $7.0046 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.759540 + supply GHO 3.138459 + supply USDC 2.105668 | $7.0046 | — | — | — |
| cap | `capapp` | ✅ | $5.0602 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.059751 | $5.0602 | — | — | — |
| Sky | `sky` | ✅ | $5.0530 | Savings USDS (`0xa3931d71…`) | supply USDS 5.053494 | $5.0530 | price feed | sUSDS 4.612968 | $5.0514 |
| Ethena | `ethena` | ✅ | $4.4845 | sUSDe (`0x9d39a5de…`) | supply USDe 4.487209 | $4.4845 | price feed | sUSDe 3.647417 | $4.4833 |
| Merkl | `merkl` | ✅ | $0.3025 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.139125 + supply USDT 0.000047 + supply USDC 0.000057 | $0.3025 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 8.905915 | $1.0003 | ✅ | $8.9086 | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | price feed | wallet / Holding | 8.905915 | $8.9044 |
| USDe | 0.999922 | $0.9994 | ✅ | $0.9993 | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | price feed | wallet / Holding | 0.999922 | $0.9991 |
| USDC | 9.626826 | $1.0001 | ✅ | $9.6278 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.626826 | $9.6254 |
| cUSD | 4.990006 | $1.0001 | ✅ | $4.9905 | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | — | — | — | — |
| USDT | 4.717667 | $0.9999 | ✅ | $4.7171 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 4.717667 | $4.7171 |
| USDS | 14.831886 | $0.9999 | ✅ | $14.8304 | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | price feed | wallet / Holding | 14.831886 | $14.8256 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | BAL | 0.029673 | $0.0046 |
| adapter | Aave V3 Core / Collateral | USDC | 9.082034 | $9.0807 |
| adapter | Aave V3 Core / Collateral | USDT | 10.084695 | $10.0835 |
| adapter | Aave V3 Core / Collateral | USDe | 5.023716 | $5.0193 |
| adapter | Aave V3 Core / Collateral | sUSDe | 3.000000 | $3.6875 |
| adapter | Cap / cUSD + stcUSD | USDC | 10.049790 | $10.0483 |
| adapter | Balancer V3 - Aave GHO/USDT/USDC / USDT | USDT | 2.072958 | $2.0727 |
| adapter | Balancer V3 - Aave GHO/USDT/USDC / GHO | GHO | 2.429021 | $2.4286 |
| adapter | Balancer V3 - Aave GHO/USDT/USDC / USDC | USDC | 2.501575 | $2.5012 |

### Optimism (chain 10)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Gnosis (chain 100)

**NAV: $5.0066 | Debank filtered: $5.0056 | Drift: +0.02% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $2.0086 | Lending (`0xb5020155…`) | supply WXDAI 2.008766 | $2.0086 | Aave V3 Gnosis | supply WXDAI 2.008773 | $2.0087 |
| Gnosis | `gnosis` | ❌ | $0.0000 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 0.998493 | $0.9994 | ✅ | $0.9979 | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | price feed | wallet / Holding | 0.998493 | $0.9983 |
| xDai | 1.999518 | $0.9999 | ✅ | $1.9993 | `xdai` | price feed | wallet / Holding | 1.999518 | $1.9995 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | sDAI | 0.000014 | $0.0000 |

### Base (chain 8453)

**NAV: $9.9998 | Debank filtered: $10.0003 | Drift: -0.01% ✅**

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| USDC | 10.001207 | $1.0001 | ✅ | $10.0022 | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | price feed | wallet / Holding | 10.001207 | $9.9997 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | GHO | 0.000143 | $0.0001 |

### Arbitrum (chain 42161)

**NAV: $10.0247 | Debank filtered: $10.0238 | Drift: +0.01% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $2.0186 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.010807 | $1.0109 | Morpho Vault | supply USDC 1.010814 | $1.0106 |
| | | | | Deposit (`0x6c247b1f…`) | supply USDC 1.007267 | $1.0074 | Morpho Blue - sUSDS/USDC | supply USDC 1.007272 | $1.0071 |
| Aave V3 | `aave3` | ✅ | $1.0027 | Lending (`0x794a6135…`) | supply USDC 2.012121 + borrow GHO 1.009848 | $1.0027 | Aave V3 Arbitrum | supply USDC 2.012131 | $2.0117 |
| Merkl | `merkl` | ❌ | $0.0004 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| syrupUSDC | 1.732523 | $1.1619 | ✅ | $2.0130 | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | price feed | wallet / Holding | 1.732523 | $2.0141 |
| GHO | 0.956018 | $0.9997 | ✅ | $0.9558 | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | price feed | wallet / Holding | 0.956018 | $0.9557 |
| USDC | 2.004327 | $1.0001 | ✅ | $2.0045 | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | price feed | wallet / Holding | 2.004327 | $2.0039 |
| USD₮0 | 2.031070 | $0.9999 | ✅ | $2.0308 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | price feed | wallet / Holding | 2.031070 | $2.0307 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| adapter | Aave V3 Arbitrum / Borrow | GHO | 1.009855 | −$1.0096 |
| adapter | Morpho Blue - syrupUSDC/USDC / Supply | USDC | 0.000321 | $0.0003 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.158M | Debank filtered: $1.153M | Drift: +0.48% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $1.156M | Lending (`0x87870bca…`) | supply WETH 0.011597 + supply rsETH 2,326.4202 + borrow WETH 2,001.3724 | $1.156M | Aave V3 Core | supply rsETH 2,326.4202 | $5.879M |
| Kelp DAO | `kelpdao` | ✅ | $744.2180 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $744.2180 | price feed | rsETH 0.292977 | $740.4137 |
| Merkl | `merkl` | ✅ | $27.6863 | Rewards (`0x3ef3d8ba…`) | supply GEAR 91,169.3043 + supply ETH 0.000000 | $27.6863 | — | — | — |
| LIDO | `lido` | ✅ | $0.0058 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.002564 | $2,374.88 | ✅ | $6.0900 | `eth` | price feed | wallet / Holding | 0.002564 | $6.0588 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | wstETH | 0.000002 | $0.0058 |
| price feed | wallet / Holding | stETH | 0.000000 | $0.0000 |
| adapter | Aave V3 Core / Collateral | WETH | 0.011597 | $27.3996 |
| adapter | Aave V3 Core / Borrow | WETH | 2,001.3678 | −$4.729M |

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

**NAV: $279.3774 | Debank filtered: $350.8366 | Drift: -20.37% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Balancer V3 | `balancer3` | ✅ | $83.2178 | Farming (`0x62a66eb9…`) | supply WETH 0.017500 + supply ETH 0.017492 + reward BAL 0.757598 | $83.2178 | Balancer V3 - rETH/Aave WETH | supply WETH 0.017500 | $41.3468 |
| Aave V3 | `aave3` | ✅ | $68.9575 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005019 + supply ezETH 0.005000 + borrow WETH 0.005024 | $27.4004 | Aave V3 Prime | supply WETH 0.005019 | $11.8578 |
| | | | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.059712 + borrow WETH 0.059002 | $41.5571 | Aave V3 Core | supply wstETH 0.059712 | $174.0514 |
| Rocket Pool | `rocketpool` | ✅ | $41.3856 | rETH (`0xae78736c…`) | supply ETH 0.017426 | $41.3856 | price feed | rETH 0.014986 | $41.1741 |
| Convex | `convex` | ✅ | $30.3343 | Staked (`0x5411cc58…`) | supply WETH 0.001171 + supply ETH 0.011583 + reward CRV 0.183834 + reward CVX 0.000062 | $30.3343 | — | — | — |
| ether.fi | `etherfi` | ✅ | $21.4029 | weETH (`0xcd5fe23c…`) | supply ETH 0.009012 | $21.4029 | price feed | weETH 0.008237 | $21.2345 |
| Kelp DAO | `kelpdao` | ✅ | $10.9050 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.9050 | price feed | rsETH 0.004293 | $10.8493 |
| Merkl | `merkl` | ✅ | $0.2094 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000006 + supply ETH 0.000006 + supply GEAR 6.174863 + supply RPL 0.092808 | $0.2094 | — | — | — |
| Aura Finance | `aurafinance` | ✅ | $0.0948 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.130822 | $0.0948 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| WETH | 0.002000 | $2,374.99 | ✅ | $4.7500 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.002000 | $4.7255 |
| ETH | 0.007468 | $2,374.99 | ✅ | $17.7372 | `eth` | price feed | wallet / Holding | 0.007468 | $17.6457 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| adapter | Merkl / Unclaimed Rewards | RPL | 0.092808 | $0.1767 |
| adapter | Aave V3 Core / Collateral | WETH | 0.002969 | $7.0140 |
| adapter | Aave V3 Core / Borrow | WETH | 0.059002 | −$139.4067 |
| adapter | Aave V3 Prime / Collateral | wstETH | 0.005000 | $14.5755 |
| adapter | Aave V3 Prime / Borrow | WETH | 0.005024 | −$11.8712 |
| adapter | Aave V3 Prime / Collateral | ezETH | 0.005000 | $12.7259 |
| adapter | Balancer V3 - rETH/Aave WETH / rETH | rETH | 0.015043 | $41.3286 |
| adapter | Balancer V3 - rETH/Aave WETH / BAL | BAL | 0.757598 | $0.1168 |
| adapter | Aura / rETH/Aave WETH | BAL | 0.489289 | $0.0754 |
| adapter | Convex / weETH/WETH | WETH | 0.001163 | $2.7480 |
| adapter | Convex / weETH/WETH | weETH | 0.010594 | $27.3114 |
| adapter | Convex / weETH/WETH | CRV | 0.183741 | $0.0440 |
| adapter | Convex / weETH/WETH | CVX | 0.000184 | $0.0003 |

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

**NAV: $177,121.65 | Debank filtered: $177,027.58 | Drift: +0.05% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $177,161.13 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 35.184884 | $66,445.78 | Aave Umbrella | supply GHO 66,390.6641 | $66,379.25 |
| | | | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,191.0829 + reward USDC 10.995750 | $65,208.60 | Aave Umbrella | supply USDC 65,190.1805 | $65,180.40 |
| | | | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,655.9741 + reward USDT 6.010076 | $27,658.66 | Aave Umbrella | supply USDT 27,655.5789 | $27,652.34 |
| | | | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.513946 + reward WETH 0.001072 | $17,848.09 | Aave Umbrella | supply WETH 7.513854 | $17,753.28 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.000282 | $2,374.99 | ✅ | $0.6700 | `eth` | price feed | wallet / Holding | 0.000282 | $0.6665 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | USDT | 0.002643 | $0.0026 |
| adapter | Aave V3 Core / Supply | WETH | 0.000000 | $0.0000 |
| adapter | Aave V3 Core / Supply | USDC | 0.000062 | $0.0001 |
| adapter | Aave V3 Core / Supply | USDT | 0.000015 | $0.0000 |
| adapter | Aave Umbrella / stkwaEthUSDC.v1 Rewards | USDC | 10.909994 | $10.9084 |
| adapter | Aave Umbrella / stkwaEthUSDT.v1 Rewards | USDT | 5.965023 | $5.9643 |
| adapter | Aave Umbrella / stkwaEthWETH.v1 Rewards | WETH | 0.001064 | $2.5146 |
| adapter | Aave Umbrella / stkGHO.v1 Rewards | GHO | 34.921676 | $34.9157 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.142M | Debank filtered: $8.144M | Drift: -0.02% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Fluid | `fluid` | ✅ | $5.047M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0471M | $5.047M | Fluid Lending | supply USDT 5.0472M | $5.047M |
| Compound V3 | `compound3` | ✅ | $3.097M | Lending (`0xc3d688b6…`) | reward COMP 24.386862 | $578.9441 | — | — | — |
| | | | | Yield (`0xc3d688b6…`) | supply USDC 3.0957M | $3.096M | Compound v3 USDC | supply USDC 3.0957M | $3.095M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.086040 | $2,374.79 | ✅ | $204.3262 | `eth` | price feed | wallet / Holding | 0.086040 | $203.2895 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | USDT | 0.008984 | $0.0090 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.762M | Debank filtered: $2.766M | Drift: -0.15% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $2.766M | Lending (`0x2e44e174…`) | reward COMP 38.421572 | $912.1281 | — | — | — |
| | | | | Yield (`0x2e44e174…`) | supply USDC 756,121.3101 | $756,196.93 | Compound v3 USDC | supply USDC 756,124.4229 | $756,013.98 |
| | | | | Lending (`0x995e394b…`) | reward COMP 138.982925 | $3,299.45 | — | — | — |
| | | | | Yield (`0x995e394b…`) | supply USDT 2.0054M | $2.005M | Compound v3 USDT | supply USDT 2.0054M | $2.005M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.049027 | $2,374.25 | ✅ | $116.4028 | `op` | price feed | wallet / Holding | 0.049027 | $116.2699 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | USDT | 0.000010 | $0.0000 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.059M | Debank filtered: $2.059M | Drift: -0.00% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $2.059M | Yield (`0x9c4ec768…`) | supply USDC 2.0592M | $2.059M | Compound v3 USDC | supply USDC 2.0592M | $2.059M |
| Vertex | `vertex` | ❌ | $0.0004 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.001305 | $2,374.79 | ✅ | $3.0992 | `arb` | price feed | wallet / Holding | 0.001305 | $3.0940 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,209.30 | Debank filtered: $823,520.82 | Drift: -0.04% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $823,687.12 | Lending (`0xb125e668…`) | reward COMP 13.108705 | $311.2007 | — | — | — |
| | | | | Yield (`0xb125e668…`) | supply USDC 823,293.5855 | $823,375.92 | Compound v3 USDC | supply USDC 823,291.5181 | $823,168.02 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| CASHW | 420,069.0000 | $0.0000 | ❌ | $2.9102 | `0x56d149dffd01564a0f472c4898b350a43439143d` | — | — | — | — |
| ETH | 0.023361 | $2,374.79 | ✅ | $55.4770 | `base` | price feed | wallet / Holding | 0.023361 | $55.4338 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | WETH | 0.000000 | $0.0000 |
| price feed | wallet / Holding | USDC | 0.000050 | $0.0000 |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $15.141M | Debank filtered: $20.208M | Drift: -25.07% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $5.756M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.6526M | $2.653M | Morpho Vault | supply USDC 2.6527M | $2.652M |
| | | | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2006M | $2.573M | — | — | — |
| | | | | kpk ETH (`0xbb50a534…`) | supply WETH 223.223882 | $530,109.84 | Morpho Vault | supply WETH 223.226900 | $527,427.13 |
| LIDO | `lido` | ✅ | $2.138M | wstETH (`0x7f39c581…`) | supply stETH 212.614503 | $503,994.91 | price feed | wstETH 172.342940 | $502,352.79 |
| | | | | stETH (`0xae7ab965…`) | supply ETH 687.856992 | $1.634M | price feed | stETH 687.856992 | $1.623M |
| Sablier | `sablier` | ❌ | $1.484M | SAB-LOCKUP:sender#1173 (`0xcf8ce57f…`) | supply COW 7.9244M | $1.484M | — | — | — |
| Uniswap V3 | `uniswap3` | ✅ | $545,963.84 | #1213124 (`0xfbb81382…`) | supply WETH 70.216581 + supply COW 2.0222M + reward WETH 0.094348 + reward COW 1,219.5370 | $545,963.84 | — | — | — |
| StakeWise | `stakewise` | ✅ | $562.0720 | Lending (`0x15639e82…`) | supply ETH 0.388010 + borrow osETH 0.142290 | $562.0720 | — | — | — |
| Aave V3 | `aave3` | ✅ | $0.0566 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0566 | Aave V3 Core | supply WETH 0.000024 | $0.0564 |
| Compound V3 | `compound3` | ✅ | $0.0014 | — | — | — | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.0000 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| USDC | 9.6573M | $1.0001 | ✅ | $9.658M | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.6573M | $9.656M |
| WETH | 0.540302 | $2,374.79 | ✅ | $1,283.10 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.540302 | $1,276.59 |
| USDT | 152.306225 | $0.9999 | ✅ | $152.2879 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 152.306225 | $152.2884 |
| COW | 20.9085M | $0.1873 | ❌ | $3.916M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` | — | — | — | — |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| adapter | Uniswap V3 / WETH/COW 0.3% | WETH | 65.845498 | $155,575.79 |
| adapter | Uniswap V3 / WETH/COW 0.3% Fees | WETH | 0.104987 | $248.0579 |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $47.083M | Debank filtered: $129.711M | Drift: -63.70% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Sky | `sky` | ✅ | $29.604M | Savings USDS (`0xa3931d71…`) | supply USDS 29.6070M | $29.604M | price feed | sUSDS 27.0258M | $29.594M |
| StakeWise | `stakewise` | ✅ | $24.662M | Lending (`0xac0f906e…`) | supply ETH 10,385.1012 + borrow osETH 0.000006 | $24.662M | — | — | — |
| Stader | `stader` | ✅ | $24.611M | ETHx (`0xa35b1b31…`) | supply ETH 10,363.3953 | $24.611M | — | — | — |
| Morpho | `morphoblue` | ✅ | $13.264M | kpk USDC (`0x4ef53d2c…`) | supply USDC 5.0709M | $5.071M | Morpho Vault | supply USDC 5.0708M | $5.070M |
| | | | | kpk ETH (`0xbb50a534…`) | supply WETH 3,449.8095 | $8.193M | Morpho Vault | supply WETH 3,449.7983 | $8.151M |
| Rocket Pool | `rocketpool` | ✅ | $4.152M | rETH (`0xae78736c…`) | supply ETH 1,748.4463 | $4.152M | price feed | rETH 1,503.6269 | $4.131M |
| Merkl | `merkl` | ✅ | $3,591.76 | Rewards (`0x3ef3d8ba…`) | supply MORPHO 1,611.6671 | $3,591.76 | — | — | — |
| Compound V3 | `compound3` | ✅ | $1,674.32 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,674.18 | — | — | — |
| | | | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1428 | — | — | — |
| LIDO | `lido` | ✅ | $356.4737 | wstETH (`0x7f39c581…`) | supply stETH 0.150381 | $356.4737 | price feed | wstETH 0.121897 | $355.3122 |
| Uniswap V3 | `uniswap3` | ✅ | $45.0069 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.001364 + supply ETH 0.015757 + reward WETH 0.000907 + reward ETH 0.000925 | $45.0069 | — | — | — |
| Aave V3 | `aave3` | ✅ | $0.4353 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4353 | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.1497 | Farming (`0xc592c33e…`) | supply WETH 0.000000 + supply osETH 0.000000 + reward BAL 0.969753 | $0.1497 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| HEX | 1,895.0000 | $0.0006 | ❌ | $1.1228 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` | — | — | — | — |
| USDC | 3,043.7273 | $1.0001 | ✅ | $3,044.03 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 3,043.7273 | $3,043.27 |
| ETH | 24.999996 | $2,374.79 | ✅ | $59,369.74 | `eth` | price feed | wallet / Holding | 24.999996 | $59,068.49 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | stETH | 0.000000 | $0.0000 |

