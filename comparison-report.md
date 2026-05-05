# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-05 20:49 UTC  
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

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | USDC | 9.626826 | $9.6254 | wallet (USDC) | $9.6268 |
| price feed | wallet / Holding | BAL | 0.029673 | $0.0046 | — | — |
| price feed | wallet / Holding | USDS | 14.831886 | $14.8256 | wallet (USDS) | $14.8304 |
| price feed | wallet / Holding | USDT | 4.717667 | $4.7171 | wallet (USDT) | $4.7181 |
| price feed | wallet / Holding | GHO | 8.905915 | $8.9044 | wallet (GHO) | $8.9113 |
| price feed | wallet / Holding | USDe | 0.999922 | $0.9991 | wallet (USDe) | $0.9993 |
| price feed | wallet / Holding | sUSDe | 3.647417 | $4.4833 | `aave3` protocol | $52.5629 |
| price feed | wallet / Holding | sUSDS | 4.612968 | $5.0514 | `sky` protocol | $5.0530 |
| adapter | Aave V3 Core / Collateral | USDC | 9.082034 | $9.0807 | `aave3` | $52.5629 |
| adapter | Aave V3 Core / Collateral | USDT | 10.084695 | $10.0835 | `aave3` | $52.5629 |
| adapter | Aave V3 Core / Collateral | USDe | 5.023716 | $5.0193 | `aave3` | $52.5629 |
| adapter | Aave V3 Core / Collateral | sUSDe | 3.000000 | $3.6875 | `aave3` | $52.5629 |
| adapter | Aave V3 Core / Supply | RLUSD | 14.671317 | $14.6700 | `aave3` | $52.5629 |
| adapter | Aave V3 Safety Module / stkGHO | GHO | 10.000000 | $9.9983 | `aave3` | $52.5629 |
| adapter | Cap / cUSD + stcUSD | USDC | 10.049790 | $10.0483 | `capapp` | $5.0602 |
| adapter | Morpho Vault / kpk USDC Prime V1 | USDC | 10.084362 | $10.0828 | `morphoblue` | $61.5665 |
| adapter | Morpho Vault / kpk USDC Prime V2 | USDC | 10.084292 | $10.0828 | `morphoblue` | $61.5665 |
| adapter | Morpho Blue - wstETH/USDC / Supply | USDC | 10.087889 | $10.0864 | `morphoblue` | $61.5665 |
| adapter | Morpho Blue - cbBTC/USDC / Supply | USDC | 10.087997 | $10.0865 | `morphoblue` | $61.5665 |
| adapter | Morpho Blue - wstUSR/USDC / Supply | USDC | 17.063582 | $17.0610 | `morphoblue` | $61.5665 |
| adapter | Morpho Blue - sUSDS/USDT / Supply | USDT | 5.038546 | $5.0380 | `morphoblue` | $61.5665 |
| adapter | Balancer V3 - Aave GHO/USDT/USDC / USDT | USDT | 2.072958 | $2.0727 | `balancer3` | $7.0057 |
| adapter | Balancer V3 - Aave GHO/USDT/USDC / GHO | GHO | 2.429021 | $2.4286 | `balancer3` | $7.0057 |
| adapter | Balancer V3 - Aave GHO/USDT/USDC / USDC | USDC | 2.501575 | $2.5012 | `balancer3` | $7.0057 |
| — | — | — | — | — | `ethena` ✅ | $4.4845 |
| — | — | — | — | — | `merkl` ✅ | $0.3025 |
| — | — | cUSD | 4.990006 | — | wallet ✅ | $4.9905 |

### Optimism (chain 10)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Gnosis (chain 100)

**NAV: $5.0066 | Debank filtered: $5.0056 | Drift: +0.02% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | xDAI | 1.999518 | $1.9995 | — | — |
| price feed | wallet / Holding | sDAI | 0.000014 | $0.0000 | `gnosis` protocol | $0.0000 |
| price feed | wallet / Holding | GHO | 0.998493 | $0.9983 | wallet (GHO) | $0.9980 |
| adapter | Aave V3 Gnosis / Collateral | WXDAI | 2.008773 | $2.0087 | `aave3` | $2.0086 |
| — | — | xDai | 1.999518 | — | wallet ❌ not in NAV | $1.9993 |

### Base (chain 8453)

