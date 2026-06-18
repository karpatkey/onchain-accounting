# Oracle Heartbeat Verification

Chainlink publishes a reference data directory that exposes every feed's `heartbeat`, `proxyAddress`, and `contractAddress` (the underlying aggregator) in one JSON per network.

## URL format

```
https://reference-data-directory.vercel.app/feeds-{network}.json?proxyAddress={address}
```

The `?proxyAddress=` query parameter filters the result to the single entry matching that proxy address. It works as client-side filtering in a browser; programmatic HTTP clients receive the full unfiltered JSON.

## Network identifiers

| Chain | Chain ID | Network slug |
|---|---|---|
| Ethereum Mainnet | 1 | `mainnet` |
| Arbitrum | 42161 | `ethereum-mainnet-arbitrum-1` |
| Base | 8453 | `ethereum-mainnet-base-1` |
| Optimism | 10 | `ethereum-mainnet-optimism-1` |
| Gnosis | 100 | `xdai-mainnet` |

## Key fields in the response

```jsonc
{
  "name": "USDC / USD",
  "proxyAddress": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6", // recorded as an asset's priceFeeds[].address in nav-config/assets-and-price-feeds/<chainId>.json
  "contractAddress": "0x...",                                    // underlying OCR2 aggregator
  "heartbeat": 86400,                                            // seconds
  "threshold": 0.25,                                             // deviation % that also triggers update
  "ens": "usdc-usd",
  "feedCategory": "low",
  "docs": { ... }
}
```

> **Note:** `contractAddress` is the OCR2 aggregator (implementation). Consumer contracts — and an asset's `priceFeeds[].address` in `nav-config/assets-and-price-feeds/<chainId>.json` — should always use `proxyAddress`.

## Example links for feeds in nav-config/assets-and-price-feeds/<chainId>.json

### Ethereum Mainnet

