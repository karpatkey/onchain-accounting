# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-05 21:14 UTC  
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

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $61.5718 | supply: USDC 10.084225 ($10.0852) → **$10.0852**<br>supply: USDC 10.087831 ($10.0888) → **$10.0888**<br>supply: USDT 5.038497 ($5.0386) → **$5.0386**<br>supply: USDC 16.183234 ($16.1849) → **$16.1849**<br>supply: USDC 10.087943 ($10.0890) → **$10.0890**<br>supply: USDC 10.084285 ($10.0853) → **$10.0853** | adapter (Morpho Blue - cbBTC/USDC, Morpho Blue - sUSDS/USDT, Morpho Blue - wstETH/USDC, Morpho Blue - wstUSR/USDC, Morpho Vault) | $62.4375 |
| Aave V3 | `aave3` | ✅ | $52.5616 | supply: GHO 10.000000 ($10.0030) → **$10.0030**<br>supply: USDC 9.081970 ($9.0829) + USDT 10.084632 ($10.0848) + USDe 5.023696 ($5.0207) + sUSDe 3.000000 ($3.6886) + RLUSD 14.671267 ($14.6727); rewards: USDS 0.008929 ($0.0089) → **$42.5586** | adapter (Aave V3 Core, Aave V3 Safety Module) | $52.5393 |
| Balancer V3 | `balancer3` | ✅ | $7.0049 | supply: USDT 1.759540 ($1.7596) + GHO 3.138459 ($3.1394) + USDC 2.105668 ($2.1059) → **$7.0049** | adapter (Balancer V3 - Aave GHO/USDT/USDC) | $7.0025 |
| cap | `capapp` | ✅ | $5.0602 | supply: cUSD 5.059751 ($5.0602) → **$5.0602** | adapter (Cap) | $10.0483 |
| Sky | `sky` | ✅ | $5.0530 | supply: USDS 5.053494 ($5.0530) → **$5.0530** | price feed (sUSDS) | $5.0514 |
| Ethena | `ethena` | ✅ | $4.4845 | supply: USDe 4.487209 ($4.4845) → **$4.4845** | price feed (sUSDe) | $4.4833 |
| Merkl | `merkl` | ✅ | $0.3024 | supply: RLUSD 0.113333 ($0.1133) + MORPHO 0.022386 ($0.0498) + GHO 0.139125 ($0.1392) + USDT 0.000047 ($0.0000) + USDC 0.000057 ($0.0001) → **$0.3024** | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 8.905915 | $1.0003 | ✅ | $8.9086 | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | price feed | wallet / Holding | 8.905915 | $8.9044 |
| USDe | 0.999922 | $0.9994 | ✅ | $0.9993 | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | price feed | wallet / Holding | 0.999922 | $0.9991 |
| USDC | 9.626826 | $1.0001 | ✅ | $9.6278 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.626826 | $9.6254 |
| cUSD | 4.990006 | $1.0001 | ✅ | $4.9905 | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | — | — | — | — |
| USDT | 4.717667 | $1.0000 | ✅ | $4.7178 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 4.717667 | $4.7171 |
| USDS | 14.831886 | $0.9999 | ✅ | $14.8304 | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | price feed | wallet / Holding | 14.831886 | $14.8256 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | BAL | 0.029673 | $0.0046 |

### Optimism (chain 10)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Gnosis (chain 100)

