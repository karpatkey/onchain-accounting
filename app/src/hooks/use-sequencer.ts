'use client'

import { useReadContracts } from 'wagmi'
import { aggregatorV3Abi, navCalcAbi } from '@/config/abis'
import { lookupNavAddress } from '@/config/chains'

export type SequencerData = {
  chainId: number
  feedAddress: `0x${string}`
  isDown: boolean
  isInGracePeriod: boolean
  answer: bigint
  startedAt: bigint
  updatedAt: bigint
  gracePeriod: bigint
  isLoading: boolean
}

export function useSequencer(
  chainId: number,
  feedAddress: `0x${string}` | null,
): SequencerData | null {
  const { data, isLoading } = useReadContracts({
    contracts: feedAddress
      ? [
          {
            chainId,
            address: feedAddress,
            abi: aggregatorV3Abi,
            functionName: 'latestRoundData' as const,
          },
          {
            chainId,
            address: lookupNavAddress(chainId),
            abi: navCalcAbi,
            functionName: 'chainlinkL2SequencerGracePeriod' as const,
          },
        ]
      : [],
    query: { enabled: !!feedAddress },
  })

  if (!feedAddress) return null

  const roundData = data?.[0]?.status === 'success'
    ? (data[0].result as [bigint, bigint, bigint, bigint, bigint])
    : null

  const gracePeriod = data?.[1]?.status === 'success'
    ? (data[1].result as bigint)
    : 3600n

  const answer = roundData?.[1] ?? 0n
  const startedAt = roundData?.[2] ?? 0n
  const updatedAt = roundData?.[3] ?? 0n

  const isDown = answer !== 0n
  const nowSec = BigInt(Math.floor(Date.now() / 1000))
  const isInGracePeriod = !isDown && startedAt > 0n && (nowSec - startedAt) < gracePeriod

  return {
    chainId,
    feedAddress,
    isDown,
    isInGracePeriod,
    answer,
    startedAt,
    updatedAt,
    gracePeriod,
    isLoading,
  }
}
