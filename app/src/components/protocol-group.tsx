'use client'

import { Fragment } from 'react'
import type { OnchainPosition } from '@/hooks/use-account-positions'
import { TokenLogo } from '@/components/token-logo'
import { formatAmount, formatPrice, formatUsd } from '@/lib/format'
import { formatUnits } from 'viem'
import {
  EthCircleColor,
  OpCircleColor,
  GnosisCircleColor,
  ArbitrumCircleColor,
  BaseCircleColor,
  AaveCircleColor,
  MorphoCircleColor,
  CurveCircleColor,
  BalancerCircleColor,
  UniCircleColor,
  SkyCircleColor,
  SparkCircleColor,
  GearboxCircleColor,
} from '@karpatkey/design-system'

const CHAIN_ICONS: Record<number, React.ComponentType<{ className?: string }>> = {
  1: EthCircleColor,
  10: OpCircleColor,
  100: GnosisCircleColor,
  42161: ArbitrumCircleColor,
  8453: BaseCircleColor,
}

const PROTOCOL_ICONS: Record<string, React.ComponentType<{ className?: string }>> = {
  aave: AaveCircleColor,
  morpho: MorphoCircleColor,
  curve: CurveCircleColor,
  balancer: BalancerCircleColor,
  uniswap: UniCircleColor,
  sky: SkyCircleColor,
  spark: SparkCircleColor,
  gearbox: GearboxCircleColor,
}

const PROTOCOL_URLS: Record<string, string> = {
  aave: 'https://app.aave.com/',
  morpho: 'https://app.morpho.org/',
  balancer: 'https://balancer.fi/',
  uniswap: 'https://app.uniswap.org/',
  curve: 'https://curve.fi/',
  sky: 'https://sky.money/',
  spark: 'https://spark.fi/',
  gearbox: 'https://app.gearbox.fi/',
}

function getProtocolKey(protocol: string): string {
  return protocol.toLowerCase().replace(/[\s_-]/g, '')
}

function getProtocolIcon(protocol: string): React.ComponentType<{ className?: string }> | null {
  const key = getProtocolKey(protocol)
  for (const [k, Icon] of Object.entries(PROTOCOL_ICONS)) {
    if (key.includes(k)) return Icon
  }
  return null
}

function getProtocolUrl(protocol: string): string | null {
  const key = getProtocolKey(protocol)
  for (const [k, url] of Object.entries(PROTOCOL_URLS)) {
    if (key.includes(k)) return url
  }
  return null
}

function WalletIcon() {
  return (
    <svg className="w-6 h-6 text-neutral-500 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 12V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2h14a2 2 0 002-2v-2" />
      <path d="M16 12h5v4h-5a2 2 0 010-4z" />
      <circle cx="16" cy="14" r="0.75" fill="currentColor" stroke="none" />
    </svg>
  )
}

function ProtocolIcon({ protocol }: { protocol: string }) {
  if (protocol.toLowerCase() === 'wallet') return <WalletIcon />
  const Icon = getProtocolIcon(protocol)
  if (Icon) return <Icon className="w-6 h-6" />
  return (
    <div className="w-6 h-6 rounded-full bg-neutral-300 flex items-center justify-center text-[10px] font-semibold text-neutral-700 shrink-0">
      {protocol.slice(0, 2).toUpperCase()}
    </div>
  )
}

function pctOfPortfolio(value: bigint, total: bigint): string {
  if (total === 0n || value === 0n) return ''
  const pct = (Number(value < 0n ? -value : value) / Number(total)) * 100
  if (pct < 0.05) return '<0.1%'
  return `${pct.toFixed(1)}%`
}

function PositionRow({ pos, chainId, totalPortfolioNav }: { pos: OnchainPosition; chainId: number; totalPortfolioNav: bigint }) {
  const pct = pctOfPortfolio(pos.value, totalPortfolioNav)
  return (
    <tr className="border-t border-neutral-200 hover:bg-neutral-50 transition-colors">
      <td className="py-2.5 px-4 text-sm font-medium text-neutral-950">
        <div className="flex items-center gap-1.5">
          <TokenLogo symbol={pos.underlyingAsset.symbol} address={pos.underlyingAsset.asset} chainId={chainId} />
          {pos.underlyingAsset.symbol}
        </div>
      </td>
      <td className="py-2.5 px-4 text-sm text-right tabular-nums text-neutral-700">
        {formatAmount(pos.amount, pos.underlyingAsset.decimals, pos.underlyingAsset.symbol)}
      </td>
      <td className="py-2.5 px-4 text-sm text-right tabular-nums text-neutral-500">
        {formatPrice(pos.price, pos.priceDecimals)}
      </td>
      <td className={`py-2.5 px-4 text-sm text-right tabular-nums font-semibold ${pos.isDebt ? 'text-rose-700' : 'text-neutral-950'}`}>
        {formatUsd(pos.value)}
        {pos.stale && <span className="ml-1 text-orange-600 text-xs">⚠</span>}
      </td>
      <td className="py-2.5 px-4 text-xs text-right tabular-nums text-neutral-400">
        {pct}
      </td>
    </tr>
  )
}

