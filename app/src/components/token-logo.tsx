'use client'

import { useState, useEffect } from 'react'
import { getAddress } from 'viem'

// CDN 1: TrustWallet — chain slug + address
const TRUST_CHAIN: Record<number, string> = {
  1:     'ethereum',
  10:    'optimism',
  100:   'xdai',
  42161: 'arbitrum',
  8453:  'base',
}

// CDN 3: symbol map — all URLs verified 200 from server (works in browser too)
// Source: Uniswap + CoinGecko token lists for canonical logoURIs
const CG  = 'https://assets.coingecko.com/coins/images'
const CGI = 'https://coin-images.coingecko.com/coins/images'  // newer CG CDN
const SYMBOL_LOGO: Record<string, string> = {
  // ETH & LSTs
  ETH:      `${CG}/279/large/ethereum.png`,
  WETH:     `${CG}/2518/large/weth.png`,
  wstETH:   `${CG}/18834/large/wstETH.png`,
  stETH:    `${CG}/13442/large/steth_logo.png`,
  rETH:     `${CG}/20764/large/reth.png`,
  cbETH:    `${CG}/27008/large/cbeth.png`,
  weETH:    `${CG}/33033/large/weETH.png`,
  ezETH:    `${CG}/34753/large/Ezeth_logo_circle.png`,
  eETH:     `${CG}/33049/large/ether.fi_eETH.png`,
  rsETH:    `${CG}/33800/large/Icon___Dark.png`,
  ETHx:     `${CG}/30870/large/staderx.png`,
  osETH:    `${CG}/33117/large/Frame_27513839.png`,
  // Stablecoins
  USDC:     `${CG}/6319/large/usdc.png`,
  USDT:     `${CG}/325/large/Tether.png`,
  DAI:      `${CG}/9956/large/Badge_Dai.png`,
  sDAI:     `${CG}/32254/large/sdai.png`,
  USDS:     `${CG}/39926/large/usds.webp`,
  sUSDS:    `${CG}/52721/large/sUSDS_Coin.png`,
  GHO:      `${CG}/30663/large/gho-token-logo.png`,
  crvUSD:   `${CG}/30118/large/crvusd.jpg`,
  LUSD:     `${CG}/14666/large/Group_3.png`,
  FRAX:     `${CG}/13422/large/FRAX_icon.png`,
  USDe:     `${CGI}/33613/large/usde.png`,
  sUSDe:    `${CG}/33669/large/sUSDe-Symbol-Color.png`,
  EURC:     `${CG}/26045/standard/euro.png`,
  RLUSD:    `${CGI}/39651/large/RLUSD_200x200_(1).png`,
  // xDAI & bridged
  xDAI:     `${CG}/11062/large/xdai.png`,
  WXDAI:    `${CG}/11062/large/xdai.png`,
  'USDC.e': `${CG}/6319/large/usdc.png`,
  // BTC
  WBTC:     `${CG}/7598/large/wrapped_bitcoin_wbtc.png`,
  cbBTC:    `${CG}/40143/large/cbbtc.webp`,
  // DeFi governance & yield
  AAVE:     `${CG}/12645/large/AAVE.png`,
  COMP:     `${CG}/10775/large/COMP.png`,
  BAL:      `${CG}/11683/large/Balancer.png`,
  CRV:      `${CG}/12124/large/Curve.png`,
  CVX:      `${CG}/15585/large/convex.png`,
  UNI:      `${CG}/12504/large/uniswap-uni.png`,
  SKY:      `${CG}/53213/large/sky-logo.png`,
  MKR:      `${CG}/1364/large/Mark_Maker.png`,
  GNO:      `${CG}/662/large/logo_square_simple_300px.png`,
  COW:      `${CG}/24384/large/cow.png`,
  LDO:      `${CG}/13573/large/Lido_DAO.png`,
  RPL:      `${CG}/2090/large/rocket_pool_%28RPL%29.png`,
  LINK:     `${CG}/877/large/chainlink-new-logo.png`,
  MORPHO:   `${CGI}/29837/large/Morpho-token-icon.png`,
  AURA:     `${CGI}/38376/large/aura_logo_200x200-01-01.png`,
  GEAR:     `${CG}/21630/large/gear.png`,
  'ETH+':   `${CG}/38061/large/ETH__Logo.png`,
  syrupUSDC:`${CG}/54658/large/syrupUSDC.png`,
  // Chain tokens
  OP:       `${CG}/25244/large/Optimism.png`,
  ARB:      `${CG}/16547/large/photo_2023-03-29_18.13.09.jpeg`,
}

// Consistent hashed colour for fallback monograms (P2 item 9)
const FALLBACK_COLORS = [
  'bg-blue-100 text-blue-800',
  'bg-violet-100 text-violet-800',
  'bg-emerald-100 text-emerald-800',
  'bg-amber-100 text-amber-800',
  'bg-rose-100 text-rose-800',
  'bg-cyan-100 text-cyan-800',
  'bg-orange-100 text-orange-800',
  'bg-indigo-100 text-indigo-800',
]
function symbolColor(symbol: string): string {
  let h = 0
  for (const c of symbol) h = (h * 31 + c.charCodeAt(0)) & 0xff
  return FALLBACK_COLORS[h % FALLBACK_COLORS.length]
}

const ZERO = '0x0000000000000000000000000000000000000000'

function cs(address: string): string | null {
  try { return getAddress(address) } catch { return null }
}

function buildUrls(chainId: number | undefined, address: string, symbol: string): string[] {
  // Known symbols use their canonical logo across all chains — guarantees visual consistency.
  // Address-based CDNs can serve different images for the same token on different chains
  // (e.g. TrustWallet stores the ETH logo for WETH on OP/Base).
  const canonical = SYMBOL_LOGO[symbol] ?? SYMBOL_LOGO[symbol.toUpperCase()]
  if (canonical) return [canonical]

  // Unknown token — fall back to address-based CDNs
  const urls: string[] = []
  if (chainId && address !== ZERO) {
    const addr = cs(address)
    if (addr) {
      const chain = TRUST_CHAIN[chainId]
      if (chain) urls.push(`https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/${chain}/assets/${addr}/logo.png`)
      urls.push(`https://raw.githubusercontent.com/SmolDapp/tokenAssets/main/tokens/${chainId}/${addr}/logo.svg`)
    }
  }
  return urls
}

interface TokenLogoProps {
  symbol: string
  address: string
  chainId?: number
  className?: string
}

export function TokenLogo({ symbol, address, chainId, className = 'w-5 h-5' }: TokenLogoProps) {
  const [urlIndex, setUrlIndex] = useState(0)

  useEffect(() => { setUrlIndex(0) }, [address, chainId])

  const urls = buildUrls(chainId, address, symbol)
  const currentUrl = urls[urlIndex]

  if (currentUrl) {
    return (
      <img
        src={currentUrl}
        alt={symbol}
        className={`${className} rounded-full object-cover shrink-0`}
        onError={() => setUrlIndex((i) => i + 1)}
      />
    )
  }

  return (
    <div className={`${className} rounded-full flex items-center justify-center text-[9px] font-semibold shrink-0 ${symbolColor(symbol)}`}>
      {symbol.slice(0, 2).toUpperCase()}
    </div>
  )
}
