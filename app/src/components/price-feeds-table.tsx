'use client'

import { useState } from 'react'
import {
  Table,
  THead,
  TBody,
  Tr,
  Th,
  Td,
  Badge,
  Launch,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  Skeleton,
} from '@karpatkey/design-system'
import type { ChainPriceFeeds, PriceFeedInfo } from '@/hooks/use-price-feeds'
import { TokenLogo } from '@/components/token-logo'
import { formatAge, formatHeartbeat, formatPrice, isStaleWarning } from '@/lib/format'
import { CopyableAddress } from '@/components/copyable-address'
import { explorerAddressUrl } from '@/config/chains'

// Indices match the Solidity IPrices.PriceType enum: Chainlink=0, Redstone=1, API3=2, Custom=3.
const PRICE_TYPES = ['Chainlink', 'Redstone', 'API3', 'Custom'] as const
// Only Custom (IPriceFeedCustom) feeds use the updatedAt==0 "Live" sentinel.
const PRICE_TYPE_CUSTOM = 3

export type FilterStatus = 'all' | 'fresh' | 'warning'
type SortKey = 'asset' | 'price' | 'heartbeat' | 'lastUpdated' | 'status'
type SortDir = 'asc' | 'desc'

function statusScore(feed: PriceFeedInfo): number {
  if (feed.sequencerDown || feed.stale) return 2
  if (isStaleWarning(feed.updatedAt, feed.chainlinkHeartbeat)) return 1
  return 0
}

function sortFeeds(feeds: PriceFeedInfo[], key: SortKey | null, dir: SortDir): PriceFeedInfo[] {
  if (!key) return feeds
  return [...feeds].sort((a, b) => {
    let d = 0
    switch (key) {
      case 'asset':       d = a.asset.symbol.localeCompare(b.asset.symbol); break
      case 'price':       d = a.price > b.price ? 1 : a.price < b.price ? -1 : 0; break
      case 'heartbeat':   d = a.chainlinkHeartbeat > b.chainlinkHeartbeat ? 1 : a.chainlinkHeartbeat < b.chainlinkHeartbeat ? -1 : 0; break
      case 'lastUpdated': d = a.updatedAt > b.updatedAt ? -1 : a.updatedAt < b.updatedAt ? 1 : 0; break
      case 'status':      d = statusScore(b) - statusScore(a); break
    }
    return dir === 'asc' ? d : -d
  })
}

function applyFilter(feeds: PriceFeedInfo[], filter: FilterStatus): PriceFeedInfo[] {
  if (filter === 'all') return feeds
  return feeds.filter((f) => {
    const hasIssue = f.stale || f.sequencerDown || isStaleWarning(f.updatedAt, f.chainlinkHeartbeat)
    return filter === 'warning' ? hasIssue : !hasIssue
  })
}

function applySearch(feeds: PriceFeedInfo[], query: string): PriceFeedInfo[] {
  if (!query.trim()) return feeds
  const q = query.trim().toLowerCase()
  return feeds.filter((f) => f.asset.symbol.toLowerCase().includes(q))
}

function FeedStatusBadge({ feed }: { feed: PriceFeedInfo }) {
  if (feed.sequencerDown) return <Badge variant="negative">Seq Down</Badge>
  if (feed.stale) return <Badge variant="negative">Stale</Badge>
  if (isStaleWarning(feed.updatedAt, feed.chainlinkHeartbeat)) {
    const ageSec = Number(BigInt(Math.floor(Date.now() / 1000)) - feed.updatedAt)
    const heartSec = Number(feed.chainlinkHeartbeat)
    const pct = heartSec > 0 ? Math.round((ageSec / heartSec) * 100) : 0
    const tip = `Last updated ${formatAge(feed.updatedAt)}, at ${pct}% of the ${formatHeartbeat(feed.chainlinkHeartbeat)} heartbeat threshold.`
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <Badge variant="generic" className="bg-amber-500 hover:bg-amber-600 text-white cursor-default">Warning</Badge>
        </TooltipTrigger>
        <TooltipContent>{tip}</TooltipContent>
      </Tooltip>
    )
  }
  return <Badge variant="positive">Fresh</Badge>
}

