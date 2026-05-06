'use client'

import { Badge, Launch, Tooltip, TooltipContent, TooltipTrigger } from '@karpatkey/design-system'
import { useSequencer } from '@/hooks/use-sequencer'
import { explorerAddressUrl } from '@/config/chains'
import { formatAge, formatHeartbeat, shortenAddress } from '@/lib/format'

const STALE_DAYS = 7n * 24n * 3600n

interface SequencerDetailCardProps {
  chainId: number
  chainLabel: string
  feedAddress: `0x${string}`
}

function SequencerStatusBadge({
  isLoading,
  isDown,
  isInGracePeriod,
  isDataStale,
}: {
  isLoading: boolean
  isDown: boolean
  isInGracePeriod: boolean
  isDataStale: boolean
}) {
  if (isLoading) return <span className="text-xs text-neutral-500">Loading…</span>
  if (isDataStale) return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Badge variant="generic" className="bg-amber-500 hover:bg-amber-600 text-white cursor-default">
          Stale Data
        </Badge>
      </TooltipTrigger>
      <TooltipContent>Feed data is over 7 days old — this address may be a deprecated sequencer feed.</TooltipContent>
    </Tooltip>
  )
  if (isDown) return <Badge variant="negative">Down</Badge>
  if (isInGracePeriod) return (
    <Badge variant="generic" className="bg-amber-500 hover:bg-amber-600 text-white">Grace Period</Badge>
  )
  return <Badge variant="positive">Up</Badge>
}

function StatCard({ label, value, tooltip }: { label: string; value: React.ReactNode; tooltip?: string }) {
  const content = (
    <div className="rounded-lg bg-neutral-50 border border-neutral-200 px-3 py-2">
      <p className="text-[10px] text-neutral-500 uppercase tracking-wider mb-0.5">{label}</p>
      <p className="text-sm font-medium text-neutral-900 flex items-center gap-1">{value}</p>
    </div>
  )
  if (!tooltip) return content
  return (
    <Tooltip>
      <TooltipTrigger asChild>{content}</TooltipTrigger>
      <TooltipContent className="max-w-xs">{tooltip}</TooltipContent>
    </Tooltip>
  )
}

export function SequencerDetailCard({ chainId, feedAddress }: SequencerDetailCardProps) {
  const seq = useSequencer(chainId, feedAddress)

  const isDown = seq?.isDown ?? false
  const inGrace = seq?.isInGracePeriod ?? false
  const isLoading = seq?.isLoading ?? true

  const nowSec = BigInt(Math.floor(Date.now() / 1000))
  const isDataStale = !isLoading && (seq?.updatedAt ?? 0n) > 0n &&
    (nowSec - (seq?.updatedAt ?? 0n)) > STALE_DAYS

  const gracePeriodRemaining = inGrace && seq ? seq.gracePeriod - (nowSec - seq.startedAt) : 0n

  const gracePeriodValue = seq && !isLoading
    ? <>
        {formatHeartbeat(seq.gracePeriod)}
        {inGrace && gracePeriodRemaining > 0n && (
          <span className="ml-1 text-orange-700 text-xs">({formatHeartbeat(gracePeriodRemaining)} remaining)</span>
        )}
      </>
    : <span className="text-neutral-400">—</span>

  return (
    <div className="rounded-xl border border-neutral-400 bg-white p-4 shadow-[var(--shadow-1)]">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-1.5">
          <span className="font-semibold text-sm text-neutral-950">Sequencer Feed</span>
          <a
            href={explorerAddressUrl(chainId, feedAddress)}
            target="_blank"
            rel="noreferrer"
            className="text-neutral-400 hover:text-neutral-950 inline-flex items-center transition-colors"
          >
            <Launch className="w-3 h-3" />
          </a>
          <Tooltip>
            <TooltipTrigger className="font-mono text-xs text-neutral-500 cursor-default">
              {shortenAddress(feedAddress)}
            </TooltipTrigger>
            <TooltipContent><span className="font-mono">{feedAddress}</span></TooltipContent>
          </Tooltip>
        </div>
        <SequencerStatusBadge
          isLoading={isLoading}
          isDown={isDown}
          isInGracePeriod={inGrace}
          isDataStale={isDataStale}
        />
      </div>

      {/* Grid layout for stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
        <StatCard
          label="Last Updated"
          value={seq && !isLoading && seq.updatedAt > 0n ? formatAge(seq.updatedAt) : <span className="text-neutral-400">—</span>}
        />
        <StatCard
          label={isDown ? 'Down Since' : 'Online Since'}
          value={seq && !isLoading && seq.startedAt > 0n ? formatAge(seq.startedAt) : <span className="text-neutral-400">—</span>}
        />
        <StatCard
          label="Grace Period"
          value={gracePeriodValue}
          tooltip="If the sequencer goes offline, price feeds remain valid for this period before being considered unreliable."
        />
        <StatCard
          label="Feed Address"
          value={
            <span className="font-mono text-xs">{shortenAddress(feedAddress)}</span>
          }
        />
      </div>
    </div>
  )
}
