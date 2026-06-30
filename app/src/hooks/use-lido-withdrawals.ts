'use client'

import { useReadContracts } from 'wagmi'
import { AUTOREFRESH_INTERVAL_MS } from '@/config/chains'

// Per-NFT-id breakdown of a Lido withdrawal-queue position. The balance adapter emits one ETH leg per
// open request, all sharing a single static positionId (abi.encode(WITHDRAWAL_QUEUE)) with the request id in
// the per-leg positionInstanceId, so they reconcile to one account-level row — see the rationale in
// src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol. This hook re-derives the per-request detail directly
// from Lido's WithdrawalQueueERC721 for a *display-only* drill-down; it does not affect NAV.
export type LidoWithdrawalRequest = {
  id: bigint
  // ETH owed for this request, valued like the adapter: getClaimableEther for finalized requests,
  // amountOfStETH for not-yet-finalized ones (the adapter additionally caps a pending request at its live
  // share value on a negative rebase; this display-only hook does not). Denominated in ETH (the asset Lido pays on claim).
  ethOwed: bigint
  // Raw stETH locked at request time, for reference. Equals ethOwed except on a finalized request that
  // took a negative-rebase haircut at finalization.
  amountOfStETH: bigint
  isFinalized: boolean
}

// Keyed by `${chainId}:${oracle.toLowerCase()}:${asset.toLowerCase()}` — matches the key PositionRow computes from a position.
export type LidoWithdrawalsByKey = Map<string, LidoWithdrawalRequest[]>

export type LidoOracleRef = { chainId: number; oracle: `0x${string}` }

// Mirror the adapter's MAX_REQUESTS_PROBED — accounts above the cap are skipped there (reported as 0), so
// there's no aggregate leg to drill into; cap here too to avoid oversized/slow reads on a refetch interval.
const MAX_REQUESTS = 256

// LidoWithdrawalQueueBalanceAdapter exposes the queue address as a public immutable.
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
    name: 'getLastCheckpointIndex',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'getWithdrawalStatus',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '_requestIds', type: 'uint256[]' }],
    outputs: [{ type: 'tuple[]', components: withdrawalStatusComponents }],
  },
  {
    name: 'findCheckpointHints',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: '_requestIds', type: 'uint256[]' },
      { name: '_firstIndex', type: 'uint256' },
      { name: '_lastIndex', type: 'uint256' },
    ],
    outputs: [{ type: 'uint256[]' }],
  },
  {
    name: 'getClaimableEther',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: '_requestIds', type: 'uint256[]' },
      { name: '_hints', type: 'uint256[]' },
    ],
    outputs: [{ type: 'uint256[]' }],
  },
] as const

// Drill-down key includes the leg asset (chainId:oracle:asset) so it stays consistent with multi-asset
// adapters like Kelp. Lido's leg is always denominated in the native-ETH sentinel.
const NATIVE_ETH = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' as const
const keyOf = (chainId: number, oracle: string, asset: string) =>
  `${chainId}:${oracle.toLowerCase()}:${asset.toLowerCase()}`
const ZERO = '0x0000000000000000000000000000000000000000' as const

type RawStatus = {
  amountOfStETH: bigint
  amountOfShares: bigint
  owner: `0x${string}`
  timestamp: bigint
  isFinalized: boolean
  isClaimed: boolean
}

