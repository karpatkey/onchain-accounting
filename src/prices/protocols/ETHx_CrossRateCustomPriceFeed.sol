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
///      Classic Push ETHx/ETH feed to Chainlink's ETHx/ETH feed (`0xC499ec76…`, `description() == "ETHx / ETH"`,
///      18-dec) because RedStone is sunsetting all its ETHx feeds. There is no Chainlink ETHx/USD feed, so the
///      ETH-quoted cross-rate is the only Chainlink route. The 18 decimals need no config change — the base captures
///      `10 ** RATE_FEED.decimals()` in its constructor, so the rate decimals cancel into `NAV_DECIMALS`. The
///      methodology is a genuine market quote, independent of Stader's on-chain rate.
///
///      **⚠️ OPEN BLOCKER — this feed cannot currently be CONSTRUCTED.** The configured `0xC499ec76…` is the raw
///      access-controlled aggregator, not its `EACAggregatorProxy`. Chainlink's `SimpleReadAccessController` grants
///      access when `_user == tx.origin`, so a direct EOA `eth_call` succeeds (which is why `cast call` and a config
///      review both pass) while **every contract is denied**: measured on mainnet, `checkEnabled() == true` and
///      `hasAccess(<contract>, "") == false`. {OracleArgumentChecks-assertChainlinkOracle} probes `latestRoundData()`
///      in a `try`, the call is denied, and this constructor reverts `NotChainlinkOracle()`. So the monitor is not
///      merely blind — it cannot be deployed, and `_deployEthxCrossRate()` (`03_DeployPriceFeeds.s.sol:211` → `:639`)
///      reverts during `03_DeployPriceFeeds` simulation. That is the NAMED deploy function, not the generic
///      `_deployCrossRateMonitor` at `:598` — ETHx does not use the generic helper.
///      "Right pair" and "readable on-chain" are independent properties: this feed's
///      `description()` is correctly `"ETHx / ETH"`, so a description-based pair assertion would NOT have caught it.
///      The fix is a config change (point at the proxy whose `aggregator()` returns `0xC499ec76…`, sourced not
///      guessed) and is tracked separately — see `PRICE_ADAPTERS.md` §7 for the four required proof checks.
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
