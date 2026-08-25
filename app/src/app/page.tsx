'use client'

import { useState, useMemo, useEffect } from 'react'
import { isAddress, formatUnits } from 'viem'
import { TooltipProvider } from '@karpatkey/design-system'
import { DashboardNav } from '@/components/dashboard-nav'
import { ProfileHeader } from '@/components/profile-header'
import { ChainSidebar } from '@/components/chain-sidebar'
import { ProtocolGroup, type ProtocolGroupData, type WithdrawalsByKey, type WithdrawalRequestRow } from '@/components/protocol-group'
import { useAccountNav } from '@/hooks/use-account-nav'
import { useAccountPositions, type ChainPositions } from '@/hooks/use-account-positions'
import { useLidoWithdrawals, type LidoOracleRef } from '@/hooks/use-lido-withdrawals'
import { useStaderWithdrawals, type StaderOracleRef } from '@/hooks/use-stader-withdrawals'
import { useKelpWithdrawals, type KelpOracleRef } from '@/hooks/use-kelp-withdrawals'
import { useEthenaCooldown, type EthenaOracleRef } from '@/hooks/use-ethena-cooldown'
import { useStakeWiseExitWithdrawals, type StakeWiseExitOracleRef } from '@/hooks/use-stakewise-exit-withdrawals'
import { useRefreshCooldown } from '@/hooks/use-refresh-cooldown'
import { AddressChip } from '@/components/address-chip'

// ─── Recent searches ─────────────────────────────────────────────────────────

const RECENT_KEY = 'nav-recent-searches'
type RecentSearch = { address: string; timestamp: number }

function getRecentSearches(): RecentSearch[] {
  try { return JSON.parse(localStorage.getItem(RECENT_KEY) || '[]') } catch { return [] }
}

