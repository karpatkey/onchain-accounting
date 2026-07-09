// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title RWIV Custom Price Oracle
/// @notice Returns the USD price of RWIV as `(USDC/USD) × (USDC per RWIV share)`, the vault's live ERC-4626
///         exchange rate times the NAV's USDC/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the RWIV vault, the NAV, and the base asset (USDC).
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract RWIV_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param rwiv_ Address of the RWIV vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDC) whose NAV-selected USD price scales the vault rate.
    constructor(address rwiv_, address nav_, address baseAsset_) ERC4626VaultRatePriceFeed(rwiv_, nav_, baseAsset_) {}
}
