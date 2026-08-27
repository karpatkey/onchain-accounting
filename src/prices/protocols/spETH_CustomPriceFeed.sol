// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title spETH Custom Price Oracle
/// @notice Returns the USD price of spETH as `(WETH/USD) × (WETH per spETH share)`, the vault's live
///         ERC-4626 exchange rate times the NAV's WETH/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the Spark Savings ETH vault, the NAV, and the base asset (WETH).
///
///      ADDRESS TRAP — Spark deployed this savings family TWICE. An earlier generation lives at a different
///      address with the SAME `symbol()`, the SAME 18 decimals, and `totalSupply == 0`. **Decimals do not
///      disambiguate spETH** — both generations are 18-decimal, so only the address pinned in
///      script/config/contracts-deployment-config/custom-price-feeds/1.json identifies the live vault. (An
///      earlier revision of this note was copied from the spUSDC sibling and told the reader to look for a
///      "6-decimal one", which does not exist for spETH and points at the dead address.)
///
///      This is the member where the trap is genuinely SILENT. spUSDC/spUSDT's dead twins are 18-decimal
///      shares over a 6-decimal asset, so they over-report by 1e12 and any sane price band catches them. Here
///      the dead vault answers `convertToAssets` at the 1:1 default with matching decimals, yielding exactly
///      the base WETH/USD price — plausible, wrong, and invisible to a price band. `test_vaultIsTheLiveGeneration`
///      (`totalSupply > 0`) is the only guard against it. Do not remove it.
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
contract spETH_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param spEth_ Address of the Spark Savings ETH vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (WETH) whose NAV-selected USD price scales the vault rate.
    constructor(address spEth_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(spEth_, nav_, baseAsset_) {}
}
