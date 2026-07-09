// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title sXDAI Custom Price Oracle
/// @notice Returns the USD price of Gnosis sDAI as `(xDAI/USD) × (xDAI per sDAI share)`, the vault's live ERC-4626
///         exchange rate times the NAV's xDAI/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the sDAI vault, the NAV, and the base asset (xDAI).
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract sXDAI_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param sDai_ Address of the Gnosis Staked DAI (sDAI) vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (xDAI) whose NAV-selected USD price scales the vault rate.
    constructor(address sDai_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(sDai_, nav_, baseAsset_) {}
}
