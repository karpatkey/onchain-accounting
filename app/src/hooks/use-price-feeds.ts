'use client'

import { useReadContracts } from 'wagmi'
import { navCalcAbi, aggregatorV3Abi } from '@/config/abis'
import { AUTOREFRESH_INTERVAL_MS, DEPLOYED_CHAINS } from '@/config/chains'

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const

export type OnchainAsset = {
  asset: `0x${string}`
  symbol: string
  decimals: number
}

// One configured price feed for an asset (a leaf in the redundancy tree). Coordinates come
// from the on-chain PriceFeedConfig; the live price/updatedAt are read directly from the feed
// via latestRoundData(). Fail-open: a feed that reverts leaves `available: false`.
export type FeedNode = {
  priceFeed: `0x${string}`
  priceType: number
  decimals: number
  chainlinkHeartbeat: bigint
  price: bigint
  updatedAt: bigint
  stale: boolean
  available: boolean
  isWinner: boolean
}

// One asset with the full set of its configured feeds (the redundancy tree node).
export type AssetFeedNode = {
  asset: OnchainAsset
  winner: {
    priceFeed: `0x${string}`
    price: bigint
    priceType: number
    decimals: number
    stale: boolean
  }
  healthyFeedCount: number
  totalFeeds: number
  feeds: FeedNode[]
  sequencerDown: boolean
}

// Retained flat winner-feed shape (one row per asset) — preserved for the chain health pills
// and section issue counts that summarise per-chain feed health.
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
  nodes: AssetFeedNode[]
  sequencerDown: boolean
  isLoading: boolean
  isError: boolean
}

type WinnerData = {
  priceFeed: `0x${string}`
  priceType: number
  price: bigint
  decimals: number
  chainlinkHeartbeat: bigint
  updatedAt: bigint
  stale: boolean
  sequencerDown: boolean
  healthyFeedCount: bigint
}

type ConfigData = {
  priceFeed: `0x${string}`
  decimals: number
  priceType: bigint
  chainlinkHeartbeat: bigint
}

// Per-feed staleness mirrors the contract's heartbeat gate: updatedAt == 0 is the
// ICustomPriceFeed "live on-chain rate" sentinel (never heartbeat-stale); otherwise a feed
// is stale when its age exceeds its heartbeat window.
function isFeedStale(updatedAt: bigint, heartbeat: bigint): boolean {
  if (updatedAt === 0n) return false
  if (heartbeat === 0n) return false
  const now = BigInt(Math.floor(Date.now() / 1000))
  return now - updatedAt > heartbeat
}