**NAV: $9.9998 | Debank filtered: $10.0003 | Drift: -0.01% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | USDC | 10.001207 | $9.9997 | wallet (USDC) | $10.0012 |
| price feed | wallet / Holding | GHO | 0.000143 | $0.0001 | — | — |

### Arbitrum (chain 42161)

**NAV: $10.0247 | Debank filtered: $10.0238 | Drift: +0.01% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | USDC | 2.004327 | $2.0039 | wallet (USDC) | $2.0043 |
| price feed | wallet / Holding | USD₮0 | 2.031070 | $2.0307 | wallet (USD₮0) | $2.0313 |
| price feed | wallet / Holding | GHO | 0.956018 | $0.9557 | wallet (GHO) | $0.9557 |
| price feed | wallet / Holding | syrupUSDC | 1.732523 | $2.0141 | wallet (syrupUSDC) | $2.0128 |
| adapter | Aave V3 Arbitrum / Collateral | USDC | 2.012131 | $2.0117 | `aave3` | $1.0026 |
| adapter | Aave V3 Arbitrum / Borrow | GHO | 1.009855 | −$1.0096 | `aave3` | $1.0026 |
| adapter | Morpho Vault / kpk USDC Yield V1 | USDC | 1.010814 | $1.0106 | `morphoblue` | $2.0184 |
| adapter | Morpho Blue - syrupUSDC/USDC / Supply | USDC | 0.000321 | $0.0003 | `morphoblue` | $2.0184 |
| adapter | Morpho Blue - sUSDS/USDC / Supply | USDC | 1.007272 | $1.0071 | `morphoblue` | $2.0184 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.158M | Debank filtered: $1.153M | Drift: +0.48% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 0.002564 | $6.0588 | `kelpdao` protocol | $746.4868 |
| price feed | wallet / Holding | wstETH | 0.000002 | $0.0058 | — | — |
| price feed | wallet / Holding | rsETH | 0.292977 | $740.4137 | `aave3` protocol | $1.162M |
| price feed | wallet / Holding | stETH | 0.000000 | $0.0000 | `lido` protocol | $0.0059 |
| adapter | Aave V3 Core / Collateral | WETH | 0.011597 | $27.3996 | `aave3` | $1.162M |
| adapter | Aave V3 Core / Borrow | WETH | 2,001.3678 | −$4.729M | `aave3` | $1.162M |
| adapter | Aave V3 Core / Collateral | rsETH | 2,326.4202 | $5.879M | `aave3` | $1.162M |
| — | — | — | — | — | `merkl` ✅ | $28.2105 |
| — | — | ETH | 0.002564 | — | wallet ❌ not in NAV | $6.1085 |

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

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 0.007468 | $17.6457 | `balancer3` protocol | $83.4714 |
| price feed | wallet / Holding | WETH | 0.002000 | $4.7255 | wallet (WETH) | $4.7642 |
| price feed | wallet / Holding | weETH | 0.008237 | $21.2345 | — | — |
| price feed | wallet / Holding | rETH | 0.014986 | $41.1741 | — | — |
| price feed | wallet / Holding | rsETH | 0.004293 | $10.8493 | — | — |
| adapter | Merkl / Unclaimed Rewards | RPL | 0.092808 | $0.1767 | `merkl` | $0.2089 |
| adapter | Aave V3 Core / Collateral | WETH | 0.002969 | $7.0140 | `aave3` | $69.2859 |
| adapter | Aave V3 Core / Borrow | WETH | 0.059002 | −$139.4067 | `aave3` | $69.2859 |
| adapter | Aave V3 Core / Collateral | wstETH | 0.059712 | $174.0514 | `aave3` | $69.2859 |
| adapter | Aave V3 Prime / Collateral | wstETH | 0.005000 | $14.5755 | `aave3` | $69.2859 |
| adapter | Aave V3 Prime / Collateral | WETH | 0.005019 | $11.8578 | `aave3` | $69.2859 |
| adapter | Aave V3 Prime / Borrow | WETH | 0.005024 | −$11.8712 | `aave3` | $69.2859 |
| adapter | Aave V3 Prime / Collateral | ezETH | 0.005000 | $12.7259 | `aave3` | $69.2859 |
| adapter | Balancer V3 - rETH/Aave WETH / WETH | WETH | 0.017500 | $41.3468 | `balancer3` | $83.4714 |
| adapter | Balancer V3 - rETH/Aave WETH / rETH | rETH | 0.015043 | $41.3286 | `balancer3` | $83.4714 |
| adapter | Balancer V3 - rETH/Aave WETH / BAL | BAL | 0.757598 | $0.1168 | `balancer3` | $83.4714 |
| adapter | Aura / rETH/Aave WETH | BAL | 0.489289 | $0.0754 | `aurafinance` | $0.0951 |
| adapter | Convex / weETH/WETH | WETH | 0.001163 | $2.7480 | `convex` | $30.4266 |
| adapter | Convex / weETH/WETH | weETH | 0.010594 | $27.3114 | `convex` | $30.4266 |
| adapter | Convex / weETH/WETH | CRV | 0.183741 | $0.0440 | `convex` | $30.4266 |
| adapter | Convex / weETH/WETH | CVX | 0.000184 | $0.0003 | `convex` | $30.4266 |
| — | — | — | — | — | `rocketpool` ✅ | $41.5118 |
| — | — | — | — | — | `etherfi` ✅ | $21.4681 |
| — | — | — | — | — | `kelpdao` ✅ | $10.9383 |
| — | — | ETH | 0.007468 | — | wallet ❌ not in NAV | $17.7904 |

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

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 0.000282 | $0.6665 | — | — |
| price feed | wallet / Holding | USDT | 0.002643 | $0.0026 | `aave3` protocol | $177,233.52 |
| adapter | Aave V3 Core / Supply | WETH | 0.000000 | $0.0000 | `aave3` | $177,233.52 |
| adapter | Aave V3 Core / Supply | USDC | 0.000062 | $0.0001 | `aave3` | $177,233.52 |
| adapter | Aave V3 Core / Supply | USDT | 0.000015 | $0.0000 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkwaEthUSDC.v1 Staked | USDC | 65,190.1805 | $65,180.40 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkwaEthUSDC.v1 Rewards | USDC | 10.909994 | $10.9084 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkwaEthUSDT.v1 Staked | USDT | 27,655.5789 | $27,652.34 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkwaEthUSDT.v1 Rewards | USDT | 5.965023 | $5.9643 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkwaEthWETH.v1 Staked | WETH | 7.513854 | $17,753.28 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkwaEthWETH.v1 Rewards | WETH | 0.001064 | $2.5146 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkGHO.v1 Staked | GHO | 66,390.6641 | $66,379.25 | `aave3` | $177,233.52 |
| adapter | Aave Umbrella / stkGHO.v1 Rewards | GHO | 34.921676 | $34.9157 | `aave3` | $177,233.52 |
| — | — | ETH | 0.000282 | — | wallet ❌ not in NAV | $0.6720 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.142M | Debank filtered: $8.144M | Drift: -0.02% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 0.086040 | $203.2895 | — | — |
| price feed | wallet / Holding | USDT | 0.008984 | $0.0090 | `fluid` protocol | $5.048M |
| adapter | Compound v3 USDC / Supply | USDC | 3.0957M | $3.095M | `compound3` | $3.096M |
| adapter | Fluid Lending / fUSDT | USDT | 5.0472M | $5.047M | `fluid` | $5.048M |
| — | — | ETH | 0.086040 | — | wallet ❌ not in NAV | $204.9569 |

