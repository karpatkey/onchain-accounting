// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BaseCustomPriceFeed} from "src/prices/BaseCustomPriceFeed.sol";

/// @title LBTC Custom Price Oracle
/// @notice USD price of LBTC = `LBTC.getRate()` (BTC per LBTC, 18 dec) × the NAV's WBTC/USD price.
/// @dev Shared skeleton (base/USD via the NAV, staleness, decimals, latestRoundData, the `rate × base/USD / 1e18`
///      math) lives in {BaseCustomPriceFeed}; this feed supplies only Lombard's exchange rate via `_rate()`.
///
///      **LBTC is yield-bearing, which is why the rate is read ON-CHAIN rather than taken from a market feed.**
///      Babylon staking rewards are converted to BTC and reflected in a rising LBTC→BTC exchange rate rather than
///      in holders' balances — the implementation behind the LBTC proxy is named `StakedLBTC` — so LBTC is the
///      same shape as rETH, cbETH, wstETH and ezETH, every one of which is priced here from its own on-chain
///      rate. The Chainlink LBTC/BTC feed is a MARKET price (`attributeType: dex_state_price`) and is wired as a
///      divergence MONITOR instead, via `LBTCCrossRateMarket`. Both legs read WBTC/USD from the same NAV, so the
///      base term cancels and the divergence check reduces to rate-vs-rate.
///
///      **Why WBTC is the base, and why that is not a WBTC bet:** the NAV prices WBTC with the Chainlink BTC/USD
///      feed, so WBTC/USD IS BTC/USD and the product is exactly `(BTC per LBTC) × (BTC/USD)`. WBTC is priced by
///      DIRECT feeds rather than by another NAV-sourced custom feed, which is what {NavBaseUsdLib}'s circularity
///      invariant requires of a base asset.
///
///      **The rate is stepwise and CAN FALL — do not treat it as a floor.** Lombard's docs describe the update as
///      continuous; the chain disagrees. Sampled every 3 days over 60 days: flat at 1.004899545 from 30d to 21d,
///      then −1.80, −0.83 and −4.57 bps to a trough of 1.004179667 at 12d, recovering to 1.005005450 — 3
///      decreases in 20 intervals, ~7.2 bps peak-to-trough. The long-run trend is up (~+16.6 bps over 180 days),
///      which is what makes the asset Appreciating, but this is not a monotonic accrual index like stETH's.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract LBTC_CustomPriceFeed is BaseCustomPriceFeed {
    /// @param lbtc_ The address of the LBTC token.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (WBTC) whose NAV-selected USD price scales the rate.
    constructor(address lbtc_, address nav_, address baseAsset_) BaseCustomPriceFeed(lbtc_, nav_, baseAsset_) {}

    /// @inheritdoc BaseCustomPriceFeed
    function _rate() internal view override returns (uint256) {
        return ILBTC(UNDERLYING).getRate();
    }
}

interface ILBTC {
    /// @notice Amount of BTC backing 1 LBTC (18 decimals).
    function getRate() external view returns (uint256);
}
