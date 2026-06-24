'use client'

import { Fragment } from 'react'
import type { OnchainPosition } from '@/hooks/use-account-positions'
import { TokenLogo } from '@/components/token-logo'
import { AddressChip, CopyIconButton } from '@/components/address-chip'
import { formatAmount, formatPrice, formatUsd } from '@/lib/format'
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
  EulerCircleColor,
} from '@karpatkey/design-system'

// Per-request drill-down rows for withdrawal-queue adapters (Lido NFT ids / Stader & Kelp request ids).
// Display only — the adapter aggregates requests into a leg; the hooks (use-lido/stader/kelp-withdrawals)
// re-derive the per-request detail and produce this shared shape. Keyed by chainId:oracle:asset (the asset
// is required because a multi-asset adapter like Kelp emits several legs from one oracle, each with its own
// requests — keying by oracle alone would cross-contaminate the legs).
// `label` overrides the default `#<id>` display for queues without a per-request id (Ethena cooldown:
// one struct per account, so we show the claimable date instead). `isFinalized` drives the
// Claimable/Pending badge for every queue (Ethena: claimable once the cooldown has elapsed).
// `label` overrides the default `#<id>` text for queues without a per-request id. `address` + `ticket` render
// the position identity as a copyable AddressChip (the vault) plus a copyable truncated ticket — used by queues
// (StakeWise exit) whose identity is a contract address + a long ticket that would otherwise be cut off.
export type WithdrawalRequestRow = {
  id: bigint
  ethOwed: bigint
  isFinalized: boolean
  label?: string
  address?: `0x${string}`
  ticket?: string
}
export type WithdrawalsByKey = Map<string, WithdrawalRequestRow[]>
export const withdrawalsKey = (chainId: number, oracle: string, asset: string) =>
  `${chainId}:${oracle.toLowerCase()}:${asset.toLowerCase()}`

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
  euler: EulerCircleColor,
}

