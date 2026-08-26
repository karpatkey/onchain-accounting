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
///      address with the SAME `symbol()`, 18 decimals, and `totalSupply == 0`. The live vault is the
///      6-decimal one pinned in script/config/contracts-deployment-config/custom-price-feeds/1.json. Never
///      re-derive this address from a symbol lookup — pricing the dead generation fails silently, because an
///      empty ERC-4626 answers `convertToAssets` at the 1:1 default rather than reverting.
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract spETH_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param spEth_ Address of the Spark Savings ETH vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (WETH) whose NAV-selected USD price scales the vault rate.
    constructor(address spEth_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(spEth_, nav_, baseAsset_) {}
}
