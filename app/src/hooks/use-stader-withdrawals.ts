'use client'

import { useReadContracts } from 'wagmi'
import { AUTOREFRESH_INTERVAL_MS } from '@/config/chains'

// Per-request-id breakdown of a Stader ETHx withdrawal-queue position. The balance adapter emits one WETH leg
// per open request, all sharing a single static positionId (abi.encode(manager)) with the request id in the
// per-leg positionInstanceId, so they reconcile to one account-level row — see the rationale in
// src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol. This hook re-derives the per-request detail directly
// from Stader's UserWithdrawalManager for a *display-only* drill-down; it does not affect NAV.
//
// Stader's identifier is a sequential `requestId` (not an ERC721 NFT like Lido), enumerated via the
// `requestIdsByUserAddress(account, index)` getter — there is no bulk getter, so we probe indices until the
// array getter reverts (out of bounds). Each request is valued exactly the way the adapter sums it:
// `ethFinalized` once the batch is finalized, otherwise the request-time `ethExpected` estimate.
export type StaderWithdrawalRequest = {
  id: bigint
  // ETH owed for this request, matching what the adapter sums: ethFinalized when finalized, else ethExpected.
  ethOwed: bigint
  // True once the request's batch is finalized (ethFinalized > 0) — rendered as the "Claimable" badge.
  isFinalized: boolean
}

// Keyed by `${chainId}:${oracle.toLowerCase()}:${asset.toLowerCase()}` — matches the key protocol-group computes from a position.
export type StaderWithdrawalsByKey = Map<string, StaderWithdrawalRequest[]>

export type StaderOracleRef = { chainId: number; oracle: `0x${string}` }

// Mirror the adapter's MAX_REQUESTS_PROBED. The adapter sums only the first 256 requests (it stops at the cap
// and returns that partial total — it does NOT zero out an above-cap account), so probing the same 256 here
// keeps the sub-rows reconciling with the adapter's leg. The index getter is contiguous, so we stop at the
// first revert anyway.
const MAX_REQUESTS = 256

// StaderWithdrawalQueueBalanceAdapter exposes the manager address as a public immutable.
const staderAdapterAbi = [
  { name: 'USER_WITHDRAWAL_MANAGER', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const

const managerAbi = [
  {
    name: 'requestIdsByUserAddress',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'index', type: 'uint256' },
    ],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'userWithdrawRequests',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'requestId', type: 'uint256' }],
    outputs: [
      { name: 'owner', type: 'address' },
      { name: 'ethXAmount', type: 'uint256' },
      { name: 'ethExpected', type: 'uint256' },
      { name: 'ethFinalized', type: 'uint256' },
      { name: 'requestBlock', type: 'uint256' },
    ],
  },
] as const

// Drill-down key includes the leg asset (chainId:oracle:asset) so it stays consistent with multi-asset
// adapters like Kelp. Stader's withdrawal queue is mainnet-only and its adapter is immutable + single-asset
// (UNDERLYING_TOKEN = WETH), so hardcoding WETH always matches the position's underlyingAsset here — no need
// for an extra on-chain read. If Stader were ever deployed on another chain or token, derive this from the
// adapter's on-chain UNDERLYING_TOKEN instead (as the multi-asset Kelp hook does for its supported-asset list).
const WETH = '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2' as const
const keyOf = (chainId: number, oracle: string, asset: string) =>
  `${chainId}:${oracle.toLowerCase()}:${asset.toLowerCase()}`
const ZERO = '0x0000000000000000000000000000000000000000' as const

/// Fetches the per-request-id breakdown for each Stader withdrawal-queue position the account holds, valuing
/// each request the same way the adapter does (ethFinalized for finalized, ethExpected for pending).
/// `staderOracles` is the set of (chainId, oracle) pairs whose protocol resolved to Stader — derived from the
/// already-fetched positions, so an account with no Stader WQ position issues no extra reads.
export function useStaderWithdrawals(
  account: `0x${string}` | undefined,
  staderOracles: StaderOracleRef[],
): StaderWithdrawalsByKey {
  // Stable list (sorted) so the dependency identity doesn't churn each render.
  const refs = [...staderOracles].sort((a, b) =>
    a.chainId - b.chainId || a.oracle.toLowerCase().localeCompare(b.oracle.toLowerCase()),
  )

  // Stage 1 — resolve each adapter's UserWithdrawalManager address.
  const { data: managerData } = useReadContracts({
    contracts: refs.map((r) => ({
      chainId: r.chainId,
      address: r.oracle,
      abi: staderAdapterAbi,
      functionName: 'USER_WITHDRAWAL_MANAGER' as const,
    })),
    query: { enabled: !!account && refs.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const managers = refs
    .map((r, i) => {
      const res = managerData?.[i]
      return { ...r, manager: res?.status === 'success' ? (res.result as `0x${string}`) : undefined }
    })
    .filter((m): m is StaderOracleRef & { manager: `0x${string}` } => !!m.manager)

  // Stage 2 — probe requestIdsByUserAddress(account, i) for i in [0, MAX_REQUESTS). The getter reverts once the
  // index runs past the user's array; allowFailure surfaces that as a failed entry. MAX_REQUESTS contracts per
  // manager resolve in a single multicall batch.
  const { data: probeData } = useReadContracts({
    contracts: managers.flatMap((m) =>
      Array.from({ length: MAX_REQUESTS }, (_, i) => ({
        chainId: m.chainId,
        address: m.manager,
        abi: managerAbi,
        functionName: 'requestIdsByUserAddress' as const,
        args: [account ?? ZERO, BigInt(i)] as const,
      })),
    ),
    query: { enabled: !!account && managers.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Collect the contiguous prefix of successful ids per manager (stop at the first revert = end of the array).
  const withIds = managers.map((m, mi) => {
    const ids: bigint[] = []
    for (let i = 0; i < MAX_REQUESTS; i++) {
      const res = probeData?.[mi * MAX_REQUESTS + i]
      if (res?.status !== 'success') break
      ids.push(res.result as bigint)
    }
    return { ...m, ids }
  })

  // Stage 3 — read each request struct. Flatten across managers; remember which manager each id belongs to.
  const idLookups = withIds.flatMap((m) =>
    m.ids.map((id) => ({ chainId: m.chainId, manager: m.manager, key: keyOf(m.chainId, m.oracle, WETH), id })),
  )
  const { data: requestData } = useReadContracts({
    contracts: idLookups.map((l) => ({
      chainId: l.chainId,
      address: l.manager,
      abi: managerAbi,
      functionName: 'userWithdrawRequests' as const,
      args: [l.id] as const,
    })),
    query: { enabled: !!account && idLookups.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const out: StaderWithdrawalsByKey = new Map()
  idLookups.forEach((l, i) => {
    const res = requestData?.[i]
    if (res?.status !== 'success') return
    // userWithdrawRequests returns (owner, ethXAmount, ethExpected, ethFinalized, requestBlock).
    const [owner, , ethExpected, ethFinalized] = res.result as readonly [
      `0x${string}`,
      bigint,
      bigint,
      bigint,
      bigint,
    ]
    if (owner === ZERO) return // claimed: storage deleted but id may linger in the index array — the adapter skips it too
    const isFinalized = ethFinalized > 0n
    const req: StaderWithdrawalRequest = { id: l.id, ethOwed: isFinalized ? ethFinalized : ethExpected, isFinalized }
    const list = out.get(l.key)
    if (list) list.push(req)
    else out.set(l.key, [req])
  })

  return out
}

export { keyOf as staderWithdrawalsKey }
