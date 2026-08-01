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

    /// @dev Every enum member must be reachable from config. If a member is ever added without a string mapping it
    ///      becomes unsettable, and this test is what notices.
    ///
    ///      **Two assertions per axis, and the pairing is the point.** The `valid` loop proves every string in the
    ///      list maps to a member. The `type(E).max` assertion proves the list is not SHORT — i.e. that no member
    ///      exists without a string. Only the second one catches "a member was added and nobody added its string",
    ///      which is the regression the docstring promises: a hardcoded list checked against a hardcoded count grows
    ///      neither when the enum grows, so it stays green through exactly the change it claims to catch.
    function test_everyEnumMemberIsReachableFromAString() public pure {
        string[2] memory pegStrings = ["Pegged", "Floating"];
        uint8 pegReached;
        for (uint256 i; i < pegStrings.length; ++i) {
            (, bool valid) = ConfigReader.pegKindFromString(pegStrings[i]);
            if (valid) ++pegReached;
        }
        assertEq(pegReached, pegStrings.length, "every listed PegKind string must map to a member");
        assertEq(
            pegStrings.length,
            uint256(uint8(type(PegKind).max)) + 1,
            "a PegKind member has no config string - add it here and to ConfigReader.pegKindFromString"
        );

        string[3] memory accrualStrings = ["None", "Rebasing", "Appreciating"];
        uint8 accrualReached;
        for (uint256 i; i < accrualStrings.length; ++i) {
            (, bool valid) = ConfigReader.accrualKindFromString(accrualStrings[i]);
            if (valid) ++accrualReached;
        }
        assertEq(accrualReached, accrualStrings.length, "every listed AccrualKind string must map to a member");
        assertEq(
            accrualStrings.length,
            uint256(uint8(type(AccrualKind).max)) + 1,
            "an AccrualKind member has no config string - add it here and to ConfigReader.accrualKindFromString"
        );
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

    /// @dev An asset ENTRY that is absent entirely reads invalid. Named for what it actually does: the symbol asked
    ///      for does not exist in chain 1's config, so this is the absent-entry case, NOT the "entry present, kind
    ///      fields absent" case — that one is
    ///      {test_assetPresentButKindFieldAbsentIsInvalid}, which needs a fixture to stay true after the data lands.
    function test_absentAssetEntryIsInvalid() public view {
        (, bool pegValid) = ConfigReader.readAssetPegKind(vm, 1, "NOT_A_REAL_SYMBOL");
        assertFalse(pegValid, "missing asset entry must read as invalid");
        (, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, 1, "NOT_A_REAL_SYMBOL");
        assertFalse(accrualValid);
    }

    /// @dev The realistic config mistake, which nothing covered before: the asset entry EXISTS and one axis is filled
    ///      in while its sibling is forgotten. Half-classified must read invalid on the missing axis — otherwise the
    ///      deploy would classify the asset using a defaulted `AccrualKind.None`, which is a real, plausible value.
    ///
    ///      Uses a throwaway fixture rather than a real symbol on purpose: asserting against live config would flip
    ///      from invalid to valid the moment the classification data lands, so the test would be pinning the absence
    ///      of the data rather than the behaviour of the reader. Fixture is removed BEFORE the assertions so a failure
    ///      never leaves it behind — same discipline as `BridgeEscrowConfigRehearsal.fork.t.sol`.
    function test_assetPresentButKindFieldAbsentIsInvalid() public {
        uint256 fixtureChainId = 987_654_322;
        string memory path = string(
            abi.encodePacked(
                vm.projectRoot(),
                "/script/config/nav-config/assets-and-price-feeds/",
                vm.toString(fixtureChainId),
                ".json"
            )
        );
        // USDC is present, has an address, has `pegKind` — and no `accrualKind`.
        vm.writeFile(path, '{"USDC":{"address":"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48","pegKind":"Pegged"}}');

        (PegKind peg, bool pegValid) = ConfigReader.readAssetPegKind(vm, fixtureChainId, "USDC");
        (, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, fixtureChainId, "USDC");

        vm.removeFile(path);

        assertTrue(pegValid, "the axis that IS configured must read valid");
        assertEq(uint8(peg), uint8(PegKind.Pegged));
        assertFalse(accrualValid, "the absent sibling axis must read invalid, not default to None");
    }
}