| Feed | Link |
|---|---|
| ETH/USD | [feeds-mainnet.json?proxyAddress=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419) |
| USDC/USD | [feeds-mainnet.json?proxyAddress=0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6) |
| USDe/USD | [feeds-mainnet.json?proxyAddress=0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961) |
| USDT/USD | [feeds-mainnet.json?proxyAddress=0x3E7d1eAB13ad0104d2750B8863b489D65364e32D](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x3E7d1eAB13ad0104d2750B8863b489D65364e32D) |
| DAI/USD | [feeds-mainnet.json?proxyAddress=0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9) |
| stETH/ETH | [feeds-mainnet.json?proxyAddress=0x86392dC19c0b719886221c78AB11eb8Cf5c52812](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x86392dC19c0b719886221c78AB11eb8Cf5c52812) |
| weETH/ETH | [feeds-mainnet.json?proxyAddress=0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22) |
| USDS/USD | [feeds-mainnet.json?proxyAddress=0xfF30586cD0F29eD462364C7e81375FC0C71219b1](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xfF30586cD0F29eD462364C7e81375FC0C71219b1) |
| GHO/USD | [feeds-mainnet.json?proxyAddress=0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC) |
| BAL/USD | [feeds-mainnet.json?proxyAddress=0xdF2917806E30300537aEB49A7663062F4d1F2b5F](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xdF2917806E30300537aEB49A7663062F4d1F2b5F) |
| RPL/USD | [feeds-mainnet.json?proxyAddress=0x4E155eD98aFE9034b7A5962f6C84c86d869daA9d](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x4E155eD98aFE9034b7A5962f6C84c86d869daA9d) |
| CRV/USD | [feeds-mainnet.json?proxyAddress=0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f) |
| CVX/USD | [feeds-mainnet.json?proxyAddress=0xd962fC30A72A84cE50161031391756Bf2876Af5D](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xd962fC30A72A84cE50161031391756Bf2876Af5D) |
| crvUSD/USD | [feeds-mainnet.json?proxyAddress=0xEEf0C605546958c1f899b6fB336C20671f9cD49F](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xEEf0C605546958c1f899b6fB336C20671f9cD49F) |
| RLUSD/USD | [feeds-mainnet.json?proxyAddress=0x26C46B7aD0012cA71F2298ada567dC9Af14E7f2A](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x26C46B7aD0012cA71F2298ada567dC9Af14E7f2A) |
| ETH+/USD | [feeds-mainnet.json?proxyAddress=0x66Ab900341C98de949EC31d11b3C4180743844F1](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x66Ab900341C98de949EC31d11b3C4180743844F1) |
| EURC/USD | [feeds-mainnet.json?proxyAddress=0x04F84020Fdf10d9ee64D1dcC2986EDF2F556DA11](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0x04F84020Fdf10d9ee64D1dcC2986EDF2F556DA11) |
| COMP/USD | [feeds-mainnet.json?proxyAddress=0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5](https://reference-data-directory.vercel.app/feeds-mainnet.json?proxyAddress=0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5) |

### Arbitrum (42161)

| Feed | Link |
|---|---|
| ETH/USD | [feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612) |
| USDC/USD | [feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3) |
| USDT/USD | [feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7) |
| GHO/USD | [feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x3c786e934F23375Ca345C9b8D5aD54838796E8e7](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x3c786e934F23375Ca345C9b8D5aD54838796E8e7) |
| wstETH/ETH | [feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0xb523AE262D20A936BC152e6023996e46FDC2A95D](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0xb523AE262D20A936BC152e6023996e46FDC2A95D) |
| weETH/eETH | [feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x20bAe7e1De9c596f5F7615aeaa1342Ba99294e12](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x20bAe7e1De9c596f5F7615aeaa1342Ba99294e12) |
| rsETH/ETH exch. rate | [feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x3A917e6B5732dFCc4A45257e3930979fAE6a3737](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json?proxyAddress=0x3A917e6B5732dFCc4A45257e3930979fAE6a3737) |

### Base (8453)

| Feed | Link |
|---|---|
| ETH/USD | [feeds-ethereum-mainnet-base-1.json?proxyAddress=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json?proxyAddress=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70) |
| USDC/USD | [feeds-ethereum-mainnet-base-1.json?proxyAddress=0x7e860098F58bBFC8648a4311b374B1D669a2bc6B](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json?proxyAddress=0x7e860098F58bBFC8648a4311b374B1D669a2bc6B) |
| GHO/USD | [feeds-ethereum-mainnet-base-1.json?proxyAddress=0x42868EFcee13C0E71af89c04fF7d96f5bec479b0](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json?proxyAddress=0x42868EFcee13C0E71af89c04fF7d96f5bec479b0) |
| MORPHO/USD | [feeds-ethereum-mainnet-base-1.json?proxyAddress=0xe95e258bb6615d47515Fc849f8542dA651f12bF6](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json?proxyAddress=0xe95e258bb6615d47515Fc849f8542dA651f12bF6) |
| wstETH/ETH | [feeds-ethereum-mainnet-base-1.json?proxyAddress=0x43a5C292A453A3bF3606fa856197f09D7B74251a](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json?proxyAddress=0x43a5C292A453A3bF3606fa856197f09D7B74251a) |
| weETH/eETH | [feeds-ethereum-mainnet-base-1.json?proxyAddress=0x35e9D7001819Ea3B39Da906aE6b06A62cfe2c181](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json?proxyAddress=0x35e9D7001819Ea3B39Da906aE6b06A62cfe2c181) |
| cbETH/ETH | [feeds-ethereum-mainnet-base-1.json?proxyAddress=0x806b4Ac04501c29769051e42783cF04dCE41440b](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json?proxyAddress=0x806b4Ac04501c29769051e42783cF04dCE41440b) |

### Optimism (10)

| Feed | Link |
|---|---|
| ETH/USD | [feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0x13e3Ee699D1909E989722E753853AE30b17e08c5](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0x13e3Ee699D1909E989722E753853AE30b17e08c5) |
| USDC/USD | [feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3) |
| USDT/USD | [feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0xECef79E109e997bCA29c1c0897ec9d7b03647F5E](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0xECef79E109e997bCA29c1c0897ec9d7b03647F5E) |
| wstETH/USD | [feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0x698B585CbC4407e2D54aa898B2600B53C68958f7](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-optimism-1.json?proxyAddress=0x698B585CbC4407e2D54aa898B2600B53C68958f7) |

### Gnosis (100)

| Feed | Link |
|---|---|
| xDAI/USD | [feeds-xdai-mainnet.json?proxyAddress=0x678df3415fc31947dA4324eC63212874be5a82f8](https://reference-data-directory.vercel.app/feeds-xdai-mainnet.json?proxyAddress=0x678df3415fc31947dA4324eC63212874be5a82f8) |
| WETH/USD | [feeds-xdai-mainnet.json?proxyAddress=0xa767f745331D267c7751297D982b050c93985627](https://reference-data-directory.vercel.app/feeds-xdai-mainnet.json?proxyAddress=0xa767f745331D267c7751297D982b050c93985627) |
| GHO/USD | [feeds-xdai-mainnet.json?proxyAddress=0x855193775eF2ABb12CF95DE3086229a14Ab8E0E3](https://reference-data-directory.vercel.app/feeds-xdai-mainnet.json?proxyAddress=0x855193775eF2ABb12CF95DE3086229a14Ab8E0E3) |
| USDCe/USD | [feeds-xdai-mainnet.json?proxyAddress=0x26C31ac71010aF62E6B486D1132E266D6298857D](https://reference-data-directory.vercel.app/feeds-xdai-mainnet.json?proxyAddress=0x26C31ac71010aF62E6B486D1132E266D6298857D) |
| wstETH/ETH | [feeds-xdai-mainnet.json?proxyAddress=0x0064AC007fF665CF8D0D3Af5E0AD1c26a3f853eA](https://reference-data-directory.vercel.app/feeds-xdai-mainnet.json?proxyAddress=0x0064AC007fF665CF8D0D3Af5E0AD1c26a3f853eA) |
