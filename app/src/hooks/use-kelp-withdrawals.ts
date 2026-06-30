'use client'

import { useReadContracts } from 'wagmi'
import { AUTOREFRESH_INTERVAL_MS } from '@/config/chains'

// Per-request breakdown of a Kelp DAO rsETH exit-queue position. The balance adapter emits one Supplied leg
// per open request (per Kelp-supported payout asset — stETH / ETHx / native ETH), all sharing a single static
// positionId (abi.encode(WITHDRAWAL_MANAGER)) with the request's userNonce in the per-leg positionInstanceId,
// so they reconcile to one account-level row per asset. This hook re-derives the per-request detail directly
// from Kelp's LRTWithdrawalManager for a *display-only* drill-down. It does not affect NAV.
//
// Kelp's identifier is the request's `userNonce` within its asset queue. A request is claimable once the
// asset's lock cursor has advanced past it (`userNonce < nextLockedNonce(asset)`); otherwise it's pending.
// Each request is valued the same way the adapter sums it — `expectedAssetAmount`.
//
// Unlike Lido/Stader, Kelp is multi-asset, so requests are keyed by `${chainId}:${oracle}:${asset}` — one
// drill-down bucket per leg, matching the asset-aware key protocol-group computes from each position.
export type KelpWithdrawalRequest = {
  id: bigint // userNonce
  ethOwed: bigint // expectedAssetAmount (the owed payout in that asset)
  isFinalized: boolean // claimable: userNonce < nextLockedNonce(asset)
}

export type KelpWithdrawalsByKey = Map<string, KelpWithdrawalRequest[]>

export type KelpOracleRef = { chainId: number; oracle: `0x${string}` }

// Mirror the adapter's MAX_REQUESTS_PROBED — accounts above the cap have their leg capped there too.
const MAX_REQUESTS = 256

// KelpWithdrawalQueueBalanceAdapter exposes the manager address as a public immutable.
const kelpAdapterAbi = [
  { name: 'WITHDRAWAL_MANAGER', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const

const managerAbi = [
  { name: 'lrtConfig', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  {
    name: 'userAssociatedNonces',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'asset', type: 'address' },
      { name: 'user', type: 'address' },
    ],
    outputs: [
      { name: 'begin', type: 'uint128' },
      { name: 'end', type: 'uint128' },
    ],
  },
  {
    name: 'nextLockedNonce',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'getUserWithdrawalRequest',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'asset', type: 'address' },
      { name: 'user', type: 'address' },
      { name: 'userIndex', type: 'uint256' },
    ],
    outputs: [
      { name: 'rsETHAmount', type: 'uint256' },
      { name: 'expectedAssetAmount', type: 'uint256' },
      { name: 'withdrawalStartBlock', type: 'uint256' },
      { name: 'userNonce', type: 'uint256' },
    ],
  },
] as const

const configAbi = [
  {
    name: 'getSupportedAssetList',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address[]' }],
  },
] as const

const keyOf = (chainId: number, oracle: string, asset: string) =>
  `${chainId}:${oracle.toLowerCase()}:${asset.toLowerCase()}`
const ZERO = '0x0000000000000000000000000000000000000000' as const

