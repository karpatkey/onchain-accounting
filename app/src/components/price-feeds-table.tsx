'use client'

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
import type { ChainPriceFeeds } from '@/hooks/use-price-feeds'
import { formatAge, formatHeartbeat, formatPrice, isStaleWarning, shortenAddress } from '@/lib/format'
import { explorerAddressUrl } from '@/config/chains'

const PRICE_TYPES = ['Chainlink', 'Custom'] as const

interface PriceFeedsTableProps {
  data: ChainPriceFeeds
}

function FeedStatusBadge({ feed }: { feed: ChainPriceFeeds['feeds'][number] }) {
  if (feed.sequencerDown) {
    return <Badge variant="negative">Seq Down</Badge>
  }
  if (feed.stale) {
    return <Badge variant="negative">Stale</Badge>
  }
  if (isStaleWarning(feed.updatedAt, feed.chainlinkHeartbeat)) {
    return <Badge variant="generic" className="bg-amber-500 hover:bg-amber-600 text-white">Warning</Badge>
  }
  return <Badge variant="positive">Fresh</Badge>
}

export function PriceFeedsTable({ data }: PriceFeedsTableProps) {
  const { feeds, isLoading, isError, chainId } = data

  if (isLoading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 5 }).map((_, i) => (
          <Skeleton key={i} className="h-10 w-full" />
        ))}
      </div>
    )
  }

  if (isError) {
    return <p className="text-sm text-destructive py-4">Failed to load price feeds.</p>
  }

  if (feeds.length === 0) {
    return <p className="text-sm text-muted-foreground py-4">No registered assets found.</p>
  }

  return (
    <div className="overflow-x-auto">
      <Table>
        <THead>
          <Tr>
            <Th>Asset</Th>
            <Th>Feed Type</Th>
            <Th>Feed Address</Th>
            <Th className="text-right">Price</Th>
            <Th className="text-right">Heartbeat</Th>
            <Th className="text-right">Last Updated</Th>
            <Th className="text-center">Status</Th>
          </Tr>
        </THead>
        <TBody>
          {feeds.map((feed, i) => (
            <Tr key={i}>
              <Td className="font-semibold">{feed.asset.symbol}</Td>
              <Td>
                <Badge variant="generic" className="text-xs">
                  {PRICE_TYPES[feed.priceType] ?? 'Unknown'}
                </Badge>
              </Td>
              <Td>
                <div className="flex items-center gap-1.5">
                  <Tooltip>
                    <TooltipTrigger className="font-mono text-sm cursor-default">
                      {shortenAddress(feed.priceFeed)}
                    </TooltipTrigger>
                    <TooltipContent>
                      <span className="font-mono">{feed.priceFeed}</span>
                    </TooltipContent>
                  </Tooltip>
                  <a
                    href={explorerAddressUrl(chainId, feed.priceFeed)}
                    target="_blank"
                    rel="noreferrer"
                    className="text-neutral-500 hover:text-neutral-950 inline-flex items-center"
                  >
                    <Launch className="w-3 h-3" />
                  </a>
                </div>
              </Td>
              <Td className="text-right tabular-nums">
                {formatPrice(feed.price, feed.decimals)}
              </Td>
              <Td className="text-right tabular-nums text-muted-foreground text-sm">
                {feed.priceType === 0
                  ? formatHeartbeat(feed.chainlinkHeartbeat)
                  : '—'}
              </Td>
              <Td className="text-right tabular-nums text-sm">
                {feed.updatedAt > 0n ? (
                  <Tooltip>
                    <TooltipTrigger className="cursor-default">
                      {formatAge(feed.updatedAt)}
                    </TooltipTrigger>
                    <TooltipContent>
                      {new Date(Number(feed.updatedAt) * 1000).toLocaleString()}
                    </TooltipContent>
                  </Tooltip>
                ) : (
                  <span className="text-muted-foreground">—</span>
                )}
              </Td>
              <Td className="text-center">
                <FeedStatusBadge feed={feed} />
              </Td>
            </Tr>
          ))}
        </TBody>
      </Table>
    </div>
  )
}
