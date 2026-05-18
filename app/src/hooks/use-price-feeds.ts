'use client'

import { useReadContracts } from 'wagmi'
import { navCalcAbi } from '@/config/abis'
import { AUTOREFRESH_INTERVAL_MS, DEPLOYED_CHAINS, NAV_CALCULATOR_ADDRESS } from '@/config/chains'

export type OnchainAsset = {
  asset: `0x${string}`
  symbol: string
  decimals: number
}

export type PriceFeedInfo = {
  asset: OnchainAsset
  priceFeed: `0x${string}`
  priceType: number
  price: bigint
  decimals: number
  chainlinkHeartbeat: bigint
  updatedAt: bigint
  stale: boolean
  sequencerDown: boolean
}

export type ChainPriceFeeds = {
  chainId: number
  label: string
  assets: OnchainAsset[]
  feeds: PriceFeedInfo[]
  sequencerDown: boolean
  isLoading: boolean
  isError: boolean
}

export function useChainPriceFeeds(chainIdx: number): ChainPriceFeeds {
  const { chain, label } = DEPLOYED_CHAINS[chainIdx]

  const { data: assetsData, isLoading: assetsLoading } = useReadContracts({
    contracts: [
      {
        chainId: chain.id,
        address: NAV_CALCULATOR_ADDRESS,
        abi: navCalcAbi,
        functionName: 'getRegisteredAssets' as const,
      },
      {
        chainId: chain.id,
        address: NAV_CALCULATOR_ADDRESS,
        abi: navCalcAbi,
        functionName: 'healthCheck' as const,
      },
    ],
    query: { refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const assets =
    assetsData?.[0]?.status === 'success'
      ? (assetsData[0].result as readonly OnchainAsset[])
      : []

  const sequencerDown =
    assetsData?.[1]?.status === 'success'
      ? (assetsData[1].result as [boolean, readonly `0x${string}`[]])[0]
      : false

  const priceContracts = assets.map((a) => ({
    chainId: chain.id,
    address: NAV_CALCULATOR_ADDRESS,
    abi: navCalcAbi,
    functionName: 'getPriceData' as const,
    args: [a.asset] as const,
  }))

  const { data: feedsData, isLoading: feedsLoading } = useReadContracts({
    contracts: priceContracts,
    query: { enabled: assets.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const feeds: PriceFeedInfo[] = assets.map((asset, i) => {
    const result = feedsData?.[i]
    if (result?.status !== 'success') {
      return {
        asset,
        priceFeed: '0x0000000000000000000000000000000000000000',
        priceType: 0,
        price: 0n,
        decimals: 8,
        chainlinkHeartbeat: 0n,
        updatedAt: 0n,
        stale: false,
        sequencerDown: false,
      } as PriceFeedInfo
    }
    const r = result.result as {
      priceFeed: `0x${string}`
      priceType: number
      price: bigint
      decimals: number
      chainlinkHeartbeat: bigint
      updatedAt: bigint
      stale: boolean
      sequencerDown: boolean
    }
    return { asset, ...r }
  })

  return {
    chainId: chain.id,
    label,
    assets: [...assets],
    feeds,
    sequencerDown,
    isLoading: assetsLoading || feedsLoading,
    isError: assetsData?.[0]?.status === 'failure',
  }
}
