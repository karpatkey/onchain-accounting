'use client'

import { useReadContracts } from 'wagmi'
import { AUTOREFRESH_INTERVAL_MS } from '@/config/chains'
import { withdrawalsKey, type WithdrawalRequestRow } from '@/components/protocol-group'

// Display-only drill-down for an Ethena sUSDe cooldown. Unlike Lido/Stader/Kelp (many requests per
// account, each with an id), Ethena keeps ONE cooldown per account — `sUSDe.cooldowns(account)` =
// (cooldownEnd, underlyingAmount). So there is no per-request id; we surface a single row whose state
// (cooling vs ready-to-claim) comes from `cooldownEnd` vs now, and whose label is the claimable date.
// The balance adapter already reports the USDe as one leg (positionId ""); this does not affect NAV.

export type EthenaOracleRef = { chainId: number; oracle: `0x${string}` }

// EthenaCooldownBalanceAdapter exposes the sUSDe + USDe addresses as public immutables.
const adapterAbi = [
  { name: 'STAKED_USDE', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { name: 'UNDERLYING_TOKEN', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const

const sUsdeAbi = [
  {
    name: 'cooldowns',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [
      { name: 'cooldownEnd', type: 'uint104' },
      { name: 'underlyingAmount', type: 'uint152' },
    ],
  },
] as const

export function useEthenaCooldown(
  account: `0x${string}` | undefined,
  oracleRefs: EthenaOracleRef[],
): Map<string, WithdrawalRequestRow[]> {
  // Stable, deterministic order (mirrors the Lido/Stader/Kelp hooks): if the caller's ref ordering churns
  // across renders, an unsorted contracts array would re-key and trigger needless refetching.
  const refs = [...oracleRefs].sort(
    (a, b) => a.chainId - b.chainId || a.oracle.toLowerCase().localeCompare(b.oracle.toLowerCase()),
  )

  // Round 1: resolve sUSDe + USDe per adapter.
  const meta = useReadContracts({
    allowFailure: true,
    contracts: refs.flatMap((r) => [
      { address: r.oracle, abi: adapterAbi, functionName: 'STAKED_USDE', chainId: r.chainId } as const,
      { address: r.oracle, abi: adapterAbi, functionName: 'UNDERLYING_TOKEN', chainId: r.chainId } as const,
    ]),
    query: { enabled: refs.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const sUsdeByRef = refs.map((_, i) => meta.data?.[i * 2]?.result as `0x${string}` | undefined)
  const usdeByRef = refs.map((_, i) => meta.data?.[i * 2 + 1]?.result as `0x${string}` | undefined)

  // Round 2: read the single cooldown struct per account — only for adapters whose sUSDe address
  // resolved in round 1 (so we never issue a call against the zero address). Keep the original ref
  // index so results map back to the right oracle/asset key.
  const resolved = refs
    .map((r, i) => ({ r, i, sUsde: sUsdeByRef[i] }))
    .filter((x): x is { r: EthenaOracleRef; i: number; sUsde: `0x${string}` } => !!x.sUsde)

  const cooldowns = useReadContracts({
    allowFailure: true,
    contracts: resolved.map(({ r, sUsde }) => ({
      address: sUsde,
      abi: sUsdeAbi,
      functionName: 'cooldowns',
      args: [account ?? '0x0000000000000000000000000000000000000000'],
      chainId: r.chainId,
    })),
    query: { enabled: !!account && resolved.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const map = new Map<string, WithdrawalRequestRow[]>()
  const nowSec = BigInt(Math.floor(Date.now() / 1000))
  resolved.forEach(({ r, i }, j) => {
    const usde = usdeByRef[i]
    const res = cooldowns.data?.[j]?.result as readonly [bigint, bigint] | undefined
    if (!usde || !res) return
    const [cooldownEnd, underlyingAmount] = res
    if (underlyingAmount === 0n) return
    const isFinalized = cooldownEnd <= nowSec
    const when = new Date(Number(cooldownEnd) * 1000)
    const label = isFinalized
      ? 'ready to claim'
      : `claimable ${when.toLocaleDateString()} ${when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`
    map.set(withdrawalsKey(r.chainId, r.oracle, usde), [
      { id: cooldownEnd, ethOwed: underlyingAmount, isFinalized, label },
    ])
  })
  return map
}
