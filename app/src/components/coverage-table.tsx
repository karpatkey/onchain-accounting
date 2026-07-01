'use client'

import { Fragment, useState } from 'react'
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  Skeleton,
  AaveCircleColor,
  MorphoCircleColor,
  CurveCircleColor,
  BalancerCircleColor,
  UniCircleColor,
  SkyCircleColor,
  SparkCircleColor,
  GearboxCircleColor,
  EulerCircleColor,
} from '@karpatkey/design-system'
import type {
  ChainCoverage,
  ProtocolCoverage,
  CoverageProduct,
  CoverageInstance,
} from '@/hooks/use-coverage'
import { TokenLogo } from '@/components/token-logo'
import { AddressChip } from '@/components/address-chip'
import { explorerAddressUrl } from '@/config/chains'

// --- protocol icons (keyed by brandKey / normalised name) --------------------
// Replicated from the portfolio ProtocolGroup lookup: design-system CircleColor icons where they
// exist, else a CDN image, else a neutral monogram fallback. Keys are matched as substrings of the
// normalised brand key so "aaveumbrella" still resolves to the Aave icon.

const PROTOCOL_ICONS: Record<string, React.ComponentType<{ className?: string }>> = {
  aave: AaveCircleColor,
  morpho: MorphoCircleColor,
  curve: CurveCircleColor,
  balancer: BalancerCircleColor,
  uniswap: UniCircleColor,
  sky: SkyCircleColor,
  spark: SparkCircleColor,
  gearbox: GearboxCircleColor,
  euler: EulerCircleColor,
}

const PROTOCOL_IMG_ICONS: Record<string, string> = {
  pancakeswap: 'https://assets.coingecko.com/coins/images/12632/large/pancakeswap-cake-logo_(1).png',
  ethena:
    'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0x4c9EDD5852cd905f086C759E8383e09bff1E68B3/logo.png',
  etherfi: 'https://icons.llamao.fi/icons/protocols/ether.fi?w=48&h=48',
  stakewise: 'https://icons.llamao.fi/icons/protocols/stakewise?w=48&h=48',
  nexus: 'https://icons.llamao.fi/icons/protocols/nexus-mutual?w=48&h=48',
  lido: 'https://icons.llamao.fi/icons/protocols/lido?w=48&h=48',
  kelp: 'https://icons.llamao.fi/icons/protocols/kelp-dao?w=48&h=48',
  stader: 'https://icons.llamao.fi/icons/protocols/stader?w=48&h=48',
  convex: 'https://icons.llamao.fi/icons/protocols/convex-finance?w=48&h=48',
  fluid: 'https://icons.llamao.fi/icons/protocols/fluid?w=48&h=48',
  compound: 'https://icons.llamao.fi/icons/protocols/compound-finance?w=48&h=48',
  merkl: 'https://icons.llamao.fi/icons/protocols/merkl?w=48&h=48',
  cap: 'https://icons.llamao.fi/icons/protocols/cap?w=48&h=48',
}

function normalize(brandKey: string): string {
  return brandKey.toLowerCase().replace(/[\s_.-]/g, '')
}

function iconComponentFor(brandKey: string): React.ComponentType<{ className?: string }> | null {
  const key = normalize(brandKey)
  for (const [k, Icon] of Object.entries(PROTOCOL_ICONS)) {
    if (key.includes(k)) return Icon
  }
  return null
}

function imgIconFor(brandKey: string): string | null {
  const key = normalize(brandKey)
  for (const [k, url] of Object.entries(PROTOCOL_IMG_ICONS)) {
    if (key.includes(k)) return url
  }
  return null
}

function WalletIcon({ size = 'w-6 h-6' }: { size?: string }) {
  return (
    <svg
      className={`${size} text-neutral-700 shrink-0`}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M21 12V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2h14a2 2 0 002-2v-2" />
      <path d="M16 12h5v4h-5a2 2 0 010-4z" />
      <circle cx="16" cy="14" r="0.75" fill="currentColor" stroke="none" />
    </svg>
  )
}