---

## ACCOUNT_6_COMPOUND_OPTIMISM

**Address:** `0xD20E007881ea62B5922B06D025c9dc1D41962953`

### Optimism (chain 10)

**NAV: $2.762M | Debank filtered: $2.766M | Drift: -0.15% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 0.049027 | $116.2699 | — | — |
| price feed | wallet / Holding | USDT | 0.000010 | $0.0000 | `compound3` protocol | $2.766M |
| adapter | Compound v3 USDC / Supply | USDC | 756,124.4229 | $756,013.98 | `compound3` | $2.766M |
| adapter | Compound v3 USDT / Supply | USDT | 2.0054M | $2.005M | `compound3` | $2.766M |
| — | — | ETH | 0.049027 | — | wallet ❌ not in NAV | $116.7886 |

---

## ACCOUNT_7_COMPOUND_ARBITRUM

**Address:** `0x530Bfd7DE5D63329E2DF996cf5afB2616524936D`

### Arbitrum (chain 42161)

**NAV: $2.059M | Debank filtered: $2.059M | Drift: -0.00% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 0.001305 | $3.0940 | — | — |
| adapter | Compound v3 USDC / Supply | USDC | 2.0592M | $2.059M | `compound3` | $2.059M |
| — | — | ETH | 0.001305 | — | wallet ❌ not in NAV | $3.1088 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,209.30 | Debank filtered: $823,520.82 | Drift: -0.04% ✅**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 0.023361 | $55.4338 | — | — |
| price feed | wallet / Holding | WETH | 0.000000 | $0.0000 | — | — |
| price feed | wallet / Holding | USDC | 0.000050 | $0.0000 | `compound3` protocol | $823,605.97 |
| adapter | Compound v3 USDC / Supply | USDC | 823,291.5181 | $823,168.02 | `compound3` | $823,605.97 |
| — | — | CASHW | 420,069.0000 | — | wallet ❌ not in NAV | $2.9207 |
| — | — | ETH | 0.023361 | — | wallet ❌ not in NAV | $55.6482 |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $15.141M | Debank filtered: $20.208M | Drift: -25.07% ⚠️**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | WETH | 0.540302 | $1,276.59 | wallet (WETH) | $1,287.07 |
| price feed | wallet / Holding | wstETH | 172.342940 | $502,352.79 | — | — |
| price feed | wallet / Holding | USDC | 9.6573M | $9.656M | wallet (USDC) | $9.657M |
| price feed | wallet / Holding | stETH | 687.856992 | $1.623M | `lido` protocol | $2.144M |
| price feed | wallet / Holding | USDT | 152.306225 | $152.2884 | wallet (USDT) | $152.3199 |
| adapter | Aave V3 Core / Collateral | WETH | 0.000024 | $0.0564 | `aave3` | $0.0568 |
| adapter | Morpho Vault / kpk ETH Prime V2 | WETH | 223.226900 | $527,427.13 | `morphoblue` | $5.757M |
| adapter | Morpho Vault / kpk USDC Prime V2 | USDC | 2.6527M | $2.652M | `morphoblue` | $5.757M |
| adapter | Uniswap V3 / WETH/COW 0.3% | WETH | 65.845498 | $155,575.79 | `uniswap3` | $546,883.90 |
| adapter | Uniswap V3 / WETH/COW 0.3% Fees | WETH | 0.104987 | $248.0579 | `uniswap3` | $546,883.90 |
| — | — | — | — | — | `sablier` ❌ not in NAV | $1.486M |
| — | — | — | — | — | `stakewise` ❌ not in NAV | $563.9529 |
| — | — | COW | 20.9085M | — | wallet ❌ not in NAV | $3.920M |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $47.083M | Debank filtered: $129.711M | Drift: -63.70% ⚠️**

