'use client'

import { useReadContracts } from 'wagmi'
import { getAddress } from 'viem'
import { navCalcAbi, adapterInfoAbi, erc20Abi } from '@/config/abis'
import { AUTOREFRESH_INTERVAL_MS, DEPLOYED_CHAINS } from '@/config/chains'

// 32-byte zero positionId used to probe a plain adapter's product label. Fixed-label adapters ignore the
// arg (Safety Module → ["Safety Module"]); adapters that decode it (Nexus, Uniswap V3) require ≥32 bytes to
// return their category ("Staking Pools", "AMM Liquidity Pool") instead of an empty array. Fail-open.
const ZERO_POSITION_ID = `0x${'0'.repeat(64)}` as const

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

// One instance of a meta-adapter (a specific market / pool / vault / gauge), identified on-chain by its
// raw bytes32 coordinate. `address` is the low-20-byte address when the coordinate is a left-padded address
// (Aave/Morpho-vaults/Gearbox/Balancer/Curve instances), else null (raw-hash ids — e.g. Morpho market ids).
export type CoverageInstance = {
  id: `0x${string}`
  address: `0x${string}` | null
  name: string
  category: string
  // The instance's underlying tokens (a Fluid vault's collateral+debt, a pool's tokens) — for per-row
  // token logos, and to name instances whose positionLabels only yield a generic category.
  tokens: CoverageAsset[]
}

// One registered balance adapter — a "product" within a protocol brand. Plain adapters carry `assets`
// (the leaf); meta-adapters carry `instances` (the markets/pools/vaults, each valued live).
export type CoverageProduct = {
  adapter: `0x${string}`
  protocolName: string
  productLabel: string
  // Secondary leaf for plain adapters — the specific token/name below the feature (e.g. feature
  // "Withdrawal Queue" + detail "stETH"). null for meta adapters and single-label features.
  detail: string | null
  isMeta: boolean
  // Assisted (agent-fed) adapter — its positions are covered via submitted coordinates, not derived
  // from on-chain enumeration. Drives a "how it works" hint (Uniswap V3, Nexus, Merkl, exit queues).
  isAssisted: boolean
  category: string | null
  instances: CoverageInstance[]
  assets: CoverageAsset[]
}

// A protocol brand — one or more related adapters folded together (e.g. "Aave V3" + "Aave Umbrella"
// → one "Aave" group). Counts aggregate across the group's products.
export type ProtocolCoverage = {
  brandKey: string
  displayName: string
  url: string | null
  products: CoverageProduct[]
  productCount: number
  instanceCount: number
  assetCount: number
}

export type ChainCoverage = {
  chainId: number
  label: string
  protocols: ProtocolCoverage[]
  productCount: number
  isLoading: boolean
  isError: boolean
}

// Protocol landing pages, keyed the same way the portfolio ProtocolGroup lookup is (substring match on a
// normalised protocol/brand key). Replicated from src/components/protocol-group.tsx so the coverage tree's
// protocol rows link out to the live app for each protocol.
const PROTOCOL_URLS: Record<string, string> = {
  aave: 'https://app.aave.com/',
  pancakeswap: 'https://pancakeswap.finance/liquidity/positions',
  morpho: 'https://app.morpho.org/',
  balancer: 'https://balancer.fi/',
  uniswap: 'https://app.uniswap.org/',
  curve: 'https://curve.fi/',
  sky: 'https://sky.money/',
  spark: 'https://spark.fi/',
  gearbox: 'https://app.gearbox.fi/',
  euler: 'https://app.euler.finance/',
  ethena: 'https://app.ethena.fi/',
  etherfi: 'https://app.ether.fi/',
  stakewise: 'https://app.stakewise.io/',
  nexus: 'https://app.nexusmutual.io/',
  lido: 'https://stake.lido.fi/',
  kelp: 'https://kelpdao.xyz/',
  stader: 'https://www.staderlabs.com/',
  convex: 'https://www.convexfinance.com/',
  fluid: 'https://fluid.io/',
  compound: 'https://app.compound.finance/',
  merkl: 'https://app.merkl.xyz/',
  cap: 'https://cap.app/',
}

function urlForBrand(brandKey: string): string | null {
  const key = brandKey.toLowerCase().replace(/[\s_.-]/g, '')
  for (const [k, url] of Object.entries(PROTOCOL_URLS)) {
    if (key.includes(k)) return url
  }
  return null
}

// Aave instances expose canonical getMarketId() strings that don't match Aave's UI branding. Alias them to
// the familiar names for display only — the on-chain positionLabels leaf stays canonical. Mirrors the alias
// map in src/components/protocol-group.tsx.
const MARKET_ALIASES: Record<string, string> = {
  'Aave Ethereum Market': 'Core Market',
  'Aave V3 Lido Ethereum': 'Prime Market',
}

