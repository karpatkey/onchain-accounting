'use client'

import type { ReactNode } from 'react'
import Link from 'next/link'

// Shared top navigation used by every dashboard page (Portfolio / Coverage / Price Feeds) so navigation is
// identical across the app. The active page is underlined; links carry the current `?address=` so switching
// tabs keeps the same account. `refresh` renders the ↻ control (with cooldown) where a page supports it;
// `right` is a slot for page-specific actions (e.g. the portfolio's CSV export + reset).

export type NavPage = 'portfolio' | 'coverage' | 'feeds'

const LINKS: { key: NavPage; href: string; label: string }[] = [
  { key: 'portfolio', href: '/', label: 'Portfolio' },
  { key: 'coverage', href: '/coverage', label: 'Coverage' },
  { key: 'feeds', href: '/feeds', label: 'Price Feeds' },
]

export function DashboardNav({
  active,
  address,
  refresh,
  right,
}: {
  active: NavPage
  address?: string | null
  refresh?: { onClick: () => void; canRefresh: boolean; secondsLeft: number }
  right?: ReactNode
}) {
  const q = address ? `?address=${address}` : ''
  return (
    <div className="flex items-center justify-between py-4">
      <Link href={`/${q}`} className="flex items-center gap-2">
        <div className="w-7 h-7 rounded-full bg-neutral-950 flex items-center justify-center text-white text-xs font-semibold">
          k
        </div>
        <span className="text-sm font-semibold text-neutral-950">NAV Dashboard</span>
      </Link>
      <div className="flex items-center gap-4 text-sm">
        {LINKS.map((l) => (
          <Link
            key={l.key}
            href={`${l.href}${q}`}
            className={
              active === l.key
                ? 'text-neutral-950 font-semibold underline underline-offset-4'
                : 'text-neutral-700 hover:text-neutral-950 transition-colors'
            }
          >
            {l.label}
          </Link>
        ))}
        {refresh && (
          <button
            type="button"
            onClick={refresh.onClick}
            disabled={!refresh.canRefresh}
            className={`tabular-nums transition-colors ${
              refresh.canRefresh
                ? 'text-neutral-700 hover:text-neutral-950'
                : 'text-neutral-700 opacity-70 cursor-not-allowed'
            }`}
          >
            {refresh.canRefresh ? '↻ Refresh' : `↻ ${refresh.secondsLeft}s`}
          </button>
        )}
        {right}
      </div>
    </div>
  )
}
