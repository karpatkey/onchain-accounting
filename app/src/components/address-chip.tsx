'use client'

import { type ReactNode, useEffect, useRef, useState } from 'react'
import { DEPLOYED_CHAINS, EXPLORER_URLS, explorerAddressUrl } from '@/config/chains'

// chainId → { label, logoUrl } for the per-chain explorer icons in MultiChainAddressChip.
const CHAIN_META = new Map<number, { label: string; logoUrl: string }>(
  DEPLOYED_CHAINS.map((c) => [c.chain.id, { label: c.label, logoUrl: c.logoUrl }]),
)

// Address chip, ported from the kpk-agents client-portal (`address-chip.tsx`) so addresses render
// consistently across our apps: a truncated `0x1234…abcd` body (full value on hover + copy), an inline
// copy button, and — when the chain is known — an explorer link. Adapted to this app's `neutral-*`
// palette and `explorerAddressUrl` (the portal uses its own design-system tokens + chain registry).

const FULL_ADDR_RE = /^0x[0-9a-fA-F]{40}$/
const FULL_HASH_RE = /^0x[0-9a-fA-F]{64}$/

/// Canonical 20-byte address check, exported so callers can decide whether a value is explorer-linkable.
export function isFullAddress(value: string): boolean {
  return FULL_ADDR_RE.test(value)
}

/// Truncate to `0x` + first 4 + … + last 4 (address) or first 8 + … + last 8 (32-byte hash), lowercased.
/// Non-hex input is returned unchanged. Mirrors the portal's proportional rule so the two read alike.
function truncate(value: string): string {
  if (FULL_ADDR_RE.test(value)) return `0x${value.slice(2, 6).toLowerCase()}…${value.slice(-4).toLowerCase()}`
  if (FULL_HASH_RE.test(value)) return `0x${value.slice(2, 10).toLowerCase()}…${value.slice(-8).toLowerCase()}`
  return value
}

const ICON_CLASS = 'shrink-0 cursor-pointer p-0.5 text-neutral-700 hover:text-neutral-950 transition-colors rounded'

/// Inline copy button. A `role=button` span (not a `<button>`) so it can nest inside clickable rows/triggers
/// without invalid HTML. Clears any pending reset before scheduling a new one (rapid copies don't flip the
/// indicator back early) and on unmount.
export function CopyIconButton({ value, label = 'Copy address' }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current) }, [])

  function copy() {
    navigator.clipboard.writeText(value).catch(() => {})
    setCopied(true)
    if (timer.current) clearTimeout(timer.current)
    timer.current = setTimeout(() => setCopied(false), 1200)
  }

  return (
    <span
      role="button"
      tabIndex={0}
      onClick={(e) => { e.preventDefault(); e.stopPropagation(); copy() }}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          e.stopPropagation()
          copy()
        }
      }}
      title={copied ? 'Copied!' : label}
      aria-label={copied ? 'Copied!' : label}
      className={ICON_CLASS}
    >
      {copied ? (
        <svg className="w-3 h-3" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path d="M2 6l3 3 5-5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : (
        <svg className="w-3 h-3" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <rect x="4" y="4" width="7" height="7" rx="1" stroke="currentColor" strokeWidth="1.2" />
          <path d="M8 4V2a1 1 0 00-1-1H2a1 1 0 00-1 1v5a1 1 0 001 1h2" stroke="currentColor" strokeWidth="1.2" />
        </svg>
      )}
    </span>
  )
}

/// Explorer link. `<a>` keeps native navigation; stopPropagation prevents a wrapping clickable row from also firing.
/// Only render for absolute https URLs — the href is built from an address that originates as user/URL text,
/// so reject any non-https scheme (e.g. a `javascript:` URL) before it reaches the anchor sink. Explorer base
/// URLs are all https, so legitimate links are unaffected.
function ExplorerLink({ href, label = 'View on explorer' }: { href: string; label?: string }) {
  if (!/^https:\/\//.test(href)) return null
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      title={label}
      aria-label={label}
      onClick={(e) => e.stopPropagation()}
      className={ICON_CLASS}
    >
      <svg className="w-3 h-3" viewBox="0 0 12 12" fill="none" aria-hidden="true">
        <path d="M5 2H2a1 1 0 00-1 1v7a1 1 0 001 1h7a1 1 0 001-1V8" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
        <path d="M8 1h3v3M7 5l4-4" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </a>
  )
}

/// Truncated address/hash chip: `0x1234…abcd  [copy]  [explorer]`. Pass `chainId` to get an explorer link
/// (only rendered for 20-byte addresses on a known chain). `full` shows the untruncated value. `className`
/// sets the text size/colour of the body (icons keep their own muted styling).
export function AddressChip({
  address,
  chainId,
  full = false,
  className = '',
}: {
  address: string
  chainId?: number
  full?: boolean
  className?: string
}): ReactNode {
  const explorer =
    isFullAddress(address) && chainId !== undefined && EXPLORER_URLS[chainId]
      ? explorerAddressUrl(chainId, address)
      : null
  return (
    <span className={`inline-flex items-center gap-0.5 font-mono align-baseline ${className}`}>
      <span title={address}>{full ? address : truncate(address)}</span>
      <CopyIconButton value={address} />
      {explorer && <ExplorerLink href={explorer} />}
    </span>
  )
}

/// Address chip with one explorer link per chain — for a single address that exists on multiple chains
/// (e.g. a Safe/EOA queried across networks). Ported from the portal's MultiChainAddressChip: truncated body
/// + copy, then a `(chain-icon ↗)` pair per chainId, each pair tight (`gap-0.5`) and groups spaced (`gap-1.5`).
export function MultiChainAddressChip({
  address,
  chainIds,
  className = '',
}: {
  address: string
  chainIds: number[]
  className?: string
}): ReactNode {
  return (
    <span className={`inline-flex items-center gap-2 font-mono align-baseline ${className}`}>
      <span title={address}>{truncate(address)}</span>
      <CopyIconButton value={address} />
      {isFullAddress(address) && chainIds.length > 0 && (
        <span className="inline-flex items-center gap-1.5">
          {chainIds.map((cid) => {
            const base = EXPLORER_URLS[cid]
            if (!base) return null
            const meta = CHAIN_META.get(cid)
            return (
              <span key={cid} className="inline-flex items-center gap-0.5">
                {meta && (
                  <img src={meta.logoUrl} alt={meta.label} className="w-3.5 h-3.5 rounded-full shrink-0 object-cover" />
                )}
                <ExplorerLink href={`${base}/address/${address}`} label={`View on ${meta?.label ?? 'chain'} explorer`} />
              </span>
            )
          })}
        </span>
      )}
    </span>
  )
}
