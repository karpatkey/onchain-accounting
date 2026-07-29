'use client'

import {
  Table,
  THead,
  TBody,
  Tr,
  Th,
  Td,
  Badge,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@karpatkey/design-system'
import type { ChainPositions } from '@/hooks/use-account-positions'
import { formatAmount, formatPrice, formatUsd } from '@/lib/format'

interface PositionsTableProps {
  data: ChainPositions
}

export function PositionsTable({ data }: PositionsTableProps) {
  const { positions, isLoading, isError } = data

  if (isLoading) {
    return <p className="text-sm text-neutral-700 py-4">Loading positions…</p>
  }

  if (isError) {
    return <p className="text-sm text-destructive py-4">Failed to load positions.</p>
  }

  if (positions.length === 0) {
    return <p className="text-sm text-neutral-700 py-4">No positions found for this address.</p>
  }

  const sorted = [...positions].sort((a, b) => {
    const aAbs = a.value < 0n ? -a.value : a.value
    const bAbs = b.value < 0n ? -b.value : b.value
    if (bAbs > aAbs) return 1
    if (bAbs < aAbs) return -1
    return 0
  })

  return (
    <div className="overflow-x-auto">
      <Table>
        <THead>
          <Tr>
            <Th>Asset</Th>
            <Th>Protocol</Th>
            <Th>Detail</Th>
            <Th className="text-right">Amount</Th>
            <Th className="text-right">Price</Th>
            <Th className="text-right">Value (USD)</Th>
            <Th className="text-center">Status</Th>
          </Tr>
        </THead>
        <TBody>
          {sorted.map((pos, i) => {
            const isDebt = pos.isDebt
            return (
              <Tr key={i} className={isDebt ? 'bg-red-50 dark:bg-red-950/10' : ''}>
                <Td className="font-medium">
                  {pos.underlyingAsset.symbol}
                </Td>
                <Td className="capitalize text-sm">
                  {pos.protocol || '—'}
                </Td>
                <Td className="text-sm text-neutral-700">
                  {pos.poolLabel || '—'}
                </Td>
                <Td className="text-right tabular-nums text-sm">
                  {formatAmount(pos.amount, pos.underlyingAsset.decimals, '')}
                </Td>
                <Td className="text-right tabular-nums text-sm">
                  {formatPrice(pos.price, pos.priceDecimals)}
                </Td>
                <Td
                  className={`text-right tabular-nums font-semibold text-sm ${
                    isDebt ? 'text-red-600 dark:text-red-400' : ''
                  }`}
                >
                  {formatUsd(pos.value)}
                </Td>
                <Td className="text-center">
                  {pos.stale && (
                    <Tooltip>
                      <TooltipTrigger>
                        <Badge variant="negative" className="text-xs">Stale</Badge>
                      </TooltipTrigger>
                      <TooltipContent>Price feed is stale for this asset</TooltipContent>
                    </Tooltip>
                  )}
                  {isDebt && !pos.stale && (
                    <Badge variant="negative" className="text-xs">Debt</Badge>
                  )}
                </Td>
              </Tr>
            )
          })}
        </TBody>
      </Table>
    </div>
  )
}