/// Extract a pool / market / vault display name from an adapter's positionDetail JSON.
/// positionDetail follows the convention defined in `script/config/adapter-identities.json`
/// — JSON-shaped, with a discriminator key whose name varies per protocol:
///   - `pool`   — Uniswap V2/V3, PancakeSwap V2/V3, Balancer V3, Curve
///   - `market` — Aave V3/V2, Compound V3, Spark, Morpho Markets
///   - `vault`  — Morpho Vaults, ERC-4626 wrappers, StakeWise V3 Vaults
///   - `name`   — Uniswap V3 in `chains/*.json` uses `"name": "WBTC/WETH 0.3%"` as the canonical
///                label, and several other adapters mirror this. Check this last to prefer the
///                protocol-specific key when both are present.
///   - `product`, `gauge`, `feed` — long-tail fallbacks for protocol-specific shapes.
/// The closing `}` may or may not be present (the adapter appends a `type` suffix at emit time;
/// gracefully handle either form).
function extractPoolLabel(positionDetail: string): string | null {
  if (!positionDetail) return null
  let text = positionDetail.trim()
  if (!text.endsWith('}')) text += '}'
  try {
    const obj = JSON.parse(text) as Record<string, unknown>
    const candidate = (obj.pool ?? obj.market ?? obj.vault ?? obj.name ?? obj.product ?? obj.gauge ?? obj.feed) as
      | string
      | undefined
    return typeof candidate === 'string' && candidate.length > 0 ? candidate : null
  } catch {
    return null
  }
}

function groupByOracle(positions: OnchainPosition[]): Map<string, OnchainPosition[]> {
  const groups = new Map<string, OnchainPosition[]>()
  for (const pos of positions) {
    const key = pos.balanceOracle.toLowerCase()
    const bucket = groups.get(key)
    if (bucket) bucket.push(pos)
    else groups.set(key, [pos])
  }
  return groups
}

/// Extract the `type` discriminator from a positionDetail JSON — `Supply` / `Borrow` /
/// `Collateral` / `Staking` / `Rewards` / `Fees` per `src/utils/PositionType.sol`. Adapters
/// that don't multi-leg their output simply omit `type` from positionDetail, in which case
/// we keep the entry in a single un-typed bucket and render flat (no inner sub-header).
function extractType(positionDetail: string): string | null {
  if (!positionDetail) return null
  let text = positionDetail.trim()
  if (!text.endsWith('}')) text += '}'
  try {
    const obj = JSON.parse(text) as Record<string, unknown>
    const t = obj.type as string | undefined
    return typeof t === 'string' && t.length > 0 ? t : null
  } catch {
    return null
  }
}

/// Group a pool's positions by the `type` discriminator in `positionDetail`, preserving the
/// adapter's emission order (which is meaningful — Uniswap V3 emits Supply legs before Fees
/// legs; Curve/Aura emit Supply → Staking → Rewards). Untyped entries collapse to a single
/// `null` bucket.
function groupByType(positions: OnchainPosition[]): Array<{ type: string | null; positions: OnchainPosition[] }> {
  const groups: Array<{ type: string | null; positions: OnchainPosition[] }> = []
  const indexByType = new Map<string | null, number>()
  for (const pos of positions) {
    const type = extractType(pos.positionDetail)
    const idx = indexByType.get(type)
    if (idx !== undefined) {
      groups[idx].positions.push(pos)
    } else {
      indexByType.set(type, groups.length)
      groups.push({ type, positions: [pos] })
    }
  }
  return groups
}

function PoolSubHeader({ label, total, isDebt }: { label: string; total: bigint; isDebt: boolean }) {
  return (
    <tr>
      <td colSpan={5} className="p-0">
        <div className="pl-9 pr-4 py-1 bg-neutral-50/60 border-t border-neutral-100 flex items-center justify-between">
          <span className="text-[11px] font-medium uppercase tracking-wide text-neutral-500">{label}</span>
          <span className={`text-[11px] tabular-nums font-medium ${isDebt ? 'text-rose-700' : 'text-neutral-600'}`}>
            {formatUsd(total)}
          </span>
        </div>
      </td>
    </tr>
  )
}

function TypeSubHeader({ label, total, isDebt }: { label: string; total: bigint; isDebt: boolean }) {
  return (
    <tr>
      <td colSpan={5} className="p-0">
        <div className="pl-14 pr-4 py-0.5 flex items-center justify-between">
          <span className="text-[10px] font-medium uppercase tracking-wider text-neutral-400">{label}</span>
          <span className={`text-[10px] tabular-nums ${isDebt ? 'text-rose-700' : 'text-neutral-500'}`}>
            {formatUsd(total)}
          </span>
        </div>
      </td>
    </tr>
  )
}

