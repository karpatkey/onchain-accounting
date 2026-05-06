# NAV vs Debank — Detailed Comparison Report

Generated: 2026-05-06 03:19 UTC  
Tolerance: 1%

Debank anchor: from `accounts.json.expected.<cid>.debankUsd` (captured at forge-snapshot time). Re-run with `--refresh-debank` to recapture against current chain state.  

## Fork blocks

| Chain | Block |
|---|---|
| mainnet (1) | 25032306 |
| optimism (10) | 151213722 |
| gnosis (100) | 46026802 |
| base (8453) | 45618437 |
| arbitrum (42161) | 459804671 |

---

## ACCOUNT_1

**Address:** `0xa57F127099421cEffEd866C1d969f8B0F4fCdbc6`

### Mainnet (chain 1)

**NAV: $180.7372 | Debank filtered: $184.6383 | Drift: -2.11% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $61.5674 | kpk USDC (`0x4ef53d2c…`) | supply USDC 10.084686 | $10.0847 | Morpho Vault | supply USDC 10.084681 | $10.0832 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.088206 | $10.0882 | Morpho Blue - cbBTC/USDC | supply USDC 10.088231 | $10.0867 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDT 5.038658 | $5.0382 | Morpho Blue - sUSDS/USDT | supply USDT 5.038628 | $5.0383 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 16.183234 | $16.1832 | Morpho Blue - wstUSR/USDC | supply USDC 17.154567 | $17.1520 |
| | | | | Deposit (`0xbbbbbbbb…`) | supply USDC 10.088323 | $10.0883 | Morpho Blue - wstETH/USDC | supply USDC 10.088117 | $10.0866 |
| | | | | USDC Prime (`0xe108fbc0…`) | supply USDC 10.084795 | $10.0848 | Morpho Vault | supply USDC 10.084579 | $10.0831 |
| Aave V3 | `aave3` | ✅ | $52.5476 | Staked (`0x1a88df1c…`) | supply GHO 10.000000 | $9.9890 | Aave V3 Safety Module | supply GHO 10.000000 | $9.9982 |
| | | | | Lending (`0x87870bca…`) | supply USDC 9.082349 + supply USDT 10.085052 + supply USDe 5.023880 + supply sUSDe 3.000000 + supply RLUSD 14.671598 + reward USDS 0.008929 | $42.5586 | Aave V3 Core | supply USDC 9.082279 | $9.0809 |
| | | | | | | | Aave V3 Core | supply USDT 10.084958 | $10.0843 |
| | | | | | | | Aave V3 Core | supply USDe 5.023847 | $5.0204 |
| | | | | | | | Aave V3 Core | supply sUSDe 3.000000 | $3.6883 |
| | | | | | | | Aave V3 Core | supply RLUSD 14.671525 | $14.6716 |
| Balancer V3 | `balancer3` | ✅ | $7.0001 | Aave GHO/USDT/USDC (`0x85b2b559…`) | supply USDT 1.844655 + supply GHO 3.183650 + supply USDC 1.975489 | $7.0001 | Balancer V3 - Aave GHO/USDT/USDC | supply USDT 1.790512 | $1.7904 |
| | | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply GHO 3.182706 | $3.1821 |
| | | | | | | | Balancer V3 - Aave GHO/USDT/USDC | supply USDC 2.030515 | $2.0302 |
| cap | `capapp` | ✅ | $5.0600 | Staked cap USD (`0x88887be4…`) | supply cUSD 5.060023 | $5.0600 | — | — | — |
| Sky | `sky` | ✅ | $5.0527 | Savings USDS (`0xa3931d71…`) | supply USDS 5.053685 | $5.0527 | price feed | sUSDS 4.612968 | $5.0515 |
| Ethena | `ethena` | ✅ | $4.4842 | sUSDe (`0x9d39a5de…`) | supply USDe 4.487362 | $4.4842 | price feed | sUSDe 3.647417 | $4.4843 |
| Merkl | `merkl` | ✅ | $0.3029 | Rewards (`0x3ef3d8ba…`) | supply RLUSD 0.113333 + supply MORPHO 0.022386 + supply GHO 0.139132 + supply USDT 0.000053 + supply USDC 0.000056 | $0.3029 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 8.905915 | $0.9989 | ✅ | $8.8961 | `0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f` | price feed | wallet / Holding | 8.905915 | $8.9043 |
| USDe | 0.999922 | $0.9993 | ✅ | $0.9992 | `0x4c9edd5852cd905f086c759e8383e09bff1e68b3` | price feed | wallet / Holding | 0.999922 | $0.9992 |
| USDC | 9.626826 | $1.0000 | ✅ | $9.6268 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.626826 | $9.6254 |
| cUSD | 4.990006 | $1.0000 | ✅ | $4.9900 | `0xcccc62962d17b8914c62d74ffb843d73b2a3cccc` | — | — | — | — |
| USDT | 4.717667 | $0.9999 | ✅ | $4.7172 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 4.717667 | $4.7174 |
| USDS | 14.831886 | $0.9998 | ✅ | $14.8289 | `0xdc035d45d973e3ec169d2276ddab16f1e407384f` | price feed | wallet / Holding | 14.831886 | $14.8257 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | BAL | 0.029673 | $0.0046 |
| adapter | Cap / cUSD + stcUSD | USDC | 10.049964 | $10.0485 |

