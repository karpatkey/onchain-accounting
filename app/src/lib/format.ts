import { formatUnits } from 'viem'

export function formatUsd(value: bigint, decimals = 8): string {
  const num = Number(formatUnits(value < 0n ? -value : value, decimals))
  const formatted = num.toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })
  return value < 0n ? `-${formatted}` : formatted
}

export function formatAmount(amount: bigint, decimals: number, symbol: string): string {
  const num = Number(formatUnits(amount, decimals))
  if (num === 0) return `0 ${symbol}`

  let formatted: string
  if (num >= 1_000_000) {
    formatted = `${(num / 1_000_000).toFixed(2)}M`
  } else if (num >= 1_000) {
    formatted = `${(num / 1_000).toFixed(2)}K`
  } else if (num >= 1) {
    formatted = num.toFixed(4)
  } else {
    formatted = num.toPrecision(4)
  }
  return `${formatted} ${symbol}`
}

export function formatPrice(price: bigint, decimals: number): string {
  const num = Number(formatUnits(price, decimals))
  // 2dp for ≥$1 (consistent column alignment), 4dp for sub-$1 to show minor depegs
  const maxFd = num >= 1 ? 2 : num >= 0.01 ? 4 : 6
  return num.toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: maxFd,
  })
}

export function formatAge(updatedAt: bigint): string {
  const seconds = Math.floor(Date.now() / 1000) - Number(updatedAt)
  if (seconds < 0) return 'just now'
  if (seconds < 60) return `${seconds}s ago`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  return `${Math.floor(seconds / 86400)}d ago`
}

export function formatHeartbeat(seconds: bigint): string {
  const s = Number(seconds)
  if (s === 0) return '—'
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

export function isStaleWarning(updatedAt: bigint, heartbeat: bigint): boolean {
  if (heartbeat === 0n) return false
  const age = BigInt(Math.floor(Date.now() / 1000)) - updatedAt
  return age > (heartbeat * 8n) / 10n
}

export function shortenAddress(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}