// Protocols without a design-system CircleColor icon fall back to a CDN image keyed the same way.
const PROTOCOL_IMG_ICONS: Record<string, string> = {
  pancakeswap: 'https://assets.coingecko.com/coins/images/12632/large/pancakeswap-cake-logo_(1).png',
  ethena:
    'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0x4c9EDD5852cd905f086C759E8383e09bff1E68B3/logo.png',
  'ether.fi': 'https://icons.llamao.fi/icons/protocols/ether.fi?w=48&h=48',
  stakewise: 'https://icons.llamao.fi/icons/protocols/stakewise?w=48&h=48',
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
  euler: 'https://app.euler.finance/',
  ethena: 'https://app.ethena.fi/',
  'ether.fi': 'https://app.ether.fi/',
  stakewise: 'https://app.stakewise.io/',
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
    <svg className="w-6 h-6 text-neutral-700 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
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

function PositionRow({
  pos,
  chainId,
  sectionTotal,
  withdrawalsByKey,
  kindLabel,
}: {
  pos: OnchainPosition
  chainId: number
  sectionTotal: bigint
  withdrawalsByKey?: WithdrawalsByKey
  // Optional inline leg tag (Staking / Borrow / …) rendered on the row itself. Used by the per-vault layout
  // so each line is self-labelled instead of relying on a separate sub-header above it.
  kindLabel?: { text: string; isDebt: boolean }
}) {
  const pct = pctOfSection(pos.value, sectionTotal)
  // Per-request drill-down for withdrawal-queue legs (Lido NFT ids / Stader request ids). The adapter
  // aggregates all open requests into this one ETH/WETH leg; these rows re-derive the components from the
  // protocol's queue for visibility only. Each request's ethOwed is valued the same way the adapter sums it
  // (finalized → exact owed, pending → estimate), so the sub-rows are genuine amounts and reconcile with it.
  const requests = withdrawalsByKey?.get(withdrawalsKey(chainId, pos.balanceOracle, pos.underlyingAsset.asset)) ?? []
  // Total ETH-owed across the requests (== the adapter's aggregate, barring an unresolved claimable fetch).
  // Used to split the parent USD value; the last row takes the remainder so the sub-rows sum *exactly* to
  // pos.value despite bigint truncation in the proportional division.
  const totalOwed = requests.reduce((sum, r) => sum + r.ethOwed, 0n)
  let allocatedSub = 0n
  return (
    <>
      <tr className="border-t border-neutral-200 hover:bg-neutral-50 transition-colors">
        <td className="py-2.5 px-4 text-sm font-medium text-neutral-950">
          <div className="flex items-center gap-1.5">
            {kindLabel && (
              <span
                className={`inline-block shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                  kindLabel.isDebt ? 'bg-rose-100 text-rose-700' : 'bg-green-100 text-green-700'
                }`}
              >
                {kindLabel.text}
              </span>
            )}
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
      {requests.map((req, idx) => {
        // Split the aggregate leg's USD value across requests by ETH-owed share (the same per-request basis
        // the adapter sums). The last row takes the leftover so the sub-rows sum exactly to pos.value rather
        // than slightly under it (bigint division truncates).
        const isLast = idx === requests.length - 1
        const subValue = isLast
          ? pos.value - allocatedSub
          : totalOwed === 0n
            ? 0n
            : (pos.value * req.ethOwed) / totalOwed
        if (!isLast) allocatedSub += subValue
        return (
          <tr
            key={`${req.address ?? ''}:${req.id.toString()}:${req.isFinalized}`}
            className="border-t border-neutral-100 bg-neutral-100/70"
          >
            <td className="py-2 px-4 pl-9 text-xs text-neutral-700">
              <div className="flex items-center gap-2">
                <span className="text-neutral-700">↳</span>
                {req.address ? (
                  // Position identity = vault (copyable AddressChip + explorer) · truncated ticket (copyable).
                  // Both are long (20-byte address / 24-digit ticket) and would otherwise be cut off.
                  <span className="inline-flex items-center gap-1.5">
                    <AddressChip address={req.address} chainId={chainId} className="text-xs text-neutral-800" />
                    {req.ticket && (
                      <span className="inline-flex items-center gap-1 text-neutral-700">
                        <span className="text-neutral-400">·</span>
                        <span title={`ticket ${req.ticket}`} className="font-mono">
                          #…{req.ticket.length > 6 ? req.ticket.slice(-6) : req.ticket}
                        </span>
                        <CopyIconButton value={req.ticket} label="Copy exit ticket" />
                      </span>
                    )}
                  </span>
                ) : (
                  <span className="font-mono font-medium text-neutral-800">{req.label ?? `#${req.id.toString()}`}</span>
                )}
                <span
                  className={`inline-block rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                    req.isFinalized ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800'
                  }`}
                >
                  {req.isFinalized ? 'Claimable' : 'Pending'}
                </span>
              </div>
            </td>
            <td className="py-2 px-4 text-xs text-right tabular-nums text-neutral-700">
              {formatAmount(req.ethOwed, pos.underlyingAsset.decimals, pos.underlyingAsset.symbol)}
            </td>
            <td className="py-2 px-4 text-xs text-right tabular-nums text-neutral-700">
              {formatPrice(pos.price, pos.priceDecimals)}
            </td>
            <td className="py-2 px-4 text-xs text-right tabular-nums font-medium text-neutral-800">
              {formatUsd(subValue)}
            </td>
            <td className="py-2 px-4 text-xs text-right tabular-nums text-neutral-700">
              {pctOfSection(subValue, sectionTotal)}
            </td>
          </tr>
        )
      })}
    </>
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

/// Group a protocol's combined legs by positionId (the on-chain instance coordinate — e.g. a StakeWise vault),
/// preserving the order of the input array (the caller passes supply legs then borrow legs, so within a vault the
/// supply/staking leg renders before the borrow leg). For CDP-style protocols where one instance carries both a supply/staking leg and a
/// borrow leg, this renders the matched legs together under one vault header instead of splitting them across the
/// protocol's Supply and Borrow sections. `label` is the instance's display name when the adapter's
/// describePosition() returns one, else null — the vault header then falls back to the full address from the key.
/// Recover the full instance address from a positionId for display. `abi.encode(address)` is a 32-byte word
/// with the address in the low 20 bytes (24 leading hex zeros) → return the 0x address (lowercased, since the
/// positionId is); for other id shapes (e.g. Morpho marketId, Uniswap NFT tuple) return the full positionId hex.
function fullAddressFromPositionId(positionId: string): string {
  const hex = positionId.startsWith('0x') ? positionId.slice(2) : positionId
  if (hex.length === 64 && /^0{24}/.test(hex)) return `0x${hex.slice(24)}`
  return positionId
}

function groupByVault(
  positions: OnchainPosition[],
): Array<{ key: string; label: string | null; positions: OnchainPosition[] }> {
  const out: Array<{ key: string; label: string | null; positions: OnchainPosition[] }> = []
  const idx = new Map<string, number>()
  for (const pos of positions) {
    const key =
      pos.positionId && pos.positionId !== '0x' ? pos.positionId.toLowerCase() : pos.balanceOracle.toLowerCase()
    const i = idx.get(key)
    if (i !== undefined) out[i].positions.push(pos)
    else {
      idx.set(key, out.length)
      out.push({ key, label: extractPoolLabel(pos.positionDetail), positions: [pos] })
    }
  }
  return out
}

/// True when some positionId carries BOTH a supply (non-debt) and a borrow (debt) leg — a true collateralised
/// position (StakeWise vault, Euler/Morpho market). For these, grouping by vault reads far better than the
/// protocol-wide Supply / Borrow split. Protocols without matched legs (wallet, supply-only, Aave cross-asset)
/// fall through to the default layout.
function hasMatchedVaultLegs(supply: OnchainPosition[], borrow: OnchainPosition[]): boolean {
  const supplyIds = new Set(
    supply.map((p) => p.positionId?.toLowerCase()).filter((id): id is string => !!id && id !== '0x'),
  )
  return borrow.some((p) => !!p.positionId && supplyIds.has(p.positionId.toLowerCase()))
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
        <div className="pl-11 pr-4 py-0.5 flex items-center justify-between">
          <span className="text-[11px] font-semibold uppercase tracking-wider text-neutral-700">{label}</span>
          <span className={`text-[11px] tabular-nums font-medium ${isDebt ? 'text-rose-700' : 'text-neutral-700'}`}>
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
  withdrawalsByKey,
}: {
  label: string
  positions: OnchainPosition[]
  total: bigint
  isDebt: boolean
  chainId: number
  withdrawalsByKey?: WithdrawalsByKey
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
                            withdrawalsByKey={withdrawalsByKey}
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
                      withdrawalsByKey={withdrawalsByKey}
                    />
                  ))}
            </Fragment>
          )
        }),
      )}
    </>
  )
}