/// Fetches the per-request breakdown for each Kelp exit-queue position the account holds, one drill-down
/// bucket per (oracle, payout asset). `kelpOracles` is the set of (chainId, oracle) pairs whose protocol
/// resolved to Kelp — derived from the already-fetched positions, so an account with no Kelp position issues
/// no extra reads.
export function useKelpWithdrawals(
  account: `0x${string}` | undefined,
  kelpOracles: KelpOracleRef[],
): KelpWithdrawalsByKey {
  const refs = [...kelpOracles].sort((a, b) =>
    a.chainId - b.chainId || a.oracle.toLowerCase().localeCompare(b.oracle.toLowerCase()),
  )

  // Stage 1 — resolve each adapter's LRTWithdrawalManager address.
  const { data: managerData } = useReadContracts({
    contracts: refs.map((r) => ({
      chainId: r.chainId,
      address: r.oracle,
      abi: kelpAdapterAbi,
      functionName: 'WITHDRAWAL_MANAGER' as const,
    })),
    query: { enabled: !!account && refs.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const managers = refs
    .map((r, i) => {
      const res = managerData?.[i]
      return { ...r, manager: res?.status === 'success' ? (res.result as `0x${string}`) : undefined }
    })
    .filter((m): m is KelpOracleRef & { manager: `0x${string}` } => !!m.manager)

  // Stage 2 — resolve each manager's LRTConfig.
  const { data: configData } = useReadContracts({
    contracts: managers.map((m) => ({
      chainId: m.chainId,
      address: m.manager,
      abi: managerAbi,
      functionName: 'lrtConfig' as const,
    })),
    query: { enabled: !!account && managers.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Keep only managers whose LRTConfig resolved — unresolved ones have nothing to read in Stage 3, and issuing
  // a getSupportedAssetList call against a ZERO placeholder just adds a guaranteed multicall failure each refresh.
  const withConfig = managers
    .map((m, i) => {
      const res = configData?.[i]
      return { ...m, config: res?.status === 'success' ? (res.result as `0x${string}`) : undefined }
    })
    .filter((m): m is KelpOracleRef & { manager: `0x${string}`; config: `0x${string}` } => !!m.config)

  // Stage 3 — the supported (payout) asset list per config.
  const { data: assetListData } = useReadContracts({
    contracts: withConfig.map((m) => ({
      chainId: m.chainId,
      address: m.config,
      abi: configAbi,
      functionName: 'getSupportedAssetList' as const,
    })),
    query: { enabled: !!account && withConfig.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Flatten to one (oracle, manager, asset) row per supported asset.
  const oracleAssets = withConfig.flatMap((m, i) => {
    const res = assetListData?.[i]
    const assets = res?.status === 'success' ? (res.result as readonly `0x${string}`[]) : []
    return assets.map((asset) => ({ chainId: m.chainId, oracle: m.oracle, manager: m.manager, asset }))
  })

  // Stage 4 — per (manager, asset): the account's open-nonce range + the asset's lock cursor (2 reads each).
  const { data: nonceData } = useReadContracts({
    contracts: oracleAssets.flatMap((oa) => [
      {
        chainId: oa.chainId,
        address: oa.manager,
        abi: managerAbi,
        functionName: 'userAssociatedNonces' as const,
        args: [oa.asset, account ?? ZERO] as const,
      },
      {
        chainId: oa.chainId,
        address: oa.manager,
        abi: managerAbi,
        functionName: 'nextLockedNonce' as const,
        args: [oa.asset] as const,
      },
    ]),
    query: { enabled: !!account && oracleAssets.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const withRanges = oracleAssets.map((oa, i) => {
    const nonceRes = nonceData?.[2 * i]
    const lockRes = nonceData?.[2 * i + 1]
    const range = nonceRes?.status === 'success' ? (nonceRes.result as readonly [bigint, bigint]) : undefined
    const begin = range ? range[0] : 0n
    const end = range ? range[1] : 0n
    const nextLocked = lockRes?.status === 'success' ? (lockRes.result as bigint) : 0n
    // Number of live requests; cap parity with the adapter. Cap in bigint space first, then convert — the
    // range can be arbitrarily large, and Number() on a huge bigint loses precision (or yields Infinity).
    const raw = end - begin
    const capped = raw < 0n ? 0n : raw > BigInt(MAX_REQUESTS) ? BigInt(MAX_REQUESTS) : raw
    const count = Number(capped)
    return { ...oa, count, nextLocked }
  })

  // Stage 5 — each live request's struct (expectedAssetAmount + userNonce). Flatten across (oracle, asset, i).
  const reqLookups = withRanges.flatMap((r) =>
    Array.from({ length: r.count }, (_, i) => ({
      chainId: r.chainId,
      manager: r.manager,
      asset: r.asset,
      key: keyOf(r.chainId, r.oracle, r.asset),
      nextLocked: r.nextLocked,
      index: i,
    })),
  )
  const { data: reqData } = useReadContracts({
    contracts: reqLookups.map((l) => ({
      chainId: l.chainId,
      address: l.manager,
      abi: managerAbi,
      functionName: 'getUserWithdrawalRequest' as const,
      args: [l.asset, account ?? ZERO, BigInt(l.index)] as const,
    })),
    query: { enabled: !!account && reqLookups.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const out: KelpWithdrawalsByKey = new Map()
  reqLookups.forEach((l, i) => {
    const res = reqData?.[i]
    if (res?.status !== 'success') return
    // getUserWithdrawalRequest returns (rsETHAmount, expectedAssetAmount, withdrawalStartBlock, userNonce).
    const [, expectedAssetAmount, , userNonce] = res.result as readonly [bigint, bigint, bigint, bigint]
    const req: KelpWithdrawalRequest = {
      id: userNonce,
      ethOwed: expectedAssetAmount,
      isFinalized: userNonce < l.nextLocked, // claimable once the asset's lock cursor passes the nonce
    }
    const list = out.get(l.key)
    if (list) list.push(req)
    else out.set(l.key, [req])
  })

  return out
}

export { keyOf as kelpWithdrawalsKey }