function ProtocolIcon({
  brandKey,
  displayName,
  size = 'w-6 h-6',
}: {
  brandKey: string
  displayName: string
  size?: string
}) {
  if (normalize(brandKey) === 'wallet') return <WalletIcon size={size} />
  const Icon = iconComponentFor(brandKey)
  if (Icon) return <Icon className={size} />
  const imgUrl = imgIconFor(brandKey)
  // biome-ignore lint/performance/noImgElement: dev dashboard, CDN logo, no Next image optimization needed
  if (imgUrl) return <img src={imgUrl} alt={displayName} className={`${size} rounded-full shrink-0`} />
  return (
    <div
      className={`${size} rounded-full bg-neutral-300 flex items-center justify-center text-[9px] font-semibold text-neutral-700 shrink-0`}
    >
      {displayName.slice(0, 2).toUpperCase()}
    </div>
  )
}

// Protocol app deep-links per instance. Baseline = the protocol's app landing (passed in); Morpho gets a
// true market/vault deep-link built from the instance coordinate. Extend per-protocol as needed.
const CHAIN_SLUG: Record<number, string> = {
  1: 'ethereum',
  10: 'optimism',
  100: 'gnosis',
  42161: 'arbitrum',
  8453: 'base',
}

function instanceAppUrl(
  brandKey: string,
  instance: CoverageInstance,
  chainId: number,
  protocolUrl: string | null,
): string | null {
  const slug = CHAIN_SLUG[chainId]
  if (brandKey === 'morpho' && slug) {
    // Morpho market ids are raw 32-byte hashes (no address); vaults are addresses.
    if (!instance.address) return `https://app.morpho.org/${slug}/market/${instance.id}`
    return `https://app.morpho.org/${slug}/vault/${instance.address}`
  }
  return protocolUrl
}

// Small "i" info affordance with a hover tooltip — explains a product / category inline (replaces the
// old adapter-type badge).
function InfoTip({ children }: { children: React.ReactNode }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <span
          className="inline-flex h-3.5 w-3.5 shrink-0 cursor-default items-center justify-center rounded-full border border-neutral-400 text-[9px] font-semibold text-neutral-600"
          aria-label="More info"
        >
          i
        </span>
      </TooltipTrigger>
      <TooltipContent className="max-w-xs">{children}</TooltipContent>
    </Tooltip>
  )
}

// A protocol's summary line: "N products · M markets/pools/vaults" (only the parts that are > 0). No token
// stack in the header — the specific markets/pools live in the tree below.
function summaryText(p: ProtocolCoverage): string {
  const parts: string[] = []
  if (p.productCount > 0)
    parts.push(`${p.productCount} ${p.productCount === 1 ? 'product' : 'products'}`)
  if (p.instanceCount > 0) {
    // Prefer the shared instance category for a natural noun ("markets", "pools", "vaults", "gauges").
    const noun = instanceNoun(p)
    parts.push(`${p.instanceCount} ${noun}`)
  }
  return parts.join(' · ')
}

// Derive a lowercase plural noun for a protocol's instances from their on-chain category. Falls back to
// the generic "markets/pools/vaults" when a protocol mixes categories or exposes none.
function instanceNoun(p: ProtocolCoverage): string {
  const cats = new Set(
    p.products.filter((pr) => pr.isMeta && pr.category).map((pr) => (pr.category as string).toLowerCase()),
  )
  if (cats.size === 1) {
    const cat = [...cats][0]
    if (cat.includes('gauge')) return p.instanceCount === 1 ? 'gauge' : 'gauges'
    if (cat.includes('vault')) return p.instanceCount === 1 ? 'vault' : 'vaults'
    if (cat.includes('pool')) return p.instanceCount === 1 ? 'pool' : 'pools'
    if (cat.includes('market')) return p.instanceCount === 1 ? 'market' : 'markets'
  }
  return p.instanceCount === 1 ? 'market/pool/vault' : 'markets/pools/vaults'
}

// A small external-link glyph (matches the AddressChip icon set; the design-system <Launch> renders
// oversized here, so we use the same inline SVG the chip uses, at a fixed 14px).
function ExtLinkIcon({ href, title }: { href: string; title: string }) {
  if (!/^https:\/\//.test(href)) return null
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      title={title}
      onClick={(e) => e.stopPropagation()}
      className="shrink-0 cursor-pointer p-1 text-neutral-600 hover:text-neutral-900 hover:bg-neutral-200 transition-colors rounded"
    >
      <svg className="w-3.5 h-3.5" viewBox="0 0 12 12" fill="none" aria-hidden="true">
        <path d="M5 2H2a1 1 0 00-1 1v7a1 1 0 001 1h7a1 1 0 001-1V8" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
        <path d="M8 1h3v3M7 5l4-4" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </a>
  )
}

// --- instance (leaf) sub-row ------------------------------------------------