/// Per-vault layout for collateralised protocols (StakeWise V3, Euler, Morpho markets): group every leg by
/// positionId so each vault renders as one block with its matched Staking/Supply + Borrow lines, rather than
/// the protocol-wide Supply / Borrow split. The vault header shows the instance label (name or short address)
/// and its net value (collateral − debt).
function VaultSections({
  positions,
  chainId,
  withdrawalsByKey,
}: {
  positions: OnchainPosition[]
  chainId: number
  withdrawalsByKey?: WithdrawalsByKey
}) {
  const vaults = groupByVault(positions)
  // Section totals for the per-row % column (a leg's share of the protocol's supply vs borrow), kept consistent
  // with the default layout.
  const supplyTotal = positions.filter((p) => !p.isDebt).reduce((s, p) => s + p.value, 0n)
  const borrowTotal = positions.filter((p) => p.isDebt).reduce((s, p) => s + p.value, 0n)
  return (
    <>
      {vaults.map((v, vi) => {
        const net = v.positions.reduce((s, p) => s + p.value, 0n)
        const fullId = fullAddressFromPositionId(v.key)
        return (
          // Key on the stable per-vault id only (groupByVault dedups on v.key); vi is used solely for the
          // first-vs-rest border styling below, not for identity, so it must not be in the key.
          <Fragment key={`vault-${v.key}`}>
            {/* Vault block start: a thick top divider + tinted header clearly bounds each vault. Shows the real
                vault name when the adapter exposes one, then the instance address as a chip (truncated, with the
                full value on hover + copy, and an explorer link when it's a 20-byte address). */}
            <tr>
              <td colSpan={5} className="p-0">
                <div
                  className={`flex items-center justify-between gap-3 bg-neutral-100 px-4 py-1.5 ${
                    vi === 0 ? 'border-t border-neutral-200' : 'border-t-2 border-neutral-300'
                  }`}
                >
                  <span className="flex min-w-0 items-center gap-2">
                    {v.label && <span className="text-xs font-semibold text-neutral-900">{v.label}</span>}
                    <AddressChip address={fullId} chainId={chainId} className="text-[11px] text-neutral-700" />
                  </span>
                  <span
                    className={`shrink-0 text-xs font-semibold tabular-nums ${net < 0n ? 'text-rose-700' : 'text-neutral-800'}`}
                  >
                    net {formatUsd(net)}
                  </span>
                </div>
              </td>
            </tr>
            {v.positions.map((pos) => {
              // Parse the type once and reuse for both the key and the kind label (extractType does a JSON.parse).
              const t = extractType(pos.positionDetail)
              return (
                <PositionRow
                  key={`vault-${v.key}-${pos.positionId}-${pos.underlyingAsset.asset}-${t ?? (pos.isDebt ? 'borrow' : 'supply')}`}
                  pos={pos}
                  chainId={chainId}
                  sectionTotal={pos.isDebt ? borrowTotal : supplyTotal}
                  withdrawalsByKey={withdrawalsByKey}
                  kindLabel={{ text: t ?? (pos.isDebt ? 'Borrow' : 'Supply'), isDebt: pos.isDebt }}
                />
              )
            })}
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
  withdrawalsByKey?: WithdrawalsByKey
}

export function ProtocolGroup({ group, totalPortfolioNav, withdrawalsByKey }: ProtocolGroupProps) {
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

      {/* Positions table — no repeated column headers. CDP-style protocols (a positionId with both a supply and
          a borrow leg) render grouped by vault so the matched legs sit together; everything else keeps the
          protocol-wide Supply / Borrow split. */}
      <table className="w-full">
        <tbody>
          {hasMatchedVaultLegs(supply, borrow) ? (
            <VaultSections positions={[...supply, ...borrow]} chainId={chainId} withdrawalsByKey={withdrawalsByKey} />
          ) : (
            <>
              <PositionSection label="Supply" positions={supply} total={supplyTotal} isDebt={false} chainId={chainId} withdrawalsByKey={withdrawalsByKey} />
              <PositionSection label="Borrow" positions={borrow} total={borrowTotal} isDebt={true} chainId={chainId} withdrawalsByKey={withdrawalsByKey} />
            </>
          )}
        </tbody>
      </table>
    </div>
  )
}
