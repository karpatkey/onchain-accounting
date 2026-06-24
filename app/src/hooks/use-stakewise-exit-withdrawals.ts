'use client'

import { useReadContracts } from 'wagmi'
import { AUTOREFRESH_INTERVAL_MS } from '@/config/chains'
import { withdrawalsKey, type WithdrawalRequestRow } from '@/components/protocol-group'

// Display-only drill-down for StakeWise V3 exit-queue positions. The adapter aggregates every cached
// (vault, positionTicket, timestamp) tuple into one ETH leg (positionId ""); this hook re-derives the
// per-position detail for visibility. A position is identified on-chain by that tuple — we surface the
// vault (short address) + a truncated ticket so multiple requests are distinguishable. Each position is
// valued the same way the adapter sums it: `exitedAssets` (claimable) + `convertToAssets(leftShares)`
// (still in the queue). A partially-exited position yields two rows (a Claimable and a Pending portion);
// this never affects NAV.

export type StakeWiseExitOracleRef = { chainId: number; oracle: `0x${string}` }

const MAX_UINT256 = 2n ** 256n - 1n
const ZERO = '0x0000000000000000000000000000000000000000' as const

// StakeWiseExitQueueBalanceAdapter: the underlying asset + the cached (vault, ticket, ts) tuples per account.
const adapterAbi = [
  { name: 'UNDERLYING_TOKEN', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  {
    name: 'positionsOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [
      {
        type: 'tuple[]',
        components: [
          { name: 'vault', type: 'address' },
          { name: 'positionTicket', type: 'uint256' },
          { name: 'timestamp', type: 'uint256' },
        ],
      },
    ],
  },
] as const

// StakeWise V3 vault exit-queue reads (mirror the adapter's valuation).
const vaultAbi = [
  {
    name: 'getExitQueueIndex',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'positionTicket', type: 'uint256' }],
    outputs: [{ type: 'int256' }],
  },
  {
    name: 'calculateExitedAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'receiver', type: 'address' },
      { name: 'positionTicket', type: 'uint256' },
      { name: 'timestamp', type: 'uint256' },
      { name: 'exitQueueIndex', type: 'uint256' },
    ],
    outputs: [
      { name: 'leftTickets', type: 'uint256' },
      { name: 'exitedTickets', type: 'uint256' },
      { name: 'exitedAssets', type: 'uint256' },
    ],
  },
  {
    name: 'convertToAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'shares', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
  },
] as const

type Pos = { refIndex: number; chainId: number; vault: `0x${string}`; ticket: bigint; ts: bigint }

