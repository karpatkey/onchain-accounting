// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sUSDe Custom Price Oracle
/// @notice Returns the USD price of sUSDe as `(USDe/USD) × (USDe per sUSDe share)`, the vault's live ERC-4626
///         exchange rate times the NAV's USDe/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sUSDe vault, the NAV, and the base asset (USDe).
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sUSDe_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sUsde_ Address of the Staked USDe (sUSDe) vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDe) whose NAV-selected USD price scales the vault rate.
    constructor(address sUsde_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(sUsde_, nav_, baseAsset_) {}
}
