// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sUSDS Custom Price Oracle
/// @notice Returns the USD price of sUSDS as `(USDS/USD) × (USDS per sUSDS share)`, the vault's live ERC-4626
///         exchange rate times the NAV's USDS/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sUSDS vault, the NAV, and the base asset (USDS).
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sUSDS_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sUsds_ Address of the Staked USDS (sUSDS) vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDS) whose NAV-selected USD price scales the vault rate.
    constructor(address sUsds_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(sUsds_, nav_, baseAsset_) {}
}
