// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title syrupUSDG Custom Price Oracle
/// @notice Returns the USD price of syrupUSDG as `(USDG/USD) × (USDG per syrupUSDG share)`, the vault's live
///         ERC-4626 exchange rate times the NAV's USDG/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the syrupUSDG vault, the NAV, and the base asset (USDG). Sibling of
///      {syrupUSDC_CustomPriceFeed}: same Maple `MaplePool` code, different underlying.
///
///      **The base asset is USDG, which is why this feed could not exist before 2026-09-16.** The base leg is read
///      from the NAV (ADR 0019), so USDG had to be a registered NAV asset first; until it was, there was no
///      USDG/USD price to scale the vault rate by. The base's own `BaseAssetMismatch` check enforces the pairing —
///      `baseAsset_` must equal the vault's `asset()` — so a copy-paste of the syrupUSDC config (baseAsset USDC)
///      reverts at construction rather than silently pricing USDG shares against USDC.
///
///      **Manipulation resistance, checked rather than assumed** (the gate in `docs/howto/add-price-feed.md` §B.2):
///      `MaplePool.totalAssets()` forwards to `IPoolManagerLike(manager).totalAssets()` — the pool manager's
///      accounting of cash plus loan principal plus accrued interest — NOT `balanceOf(vault)`. Measured live
///      2026-09-16: `totalAssets` 168,376,875.642470 USDG against a vault USDG balance of 8,060,166.467433, i.e.
///      cash is ~4.8% of assets, so the rate is not donation-spikeable in the way a naive balance-of vault is.
///
///      **One known property, shared with the live syrupUSDC feed and stated so it is not rediscovered as a
///      surprise:** `MaplePool.convertToAssets` divides the RAW `totalAssets()` by supply, while the pool's own
///      `convertToExitAssets` first subtracts `unrealizedLosses()`. The base prices with `convertToAssets`, so on a
///      loan default this feed keeps reporting the pre-loss rate until Maple realises the loss — an over-report in
///      that window. Both Maple vaults read `unrealizedLosses() == 0` at the time of writing, so the two paths
///      agree exactly today and the divergence is latent rather than active.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract syrupUSDG_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param syrupUsdg_ Address of the syrupUSDG vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDG) whose NAV-selected USD price scales the vault rate.
    constructor(address syrupUsdg_, address nav_, address baseAsset_)
        ERC4626VaultRatePriceFeed(syrupUsdg_, nav_, baseAsset_)
    {}
}
