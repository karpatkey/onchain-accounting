'use client'

import Link from 'next/link'
import { TooltipProvider } from '@karpatkey/design-system'
import { PriceFeedsTable } from '@/components/price-feeds-table'
import { SequencerDetailCard } from '@/components/sequencer-detail-card'
import { useChainPriceFeeds } from '@/hooks/use-price-feeds'
import { DEPLOYED_CHAINS } from '@/config/chains'

function ChainFeedsSection({ chainIdx }: { chainIdx: number }) {
  const data = useChainPriceFeeds(chainIdx)
  const chainConfig = DEPLOYED_CHAINS[chainIdx]

  return (
    <div className="rounded-xl border border-neutral-400 bg-white overflow-hidden shadow-[var(--shadow-1)]">
      <div className="flex items-center justify-between px-5 py-4 border-b border-neutral-300">
        <h2 className="font-semibold text-neutral-950">{chainConfig.label}</h2>
        {!data.isLoading && (
          <span className="text-xs text-neutral-500">{data.assets.length} assets</span>
        )}
      </div>

      <div className="p-5 space-y-5">
        {chainConfig.sequencerFeed ? (
          <SequencerDetailCard
            chainId={chainConfig.chain.id}
            chainLabel={chainConfig.label}
            feedAddress={chainConfig.sequencerFeed}
          />
        ) : (
          <p className="text-xs text-neutral-500">L1 — no sequencer feed</p>
        )}
        <PriceFeedsTable data={data} />
      </div>
    </div>
  )
}

export default function FeedsPage() {
  return (
    <TooltipProvider>
      <div className="space-y-8">
        <div>
          <Link
            href="/"
            className="inline-flex items-center gap-1 text-sm text-neutral-500 hover:text-neutral-950 mb-4"
          >
            ← Portfolio
          </Link>
          <h1 className="text-2xl font-bold text-neutral-950">Price Feeds</h1>
          <p className="text-sm text-neutral-500 mt-1">
            Chainlink and custom feed health across all deployed chains.
          </p>
        </div>

        <div className="space-y-6">
          {DEPLOYED_CHAINS.map((_, idx) => (
            <ChainFeedsSection key={idx} chainIdx={idx} />
          ))}
        </div>
      </div>
    </TooltipProvider>
  )
}