function aliasName(name: string): string {
  return MARKET_ALIASES[name] ?? name
}

// Version tokens stripped from the tail of a protocol name to derive the brand key, so that
// versioned products of one protocol fold together (Aave V3 + Aave Umbrella → "aave", Balancer V3
// + Balancer V2 → "balancer"). Order-insensitive; applied repeatedly until no tail token matches.
const VERSION_TAIL = /\s+(v\d+|dao|mutual|finance|protocol|labs)$/i

/// Normalise a protocol name to a stable brand key: lowercase, strip trailing version/qualifier
/// tokens ("v3", "dao", "mutual", …), then remove all whitespace. Robust and dependency-free.
/// e.g. "Aave V3" → "aave", "Aave Umbrella" → "aave" (aave* sub-brands fold in), "Balancer V3" → "balancer".
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

/// Pluralise a shared instance category for a meta-adapter's product label ("Market" → "Markets",
/// "AMM Liquidity Pool" → "AMM Liquidity Pools", "Staking Gauge" → "Staking Gauges"). Generic English
/// rule: already-plural (trailing "s") is left alone; a trailing consonant+"y" → "ies"; else add "s".
function pluralize(category: string): string {
  const c = category.trim()
  if (!c) return c
  if (/s$/i.test(c)) return c
  if (/[^aeiou]y$/i.test(c)) return `${c.slice(0, -1)}ies`
  return `${c}s`
}

