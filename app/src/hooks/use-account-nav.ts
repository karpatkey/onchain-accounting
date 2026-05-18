'use client'

import { useReadContracts } from 'wagmi'
import { zeroAddress } from 'viem'
import { navCalcAbi } from '@/config/abis'
import { AUTOREFRESH_INTERVAL_MS, DEPLOYED_CHAINS, NAV_CALCULATOR_ADDRESS } from '@/config/chains'

export type ChainNav = {
  chainId: number
  label: string
  nav: {
    value: bigint
    quoteAsset: { asset: `0x${string}`; symbol: string; decimals: number }
    timestamp: bigint
    stalePriceAssets: readonly { asset: `0x${string}`; symbol: string; decimals: number }[]
    sequencerDown: boolean
  } | null
  isLoading: boolean
  isError: boolean
}

export function useAccountNav(account: `0x${string}` | undefined): { chains: ChainNav[]; refetch: () => void } {
  const contracts = DEPLOYED_CHAINS.map(({ chain }) => ({
    chainId: chain.id,
    address: NAV_CALCULATOR_ADDRESS,
    abi: navCalcAbi,
    functionName: 'getAccountNav' as const,
    args: [account ?? zeroAddress, zeroAddress] as const,
  }))

  const { data, isLoading, refetch } = useReadContracts({
    contracts,
    query: { enabled: !!account, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const chains = DEPLOYED_CHAINS.map(({ chain, label }, i) => {
    const result = data?.[i]
    return {
      chainId: chain.id,
      label,
      nav: result?.status === 'success' ? (result.result as ChainNav['nav']) : null,
      isLoading,
      isError: result?.status === 'failure',
    }
  })

  return { chains, refetch: () => { void refetch() } }
}