export function useStakeWiseExitWithdrawals(
  account: `0x${string}` | undefined,
  oracleRefs: StakeWiseExitOracleRef[],
): Map<string, WithdrawalRequestRow[]> {
  // Stable, deterministic order (mirrors the other queue hooks) so the contracts array doesn't re-key.
  const refs = [...oracleRefs].sort(
    (a, b) => a.chainId - b.chainId || a.oracle.toLowerCase().localeCompare(b.oracle.toLowerCase()),
  )

  // Round 1: per adapter, resolve UNDERLYING_TOKEN + the cached position tuples for the account.
  const meta = useReadContracts({
    allowFailure: true,
    contracts: refs.flatMap((r) => [
      { address: r.oracle, abi: adapterAbi, functionName: 'UNDERLYING_TOKEN', chainId: r.chainId } as const,
      { address: r.oracle, abi: adapterAbi, functionName: 'positionsOf', args: [account ?? ZERO], chainId: r.chainId } as const,
    ]),
    query: { enabled: !!account && refs.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const underlyingByRef = refs.map((_, i) => meta.data?.[i * 2]?.result as `0x${string}` | undefined)

  // Flatten all cached positions across adapters into one list (keeping the originating ref index).
  const positions: Pos[] = []
  refs.forEach((r, i) => {
    const list = meta.data?.[i * 2 + 1]?.result as
      | readonly { vault: `0x${string}`; positionTicket: bigint; timestamp: bigint }[]
      | undefined
    if (!list) return
    for (const p of list) {
      positions.push({ refIndex: i, chainId: r.chainId, vault: p.vault, ticket: p.positionTicket, ts: p.timestamp })
    }
  })

  // Round 2: checkpoint index per position (-1 ⇒ fully pending).
  const idxReads = useReadContracts({
    allowFailure: true,
    contracts: positions.map((p) => ({
      address: p.vault,
      abi: vaultAbi,
      functionName: 'getExitQueueIndex',
      args: [p.ticket],
      chainId: p.chainId,
    })),
    query: { enabled: positions.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Round 3: exited/left split per position. idx<0 ⇒ pass an out-of-range index (the adapter's trick): the
  // queue lib then returns leftTickets = full queued shares without reverting.
  const calcReads = useReadContracts({
    allowFailure: true,
    contracts: positions.map((p, j) => {
      const idx = idxReads.data?.[j]?.result as bigint | undefined
      const queryIdx = idx === undefined || idx < 0n ? MAX_UINT256 : idx
      return {
        address: p.vault,
        abi: vaultAbi,
        functionName: 'calculateExitedAssets',
        args: [account ?? ZERO, p.ticket, p.ts, queryIdx],
        chainId: p.chainId,
      } as const
    }),
    // Gate on the index read having landed for THIS positions set (length match): when the position set
    // changes, idxReads briefly holds the prior render's data — skip rather than compute queryIdx from a
    // mismatched index. Display-only; converges on the next refetch.
    query: {
      enabled: !!account && positions.length > 0 && idxReads.data?.length === positions.length,
      refetchInterval: AUTOREFRESH_INTERVAL_MS,
    },
  })

  // Round 4: value the still-queued remainder (leftTickets are vault shares) at the vault's current rate.
  const queuedReads = useReadContracts({
    allowFailure: true,
    contracts: positions.map((p, j) => {
      const res = calcReads.data?.[j]?.result as readonly [bigint, bigint, bigint] | undefined
      const leftShares = res?.[0] ?? 0n
      return {
        address: p.vault,
        abi: vaultAbi,
        functionName: 'convertToAssets',
        args: [leftShares],
        chainId: p.chainId,
      } as const
    }),
    query: {
      enabled: positions.length > 0 && calcReads.data?.length === positions.length,
      refetchInterval: AUTOREFRESH_INTERVAL_MS,
    },
  })

  const map = new Map<string, WithdrawalRequestRow[]>()
  // Only build rows once the exited-split read corresponds to the current positions set (length match);
  // otherwise wait for the next render rather than pairing a position with another's stale result.
  if (calcReads.data?.length !== positions.length) return map
  positions.forEach((p, j) => {
    const underlying = underlyingByRef[p.refIndex]
    const res = calcReads.data?.[j]?.result as readonly [bigint, bigint, bigint] | undefined
    if (!underlying || !res) return
    const [leftShares, , exitedAssets] = res
    const queued = (leftShares > 0n ? (queuedReads.data?.[j]?.result as bigint | undefined) : 0n) ?? 0n
    if (exitedAssets === 0n && queued === 0n) return // claimed / stale

    const ref = refs[p.refIndex]
    const key = withdrawalsKey(ref.chainId, ref.oracle, underlying)
    const rows = map.get(key) ?? []
    // Identity = vault (AddressChip) + positionTicket (truncated, copyable). A partially-exited position emits
    // both a claimable and a pending row; they share id (ticket) and are disambiguated by the renderer's
    // vault:ticket:finalized key, so no `+1` id hack is needed.
    const ticket = p.ticket.toString()
    if (exitedAssets > 0n) {
      rows.push({ id: p.ticket, ethOwed: exitedAssets, isFinalized: true, address: p.vault, ticket })
    }
    if (queued > 0n) {
      rows.push({ id: p.ticket, ethOwed: queued, isFinalized: false, address: p.vault, ticket })
    }
    map.set(key, rows)
  })
  return map
}