function SortTh({
  children,
  sortKey: key,
  currentKey,
  currentDir,
  onSort,
  align = 'left',
}: {
  children: React.ReactNode
  sortKey: SortKey
  currentKey: SortKey | null
  currentDir: SortDir
  onSort: (k: SortKey) => void
  align?: 'left' | 'right' | 'center'
}) {
  const isActive = currentKey === key
  const justifyClass = align === 'right' ? 'justify-end' : align === 'center' ? 'justify-center' : 'justify-start'
  const thClass = align === 'right' ? 'text-right' : align === 'center' ? 'text-center' : ''
  return (
    <Th className={thClass}>
      <button
        type="button"
        onClick={() => onSort(key)}
        className={`inline-flex items-center gap-1 ${justifyClass} w-full bg-transparent border-0 p-0 cursor-pointer select-none hover:text-neutral-950 font-[inherit] text-[inherit]`}
      >
        {children}
        <span className={`text-[10px] ${isActive ? 'text-neutral-700' : 'text-neutral-500'}`}>
          {isActive ? (currentDir === 'asc' ? '↑' : '↓') : '↕'}
        </span>
      </button>
    </Th>
  )
}

// Custom feeds: heartbeat and updatedAt are the worst-case across the feed's underlying
// oracle(s) per IPriceFeedCustom.latestRoundData() convention. updatedAt == 0 is the
// documented sentinel for "no trackable oracle dependency" (live on-chain rate) — see ADR 0010.
const CUSTOM_LIVE_TIP = 'Live on-chain rate — no external oracle dependency.'

interface PriceFeedsTableProps {
  data: ChainPriceFeeds
  dense?: boolean
  filterStatus?: FilterStatus
  searchQuery?: string
}

