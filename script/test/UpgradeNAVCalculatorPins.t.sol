// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UpgradeNAVCalculator} from "script/upgrade/UpgradeNAVCalculator.s.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";

/// @dev Exposes the script's internal guard so each failure mode can be tripped individually. Calling
///      `run()` instead would need chain config, a deployments entry, a broadcast and a Safe-TX file write.
contract UpgradeNAVCalculatorHarness is UpgradeNAVCalculator {
    function assertPinnedLibrariesUsable(bytes memory implBytecode) external view {
        _assertPinnedLibrariesUsable(implBytecode);
    }
}

/// @title UpgradeNAVCalculatorPinsTest
/// @notice The upgrade script repoints a LIVE proxy at whatever `new NAVCalculator()` produced, so it must refuse
///         to broadcast an implementation that is not usable on the target chain. Two distinct failure modes, both
///         silent in production: bytecode linked against something other than the pins, and pinned addresses that
///         hold no code on this chain (a DELEGATECALL into nothing on the first library call).
/// @dev    Each negative test must fail if the corresponding `require` is removed — that is the point of splitting
///         them. The positive test pins the happy path so the guard cannot be satisfied by rejecting everything.
contract UpgradeNAVCalculatorPinsTest is Test {
    UpgradeNAVCalculatorHarness internal harness;

    /// @dev Any non-empty runtime code; the guard only checks `code.length > 0`.
    bytes internal constant STUB_CODE = hex"600160005260206000f3";

    function setUp() public {
        harness = new UpgradeNAVCalculatorHarness();
    }

    /// @dev In a non-fork test the pinned addresses start empty, which is exactly the fresh-chain case.
    function _deployPinnedLibraries() internal {
        vm.etch(LibraryPins.PRICE_FEED_LIB, STUB_CODE);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, STUB_CODE);
    }

    function test_passes_whenLinkedAndBothLibrariesPresent() public {
        _deployPinnedLibraries();
        harness.assertPinnedLibrariesUsable(type(NAVCalculator).creationCode);
    }

    function test_reverts_whenBytecodeNotLinkedAgainstPriceFeedLib() public {
        _deployPinnedLibraries();
        // Bytecode embedding only the NAVRegistryLib pin: isolates the PriceFeedLib linkage assertion.
        bytes memory unlinked = abi.encodePacked(hex"60806040", LibraryPins.NAV_REGISTRY_LIB);
        vm.expectRevert("NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)");
        harness.assertPinnedLibrariesUsable(unlinked);
    }

    function test_reverts_whenBytecodeNotLinkedAgainstNavRegistryLib() public {
        _deployPinnedLibraries();
        bytes memory unlinked = abi.encodePacked(hex"60806040", LibraryPins.PRICE_FEED_LIB);
        vm.expectRevert("NAVCalculator impl not linked against pinned NAVRegistryLib (foundry.toml `libraries` drift)");
        harness.assertPinnedLibrariesUsable(unlinked);
    }

    /// @notice The fresh-chain case: correctly linked bytecode, but nothing deployed at the pin.
    function test_reverts_whenPriceFeedLibHasNoCodeOnThisChain() public {
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, STUB_CODE); // only the other one is present
        vm.expectRevert("pinned PriceFeedLib has no code on this chain (deploy the libraries here before upgrading)");
        harness.assertPinnedLibrariesUsable(type(NAVCalculator).creationCode);
    }

    function test_reverts_whenNavRegistryLibHasNoCodeOnThisChain() public {
        vm.etch(LibraryPins.PRICE_FEED_LIB, STUB_CODE);
        vm.expectRevert("pinned NAVRegistryLib has no code on this chain (deploy the libraries here before upgrading)");
        harness.assertPinnedLibrariesUsable(type(NAVCalculator).creationCode);
    }

    /// @notice Guards the guard: the real implementation bytecode must embed both pins, so the positive test above
    ///         is not passing for some unrelated reason. This is the same property CI asserts in
    ///         LibraryPinConsistency, restated here against the exact bytecode this script broadcasts.
    function test_realImplBytecodeEmbedsBothPins() public view {
        bytes memory code = type(NAVCalculator).creationCode;
        assertTrue(LibraryPins.contains(code, LibraryPins.PRICE_FEED_LIB), "impl missing PriceFeedLib pin");
        assertTrue(LibraryPins.contains(code, LibraryPins.NAV_REGISTRY_LIB), "impl missing NAVRegistryLib pin");
    }
}
