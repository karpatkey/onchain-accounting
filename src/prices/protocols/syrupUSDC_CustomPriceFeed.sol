// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626VaultRatePriceFeed} from "src/prices/ERC4626VaultRatePriceFeed.sol";

/// @title syrupUSDC Custom Price Oracle
/// @notice Returns the USD price of syrupUSDC as `(USDC/USD) × (USDC per syrupUSDC share)`, the vault's live
///         ERC-4626 exchange rate times the NAV's USDC/USD price.
/// @dev Thin {ERC4626VaultRatePriceFeed} subclass — the rate/staleness math and `ICustomPriceFeed` surface live in
///      the base; this only pins the syrupUSDC vault, the NAV, and the base asset (USDC).
/// @author KPK
/* solhint-disable contract-name-camelcase */
contract syrupUSDC_CustomPriceFeed is ERC4626VaultRatePriceFeed {
    /// @param syrupUsdc_ Address of the syrupUSDC vault contract.
    /// @param nav_ The NAVCalculator proxy to read the base asset's USD price from.
    /// @param baseAsset_ The base asset (USDC) whose NAV-selected USD price scales the vault rate.
    constructor(address syrupUsdc_, address nav_, address baseAsset_)
        ERC4626VaultRatePriceFeed(syrupUsdc_, nav_, baseAsset_)
    {}
}
