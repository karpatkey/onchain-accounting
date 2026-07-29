// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sGHO Custom Price Oracle
/// @notice Returns the USD price of sGHO as `(GHO/USD) × (GHO per sGHO share)`, the vault's live ERC-4626
///         exchange rate times the NAV's GHO/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sGHO vault, the NAV, and the base asset (GHO).
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sGHO_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sGho_ Address of the Savings GHO (sGHO) vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (GHO) whose NAV-selected USD price scales the vault rate.
    constructor(address sGho_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(sGho_, nav_, baseAsset_) {}
}
