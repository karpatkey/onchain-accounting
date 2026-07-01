const assetComponents = [
  { name: 'asset', type: 'address' },
  { name: 'symbol', type: 'string' },
  { name: 'decimals', type: 'uint8' },
] as const

// The 17-field typed Position struct (src/nav/INAVCalculator.sol :: Position). Shared by getAccountPositions
// and the inner `position` tuple of getAccountPositionsVerbose. Field names mirror the on-chain struct
// (balanceAsset / balanceAdapter); the hook aliases them to the app's underlyingAsset / balanceOracle.
const positionComponents = [
  { name: 'balanceAsset', type: 'tuple', components: assetComponents },
  { name: 'balanceAdapter', type: 'address' },
  { name: 'amount', type: 'uint256' },
  { name: 'isDebt', type: 'bool' },
  { name: 'quoteAsset', type: 'tuple', components: assetComponents },
  { name: 'value', type: 'int256' },
  { name: 'price', type: 'int256' },
  { name: 'priceDecimals', type: 'uint8' },
  { name: 'stale', type: 'bool' },
  { name: 'quoteAssetStale', type: 'bool' },
  { name: 'protocolBrand', type: 'bytes32' },
  { name: 'protocolId', type: 'bytes32' },
  { name: 'protocolSubId', type: 'bytes32' },
  { name: 'positionId', type: 'bytes' },
  { name: 'positionKind', type: 'uint8' },
  { name: 'isLocked', type: 'bool' },
  { name: 'positionInstanceId', type: 'bytes32' },
] as const

export const navCalcAbi = [
  {
    name: 'getAccountNav',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'account', type: 'address' },
      { name: 'quoteAsset', type: 'address' },
    ],
    outputs: [
      {
        name: 'nav',
        type: 'tuple',
        components: [
          { name: 'value', type: 'int256' },
          { name: 'quoteAsset', type: 'tuple', components: assetComponents },
          { name: 'timestamp', type: 'uint64' },
          { name: 'stalePriceAssets', type: 'tuple[]', components: assetComponents },
          { name: 'sequencerDown', type: 'bool' },
          { name: 'quoteAssetStale', type: 'bool' },
        ],
      },
    ],
  },
  {
    name: 'getAccountPositions',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'account', type: 'address' },
      { name: 'quoteAsset', type: 'address' },
    ],
    outputs: [
      {
        name: 'positions',
        type: 'tuple[]',
        components: positionComponents,
      },
    ],
  },
  // Verbose read: the typed Position plus its human protocolName and on-chain display labels (leaf last),
  // both sourced from the adapter's IPositionDescribable layer. Bundles what the dashboard previously fetched
  // in a separate second multicall (protocolName() + positionLabels()) into a single call per chain.
  {
    name: 'getAccountPositionsVerbose',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'account', type: 'address' },
      { name: 'quoteAsset', type: 'address' },
    ],
    outputs: [
      {
        name: 'positions',
        type: 'tuple[]',
        components: [
          { name: 'position', type: 'tuple', components: positionComponents },
          { name: 'protocolName', type: 'string' },
          { name: 'labels', type: 'string[]' },
        ],
      },
    ],
  },
  {
    name: 'getPriceData',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'underlyingAsset', type: 'address' }],
    outputs: [
      {
        name: 'priceFeedData',
        type: 'tuple',
        components: [
          { name: 'priceFeed', type: 'address' },
          { name: 'priceType', type: 'uint8' },
          { name: 'price', type: 'int256' },
          { name: 'decimals', type: 'uint8' },
          { name: 'chainlinkHeartbeat', type: 'uint256' },
          { name: 'updatedAt', type: 'uint256' },
          { name: 'stale', type: 'bool' },
          { name: 'sequencerDown', type: 'bool' },
          { name: 'healthyFeedCount', type: 'uint256' },
        ],
      },
    ],
  },
  // All configured price feeds for an asset (the redundancy set). Field order mirrors the
  // on-chain IPrices.PriceFeedConfig struct: priceFeed, decimals, priceType, chainlinkHeartbeat.
  {
    name: 'getPriceFeeds',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [
      {
        name: 'configs',
        type: 'tuple[]',
        components: [
          { name: 'priceFeed', type: 'address' },
          { name: 'decimals', type: 'uint8' },
          { name: 'priceType', type: 'uint8' },
          { name: 'chainlinkHeartbeat', type: 'uint256' },
        ],
      },
    ],
  },
  {
    name: 'getRegisteredAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      {
        name: 'assets',
        type: 'tuple[]',
        components: assetComponents,
      },
    ],
  },
  {
    name: 'healthCheck',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'sequencerDown', type: 'bool' },
      { name: 'stalePriceAssets', type: 'address[]' },
    ],
  },
  {
    name: 'chainlinkL2SequencerGracePeriod',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  // Every registered balance adapter (plain + meta + assisted). Account-less — the coverage view
  // reads these to show which protocols/positions the NAV system values.
  {
    name: 'getAllAdapters',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: 'adapters', type: 'address[]' }],
  },
  // The active instance set governed on NAVCalculator for a meta-adapter (Aave V3 instances, Morpho
  // markets/vaults, Curve pools, …). Non-empty only for meta-adapters; empty for plain/assisted ones.
  {
    name: 'getMetaInstances',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'adapter', type: 'address' }],
    outputs: [{ name: 'instances', type: 'bytes32[]' }],
  },
] as const

