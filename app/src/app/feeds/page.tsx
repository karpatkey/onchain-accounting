'use client'

import { useState, useRef, useEffect, useCallback } from 'react'
import Link from 'next/link'
import { TooltipProvider, Tooltip, TooltipContent, TooltipTrigger } from '@karpatkey/design-system'
import { PriceFeedsTable, type FilterStatus } from '@/components/price-feeds-table'
import { SequencerDetailCard } from '@/components/sequencer-detail-card'
import { useChainPriceFeeds } from '@/hooks/use-price-feeds'
import { useRefreshCooldown } from '@/hooks/use-refresh-cooldown'
import { isStaleWarning } from '@/lib/format'
import { DEPLOYED_CHAINS } from '@/config/chains'

function ChainHealthPill({ chainIdx, isActive }: { chainIdx: number; isActive: boolean }) {
  const data = useChainPriceFeeds(chainIdx)
  const config = DEPLOYED_CHAINS[chainIdx]

  const issueCount = data.isLoading
    ? null
    : data.feeds.filter(
        (f) => f.stale || f.sequencerDown || isStaleWarning(f.updatedAt, f.chainlinkHeartbeat),
      ).length

  return (
    <a
      href={`#chain-${config.chain.id}`}
      className={`flex items-center gap-1.5 text-sm transition-colors ${
        isActive
          ? 'text-neutral-950 font-semibold'
          : 'text-neutral-700 hover:text-neutral-950'
      }`}
    >
      <img
        src={config.logoUrl}
        alt={config.label}
        className="w-4 h-4 rounded-full shrink-0 object-cover"
      />
      <span>{config.label}</span>
      {issueCount !== null && (
        <span className="text-neutral-700">({data.assets.length})</span>
      )}
      {issueCount === null && (
        <span className="text-neutral-700 text-xs">…</span>
      )}
      {issueCount !== null && issueCount > 0 && (
        <span className="bg-amber-100 text-amber-800 text-xs rounded-full px-2 py-0.5 font-medium">
          {issueCount} {issueCount === 1 ? 'warning' : 'warnings'}
        </span>
      )}
      {issueCount === 0 && (
        <span className="text-green-700 text-xs font-medium">All fresh</span>
      )}
    </a>
  )
}

function ChainFeedsSection({
  chainIdx,
  dense,
  filterStatus,
  searchQuery,
}: {
  chainIdx: number
  dense: boolean
  filterStatus: FilterStatus
  searchQuery: string
}) {
  const data = useChainPriceFeeds(chainIdx)
  const chainConfig = DEPLOYED_CHAINS[chainIdx]

  const issueCount = data.isLoading
    ? null
    : data.feeds.filter(
        (f) => f.stale || f.sequencerDown || isStaleWarning(f.updatedAt, f.chainlinkHeartbeat),
      ).length

  const isL2 = chainConfig.sequencerFeed !== null

  return (
    <div
      id={`chain-${chainConfig.chain.id}`}
      className="rounded-xl border border-neutral-400 bg-white overflow-hidden shadow-[var(--shadow-1)]"
      style={{ borderLeftColor: chainConfig.brandColor, borderLeftWidth: 4 }}
    >
      <div className="flex items-center justify-between px-5 py-4 border-b border-neutral-300">
        <div className="flex items-center gap-2">
          <img
            src={chainConfig.logoUrl}
            alt={chainConfig.label}
            className="w-5 h-5 rounded-full shrink-0 object-cover"
          />
          <h2 className="font-semibold text-neutral-950">{chainConfig.label}</h2>
          <span className={`text-[10px] font-semibold px-1.5 py-0.5 rounded uppercase tracking-wide ${
            isL2
              ? 'bg-violet-100 text-violet-700'
              : 'bg-neutral-100 text-neutral-700'
          }`}>
            {isL2 ? 'L2' : 'L1'}
          </span>
          {issueCount !== null && issueCount > 0 && (
            <span className="text-xs bg-amber-100 text-amber-800 rounded-full px-2 py-0.5 font-medium">
              {issueCount} {issueCount === 1 ? 'issue' : 'issues'}
            </span>
          )}
        </div>
        {!data.isLoading && (
          <span className="text-xs text-neutral-700">{data.assets.length} assets</span>
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
          <p className="text-xs text-neutral-700">L1 — no sequencer feed</p>
        )}
        <PriceFeedsTable data={data} dense={dense} filterStatus={filterStatus} searchQuery={searchQuery} />
      </div>
    </div>
  )
}

