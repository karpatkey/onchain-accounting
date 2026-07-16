// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title LibraryPins
/// @notice Single Solidity source of truth for the deterministic CREATE2 addresses that NAVCalculator's two
///         external libraries (PriceFeedLib, NAVRegistryLib) are pinned to in foundry.toml (`libraries`), plus
///         the byte-scan helper used to assert NAVCalculator's creation bytecode is actually linked against them.
/// @dev    foundry.toml's `libraries` array is the one copy of these addresses that cannot import a Solidity
///         constant (it's TOML), so it is cross-checked instead: LibraryPinConsistencyTest
///         .test_navCalculator_creationCodeLinkedAgainstPins() asserts the addresses forge links into
///         NAVCalculator.creationCode (from foundry.toml) match PRICE_FEED_LIB / NAV_REGISTRY_LIB below. Both the
///         deploy guard (01_2_DeployNAVImplementation) and the CI guard import these. A pin regeneration updates
///         just these two canonical copies (this file + foundry.toml); call sites that `vm.etch` library code
///         reference the constants here (`LibraryPins.PRICE_FEED_LIB` / `NAV_REGISTRY_LIB`), so they pick up the
///         new value automatically. If a future call site hard-codes a raw address instead, grep the *constants*
///         (not the literal) to find it.
library LibraryPins {
    address internal constant PRICE_FEED_LIB = 0xfa5D2C267aca39B4b2FE1dd2BB9f8DE0901EF635;
    address internal constant NAV_REGISTRY_LIB = 0x549f6fB0EC34E18A82A320b79C968a9Ca6e7b96b;

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