### Optimism (chain 10)

**NAV: $0.0000 | Debank filtered: $0.0000 | Drift: — **

_No positions on this chain._

### Gnosis (chain 100)

**NAV: $5.0066 | Debank filtered: $5.0056 | Drift: +0.02% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $2.0084 | Lending (`0xb5020155…`) | supply WXDAI 2.008813 | $2.0084 | Aave V3 Gnosis | supply WXDAI 2.008799 | $2.0088 |
| Gnosis | `gnosis` | ✅ | $0.0000 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| GHO | 0.998493 | $0.9994 | ✅ | $0.9979 | `0xfc421ad3c883bf9e7c4f42de845c4e4405799e73` | price feed | wallet / Holding | 0.998493 | $0.9983 |
| xDai | 1.999518 | $0.9998 | ✅ | $1.9991 | `xdai` | price feed | wallet / Holding | 1.999518 | $1.9995 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | sDAI | 0.000014 | $0.0000 |

### Base (chain 8453)

**NAV: $9.9998 | Debank filtered: $10.0003 | Drift: -0.01% ✅**

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| USDC | 10.001207 | $1.0000 | ✅ | $10.0012 | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | price feed | wallet / Holding | 10.001207 | $9.9997 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | GHO | 0.000143 | $0.0001 |

### Arbitrum (chain 42161)

**NAV: $10.0247 | Debank filtered: $10.0238 | Drift: +0.01% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $2.0185 | USDC Yield (`0x2c609d9c…`) | supply USDC 1.010867 | $1.0109 | Morpho Vault | supply USDC 1.010814 | $1.0106 |
| | | | | Deposit (`0x6c247b1f…`) | supply USDC 1.007296 | $1.0073 | Morpho Blue - sUSDS/USDC | supply USDC 1.007272 | $1.0071 |
| Aave V3 | `aave3` | ✅ | $1.0026 | Lending (`0x794a6135…`) | supply USDC 2.012189 + borrow GHO 1.009893 | $1.0026 | Aave V3 Arbitrum | supply USDC 2.012131 | $2.0117 |
| | | | | | | | Aave V3 Arbitrum | borrow GHO 1.009855 | $-1.0096 |
| Merkl | `merkl` | ❌ | $0.0004 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| syrupUSDC | 1.732523 | $1.1618 | ✅ | $2.0128 | `0x41ca7586cc1311807b4605fbb748a3b8862b42b5` | price feed | wallet / Holding | 1.732523 | $2.0141 |
| GHO | 0.956018 | $0.9997 | ✅ | $0.9557 | `0x7dff72693f6a4149b17e7c6314655f6a9f7c8b33` | price feed | wallet / Holding | 0.956018 | $0.9557 |
| USDC | 2.004327 | $1.0000 | ✅ | $2.0043 | `0xaf88d065e77c8cc2239327c5edb3a432268e5831` | price feed | wallet / Holding | 2.004327 | $2.0039 |
| USD₮0 | 2.031070 | $0.9999 | ✅ | $2.0309 | `0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9` | price feed | wallet / Holding | 2.031070 | $2.0307 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| adapter | Morpho Blue - syrupUSDC/USDC / Supply | USDC | 0.000321 | $0.0003 |

---

## ACCOUNT_2

**Address:** `0x99b9F5F24205Cb88E33b1CC72008f644Fc23768b`