/// A meta-adapter instance coordinate is a 32-byte word; when it's a left-padded 20-byte address (24 leading
/// hex zeros) recover the address, else null (raw-hash ids like Morpho market ids aren't addresses).
function addressFromInstanceId(id: string): `0x${string}` | null {
  const hex = id.startsWith('0x') ? id.slice(2) : id
  if (hex.length !== 64 || !/^0{24}/.test(hex)) return null
  return csAddress(`0x${hex.slice(24)}`)
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

  // 2. Per adapter (5 calls each, interleaved, flattened): protocolName(), positionLabels(0x),
  //    underlyingAssetsSupported() and ASSISTANT_ROLE() on the adapter, and getMetaInstances(adapter)
  //    on the NAV proxy.
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
      functionName: 'positionLabels' as const,
      args: [ZERO_POSITION_ID] as const,
    },
    {
      chainId: chain.id,
      address: navAddress,
      abi: navCalcAbi,
      functionName: 'getMetaInstances' as const,
      args: [addr] as const,
    },
    {
      chainId: chain.id,
      address: addr,
      abi: adapterInfoAbi,
      functionName: 'underlyingAssetsSupported' as const,
    },
    {
      chainId: chain.id,
      address: addr,
      abi: adapterInfoAbi,
      functionName: 'ASSISTANT_ROLE' as const,
    },
  ])

  const { data: perAdapterData, isLoading: perAdapterLoading } = useReadContracts({
    contracts: perAdapterContracts,
    query: { enabled: adapterAddresses.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Decode per adapter (5 calls each, interleaved). wagmi infers a union across the mixed multicall,
  // so cast each result through `unknown` to its concrete shape. Fail-open on every read.
  type RawAdapter = {
    address: `0x${string}`
    protocolName: string
    productLabels: string[]
    instanceIds: `0x${string}`[]
    assetAddresses: `0x${string}`[]
    isAssisted: boolean
  }
  const rawAdapters: RawAdapter[] = adapterAddresses.map((address, i) => {
    const nameR = perAdapterData?.[i * 5]
    const labelsR = perAdapterData?.[i * 5 + 1]
    const instR = perAdapterData?.[i * 5 + 2]
    const assetsR = perAdapterData?.[i * 5 + 3]
    const roleR = perAdapterData?.[i * 5 + 4]

    const protocolName =
      nameR?.status === 'success' && (nameR.result as unknown as string)
        ? (nameR.result as unknown as string)
        : 'Unknown'
    const productLabels =
      labelsR?.status === 'success'
        ? [...(labelsR.result as unknown as readonly string[])]
        : []
    const instanceIds =
      instR?.status === 'success'
        ? [...(instR.result as unknown as readonly `0x${string}`[])]
        : []
    const assetAddresses =
      assetsR?.status === 'success'
        ? [...(assetsR.result as unknown as readonly `0x${string}`[])]
        : []

    // Assisted adapters (agent-fed: Merkl, ether.fi/StakeWise exit, Uniswap V3, Nexus) expose the public
    // ASSISTANT_ROLE constant; plain/meta adapters revert. Used only to explain how they're covered.
    const isAssisted = roleR?.status === 'success'

    return { address, protocolName, productLabels, instanceIds, assetAddresses, isAssisted }
  })

  // 3. Per instance across all adapters (flattened): positionLabels(<raw instance bytes32>) on that adapter.
  //    Each returns ["Category", "Instance Name"]. Keep a flat parallel list of (adapterIdx, instanceId).
  type FlatInstance = { adapterIdx: number; id: `0x${string}` }
  const flatInstances: FlatInstance[] = []
  rawAdapters.forEach((ra, adapterIdx) => {
    for (const id of ra.instanceIds) flatInstances.push({ adapterIdx, id })
  })

  const instanceLabelContracts = flatInstances.map((fi) => ({
    chainId: chain.id,
    address: rawAdapters[fi.adapterIdx].address,
    abi: adapterInfoAbi,
    functionName: 'positionLabels' as const,
    args: [fi.id] as const,
  }))

  const { data: instanceLabelData, isLoading: instanceLoading } = useReadContracts({
    contracts: instanceLabelContracts,
    query: { enabled: flatInstances.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })

  // Decode each instance's positionLabels into (category, leaf). `category` = labels[0] (e.g. "Vault",
  // "Market", "AMM Liquidity Pool"); `leaf` = the distinct instance name (labels[1..]) — empty when the
  // adapter only exposes the category (e.g. StakeWise / Fluid vaults return just ["Vault"]).
  const decoded = flatInstances.map((fi, i) => {
    const r = instanceLabelData?.[i]
    const labels =
      r?.status === 'success' ? (r.result as unknown as readonly string[]) : ([] as readonly string[])
    return {
      adapterIdx: fi.adapterIdx,
      id: fi.id,
      address: addressFromInstanceId(fi.id),
      category: labels.length >= 1 ? labels[0] : '',
      leaf: labels.length >= 2 ? labels[labels.length - 1] : '',
    }
  })

  // 3b. Per-instance underlying tokens (IMetaBalanceAdapter.underlyingAssetsSupportedForInstances([id])) —
  //     drives per-row token logos, and names instances whose positionLabels give only a category ("Vault"
  //     → its collateral+debt, e.g. "wstETH/USDC"). Fail-open (plain adapters don't implement it).
  const instUnderlyingContracts = flatInstances.map((fi) => ({
    chainId: chain.id,
    address: rawAdapters[fi.adapterIdx].address,
    abi: adapterInfoAbi,
    functionName: 'underlyingAssetsSupportedForInstances' as const,
    args: [[fi.id]] as const,
  }))
  const { data: instUnderlyingData, isLoading: instUnderlyingLoading } = useReadContracts({
    contracts: instUnderlyingContracts,
    query: { enabled: flatInstances.length > 0, refetchInterval: AUTOREFRESH_INTERVAL_MS },
  })
  const instTokenAddrs: `0x${string}`[][] = flatInstances.map((_, i) => {
    const r = instUnderlyingData?.[i]
    return r?.status === 'success' ? [...(r.result as unknown as readonly `0x${string}`[])] : []
  })

  // 4. Symbol resolution for all underlying assets (adapter-level + per-instance) not already priced.
  const unresolved: `0x${string}`[] = []
  const seen = new Set<string>()
  const queueSymbol = (asset: `0x${string}`) => {
    const key = asset.toLowerCase()
    if (symbolByAddress.has(key) || seen.has(key)) return
    seen.add(key)
    unresolved.push(asset)
  }
  for (const ra of rawAdapters) for (const asset of ra.assetAddresses) queueSymbol(asset)
  for (const toks of instTokenAddrs) for (const asset of toks) queueSymbol(asset)

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

  const resolveSym = (addr: `0x${string}`) =>
    symbolByAddress.get(addr.toLowerCase()) ?? `${addr.slice(0, 6)}…${addr.slice(-4)}`

  // Build CoverageInstances now that symbols resolve. Name priority: positionLabels leaf → underlying
  // token symbols joined ("wstETH/USDC") → category → truncated id. `tokens` carry the per-instance
  // underlying for the per-row logos.
  const instancesByAdapter = new Map<number, CoverageInstance[]>()
  decoded.forEach((d, i) => {
    const tokens: CoverageAsset[] = instTokenAddrs[i].map((a) => ({
      address: (csAddress(a) ?? a) as `0x${string}`,
      symbol: resolveSym(a),
    }))
    const tokenName = tokens.length > 0 ? tokens.map((t) => t.symbol).join('/') : ''
    const rawName = d.leaf || tokenName || d.category || `${d.id.slice(0, 10)}…${d.id.slice(-6)}`
    const inst: CoverageInstance = {
      id: d.id,
      address: d.address,
      name: aliasName(rawName),
      category: d.category,
      tokens,
    }
    const bucket = instancesByAdapter.get(d.adapterIdx)
    if (bucket) bucket.push(inst)
    else instancesByAdapter.set(d.adapterIdx, [inst])
  })

  // 5. Build a CoverageProduct per adapter.
  const products: CoverageProduct[] = rawAdapters.map((ra, adapterIdx) => {
    const instances = instancesByAdapter.get(adapterIdx) ?? []
    const isMeta = instances.length > 0
    // Shared instance category (they're uniform per meta-adapter — all "Market" / "AMM Liquidity Pool" / …).
    const sharedCategory = isMeta ? (instances[0].category || null) : (ra.productLabels[0] || null)

    // Plain adapter: positionLabels('0x') → ["Feature", "Token"] or ["Feature"] or []. Use the FIRST
    // element as the product label — the FEATURE we cover ("Withdrawal Queue", "Safety Module",
    // "Unstaking Cooldown", "Market", "Claimable Rewards") — not the token leaf. The token (2nd element,
    // e.g. "stETH") rides in `detail` as muted context. Fall back to protocolName when empty.
    // Meta adapter: pluralize the shared instance category (Market → Markets); the specific markets/pools/
    // vaults/gauges are the instances below, so there is no detail leaf.
    let productLabel: string
    let detail: string | null = null
    if (isMeta) {
      productLabel = sharedCategory ? pluralize(sharedCategory) : ra.protocolName
    } else {
      productLabel = ra.productLabels.length > 0 ? ra.productLabels[0] : ra.protocolName
      // Detail is the token leaf (e.g. "stETH"); drop it when it's the hex address our zero-positionId
      // probe produced for adapters that echo the coordinate (Nexus → "Staking Pools" + "0x000…").
      const leaf = ra.productLabels.length > 1 ? ra.productLabels[ra.productLabels.length - 1] : ''
      detail = leaf && !/^0x[0-9a-f]/i.test(leaf) ? leaf : null
    }

    const assets: CoverageAsset[] = ra.assetAddresses
      .map((asset) => ({
        address: (csAddress(asset) ?? asset) as `0x${string}`,
        symbol: symbolByAddress.get(asset.toLowerCase()) ?? `${asset.slice(0, 6)}…${asset.slice(-4)}`,
      }))
      .sort((a, b) => a.symbol.localeCompare(b.symbol))

    return {
      adapter: ra.address,
      protocolName: ra.protocolName,
      productLabel,
      detail,
      isMeta,
      isAssisted: ra.isAssisted,
      category: sharedCategory,
      instances,
      assets,
    }
  })

  // 6. Group products by protocol brand so related products fold together.
  type BrandGroup = { products: CoverageProduct[]; names: string[] }
  const byBrand = new Map<string, BrandGroup>()
  rawAdapters.forEach((ra, i) => {
    const key = brandKeyOf(ra.protocolName)
    const bucket = byBrand.get(key)
    if (bucket) {
      bucket.products.push(products[i])
      bucket.names.push(ra.protocolName)
    } else {
      byBrand.set(key, { products: [products[i]], names: [ra.protocolName] })
    }
  })

  const protocols: ProtocolCoverage[] = Array.from(byBrand.entries()).map(([brandKey, group]) => {
    const uniqueAssets = new Set<string>()
    let instanceCount = 0
    for (const p of group.products) {
      for (const a of p.assets) uniqueAssets.add(a.address.toLowerCase())
      instanceCount += p.instances.length
    }
    // Products sorted alphabetically by label; each product's instances (markets/pools/vaults) too.
    const sortedProducts = [...group.products]
      .map((p) => ({ ...p, instances: [...p.instances].sort((x, y) => x.name.localeCompare(y.name)) }))
      .sort((a, b) => a.productLabel.localeCompare(b.productLabel))
    return {
      brandKey,
      displayName: displayNameFor(group.names),
      url: urlForBrand(brandKey),
      products: sortedProducts,
      productCount: group.products.length,
      instanceCount,
      assetCount: uniqueAssets.size,
    }
  })

  // Wallet holdings always pinned first (the base "tokens we track directly" statement); every other
  // protocol sorted alphabetically by display name.
  protocols.sort((a, b) => {
    const aw = a.brandKey === 'wallet' ? 0 : 1
    const bw = b.brandKey === 'wallet' ? 0 : 1
    return aw - bw || a.displayName.localeCompare(b.displayName)
  })

  return {
    chainId: chain.id,
    label,
    protocols,
    productCount: products.length,
    isLoading:
      baseLoading || perAdapterLoading || instanceLoading || instUnderlyingLoading || symbolLoading,
    isError: baseData?.[0]?.status === 'failure',
  }
}
