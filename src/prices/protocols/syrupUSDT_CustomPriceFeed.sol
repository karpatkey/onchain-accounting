// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title syrupUSDT Custom Price Oracle
/// @notice Returns the USD price of syrupUSDT as `(USDT/USD) × (USDT per syrupUSDT share)`, the vault's live
///         ERC-4626 exchange rate times the NAV's USDT/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the syrupUSDT vault, the NAV, and the base asset (USDT). Third member of the
///      Maple family here, alongside {syrupUSDC_CustomPriceFeed} and {syrupUSDG_CustomPriceFeed}: same
///      `MaplePool` code, different underlying, so the pricing logic is deliberately identical across all three.
///
///      **Requested for the XAUt carry fund's syrupUSDT leg.** Before this feed, `isAssetRegistered(syrupUSDT)`
///      was false and `getPriceData` reverted, so a syrupUSDT position did not appear in NAV at all.
///
///      **The base asset is USDT, which was already registered and priced by a DIRECT Chainlink feed** — that is
///      what {NavBaseUsdLib}'s circularity invariant requires of a base, and it means the syrupUSDT share is
///      valued with the same USDT/USD price every other USDT leg in the portfolio uses. The base's
///      `BaseAssetMismatch` check enforces the pairing against the vault's own `asset()`, so a copy-paste of the
///      syrupUSDC or syrupUSDG config reverts at construction rather than silently pricing against the wrong
///      dollar.
///
///      **Manipulation resistance, checked rather than assumed** (the gate in `docs/howto/add-price-feed.md`):
///      `MaplePool.totalAssets()` forwards to `IPoolManagerLike(manager).totalAssets()` — cash plus loan
///      principal plus accrued interest — NOT `balanceOf(vault)`. Measured live 2026-09-17: `totalAssets`
///      336,758,291.074368 USDT against a vault USDT balance of 642,712.210795, i.e. cash is **0.19%** of assets,
///      so a donation moves the share rate by a correspondingly tiny fraction of the donated amount. That is a
///      wider margin than the sibling syrupUSDG feed (4.8%).
///
///      **Same latent property as its siblings, restated so it is not rediscovered:** `MaplePool.convertToAssets`
///      divides the RAW `totalAssets()` by supply, while the pool's own `convertToExitAssets` first subtracts
///      `unrealizedLosses()`. The base prices with `convertToAssets`, so on a loan default this over-reports
///      until Maple realises the loss. `unrealizedLosses()` reads 0 on all three Maple vaults at the time of
///      writing, so the two paths agree exactly today.
///
///      **Liquidity, which pricing does not capture.** syrupUSDT redemption is not instantaneous — kpk's own
///      Maple risk assessment records a withdrawal pending well beyond the ~5-minute median. This feed reports a
///      mark, not an exit price; do not read it as redeemable-on-demand value.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract syrupUSDT_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param syrupUsdt_ Address of the syrupUSDT vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDT) whose NAV-selected USD price scales the vault rate.
    constructor(address syrupUsdt_, address nav_, address baseAsset_)
        ERC4626VaultRatePriceFeed(syrupUsdt_, nav_, baseAsset_)
    {}
}
