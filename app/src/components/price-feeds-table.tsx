'use client'

import { Fragment, useState } from 'react'
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
import type { ChainPriceFeeds, AssetFeedNode, FeedNode } from '@/hooks/use-price-feeds'
import { TokenLogo } from '@/components/token-logo'
import { formatAge, formatHeartbeat, formatPrice, isStaleWarning } from '@/lib/format'
import { AddressChip } from '@/components/address-chip'
import { explorerAddressUrl } from '@/config/chains'

// Indices match the Solidity IPrices.PriceType enum: Chainlink=0, Redstone=1, API3=2, Custom=3.
const PRICE_TYPES = ['Chainlink', 'Redstone', 'API3', 'Custom'] as const
// Only Custom (ICustomPriceFeed) feeds use the updatedAt==0 "Live" sentinel.
const PRICE_TYPE_CUSTOM = 3

export type FilterStatus = 'all' | 'fresh' | 'warning'
type SortKey = 'asset' | 'price' | 'redundancy' | 'status'
type SortDir = 'asc' | 'desc'

// Custom feeds: heartbeat and updatedAt are the worst-case across the feed's underlying
// oracle(s) per ICustomPriceFeed.latestRoundData() convention. updatedAt == 0 is the
// documented sentinel for "no trackable oracle dependency" (live on-chain rate).
const CUSTOM_LIVE_TIP = 'Live on-chain rate — no external oracle dependency.'

// --- per-feed status ---------------------------------------------------------

type FeedHealth = 'unavailable' | 'stale' | 'warning' | 'fresh'

function feedHealth(feed: FeedNode, sequencerDown: boolean): FeedHealth {
  if (!feed.available) return 'unavailable'
  if (sequencerDown || feed.stale) return 'stale'
  if (isStaleWarning(feed.updatedAt, feed.chainlinkHeartbeat)) return 'warning'
  return 'fresh'
}

function FeedStatusBadge({ feed, sequencerDown }: { feed: FeedNode; sequencerDown: boolean }) {
  const h = feedHealth(feed, sequencerDown)
  if (h === 'unavailable') {
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <Badge variant="generic" className="bg-neutral-400 text-white cursor-default">Unavailable</Badge>
        </TooltipTrigger>
        <TooltipContent>Feed read reverted — live price could not be fetched.</TooltipContent>
      </Tooltip>
    )
  }
  if (sequencerDown) return <Badge variant="negative">Seq Down</Badge>
  if (feed.stale) return <Badge variant="negative">Stale</Badge>
  if (h === 'warning') {
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

// Redundancy badge: N healthy of M configured. Green when all healthy, amber when degraded
// (some but not all), red when none.
function RedundancyBadge({ healthy, total }: { healthy: number; total: number }) {
  const cls =
    total === 0 || healthy === 0
      ? 'bg-red-100 text-red-800'
      : healthy >= total
        ? 'bg-green-100 text-green-800'
        : 'bg-amber-100 text-amber-800'
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <span className={`text-xs rounded-full px-2 py-0.5 font-medium tabular-nums cursor-default ${cls}`}>
          {healthy}/{total} healthy
        </span>
      </TooltipTrigger>
      <TooltipContent>
        {healthy} of {total} configured {total === 1 ? 'feed' : 'feeds'} currently non-stale (redundancy set).
      </TooltipContent>
    </Tooltip>
  )
}

// --- asset-level status (for filter/sort) ------------------------------------

// An asset "has an issue" (for the warning filter) when its winning feed is stale/down, its
// winner is in the heartbeat warning band, or its redundancy is degraded (not all feeds healthy).
function assetHasIssue(node: AssetFeedNode): boolean {
  if (node.winner.stale || node.sequencerDown) return true
  const winnerFeed = node.feeds.find((f) => f.isWinner)
  if (winnerFeed && isStaleWarning(winnerFeed.updatedAt, winnerFeed.chainlinkHeartbeat)) return true
  if (node.totalFeeds === 0 || node.healthyFeedCount < node.totalFeeds) return true
  return false
}

function assetStatusScore(node: AssetFeedNode): number {
  if (node.winner.stale || node.sequencerDown) return 3
  if (node.totalFeeds === 0 || node.healthyFeedCount === 0) return 3
  const winnerFeed = node.feeds.find((f) => f.isWinner)
  if (winnerFeed && isStaleWarning(winnerFeed.updatedAt, winnerFeed.chainlinkHeartbeat)) return 2
  if (node.healthyFeedCount < node.totalFeeds) return 1
  return 0
}

