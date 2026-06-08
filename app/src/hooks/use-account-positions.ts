'use client'

import { useReadContracts } from 'wagmi'
import { zeroAddress } from 'viem'
import { navCalcAbi } from '@/config/abis'
import { AUTOREFRESH_INTERVAL_MS, DEPLOYED_CHAINS } from '@/config/chains'

export type OnchainPosition = {
  underlyingAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  balanceOracle: `0x${string}`
  amount: bigint
  isDebt: boolean
  quoteAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  value: bigint
  price: bigint
  priceDecimals: number
  stale: boolean
  // Display fields synthesised from the typed-identity API + the adapter's IPositionDescribable layer.
  protocol: string
  positionDetail: string
}

// Raw tuple as returned by the typed-identity getAccountPositions (src/nav/INAVCalculator.sol :: Position).
type RawPosition = {
  underlyingAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  balanceOracle: `0x${string}`
  amount: bigint
  isDebt: boolean
  quoteAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  value: bigint
  price: bigint
  priceDecimals: number
  stale: boolean
  protocolId: `0x${string}`
  positionId: `0x${string}`
  positionKind: number
}

// IPositionDescribable (src/balances/IPositionDescribable.sol) — the display layer. protocolName() returns the
// human protocol name ("PancakeSwap V3"), describePosition(positionId) returns a per-position label ("NFT #22279").
// The dashboard renders these rather than the machine-level protocolId, so e.g. PancakeSwap V3 shows as
// "PancakeSwap V3" even though its inherited protocolId is uniswap-v3.
const describableAbi = [
  { name: 'protocolName', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  {
    name: 'describePosition',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'positionId', type: 'bytes' }],
    outputs: [{ type: 'string' }],
  },
] as const

// PositionKind enum (src/utils/PositionKind.sol) → the `type` discriminator the dashboard expects in
// positionDetail (legacy PositionType values). Wallet legs render flat (no type sub-header).
const KIND_TO_TYPE: Record<number, string | null> = {
  0: null, // Wallet
  1: 'Supply', // Supplied
  2: 'Borrow', // Borrowed
  3: 'Collateral',
  4: 'Staking',
  5: 'Rewards',
  6: 'Fees',
}

export type ChainPositions = {
  chainId: number
  label: string
  positions: readonly OnchainPosition[]
  isLoading: boolean
  isError: boolean
}

export function useAccountPositions(account: `0x${string}` | undefined): { chains: ChainPositions[]; refetch: () => void } {
  // Phase 1 — typed positions per chain.
  const posContracts = DEPLOYED_CHAINS.map(({ chain, navAddress }) => ({
    chainId: chain.id,
    address: navAddress,
    abi: navCalcAbi,
    functionName: 'getAccountPositions' as const,
    args: [account ?? zeroAddress, zeroAddress] as const,
  }))

  const { data: posData, isLoading, refetch } = useReadContracts({
    contracts: posContracts,
    query: { enabled: !!account, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const rawByChain: RawPosition[][] = DEPLOYED_CHAINS.map((_, i) => {
    const r = posData?.[i]
    return r?.status === 'success' ? (r.result as RawPosition[]) : []
  })

  // Phase 2 — display labels from the adapter's IPositionDescribable. One protocolName() per (chain, oracle)
  // and one describePosition() per (chain, position). Indices are tracked so results map back deterministically.
  const nameContracts: { chainId: number; address: `0x${string}`; abi: typeof describableAbi; functionName: 'protocolName'; key: string }[] = []
  const nameKeyToIdx = new Map<string, number>()
  const describeContracts: { chainId: number; address: `0x${string}`; abi: typeof describableAbi; functionName: 'describePosition'; args: readonly [`0x${string}`] }[] = []

  rawByChain.forEach((positions, ci) => {
    const chainId = DEPLOYED_CHAINS[ci].chain.id
    for (const p of positions) {
      const key = `${chainId}:${p.balanceOracle.toLowerCase()}`
      if (!nameKeyToIdx.has(key)) {
        nameKeyToIdx.set(key, nameContracts.length)
        nameContracts.push({ chainId, address: p.balanceOracle, abi: describableAbi, functionName: 'protocolName', key })
      }
      describeContracts.push({ chainId, address: p.balanceOracle, abi: describableAbi, functionName: 'describePosition', args: [p.positionId] })
    }
  })

  const allMeta = [
    ...nameContracts.map(({ chainId, address, abi, functionName }) => ({ chainId, address, abi, functionName })),
    ...describeContracts.map(({ chainId, address, abi, functionName, args }) => ({ chainId, address, abi, functionName, args })),
  ]

  const { data: metaData } = useReadContracts({
    contracts: allMeta,
    query: { enabled: !!account && allMeta.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const nameByKey = new Map<string, string>()
  nameContracts.forEach((c, i) => {
    const r = metaData?.[i]
    if (r?.status === 'success' && typeof r.result === 'string' && r.result.length > 0) nameByKey.set(c.key, r.result)
  })
  const describeOffset = nameContracts.length
  const labelByGlobalIdx: (string | undefined)[] = describeContracts.map((_, i) => {
    const r = metaData?.[describeOffset + i]
    return r?.status === 'success' && typeof r.result === 'string' && r.result.length > 0 ? r.result : undefined
  })

  // Assemble. describeContracts was built in the same chain/position order, so a running counter maps labels back.
  let describeCursor = 0
  const chains = DEPLOYED_CHAINS.map(({ chain, label }, ci) => {
    const raw = rawByChain[ci]
    const positions: OnchainPosition[] = raw.map((p) => {
      const protocol = nameByKey.get(`${chain.id}:${p.balanceOracle.toLowerCase()}`) ?? `${p.protocolId.slice(0, 10)}…`
      const posLabel = labelByGlobalIdx[describeCursor++]
      const type = KIND_TO_TYPE[p.positionKind] ?? null
      // positionDetail JSON is parsed by extractType (type → Supply/Fees split) + extractPoolLabel (name → row label).
      const detail: Record<string, string> = {}
      if (type) detail.type = type
      if (posLabel) detail.name = posLabel
      return {
        underlyingAsset: p.underlyingAsset,
        balanceOracle: p.balanceOracle,
        amount: p.amount,
        isDebt: p.isDebt,
        quoteAsset: p.quoteAsset,
        value: p.value,
        price: p.price,
        priceDecimals: p.priceDecimals,
        stale: p.stale,
        protocol,
        positionDetail: Object.keys(detail).length > 0 ? JSON.stringify(detail) : '',
      }
    })
    const result = posData?.[ci]
    return {
      chainId: chain.id,
      label,
      positions,
      isLoading,
      isError: result?.status === 'failure',
    }
  })

  return { chains, refetch: () => { void refetch() } }
}
