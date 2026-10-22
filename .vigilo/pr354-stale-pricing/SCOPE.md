# PR #354 scope (fix/nav-stale-best-available, HEAD d05cbcf8)
`git diff origin/main...HEAD -- src/` (13 files, +304/-243):
- src/constants.sol (MAX_STALE_PRICE_AGE = 7 days)
- src/prices/PriceFeedLib.sol (_selectFeedCore / _outranks / _readPrimaryFeed, _readFeedPrice, _divergenceFor/_monitorDivergence, _getQuoteAssetInfo revert, irregularForSelected internal->public)
- src/prices/NavBaseUsdLib.sol (stale base keeps price; baseStale = healthyFeedCount == 0)
- src/prices/BaseCustomPriceFeed.sol, ERC4626VaultRatePriceFeed.sol, TwoFeedChainlinkPriceFeed.sol, protocols/ankrETH_CustomPriceFeed.sol, protocols/InvertedChainlinkCustomPriceFeed.sol
- src/prices/Prices.sol, IPrices.sol, ICustomPriceFeed.sol, src/nav/INAVCalculator.sol (NatSpec + QuoteAssetUnpriceable error)
Context read in full: NAVCalculator.getPriceData/getPriceDataNoDivergence/initialize/registerAsset, Prices.latestPrice, PriceFeedLib buildPriceData/healthCheck/calculateValue/_buildPriceFeedCache/_priceConversion/addFeed/_validateFeedSupportInternal, origin/main NavBaseUsdLib + TwoFeedChainlinkPriceFeed, nav-config assets-and-price-feeds/*.json, chains/*.json sequencer feeds, deployments customPriceFeeds.
Out of scope: balances/, bridge/, scripts (except preflight heartbeat guard grep).