// Adapter-level introspection (IPositionDescribable + IBalanceAdapter). Read directly off each
// adapter contract, not the NAV proxy. Fail-open: some adapters may revert on protocolName() (→
// treated as "Unknown") or return no underlyingAssetsSupported() (e.g. Merkl rewards, Uniswap V3).
export const adapterInfoAbi = [
  {
    name: 'protocolName',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'string' }],
  },
  {
    name: 'underlyingAssetsSupported',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address[]' }],
  },
  // On-chain display labels for a positionId (IPositionDescribable). Called with EMPTY bytes (0x) it
  // returns the adapter's product label(s): on a plain adapter e.g. ["Safety Module"] or a
  // ["Category", "Product"] pair; on a meta-adapter it returns [] (the labels live per-instance).
  // Called with a raw 32-byte instance coordinate (from getMetaInstances) it returns the instance's
  // ["Category", "Instance Name"] pair (e.g. ["Market", "Aave Ethereum Market"], ["AMM Liquidity Pool",
  // "WETH/rETH"]). Fail-open: some adapters revert / return [] for coordinates they don't recognise.
  {
    name: 'positionLabels',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'positionId', type: 'bytes' }],
    outputs: [{ name: '', type: 'string[]' }],
  },
  // IMetaBalanceAdapter — the underlying assets a specific meta instance covers (a Fluid vault's
  // collateral+debt, a pool's tokens, …). Used to name/iconify instances whose positionLabels only
  // yield a generic category ("Vault") and to render per-instance token logos. Fail-open on plain
  // adapters (which don't implement it) → empty.
  {
    name: 'underlyingAssetsSupportedForInstances',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'instances', type: 'bytes32[]' }],
    outputs: [{ name: '', type: 'address[]' }],
  },
] as const

// Minimal ERC20 — symbol() to resolve underlying assets not covered by getRegisteredAssets(), and
// name() as a fallback for meta-instance display names when positionLabels() yields only a generic
// category (e.g. a StakeWise / Fluid vault whose on-chain label is just "Vault").
export const erc20Abi = [
  {
    name: 'symbol',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'string' }],
  },
  {
    name: 'name',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'string' }],
  },
] as const

export const aggregatorV3Abi = [
  {
    name: 'latestRoundData',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'roundId', type: 'uint80' },
      { name: 'answer', type: 'int256' },
      { name: 'startedAt', type: 'uint256' },
      { name: 'updatedAt', type: 'uint256' },
      { name: 'answeredInRound', type: 'uint80' },
    ],
  },
] as const
