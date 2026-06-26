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
  // The on-chain position identity (abi.encode(...) per protocol). Legs of one logical position (e.g. a
  // StakeWise vault's Staking + Borrow legs) share it, so the dashboard can group matched legs by vault.
  positionId: string
  // The machine-level protocol slug hash (keccak256, e.g. keccak256("stakewise-exit")). Not rendered — used
  // as an unambiguous discriminator when the human `protocol` name is shared across adapters (e.g. the
  // StakeWise V3 vaults meta and the StakeWise exit-queue adapter both report "StakeWise V3").
  protocolId: `0x${string}`
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
  quoteAssetStale: boolean
  protocolId: `0x${string}`
  positionId: `0x${string}`
  positionKind: number
}

// IPositionDescribable (src/balances/IPositionDescribable.sol) — the display layer. protocolName() returns the
// human protocol name ("PancakeSwap V3"); positionLabels(positionId) returns an ordered hierarchy below the
// protocol, leaf last (e.g. ["Liquidity Pool", "NFT #22279"]). The dashboard renders these rather than the
// machine-level protocolId (a keccak slug, e.g. pancakeswap-v3): the slug and the human name are independent
// fields, so rendering never depends on the protocolId value. (For now we render the leaf — the last element;
// the full breadcrumb is a follow-up.)
const describableAbi = [
  { name: 'protocolName', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  {
    name: 'positionLabels',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'positionId', type: 'bytes' }],
    outputs: [{ type: 'string[]' }],
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
  // and one positionLabels() per distinct (chain, oracle, positionId). Multi-leg positions (e.g. Supply + Fees)
  // share a positionId, so de-duping keeps the describe call-count proportional to logical positions, not legs.
  const describeKey = (chainId: number, oracle: string, positionId: string) =>
    `${chainId}:${oracle.toLowerCase()}:${positionId}`
  const nameContracts: { chainId: number; address: `0x${string}`; abi: typeof describableAbi; functionName: 'protocolName'; key: string }[] = []
  const seenNameKeys = new Set<string>()
  const describeContracts: { chainId: number; address: `0x${string}`; abi: typeof describableAbi; functionName: 'positionLabels'; args: readonly [`0x${string}`] }[] = []
  const seenDescribeKeys = new Set<string>()

  rawByChain.forEach((positions, ci) => {
    const chainId = DEPLOYED_CHAINS[ci].chain.id
    for (const p of positions) {
      const key = `${chainId}:${p.balanceOracle.toLowerCase()}`
      if (!seenNameKeys.has(key)) {
        seenNameKeys.add(key)
        nameContracts.push({ chainId, address: p.balanceOracle, abi: describableAbi, functionName: 'protocolName', key })
      }
      const dKey = describeKey(chainId, p.balanceOracle, p.positionId)
      if (!seenDescribeKeys.has(dKey)) {
        seenDescribeKeys.add(dKey)
        describeContracts.push({ chainId, address: p.balanceOracle, abi: describableAbi, functionName: 'positionLabels', args: [p.positionId] })
      }
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
  const labelByDescribeKey = new Map<string, string>()
  describeContracts.forEach((c, i) => {
    const r = metaData?.[describeOffset + i]
    // positionLabels returns an ordered hierarchy (leaf last). Render the leaf as the per-position label
    // for now (matches the prior single-string behaviour); the full breadcrumb is a follow-up.
    if (r?.status === 'success' && Array.isArray(r.result) && r.result.length > 0) {
      const leaf = r.result[r.result.length - 1] as string
      if (leaf.length > 0) labelByDescribeKey.set(describeKey(c.chainId, c.address, c.args[0]), leaf)
    }
  })

  // Assemble. Labels are looked up by (chain, oracle, positionId), so the legs of a multi-leg position share one result.
  const chains = DEPLOYED_CHAINS.map(({ chain, label }, ci) => {
    const raw = rawByChain[ci]
    const positions: OnchainPosition[] = raw.map((p) => {
      const protocol = nameByKey.get(`${chain.id}:${p.balanceOracle.toLowerCase()}`) ?? `${p.protocolId.slice(0, 10)}…`
      const posLabel = labelByDescribeKey.get(describeKey(chain.id, p.balanceOracle, p.positionId))
      const type = KIND_TO_TYPE[p.positionKind] ?? null
      // positionDetail JSON is parsed by extractType (type → Supply/Fees split) + extractPoolLabel (name → row label).
      const detail: Record<string, string> = {}
      if (type) detail.type = type
      // Wallet rows (kind 0) group under one oracle sub-header; their positionLabels() leaf is just the token
      // symbol, so using it as `name` would render a misleading header (first token's symbol over a mixed-token
      // wallet group). The symbol is already shown per row — omit name for Wallet; keep it for protocol
      // positions where it's a real label (e.g. "NFT #22279"). When positionLabels() is empty (e.g. StakeWise
      // V3 Gnosis vaults don't implement name()), `name` stays unset — the per-vault layout groups by positionId
      // and renders the full vault address from it, so no synthetic label is needed here.
      if (posLabel && p.positionKind !== 0) detail.name = posLabel
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
        positionId: p.positionId,
        protocolId: p.protocolId,
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
