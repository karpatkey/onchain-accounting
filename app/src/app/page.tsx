'use client'

import { useState, useMemo } from 'react'
import { isAddress } from 'viem'
import { TooltipProvider } from '@karpatkey/design-system'
import { ProfileHeader } from '@/components/profile-header'
import { ChainSidebar } from '@/components/chain-sidebar'
import { ProtocolGroup, type ProtocolGroupData } from '@/components/protocol-group'
import { useAccountNav } from '@/hooks/use-account-nav'
import { useAccountPositions } from '@/hooks/use-account-positions'

function buildProtocolGroups(
  positionResults: ReturnType<typeof useAccountPositions>,
  selectedChainId: number | null,
): ProtocolGroupData[] {
  const map = new Map<string, ProtocolGroupData>()

  for (const { chainId, positions } of positionResults) {
    if (selectedChainId !== null && chainId !== selectedChainId) continue
    for (const pos of positions) {
      const key = `${pos.protocol}::${chainId}`
      if (!map.has(key)) {
        map.set(key, { protocol: pos.protocol || 'Unknown', chainId, supply: [], borrow: [], totalValue: 0n })
      }
      const group = map.get(key)!
      if (pos.isDebt) {
        group.borrow.push(pos)
      } else {
        group.supply.push(pos)
      }
      const absValue = pos.value < 0n ? -pos.value : pos.value
      group.totalValue += absValue
    }
  }

  return [...map.values()].sort((a, b) => (b.totalValue > a.totalValue ? 1 : -1))
}

function SearchPage({ onSearch }: { onSearch: (addr: `0x${string}`) => void }) {
  const [value, setValue] = useState('')
  const [error, setError] = useState('')

  function submit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = value.trim()
    if (!isAddress(trimmed)) {
      setError('Enter a valid Ethereum address')
      return
    }
    setError('')
    onSearch(trimmed as `0x${string}`)
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-neutral-200">
      <div className="w-full max-w-lg px-4">
        <div className="text-center mb-8">
          <div className="flex justify-center mb-4">
            {/* kpk logo placeholder */}
            <div className="w-10 h-10 rounded-full bg-neutral-950 flex items-center justify-center text-white text-sm font-semibold">k</div>
          </div>
          <h1 className="text-3xl font-semibold text-neutral-950 mb-2 tracking-tight">NAV Dashboard</h1>
          <p className="text-neutral-700 text-sm">On-chain portfolio across all chains</p>
        </div>
        <form onSubmit={submit} className="flex gap-2">
          <input
            value={value}
            onChange={(e) => { setValue(e.target.value); if (error) setError('') }}
            placeholder="Enter an 0x address"
            className="flex-1 bg-white border border-neutral-400 rounded-lg px-4 py-3 text-sm font-mono placeholder:text-neutral-600 text-neutral-950 focus:outline-none focus:border-neutral-700 transition-colors shadow-[var(--shadow-1)]"
          />
          <button
            type="submit"
            className="bg-neutral-950 text-white rounded-lg px-5 py-3 text-sm font-semibold hover:bg-neutral-800 transition-colors"
          >
            Search
          </button>
        </form>
        {error && <p className="text-rose-700 text-sm mt-2 text-center">{error}</p>}
      </div>
    </div>
  )
}

function PortfolioView({ account, onReset }: { account: `0x${string}`; onReset: () => void }) {
  const [selectedChainId, setSelectedChainId] = useState<number | null>(null)

  const navResults = useAccountNav(account)
  const positionResults = useAccountPositions(account)

  const groups = useMemo(
    () => buildProtocolGroups(positionResults, selectedChainId),
    [positionResults, selectedChainId],
  )

  const isLoading = positionResults.some((r) => r.isLoading)

  return (
    <div className="min-h-screen bg-neutral-200">
      <div className="max-w-6xl mx-auto px-4">
        {/* Top bar */}
        <div className="flex items-center justify-between py-4">
          <div className="flex items-center gap-2">
            <div className="w-7 h-7 rounded-full bg-neutral-950 flex items-center justify-center text-white text-xs font-semibold">k</div>
            <span className="text-sm font-semibold text-neutral-950">NAV Dashboard</span>
          </div>
          <div className="flex gap-4 text-sm">
            <a href="/" className="text-neutral-700 hover:text-neutral-950 transition-colors">Portfolio</a>
            <a href="/feeds" className="text-neutral-700 hover:text-neutral-950 transition-colors">Price Feeds</a>
            <button
              type="button"
              onClick={onReset}
              className="text-neutral-600 hover:text-neutral-950 transition-colors"
            >
              ✕
            </button>
          </div>
        </div>

        <ProfileHeader address={account} navResults={navResults} />

        <div className="flex gap-6 mt-6 pb-12">
          <ChainSidebar
            navResults={navResults}
            selectedChainId={selectedChainId}
            onSelect={setSelectedChainId}
          />

          <div className="flex-1 min-w-0">
            {isLoading && (
              <div className="space-y-3">
                {[120, 80, 160, 80].map((h, i) => (
                  <div
                    key={i}
                    className="rounded-xl border border-neutral-400 bg-white animate-pulse"
                    style={{ height: h }}
                  />
                ))}
              </div>
            )}

            {!isLoading && groups.length === 0 && (
              <div className="text-center py-16 text-neutral-600">
                No positions found on {selectedChainId ? 'this chain' : 'any chain'}.
              </div>
            )}

            {!isLoading && groups.map((group) => (
              <ProtocolGroup
                key={`${group.protocol}::${group.chainId}`}
                group={group}
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

export default function Page() {
  const [account, setAccount] = useState<`0x${string}` | null>(null)

  return (
    <TooltipProvider>
      {account ? (
        <PortfolioView account={account} onReset={() => setAccount(null)} />
      ) : (
        <SearchPage onSearch={setAccount} />
      )}
    </TooltipProvider>
  )
}
