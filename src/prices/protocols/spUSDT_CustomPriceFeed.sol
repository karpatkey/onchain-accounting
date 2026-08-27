// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title spUSDT Custom Price Oracle
/// @notice Returns the USD price of spUSDT as `(USDT/USD) × (USDT per spUSDT share)`, the vault's live
///         ERC-4626 exchange rate times the NAV's USDT/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the Spark Savings USDT vault, the NAV, and the base asset (USDT).
///
///      ADDRESS TRAP — Spark deployed this savings family TWICE. An earlier generation lives at a different
///      address with the SAME `symbol()`, 18 decimals, and `totalSupply == 0`. The live vault is the
///      6-decimal one pinned in script/config/contracts-deployment-config/custom-price-feeds/1.json. Never
///      re-derive this address from a symbol lookup.
///
///      Pricing the dead generation here does NOT fail silently, and an earlier revision of this note said it
///      did: its shares are 18-decimal over a 6-decimal asset, so `_shareUnit`/`_assetUnit` gives 1e12 x the
///      base price — roughly $1e12 per share, a gross OVER-report that the fork test's `assertLe(price, 2e8)`
///      band catches. The silent case is {spETH_CustomPriceFeed}, whose two generations are both 18-decimal;
///      its `test_vaultIsTheLiveGeneration` guard is the only thing standing between it and a plausible wrong
///      price, so do not remove that guard on the assumption a price band covers this family.
///
///      TRUST MODEL — two things this feed does NOT bound, recorded because neither is obvious from the code.
///      (1) NOTIONAL PRICING. `TAKER_ROLE` can withdraw assets from the vault WITHOUT burning shares, so the
///      share price is a claim on the borrower, not on assets on hand. Measured 2026-08-27: spUSDC 3.3% of
///      `totalAssets` was actually held, spUSDT 23.8%, spETH 9.9%. This feed applies no coverage floor and no
///      rate-of-change cap, so it prices that claim at full notional. It is the one genuine OVER-report axis in
///      the design, and it is deliberate: the framework prices aTokens, Morpho and Euler positions the same way.
///      (2) UPGRADEABILITY. The three Spark savings vaults are UUPS proxies whose `_authorizeUpgrade` is
///      `onlyRole(DEFAULT_ADMIN_ROLE)`, held by SparkProxy 0x3300f198988e4C9C63f75dF86De36421f06af8c4 — that
///      address can replace the implementation and make `convertToAssets` return anything. {sDAI_CustomPriceFeed}
///      is NOT in this position: `SavingsDai` is non-upgradeable and derives its rate from the Sky Pot. The two
///      are grouped together in config and tests, but their immutability posture differs.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract spUSDT_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param spUsdt_ Address of the Spark Savings USDT vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDT) whose NAV-selected USD price scales the vault rate.
    constructor(address spUsdt_, address nav_, address baseAsset_)
        ERC4626VaultRatePriceFeed(spUsdt_, nav_, baseAsset_)
    {}
}