function PositionSection({
  label,
  positions,
  total,
  isDebt,
  chainId,
  totalPortfolioNav,
}: {
  label: string
  positions: OnchainPosition[]
  total: bigint
  isDebt: boolean
  chainId: number
  totalPortfolioNav: bigint
}) {
  if (positions.length === 0) return null

  const oracleGroups = groupByOracle(positions)

  return (
    <>
      <tr>
        <td colSpan={5} className="p-0">
          <div className={`px-4 py-2 border-l-4 flex items-center justify-between ${
            isDebt ? 'border-rose-500 bg-rose-50' : 'border-green-500 bg-green-50'
          }`}>
            <span className={`text-xs font-semibold uppercase tracking-wider flex items-center gap-1.5 ${isDebt ? 'text-rose-700' : 'text-green-700'}`}>
              <span>{isDebt ? '↓' : '↑'}</span>
              {label}
            </span>
            <span className={`text-xs tabular-nums font-semibold ${isDebt ? 'text-rose-700' : 'text-green-700'}`}>
              {formatUsd(total)}
            </span>
          </div>
        </td>
      </tr>
      {Array.from(oracleGroups.entries()).map(([oracle, group]) => {
        const subTotal = group.reduce((s, p) => s + p.value, 0n)
        const poolLabel = extractPoolLabel(group[0].positionDetail) ?? `Pool ${oracle.slice(0, 6)}…${oracle.slice(-4)}`
        const typeGroups = groupByType(group)
        // Render an inner type sub-header (Supply / Fees / Staking / Rewards / …) only when
        // the pool's entries actually carry >1 distinct `type` discriminator. Single-type
        // pools (most non-V3 cases) stay flat under the pool sub-header so we don't add
        // redundant labels like "Supply" inside an already-Supply section.
        const renderTypeSubHeaders =
          typeGroups.length > 1 && typeGroups.some((tg) => tg.type !== null)
        return (
          <Fragment key={oracle}>
            <PoolSubHeader label={poolLabel} total={subTotal} isDebt={isDebt} />
            {renderTypeSubHeaders
              ? typeGroups.map((tg, ti) => {
                  const typeTotal = tg.positions.reduce((s, p) => s + p.value, 0n)
                  const typeLabel = tg.type ?? 'Other'
                  return (
                    <Fragment key={`${oracle}-${ti}`}>
                      <TypeSubHeader label={typeLabel} total={typeTotal} isDebt={isDebt} />
                      {tg.positions.map((pos, i) => (
                        <PositionRow
                          key={`${oracle}-${ti}-${i}`}
                          pos={pos}
                          chainId={chainId}
                          totalPortfolioNav={totalPortfolioNav}
                        />
                      ))}
                    </Fragment>
                  )
                })
              : group.map((pos, i) => (
                  <PositionRow key={`${oracle}-${i}`} pos={pos} chainId={chainId} totalPortfolioNav={totalPortfolioNav} />
                ))}
          </Fragment>
        )
      })}
    </>
  )
}

export type ProtocolGroupData = {
  protocol: string
  chainId: number
  supply: OnchainPosition[]
  borrow: OnchainPosition[]
  totalValue: bigint
}

interface ProtocolGroupProps {
  group: ProtocolGroupData
  totalPortfolioNav: bigint
}

export function ProtocolGroup({ group, totalPortfolioNav }: ProtocolGroupProps) {
  const { protocol, chainId, supply, borrow, totalValue } = group

  const supplyTotal = supply.reduce((s, p) => s + p.value, 0n)
  const borrowTotal = borrow.reduce((s, p) => s + p.value, 0n)
  const ChainIcon = CHAIN_ICONS[chainId]
  const protocolUrl = getProtocolUrl(protocol)
  const groupPct = pctOfPortfolio(totalValue, totalPortfolioNav)

  return (
    <div className="rounded-xl border border-neutral-400 bg-white overflow-hidden mb-3 shadow-[var(--shadow-1)]">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-300">
        <div className="flex items-center gap-2.5">
          <ProtocolIcon protocol={protocol} />
          {protocolUrl ? (
            <a
              href={protocolUrl}
              target="_blank"
              rel="noreferrer"
              className="font-semibold text-sm capitalize text-neutral-950 hover:underline"
            >
              {protocol === 'wallet' ? 'Wallet' : protocol}
            </a>
          ) : (
            <span className="font-semibold text-sm capitalize text-neutral-950">
              {protocol === 'wallet' ? 'Wallet' : protocol}
            </span>
          )}
          {ChainIcon && (
            <span className="flex items-center bg-neutral-100 rounded-full px-1.5 py-0.5">
              <ChainIcon className="w-3.5 h-3.5" />
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {groupPct && <span className="text-xs text-neutral-400">{groupPct}</span>}
          <span className="tabular-nums font-semibold text-sm text-neutral-950">{formatUsd(totalValue)}</span>
        </div>
      </div>

      {/* Positions table — no repeated column headers */}
      <table className="w-full">
        <tbody>
          <PositionSection label="Supply" positions={supply} total={supplyTotal} isDebt={false} chainId={chainId} totalPortfolioNav={totalPortfolioNav} />
          <PositionSection label="Borrow" positions={borrow} total={borrowTotal} isDebt={true} chainId={chainId} totalPortfolioNav={totalPortfolioNav} />
        </tbody>
      </table>
    </div>
  )
}
