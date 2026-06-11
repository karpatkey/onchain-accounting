'use client'

import { useReadContracts } from 'wagmi'
import { AUTOREFRESH_INTERVAL_MS } from '@/config/chains'

// Per-NFT-id breakdown of a Lido withdrawal-queue position. The balance adapter aggregates all open
// requests into a single ETH leg (positionId = "", account-global) — see ADR rationale in
// src/balances/protocols/LidoWithdrawalQueue.sol. This hook re-derives the per-request detail directly
// from Lido's WithdrawalQueueERC721 for a *display-only* drill-down; it does not affect NAV.
export type LidoWithdrawalRequest = {
  id: bigint
  amountOfStETH: bigint
  isFinalized: boolean
  isClaimed: boolean
}

// Keyed by `${chainId}:${oracle.toLowerCase()}` — matches the key PositionRow computes from a position.
export type LidoWithdrawalsByKey = Map<string, LidoWithdrawalRequest[]>

export type LidoOracleRef = { chainId: number; oracle: `0x${string}` }

// LidoWithdrawalQueueBalanceOracle exposes the queue address as a public immutable.
const lidoAdapterAbi = [
  { name: 'WITHDRAWAL_QUEUE', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const

const withdrawalStatusComponents = [
  { name: 'amountOfStETH', type: 'uint256' },
  { name: 'amountOfShares', type: 'uint256' },
  { name: 'owner', type: 'address' },
  { name: 'timestamp', type: 'uint256' },
  { name: 'isFinalized', type: 'bool' },
  { name: 'isClaimed', type: 'bool' },
] as const

const queueAbi = [
  {
    name: 'getWithdrawalRequests',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '_owner', type: 'address' }],
    outputs: [{ type: 'uint256[]' }],
  },
  {
    name: 'getWithdrawalStatus',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '_requestIds', type: 'uint256[]' }],
    outputs: [{ type: 'tuple[]', components: withdrawalStatusComponents }],
  },
] as const

const keyOf = (chainId: number, oracle: string) => `${chainId}:${oracle.toLowerCase()}`

type RawStatus = {
  amountOfStETH: bigint
  amountOfShares: bigint
  owner: `0x${string}`
  timestamp: bigint
  isFinalized: boolean
  isClaimed: boolean
}

/// Fetches the per-NFT-id breakdown for each Lido withdrawal-queue position the account holds.
/// `lidoOracles` is the set of (chainId, oracle) pairs whose protocol resolved to Lido — derived from
/// the already-fetched positions, so an account with no Lido WQ position issues no extra reads.
export function useLidoWithdrawals(
  account: `0x${string}` | undefined,
  lidoOracles: LidoOracleRef[],
): LidoWithdrawalsByKey {
  // Stable list (sorted) so the dependency identity doesn't churn each render.
  const refs = [...lidoOracles].sort((a, b) =>
    a.chainId - b.chainId || a.oracle.toLowerCase().localeCompare(b.oracle.toLowerCase()),
  )

  // Stage 1 — resolve each adapter's WithdrawalQueue address.
  const { data: queueData } = useReadContracts({
    contracts: refs.map((r) => ({
      chainId: r.chainId,
      address: r.oracle,
      abi: lidoAdapterAbi,
      functionName: 'WITHDRAWAL_QUEUE' as const,
    })),
    query: { enabled: !!account && refs.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const queues = refs.map((r, i) => {
    const res = queueData?.[i]
    const queue = res?.status === 'success' ? (res.result as `0x${string}`) : undefined
    return { ...r, queue }
  })

  // Stage 2 — the account's open request ids per queue.
  const idsContracts = queues
    .filter((q) => q.queue)
    .map((q) => ({
      chainId: q.chainId,
      address: q.queue!,
      abi: queueAbi,
      functionName: 'getWithdrawalRequests' as const,
      args: [account ?? '0x0000000000000000000000000000000000000000'] as const,
    }))

  const { data: idsData } = useReadContracts({
    contracts: idsContracts,
    query: { enabled: !!account && idsContracts.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const queuesWithQueue = queues.filter((q) => q.queue)
  const withIds = queuesWithQueue.map((q, i) => {
    const res = idsData?.[i]
    const ids = res?.status === 'success' ? (res.result as readonly bigint[]) : []
    return { ...q, ids }
  })

  // Stage 3 — status per id batch.
  const statusContracts = withIds
    .filter((q) => q.ids.length > 0)
    .map((q) => ({
      chainId: q.chainId,
      address: q.queue!,
      abi: queueAbi,
      functionName: 'getWithdrawalStatus' as const,
      args: [q.ids] as const,
    }))

  const { data: statusData } = useReadContracts({
    contracts: statusContracts,
    query: { enabled: !!account && statusContracts.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const out: LidoWithdrawalsByKey = new Map()
  const withStatusQueues = withIds.filter((q) => q.ids.length > 0)
  withStatusQueues.forEach((q, i) => {
    const res = statusData?.[i]
    if (res?.status !== 'success') return
    const statuses = res.result as readonly RawStatus[]
    const requests: LidoWithdrawalRequest[] = []
    statuses.forEach((s, j) => {
      if (s.isClaimed) return // claimed requests are burned — the adapter excludes them too
      requests.push({ id: q.ids[j], amountOfStETH: s.amountOfStETH, isFinalized: s.isFinalized, isClaimed: s.isClaimed })
    })
    if (requests.length > 0) out.set(keyOf(q.chainId, q.oracle), requests)
  })

  return out
}

export { keyOf as lidoWithdrawalsKey }
