// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title RegisteredAssetLib
/// @author KPK
/// @notice Shared helper for resolving a single registered asset's metadata out of a NAVCalculator
///         `getRegisteredAssets()` snapshot. Several balance adapters that denominate their positions in one fixed
///         underlying (the withdrawal-queue / exit-queue adapters) need exactly this find-by-address scan; centralising
///         it here removes the hand-rolled copies that previously lived in each adapter.
/// @dev `internal` functions only, so this library is inlined into each caller's bytecode — it is NOT a linked/pinned
///      external library (no CREATE2 address, no `foundry.toml [libraries]` entry, no effect on the PriceFeedLib /
///      NAVRegistryLib pins).
library RegisteredAssetLib {
    /// @notice Finds `asset` in a pre-fetched `getRegisteredAssets()` snapshot.
    /// @param reg The registry snapshot (caller fetches it once via `NAV_CALCULATOR.getRegisteredAssets()`).
    /// @param asset The asset address to resolve.
    /// @return assetInfo The matching `Asset` (zeroed if not found).
    /// @return found True if `asset` is registered.
    function find(INAVCalculator.Asset[] memory reg, address asset)
        internal
        pure
        returns (INAVCalculator.Asset memory assetInfo, bool found)
    {
        for (uint256 i = 0; i < reg.length; i++) {
            if (reg[i].asset == asset) {
                return (reg[i], true);
            }
        }
        return (INAVCalculator.Asset({asset: address(0), symbol: "", decimals: 0}), false);
    }
}
