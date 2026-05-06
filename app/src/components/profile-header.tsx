'use client'

import { useState } from 'react'
import type { ChainNav } from '@/hooks/use-account-nav'
import { formatUsd, shortenAddress } from '@/lib/format'
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

function Blockie({ address }: { address: string }) {
  const [src, setSrc] = useState<string>('')

  if (!src) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const makeBlockie = require('ethereum-blockies-base64')
      setSrc(makeBlockie(address))
    } catch {}
  }

  if (!src) {
    return (
      <div className="w-10 h-10 rounded-full bg-neutral-400 flex items-center justify-center text-xs text-neutral-700 font-semibold">
        {address.slice(2, 4).toUpperCase()}
      </div>
    )
  }

  return <img src={src} alt="blockie" className="w-10 h-10 rounded-full" />
}

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      type="button"
      onClick={() => {
        navigator.clipboard.writeText(text)
        setCopied(true)
        setTimeout(() => setCopied(false), 1500)
      }}
      className="text-neutral-600 hover:text-neutral-950 transition-colors text-xs px-1.5 py-0.5 rounded border border-neutral-400 hover:border-neutral-700"
    >
      {copied ? 'Copied' : 'Copy'}
    </button>
  )
}

interface ProfileHeaderProps {
  address: `0x${string}`
  navResults: ChainNav[]
}

export function ProfileHeader({ address, navResults }: ProfileHeaderProps) {
  const totalNav = navResults.reduce((sum, r) => sum + (r.nav?.value ?? 0n), 0n)
  const isLoading = navResults.some((r) => r.isLoading)

  return (
    <div className="py-6 border-b border-neutral-400">
      {/* Address row */}
      <div className="flex items-center gap-3 mb-4">
        <Blockie address={address} />
        <div>
          <div className="flex items-center gap-2">
            <span className="font-mono text-sm text-neutral-800">{address}</span>
            <CopyButton text={address} />
          </div>
          <span className="text-xs text-neutral-600">{shortenAddress(address)}</span>
        </div>
      </div>

      {/* Total NAV */}
      <div className="mb-4">
        <p className="text-xs text-neutral-600 uppercase tracking-wider mb-1">Total Net Worth</p>
        {isLoading ? (
          <div className="h-10 w-48 bg-neutral-300 rounded animate-pulse" />
        ) : (
          <p className="text-4xl font-semibold tabular-nums text-neutral-950 tracking-tight">{formatUsd(totalNav)}</p>
        )}
      </div>

      {/* Chain pills */}
      <div className="flex flex-wrap gap-2">
        {navResults.map(({ chainId, label, nav, isLoading: chainLoading }) => {
          const meta = CHAIN_META[chainId]
          if (!meta) return null
          const { Icon } = meta
          return (
            <div
              key={chainId}
              className="flex items-center gap-1.5 bg-white border border-neutral-400 rounded-full px-3 py-1 text-sm shadow-[var(--shadow-1)]"
            >
              <Icon className="w-4 h-4" />
              <span className="text-neutral-800">{label}</span>
              {chainLoading ? (
                <span className="text-neutral-400">…</span>
              ) : (
                <span className="text-neutral-700 tabular-nums">{formatUsd(nav?.value ?? 0n)}</span>
              )}
              {nav?.sequencerDown && (
                <span className="text-rose-700 text-xs ml-1">↓</span>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