function InstanceRow({
  instance,
  brandKey,
  displayName,
  protocolUrl,
  chainId,
  isLast,
}: {
  instance: CoverageInstance
  brandKey: string
  displayName: string
  protocolUrl: string | null
  chainId: number
  isLast: boolean
}) {
  const appUrl = instanceAppUrl(brandKey, instance, chainId, protocolUrl)
  return (
    <div className="flex items-center gap-2 py-1.5 pl-12 pr-3">
      <span className="text-neutral-400 select-none leading-5" aria-hidden>
        {isLast ? '└' : '├'}
      </span>
      {/* Leading icon: the instance's underlying tokens (a pool/vault's assets), else the protocol icon. */}
      {instance.tokens.length > 0 ? (
        <span className="flex items-center -space-x-1 shrink-0">
          {instance.tokens.slice(0, 3).map((t, i) => (
            <TokenLogo
              key={`${t.address}-${i}`}
              symbol={t.symbol}
              address={t.address}
              chainId={chainId}
              className="w-4 h-4 rounded-full ring-1 ring-white"
            />
          ))}
        </span>
      ) : (
        <ProtocolIcon brandKey={brandKey} displayName={displayName} size="w-4 h-4" />
      )}
      <span className="text-sm text-neutral-800 truncate">{instance.name}</span>
      {/* App link (protocol app / market page) then explorer link — separate from the name. */}
      {appUrl && <ExtLinkIcon href={appUrl} title={`Open in ${displayName}`} />}
      {instance.address && (
        <AddressChip address={instance.address} chainId={chainId} className="text-[11px] text-neutral-600" />
      )}
    </div>
  )
}

// --- product row -------------------------------------------------------------

