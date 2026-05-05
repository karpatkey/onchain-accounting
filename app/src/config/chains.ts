import { arbitrum, base, gnosis, mainnet, optimism } from 'viem/chains'

export const NAV_CALCULATOR_ADDRESS =
  '0x07938ddDfACa63679c4d3F1d80BBe6aB1a6aEB19' as const

export const DEPLOYED_CHAINS = [
  {
    chain: mainnet,
    label: 'Ethereum',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_1,
    sequencerFeed: null as `0x${string}` | null,
  },
  {
    chain: optimism,
    label: 'Optimism',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_10,
    sequencerFeed: '0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389' as `0x${string}`,
  },
  {
    chain: gnosis,
    label: 'Gnosis',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_100,
    sequencerFeed: null as `0x${string}` | null,
  },
  {
    chain: arbitrum,
    label: 'Arbitrum',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_42161,
    sequencerFeed: '0xFdB631F5EE196F0ed6FAa767959853A9F217697D' as `0x${string}`,
  },
  {
    chain: base,
    label: 'Base',
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_8453,
    sequencerFeed: '0xBCF85224fc0756B9Fa45aA7892530B47e10b6433' as `0x${string}`,
  },
] as const
