'use client'

import { Fragment, useState } from 'react'
import {
  Badge,
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
import type { ChainCoverage, ProtocolCoverage, CoverageAsset } from '@/hooks/use-coverage'
import { TokenLogo } from '@/components/token-logo'
import { AddressChip } from '@/components/address-chip'

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

function WalletIcon() {
  return (
    <svg
      className="w-6 h-6 text-neutral-700 shrink-0"
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

function ProtocolIcon({ brandKey, displayName }: { brandKey: string; displayName: string }) {
  if (normalize(brandKey) === 'wallet') return <WalletIcon />
  const Icon = iconComponentFor(brandKey)
  if (Icon) return <Icon className="w-6 h-6" />
  const imgUrl = imgIconFor(brandKey)
  // biome-ignore lint/performance/noImgElement: dev dashboard, CDN logo, no Next image optimization needed
  if (imgUrl) return <img src={imgUrl} alt={displayName} className="w-6 h-6 rounded-full shrink-0" />
  return (
    <div className="w-6 h-6 rounded-full bg-neutral-300 flex items-center justify-center text-[10px] font-semibold text-neutral-700 shrink-0">
      {displayName.slice(0, 2).toUpperCase()}
    </div>
  )
}

// --- overlapping asset logos (parent-row summary) ----------------------------

const MAX_LOGOS = 6

function AssetLogoStack({ assets, chainId }: { assets: CoverageAsset[]; chainId: number }) {
  if (assets.length === 0) return null
  const shown = assets.slice(0, MAX_LOGOS)
  const overflow = assets.length - shown.length
  return (
    <div className="flex items-center">
      <div className="flex items-center -space-x-1.5">
        {shown.map((a) => (
          <span key={a.address} className="ring-2 ring-white rounded-full">
            <Tooltip>
              <TooltipTrigger asChild>
                <span className="inline-flex">
                  <TokenLogo symbol={a.symbol} address={a.address} chainId={chainId} className="w-5 h-5" />
                </span>
              </TooltipTrigger>
              <TooltipContent>{a.symbol}</TooltipContent>
            </Tooltip>
          </span>
        ))}
      </div>
      {overflow > 0 && (
        <span className="ml-1.5 text-xs font-medium text-neutral-700 tabular-nums">+{overflow}</span>
      )}
    </div>
  )
}

// A protocol's summary line: "N products · M markets · K assets" (only the parts that are > 0).
function summaryText(p: ProtocolCoverage): string {
  const parts: string[] = []
  if (p.adapters.length > 0)
    parts.push(`${p.adapters.length} ${p.adapters.length === 1 ? 'product' : 'products'}`)
  if (p.instanceCount > 0)
    parts.push(`${p.instanceCount} ${p.instanceCount === 1 ? 'market/vault' : 'markets/vaults'}`)
  if (p.assetCount > 0) parts.push(`${p.assetCount} ${p.assetCount === 1 ? 'asset' : 'assets'}`)
  return parts.join(' · ')
}

// --- child (adapter/product) row ---------------------------------------------

function AdapterRow({
  adapter,
  chainId,
  isLast,
}: {
  adapter: ProtocolCoverage['adapters'][number]
  chainId: number
  isLast: boolean
}) {
  return (
    <div className="flex items-start gap-3 py-2.5 pl-6 pr-3">
      <span className="text-neutral-400 select-none leading-6" aria-hidden>
        {isLast ? '└' : '├'}
      </span>
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-medium text-neutral-950">{adapter.protocolName}</span>
          {adapter.isMeta ? (
            <Tooltip>
              <TooltipTrigger asChild>
                <Badge variant="generic" className="text-xs bg-violet-100 text-violet-700 cursor-default">
                  Meta · {adapter.instanceCount} {adapter.instanceCount === 1 ? 'market' : 'markets'}
                </Badge>
              </TooltipTrigger>
              <TooltipContent className="max-w-xs">
                Multi-instance adapter — one immutable contract values every registered instance
                (markets / vaults / pools). Instances are governed on NAVCalculator.
              </TooltipContent>
            </Tooltip>
          ) : (
            <Badge variant="generic" className="text-xs">
              Direct
            </Badge>
          )}
          <AddressChip address={adapter.address} chainId={chainId} className="text-xs text-neutral-700" />
        </div>
        {adapter.assets.length > 0 && (
          <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
            {adapter.assets.map((a) => (
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
      </div>
    </div>
  )
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
  const displayed = q ? protocols.filter((p) => p.displayName.toLowerCase().includes(q)) : protocols

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
            <button
              type="button"
              onClick={() => toggle(p.brandKey)}
              className="w-full flex items-center gap-3 px-3 py-3 text-left bg-white hover:bg-neutral-50 transition-colors"
            >
              <span className="text-neutral-500 w-3 inline-block select-none shrink-0" aria-hidden>
                {isCollapsed ? '▸' : '▾'}
              </span>
              <ProtocolIcon brandKey={p.brandKey} displayName={p.displayName} />
              <div className="min-w-0 flex-1">
                <div className="font-semibold text-neutral-950 truncate">{p.displayName}</div>
                <div className="text-xs text-neutral-700">{summaryText(p)}</div>
              </div>
              <AssetLogoStack
                assets={Array.from(
                  new Map(
                    p.adapters.flatMap((a) => a.assets).map((a) => [a.address.toLowerCase(), a]),
                  ).values(),
                )}
                chainId={chainId}
              />
            </button>

            {/* Child adapter rows */}
            {!isCollapsed && (
              <div className="bg-neutral-50/60 divide-y divide-neutral-100">
                {p.adapters.map((adapter, ai) => (
                  <AdapterRow
                    key={adapter.address}
                    adapter={adapter}
                    chainId={chainId}
                    isLast={ai === p.adapters.length - 1}
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
