'use client'

import { useState, useRef, useEffect } from 'react'
import Link from 'next/link'
import { TooltipProvider } from '@karpatkey/design-system'
import { CoverageTable } from '@/components/coverage-table'
import { useChainCoverage } from '@/hooks/use-coverage'
import { DEPLOYED_CHAINS } from '@/config/chains'

function ChainCoveragePill({ chainIdx, isActive }: { chainIdx: number; isActive: boolean }) {
  const data = useChainCoverage(chainIdx)
  const config = DEPLOYED_CHAINS[chainIdx]

  return (
    <a
      href={`#chain-${config.chain.id}`}
      className={`flex items-center gap-1.5 text-sm transition-colors ${
        isActive ? 'text-neutral-950 font-semibold' : 'text-neutral-700 hover:text-neutral-950'
      }`}
    >
      <img
        src={config.logoUrl}
        alt={config.label}
        className="w-4 h-4 rounded-full shrink-0 object-cover"
      />
      <span>{config.label}</span>
      {data.isLoading ? (
        <span className="text-neutral-700 text-xs">…</span>
      ) : data.protocols.length > 0 ? (
        <span className="text-neutral-700">
          ({data.protocols.length} {data.protocols.length === 1 ? 'protocol' : 'protocols'})
        </span>
      ) : (
        <span className="text-neutral-500 text-xs">none yet</span>
      )}
    </a>
  )
}

function ChainCoverageSection({ chainIdx, searchQuery }: { chainIdx: number; searchQuery: string }) {
  const data = useChainCoverage(chainIdx)
  const chainConfig = DEPLOYED_CHAINS[chainIdx]
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
          <span
            className={`text-[10px] font-semibold px-1.5 py-0.5 rounded uppercase tracking-wide ${
              isL2 ? 'bg-violet-100 text-violet-700' : 'bg-neutral-100 text-neutral-700'
            }`}
          >
            {isL2 ? 'L2' : 'L1'}
          </span>
        </div>
        {!data.isLoading && (
          <span className="text-xs text-neutral-700">
            {data.protocols.length} {data.protocols.length === 1 ? 'protocol' : 'protocols'} ·{' '}
            {data.adapterCount} {data.adapterCount === 1 ? 'adapter' : 'adapters'}
          </span>
        )}
      </div>

      <div className="p-5">
        <CoverageTable data={data} searchQuery={searchQuery} />
      </div>
    </div>
  )
}

export default function CoveragePage() {
  const [searchQuery, setSearchQuery] = useState('')
  const [activeChainId, setActiveChainId] = useState<number | null>(null)
  const searchRef = useRef<HTMLInputElement>(null)

  // Preserve the ?address= when going back so "Portfolio" returns to the same account's dashboard
  // instead of the empty landing page. Read from the URL on mount (the app reads addresses from
  // window.location, not useSearchParams — no Suspense needed).
  const [portfolioHref, setPortfolioHref] = useState('/')
  const [feedsHref, setFeedsHref] = useState('/feeds')
  useEffect(() => {
    const addr = new URLSearchParams(window.location.search).get('address')
    if (addr) {
      setPortfolioHref(`/?address=${addr}`)
      setFeedsHref(`/feeds?address=${addr}`)
    }
  }, [])

  // Scroll-spy: observe each chain section and track which is most in view.
  useEffect(() => {
    const sectionIds = DEPLOYED_CHAINS.map((c) => `chain-${c.chain.id}`)
    const observers: IntersectionObserver[] = []
    for (const id of sectionIds) {
      const el = document.getElementById(id)
      if (!el) continue
      const obs = new IntersectionObserver(
        ([entry]) => {
          if (entry.isIntersecting) setActiveChainId(Number(id.replace('chain-', '')))
        },
        { rootMargin: '-20% 0px -60% 0px', threshold: 0 },
      )
      obs.observe(el)
      observers.push(obs)
    }
    return () => observers.forEach((o) => o.disconnect())
  }, [])

  // Cmd+K / "/" to focus search.
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

  return (
    <TooltipProvider>
      <div className="space-y-4">
          {/* Header row */}
          <div className="flex items-start justify-between gap-4">
            <div className="min-w-0">
              <Link
                href={portfolioHref}
                className="group inline-flex items-center gap-1.5 rounded-lg border border-neutral-300 bg-white px-2.5 py-1 text-xs font-medium text-neutral-700 shadow-sm transition-colors hover:border-neutral-500 hover:text-neutral-950 mb-3"
              >
                <span aria-hidden className="transition-transform group-hover:-translate-x-0.5">
                  ←
                </span>
                Portfolio
              </Link>
              <h1 className="font-bold text-neutral-950 text-2xl">Coverage</h1>
              <p className="text-sm text-neutral-700 mt-1">
                The protocols and positions the NAV system tracks, per chain.
              </p>
            </div>
            <div className="flex shrink-0 items-center gap-3 mt-1 text-sm">
              <Link href={feedsHref} className="text-neutral-700 hover:text-neutral-950 transition-colors">
                Price Feeds
              </Link>
            </div>
          </div>

          {/* Scope banner */}
          <div className="rounded-xl border border-neutral-300 border-l-4 border-l-violet-500 bg-violet-50/50 px-5 py-4">
            <h2 className="text-sm font-semibold text-neutral-950">What the NAV system tracks</h2>
            <p className="text-sm text-neutral-700 mt-1 max-w-3xl">
              NAV values only the protocols and positions listed below — the ones karpatkey actively
              uses across these accounts. Anything outside this set is intentionally not counted.
            </p>
          </div>

          {/* Chain summary strip with scroll overflow + fade mask */}
          <div className="relative">
            <div className="overflow-x-auto no-scrollbar flex items-center gap-x-6 gap-y-2 py-3 px-4 rounded-xl border border-neutral-300 bg-neutral-100 text-sm">
              {DEPLOYED_CHAINS.map((c, idx) => (
                <ChainCoveragePill key={idx} chainIdx={idx} isActive={activeChainId === c.chain.id} />
              ))}
            </div>
            <div className="pointer-events-none absolute inset-y-0 right-0 w-8 rounded-r-xl bg-gradient-to-l from-neutral-100 to-transparent" />
          </div>

          {/* Search */}
          <div className="flex items-center justify-end">
            <div className="relative">
              <input
                ref={searchRef}
                type="search"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search protocols…"
                className="text-sm rounded-lg border border-neutral-300 bg-white px-3 py-1.5 pr-16 text-neutral-900 placeholder:text-neutral-700 focus:outline-none focus:ring-2 focus:ring-neutral-400 w-52"
              />
              {!searchQuery && (
                <span className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 text-[10px] text-neutral-700 font-mono bg-neutral-100 border border-neutral-200 rounded px-1 py-0.5">
                  ⌘K
                </span>
              )}
            </div>
          </div>

          {/* Chain sections */}
          <div className="space-y-6">
            {DEPLOYED_CHAINS.map((_, idx) => (
              <ChainCoverageSection key={idx} chainIdx={idx} searchQuery={searchQuery} />
            ))}
          </div>
      </div>
    </TooltipProvider>
  )
}
