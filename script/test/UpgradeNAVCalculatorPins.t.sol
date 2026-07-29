// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UpgradeNAVCalculator} from "script/upgrade/UpgradeNAVCalculator.s.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {NAVRegistryLib} from "src/nav/NAVRegistryLib.sol";

/// @dev Exposes the script's internals so each failure mode can be tripped individually, and so the guarded
///      deploy path itself can be driven. Calling `run()` instead would need chain config, a deployments entry
///      and a Safe-TX file write; `_deployGuardedNavImplementation` is the part that must not be bypassable.
contract UpgradeNAVCalculatorHarness is UpgradeNAVCalculator {
    function assertLibrarySourceMatchesPins() external view {
        _assertLibrarySourceMatchesPins();
    }

    function assertImplLinkedAndLibrariesPresent(bytes memory implBytecode) external view {
        _assertImplLinkedAndLibrariesPresent(implBytecode);
    }

    function deployGuardedNavImplementation() external returns (NAVCalculator) {
        return _deployGuardedNavImplementation();
    }
}

/// @title UpgradeNAVCalculatorPinsTest
/// @notice The upgrade script repoints a LIVE proxy at whatever `new NAVCalculator()` produced, so it must refuse
///         to broadcast an implementation that is not usable on the target chain. Three failure families, all
///         silent in production: a pin that no longer matches the library source in this tree, bytecode linked
///         against something other than the pins, and pinned addresses holding no code on this chain.
/// @dev    Every negative test must fail if its `require` is removed, and the wiring test must fail if the guard
///         CALL is removed from `_deployGuardedNavImplementation` — blanking the guard body is the weaker mutation
///         and does not reach the call site.
contract UpgradeNAVCalculatorPinsTest is Test {
    UpgradeNAVCalculatorHarness internal harness;

    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @dev Any non-empty runtime code; the guard only checks `code.length > 0`.
    bytes internal constant STUB_CODE = hex"600160005260206000f3";

    function setUp() public {
        harness = new UpgradeNAVCalculatorHarness();
    }

    /// @dev In a non-fork run the pinned addresses start empty, which IS the fresh-chain case. Etch explicitly
    ///      rather than relying on that, so these tests cannot silently invert if ever run against a fork.
    function _deployPinnedLibraries() internal {
        vm.etch(LibraryPins.PRICE_FEED_LIB, STUB_CODE);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, STUB_CODE);
    }

    function _clearPinnedLibraries() internal {
        vm.etch(LibraryPins.PRICE_FEED_LIB, "");
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, "");
    }

    /// @dev True when this tree's library source still maps to the pins. False during a pin regeneration (PR #185),
    ///      when `LibraryPinConsistency` is red by design — the tests below must be meaningful in BOTH states, so
    ///      they assert that the guard tracks this condition rather than asserting a particular value of it.
    function _pinsMatchCurrentSource() internal pure returns (bool) {
        // Same salt routine as ConfigReader.computeSalt and the same deployer the pins are derived from.
        bool priceFeed = vm.computeCreate2Address(
            keccak256(abi.encodePacked("PriceFeedLib", uint256(1))),
            keccak256(type(PriceFeedLib).creationCode),
            CANONICAL_CREATE2_DEPLOYER
        ) == LibraryPins.PRICE_FEED_LIB;
        bool registry = vm.computeCreate2Address(
            keccak256(abi.encodePacked("NavRegistryLib", uint256(1))),
            keccak256(type(NAVRegistryLib).creationCode),
            CANONICAL_CREATE2_DEPLOYER
        ) == LibraryPins.NAV_REGISTRY_LIB;
        return priceFeed && registry;
    }

    // ---------------------------------------------------------------
    // Family 1: the pins must still match the library source in this tree
    // ---------------------------------------------------------------

    /// @notice The stale-pin case the first revision of this guard missed entirely: linkage and code-presence both
    ///         pass on a stale pin (the impl embeds the old pin, and the old library is deployed there), so this is
    ///         the only check that catches a library source change with no pin regeneration.
    function test_librarySourceCheck_tracksPinDrift() public {
        if (_pinsMatchCurrentSource()) {
            harness.assertLibrarySourceMatchesPins(); // must not revert
        } else {
            vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
            harness.assertLibrarySourceMatchesPins();
        }
    }

    /// @notice Locks the asymmetry that motivated the fix: on a drifting tree the two weaker families still pass,
    ///         so they cannot substitute for the source check.
    function test_weakerFamiliesArePassedByAStalePin() public {
        _deployPinnedLibraries();
        harness.assertImplLinkedAndLibrariesPresent(type(NAVCalculator).creationCode);
        // No assertion on _pinsMatchCurrentSource() here: the point is that this call succeeds either way.
    }

    // ---------------------------------------------------------------
    // Family 2: the impl must be linked against both pins
    // ---------------------------------------------------------------

    function test_reverts_whenBytecodeNotLinkedAgainstPriceFeedLib() public {
        _deployPinnedLibraries();
        // Bytecode embedding only the NAVRegistryLib pin: isolates the PriceFeedLib linkage assertion.
        bytes memory unlinked = abi.encodePacked(hex"60806040", LibraryPins.NAV_REGISTRY_LIB);
        vm.expectRevert("NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)");
        harness.assertImplLinkedAndLibrariesPresent(unlinked);
    }

    function test_reverts_whenBytecodeNotLinkedAgainstNavRegistryLib() public {
        _deployPinnedLibraries();
        bytes memory unlinked = abi.encodePacked(hex"60806040", LibraryPins.PRICE_FEED_LIB);
        vm.expectRevert("NAVCalculator impl not linked against pinned NAVRegistryLib (foundry.toml `libraries` drift)");
        harness.assertImplLinkedAndLibrariesPresent(unlinked);
    }

    // ---------------------------------------------------------------
    // Family 3: the pinned addresses must hold code on this chain
    // ---------------------------------------------------------------

    function test_reverts_whenPriceFeedLibHasNoCodeOnThisChain() public {
        _clearPinnedLibraries();
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, STUB_CODE); // only the other one is present
        vm.expectRevert("pinned PriceFeedLib has no code on this chain (deploy the libraries here before upgrading)");
        harness.assertImplLinkedAndLibrariesPresent(type(NAVCalculator).creationCode);
    }

    function test_reverts_whenNavRegistryLibHasNoCodeOnThisChain() public {
        _clearPinnedLibraries();
        vm.etch(LibraryPins.PRICE_FEED_LIB, STUB_CODE);
        vm.expectRevert("pinned NAVRegistryLib has no code on this chain (deploy the libraries here before upgrading)");
        harness.assertImplLinkedAndLibrariesPresent(type(NAVCalculator).creationCode);
    }

    function test_passes_whenLinkedAndBothLibrariesPresent() public {
        _deployPinnedLibraries();
        harness.assertImplLinkedAndLibrariesPresent(type(NAVCalculator).creationCode);
    }

    // ---------------------------------------------------------------
    // The wiring: the deploy path must go through the guard
    // ---------------------------------------------------------------

    /// @notice The mutation that matters. `new NAVCalculator()` succeeds happily with the libraries absent — a
    ///         DELEGATECALL into nothing only reverts on first use — so if the guard call is deleted from
    ///         `_deployGuardedNavImplementation`, or moved below the broadcast, this deploy SUCCEEDS and the test
    ///         fails. That is the regression the whole PR exists to prevent.
    function test_guardedDeploy_reverts_whenPinnedLibrariesAbsent() public {
        _clearPinnedLibraries();
        vm.expectRevert();
        harness.deployGuardedNavImplementation();
    }

    /// @notice The other direction, so the guard is not satisfied by refusing everything. During a pin
    ///         regeneration the source check is the first objection, so the deploy must refuse then too.
    function test_guardedDeploy_succeedsOnlyWhenEverythingHolds() public {
        _deployPinnedLibraries();
        if (_pinsMatchCurrentSource()) {
            NAVCalculator impl = harness.deployGuardedNavImplementation();
            assertGt(address(impl).code.length, 0, "implementation not deployed");
        } else {
            vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
            harness.deployGuardedNavImplementation();
        }
    }

    /// @notice Guards the guard: the real implementation bytecode must embed both pins, so the positive tests
    ///         above cannot pass for an unrelated reason.
    function test_realImplBytecodeEmbedsBothPins() public pure {
        bytes memory code = type(NAVCalculator).creationCode;
        assertTrue(LibraryPins.contains(code, LibraryPins.PRICE_FEED_LIB), "impl missing PriceFeedLib pin");
        assertTrue(LibraryPins.contains(code, LibraryPins.NAV_REGISTRY_LIB), "impl missing NAVRegistryLib pin");
    }
}