export function PriceFeedsTable({ data, dense = false, filterStatus = 'all', searchQuery = '' }: PriceFeedsTableProps) {
  const { feeds, isLoading, isError, chainId } = data
  const [sortKey, setSortKey] = useState<SortKey | null>(null)
  const [sortDir, setSortDir] = useState<SortDir>('asc')

  function handleSort(key: SortKey) {
    if (sortKey === key) setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))
    else { setSortKey(key); setSortDir('asc') }
  }

  if (isLoading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 5 }).map((_, i) => (
          <Skeleton key={i} className="h-10 w-full" />
        ))}
      </div>
    )
  }

  if (isError) return <p className="text-sm text-destructive py-4">Failed to load price feeds.</p>
  if (feeds.length === 0) return <p className="text-sm text-neutral-700 py-4">No registered assets found.</p>

  // Build a map of priceFeed address → symbols that share it (for same-feed tooltip)
  const sharedFeedMap = new Map<string, string[]>()
  for (const f of feeds) {
    const addr = f.priceFeed.toLowerCase()
    const existing = sharedFeedMap.get(addr) ?? []
    existing.push(f.asset.symbol)
    sharedFeedMap.set(addr, existing)
  }

  const displayed = sortFeeds(applySearch(applyFilter(feeds, filterStatus), searchQuery), sortKey, sortDir)

  if (displayed.length === 0) {
    const reason = searchQuery.trim()
      ? `No assets matching "${searchQuery.trim()}"`
      : `No ${filterStatus} feeds on this chain`
    return (
      <p className="text-sm text-neutral-700 py-6 text-center">{reason}.</p>
    )
  }

  const td = dense ? '!py-1.5 !text-xs' : ''
  const logo = dense ? 'w-4 h-4' : 'w-5 h-5'
  const sortProps = { currentKey: sortKey, currentDir: sortDir, onSort: handleSort }

  return (
    <div className="overflow-x-auto feeds-table">
      <Table>
        <THead className="sticky top-0 z-10 bg-white">
          <Tr>
            <SortTh sortKey="asset" {...sortProps} align="left">Asset</SortTh>
            <Th>Feed Type</Th>
            <Th>Feed Address</Th>
            <SortTh sortKey="price" {...sortProps} align="right">Price</SortTh>
            <SortTh sortKey="heartbeat" {...sortProps} align="right">Heartbeat</SortTh>
            <SortTh sortKey="lastUpdated" {...sortProps} align="right">Last Updated</SortTh>
            <SortTh sortKey="status" {...sortProps} align="center">Status</SortTh>
          </Tr>
        </THead>
        <TBody>
          {displayed.map((feed, i) => {
            const sharedWith = (sharedFeedMap.get(feed.priceFeed.toLowerCase()) ?? []).filter(
              (s) => s !== feed.asset.symbol,
            )
            return (
              <Tr key={i} className="hover:bg-neutral-50 transition-colors">
                <Td className={td}>
                  <div className="flex items-center gap-1.5">
                    <TokenLogo symbol={feed.asset.symbol} address={feed.asset.asset} chainId={chainId} className={logo} />
                    <span className="font-semibold">{feed.asset.symbol}</span>
                    <a
                      href={explorerAddressUrl(chainId, feed.asset.asset)}
                      target="_blank"
                      rel="noreferrer"
                      className="link-icon text-neutral-700 hover:text-neutral-950 inline-flex items-center transition-colors"
                    >
                      <Launch className="w-3 h-3" />
                    </a>
                  </div>
                </Td>
                <Td className={td}>
                  <Badge variant="generic" className="text-xs">
                    {PRICE_TYPES[feed.priceType] ?? 'Unknown'}
                  </Badge>
                </Td>
                <Td className={td}>
                  <div className="flex items-center gap-1.5">
                    <CopyableAddress value={feed.priceFeed} className="text-sm" />
                    {sharedWith.length > 0 && (
                      <Tooltip>
                        <TooltipTrigger className="cursor-default text-xs text-neutral-500">↔</TooltipTrigger>
                        <TooltipContent>
                          <span className="block text-neutral-700 text-xs">Shared feed with {sharedWith.join(', ')}</span>
                        </TooltipContent>
                      </Tooltip>
                    )}
                    <a
                      href={explorerAddressUrl(chainId, feed.priceFeed)}
                      target="_blank"
                      rel="noreferrer"
                      className="link-icon text-neutral-700 hover:text-neutral-950 inline-flex items-center"
                    >
                      <Launch className="w-3 h-3" />
                    </a>
                  </div>
                </Td>
                <Td className={`text-right tabular-nums ${td}`}>
                  {formatPrice(feed.price, feed.decimals)}
                </Td>
                <Td className={`text-right tabular-nums text-neutral-700 ${td}`}>
                  {formatHeartbeat(feed.chainlinkHeartbeat)}
                </Td>
                <Td className={`text-right tabular-nums ${td}`}>
                  {feed.updatedAt > 0n ? (
                    <Tooltip>
                      <TooltipTrigger className="cursor-default">
                        {formatAge(feed.updatedAt)}
                      </TooltipTrigger>
                      <TooltipContent>
                        {new Date(Number(feed.updatedAt) * 1000).toLocaleString()}
                      </TooltipContent>
                    </Tooltip>
                  ) : feed.priceType === PRICE_TYPE_CUSTOM ? (
                    <Tooltip>
                      <TooltipTrigger className="cursor-default text-neutral-700">Live</TooltipTrigger>
                      <TooltipContent>{CUSTOM_LIVE_TIP}</TooltipContent>
                    </Tooltip>
                  ) : (
                    <span className="text-neutral-700">—</span>
                  )}
                </Td>
                <Td className={`text-center ${td}`}>
                  <FeedStatusBadge feed={feed} />
                </Td>
              </Tr>
            )
          })}
        </TBody>
      </Table>
    </div>
  )
}