function ProductRow({
  product,
  brandKey,
  displayName,
  protocolUrl,
  chainId,
  isLast,
}: {
  product: CoverageProduct
  brandKey: string
  displayName: string
  protocolUrl: string | null
  chainId: number
  isLast: boolean
}) {
  // Show underlying-token chips only where the tokens ARE the coverage: wallet holdings and staking
  // modules (Safety Module / Umbrella). For queues / cooldowns / rewards / lending markets the feature
  // label is the point — the token wall is noise (per product guidance). The wallet lists ALL its tokens
  // (that IS the "tokens we track directly" statement); staking modules are short, so no cap needed there.
  const isWallet = /^wallet/i.test(product.productLabel)
  const showsTokens = !product.isMeta && (isWallet || /^(safety module|umbrella)/i.test(product.productLabel))
  const shownAssets = showsTokens ? product.assets : []

  return (
    <div className="flex items-start gap-3 py-2.5 pl-6 pr-3">
      <span className="text-neutral-400 select-none leading-6" aria-hidden>
        {isLast ? '└' : '├'}
      </span>
      {/* Leading product icon — the protocol mark (keeps every position visually anchored). */}
      <span className="mt-0.5 shrink-0">
        <ProtocolIcon brandKey={brandKey} displayName={displayName} size="w-4 h-4" />
      </span>
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-medium text-neutral-950">{product.productLabel}</span>
          {/* The specific token/name below the feature (e.g. "Withdrawal Queue · stETH"), muted. */}
          {product.detail && <span className="text-xs text-neutral-600">· {product.detail}</span>}
          {product.isMeta && (
            <>
              <span className="text-xs text-neutral-600 tabular-nums">{product.instances.length}</span>
              {product.category && (
                <InfoTip>
                  {`One immutable meta-adapter values every registered ${product.category.toLowerCase()} listed below — added or removed by config, not redeploy.`}
                </InfoTip>
              )}
            </>
          )}
          {/* Link to the product in the protocol's app, then the adapter address (the on-chain audit
              trail / balanceAdapter, explorer-linked) — split so the app link and the contract are distinct. */}
          {protocolUrl && <ExtLinkIcon href={protocolUrl} title={`Open in ${displayName}`} />}
          <AddressChip address={product.adapter} chainId={chainId} className="text-xs text-neutral-600" />
        </div>

        {/* Wallet / staking leaf: the underlying-asset chips (they ARE the coverage here). */}
        {shownAssets.length > 0 && (
          <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
            {shownAssets.map((a) => (
              <span
                key={a.address}
                className="inline-flex items-center gap-1 rounded-full bg-neutral-100 border border-neutral-200 pl-1 pr-2 py-0.5"
              >
                <TokenLogo symbol={a.symbol} address={a.address} chainId={chainId} className="w-4 h-4" />
                <span className="text-[11px] font-medium text-neutral-800">{a.symbol}</span>
              </span>
            ))}
          </div>
        )}

        {/* Meta product: its instances (markets / pools / vaults / gauges) as deeper sub-rows. */}
        {product.isMeta && product.instances.length > 0 && (
          <div className="mt-1">
            {product.instances.map((inst, ii) => (
              <InstanceRow
                key={inst.id}
                instance={inst}
                brandKey={brandKey}
                displayName={displayName}
                protocolUrl={protocolUrl}
                chainId={chainId}
                isLast={ii === product.instances.length - 1}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

// --- filtering ---------------------------------------------------------------

/// Match a protocol against a search query — by display name, or by any product / instance name. Returns a
/// filtered protocol (products narrowed to matching ones when the match is on a product/instance) or null.
function filterProtocol(p: ProtocolCoverage, q: string): ProtocolCoverage | null {
  if (!q) return p
  if (p.displayName.toLowerCase().includes(q)) return p
  const products = p.products.filter(
    (pr) =>
      pr.productLabel.toLowerCase().includes(q) ||
      (pr.category?.toLowerCase().includes(q) ?? false) ||
      pr.instances.some((i) => i.name.toLowerCase().includes(q)) ||
      pr.assets.some((a) => a.symbol.toLowerCase().includes(q)),
  )
  if (products.length === 0) return null
  return { ...p, products }
}

// --- component ---------------------------------------------------------------

interface CoverageTableProps {
  data: ChainCoverage
  searchQuery?: string
}

export function CoverageTable({ data, searchQuery = '' }: CoverageTableProps) {
  const { protocols, isLoading, isError, chainId } = data
  // Collapsed set — default expanded so the coverage tree is visible at a glance. Keyed by brandKey.
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())

  function toggle(key: string) {
    setCollapsed((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  if (isLoading) {
    return (
      <div className="space-y-2">
        {Array.from({ length: 5 }).map((_, i) => (
          <Skeleton key={i} className="h-12 w-full" />
        ))}
      </div>
    )
  }

  if (isError) return <p className="text-sm text-destructive py-4">Failed to load coverage.</p>
  if (protocols.length === 0)
    return <p className="text-sm text-neutral-700 py-4">No adapters registered on this chain yet.</p>

  const q = searchQuery.trim().toLowerCase()
  const displayed = q
    ? protocols.map((p) => filterProtocol(p, q)).filter((p): p is ProtocolCoverage => p !== null)
    : protocols

  if (displayed.length === 0) {
    return (
      <p className="text-sm text-neutral-700 py-6 text-center">
        No protocols matching &ldquo;{searchQuery.trim()}&rdquo;.
      </p>
    )
  }

  return (
    <div className="divide-y divide-neutral-200 rounded-lg border border-neutral-200 overflow-hidden">
      {displayed.map((p) => {
        const isCollapsed = collapsed.has(p.brandKey)
        return (
          <Fragment key={p.brandKey}>
            {/* Protocol parent row */}
            <div className="flex items-center gap-2 bg-white hover:bg-neutral-50 transition-colors">
              <button
                type="button"
                onClick={() => toggle(p.brandKey)}
                className="flex flex-1 items-center gap-3 px-3 py-3 text-left min-w-0"
              >
                <span className="text-neutral-500 w-3 inline-block select-none shrink-0" aria-hidden>
                  {isCollapsed ? '▸' : '▾'}
                </span>
                <ProtocolIcon brandKey={p.brandKey} displayName={p.displayName} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5">
                    <span className="font-semibold text-neutral-950 truncate">{p.displayName}</span>
                  </div>
                  <div className="text-xs text-neutral-700">{summaryText(p)}</div>
                </div>
              </button>
              {p.url && (
                <span className="mr-2 shrink-0">
                  <ExtLinkIcon href={p.url} title={`Open ${p.displayName}`} />
                </span>
              )}
            </div>

            {/* Child product rows */}
            {!isCollapsed && (
              <div className="bg-neutral-50/60 divide-y divide-neutral-100">
                {p.products.map((product, pi) => (
                  <ProductRow
                    key={product.adapter}
                    product={product}
                    brandKey={p.brandKey}
                    displayName={p.displayName}
                    protocolUrl={p.url}
                    chainId={chainId}
                    isLast={pi === p.products.length - 1}
                  />
                ))}
              </div>
            )}
          </Fragment>
        )
      })}
    </div>
  )
}
