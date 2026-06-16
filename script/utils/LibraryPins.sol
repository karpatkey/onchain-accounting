// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title LibraryPins
/// @notice Single Solidity source of truth for the deterministic CREATE2 addresses that NAVCalculator's two
///         external libraries (PriceFeedLib, NavRegistryLib) are pinned to in foundry.toml (`libraries`), plus
///         the byte-scan helper used to assert NAVCalculator's creation bytecode is actually linked against them.
/// @dev    foundry.toml's `libraries` array is the one copy of these addresses that cannot import a Solidity
///         constant (it's TOML), so it is cross-checked instead: LibraryPinConsistencyTest
///         .test_navCalculator_creationCodeLinkedAgainstPins() asserts the addresses forge links into
///         NAVCalculator.creationCode (from foundry.toml) match PRICE_FEED_LIB / NAV_REGISTRY_LIB below. Both the
///         deploy guard (01_2_DeployNAVImplementation) and the CI guard import these, so a pin regeneration
///         updates exactly two places: this file and foundry.toml.
library LibraryPins {
    address internal constant PRICE_FEED_LIB = 0x6F0C6f68728Ec474FecB4DE7cdd72E28C2D42715;
    address internal constant NAV_REGISTRY_LIB = 0xB47b227eA8B8bcFD3c2e5D54d2ff7Ffa3c1B138D;

    /// @dev True if the 20-byte `needle` address appears verbatim anywhere in `haystack` — the linker embeds a
    ///      pinned library's address directly in the linked creation bytecode.
    function contains(bytes memory haystack, address needle) internal pure returns (bool) {
        if (haystack.length < 20) return false;
        bytes20 n = bytes20(needle);
        for (uint256 i = 0; i + 20 <= haystack.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < 20; j++) {
                if (haystack[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