function sortNodes(nodes: AssetFeedNode[], key: SortKey | null, dir: SortDir): AssetFeedNode[] {
  if (!key) return nodes
  return [...nodes].sort((a, b) => {
    let d = 0
    switch (key) {
      case 'asset':      d = a.asset.symbol.localeCompare(b.asset.symbol); break
      case 'price':      d = a.winner.price > b.winner.price ? 1 : a.winner.price < b.winner.price ? -1 : 0; break
      case 'redundancy': d = a.healthyFeedCount - b.healthyFeedCount; break
      case 'status':     d = assetStatusScore(b) - assetStatusScore(a); break
    }
    return dir === 'asc' ? d : -d
  })
}

function applyFilter(nodes: AssetFeedNode[], filter: FilterStatus): AssetFeedNode[] {
  if (filter === 'all') return nodes
  return nodes.filter((n) => (filter === 'warning' ? assetHasIssue(n) : !assetHasIssue(n)))
}

function applySearch(nodes: AssetFeedNode[], query: string): AssetFeedNode[] {
  if (!query.trim()) return nodes
  const q = query.trim().toLowerCase()
  return nodes.filter((n) => n.asset.symbol.toLowerCase().includes(q))
}

// --- sortable header ---------------------------------------------------------

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

// --- child feed row ----------------------------------------------------------

