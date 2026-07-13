import { formatUnits } from 'viem'

// Converting a fixed-point bigint via Number(formatUnits(...)) is exact for realistic
// NAVs/amounts, but loses integer precision above Number.MAX_SAFE_INTEGER and overflows
// to Infinity for absurdly large values. The formatters below take the fast Number path
// normally and fall back to the exact (string-based) fixed-point representation when the
// conversion is not finite, so the UI never renders "Infinity"/"NaN".

export function formatUsd(value: bigint, decimals = 8): string {
  const abs = value < 0n ? -value : value
  const num = Number(formatUnits(abs, decimals))
  const formatted = Number.isFinite(num)
    ? num.toLocaleString('en-US', {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      })
    : `$${formatUnits(abs, decimals)}`
  return value < 0n ? `-${formatted}` : formatted
}

/// Compact USD for space-constrained UI (e.g. the fixed-width chains sidebar): $73.80M / $786.17K / $372.85.
/// Compact K/M/B/T notation keeps the width bounded for any realistic NAV, so it can't overflow the row (the
/// non-finite fallback below is a defensive path for astronomically large / overflowed values only).
/// Full-precision values belong in the header + positions table (formatUsd).
export function formatUsdCompact(value: bigint, decimals = 8): string {
  const abs = value < 0n ? -value : value
  const num = Number(formatUnits(abs, decimals))
  const formatted = Number.isFinite(num)
    ? num.toLocaleString('en-US', {
        style: 'currency',
        currency: 'USD',
        notation: 'compact',
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      })
    : `$${formatUnits(abs, decimals)}`
  return value < 0n ? `-${formatted}` : formatted
}

export function formatAmount(amount: bigint, decimals: number, symbol: string): string {
  const suffix = symbol ? ` ${symbol}` : ''
  const num = Number(formatUnits(amount, decimals))
  if (num === 0) return `0${suffix}`
  if (!Number.isFinite(num)) return `${formatUnits(amount, decimals)}${suffix}`

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
  return `${formatted}${suffix}`
}

export function formatPrice(price: bigint, decimals: number): string {
  const num = Number(formatUnits(price, decimals))
  if (!Number.isFinite(num)) return `$${formatUnits(price, decimals)}`
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

// Treat any heartbeat larger than 100 years as the "disabled" sentinel. Custom feeds
// are sometimes registered with `chainlinkHeartbeat = type(uint256).max` to document
// that staleness is enforced by the feed's internal `getLatestPrice().stale` instead
// of a wall-clock heartbeat — without this guard, `Number(MAX_UINT256)` overflows to
// floating-point and the table renders nonsense like "1.3e+72d".
const HEARTBEAT_DISABLED_THRESHOLD_SECONDS = 100n * 365n * 24n * 3600n

export function formatHeartbeat(seconds: bigint): string {
  if (seconds === 0n) return '—'
  if (seconds >= HEARTBEAT_DISABLED_THRESHOLD_SECONDS) return '∞'
  const s = Number(seconds)
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

export function isStaleWarning(updatedAt: bigint, heartbeat: bigint): boolean {
  // updatedAt == 0 is the documented ICustomPriceFeed sentinel for "no trackable oracle
  // dependency" (live on-chain rate, see ADR 0010). Such feeds have no heartbeat semantics —
  // bail before computing `block.timestamp - 0`, which would overflow into an enormous Number
  // when cast and falsely flag every live-rate feed as Warning. The dashboard renders these as
  // "Live" in the Last Updated column.
  if (updatedAt === 0n) return false
  if (heartbeat === 0n) return false
  const age = BigInt(Math.floor(Date.now() / 1000)) - updatedAt
  return age > (heartbeat * 8n) / 10n
}
