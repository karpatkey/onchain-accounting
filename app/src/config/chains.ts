import { arbitrum, base, gnosis, mainnet, optimism } from 'viem/chains'

// Set NEXT_PUBLIC_AUTOREFRESH_INTERVAL_MIN to enable background polling (e.g. "5").
// Unset or 0 disables auto-refresh; false is what TanStack Query expects to opt out.
const _min = Number(process.env.NEXT_PUBLIC_AUTOREFRESH_INTERVAL_MIN)
export const AUTOREFRESH_INTERVAL_MS: number | false = _min > 0 ? _min * 60_000 : false

export const EXPLORER_URLS: Record<number, string> = {
  1:     'https://etherscan.io',
  10:    'https://optimistic.etherscan.io',
  100:   'https://gnosisscan.io',
  42161: 'https://arbiscan.io',
  8453:  'https://basescan.org',
}

export function explorerAddressUrl(chainId: number, address: string): string {
  const base = EXPLORER_URLS[chainId]
  return base ? `${base}/address/${address}` : '#'
}

export const NAV_CALCULATOR_ADDRESS =
  '0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19' as const

const TW = 'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains'

export const DEPLOYED_CHAINS = [
  {
    chain: mainnet,
    label: 'Ethereum',
    logoUrl: `${TW}/ethereum/info/logo.png`,
    brandColor: '#627EEA',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_1,
    sequencerFeed: null as `0x${string}` | null,
  },
  {
    chain: optimism,
    label: 'Optimism',
    logoUrl: `${TW}/optimism/info/logo.png`,
    brandColor: '#FF0420',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_10,
    sequencerFeed: '0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389' as `0x${string}`,
  },
  {
    chain: gnosis,
    label: 'Gnosis',
    logoUrl: `${TW}/xdai/info/logo.png`,
    brandColor: '#04795B',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_100,
    sequencerFeed: null as `0x${string}` | null,
  },
  {
    chain: arbitrum,
    label: 'Arbitrum',
    logoUrl: `${TW}/arbitrum/info/logo.png`,
    brandColor: '#12AAFF',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_42161,
    sequencerFeed: '0xFdB631F5EE196F0ed6FAa767959853A9F217697D' as `0x${string}`,
  },
  {
    chain: base,
    label: 'Base',
    logoUrl: `${TW}/base/info/logo.png`,
    brandColor: '#0052FF',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_8453,
    sequencerFeed: '0xBCF85224fc0756B9Fa45aA7892530B47e10b6433' as `0x${string}`,
  },
] as const
