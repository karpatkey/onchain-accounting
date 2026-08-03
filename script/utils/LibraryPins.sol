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
/// @dev **HOW TO REGENERATE THESE, AND WHY THE METHOD MATTERS.** Both values MUST be derived from a
///      CLEAN build — `forge clean` (or a runner that starts with no `out/`) followed by a full
///      `forge build`. A warm tree can produce a DIFFERENT address for the same source: reusing
///      compilation state changes the compilation scope, which changes a library's emitted bytecode
///      and so the CREATE2 address derived from it. This was observed repeatedly in CI before the
///      Build job stopped restoring a Foundry cache (PR #200) — three different `PriceFeedLib`
///      values appeared across branches whose `PriceFeedLib` source was byte-identical, including
///      one branch that changed no file under `src/` at all.
///
///      Two consequences worth stating explicitly, because the next person to regenerate these will
///      not have that context:
///        1. Measure TWICE from two independent clean builds and confirm the values agree before
///           committing. If they disagree, stop — the pin is not computable and that is a far worse
///           problem than a stale one.
///        2. `01_DeployImplementations` asserts the deployed libraries land on these addresses. That
///           assertion is only meaningful against a clean build too; validating it from a warm tree
///           can green-light a pin that no clean build reproduces.
///
///      A pin moves only when a file in THAT library's own compilation closure changes, and even
///      then only if emitted bytecode actually changes — an interface-only addition to a closure
///      member recompiles the library without moving its address. Membership is necessary, not
///      sufficient; measure rather than predict.
library LibraryPins {
    address internal constant PRICE_FEED_LIB = 0x49C18627665562F4bEbae5208BA6eF7428039614;
    address internal constant NAV_REGISTRY_LIB = 0x5f5D054E021A53E1DEF54B3Bda3c939ccD14fd90;

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