export default function FeedsPage() {
  const [refreshKey, setRefreshKey] = useState(0)
  const [dense, setDense] = useState(false)
  const [filterStatus, setFilterStatus] = useState<FilterStatus>('all')
  const [searchQuery, setSearchQuery] = useState('')
  const [activeChainId, setActiveChainId] = useState<number | null>(null)
  const [isRefreshing, setIsRefreshing] = useState(false)
  const { canRefresh, secondsLeft, startCooldown, lastRefreshedLabel } = useRefreshCooldown()
  const searchRef = useRef<HTMLInputElement>(null)

  // Scroll-spy: observe each chain section and track which is most in view
  useEffect(() => {
    const sectionIds = DEPLOYED_CHAINS.map((c) => `chain-${c.chain.id}`)
    const observers: IntersectionObserver[] = []

    for (const id of sectionIds) {
      const el = document.getElementById(id)
      if (!el) continue
      const obs = new IntersectionObserver(
        ([entry]) => {
          if (entry.isIntersecting) {
            const chainId = Number(id.replace('chain-', ''))
            setActiveChainId(chainId)
          }
        },
        { rootMargin: '-20% 0px -60% 0px', threshold: 0 },
      )
      obs.observe(el)
      observers.push(obs)
    }

    return () => observers.forEach((o) => o.disconnect())
  }, [])

  // Cmd+K / "/" to focus search
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault()
        searchRef.current?.focus()
        searchRef.current?.select()
      } else if (e.key === '/' && document.activeElement?.tagName !== 'INPUT') {
        e.preventDefault()
        searchRef.current?.focus()
        searchRef.current?.select()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  const handleRefresh = useCallback(() => {
    setIsRefreshing(true)
    setRefreshKey((k) => k + 1)
    startCooldown()
    setTimeout(() => setIsRefreshing(false), 800)
  }, [startCooldown])

  return (
    <TooltipProvider>
      <div className="space-y-4">

        {/* Header row */}
        <div className="flex items-start justify-between">
          <div>
            <Link
              href="/"
              className="inline-flex items-center gap-1 text-sm font-medium text-neutral-700 hover:text-neutral-950 mb-3 transition-colors"
            >
              ← Portfolio
            </Link>
            <h1 className={`font-bold text-neutral-950 ${dense ? 'text-xl' : 'text-2xl'}`}>Price Feeds</h1>
            {!dense && (
              <p className="text-sm text-neutral-700 mt-1">
                Chainlink and custom feed health across all deployed chains.
              </p>
            )}
          </div>
          <div className="flex items-center gap-3 mt-1">
            <span className="text-xs text-neutral-700">{lastRefreshedLabel}</span>
            <button
              type="button"
              onClick={handleRefresh}
              disabled={!canRefresh}
              className={`tabular-nums text-sm transition-colors ${
                canRefresh
                  ? 'text-neutral-700 hover:text-neutral-950'
                  : 'text-neutral-700 opacity-70 cursor-not-allowed'
              } ${isRefreshing ? 'animate-spin' : ''}`}
            >
              ↻{canRefresh ? ' Refresh' : ` ${secondsLeft}s`}
            </button>
          </div>
        </div>

        {/* Health summary strip with scroll overflow + fade mask */}
        <div className="relative">
          <div className="overflow-x-auto no-scrollbar flex items-center gap-x-6 gap-y-2 py-3 px-4 rounded-xl border border-neutral-300 bg-neutral-100 text-sm">
            {DEPLOYED_CHAINS.map((c, idx) => (
              <ChainHealthPill key={idx} chainIdx={idx} isActive={activeChainId === c.chain.id} />
            ))}
          </div>
          {/* Fade mask on the right edge */}
          <div className="pointer-events-none absolute inset-y-0 right-0 w-8 rounded-r-xl bg-gradient-to-l from-neutral-100 to-transparent" />
        </div>

        {/* Controls bar: filter + search + density toggle */}
        <div className="flex items-center justify-between gap-3 flex-wrap">
          <div className="flex items-center gap-2 flex-wrap">
            {/* Status filter pills */}
            <div className="flex items-center gap-1 rounded-lg border border-neutral-300 bg-white p-0.5 shadow-sm">
              {(['all', 'fresh', 'warning'] as FilterStatus[]).map((f) => (
                <button
                  key={f}
                  type="button"
                  onClick={() => setFilterStatus(f)}
                  className={`px-3 py-1 rounded-md text-sm capitalize transition-colors ${
                    filterStatus === f
                      ? 'bg-neutral-950 text-white'
                      : 'text-neutral-700 hover:text-neutral-950'
                  }`}
                >
                  {f.charAt(0).toUpperCase() + f.slice(1)}
                </button>
              ))}
            </div>

            {/* Warning threshold info */}
            <Tooltip>
              <TooltipTrigger className="text-neutral-700 hover:text-neutral-700 text-sm cursor-default leading-none">ⓘ</TooltipTrigger>
              <TooltipContent className="max-w-xs">
                <strong>Warning threshold:</strong> a feed is flagged as Warning when its last update is older than 80% of its Chainlink heartbeat interval — before it goes Stale.
              </TooltipContent>
            </Tooltip>
          </div>

          <div className="flex items-center gap-2">
            {/* Search input */}
            <div className="relative">
              <input
                ref={searchRef}
                type="search"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search assets…"
                className="text-sm rounded-lg border border-neutral-300 bg-white px-3 py-1.5 pr-16 text-neutral-900 placeholder:text-neutral-700 focus:outline-none focus:ring-2 focus:ring-neutral-400 w-44"
              />
              {!searchQuery && (
                <span className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 text-[10px] text-neutral-700 font-mono bg-neutral-100 border border-neutral-200 rounded px-1 py-0.5">
                  ⌘K
                </span>
              )}
            </div>

            {/* Density toggle */}
            <button
              type="button"
              onClick={() => setDense((d) => !d)}
              className={`text-sm px-3 py-1.5 rounded-lg border transition-colors ${
                dense
                  ? 'border-neutral-950 bg-neutral-950 text-white'
                  : 'border-neutral-300 text-neutral-700 hover:text-neutral-950 hover:border-neutral-500'
              }`}
            >
              {dense ? '⊟ Compact' : '⊞ Comfortable'}
            </button>
          </div>
        </div>

        {/* Chain sections */}
        <div className="space-y-6">
          {DEPLOYED_CHAINS.map((_, idx) => (
            <ChainFeedsSection
              key={`${idx}-${refreshKey}`}
              chainIdx={idx}
              dense={dense}
              filterStatus={filterStatus}
              searchQuery={searchQuery}
            />
          ))}
        </div>
      </div>
    </TooltipProvider>
  )
}
