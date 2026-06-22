'use client'

import { useState } from 'react'

/// Renders a full address (monospace) with an inline copy button. Used everywhere an address is shown so the
/// dashboard never truncates — addresses are always fully visible and one-click copyable. `break-all` lets the
/// address wrap gracefully inside narrow cells rather than overflow.
export function CopyableAddress({ value, className = '' }: { value: string; className?: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <span className={`inline-flex items-center gap-1 font-mono break-all ${className}`}>
      {value}
      {/* `role=button` span (not a <button>) so it can nest inside clickable rows/triggers without invalid HTML. */}
      <span
        role="button"
        tabIndex={0}
        onClick={(e) => {
          e.stopPropagation()
          navigator.clipboard.writeText(value).catch(() => {})
          setCopied(true)
          setTimeout(() => setCopied(false), 1200)
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            e.stopPropagation()
            navigator.clipboard.writeText(value).catch(() => {})
            setCopied(true)
            setTimeout(() => setCopied(false), 1200)
          }
        }}
        title={copied ? 'Copied' : 'Copy address'}
        aria-label="Copy address"
        className="shrink-0 cursor-pointer text-neutral-500 hover:text-neutral-900 transition-colors"
      >
        {copied ? (
          <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M20 6 9 17l-5-5" />
          </svg>
        ) : (
          <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
          </svg>
        )}
      </span>
    </span>
  )
}
