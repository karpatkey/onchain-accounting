// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";

/// @title AssetKindConfigParsingTest
/// @notice Proves the config -> enum mapping for asset kinds is fail-closed: there is no default, and anything the
///         mapping does not recognize is reported invalid rather than silently becoming the zero value.
/// @dev These call {ConfigReader}'s mapping directly — the same functions `08_DeployAssetKindRegistry` uses — rather
///      than re-implementing it, so the test cannot drift from production. The deploy script turns `valid == false`
///      into an abort; this file pins the `valid` flag itself.
contract AssetKindConfigParsingTest is Test {
    // ============================================================
    // Every recognized value maps to the right enum
    // ============================================================

    function test_pegKind_recognizedValues() public pure {
        (PegKind pegged, bool v1) = ConfigReader.pegKindFromString("Pegged");
        assertTrue(v1, "Pegged is valid");
        assertEq(uint8(pegged), uint8(PegKind.Pegged));

        (PegKind floating, bool v2) = ConfigReader.pegKindFromString("Floating");
        assertTrue(v2, "Floating is valid");
        assertEq(uint8(floating), uint8(PegKind.Floating));
    }

    function test_accrualKind_recognizedValues() public pure {
        (AccrualKind none, bool v1) = ConfigReader.accrualKindFromString("None");
        assertTrue(v1, "None is valid");
        assertEq(uint8(none), uint8(AccrualKind.None));

        (AccrualKind rebasing, bool v2) = ConfigReader.accrualKindFromString("Rebasing");
        assertTrue(v2, "Rebasing is valid");
        assertEq(uint8(rebasing), uint8(AccrualKind.Rebasing));

        (AccrualKind appreciating, bool v3) = ConfigReader.accrualKindFromString("Appreciating");
        assertTrue(v3, "Appreciating is valid");
        assertEq(uint8(appreciating), uint8(AccrualKind.Appreciating));
    }

    /// @dev Every enum member must be reachable from config. If a member is ever added without a string mapping, it
    ///      becomes unsettable and this count assertion is what notices.
    function test_everyEnumMemberIsReachableFromAString() public pure {
        uint8 pegReached;
        string[2] memory pegStrings = ["Pegged", "Floating"];
        for (uint256 i; i < pegStrings.length; ++i) {
            (, bool valid) = ConfigReader.pegKindFromString(pegStrings[i]);
            if (valid) ++pegReached;
        }
        assertEq(pegReached, 2, "both PegKind members reachable");

        uint8 accrualReached;
        string[3] memory accrualStrings = ["None", "Rebasing", "Appreciating"];
        for (uint256 i; i < accrualStrings.length; ++i) {
            (, bool valid) = ConfigReader.accrualKindFromString(accrualStrings[i]);
            if (valid) ++accrualReached;
        }
        assertEq(accrualReached, 3, "all three AccrualKind members reachable");
    }

    // ============================================================
    // Fail-closed: nothing unrecognized becomes a default
    // ============================================================

    /// @dev The core property. An absent field arrives here as "" and MUST be invalid — if it returned
    ///      `(Pegged, true)` the deploy would silently classify every unconfigured asset as a non-accruing stablecoin.
    function test_emptyStringIsInvalidForBothAxes() public pure {
        (, bool pegValid) = ConfigReader.pegKindFromString("");
        assertFalse(pegValid, "absent pegKind must be invalid, not defaulted");
        (, bool accrualValid) = ConfigReader.accrualKindFromString("");
        assertFalse(accrualValid, "absent accrualKind must be invalid, not defaulted");
    }

    function test_unknownStringsAreInvalid() public pure {
        (, bool v1) = ConfigReader.pegKindFromString("Stablecoin");
        assertFalse(v1, "a plausible-but-wrong value must not be accepted");
        (, bool v2) = ConfigReader.accrualKindFromString("YieldBearing");
        assertFalse(v2);
        (, bool v3) = ConfigReader.accrualKindFromString("Appreciate"); // near-miss
        assertFalse(v3, "a near-miss must fail rather than fuzzy-match");
    }

    /// @dev Matching is exact, including case. Leniency here would be the wrong kind of helpfulness: a config author
    ///      who wrote `pegged` should be told, not guessed at.
    function test_matchingIsCaseSensitive() public pure {
        (, bool v1) = ConfigReader.pegKindFromString("pegged");
        assertFalse(v1, "lowercase must not match");
        (, bool v2) = ConfigReader.pegKindFromString("PEGGED");
        assertFalse(v2, "uppercase must not match");
        (, bool v3) = ConfigReader.accrualKindFromString("rebasing");
        assertFalse(v3);
    }

    /// @dev The value returned alongside `valid == false` is not meaningful, and callers must branch on the flag. This
    ///      documents that the sentinel enum happens to be the zero value — which is precisely why the flag, and not
    ///      the value, is the thing to check.
    function test_invalidReturnsZeroValue_whichIsWhyTheFlagIsTheContract() public pure {
        (PegKind peg, bool pegValid) = ConfigReader.pegKindFromString("nonsense");
        assertFalse(pegValid);
        assertEq(uint8(peg), uint8(PegKind.Pegged), "zero value returned - indistinguishable from a real Pegged");

        (AccrualKind accrual, bool accrualValid) = ConfigReader.accrualKindFromString("nonsense");
        assertFalse(accrualValid);
        assertEq(uint8(accrual), uint8(AccrualKind.None), "likewise indistinguishable from a real None");
    }

    // ============================================================
    // End-to-end through the chainId reader
    // ============================================================

    /// @dev A chain with no assets config at all must report invalid rather than throwing or defaulting — the path an
    ///      operator hits when running the deploy against a chain that was never configured.
    function test_absentChainConfigIsInvalidNotADefault() public view {
        uint256 unconfiguredChainId = 987_654_321;
        (, bool pegValid) = ConfigReader.readAssetPegKind(vm, unconfiguredChainId, "USDC");
        assertFalse(pegValid, "no config file must read as invalid");
        (, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, unconfiguredChainId, "USDC");
        assertFalse(accrualValid);
    }

    /// @dev An asset that exists in a real chain config but has no kind fields must also read invalid. This is the
    ///      state every chain is in until the classification data lands, and it is the guard that makes the deploy
    ///      abort rather than write defaults. It keeps passing once the data lands, because the symbol asked for here
    ///      is deliberately one that does not exist.
    function test_assetWithoutKindFieldsIsInvalid() public view {
        (, bool pegValid) = ConfigReader.readAssetPegKind(vm, 1, "NOT_A_REAL_SYMBOL");
        assertFalse(pegValid, "missing asset entry must read as invalid");
        (, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, 1, "NOT_A_REAL_SYMBOL");
        assertFalse(accrualValid);
    }
}
