'use client'

import { Launch } from '@karpatkey/design-system'
import { useSequencer } from '@/hooks/use-sequencer'
import { explorerAddressUrl } from '@/config/chains'
import { formatAge, formatHeartbeat, shortenAddress } from '@/lib/format'

interface SequencerDetailCardProps {
  chainId: number
  chainLabel: string
  feedAddress: `0x${string}`
}

function StatusDot({ ok }: { ok: boolean }) {
  return (
    <span
      className={`inline-block w-2 h-2 rounded-full ${ok ? 'bg-green-600' : 'bg-rose-600'}`}
    />
  )
}

export function SequencerDetailCard({ chainId, chainLabel, feedAddress }: SequencerDetailCardProps) {
  const seq = useSequencer(chainId, feedAddress)

  const isUp = seq ? !seq.isDown : true
  const inGrace = seq?.isInGracePeriod ?? false

  let statusLabel = 'Up'
  let statusColor = 'text-green-700'
  if (seq?.isDown) { statusLabel = 'Down'; statusColor = 'text-rose-700' }
  else if (inGrace) { statusLabel = 'Up (grace period)'; statusColor = 'text-orange-700' }

  const nowSec = BigInt(Math.floor(Date.now() / 1000))
  const gracePeriodRemaining =
    inGrace && seq ? seq.gracePeriod - (nowSec - seq.startedAt) : 0n

  return (
    <div className="rounded-xl border border-neutral-400 bg-white p-4 shadow-[var(--shadow-1)]">
      <div className="flex items-center justify-between mb-3">
        <span className="font-semibold text-sm text-neutral-950">{chainLabel}</span>
        <div className="flex items-center gap-1.5">
          {seq?.isLoading ? (
            <span className="text-xs text-neutral-500">Loading…</span>
          ) : (
            <>
              <StatusDot ok={isUp && !inGrace} />
              <span className={`text-xs font-semibold ${statusColor}`}>{statusLabel}</span>
            </>
          )}
        </div>
      </div>

      <div className="space-y-1.5 text-xs">
        <Row label="Feed address">
          <span className="font-mono text-neutral-700">{shortenAddress(feedAddress)}</span>
          <a
            href={explorerAddressUrl(chainId, feedAddress)}
            target="_blank"
            rel="noreferrer"
            className="ml-1 text-neutral-500 hover:text-neutral-950 inline-flex items-center"
          >
            <Launch className="w-3 h-3" />
          </a>
        </Row>

        {seq && !seq.isLoading && (
          <>
            <Row label="Last updated">
              {seq.updatedAt > 0n ? formatAge(seq.updatedAt) : '—'}
            </Row>
            <Row label={seq.isDown ? 'Down since' : 'Online since'}>
              {seq.startedAt > 0n ? formatAge(seq.startedAt) : '—'}
            </Row>
            <Row label="Grace period">
              {formatHeartbeat(seq.gracePeriod)}
              {inGrace && gracePeriodRemaining > 0n && (
                <span className="ml-1 text-orange-700">
                  ({formatHeartbeat(gracePeriodRemaining)} remaining)
                </span>
              )}
            </Row>
          </>
        )}
      </div>
    </div>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-neutral-500">{label}</span>
      <span className="text-neutral-800 flex items-center">{children}</span>
    </div>
  )
}
