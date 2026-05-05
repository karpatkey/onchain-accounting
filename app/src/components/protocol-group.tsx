'use client'

import type { OnchainPosition } from '@/hooks/use-account-positions'
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

function getProtocolIcon(protocol: string): React.ComponentType<{ className?: string }> | null {
  const key = protocol.toLowerCase().replace(/[\s_-]/g, '')
  for (const [k, Icon] of Object.entries(PROTOCOL_ICONS)) {
    if (key.includes(k)) return Icon
  }
  return null
}

function ProtocolIcon({ protocol }: { protocol: string }) {
  const Icon = getProtocolIcon(protocol)
  if (Icon) return <Icon className="w-6 h-6" />
  return (
    <div className="w-6 h-6 rounded-full bg-neutral-300 flex items-center justify-center text-[10px] font-semibold text-neutral-700 shrink-0">
      {protocol.slice(0, 2).toUpperCase()}
    </div>
  )
}

function PositionRow({ pos }: { pos: OnchainPosition }) {
  const isDebt = pos.isDebt
  return (
    <tr className="border-t border-neutral-300 hover:bg-neutral-100/60 transition-colors">
      <td className="py-2.5 px-4 text-sm font-medium text-neutral-950">
        {pos.underlyingAsset.symbol}
      </td>
      <td className="py-2.5 px-4 text-sm text-right tabular-nums text-neutral-800">
        {formatAmount(pos.amount, pos.underlyingAsset.decimals, pos.underlyingAsset.symbol)}
      </td>
      <td className="py-2.5 px-4 text-sm text-right tabular-nums text-neutral-600">
        {formatPrice(pos.price, pos.priceDecimals)}
      </td>
      <td className={`py-2.5 px-4 text-sm text-right tabular-nums font-semibold ${isDebt ? 'text-rose-700' : 'text-neutral-950'}`}>
        {formatUsd(pos.value)}
        {pos.stale && <span className="ml-1 text-orange-700 text-xs">⚠</span>}
      </td>
    </tr>
  )
}

function PositionSection({
  label,
  positions,
  total,
  isDebt,
}: {
  label: string
  positions: OnchainPosition[]
  total: bigint
  isDebt: boolean
}) {
  if (positions.length === 0) return null
  return (
    <>
      <tr>
        <td colSpan={4} className={`pt-3 pb-1 px-4 ${isDebt ? 'bg-rose-50' : 'bg-green-50'}`}>
          <div className="flex items-center justify-between">
            <span className={`text-xs font-semibold uppercase tracking-wider ${isDebt ? 'text-rose-700' : 'text-green-700'}`}>
              {label}
            </span>
            <span className={`text-xs tabular-nums font-semibold ${isDebt ? 'text-rose-700' : 'text-green-700'}`}>
              {formatUsd(total)}
            </span>
          </div>
        </td>
      </tr>
      {positions.map((pos, i) => (
        <PositionRow key={i} pos={pos} />
      ))}
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
}

export function ProtocolGroup({ group }: ProtocolGroupProps) {
  const { protocol, chainId, supply, borrow, totalValue } = group

  const supplyTotal = supply.reduce((s, p) => s + p.value, 0n)
  const borrowTotal = borrow.reduce((s, p) => s + p.value, 0n)

  const ChainIcon = CHAIN_ICONS[chainId]

  return (
    <div className="rounded-xl border border-neutral-400 bg-white overflow-hidden mb-3 shadow-[var(--shadow-1)]">
      {/* Protocol header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-300">
        <div className="flex items-center gap-2.5">
          <ProtocolIcon protocol={protocol} />
          <span className="font-semibold text-sm capitalize text-neutral-950">
            {protocol === 'wallet' ? 'Wallet' : protocol}
          </span>
          {ChainIcon && (
            <span className="flex items-center gap-1 text-xs text-neutral-600 bg-neutral-200 rounded-full px-2 py-0.5">
              <ChainIcon className="w-3.5 h-3.5" />
            </span>
          )}
        </div>
        <span className="tabular-nums font-semibold text-sm text-neutral-950">{formatUsd(totalValue)}</span>
      </div>

      {/* Positions table */}
      <table className="w-full">
        <thead>
          <tr className="bg-neutral-100">
            <th className="text-left py-2 px-4 text-xs text-neutral-600 font-medium">Asset</th>
            <th className="text-right py-2 px-4 text-xs text-neutral-600 font-medium">Balance</th>
            <th className="text-right py-2 px-4 text-xs text-neutral-600 font-medium">Price</th>
            <th className="text-right py-2 px-4 text-xs text-neutral-600 font-medium">USD Value</th>
          </tr>
        </thead>
        <tbody>
          <PositionSection label="Supply" positions={supply} total={supplyTotal} isDebt={false} />
          <PositionSection label="Borrow" positions={borrow} total={borrowTotal} isDebt={true} />
        </tbody>
      </table>
    </div>
  )
}