#### Positions

| NAV type | Protocol / detail | Asset | NAV amount | NAV USD | Debank source | Debank USD |
|---|---|---|---:|---:|---|---:|
| price feed | wallet / Holding | ETH | 24.999996 | $59,068.49 | `stakewise` protocol | $24.739M |
| price feed | wallet / Holding | wstETH | 0.121897 | $355.3122 | — | — |
| price feed | wallet / Holding | rETH | 1,503.6269 | $4.131M | — | — |
| price feed | wallet / Holding | USDC | 3,043.7273 | $3,043.27 | wallet (USDC) | $3,043.73 |
| price feed | wallet / Holding | stETH | 0.000000 | $0.0000 | `lido` protocol | $357.7511 |
| price feed | wallet / Holding | sUSDS | 27.0258M | $29.594M | `sky` protocol | $29.604M |
| adapter | Morpho Vault / kpk ETH Prime V2 | WETH | 3,449.7983 | $8.151M | `morphoblue` | $13.289M |
| adapter | Morpho Vault / kpk USDC Prime V2 | USDC | 5.0708M | $5.070M | `morphoblue` | $13.289M |
| — | — | — | — | — | `stader` ✅ | $24.687M |
| — | — | — | — | — | `rocketpool` ✅ | $4.165M |
| — | — | — | — | — | `merkl` ✅ | $3,592.41 |
| — | — | — | — | — | `compound3` ✅ | $1,680.67 |
| — | — | — | — | — | `uniswap3` ✅ | $45.1458 |
| — | — | — | — | — | `aave3` ✅ | $0.4353 |
| — | — | — | — | — | `balancer2` ❌ not in NAV | $0.1502 |
| — | — | HEX | 1,895.0000 | — | wallet ❌ not in NAV | $1.0974 |
| — | — | ETH | 24.999996 | — | wallet ❌ not in NAV | $59,552.99 |