export function useChainPriceFeeds(chainIdx: number): ChainPriceFeeds {
  const { chain, label, navAddress } = DEPLOYED_CHAINS[chainIdx]

  const { data: assetsData, isLoading: assetsLoading } = useReadContracts({
    contracts: [
      {
        chainId: chain.id,
        address: navAddress,
        abi: navCalcAbi,
        functionName: 'getRegisteredAssets' as const,
      },
      {
        chainId: chain.id,
        address: navAddress,
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

  // Per asset: the winning feed (getPriceData) and the full configured set (getPriceFeeds).
  const perAssetContracts = assets.flatMap((a) => [
    {
      chainId: chain.id,
      address: navAddress,
      abi: navCalcAbi,
      functionName: 'getPriceData' as const,
      args: [a.asset] as const,
    },
    {
      chainId: chain.id,
      address: navAddress,
      abi: navCalcAbi,
      functionName: 'getPriceFeeds' as const,
      args: [a.asset] as const,
    },
  ])

  const { data: perAssetData, isLoading: perAssetLoading } = useReadContracts({
    contracts: perAssetContracts,
    query: { enabled: assets.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Decode winner + configs per asset (2 calls each, interleaved). wagmi infers a union across
  // the mixed multicall, so cast each result through `unknown` to its concrete shape.
  const winners: (WinnerData | null)[] = assets.map((_, i) => {
    const r = perAssetData?.[i * 2]
    return r?.status === 'success' ? (r.result as unknown as WinnerData) : null
  })
  const configsPerAsset: ConfigData[][] = assets.map((_, i) => {
    const r = perAssetData?.[i * 2 + 1]
    return r?.status === 'success' ? ([...(r.result as unknown as readonly ConfigData[])]) : []
  })

  // Flatten every feed address across all assets into one latestRoundData() multicall.
  type FeedRef = { assetIdx: number; cfg: ConfigData }
  const feedRefs: FeedRef[] = configsPerAsset.flatMap((cfgs, assetIdx) =>
    cfgs.map((cfg) => ({ assetIdx, cfg })),
  )

  const feedReadContracts = feedRefs.map((ref) => ({
    chainId: chain.id,
    address: ref.cfg.priceFeed,
    abi: aggregatorV3Abi,
    functionName: 'latestRoundData' as const,
  }))

  const { data: feedReadData, isLoading: feedReadLoading } = useReadContracts({
    contracts: feedReadContracts,
    query: { enabled: feedRefs.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Per-feed live results, grouped back per asset.
  const feedNodesPerAsset: FeedNode[][] = assets.map(() => [])
  feedRefs.forEach((ref, i) => {
    const cfg = ref.cfg
    const heartbeat = cfg.chainlinkHeartbeat
    const result = feedReadData?.[i]

    let price = 0n
    let updatedAt = 0n
    let available = false
    if (result?.status === 'success') {
      // latestRoundData: [roundId, answer, startedAt, updatedAt, answeredInRound]
      const tuple = result.result as readonly [bigint, bigint, bigint, bigint, bigint]
      price = tuple[1]
      updatedAt = tuple[3]
      available = true
    }

    const winner = winners[ref.assetIdx]
    const isWinner =
      winner != null && winner.priceFeed.toLowerCase() === cfg.priceFeed.toLowerCase()

    feedNodesPerAsset[ref.assetIdx].push({
      priceFeed: cfg.priceFeed,
      priceType: Number(cfg.priceType),
      decimals: Number(cfg.decimals),
      chainlinkHeartbeat: heartbeat,
      price,
      updatedAt,
      stale: available ? isFeedStale(updatedAt, heartbeat) : false,
      available,
      isWinner,
    })
  })

  const nodes: AssetFeedNode[] = assets.map((asset, i) => {
    const winner = winners[i]
    const feedNodes = feedNodesPerAsset[i]
    return {
      asset,
      winner: {
        priceFeed: winner?.priceFeed ?? ZERO_ADDRESS,
        price: winner?.price ?? 0n,
        priceType: winner ? Number(winner.priceType) : 0,
        decimals: winner ? Number(winner.decimals) : 8,
        stale: winner?.stale ?? false,
      },
      healthyFeedCount: winner ? Number(winner.healthyFeedCount) : 0,
      totalFeeds: feedNodes.length,
      feeds: feedNodes,
      sequencerDown,
    }
  })

  // Flat winner-feed rows (for health pills / issue counts).
  const feeds: PriceFeedInfo[] = assets.map((asset, i) => {
    const winner = winners[i]
    if (!winner) {
      return {
        asset,
        priceFeed: ZERO_ADDRESS,
        priceType: 0,
        price: 0n,
        decimals: 8,
        chainlinkHeartbeat: 0n,
        updatedAt: 0n,
        stale: false,
        sequencerDown: false,
      }
    }
    return {
      asset,
      priceFeed: winner.priceFeed,
      priceType: Number(winner.priceType),
      price: winner.price,
      decimals: Number(winner.decimals),
      chainlinkHeartbeat: winner.chainlinkHeartbeat,
      updatedAt: winner.updatedAt,
      stale: winner.stale,
      sequencerDown: winner.sequencerDown,
    }
  })

  return {
    chainId: chain.id,
    label,
    assets: [...assets],
    feeds,
    nodes,
    sequencerDown,
    isLoading: assetsLoading || perAssetLoading || feedReadLoading,
    isError: assetsData?.[0]?.status === 'failure',
  }
}
