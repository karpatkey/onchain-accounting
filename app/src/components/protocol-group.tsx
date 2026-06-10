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

// Protocols without a design-system CircleColor icon fall back to a CDN image keyed the same way.
const PROTOCOL_IMG_ICONS: Record<string, string> = {
  pancakeswap: 'https://assets.coingecko.com/coins/images/12632/large/pancakeswap-cake-logo_(1).png',
}

const PROTOCOL_URLS: Record<string, string> = {
  aave: 'https://app.aave.com/',
  pancakeswap: 'https://pancakeswap.finance/liquidity/positions',
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

function getProtocolImgIcon(protocol: string): string | null {
  const key = getProtocolKey(protocol)
  for (const [k, url] of Object.entries(PROTOCOL_IMG_ICONS)) {
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
  const imgUrl = getProtocolImgIcon(protocol)
  // biome-ignore lint/performance/noImgElement: dev dashboard, CDN logo, no Next image optimization needed
  if (imgUrl) return <img src={imgUrl} alt={protocol} className="w-6 h-6 rounded-full shrink-0" />
  return (
    <div className="w-6 h-6 rounded-full bg-neutral-300 flex items-center justify-center text-[10px] font-semibold text-neutral-700 shrink-0">
      {protocol.slice(0, 2).toUpperCase()}
    </div>
  )
}

function pctOfPortfolio(value: bigint, total: bigint): string {
  if (total === 0n || value === 0n) return ''
  // Signed share of NET NAV (total is the net NAV): debt is negative, so each position's % reflects its
  // real contribution to net worth and the percentages reconcile — a group's rows sum to its net %, and
  // all positions across the portfolio sum to ~100%. (Previously this used abs(value)/net, which didn't.)
  // Compute in bigint (NAV values can exceed 2^53, where Number() loses precision): signed basis points,
  // then a small Number for display. For the truncated-to-0bp case, take the sign from the ratio
  // value/total (negative iff value and total have opposite signs) so a tiny contribution still shows the
  // correct sign even when net NAV (total) is negative — not just the sign of `value`.
  const pct = Number((value * 10_000n) / total) / 100
  if (Math.abs(pct) < 0.05) return (value < 0n) !== (total < 0n) ? '-<0.1%' : '<0.1%'
  return `${pct.toFixed(1)}%`
}

/// Share of a position's own section total (a supply row vs total supply, a borrow row vs total borrow),
/// as a positive percentage — for composition *within* a protocol. Uses magnitudes so a debt row reads as a
/// positive share of the borrow section. Each section's rows sum to 100%. (The group header uses
/// pctOfPortfolio for the cross-protocol allocation view.)
function pctOfSection(value: bigint, sectionTotal: bigint): string {
  const v = value < 0n ? -value : value
  const t = sectionTotal < 0n ? -sectionTotal : sectionTotal
  if (t === 0n || v === 0n) return ''
  // bigint basis points (values can exceed 2^53), then a small Number for display.
  const pct = Number((v * 10_000n) / t) / 100
  if (pct < 0.05) return '<0.1%'
  return `${pct.toFixed(1)}%`
}

function PositionRow({ pos, chainId, sectionTotal }: { pos: OnchainPosition; chainId: number; sectionTotal: bigint }) {
  const pct = pctOfSection(pos.value, sectionTotal)
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
      <td className="py-2.5 px-4 text-sm text-right tabular-nums text-neutral-700">
        {formatPrice(pos.price, pos.priceDecimals)}
      </td>
      <td className={`py-2.5 px-4 text-sm text-right tabular-nums font-semibold ${pos.isDebt ? 'text-rose-700' : 'text-neutral-950'}`}>
        {formatUsd(pos.value)}
        {pos.stale && <span className="ml-1 text-orange-600 text-xs">⚠</span>}
      </td>
      <td className={`py-2.5 px-4 text-xs text-right tabular-nums font-medium ${pos.isDebt ? 'text-rose-700' : 'text-neutral-800'}`}>
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

/// Aave instances expose canonical getMarketId() strings that don't match Aave's UI branding. Alias
/// them to the familiar names for display only — the on-chain describePosition label stays canonical.
const MARKET_ALIASES: Record<string, string> = {
  'Aave Ethereum Market': 'Core Market',
  'Aave V3 Lido Ethereum': 'Prime Market',
}

/// If a pool label carries a trailing "(<market>)" — e.g. Aave's "WETH position (Aave Ethereum Market)" —
/// return the market name aliased for display ("Core" / "Prime"); otherwise null. Lets us sub-group an
/// oracle's positions by market so instances that share a reserve symbol (Aave Core vs Prime) render apart.
function extractMarket(positionDetail: string): string | null {
  const label = extractPoolLabel(positionDetail)
  if (!label) return null
  const m = label.match(/\(([^()]+)\)\s*$/)
  if (!m) return null
  const raw = m[1].trim()
  return MARKET_ALIASES[raw] ?? raw
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

/// Within one oracle (one adapter), split positions into sub-groups by their market/pool label so each
/// distinct instance (Aave Core vs Prime, different Uniswap NFTs/pools, …) gets its own sub-header rather
/// than collapsing every leg under the first one's label.
function groupBySubLabel(
  positions: OnchainPosition[],
): Array<{ label: string | null; positions: OnchainPosition[] }> {
  const out: Array<{ label: string | null; positions: OnchainPosition[] }> = []
  const indexByKey = new Map<string, number>()
  for (const pos of positions) {
    // null label = no market/pool name (e.g. plain wallet holdings) → render flat with no sub-header,
    // rather than a meaningless "Pool 0x…" fallback.
    const label = extractMarket(pos.positionDetail) ?? extractPoolLabel(pos.positionDetail)
    // Map key only; '' is a safe sentinel for the null (no-label) bucket since real market/pool labels are
    // always non-empty. The stored `label` stays null so no sub-header renders for that bucket.
    const key = label ?? ''
    const idx = indexByKey.get(key)
    if (idx !== undefined) out[idx].positions.push(pos)
    else {
      indexByKey.set(key, out.length)
      out.push({ label, positions: [pos] })
    }
  }
  return out
}

function PoolSubHeader({ label, total, isDebt }: { label: string; total: bigint | null; isDebt: boolean }) {
  return (
    <tr>
      <td colSpan={5} className="p-0">
        <div className="pl-9 pr-4 py-1 bg-neutral-50/60 border-t border-neutral-100 flex items-center justify-between">
          <span className="text-[11px] font-semibold uppercase tracking-wide text-neutral-700">{label}</span>
          {total !== null && (
            <span className={`text-[11px] tabular-nums font-medium ${isDebt ? 'text-rose-700' : 'text-neutral-700'}`}>
              {formatUsd(total)}
            </span>
          )}
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
}: {
  label: string
  positions: OnchainPosition[]
  total: bigint
  isDebt: boolean
  chainId: number
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
      {Array.from(oracleGroups.entries()).flatMap(([oracle, group]) =>
        // Split each oracle's legs by market/pool sub-label first, so e.g. Aave Core and Prime — which
        // share the same balanceOracle and reserve symbol — render under separate sub-headers.
        groupBySubLabel(group).map((sg, si) => {
          const subTotal = sg.positions.reduce((s, p) => s + p.value, 0n)
          const typeGroups = groupByType(sg.positions)
          // Render an inner type sub-header (Supply / Fees / Staking / Rewards / …) only when the
          // sub-group's entries carry >1 distinct `type` discriminator. Single-type sub-groups stay
          // flat under the sub-header so we don't add redundant labels like "Supply" in a Supply section.
          const renderTypeSubHeaders =
            typeGroups.length > 1 && typeGroups.some((tg) => tg.type !== null)
          return (
            <Fragment key={`${oracle}-${si}`}>
              {/* Sub-header only when there's a real market/pool label (skip plain wallet holdings). Show its
                  total only when it aggregates >1 row; for a single leg it would just repeat the row amount. */}
              {sg.label !== null && (
                <PoolSubHeader label={sg.label} total={sg.positions.length > 1 ? subTotal : null} isDebt={isDebt} />
              )}
              {renderTypeSubHeaders
                ? typeGroups.map((tg, ti) => {
                    const typeTotal = tg.positions.reduce((s, p) => s + p.value, 0n)
                    const typeLabel = tg.type ?? 'Other'
                    return (
                      <Fragment key={`${oracle}-${si}-${ti}`}>
                        <TypeSubHeader label={typeLabel} total={typeTotal} isDebt={isDebt} />
                        {tg.positions.map((pos, i) => (
                          <PositionRow
                            key={`${oracle}-${si}-${ti}-${i}`}
                            pos={pos}
                            chainId={chainId}
                            sectionTotal={total}
                          />
                        ))}
                      </Fragment>
                    )
                  })
                : sg.positions.map((pos, i) => (
                    <PositionRow
                      key={`${oracle}-${si}-${i}`}
                      pos={pos}
                      chainId={chainId}
                      sectionTotal={total}
                    />
                  ))}
            </Fragment>
          )
        }),
      )}
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
          {groupPct && <span className="text-xs font-medium text-neutral-800">{groupPct}</span>}
          <span className="tabular-nums font-semibold text-sm text-neutral-950">{formatUsd(totalValue)}</span>
        </div>
      </div>

      {/* Positions table — no repeated column headers */}
      <table className="w-full">
        <tbody>
          <PositionSection label="Supply" positions={supply} total={supplyTotal} isDebt={false} chainId={chainId} />
          <PositionSection label="Borrow" positions={borrow} total={borrowTotal} isDebt={true} chainId={chainId} />
        </tbody>
      </table>
    </div>
  )
}