### Mainnet (chain 1)

**NAV: $1.148M | Debank filtered: $1.153M | Drift: -0.45% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $1.152M | Lending (`0x87870bca…`) | supply WETH 0.011597 + supply rsETH 2,326.4202 + borrow WETH 2,001.4307 | $1.152M | Aave V3 Core | supply WETH 0.011597 | $27.3145 |
| | | | | | | | Aave V3 Core | supply rsETH 2,326.4202 | $5.861M |
| | | | | | | | Aave V3 Core | borrow WETH 2,001.4271 | $-4.714M |
| Kelp DAO | `kelpdao` | ✅ | $742.6261 | rsETH (`0xa1290d69…`) | supply ETH 0.313371 | $742.6261 | price feed | rsETH 0.292977 | $738.0949 |
| Merkl | `merkl` | ✅ | $27.6079 | Rewards (`0x3ef3d8ba…`) | supply GEAR 91,169.3043 + supply ETH 0.000000 | $27.6079 | — | — | — |
| LIDO | `lido` | ✅ | $0.0058 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.002564 | $2,369.80 | ✅ | $6.0769 | `eth` | price feed | wallet / Holding | 0.002564 | $6.0398 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | wstETH | 0.000002 | $0.0058 |
| price feed | wallet / Holding | stETH | 0.000000 | $0.0000 |

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

**NAV: $276.8597 | Debank filtered: $350.8366 | Drift: -21.09% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Balancer V3 | `balancer3` | ✅ | $83.0408 | Farming (`0x62a66eb9…`) | supply WETH 0.017348 + supply ETH 0.017644 + reward BAL 0.757598 | $83.0408 | Balancer V3 - rETH/Aave WETH | supply WETH 0.017500 | $41.2183 |
| Aave V3 | `aave3` | ✅ | $68.7013 | Lending (`0x4e033931…`) | supply wstETH 0.005000 + supply WETH 0.005019 + supply ezETH 0.005000 + borrow WETH 0.005024 | $27.3305 | Aave V3 Prime | supply wstETH 0.005000 | $14.5298 |
| | | | | | | | Aave V3 Prime | supply WETH 0.005019 | $11.8208 |
| | | | | | | | Aave V3 Prime | supply ezETH 0.005000 | $12.6861 |
| | | | | | | | Aave V3 Prime | borrow WETH 0.005024 | $-11.8343 |
| | | | | Lending (`0x87870bca…`) | supply WETH 0.002969 + supply wstETH 0.059712 + borrow WETH 0.059002 | $41.3708 | Aave V3 Core | supply WETH 0.002969 | $6.9922 |
| | | | | | | | Aave V3 Core | supply wstETH 0.059712 | $173.5063 |
| | | | | | | | Aave V3 Core | borrow WETH 0.059004 | $-138.9742 |
| Rocket Pool | `rocketpool` | ✅ | $41.2971 | rETH (`0xae78736c…`) | supply ETH 0.017426 | $41.2971 | price feed | rETH 0.014986 | $41.0451 |
| Convex | `convex` | ✅ | $30.2700 | Staked (`0x5411cc58…`) | supply WETH 0.001194 + supply ETH 0.011560 + reward CRV 0.183834 + reward CVX 0.000062 | $30.2700 | Convex | supply WETH 0.001178 | $2.7750 |
| ether.fi | `etherfi` | ✅ | $21.3573 | weETH (`0xcd5fe23c…`) | supply ETH 0.009012 | $21.3573 | price feed | weETH 0.008237 | $21.1680 |
| Kelp DAO | `kelpdao` | ✅ | $10.8817 | rsETH (`0xa1290d69…`) | supply ETH 0.004592 | $10.8817 | price feed | rsETH 0.004293 | $10.8153 |
| Merkl | `merkl` | ✅ | $0.2104 | Rewards (`0x3ef3d8ba…`) | supply WETH 0.000006 + supply ETH 0.000006 + supply GEAR 6.174863 + supply RPL 0.092808 | $0.2104 | Merkl | supply RPL 0.094626 | $0.1838 |
| Aura Finance | `aurafinance` | ✅ | $0.0946 | aurarETH-waEthWETH-vault (`0x20283cce…`) | supply WETH 0.000000 + supply ETH 0.000000 + reward BAL 0.489289 + reward AURA 1.130822 | $0.0946 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| WETH | 0.002000 | $2,369.80 | ✅ | $4.7396 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.002000 | $4.7107 |
| ETH | 0.007468 | $2,369.80 | ✅ | $17.6984 | `eth` | price feed | wallet / Holding | 0.007468 | $17.5904 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| adapter | Balancer V3 - rETH/Aave WETH / rETH | rETH | 0.015043 | $41.1992 |
| adapter | Balancer V3 - rETH/Aave WETH / BAL | BAL | 0.757598 | $0.1168 |
| adapter | Aura / rETH/Aave WETH | BAL | 0.489289 | $0.0754 |
| adapter | Convex / weETH/WETH | weETH | 0.010580 | $27.1902 |
| adapter | Convex / weETH/WETH | CRV | 0.185080 | $0.0443 |
| adapter | Convex / weETH/WETH | CVX | 0.000185 | $0.0003 |

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

