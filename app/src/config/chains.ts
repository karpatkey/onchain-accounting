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
  // encodeURIComponent the address: it originates as user/URL text, so escape meta-characters before it
  // becomes part of an href (neutralises the CodeQL js/xss-through-dom flow; base is a constant https URL).
  return base ? `${base}/address/${encodeURIComponent(address)}` : '#'
}

// Production CREATE2 deployment address (same on every chain).
// Overrides:
//   - NEXT_PUBLIC_NAV_ADDRESS (global)            — applied to every chain
//   - NEXT_PUBLIC_NAV_ADDRESS_<chainId> (per-chain) — wins over the global one
// Per-chain overrides exist because dev forks deploy via plain CREATE (not CREATE2), so the
// proxy addresses diverge per chain depending on the deployer EOA's nonce on each fork.
//
// IMPORTANT: there is no global `NAV_CALCULATOR_ADDRESS` export. Use `DEPLOYED_CHAINS[i].navAddress`
// or `lookupNavAddress(chainId)` below. A global would silently target the wrong proxy on dev
// forks where per-chain addresses diverge.
const DEFAULT_NAV_ADDRESS = '0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19' as const
const GLOBAL_NAV_OVERRIDE = process.env.NEXT_PUBLIC_NAV_ADDRESS || ''

function resolveNavAddress(chainId: number): `0x${string}` {
  const perChain = {
    1:     process.env.NEXT_PUBLIC_NAV_ADDRESS_1,
    10:    process.env.NEXT_PUBLIC_NAV_ADDRESS_10,
    100:   process.env.NEXT_PUBLIC_NAV_ADDRESS_100,
    42161: process.env.NEXT_PUBLIC_NAV_ADDRESS_42161,
    8453:  process.env.NEXT_PUBLIC_NAV_ADDRESS_8453,
  }[chainId]
  return (perChain || GLOBAL_NAV_OVERRIDE || DEFAULT_NAV_ADDRESS) as `0x${string}`
}

const TW = 'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains'

export const DEPLOYED_CHAINS = [
  {
    chain: mainnet,
    label: 'Ethereum',
    logoUrl: `${TW}/ethereum/info/logo.png`,
    brandColor: '#627EEA',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_1,
    sequencerFeed: null as `0x${string}` | null,
    navAddress: resolveNavAddress(1),
  },
  {
    chain: optimism,
    label: 'Optimism',
    logoUrl: `${TW}/optimism/info/logo.png`,
    brandColor: '#FF0420',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_10,
    sequencerFeed: '0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389' as `0x${string}`,
    navAddress: resolveNavAddress(10),
  },
  {
    chain: gnosis,
    label: 'Gnosis',
    logoUrl: `${TW}/xdai/info/logo.png`,
    brandColor: '#04795B',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_100,
    sequencerFeed: null as `0x${string}` | null,
    navAddress: resolveNavAddress(100),
  },
  {
    chain: arbitrum,
    label: 'Arbitrum',
    logoUrl: `${TW}/arbitrum/info/logo.png`,
    brandColor: '#12AAFF',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_42161,
    sequencerFeed: '0xFdB631F5EE196F0ed6FAa767959853A9F217697D' as `0x${string}`,
    navAddress: resolveNavAddress(42161),
  },
  {
    chain: base,
    label: 'Base',
    logoUrl: `${TW}/base/info/logo.png`,
    brandColor: '#0052FF',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_8453,
    sequencerFeed: '0xBCF85224fc0756B9Fa45aA7892530B47e10b6433' as `0x${string}`,
    navAddress: resolveNavAddress(8453),
  },
] as const

/// Per-chain NAV proxy lookup. Prefer this over a global constant — see the comment above
/// `resolveNavAddress` for why per-chain matters on dev forks.
/// Returns the production CREATE2 address if the chainId is not in DEPLOYED_CHAINS.
export function lookupNavAddress(chainId: number): `0x${string}` {
  return resolveNavAddress(chainId)
}
