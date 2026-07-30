// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {CrossRateCustomPriceFeed} from "src/prices/protocols/CrossRateCustomPriceFeed.sol";

/// @title ETHx Cross-Rate Custom Price Oracle
/// @notice Returns the USD price of ETHx as `(ETHx/ETH) × (ETH/USD)`, the rate from a Chainlink-ABI feed and the
///         `ETH/USD` leg from the NAV's own selector (ADR 0019).
/// @dev Thin {CrossRateCustomPriceFeed} subclass — the cross-rate compose/staleness math lives in the base; this
///      only pins ETHx's feeds and gives the deployment its own named contract.
///
///      **Registered as a `monitorFeed`, NOT as a price feed.** It never prices the NAV: monitors are read only to
///      compute `divergenceBps` against the primary {ETHx_CustomPriceFeed} (Stader `getExchangeRate`), which carries
///      a 250 bps divergence tolerance. PR #151 replaced freshest-wins redundancy for this instance with the
///      primary-plus-monitors model, so this feed is not a fallback source and cannot win a selection.
///
///      **The `ETHx/ETH` rate leg is CHAINLINK, not RedStone.** It was migrated on 2026-07-27 from the Redstone
///      Classic Push ETHx/ETH feed to Chainlink because RedStone is sunsetting all its ETHx feeds. There is no
///      Chainlink ETHx/USD feed, so the ETH-quoted cross-rate is the only Chainlink route. The 18 decimals need no
///      config change — the base captures `10 ** RATE_FEED.decimals()` in its constructor, so the rate decimals cancel
///      into `NAV_DECIMALS`. A genuine market quote, independent of Stader's on-chain rate in source and methodology,
///      so this monitor CAN register a market depeg.
///
///      **The configured feed MUST be the `EACAggregatorProxy` `0xC5f8c4aB…`, never the aggregator it wraps.** Until
///      2026-07-30 the config pointed at `0xC499ec76…`, the raw access-controlled aggregator underneath that proxy,
///      which made this feed **impossible to construct**. Chainlink's `SimpleReadAccessController` grants access when
///      `_user == tx.origin`, so a direct EOA `eth_call` succeeds — which is why both `cast call` and a config review
///      passed it — while **every contract is denied**: measured on mainnet, `checkEnabled() == true` and
///      `hasAccess(<contract>, "") == false`. {OracleArgumentChecks-assertChainlinkOracle} probes `latestRoundData()`
///      in a `try`, was denied, and this constructor reverted `NotChainlinkOracle()`, so `_deployEthxCrossRate()`
///      (`03_DeployPriceFeeds.s.sol:211` → `:639` — the NAMED deploy function; ETHx does not use the generic
///      `_deployCrossRateMonitor` at `:598`) reverted during simulation, leaving phantom `customPriceFeeds` addresses
///      in `deployments/1.json` because `vm.writeJson` side effects are not rolled back.
///
///      **The durable lesson: "right pair" and "readable on-chain" are independent properties.** The bad address's
///      `description()` was correctly `"ETHx / ETH"`, so a description-based pair assertion would NOT have caught it —
///      only construction from a contract context did. `test/prices/protocols/fork/ETHx_RateFeedProxy.fork.t.sol`
///      guards the config address and pins the regression; see `PRICE_ADAPTERS.md` §7 for the four proof checks.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract ETHx_CrossRateCustomPriceFeed is CrossRateCustomPriceFeed {
    /// @param ethx_ The ETHx token address.
    /// @param ethxToEthFeed_ The ETHx/ETH feed (rate; Redstone Classic Push proxy, Chainlink ABI).
    /// @param ethxToEthHeartbeat_ Staleness threshold (seconds) for the ETHx/ETH feed.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (e.g. WETH) whose NAV-selected USD price scales the rate.
    constructor(address ethx_, address ethxToEthFeed_, uint256 ethxToEthHeartbeat_, address nav_, address baseAsset_)
        CrossRateCustomPriceFeed(ethx_, ethxToEthFeed_, ethxToEthHeartbeat_, nav_, baseAsset_)
    {}
}