**NAV: $176,974.88 | Debank filtered: $177,027.58 | Drift: -0.03% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V3 | `aave3` | ✅ | $177,028.59 | Umbrella Stake Gho Token v1 (`0x4f827a63…`) | supply GHO 66,390.6641 + reward GHO 35.184884 | $66,352.78 | Aave Umbrella | supply GHO 66,390.6641 | $66,378.85 |
| | | | | Umbrella Stake Wrapped Aave Ethereum USDC v1 (`0x6bf18324…`) | supply USDC 65,192.6282 + reward USDC 10.995750 | $65,203.62 | Aave Umbrella | supply USDC 65,191.9425 | $65,182.16 |
| | | | | Umbrella Stake Wrapped Aave Ethereum USDT v1 (`0xa484ab92…`) | supply USDT 27,656.6576 + reward USDT 6.010076 | $27,660.18 | Aave Umbrella | supply USDT 27,656.2988 | $27,654.46 |
| | | | | Umbrella Stake Wrapped Aave Ethereum WETH v1 (`0xaafd07d5…`) | supply WETH 7.514131 + reward WETH 0.001072 | $17,812.01 | Aave Umbrella | supply WETH 7.514041 | $17,698.13 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.000282 | $2,370.13 | ✅ | $0.6686 | `eth` | price feed | wallet / Holding | 0.000282 | $0.6644 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | USDT | 0.002643 | $0.0026 |
| adapter | Aave V3 Core / Supply | WETH | 0.000000 | $0.0000 |
| adapter | Aave V3 Core / Supply | USDC | 0.000062 | $0.0001 |
| adapter | Aave V3 Core / Supply | USDT | 0.000015 | $0.0000 |
| adapter | Aave Umbrella / stkwaEthUSDC.v1 Rewards | USDC | 12.224466 | $12.2226 |
| adapter | Aave Umbrella / stkwaEthUSDT.v1 Rewards | USDT | 6.655007 | $6.6546 |
| adapter | Aave Umbrella / stkwaEthWETH.v1 Rewards | WETH | 0.001186 | $2.7931 |
| adapter | Aave Umbrella / stkGHO.v1 Rewards | GHO | 38.955282 | $38.9483 |

---

## ACCOUNT_5_COMPOUND_MAINNET

**Address:** `0x9C1b8c994935e3890bD2257AD2a681d6D4465a73`

### Mainnet (chain 1)

**NAV: $8.142M | Debank filtered: $8.144M | Drift: -0.01% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Fluid | `fluid` | ✅ | $5.047M | Fluid Tether USD (`0x5c20b550…`) | supply USDT 5.0471M | $5.047M | Fluid Lending | supply USDT 5.0473M | $5.047M |
| Compound V3 | `compound3` | ✅ | $3.096M | Lending (`0xc3d688b6…`) | reward COMP 24.386862 | $581.6267 | — | — | — |
| | | | | Yield (`0xc3d688b6…`) | supply USDC 3.0957M | $3.096M | Compound v3 USDC | supply USDC 3.0958M | $3.095M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.086040 | $2,370.13 | ✅ | $203.9253 | `eth` | price feed | wallet / Holding | 0.086040 | $202.6528 |

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
| Compound V3 | `compound3` | ✅ | $2.766M | Lending (`0x2e44e174…`) | reward COMP 38.421572 | $916.3545 | — | — | — |
| | | | | Yield (`0x2e44e174…`) | supply USDC 756,121.3101 | $756,121.31 | Compound v3 USDC | supply USDC 756,140.5587 | $756,030.11 |
| | | | | Lending (`0x995e394b…`) | reward COMP 138.982925 | $3,314.74 | — | — | — |
| | | | | Yield (`0x995e394b…`) | supply USDT 2.0054M | $2.005M | Compound v3 USDT | supply USDT 2.0055M | $2.005M |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| ETH | 0.049027 | $2,370.13 | ✅ | $116.2008 | `op` | price feed | wallet / Holding | 0.049027 | $115.8626 |

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
| ETH | 0.001305 | $2,370.13 | ✅ | $3.0932 | `arb` | price feed | wallet / Holding | 0.001305 | $3.0940 |

