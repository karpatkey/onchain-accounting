import { Badge } from '@karpatkey/design-system'

interface SequencerBadgeProps {
  label: string
  sequencerFeed: `0x${string}` | null
  isDown: boolean
}

export function SequencerBadge({ label, sequencerFeed, isDown }: SequencerBadgeProps) {
  if (!sequencerFeed) return null

  return (
    <div className="flex items-center gap-2">
      <span className="text-sm font-medium text-muted-foreground">{label}</span>
      <Badge variant={isDown ? 'negative' : 'positive'}>
        {isDown ? 'Sequencer Down' : 'Sequencer Up'}
      </Badge>
    </div>
  )
}