**NAV: $5.0066 | Debank filtered: $5.0056 | Drift: +0.02% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $2.0086 | supply: WXDAI 2.008766 ($2.0086) → **$2.0086** | adapter (Aave V3 Gnosis) | $2.0087 |
| Gnosis | `gnosis` | ❌ | $0.0000 | supply: WXDAI 0.000018 ($0.0000) → **$0.0000** | price feed (sDAI) | $0.0000 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 0.998493 | $0.9994 | ✅ | $0.9979 | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | price feed | wallet / Holding | 0.998493 | $0.9983 |
| xDai | 1.999518 | $0.9999 | ✅ | $1.9993 | `xdai` | price feed | wallet / Holding | 1.999518 | $1.9995 |

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

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $2.0186 | supply: USDC 1.010807 ($1.0109) → **$1.0109**<br>supply: USDC 0.000322 ($0.0003) → **$0.0003**<br>supply: USDC 1.007267 ($1.0074) → **$1.0074** | adapter (Morpho Blue - sUSDS/USDC, Morpho Blue - syrupUSDC/USDC, Morpho Vault) | $2.0180 |
| Aave V3 | `aave3` | ✅ | $1.0026 | supply: USDC 2.012121 ($2.0123); borrow: GHO 1.009848 ($1.0097) → **$1.0026** | adapter (Aave V3 Arbitrum) | $1.0022 |
| Merkl | `merkl` | ❌ | $0.0004 | supply: MORPHO 0.000083 ($0.0002) + ARB 0.001766 ($0.0002) → **$0.0004** | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| syrupUSDC | 1.732523 | $1.1619 | ✅ | $2.0130 | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | price feed | wallet / Holding | 1.732523 | $2.0141 |
| GHO | 0.956018 | $0.9998 | ✅ | $0.9559 | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | price feed | wallet / Holding | 0.956018 | $0.9557 |
| USDC | 2.004327 | $1.0001 | ✅ | $2.0045 | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | price feed | wallet / Holding | 2.004327 | $2.0039 |
| USD₮0 | 2.031070 | $1.0000 | ✅ | $2.0311 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | price feed | wallet / Holding | 2.031070 | $2.0307 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.158M | Debank filtered: $1.153M | Drift: +0.48% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $1.159M | supply: WETH 0.011597 ($27.5922) + rsETH 2,326.4202 ($5.921M); borrow: WETH 2,001.3724 ($4.762M) → **$1.159M** | adapter (Aave V3 Core) | $1.151M |
| Kelp DAO | `kelpdao` | ✅ | $745.6156 | supply: ETH 0.313371 ($745.6156) → **$745.6156** | price feed (rsETH) | $740.4137 |
| Merkl | `merkl` | ✅ | $27.7699 | supply: GEAR 91,169.3043 ($27.7699) + ETH 0.000000 ($0.0000) → **$27.7699** | — | — |
| LIDO | `lido` | ✅ | $0.0059 | supply: stETH 0.000002 ($0.0059) → **$0.0059**<br>supply: ETH 0.000000 ($0.0000) → **$0.0000** | price feed (stETH, wstETH) | $0.0058 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.002564 | $2,379.34 | ✅ | $6.1014 | `eth` | price feed | wallet / Holding | 0.002564 | $6.0588 |

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

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Balancer V3 | `balancer3` | ✅ | $83.3740 | supply: WETH 0.017500 ($41.6378) + ETH 0.017492 ($41.6190); rewards: BAL 0.757598 ($0.1172) → **$83.3740** | adapter (Balancer V3 - rETH/Aave WETH) | $82.7923 |
| Aave V3 | `aave3` | ✅ | $69.2614 | supply: wstETH 0.005000 ($14.6648) + WETH 0.005019 ($11.9411) + ezETH 0.005000 ($12.8157); borrow: WETH 0.005024 ($11.9547) → **$27.4670**<br>supply: WETH 0.002969 ($7.0633) + wstETH 0.059712 ($175.1176); borrow: WETH 0.059002 ($140.3864) → **$41.7944** | adapter (Aave V3 Core, Aave V3 Prime) | $68.9466 |
| Rocket Pool | `rocketpool` | ✅ | $41.4633 | supply: ETH 0.017426 ($41.4633) → **$41.4633** | price feed (rETH) | $41.1741 |
| Convex | `convex` | ✅ | $30.3913 | supply: WETH 0.001171 ($2.7871) + ETH 0.011583 ($27.5597); rewards: CRV 0.183834 ($0.0444) + CVX 0.000062 ($0.0001) → **$30.3913** | adapter (Convex) | $30.1037 |
| ether.fi | `etherfi` | ✅ | $21.4431 | supply: ETH 0.009012 ($21.4431) → **$21.4431** | price feed (weETH) | $21.2345 |
| Kelp DAO | `kelpdao` | ✅ | $10.9255 | supply: ETH 0.004592 ($10.9255) → **$10.9255** | price feed (rsETH) | $10.8493 |
| Merkl | `merkl` | ✅ | $0.2088 | supply: WETH 0.000006 ($0.0141) + ETH 0.000006 ($0.0141) + GEAR 6.174863 ($0.0019) + RPL 0.092808 ($0.1788) → **$0.2088** | adapter (Merkl) | $0.1767 |
| Aura Finance | `aurafinance` | ✅ | $0.0950 | supply: WETH 0.000000 ($0.0000) + ETH 0.000000 ($0.0000); rewards: BAL 0.489289 ($0.0757) + AURA 1.130822 ($0.0193) → **$0.0950** | adapter (Aura) | $0.0754 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| WETH | 0.002000 | $2,379.34 | ✅ | $4.7587 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.002000 | $4.7255 |
| ETH | 0.007468 | $2,379.34 | ✅ | $17.7697 | `eth` | price feed | wallet / Holding | 0.007468 | $17.6457 |

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

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $177,196.30 | supply: GHO 66,390.6641 ($66,410.58); rewards: GHO 35.184884 ($35.1954) → **$66,445.78**<br>supply: USDC 65,191.0829 ($65,197.60); rewards: USDC 10.995750 ($10.9968) → **$65,208.60**<br>supply: WETH 0.000000 ($0.0000) + USDC 0.000062 ($0.0001) + USDT 0.000015 ($0.0000) → **$0.0001**<br>supply: USDT 27,655.9326 ($27,656.49); rewards: USDT 6.010076 ($6.0102) → **$27,662.50**<br>supply: WETH 7.513946 ($17,876.88); rewards: WETH 0.001072 ($2.5510) → **$17,879.43** | adapter (Aave Umbrella, Aave V3 Core) | $177,019.58 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.000282 | $2,379.16 | ✅ | $0.6712 | `eth` | price feed | wallet / Holding | 0.000282 | $0.6665 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | USDT | 0.002643 | $0.0026 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.142M | Debank filtered: $8.144M | Drift: -0.02% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Fluid | `fluid` | ✅ | $5.047M | supply: USDT 5.0471M ($5.047M) → **$5.047M** | adapter (Fluid Lending) | $5.047M |
| Compound V3 | `compound3` | ✅ | $3.097M | rewards: COMP 24.386862 ($582.3583) → **$582.3583**<br>supply: USDC 3.0957M ($3.096M) → **$3.096M** | adapter (Compound v3 USDC) | $3.095M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.086040 | $2,379.16 | ✅ | $204.7022 | `eth` | price feed | wallet / Holding | 0.086040 | $203.2895 |

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

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $2.766M | rewards: COMP 38.421572 ($917.5071) → **$917.5071**<br>supply: USDC 756,121.3101 ($756,196.93) → **$756,196.93**<br>rewards: COMP 138.982925 ($3,318.91) → **$3,318.91**<br>supply: USDT 2.0054M ($2.005M) → **$2.005M** | adapter (Compound v3 USDC, Compound v3 USDT) | $2.761M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.049027 | $2,379.16 | ✅ | $116.6435 | `op` | price feed | wallet / Holding | 0.049027 | $116.2699 |

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

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $2.059M | supply: USDC 2.0592M ($2.059M) → **$2.059M** | adapter (Compound v3 USDC) | $2.059M |
| Vertex | `vertex` | ❌ | $0.0004 | supply: USDC 0.000000 ($0.0000) + WBTC 0.000000 ($0.0004) → **$0.0004** | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.001305 | $2,378.73 | ✅ | $3.1044 | `arb` | price feed | wallet / Holding | 0.001305 | $3.0940 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,209.30 | Debank filtered: $823,520.82 | Drift: -0.04% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $823,688.96 | rewards: COMP 13.108705 ($313.0359) → **$313.0359**<br>supply: USDC 823,293.5855 ($823,375.92) → **$823,375.92** | adapter (Compound v3 USDC) | $823,168.02 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| CASHW | 420,069.0000 | $0.0000 | ❌ | $2.9173 | `0x56d149dffd01564a0f472c4898b350a43439143d` | — | — | — | — |
| ETH | 0.023361 | $2,379.65 | ✅ | $55.5905 | `base` | price feed | wallet / Holding | 0.023361 | $55.4338 |

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

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $5.757M | supply: USDC 2.6526M ($2.653M) → **$2.653M**<br>supply: EURC 2.2006M ($2.573M) → **$2.573M**<br>supply: WETH 223.223882 ($530,989.34) → **$530,989.34** | adapter (Morpho Vault) | $3.180M |
| LIDO | `lido` | ✅ | $2.141M | supply: stETH 212.614503 ($505,142.88) → **$505,142.88**<br>supply: ETH 687.856992 ($1.636M) → **$1.636M** | price feed (stETH, wstETH) | $2.125M |
| Sablier | `sablier` | ❌ | $1.484M | supply: COW 7.9244M ($1.484M) → **$1.484M** | — | — |
| Uniswap V3 | `uniswap3` | ✅ | $546,240.86 | supply: WETH 70.216581 ($167,026.29) + COW 2.0222M ($378,761.73); rewards: WETH 0.094348 ($224.4286) + COW 1,219.5370 ($228.4193) → **$546,240.86** | adapter (Uniswap V3) | $155,823.85 |
| StakeWise | `stakewise` | ❌ | $563.0693 | supply: ETH 0.388010 ($922.9712); borrow: osETH 0.142290 ($359.9019) → **$563.0693** | — | — |
| Aave V3 | `aave3` | ✅ | $0.0567 | supply: WETH 0.000024 ($0.0567) → **$0.0567** | adapter (Aave V3 Core) | $0.0564 |
| Compound V3 | `compound3` | ✅ | $0.0014 | rewards: COMP 0.000059 ($0.0014) → **$0.0014** | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.0000 | supply: WETH 0.000000 ($0.0000) + COW 0.000000 ($0.0000) → **$0.0000**<br>supply: waDAI 0.000030 ($0.0000) + DAI 0.000000 ($0.0000) + waUSDT 0.000074 ($0.0000) + USDT 0.000000 ($0.0000) + waUSDC 0.000014 ($0.0000) + USDC 0.000018 ($0.0000) → **$0.0000** | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| USDC | 9.6573M | $1.0001 | ✅ | $9.658M | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.6573M | $9.656M |
| WETH | 0.540302 | $2,378.73 | ✅ | $1,285.23 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.540302 | $1,276.59 |
| USDT | 152.306225 | $1.0000 | ✅ | $152.3093 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 152.306225 | $152.2884 |
| COW | 20.9085M | $0.1873 | ❌ | $3.916M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` | — | — | — | — |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $47.083M | Debank filtered: $129.711M | Drift: -63.70% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Debank USD | Debank position detail | NAV type | NAV USD |
|---|---|:---:|---:|---|---|---:|
| Sky | `sky` | ✅ | $29.604M | supply: USDS 29.6070M ($29.604M) → **$29.604M** | price feed (sUSDS) | $29.594M |
| StakeWise | `stakewise` | ❌ | $24.703M | supply: ETH 0.000000 ($0.0000) → **$0.0000**<br>supply: ETH 10,385.1012 ($24.703M); borrow: osETH 0.000006 ($0.0141) → **$24.703M** | — | — |
| Stader | `stader` | ✅ | $24.652M | supply: ETH 10,363.3953 ($24.652M) → **$24.652M** | — | — |
| Morpho | `morphoblue` | ✅ | $13.278M | supply: USDC 5.0709M ($5.071M) → **$5.071M**<br>supply: WETH 3,449.8095 ($8.206M) → **$8.206M** | adapter (Morpho Vault) | $13.221M |
| Rocket Pool | `rocketpool` | ✅ | $4.159M | supply: ETH 1,748.4463 ($4.159M) → **$4.159M** | price feed (rETH) | $4.131M |
| Merkl | `merkl` | ✅ | $3,586.44 | supply: MORPHO 1,611.6671 ($3,586.44) → **$3,586.44** | — | — |
| Compound V3 | `compound3` | ✅ | $1,684.19 | rewards: COMP 70.521281 ($1,684.05) → **$1,684.05**<br>rewards: COMP 0.006016 ($0.1437) → **$0.1437** | — | — |
| LIDO | `lido` | ✅ | $357.2856 | supply: stETH 0.150381 ($357.2856) → **$357.2856**<br>supply: ETH 0.000000 ($0.0000) → **$0.0000** | price feed (stETH, wstETH) | $355.3122 |
| Uniswap V3 | `uniswap3` | ✅ | $45.0816 | supply: WETH 0.001364 ($3.2435) + ETH 0.015757 ($37.4809); rewards: WETH 0.000907 ($2.1571) + ETH 0.000925 ($2.2001) → **$45.0816** | — | — |
| Aave V3 | `aave3` | ✅ | $0.4353 | rewards: USDS 0.435315 ($0.4353) → **$0.4353** | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.1500 | supply: WETH 0.000000 ($0.0000) + osETH 0.000000 ($0.0000); rewards: BAL 0.969753 ($0.1500) → **$0.1500** | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| HEX | 1,895.0000 | $0.0006 | ❌ | $1.1338 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` | — | — | — | — |
| USDC | 3,043.7273 | $1.0001 | ✅ | $3,044.03 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 3,043.7273 | $3,043.27 |
| ETH | 24.999996 | $2,378.73 | ✅ | $59,468.24 | `eth` | price feed | wallet / Holding | 24.999996 | $59,068.49 |