---

## ACCOUNT_8_COMPOUND_BASE

**Address:** `0xA46680F63b905DdC4A5fC3038584328A04623314`

### Base (chain 8453)

**NAV: $823,249.62 | Debank filtered: $823,520.82 | Drift: -0.03% ✅**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Compound V3 | `compound3` | ✅ | $823,606.23 | Lending (`0xb125e668…`) | reward COMP 13.108705 | $312.6426 | — | — | — |
| | | | | Yield (`0xb125e668…`) | supply USDC 823,293.5855 | $823,293.59 | Compound v3 USDC | supply USDC 823,291.5181 | $823,168.02 |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| CASHW | 420,069.0000 | $0.0000 | ❌ | $2.9041 | `0x56d149dffd01564a0f472c4898b350a43439143d` | — | — | — | — |
| ETH | 0.023361 | $2,370.13 | ✅ | $55.3681 | `base` | price feed | wallet / Holding | 0.023361 | $55.4338 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | WETH | 0.000000 | $0.0000 |
| price feed | wallet / Holding | USDC | 0.000050 | $0.0000 |

---

## ACCOUNT_9_MAINNET_DIVERSIFIED

**Address:** `0x616dE58c011F8736fa20c7Ae5352F7f6FB9F0669`

### Mainnet (chain 1)

