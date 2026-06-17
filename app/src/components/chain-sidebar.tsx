'use client'

import { Tooltip, TooltipContent, TooltipTrigger } from '@karpatkey/design-system'
import type { ChainNav } from '@/hooks/use-account-nav'
import { formatUsd } from '@/lib/format'
import {
  EthCircleColor,
  OpCircleColor,
  GnosisCircleColor,
  ArbitrumCircleColor,
  BaseCircleColor,
} from '@karpatkey/design-system'

const CHAIN_META: Record<number, { label: string; Icon: React.ComponentType<{ className?: string }> }> = {
  1:     { label: 'Ethereum', Icon: EthCircleColor },
  10:    { label: 'Optimism', Icon: OpCircleColor },
  100:   { label: 'Gnosis',   Icon: GnosisCircleColor },
  42161: { label: 'Arbitrum', Icon: ArbitrumCircleColor },
  8453:  { label: 'Base',     Icon: BaseCircleColor },
}

interface ChainSidebarProps {
  navResults: ChainNav[]
  selectedChainId: number | null
  onSelect: (chainId: number | null) => void
}

export function ChainSidebar({ navResults, selectedChainId, onSelect }: ChainSidebarProps) {
  const totalNav = navResults.reduce((sum, r) => sum + (r.nav?.value ?? 0n), 0n)
  const isLoading = navResults.some((r) => r.isLoading)

  return (
    <div className="w-52 shrink-0 sticky top-4 self-start">
      <p className="text-xs text-neutral-500 uppercase tracking-wider mb-2 px-2">Chains</p>
      <ul className="space-y-0.5">

        {/* All chains */}
        <li>
          <button
            type="button"
            onClick={() => onSelect(null)}
            className={`w-full flex items-center justify-between px-3 py-2 rounded-lg text-sm transition-colors ${
              selectedChainId === null
                ? 'bg-neutral-300 text-neutral-950 font-semibold'
                : 'text-neutral-700 hover:bg-neutral-300/60 hover:text-neutral-950'
            }`}
          >
            <span className="flex items-center gap-2">
              <span className="w-5 h-5 rounded-full bg-neutral-400 flex items-center justify-center text-[10px] text-neutral-700 font-semibold">∑</span>
              All Chains
            </span>
            {isLoading ? (
              <span className="text-neutral-400 text-xs">…</span>
            ) : (
              <span className="tabular-nums text-xs">{formatUsd(totalNav)}</span>
            )}
          </button>
        </li>

        {/* Per-chain */}
        {navResults.map(({ chainId, label, nav, isLoading: chainLoading }) => {
          const meta = CHAIN_META[chainId]
          if (!meta) return null
          const { Icon } = meta
          const isSelected = selectedChainId === chainId
          const isEmpty = !chainLoading && (nav?.value ?? 0n) === 0n
          // Keep the ratio in bigint (basis points) so large NAVs can't overflow/lose
          // precision in Number(); only the bounded 0–10000 result is converted.
          const pct =
            totalNav > 0n && nav?.value ? Math.round(Number((nav.value * 10_000n) / totalNav) / 100) : 0

          const button = (
            <button
              type="button"
              onClick={() => onSelect(isSelected ? null : chainId)}
              className={`w-full flex items-center justify-between px-3 py-2 rounded-lg text-sm transition-colors ${
                isSelected
                  ? 'bg-neutral-300 text-neutral-950 font-semibold'
                  : isEmpty
                  ? 'text-neutral-400 hover:bg-neutral-300/40 hover:text-neutral-600'
                  : 'text-neutral-700 hover:bg-neutral-300/60 hover:text-neutral-950'
              }`}
            >
              <span className="flex items-center gap-2">
                <Icon className={`w-5 h-5 ${isEmpty ? 'opacity-40' : ''}`} />
                {label}
                {nav?.sequencerDown && <span className="text-rose-700 text-[10px]">↓</span>}
              </span>
              <span className="flex items-center gap-1.5">
                {chainLoading ? (
                  <span className="text-neutral-400 text-xs">…</span>
                ) : (
                  <>
                    {!isEmpty && pct > 0 && (
                      <span className="text-neutral-400 text-[10px]">{pct}%</span>
                    )}
                    <span className={`tabular-nums text-xs ${nav?.stalePriceAssets.length ? 'text-orange-700' : ''}`}>
                      {formatUsd(nav?.value ?? 0n)}
                    </span>
                  </>
                )}
              </span>
            </button>
          )

          if (isEmpty && !chainLoading) {
            return (
              <li key={chainId}>
                <Tooltip>
                  <TooltipTrigger asChild>{button}</TooltipTrigger>
                  <TooltipContent>No positions found on this chain</TooltipContent>
                </Tooltip>
              </li>
            )
          }

          return <li key={chainId}>{button}</li>
        })}
      </ul>
    </div>
  )
}
