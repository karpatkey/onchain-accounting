'use client'

import { useState } from 'react'
import { useEnsName } from 'wagmi'
import type { ChainNav } from '@/hooks/use-account-nav'
import { formatUsd } from '@/lib/format'
import { MultiChainAddressChip } from '@/components/address-chip'
import { DEPLOYED_CHAINS } from '@/config/chains'

// Brand colours from chains config, keyed by chainId
const CHAIN_COLORS: Record<number, string> = Object.fromEntries(
  DEPLOYED_CHAINS.map((c) => [c.chain.id, c.brandColor]),
)

// ─── Donut chart ──────────────────────────────────────────────────────────────

function DonutChart({ navResults }: { navResults: ChainNav[] }) {
  const loaded = navResults.filter((r) => r.nav && r.nav.value > 0n && !r.isLoading)
  if (loaded.length === 0) return <div className="w-20 h-20 rounded-full bg-neutral-200 animate-pulse shrink-0" />

  const total = loaded.reduce((s, r) => s + r.nav!.value, 0n)
  if (total === 0n) return null

  const radius = 35
  const circumference = 2 * Math.PI * radius
  let angle = -90

  const circles = loaded.map((r) => {
    const frac = Number(r.nav!.value) / Number(total)
    const dash = frac * circumference
    const color = CHAIN_COLORS[r.chainId] ?? '#ccc'
    const el = (
      <circle
        key={r.chainId}
        cx={50} cy={50} r={radius}
        fill="none"
        stroke={color}
        strokeWidth="20"
        strokeDasharray={`${dash} ${circumference}`}
        transform={`rotate(${angle} 50 50)`}
      />
    )
    angle += frac * 360
    return el
  })

  return (
    <svg viewBox="0 0 100 100" className="w-20 h-20 shrink-0">
      {circles}
      <circle cx={50} cy={50} r={24} fill="white" />
    </svg>
  )
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function Blockie({ address }: { address: string }) {
  const [src, setSrc] = useState('')

  if (!src) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const makeBlockie = require('ethereum-blockies-base64')
      setSrc(makeBlockie(address))
    } catch {}
  }

  if (!src) {
    return (
      <div className="w-10 h-10 rounded-full bg-neutral-400 flex items-center justify-center text-xs text-neutral-700 font-semibold shrink-0">
        {address.slice(2, 4).toUpperCase()}
      </div>
    )
  }
  return <img src={src} alt="blockie" className="w-10 h-10 rounded-full shrink-0" />
}


// ─── Supply vs borrow bar ─────────────────────────────────────────────────────

function SupplyBorrowBar({ supplyTotal, borrowTotal }: { supplyTotal: bigint; borrowTotal: bigint }) {
  const supply = Number(supplyTotal)
  const borrow = Number(borrowTotal)
  const total = supply + borrow
  if (total === 0) return null
  const supplyPct = (supply / total) * 100
  return (
    <div className="h-1 rounded-full bg-neutral-200 overflow-hidden">
      <div className="h-full flex">
        <div className="h-full bg-green-500 transition-all" style={{ width: `${supplyPct}%` }} />
        <div className="h-full bg-rose-500 flex-1" />
      </div>
    </div>
  )
}

// ─── Main component ───────────────────────────────────────────────────────────

interface ProfileHeaderProps {
  address: `0x${string}`
  navResults: ChainNav[]
  supplyTotal: bigint
  borrowTotal: bigint
}

export function ProfileHeader({ address, navResults, supplyTotal, borrowTotal }: ProfileHeaderProps) {
  const totalNav = navResults.reduce((sum, r) => sum + (r.nav?.value ?? 0n), 0n)
  const isLoading = navResults.some((r) => r.isLoading)

  const { data: ensName } = useEnsName({ address, chainId: 1 })

  return (
    <div className="py-6 border-b border-neutral-400">
      <div className="flex items-start justify-between gap-6">

        {/* Left: identity + NAV */}
        <div className="flex-1 min-w-0">
          {/* Address row */}
          <div className="flex items-center gap-2.5 mb-4">
            <Blockie address={address} />
            <div className="min-w-0">
              {ensName && (
                <p className="font-semibold text-neutral-950 text-sm leading-tight">{ensName}</p>
              )}
              {/* Account address: copy + one explorer link per chain it holds value on (mainnet while loading). */}
              <MultiChainAddressChip
                address={address}
                chainIds={isLoading ? [1] : navResults.filter((r) => r.nav && r.nav.value > 0n).map((r) => r.chainId)}
                className={`text-sm ${ensName ? 'text-neutral-700' : 'text-neutral-900 font-medium'}`}
              />
            </div>
          </div>

          {/* NAV */}
          <div className="mb-3">
            <p className="text-xs text-neutral-700 uppercase tracking-wider mb-1">Total Net Worth</p>
            {isLoading ? (
              <div className="h-10 w-44 bg-neutral-300 rounded animate-pulse" />
            ) : (
              <p className="text-4xl font-semibold tabular-nums text-neutral-950 tracking-tight">{formatUsd(totalNav)}</p>
            )}
          </div>

          {/* Supply / Borrow breakdown */}
          {!isLoading && (supplyTotal > 0n || borrowTotal > 0n) && (
            <div className="space-y-1.5">
              <div className="flex items-center gap-4 text-sm">
                <span className="text-green-700 font-medium">↑ Supply {formatUsd(supplyTotal)}</span>
                {borrowTotal > 0n && (
                  <span className="text-rose-700 font-medium">↓ Borrow {formatUsd(borrowTotal)}</span>
                )}
                {borrowTotal > 0n && (
                  <span className="text-neutral-700">Net {formatUsd(totalNav)}</span>
                )}
              </div>
              {borrowTotal > 0n && <SupplyBorrowBar supplyTotal={supplyTotal} borrowTotal={borrowTotal} />}
            </div>
          )}
        </div>

        {/* Right: donut chart */}
        <div className="shrink-0 flex flex-col items-center gap-2">
          <DonutChart navResults={navResults} />
          {!isLoading && (
            <div className="flex flex-col gap-0.5 text-right">
              {navResults.filter((r) => r.nav && r.nav.value > 0n).map((r) => (
                <div key={r.chainId} className="flex items-center gap-1.5 justify-end">
                  <span className="text-[10px] text-neutral-700">{r.label}</span>
                  <div className="w-2 h-2 rounded-full shrink-0" style={{ backgroundColor: CHAIN_COLORS[r.chainId] }} />
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
