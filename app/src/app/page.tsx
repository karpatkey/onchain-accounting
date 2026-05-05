'use client'

import { useState } from 'react'
import { Badge, Separator, Skeleton, TooltipProvider } from '@karpatkey/design-system'
import { AddressInput } from '@/components/address-input'
import { ChainNavCard } from '@/components/chain-nav-card'
import { PositionsTable } from '@/components/positions-table'
import { useAccountNav } from '@/hooks/use-account-nav'
import { useAccountPositions } from '@/hooks/use-account-positions'
import { DEPLOYED_CHAINS } from '@/config/chains'
import { formatUsd } from '@/lib/format'

export default function PortfolioPage() {
  const [account, setAccount] = useState<`0x${string}` | undefined>()
  const [selectedChainIdx, setSelectedChainIdx] = useState<number | null>(null)

  const navResults = useAccountNav(account)
  const positionResults = useAccountPositions(account)

  const isLoading = navResults.some((r) => r.isLoading)

  const totalNav = navResults.reduce((sum, r) => {
    if (r.nav) return sum + r.nav.value
    return sum
  }, 0n)

  const staleChains = navResults.filter(
    (r) => r.nav && r.nav.stalePriceAssets.length > 0,
  )
  const seqDownChains = navResults.filter((r) => r.nav?.sequencerDown)

  const activeChainData =
    selectedChainIdx !== null ? positionResults[selectedChainIdx] : null

  return (
    <TooltipProvider>
      <div className="space-y-8">
        <div>
          <h1 className="text-2xl font-bold mb-1">Portfolio NAV</h1>
          <p className="text-sm text-muted-foreground">
            Query any address across all deployed chains simultaneously.
          </p>
        </div>

        <AddressInput onSearch={setAccount} isLoading={isLoading} />

        {account && (
          <>
            {/* Summary */}
            <div className="rounded-xl border bg-card p-6">
              <div className="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <p className="text-sm text-muted-foreground mb-1">Total NAV (all chains)</p>
                  {isLoading ? (
                    <Skeleton className="h-9 w-40" />
                  ) : (
                    <p className="text-4xl font-bold tabular-nums">{formatUsd(totalNav)}</p>
                  )}
                  <p className="font-mono text-xs text-muted-foreground mt-1">{account}</p>
                </div>
                <div className="flex flex-col gap-2">
                  {staleChains.map((r) => (
                    <Badge key={r.chainId} variant="negative" className="text-xs">
                      ⚠ Stale prices on {r.label} ({r.nav!.stalePriceAssets.length})
                    </Badge>
                  ))}
                  {seqDownChains.map((r) => (
                    <Badge key={r.chainId} variant="negative" className="text-xs">
                      Sequencer down on {r.label}
                    </Badge>
                  ))}
                </div>
              </div>
            </div>

            {/* Per-chain NAV cards */}
            <div>
              <h2 className="text-lg font-semibold mb-3">By Chain</h2>
              <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-3">
                {navResults.map((result, idx) => (
                  <ChainNavCard
                    key={result.chainId}
                    data={result}
                    isSelected={selectedChainIdx === idx}
                    onClick={() =>
                      setSelectedChainIdx(selectedChainIdx === idx ? null : idx)
                    }
                  />
                ))}
              </div>
            </div>

            {/* Positions detail */}
            {activeChainData && (
              <div>
                <Separator className="mb-6" />
                <h2 className="text-lg font-semibold mb-3">
                  Positions on{' '}
                  <span className="text-primary">
                    {DEPLOYED_CHAINS[selectedChainIdx!].label}
                  </span>
                </h2>
                <PositionsTable data={activeChainData} />
              </div>
            )}

            {selectedChainIdx === null && (
              <p className="text-sm text-muted-foreground text-center py-4">
                Click a chain card above to see position details.
              </p>
            )}
          </>
        )}

        {!account && (
          <div className="text-center py-16 text-muted-foreground">
            <p className="text-lg">Enter an address to get started.</p>
          </div>
        )}
      </div>
    </TooltipProvider>
  )
}
