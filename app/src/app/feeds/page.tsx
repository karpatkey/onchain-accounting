'use client'

import { useState } from 'react'
import { TooltipProvider, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, Badge } from '@karpatkey/design-system'
import { PriceFeedsTable } from '@/components/price-feeds-table'
import { SequencerBadge } from '@/components/sequencer-badge'
import { useChainPriceFeeds } from '@/hooks/use-price-feeds'
import { DEPLOYED_CHAINS } from '@/config/chains'

function ChainFeedsView({ chainIdx }: { chainIdx: number }) {
  const data = useChainPriceFeeds(chainIdx)
  const chainConfig = DEPLOYED_CHAINS[chainIdx]

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3 flex-wrap">
        <span className="text-sm font-medium text-muted-foreground">Sequencer:</span>
        {chainConfig.sequencerFeed ? (
          <SequencerBadge
            label={data.label}
            sequencerFeed={chainConfig.sequencerFeed}
            isDown={data.sequencerDown}
          />
        ) : (
          <Badge variant="generic" className="text-xs">L1 — no sequencer</Badge>
        )}
        {!data.isLoading && (
          <span className="text-xs text-muted-foreground ml-auto">
            {data.assets.length} registered assets
          </span>
        )}
      </div>
      <PriceFeedsTable data={data} />
    </div>
  )
}

export default function FeedsPage() {
  const [selectedIdx, setSelectedIdx] = useState(0)

  return (
    <TooltipProvider>
      <div className="space-y-8">
        <div>
          <h1 className="text-2xl font-bold mb-1">Price Feeds</h1>
          <p className="text-sm text-muted-foreground">
            Chainlink and custom feed health across all deployed chains.
          </p>
        </div>

        {/* L2 sequencer overview */}
        <div className="rounded-xl border bg-card p-5">
          <h2 className="text-sm font-semibold mb-3 text-muted-foreground uppercase tracking-wide">
            L2 Sequencer Status
          </h2>
          <div className="flex flex-wrap gap-4">
            {DEPLOYED_CHAINS.map((c, idx) => (
              <SequencerBadge
                key={c.chain.id}
                label={c.label}
                sequencerFeed={c.sequencerFeed}
                isDown={false}
              />
            ))}
          </div>
        </div>

        {/* Chain selector + table */}
        <div className="space-y-4">
          <div className="flex items-center gap-3">
            <label htmlFor="chain-select" className="text-sm font-medium">
              Chain
            </label>
            <Select
              value={String(selectedIdx)}
              onValueChange={(v) => setSelectedIdx(Number(v))}
            >
              <SelectTrigger id="chain-select" className="w-48">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {DEPLOYED_CHAINS.map((c, idx) => (
                  <SelectItem key={c.chain.id} value={String(idx)}>
                    {c.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <ChainFeedsView chainIdx={selectedIdx} />
        </div>
      </div>
    </TooltipProvider>
  )
}
