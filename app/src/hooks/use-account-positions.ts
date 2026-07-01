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
  // Human protocol name from the adapter's IPositionDescribable layer (e.g. "Aave V3", "Morpho", "Wallet").
  // The dashboard groups on this. Falls back to a truncated protocolId slug if the adapter returns none.
  protocol: string
  // Ordered display hierarchy BELOW the protocol, leaf last, sourced on-chain from IPositionDescribable
  // (positionLabels). Empty for simple positions. Drives the card title / sub-headers — see protocol-group.tsx.
  labels: readonly string[]
  // The on-chain position identity (abi.encode(...) per protocol). Legs of one logical position (e.g. a
  // StakeWise vault's Staking + Borrow legs, or every reserve of an Aave market) share it, so the dashboard
  // groups matched legs by it.
  positionId: string
  // The machine-level protocol slug hash (keccak256, e.g. keccak256("stakewise-exit")). Not rendered — used
  // as an unambiguous discriminator when the human `protocol` name is shared across adapters (e.g. the
  // StakeWise V3 vaults meta and the StakeWise exit-queue adapter both report "StakeWise V3").
  protocolId: `0x${string}`
  // PositionKind enum (src/utils/PositionKind.sol): 0 Wallet, 1 Supplied, 2 Borrowed, 3 Collateral, 4 Staking,
  // 5 Rewards, 6 Fees. Drives the per-leg role tag (see KIND_TO_TYPE in protocol-group.tsx).
  positionKind: number
  // True if this leg is not withdrawable now (a pending withdrawal-queue request, or a staked amount in/awaiting
  // its unstaking cooldown). False for fully-liquid legs and for every non-queue/non-cooldown adapter.
  isLocked: boolean
  // Ephemeral per-item coordinate (NFT / request / ticket id as bytes32), bytes32(0) when none. Display only —
  // excluded from the stable identity key.
  positionInstanceId: `0x${string}`
}

// Raw inner Position tuple as returned by getAccountPositionsVerbose (src/nav/INAVCalculator.sol :: Position).
// Field names mirror the on-chain struct (balanceAsset / balanceAdapter); the hook aliases them below.
type RawPosition = {
  balanceAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  balanceAdapter: `0x${string}`
  amount: bigint
  isDebt: boolean
  quoteAsset: { asset: `0x${string}`; symbol: string; decimals: number }
  value: bigint
  price: bigint
  priceDecimals: number
  stale: boolean
  quoteAssetStale: boolean
  protocolBrand: `0x${string}`
  protocolId: `0x${string}`
  protocolSubId: `0x${string}`
  positionId: `0x${string}`
  positionKind: number
  isLocked: boolean
  positionInstanceId: `0x${string}`
}

// VerbosePosition tuple (src/nav/INAVCalculator.sol :: VerbosePosition) — the typed Position plus the
// human protocolName and the on-chain display label hierarchy (leaf last), both from IPositionDescribable.
type RawVerbosePosition = {
  position: RawPosition
  protocolName: string
  labels: readonly string[]
}

export type ChainPositions = {
  chainId: number
  label: string
  positions: readonly OnchainPosition[]
  isLoading: boolean
  isError: boolean
}

export function useAccountPositions(account: `0x${string}` | undefined): { chains: ChainPositions[]; refetch: () => void } {
  // One verbose read per chain. This bundles what used to be two multicall phases (typed getAccountPositions,
  // then a separate protocolName()/positionLabels() sweep over each (chain, oracle, positionId)) into a single
  // getAccountPositionsVerbose call that returns the typed Position plus its human name and display labels.
  const posContracts = DEPLOYED_CHAINS.map(({ chain, navAddress }) => ({
    chainId: chain.id,
    address: navAddress,
    abi: navCalcAbi,
    functionName: 'getAccountPositionsVerbose' as const,
    args: [account ?? zeroAddress, zeroAddress] as const,
  }))

  const { data: posData, isLoading, refetch } = useReadContracts({
    contracts: posContracts,
    query: { enabled: !!account, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const chains = DEPLOYED_CHAINS.map(({ chain, label }, ci) => {
    const result = posData?.[ci]
    const verbose: RawVerbosePosition[] =
      result?.status === 'success' ? (result.result as RawVerbosePosition[]) : []
    const positions: OnchainPosition[] = verbose.map((v) => {
      const p = v.position
      // protocolName is authoritative for grouping; only fall back to a truncated slug if the adapter's
      // IPositionDescribable returned an empty name (should not happen for registered adapters).
      const protocol = v.protocolName.length > 0 ? v.protocolName : `${p.protocolId.slice(0, 10)}…`
      return {
        underlyingAsset: p.balanceAsset,
        balanceOracle: p.balanceAdapter,
        amount: p.amount,
        isDebt: p.isDebt,
        quoteAsset: p.quoteAsset,
        value: p.value,
        price: p.price,
        priceDecimals: p.priceDecimals,
        stale: p.stale,
        protocol,
        labels: v.labels,
        positionId: p.positionId,
        protocolId: p.protocolId,
        positionKind: p.positionKind,
        isLocked: p.isLocked,
        positionInstanceId: p.positionInstanceId,
      }
    })
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