function FeedChildRow({
  feed,
  chainId,
  sequencerDown,
  td,
}: {
  feed: FeedNode
  chainId: number
  sequencerDown: boolean
  td: string
}) {
  return (
    <Tr className="bg-neutral-50/60 hover:bg-neutral-100 transition-colors">
      {/* Feed type — indented under the asset, with a tree connector */}
      <Td className={td}>
        <div className="flex items-center gap-2 pl-6">
          <span className="text-neutral-400 select-none">└</span>
          <Badge variant="generic" className="text-xs">
            {PRICE_TYPES[feed.priceType] ?? 'Unknown'}
          </Badge>
          {feed.isWinner && (
            <Tooltip>
              <TooltipTrigger asChild>
                <span className="text-amber-500 cursor-default" aria-label="Winning feed">★</span>
              </TooltipTrigger>
              <TooltipContent>Winning feed — freshest non-stale feed selected by NAVCalculator.</TooltipContent>
            </Tooltip>
          )}
        </div>
      </Td>
      {/* Feed address */}
      <Td className={td}>
        <AddressChip address={feed.priceFeed} chainId={chainId} className="text-sm" />
      </Td>
      {/* Live price */}
      <Td className={`text-right tabular-nums ${td}`}>
        {feed.available ? formatPrice(feed.price, feed.decimals) : <span className="text-neutral-500">—</span>}
      </Td>
      {/* Decimals */}
      <Td className={`text-right tabular-nums text-neutral-700 ${td}`}>{feed.decimals}</Td>
      {/* Heartbeat */}
      <Td className={`text-right tabular-nums text-neutral-700 ${td}`}>
        {formatHeartbeat(feed.chainlinkHeartbeat)}
      </Td>
      {/* Last updated */}
      <Td className={`text-right tabular-nums ${td}`}>
        {!feed.available ? (
          <span className="text-neutral-500">—</span>
        ) : feed.updatedAt > 0n ? (
          <Tooltip>
            <TooltipTrigger className="cursor-default">{formatAge(feed.updatedAt)}</TooltipTrigger>
            <TooltipContent>{new Date(Number(feed.updatedAt) * 1000).toLocaleString()}</TooltipContent>
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
      {/* Status */}
      <Td className={`text-center ${td}`}>
        <FeedStatusBadge feed={feed} sequencerDown={sequencerDown} />
      </Td>
    </Tr>
  )
}

// --- component ---------------------------------------------------------------

interface PriceFeedsTableProps {
  data: ChainPriceFeeds
  dense?: boolean
  filterStatus?: FilterStatus
  searchQuery?: string
}

export function PriceFeedsTable({ data, dense = false, filterStatus = 'all', searchQuery = '' }: PriceFeedsTableProps) {
  const { nodes, isLoading, isError, chainId, sequencerDown } = data
  const [sortKey, setSortKey] = useState<SortKey | null>(null)
  const [sortDir, setSortDir] = useState<SortDir>('asc')
  // Collapsed set — default expanded so the redundancy is visible at a glance. Keyed by asset address.
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())

  function handleSort(key: SortKey) {
    if (sortKey === key) setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))
    else { setSortKey(key); setSortDir('asc') }
  }

  function toggle(addr: string) {
    setCollapsed((prev) => {
      const next = new Set(prev)
      if (next.has(addr)) next.delete(addr)
      else next.add(addr)
      return next
    })
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
  if (nodes.length === 0) return <p className="text-sm text-neutral-700 py-4">No registered assets found.</p>

  const displayed = sortNodes(applySearch(applyFilter(nodes, filterStatus), searchQuery), sortKey, sortDir)

  if (displayed.length === 0) {
    const reason = searchQuery.trim()
      ? `No assets matching "${searchQuery.trim()}"`
      : `No ${filterStatus} assets on this chain`
    return <p className="text-sm text-neutral-700 py-6 text-center">{reason}.</p>
  }

  const td = dense ? '!py-1.5 !text-xs' : ''
  const logo = dense ? 'w-4 h-4' : 'w-5 h-5'
  const sortProps = { currentKey: sortKey, currentDir: sortDir, onSort: handleSort }

  return (
    <div className="overflow-x-auto feeds-table">
      <Table>
        <THead className="sticky top-0 z-10 bg-white">
          <Tr>
            <SortTh sortKey="asset" {...sortProps} align="left">Asset / Feed Type</SortTh>
            <Th>Feed Address</Th>
            <SortTh sortKey="price" {...sortProps} align="right">Price</SortTh>
            <Th className="text-right">Decimals</Th>
            <Th className="text-right">Heartbeat</Th>
            <Th className="text-right">Last Updated</Th>
            <SortTh sortKey="status" {...sortProps} align="center">Status</SortTh>
          </Tr>
        </THead>
        <TBody>
          {displayed.map((node) => {
            const addr = node.asset.asset.toLowerCase()
            const isCollapsed = collapsed.has(addr)
            const winnerFeed = node.feeds.find((f) => f.isWinner)
            return (
              <Fragment key={addr}>
                {/* Asset parent row */}
                <Tr
                  className="hover:bg-neutral-50 transition-colors cursor-pointer border-t-2 border-neutral-200"
                  onClick={() => toggle(addr)}
                >
                  <Td className={td}>
                    <div className="flex items-center gap-1.5">
                      <span className="text-neutral-500 w-3 inline-block select-none">
                        {isCollapsed ? '▸' : '▾'}
                      </span>
                      <TokenLogo symbol={node.asset.symbol} address={node.asset.asset} chainId={chainId} className={logo} />
                      <span className="font-semibold">{node.asset.symbol}</span>
                      <a
                        href={explorerAddressUrl(chainId, node.asset.asset)}
                        target="_blank"
                        rel="noreferrer"
                        onClick={(e) => e.stopPropagation()}
                        className="link-icon text-neutral-700 hover:text-neutral-950 inline-flex items-center transition-colors"
                      >
                        <Launch className="w-3 h-3" />
                      </a>
                    </div>
                  </Td>
                  <Td className={td}>
                    <RedundancyBadge healthy={node.healthyFeedCount} total={node.totalFeeds} />
                  </Td>
                  <Td className={`text-right tabular-nums font-semibold ${td}`}>
                    {formatPrice(node.winner.price, node.winner.decimals)}
                  </Td>
                  <Td className={td} />
                  <Td className={td} />
                  <Td className={`text-right tabular-nums ${td}`}>
                    {winnerFeed && winnerFeed.available ? (
                      winnerFeed.updatedAt > 0n ? (
                        formatAge(winnerFeed.updatedAt)
                      ) : (
                        <span className="text-neutral-700">Live</span>
                      )
                    ) : (
                      <span className="text-neutral-700">—</span>
                    )}
                  </Td>
                  <Td className={`text-center ${td}`}>
                    {node.winner.stale || node.sequencerDown ? (
                      <Badge variant="negative">{node.sequencerDown ? 'Seq Down' : 'Stale'}</Badge>
                    ) : node.healthyFeedCount >= node.totalFeeds && node.totalFeeds > 0 ? (
                      <Badge variant="positive">Fresh</Badge>
                    ) : (
                      <Badge variant="generic" className="bg-amber-500 text-white">Degraded</Badge>
                    )}
                  </Td>
                </Tr>
                {/* Feed child rows */}
                {!isCollapsed &&
                  node.feeds.map((feed, fi) => (
                    <FeedChildRow
                      key={`${addr}-${feed.priceFeed}-${fi}`}
                      feed={feed}
                      chainId={chainId}
                      sequencerDown={sequencerDown}
                      td={td}
                    />
                  ))}
                {!isCollapsed && node.feeds.length === 0 && (
                  <Tr className="bg-neutral-50/60">
                    <Td className={td} colSpan={7}>
                      <span className="pl-6 text-xs text-neutral-500">No configured feeds could be read.</span>
                    </Td>
                  </Tr>
                )}
              </Fragment>
            )
          })}
        </TBody>
      </Table>
    </div>
  )
}
