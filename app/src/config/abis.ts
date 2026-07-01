const assetComponents = [
  { name: 'asset', type: 'address' },
  { name: 'symbol', type: 'string' },
  { name: 'decimals', type: 'uint8' },
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
        components: [
          { name: 'underlyingAsset', type: 'tuple', components: assetComponents },
          { name: 'balanceOracle', type: 'address' },
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
