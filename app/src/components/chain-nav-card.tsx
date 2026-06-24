'use client'

import { Badge } from '@karpatkey/design-system'
import { Card } from '@karpatkey/design-system'
import { Skeleton } from '@karpatkey/design-system'
import type { ChainNav } from '@/hooks/use-account-nav'
import { formatUsd } from '@/lib/format'

interface ChainNavCardProps {
  data: ChainNav
  isSelected: boolean
  onClick: () => void
}

export function ChainNavCard({ data, isSelected, onClick }: ChainNavCardProps) {
  const { label, nav, isLoading, isError } = data

  return (
    <button
      type="button"
      onClick={onClick}
      className={`w-full text-left rounded-lg border transition-colors ${
        isSelected ? 'border-primary bg-primary/5' : 'border-border hover:border-primary/50'
      }`}
    >
      <div className="p-4">
        <div className="flex items-center justify-between mb-2">
          <span className="font-semibold text-sm">{label}</span>
          {nav?.sequencerDown && (
            <Badge variant="negative" className="text-xs">Seq Down</Badge>
          )}
        </div>

        {isLoading && <Skeleton className="h-6 w-28" />}

        {isError && (
          <span className="text-sm text-destructive">RPC error</span>
        )}

        {!isLoading && !isError && nav && (
          <div>
            <p className="text-xl font-bold tabular-nums">
              {formatUsd(nav.value)}
            </p>
            {nav.stalePriceAssets.length > 0 && (
              <p className="text-xs text-amber-600 mt-1">
                ⚠ {nav.stalePriceAssets.length} stale price
                {nav.stalePriceAssets.length > 1 ? 's' : ''}
              </p>
            )}
          </div>
        )}

        {!isLoading && !isError && !nav && (
          <p className="text-sm text-neutral-700">No data</p>
        )}
      </div>
    </button>
  )
}