function addRecentSearch(address: string) {
  const prev = getRecentSearches().filter((r) => r.address.toLowerCase() !== address.toLowerCase())
  localStorage.setItem(RECENT_KEY, JSON.stringify([{ address, timestamp: Date.now() }, ...prev].slice(0, 5)))
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Absolute magnitude of a (signed, net) value — used for size comparisons (sorting, dust filter) so a
/// net-negative group (borrow > supply) is ranked/kept by how big it is, not filtered out as "dust".
function mag(v: bigint): bigint {
  return v < 0n ? -v : v
}

function buildProtocolGroups(
  positionResults: ChainPositions[],
  selectedChainId: number | null,
): ProtocolGroupData[] {
  const map = new Map<string, ProtocolGroupData>()
  for (const { chainId, positions } of positionResults) {
    if (selectedChainId !== null && chainId !== selectedChainId) continue
    for (const pos of positions) {
      const key = `${pos.protocol}::${chainId}`
      if (!map.has(key)) map.set(key, { protocol: pos.protocol || 'Unknown', chainId, supply: [], borrow: [], totalValue: 0n })
      const group = map.get(key)!
      if (pos.isDebt) group.borrow.push(pos)
      else group.supply.push(pos)
      // Net contribution to NAV: debt is negative, so it subtracts (matches the Net headline). pos.value
      // is already signed (negative for debt), so a plain sum gives the protocol's net value.
      group.totalValue += pos.value
    }
  }
  // Sort by net magnitude so a net-negative group (rare: borrow > supply) still ranks by size.
  return [...map.values()].sort((a, b) => {
    const d = mag(b.totalValue) - mag(a.totalValue)
    return d > 0n ? 1 : d < 0n ? -1 : 0
  })
}

// Truncate a fixed-point bigint to `dp` decimals as a string — avoids Number() precision loss / Infinity on large values.
function csvFixed(value: bigint, decimals: number, dp: number): string {
  const [int, frac = ''] = formatUnits(value, decimals).split('.')
  return dp === 0 ? int : `${int}.${(frac + '0'.repeat(dp)).slice(0, dp)}`
}

function exportCsv(positionResults: ChainPositions[], address: string) {
  const rows = ['Protocol,Chain,Type,Asset,Balance,Price (USD),Value (USD)']
  for (const { label, positions } of positionResults) {
    for (const pos of positions) {
      rows.push([
        `"${pos.protocol}"`,
        `"${label}"`,
        pos.isDebt ? 'Borrow' : 'Supply',
        `"${pos.underlyingAsset.symbol}"`,
        csvFixed(pos.amount, pos.underlyingAsset.decimals, 6),
        csvFixed(pos.price, pos.priceDecimals, 6),
        csvFixed(pos.value < 0n ? -pos.value : pos.value, 8, 2),
      ].join(','))
    }
  }
  const blob = new Blob([rows.join('\n')], { type: 'text/csv' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `portfolio-${address.slice(0, 8)}-${new Date().toISOString().slice(0, 10)}.csv`
  a.click()
  URL.revokeObjectURL(url)
}

// ─── Landing page ─────────────────────────────────────────────────────────────

function SearchPage({ onSearch }: { onSearch: (addr: `0x${string}`) => void }) {
  const [value, setValue] = useState('')
  const [error, setError] = useState('')
  const [recents, setRecents] = useState<RecentSearch[]>([])

  useEffect(() => { setRecents(getRecentSearches()) }, [])

  function submit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = value.trim()
    if (!isAddress(trimmed)) { setError('Please enter a valid Ethereum address'); return }
    setError('')
    onSearch(trimmed as `0x${string}`)
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-neutral-200">
      <div className="w-full max-w-lg px-4 -mt-20">
        <div className="text-center mb-8">
          <div className="flex justify-center mb-4">
            <div className="w-10 h-10 rounded-full bg-neutral-950 flex items-center justify-center text-white text-sm font-semibold">k</div>
          </div>
          <h1 className="text-3xl font-semibold text-neutral-950 mb-2 tracking-tight">NAV Dashboard</h1>
          <p className="text-neutral-700 text-sm">On-chain portfolio across all chains</p>
        </div>

        <form onSubmit={submit} className="flex gap-2">
          <input
            value={value}
            onChange={(e) => { setValue(e.target.value); if (error) setError('') }}
            placeholder="Enter a 0x wallet address"
            className="flex-1 bg-white border border-neutral-400 rounded-lg px-4 py-3 text-sm font-mono placeholder:text-neutral-700 text-neutral-950 focus:outline-none focus:border-neutral-700 transition-colors shadow-[var(--shadow-1)]"
          />
          <button type="submit" className="bg-neutral-950 text-white rounded-lg px-5 py-3 text-sm font-semibold hover:bg-neutral-800 transition-colors">
            Search
          </button>
        </form>
        {error && <p className="text-rose-700 text-sm mt-2">{error}</p>}
        <p className="text-xs text-neutral-700 mt-2 text-center">Enter an Ethereum-compatible wallet or Safe address</p>

        {recents.length > 0 && (
          <div className="mt-6">
            <p className="text-xs text-neutral-700 uppercase tracking-wider mb-2">Recent searches</p>
            <div className="space-y-1">
              {recents.map((r) => (
                <div
                  key={r.address}
                  role="button"
                  tabIndex={0}
                  onClick={() => onSearch(r.address as `0x${string}`)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault()
                      onSearch(r.address as `0x${string}`)
                    }
                  }}
                  className="w-full cursor-pointer flex items-center justify-between px-3 py-2 rounded-lg bg-white border border-neutral-300 hover:border-neutral-500 text-sm transition-colors shadow-[var(--shadow-1)]"
                >
                  <AddressChip address={r.address} className="text-neutral-800" />
                  <span className="text-neutral-700 text-xs">{new Date(r.timestamp).toLocaleDateString()}</span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

// ─── Portfolio view ───────────────────────────────────────────────────────────

type SortOrder = 'value-desc' | 'value-asc' | 'name-asc'
const DUST_THRESHOLD = 100_000_000n // $1 in 8-decimal bigint

function PortfolioView({ account, onReset }: { account: `0x${string}`; onReset: () => void }) {
  const [selectedChainId, setSelectedChainId] = useState<number | null>(null)
  const [sortOrder, setSortOrder] = useState<SortOrder>('value-desc')
  const [hideDust, setHideDust] = useState(() =>
    typeof window === 'undefined' ? true : localStorage.getItem('nav-hide-dust') !== 'false'
  )

  const { chains: navResults, refetch: refetchNav } = useAccountNav(account)
  const { chains: positionResults, refetch: refetchPositions } = useAccountPositions(account)
  const { canRefresh, secondsLeft, startCooldown } = useRefreshCooldown()

  const isLoading = positionResults.some((r) => r.isLoading)

  const allGroups = useMemo(
    () => buildProtocolGroups(positionResults, selectedChainId),
    [positionResults, selectedChainId],
  )

  const groups = useMemo(() => {
    let g = hideDust ? allGroups.filter((gr) => mag(gr.totalValue) >= DUST_THRESHOLD) : allGroups
    if (sortOrder === 'value-asc') {
      g = [...g].sort((a, b) => {
        const d = mag(a.totalValue) - mag(b.totalValue)
        return d > 0n ? 1 : d < 0n ? -1 : 0
      })
    }
    else if (sortOrder === 'name-asc') g = [...g].sort((a, b) => a.protocol.localeCompare(b.protocol))
    // Wallet holdings always render on top, regardless of sort order (the ERC20Default adapter's
    // protocolName() is "Wallet"). Stable partition — preserves the sorted order of the rest.
    return [...g.filter((gr) => gr.protocol === 'Wallet'), ...g.filter((gr) => gr.protocol !== 'Wallet')]
  }, [allGroups, hideDust, sortOrder])

  // Lido withdrawal-queue oracles the account touches — drives the per-NFT-id drill-down (display only;
  // the adapter aggregates to a single ETH leg). Keyed off the resolved protocol name, deduped per oracle.
  const lidoOracles = useMemo<LidoOracleRef[]>(() => {
    const seen = new Set<string>()
    const refs: LidoOracleRef[] = []
    for (const { chainId, positions } of positionResults) {
      for (const p of positions) {
        if (p.protocol !== 'Lido') continue
        const key = `${chainId}:${p.balanceOracle.toLowerCase()}`
        if (seen.has(key)) continue
        seen.add(key)
        refs.push({ chainId, oracle: p.balanceOracle })
      }
    }
    return refs
  }, [positionResults])

  // Stader withdrawal-queue oracles the account touches — drives the per-request-id drill-down (display only;
  // the adapter aggregates to a single WETH leg). Same shape as Lido, keyed off the resolved protocol name.
  const staderOracles = useMemo<StaderOracleRef[]>(() => {
    const seen = new Set<string>()
    const refs: StaderOracleRef[] = []
    for (const { chainId, positions } of positionResults) {
      for (const p of positions) {
        if (p.protocol !== 'Stader') continue
        const key = `${chainId}:${p.balanceOracle.toLowerCase()}`
        if (seen.has(key)) continue
        seen.add(key)
        refs.push({ chainId, oracle: p.balanceOracle })
      }
    }
    return refs
  }, [positionResults])

  // Kelp withdrawal-queue oracles the account touches — drives the per-request-id drill-down (display only).
  // Kelp is multi-asset (one leg per payout asset), so its drill-down map is keyed by oracle AND asset.
  const kelpOracles = useMemo<KelpOracleRef[]>(() => {
    const seen = new Set<string>()
    const refs: KelpOracleRef[] = []
    for (const { chainId, positions } of positionResults) {
      for (const p of positions) {
        if (p.protocol !== 'Kelp' && p.protocol !== 'Kelp DAO') continue
        const key = `${chainId}:${p.balanceOracle.toLowerCase()}`
        if (seen.has(key)) continue
        seen.add(key)
        refs.push({ chainId, oracle: p.balanceOracle })
      }
    }
    return refs
  }, [positionResults])

  // Ethena cooldown adapters the account touches — drives the cooling/ready-to-claim drill-down (display only;
  // the adapter reports a single USDe leg). One cooldown per account, so each ref yields at most one row.
  const ethenaOracles = useMemo<EthenaOracleRef[]>(() => {
    const seen = new Set<string>()
    const refs: EthenaOracleRef[] = []
    for (const { chainId, positions } of positionResults) {
      for (const p of positions) {
        if (p.protocol !== 'Ethena') continue
        const key = `${chainId}:${p.balanceOracle.toLowerCase()}`
        if (seen.has(key)) continue
        seen.add(key)
        refs.push({ chainId, oracle: p.balanceOracle })
      }
    }
    return refs
  }, [positionResults])

  // StakeWise V3 exit-queue adapters the account touches — drives the per-position pending/claimable
  // drill-down (display only; the adapter reports a single ETH leg). Filtered by protocolId, not protocol
  // name: the exit-queue adapter shares the "StakeWise V3" name with the vaults meta-adapter, so the
  // keccak256("stakewise-exit") slug is the only unambiguous discriminator.
  const stakewiseExitOracles = useMemo<StakeWiseExitOracleRef[]>(() => {
    const STAKEWISE_EXIT_PROTOCOL_ID = '0x304c70a6113f73971716dfe5604e9826967adbaad918beca2a7a1ac460a6b2b9'
    const seen = new Set<string>()
    const refs: StakeWiseExitOracleRef[] = []
    for (const { chainId, positions } of positionResults) {
      for (const p of positions) {
        if (p.protocolId.toLowerCase() !== STAKEWISE_EXIT_PROTOCOL_ID) continue
        const key = `${chainId}:${p.balanceOracle.toLowerCase()}`
        if (seen.has(key)) continue
        seen.add(key)
        refs.push({ chainId, oracle: p.balanceOracle })
      }
    }
    return refs
  }, [positionResults])

  const lidoWithdrawalsByKey = useLidoWithdrawals(account, lidoOracles)
  const staderWithdrawalsByKey = useStaderWithdrawals(account, staderOracles)
  const kelpWithdrawalsByKey = useKelpWithdrawals(account, kelpOracles)
  const ethenaWithdrawalsByKey = useEthenaCooldown(account, ethenaOracles)
  const stakewiseExitWithdrawalsByKey = useStakeWiseExitWithdrawals(account, stakewiseExitOracles)

  // Merge the per-request drill-down maps into one. Keys are `${chainId}:${oracle}:${asset}`, unique per
  // (adapter, leg), so no collision. protocol-group looks each leg up by that asset-aware key.
  const withdrawalsByKey = useMemo<WithdrawalsByKey>(() => {
    const m = new Map<string, WithdrawalRequestRow[]>()
    for (const [k, v] of lidoWithdrawalsByKey) m.set(k, v)
    for (const [k, v] of staderWithdrawalsByKey) m.set(k, v)
    for (const [k, v] of kelpWithdrawalsByKey) m.set(k, v)
    for (const [k, v] of ethenaWithdrawalsByKey) m.set(k, v)
    for (const [k, v] of stakewiseExitWithdrawalsByKey) m.set(k, v)
    return m
  }, [lidoWithdrawalsByKey, staderWithdrawalsByKey, kelpWithdrawalsByKey, ethenaWithdrawalsByKey, stakewiseExitWithdrawalsByKey])

  const totalPortfolioNav = navResults.reduce((s, r) => s + (r.nav?.value ?? 0n), 0n)

  const supplyTotal = useMemo(
    () => positionResults.flatMap((r) => r.positions).filter((p) => !p.isDebt).reduce((s, p) => s + (p.value > 0n ? p.value : 0n), 0n),
    [positionResults],
  )
  const borrowTotal = useMemo(
    () => positionResults.flatMap((r) => r.positions).filter((p) => p.isDebt).reduce((s, p) => s + (p.value < 0n ? -p.value : p.value), 0n),
    [positionResults],
  )

  function handleRefresh() { refetchNav(); refetchPositions(); startCooldown() }

  function toggleHideDust() {
    const next = !hideDust
    setHideDust(next)
    localStorage.setItem('nav-hide-dust', String(next))
  }

  return (
    <div className="min-h-screen bg-neutral-200">
      <div className="max-w-6xl mx-auto px-4">

        {/* Top bar — shared across Portfolio / Coverage / Price Feeds */}
        <DashboardNav
          active="portfolio"
          address={account}
          refresh={{ onClick: handleRefresh, canRefresh, secondsLeft }}
          right={
            <>
              <button
                type="button"
                onClick={() => exportCsv(positionResults, account)}
                disabled={isLoading}
                title="Export positions as CSV"
                className="text-neutral-700 hover:text-neutral-950 transition-colors disabled:opacity-70 disabled:cursor-not-allowed"
              >
                ↓ CSV
              </button>
              <button
                type="button"
                onClick={onReset}
                className="text-neutral-700 hover:text-neutral-950 transition-colors"
              >
                ✕
              </button>
            </>
          }
        />

        <ProfileHeader
          address={account}
          navResults={navResults}
          supplyTotal={supplyTotal}
          borrowTotal={borrowTotal}
        />

        <div className="flex gap-6 mt-6 pb-12">
          <ChainSidebar navResults={navResults} selectedChainId={selectedChainId} onSelect={setSelectedChainId} />

          <div className="flex-1 min-w-0">
            {/* Controls bar */}
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-2">
                <select
                  value={sortOrder} onChange={(e) => setSortOrder(e.target.value as SortOrder)}
                  className="text-xs border border-neutral-300 rounded-lg px-2 py-1.5 bg-white text-neutral-700 focus:outline-none focus:border-neutral-500"
                >
                  <option value="value-desc">Sort: Value ↓</option>
                  <option value="value-asc">Sort: Value ↑</option>
                  <option value="name-asc">Sort: Name A–Z</option>
                </select>
                <button
                  type="button" onClick={toggleHideDust}
                  className={`text-xs px-3 py-1.5 rounded-lg border transition-colors ${
                    hideDust
                      ? 'bg-neutral-950 text-white border-neutral-950'
                      : 'bg-white text-neutral-700 border-neutral-300 hover:border-neutral-500'
                  }`}
                >
                  {hideDust ? '⊘ Hiding dust' : '⊙ Show all'}
                </button>
              </div>
              {!isLoading && (
                <span className="text-xs text-neutral-700">{groups.length} {groups.length === 1 ? 'position' : 'positions'}</span>
              )}
            </div>

            {isLoading && (
              <div className="space-y-3">
                {[120, 80, 160, 80].map((h, i) => (
                  <div key={i} className="rounded-xl border border-neutral-400 bg-white animate-pulse" style={{ height: h }} />
                ))}
              </div>
            )}

            {!isLoading && groups.length === 0 && (
              <div className="text-center py-16 text-neutral-700 text-sm">
                {allGroups.length > 0
                  ? 'All positions are below the dust threshold ($1). Toggle "Show all" to see them.'
                  : `No positions found on ${selectedChainId ? 'this chain' : 'any chain'}.`
                }
              </div>
            )}

            {!isLoading && groups.map((group) => (
              <ProtocolGroup
                key={`${group.protocol}::${group.chainId}`}
                group={group}
                totalPortfolioNav={totalPortfolioNav}
                withdrawalsByKey={withdrawalsByKey}
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

// ─── Root ─────────────────────────────────────────────────────────────────────

export default function Page() {
  const [account, setAccount] = useState<`0x${string}` | null>(null)

  // Read address from URL on mount only — no Next.js router, no Suspense required
  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const addr = params.get('address')
    if (addr && isAddress(addr)) setAccount(addr as `0x${string}`)
  }, [])

  function handleSearch(addr: `0x${string}`) {
    addRecentSearch(addr)
    setAccount(addr)
    // Update URL without triggering a Next.js navigation (avoids Suspense state reset)
    window.history.replaceState(null, '', `/?address=${addr}`)
  }

  function handleReset() {
    setAccount(null)
    window.history.replaceState(null, '', '/')
  }

  return (
    <TooltipProvider>
      {account ? (
        <PortfolioView account={account} onReset={handleReset} />
      ) : (
        <SearchPage onSearch={handleSearch} />
      )}
    </TooltipProvider>
  )
}
