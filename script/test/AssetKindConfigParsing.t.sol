// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {ConfigReader} from "script/utils/ConfigReader.sol";
import {AccrualKind} from "src/utils/AssetKind.sol";

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

    /// @dev Every `AccrualKind` member must be reachable from config. If a member is added without a string mapping it
    ///      becomes unsettable, and the `type(E).max` assertion is what notices — a hardcoded list checked against a
    ///      hardcoded count grows neither when the enum grows, so it would stay green through exactly that change.
    ///
    ///      **There is no `PegKind` half any more, deliberately.** The peg axis is derived on-chain from the NAV's
    ///      `pegToleranceBps`, so it has no config string to be reachable from. The reader and parser were deleted, and
    ///      these tests went with them rather than being kept alive to keep a function alive.
    function test_everyAccrualKindMemberIsReachableFromAString() public pure {
        string[3] memory accrualStrings = ["None", "Rebasing", "Appreciating"];
        uint8 reached;
        for (uint256 i; i < accrualStrings.length; ++i) {
            (, bool valid) = ConfigReader.accrualKindFromString(accrualStrings[i]);
            if (valid) ++reached;
        }
        assertEq(reached, accrualStrings.length, "every listed AccrualKind string must map to a member");
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
    ///      `(None, true)` the deploy would silently classify every unconfigured asset as non-accruing, which is a real
    ///      and plausible value and therefore indistinguishable from a deliberate one.
    function test_emptyStringIsInvalid() public pure {
        (, bool accrualValid) = ConfigReader.accrualKindFromString("");
        assertFalse(accrualValid, "absent accrualKind must be invalid, not defaulted");
    }

    function test_unknownStringsAreInvalid() public pure {
        (, bool v2) = ConfigReader.accrualKindFromString("YieldBearing");
        assertFalse(v2, "a plausible-but-wrong value must not be accepted");
        (, bool v3) = ConfigReader.accrualKindFromString("Appreciate"); // near-miss
        assertFalse(v3, "a near-miss must fail rather than fuzzy-match");
    }

    /// @dev Matching is exact, including case. Leniency here would be the wrong kind of helpfulness: a config author
    ///      who wrote `rebasing` should be told, not guessed at.
    function test_matchingIsCaseSensitive() public pure {
        (, bool v3) = ConfigReader.accrualKindFromString("rebasing");
        assertFalse(v3, "lowercase must not match");
        (, bool v4) = ConfigReader.accrualKindFromString("REBASING");
        assertFalse(v4, "uppercase must not match");
    }

    /// @dev The value returned alongside `valid == false` is not meaningful, and callers must branch on the flag. This
    ///      documents that the sentinel enum happens to be the zero value — which is precisely why the flag, and not
    ///      the value, is the thing to check.
    function test_invalidReturnsZeroValue_whichIsWhyTheFlagIsTheContract() public pure {
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
        (, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, unconfiguredChainId, "USDC");
        assertFalse(accrualValid);
    }

    /// @dev An asset ENTRY that is absent entirely reads invalid. Named for what it actually does: the symbol asked
    ///      for does not exist in chain 1's config, so this is the absent-entry case, NOT the "entry present, kind
    ///      fields absent" case — that one is
    ///      {test_assetPresentButKindFieldAbsentIsInvalid}, which needs a fixture to stay true after the data lands.
    function test_absentAssetEntryIsInvalid() public view {
        (, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, 1, "NOT_A_REAL_SYMBOL");
        assertFalse(accrualValid);
    }

    /// @dev The realistic config mistake: the asset entry EXISTS, with an address, and the `accrualKind` is simply
    ///      forgotten. That must read invalid rather than defaulting — otherwise the deploy would classify the asset as
    ///      `AccrualKind.None`, which is a real, plausible value and so indistinguishable from a deliberate choice.
    ///
    ///      Uses a throwaway fixture rather than a real symbol on purpose: asserting against live config would flip
    ///      from invalid to valid the moment the classification data lands, so the test would be pinning the absence
    ///      of the data rather than the behaviour of the reader.
    ///
    ///      The fixture is removed BEFORE the assertions, so an assertion FAILURE never leaves it behind — the same
    ///      discipline as `BridgeEscrowConfigRehearsal.fork.t.sol`. **That is not total, and the limit is worth
    ///      stating:** a revert between the write and the remove, or an interrupted / OOM-killed run, still leaves
    ///      `assets-and-price-feeds/987654322.json` inside the git tree, where it is untracked, un-ignored, and breaks
    ///      the clean-tree gate. If that ever happens, delete that file — it is test debris, never real config.
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
        // Refuse to touch the path if anything is already there. `foundry.toml` grants read-write over all of
        // `script/`, so a typo in the chain id above would otherwise let this test overwrite a REAL chain's committed
        // asset config and then `vm.removeFile` it — and the assertions below would still pass, because they only
        // check the reader's output. The literal id is the only thing separating the two, so assert on it.
        assertFalse(vm.exists(path), "fixture path must be unoccupied - refusing to overwrite a real chain config");

        // USDC is present and has an address — and no `accrualKind`.
        vm.writeFile(path, '{"USDC":{"address":"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"}}');

        (, bool accrualValid) = ConfigReader.readAssetAccrualKind(vm, fixtureChainId, "USDC");

        vm.removeFile(path);

        assertFalse(accrualValid, "an absent accrualKind must read invalid, not default to None");
    }
}
