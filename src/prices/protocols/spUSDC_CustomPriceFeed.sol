// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title spUSDC Custom Price Oracle
/// @notice Returns the USD price of spUSDC as `(USDC/USD) × (USDC per spUSDC share)`, the vault's live
///         ERC-4626 exchange rate times the NAV's USDC/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the Spark Savings USDC vault, the NAV, and the base asset (USDC).
///
///      ADDRESS TRAP — Spark deployed this savings family TWICE. An earlier generation lives at a different
///      address with the SAME `symbol()`, 18 decimals, and `totalSupply == 0`. The live vault is the
///      6-decimal one pinned in script/config/contracts-deployment-config/custom-price-feeds/1.json. Never
///      re-derive this address from a symbol lookup — pricing the dead generation fails silently, because an
///      empty ERC-4626 answers `convertToAssets` at the 1:1 default rather than reverting.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract spUSDC_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param spUsdc_ Address of the Spark Savings USDC vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDC) whose NAV-selected USD price scales the vault rate.
    constructor(address spUsdc_, address nav_, address baseAsset_)
        ERC4626VaultRatePriceFeed(spUsdc_, nav_, baseAsset_)
    {}
}
