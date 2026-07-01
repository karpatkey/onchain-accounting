'use client'

import { useReadContracts } from 'wagmi'
import { getAddress } from 'viem'
import { navCalcAbi, adapterInfoAbi, erc20Abi } from '@/config/abis'
import { AUTOREFRESH_INTERVAL_MS, DEPLOYED_CHAINS } from '@/config/chains'

// Registered-asset shape from getRegisteredAssets() — reused to resolve symbols without an extra
// ERC20 read for the assets the NAV system already prices.
type RegisteredAsset = {
  asset: `0x${string}`
  symbol: string
  decimals: number
}

// One asset an adapter covers, with a resolved (or fail-open truncated) symbol.
export type CoverageAsset = {
  address: `0x${string}`
  symbol: string
}

// One registered balance adapter (a "product" within a protocol brand). Meta-adapters carry a
// non-zero instanceCount (Aave V3 instances, Morpho markets/vaults, Curve pools, …).
export type AdapterInfo = {
  address: `0x${string}`
  protocolName: string
  assets: CoverageAsset[]
  instanceCount: number
  isMeta: boolean
}

// A protocol brand — one or more related adapters folded together (e.g. "Aave V3" + "Aave Umbrella"
// → one "Aave" group). assetCount/instanceCount aggregate across the group's adapters.
export type ProtocolCoverage = {
  brandKey: string
  displayName: string
  adapters: AdapterInfo[]
  assetCount: number
  instanceCount: number
}

export type ChainCoverage = {
  chainId: number
  label: string
  protocols: ProtocolCoverage[]
  adapterCount: number
  isLoading: boolean
  isError: boolean
}

// Version tokens stripped from the tail of a protocol name to derive the brand key, so that
// versioned products of one protocol fold together (Aave V3 + Aave Umbrella → "aave", Balancer V3
// + Balancer V2 → "balancer"). Order-insensitive; applied repeatedly until no tail token matches.
const VERSION_TAIL = /\s+(v\d+|dao|mutual|finance|protocol|labs)$/i

/// Normalise a protocol name to a stable brand key: lowercase, strip trailing version/qualifier
/// tokens ("v3", "dao", "mutual", …), then remove all whitespace. Robust and dependency-free.
/// e.g. "Aave V3" → "aave", "Aave Umbrella" → "aaveumbrella", "Balancer V3" → "balancer".
export function brandKeyOf(protocolName: string): string {
  let name = protocolName.trim()
  // Strip repeated trailing qualifier tokens (handles "Kelp DAO" → "Kelp", "Nexus Mutual" → "Nexus").
  let prev: string
  do {
    prev = name
    name = name.replace(VERSION_TAIL, '')
  } while (name !== prev)
  // Fold known sub-brands into their parent so related products group (Aave Umbrella → Aave).
  const collapsed = name.toLowerCase().replace(/\s+/g, '')
  if (collapsed.startsWith('aave')) return 'aave'
  if (collapsed.startsWith('morpho')) return 'morpho'
  return collapsed
}

/// Human display name for a brand group: the shortest adapter name in the group (its base/parent
/// form), so "Aave V3" + "Aave Umbrella" display as "Aave V3" — the shortest, most recognisable.
function displayNameFor(names: string[]): string {
  return names.reduce((a, b) => (b.length < a.length ? b : a))
}

function csAddress(address: string): `0x${string}` | null {
  try {
    return getAddress(address) as `0x${string}`
  } catch {
    return null
  }
}

