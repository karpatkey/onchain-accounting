'use client'

import { useReadContracts } from 'wagmi'
import { zeroAddress } from 'viem'
import { navCalcAbi } from '@/config/abis'
import { AUTOREFRESH_INTERVAL_MS, DEPLOYED_CHAINS } from '@/config/chains'

export type OnchainPosition = {
  underlyingAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  balanceOracle: `0x${string}`
  amount: bigint
  isDebt: boolean
  quoteAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  value: bigint
  price: bigint
  priceDecimals: number
  stale: boolean
  protocol: string
  positionDetail: string
}

export type ChainPositions = {
  chainId: number
  label: string
  positions: readonly OnchainPosition[]
  isLoading: boolean
  isError: boolean
}

export function useAccountPositions(account: `0x${string}` | undefined): { chains: ChainPositions[]; refetch: () => void } {
  const contracts = DEPLOYED_CHAINS.map(({ chain, navAddress }) => ({
    chainId: chain.id,
    address: navAddress,
    abi: navCalcAbi,
    functionName: 'getAccountPositions' as const,
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
      positions:
        result?.status === 'success'
          ? (result.result as readonly OnchainPosition[])
          : [],
      isLoading,
      isError: result?.status === 'failure',
    }
  })

  return { chains, refetch: () => { void refetch() } }
}