**NAV: $14.956M | Debank filtered: $20.208M | Drift: -25.99% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Morpho | `morphoblue` | ✅ | $5.759M | kpk USDC (`0x4ef53d2c…`) | supply USDC 2.6526M | $2.653M | Morpho Vault | supply USDC 2.6528M | $2.652M |
| | | | | kpk EURC (`0xa877d5bb…`) | supply EURC 2.2006M | $2.577M | — | — | — |
| | | | | kpk ETH (`0xbb50a534…`) | supply WETH 223.223882 | $529,069.62 | Morpho Vault | supply WETH 223.230043 | $525,782.79 |
| LIDO | `lido` | ✅ | $2.133M | wstETH (`0x7f39c581…`) | supply stETH 212.614503 | $502,759.43 | price feed | wstETH 172.342940 | $500,779.58 |
| | | | | stETH (`0xae7ab965…`) | supply ETH 687.856992 | $1.630M | price feed | stETH 687.856992 | $1.620M |
| Sablier | `sablier` | ❌ | $1.387M | SAB-LOCKUP:sender#1173 (`0xcf8ce57f…`) | supply COW 7.9177M | $1.387M | — | — | — |
| Uniswap V3 | `uniswap3` | ✅ | $521,152.57 | #1213124 (`0xfbb81382…`) | supply WETH 70.216581 + supply COW 2.0222M + reward WETH 0.094348 + reward COW 1,219.5370 | $521,152.57 | — | — | — |
| StakeWise | `stakewise` | ✅ | $561.7473 | Lending (`0x15639e82…`) | supply ETH 0.388010 + borrow osETH 0.142290 | $561.7473 | — | — | — |
| Aave V3 | `aave3` | ✅ | $0.0565 | Lending (`0x87870bca…`) | supply WETH 0.000024 | $0.0565 | Aave V3 Core | supply WETH 0.000024 | $0.0562 |
| Compound V3 | `compound3` | ✅ | $0.0014 | — | — | — | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.0000 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| USDC | 9.6573M | $1.0000 | ✅ | $9.657M | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 9.6573M | $9.656M |
| WETH | 0.540302 | $2,370.13 | ✅ | $1,280.59 | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | price feed | wallet / Holding | 0.540302 | $1,272.60 |
| USDT | 152.306225 | $0.9999 | ✅ | $152.2925 | `0xdac17f958d2ee523a2206206994597c13d831ec7` | price feed | wallet / Holding | 152.306225 | $152.2961 |
| COW | 20.9085M | $0.1752 | ❌ | $3.663M | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` | — | — | — | — |

---

## ACCOUNT_10_MAINNET_LST_YIELD

**Address:** `0x4F2083f5fBede34C2714aFfb3105539775f7FE64`

### Mainnet (chain 1)

**NAV: $71.432M | Debank filtered: $129.711M | Drift: -44.93% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Sky | `sky` | ✅ | $29.602M | Savings USDS (`0xa3931d71…`) | supply USDS 29.6075M | $29.602M | price feed | sUSDS 27.0258M | $29.595M |
| StakeWise | `stakewise` | ✅ | $24.614M | Lending (`0xac0f906e…`) | supply ETH 10,385.1012 + borrow osETH 0.000006 | $24.614M | Stakewise v3 | supply ETH 10,385.1012 | $24.460M |
| Stader | `stader` | ✅ | $24.563M | ETHx (`0xa35b1b31…`) | supply ETH 10,363.3953 | $24.563M | — | — | — |
| Morpho | `morphoblue` | ✅ | $13.248M | kpk USDC (`0x4ef53d2c…`) | supply USDC 5.0710M | $5.071M | Morpho Vault | supply USDC 5.0710M | $5.070M |
| | | | | kpk ETH (`0xbb50a534…`) | supply WETH 3,449.8432 | $8.177M | Morpho Vault | supply WETH 3,449.8469 | $8.126M |
| Rocket Pool | `rocketpool` | ✅ | $4.144M | rETH (`0xae78736c…`) | supply ETH 1,748.4463 | $4.144M | price feed | rETH 1,503.6269 | $4.118M |
| Merkl | `merkl` | ✅ | $3,627.54 | Rewards (`0x3ef3d8ba…`) | supply MORPHO 1,611.6671 | $3,627.54 | — | — | — |
| Compound V3 | `compound3` | ✅ | $1,682.08 | Lending (`0x5d409e56…`) | reward COMP 70.521281 | $1,681.93 | — | — | — |
| | | | | Lending (`0xc3d688b6…`) | reward COMP 0.006016 | $0.1435 | — | — | — |
| LIDO | `lido` | ✅ | $355.5998 | wstETH (`0x7f39c581…`) | supply stETH 0.150381 | $355.5998 | price feed | wstETH 0.121897 | $354.1995 |
| Uniswap V3 | `uniswap3` | ✅ | $44.9186 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.001364 + supply ETH 0.015757 + reward WETH 0.000907 + reward ETH 0.000925 | $44.9186 | — | — | — |
| Aave V3 | `aave3` | ✅ | $0.4352 | Lending (`0x87870bca…`) | reward USDS 0.435315 | $0.4352 | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $0.1493 | Farming (`0xc592c33e…`) | supply WETH 0.000000 + supply osETH 0.000000 + reward BAL 0.969753 | $0.1493 | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| HEX | 1,895.0000 | $0.0006 | ❌ | $1.1481 | `0x2b591e99afe9f32eaa6214f7b7629768c40eeb39` | — | — | — | — |
| USDC | 3,043.7273 | $1.0000 | ✅ | $3,043.73 | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 3,043.7273 | $3,043.27 |
| ETH | 24.999996 | $2,370.39 | ✅ | $59,259.74 | `eth` | price feed | wallet / Holding | 24.999996 | $58,883.51 |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | stETH | 0.000000 | $0.0000 |

---

## ACCOUNT_11_MAINNET_COMPOUND_UNISWAP

**Address:** `0x0EFcCBb9E2C09Ea29551879bd9Da32362b32fc89`

### Mainnet (chain 1)

**NAV: $0.0000 | Debank filtered: $6.856M | Drift: -100.00% ⚠️**

#### Debank protocol positions

| Protocol | Debank ID | Covered | Protocol USD | Debank item | Debank position | Item USD | NAV market | NAV position | NAV USD |
|---|---|:---:|---:|---|---|---:|---|---|---:|
| Aave V2 | `aave2` | ✅ | $1.823M | Staked (`0x4da27a54…`) | supply AAVE 19,442.9617 + reward AAVE 0.614491 | $1.823M | — | — | — |
| | | | | Lending (`0x7d2768de…`) | supply BAL 58.491558 | $9.0055 | Aave V2 | supply BAL 58.491558 | $9.0179 |
| StakeWise | `stakewise` | ✅ | $880,673.85 | Rewards (`0x20bc832c…`) | supply ETH 0.000374 | $0.8877 | — | — | — |
| | | | | Lending (`0xac0f906e…`) | supply ETH 371.527015 | $880,663.92 | Stakewise v3 | supply ETH 371.527015 | $875,072.68 |
| | | | | Staked (`0xfe2e6372…`) | supply ETH 0.003813 | $9.0390 | — | — | — |
| Rocket Pool | `rocketpool` | ✅ | $172,807.01 | rETH (`0xae78736c…`) | supply ETH 72.902352 | $172,807.01 | price feed | rETH 62.694486 | $171,709.87 |
| Aave V3 | `aave3` | ✅ | $49,522.36 | Lending (`0x87870bca…`) | supply BAL 320,140.0752 | $49,289.66 | Aave V3 Core | supply BAL 320,140.5676 | $49,357.67 |
| | | | | Wrapped Aave Ethereum Lido GHO (`0xc71ea051…`) | supply GHO 232.956129 | $232.6999 | — | — | — |
| Balancer V2 | `balancer2` | ❌ | $35,693.43 | Liquidity Pool (`0xc5c91aea…`) | supply BAL 92,276.3405 + supply WETH 9.064462 | $35,693.43 | — | — | — |
| Across V2 | `acrocc_v2` | ❌ | $12,792.59 | Liquidity Pool (`0xfacd2ec4…`) | supply BAL 83,088.8503 | $12,792.59 | — | — | — |
| Compound V3 | `compound3` | ✅ | $107.4004 | Lending (`0xc3d688b6…`) | reward COMP 4.437373 | $105.8313 | — | — | — |
| | | | | Yield (`0xc3d688b6…`) | supply USDC 1.569025 | $1.5690 | Compound v3 USDC | supply USDC 1.569038 | $1.5688 |
| Uniswap V3 | `uniswap3` | ✅ | $9.9405 | ETH / sETH2 (`0x7379e812…`) | supply WETH 0.000154 + supply ETH 0.001778 + reward WETH 0.000102 + reward ETH 0.000104 | $5.0708 | Uniswap V3 | supply WETH 0.001972 | $4.6436 |
| | | | | | | | Uniswap V3 | supply WETH 0.000027 | $0.0625 |
| | | | | #418522 (`0xcbcdf962…`) | supply WBTC 0.000000 + supply WETH 0.001972 + reward WBTC 0.000002 + reward WETH 0.000027 | $4.8697 | — | — | — |
| Multichain | `multichain` | ❌ | $3.2585 | anyBAL (`0xcb9d0b8c…`) | supply BAL 21.164100 | $3.2585 | — | — | — |
| Compound | `compound` | ❌ | $2.1152 | Lending (`0x3d981921…`) | supply DAI 1.132199 + supply AAVE 0.010451 + reward COMP 0.000146 | $2.1152 | — | — | — |
| LIDO | `lido` | ✅ | $0.0000 | — | — | — | — | — | — |

#### Debank wallet tokens

| Symbol | Amount | Price | Covered | Debank USD | Address | NAV type | NAV detail | NAV amount | NAV USD |
|---|---:|---:|:---:|---:|---|---|---|---:|---:|
| POL | 91,874.4838 | $0.0978 | ❌ | $8,988.47 | `0x455e53cbb86018ac2b8092fdcd39d8444affc3f6` | — | — | — | — |
| USDC | 3.5520M | $1.0000 | ✅ | $3.552M | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | price feed | wallet / Holding | 3.5520M | $3.551M |
| BAL | 2.4916M | $0.1540 | ✅ | $383,614.16 | `0xba100000625a3754423978a60c9317c58a424e3d` | price feed | wallet / Holding | 2.4916M | $384,142.90 |
| COW | 1.1876M | $0.1752 | ❌ | $208,069.84 | `0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab` | — | — | — | — |

#### NAV positions without Debank counterpart

| NAV type | NAV detail | Asset | NAV amount | NAV USD |
|---|---|---|---:|---:|
| price feed | wallet / Holding | ETH | 0.000041 | $0.0956 |
| price feed | wallet / Holding | stETH | 0.000000 | $0.0000 |