export function useChainCoverage(chainIdx: number): ChainCoverage {
  const { chain, label, navAddress } = DEPLOYED_CHAINS[chainIdx]

  // 1. Registered adapters + registered assets (for symbol resolution) on the NAV proxy.
  const { data: baseData, isLoading: baseLoading } = useReadContracts({
    contracts: [
      {
        chainId: chain.id,
        address: navAddress,
        abi: navCalcAbi,
        functionName: 'getAllAdapters' as const,
      },
      {
        chainId: chain.id,
        address: navAddress,
        abi: navCalcAbi,
        functionName: 'getRegisteredAssets' as const,
      },
    ],
    query: { refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  const adapterAddresses =
    baseData?.[0]?.status === 'success'
      ? (baseData[0].result as readonly `0x${string}`[])
      : []

  const registeredAssets =
    baseData?.[1]?.status === 'success'
      ? (baseData[1].result as readonly RegisteredAsset[])
      : []

  // address(lowercase) → symbol, from the assets the NAV system already prices.
  const symbolByAddress = new Map<string, string>()
  for (const a of registeredAssets) symbolByAddress.set(a.asset.toLowerCase(), a.symbol)

  // 2. Per adapter: protocolName() + underlyingAssetsSupported() (on the adapter) and
  //    getMetaInstances(adapter) (on the NAV proxy). Interleaved 3-per-adapter, flattened.
  const perAdapterContracts = adapterAddresses.flatMap((addr) => [
    {
      chainId: chain.id,
      address: addr,
      abi: adapterInfoAbi,
      functionName: 'protocolName' as const,
    },
    {
      chainId: chain.id,
      address: addr,
      abi: adapterInfoAbi,
      functionName: 'underlyingAssetsSupported' as const,
    },
    {
      chainId: chain.id,
      address: navAddress,
      abi: navCalcAbi,
      functionName: 'getMetaInstances' as const,
      args: [addr] as const,
    },
  ])

  const { data: perAdapterData, isLoading: perAdapterLoading } = useReadContracts({
    contracts: perAdapterContracts,
    query: { enabled: adapterAddresses.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Decode per adapter (3 calls each, interleaved). wagmi infers a union across the mixed multicall,
  // so cast each result through `unknown` to its concrete shape. Fail-open on every read.
  type RawAdapter = {
    address: `0x${string}`
    protocolName: string
    assetAddresses: `0x${string}`[]
    instanceCount: number
  }
  const rawAdapters: RawAdapter[] = adapterAddresses.map((address, i) => {
    const nameR = perAdapterData?.[i * 3]
    const assetsR = perAdapterData?.[i * 3 + 1]
    const instR = perAdapterData?.[i * 3 + 2]

    const protocolName =
      nameR?.status === 'success' && (nameR.result as unknown as string)
        ? (nameR.result as unknown as string)
        : 'Unknown'
    const assetAddresses =
      assetsR?.status === 'success'
        ? [...(assetsR.result as unknown as readonly `0x${string}`[])]
        : []
    const instanceCount =
      instR?.status === 'success'
        ? (instR.result as unknown as readonly `0x${string}`[]).length
        : 0

    return { address, protocolName, assetAddresses, instanceCount }
  })

  // 3. Collect all unique underlying-asset addresses not covered by getRegisteredAssets; multicall
  //    symbol() for those. Fail-open to a truncated address.
  const unresolved: `0x${string}`[] = []
  const seen = new Set<string>()
  for (const ra of rawAdapters) {
    for (const asset of ra.assetAddresses) {
      const key = asset.toLowerCase()
      if (symbolByAddress.has(key) || seen.has(key)) continue
      seen.add(key)
      unresolved.push(asset)
    }
  }

  const symbolContracts = unresolved.map((addr) => ({
    chainId: chain.id,
    address: addr,
    abi: erc20Abi,
    functionName: 'symbol' as const,
  }))

  const { data: symbolData, isLoading: symbolLoading } = useReadContracts({
    contracts: symbolContracts,
    query: { enabled: unresolved.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  unresolved.forEach((addr, i) => {
    const r = symbolData?.[i]
    const sym = r?.status === 'success' ? (r.result as unknown as string) : ''
    symbolByAddress.set(addr.toLowerCase(), sym || `${addr.slice(0, 6)}…${addr.slice(-4)}`)
  })

  // 4. Build AdapterInfo per adapter.
  const adapters: AdapterInfo[] = rawAdapters.map((ra) => ({
    address: ra.address,
    protocolName: ra.protocolName,
    assets: ra.assetAddresses.map((asset) => ({
      address: (csAddress(asset) ?? asset) as `0x${string}`,
      symbol: symbolByAddress.get(asset.toLowerCase()) ?? `${asset.slice(0, 6)}…${asset.slice(-4)}`,
    })),
    instanceCount: ra.instanceCount,
    isMeta: ra.instanceCount > 0,
  }))

  // 5. Group adapters by protocol brand so related products fold together.
  const byBrand = new Map<string, AdapterInfo[]>()
  for (const a of adapters) {
    const key = brandKeyOf(a.protocolName)
    const bucket = byBrand.get(key)
    if (bucket) bucket.push(a)
    else byBrand.set(key, [a])
  }

  const protocols: ProtocolCoverage[] = Array.from(byBrand.entries()).map(([brandKey, group]) => {
    const uniqueAssets = new Set<string>()
    let instanceCount = 0
    for (const a of group) {
      for (const asset of a.assets) uniqueAssets.add(asset.address.toLowerCase())
      instanceCount += a.instanceCount
    }
    return {
      brandKey,
      displayName: displayNameFor(group.map((a) => a.protocolName)),
      adapters: group,
      assetCount: uniqueAssets.size,
      instanceCount,
    }
  })

  // Sort protocols by adapter count desc, then display name.
  protocols.sort(
    (a, b) => b.adapters.length - a.adapters.length || a.displayName.localeCompare(b.displayName),
  )

  return {
    chainId: chain.id,
    label,
    protocols,
    adapterCount: adapters.length,
    isLoading: baseLoading || perAdapterLoading || symbolLoading,
    isError: baseData?.[0]?.status === 'failure',
  }
}