/// Fetches the per-NFT-id breakdown for each Lido withdrawal-queue position the account holds, valuing each
/// finalized request exactly as the adapter does (claimable ETH) and each pending one from amountOfStETH (see
/// LidoWithdrawalRequest.ethOwed for the adapter's extra negative-rebase cap on pending). `lidoOracles`
/// is the set of (chainId, oracle) pairs whose protocol resolved to Lido — derived from the already-fetched
/// positions, so an account with no Lido WQ position issues no extra reads.
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

  const queues = refs
    .map((r, i) => {
      const res = queueData?.[i]
      return { ...r, queue: res?.status === 'success' ? (res.result as `0x${string}`) : undefined }
    })
    .filter((q): q is LidoOracleRef & { queue: `0x${string}` } => !!q.queue)

  // Stage 2 — per queue: the account's open request ids + the last checkpoint index (interleaved 2-per-queue).
  const { data: idsData } = useReadContracts({
    contracts: queues.flatMap((q) => [
      {
        chainId: q.chainId,
        address: q.queue,
        abi: queueAbi,
        functionName: 'getWithdrawalRequests' as const,
        args: [account ?? ZERO] as const,
      },
      { chainId: q.chainId, address: q.queue, abi: queueAbi, functionName: 'getLastCheckpointIndex' as const },
    ]),
    query: { enabled: !!account && queues.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const withIds = queues.map((q, i) => {
    const idsRes = idsData?.[2 * i]
    const cpRes = idsData?.[2 * i + 1]
    const allIds = idsRes?.status === 'success' ? (idsRes.result as readonly bigint[]) : []
    const lastCheckpoint = cpRes?.status === 'success' ? (cpRes.result as bigint) : 0n
    // Cap parity with the adapter: above the cap it reports 0 (no leg), so render no breakdown.
    const ids = allIds.length > MAX_REQUESTS ? [] : allIds
    return { ...q, ids, lastCheckpoint }
  })

  // Stage 3 — status per id batch.
  const statusQueues = withIds.filter((q) => q.ids.length > 0)
  const { data: statusData } = useReadContracts({
    contracts: statusQueues.map((q) => ({
      chainId: q.chainId,
      address: q.queue,
      abi: queueAbi,
      functionName: 'getWithdrawalStatus' as const,
      args: [q.ids] as const,
    })),
    query: { enabled: !!account && statusQueues.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Flatten to unclaimed requests; collect the finalized ones (which need a claimable-ETH lookup).
  type Pending = { queueKey: string; id: bigint; amountOfStETH: bigint; isFinalized: boolean }
  const perQueue = new Map<string, Pending[]>()
  // One claimable lookup per finalized request, resolved per-request (single-element arrays) because
  // findCheckpointHints reverts on an unsorted batch and getWithdrawalRequests order isn't sorted.
  const finalizedLookups: {
    chainId: number
    queue: `0x${string}`
    queueKey: string
    id: bigint
    lastCheckpoint: bigint
  }[] = []

  statusQueues.forEach((q, i) => {
    const res = statusData?.[i]
    if (res?.status !== 'success') return
    const statuses = res.result as readonly RawStatus[]
    const key = keyOf(q.chainId, q.oracle, NATIVE_ETH)
    const list: Pending[] = []
    statuses.forEach((s, j) => {
      if (s.isClaimed) return // claimed requests are burned — the adapter excludes them too
      list.push({ queueKey: key, id: q.ids[j], amountOfStETH: s.amountOfStETH, isFinalized: s.isFinalized })
      if (s.isFinalized && q.lastCheckpoint !== 0n) {
        finalizedLookups.push({
          chainId: q.chainId,
          queue: q.queue,
          queueKey: key,
          id: q.ids[j],
          lastCheckpoint: q.lastCheckpoint,
        })
      }
    })
    if (list.length > 0) perQueue.set(key, list)
  })

  // Stage 4 — checkpoint hint per finalized request.
  const { data: hintData } = useReadContracts({
    contracts: finalizedLookups.map((f) => ({
      chainId: f.chainId,
      address: f.queue,
      abi: queueAbi,
      functionName: 'findCheckpointHints' as const,
      args: [[f.id], 1n, f.lastCheckpoint] as const,
    })),
    query: { enabled: !!account && finalizedLookups.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Stage 5 — claimable ETH per finalized request. Only build calls for requests whose checkpoint hint has
  // already resolved to a usable value: a hint of 0 means "not yet resolved / no checkpoint", and
  // getClaimableEther with a 0 hint would fail — so we skip it and let the request fall back to amountOfStETH
  // until the hint lands, rather than issuing a doomed call that just retries on the refetch interval.
  const claimReady = finalizedLookups
    .map((f, i) => {
      const hintRes = hintData?.[i]
      const hint = hintRes?.status === 'success' ? (hintRes.result as readonly bigint[])[0] ?? 0n : 0n
      return { f, hint }
    })
    .filter((x) => x.hint !== 0n)

  const { data: claimableData } = useReadContracts({
    contracts: claimReady.map(({ f, hint }) => ({
      chainId: f.chainId,
      address: f.queue,
      abi: queueAbi,
      functionName: 'getClaimableEther' as const,
      args: [[f.id], [hint]] as const,
    })),
    query: { enabled: !!account && claimReady.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // claimable[queueKey:id] = exact ETH for that finalized request.
  const claimableById = new Map<string, bigint>()
  claimReady.forEach(({ f }, i) => {
    const res = claimableData?.[i]
    if (res?.status !== 'success') return
    const eth = (res.result as readonly bigint[])[0] ?? 0n
    claimableById.set(`${f.queueKey}:${f.id}`, eth)
  })

  const out: LidoWithdrawalsByKey = new Map()
  for (const [key, list] of perQueue) {
    const requests: LidoWithdrawalRequest[] = list.map((p) => {
      // Finalized → exact claimable ETH (matches the adapter); pending → amountOfStETH (the adapter's
      // estimate until finalization, == ETH paid in the normal case). Fall back to amountOfStETH if the
      // claimable lookup hasn't resolved yet, so a row never renders blank.
      const claimable = p.isFinalized ? claimableById.get(`${key}:${p.id}`) : undefined
      return {
        id: p.id,
        ethOwed: claimable ?? p.amountOfStETH,
        amountOfStETH: p.amountOfStETH,
        isFinalized: p.isFinalized,
      }
    })
    out.set(key, requests)
  }

  return out
}

export { keyOf as lidoWithdrawalsKey }
