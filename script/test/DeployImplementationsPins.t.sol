// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployImplementations} from "script/deploy/01_DeployImplementations.s.sol";
import {DeployNAVImplementation} from "script/deploy/01_2_DeployNAVImplementation.s.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {NAVRegistryLib} from "src/nav/NAVRegistryLib.sol";

address constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
address constant WRONG_PRICE_FEED_PIN = address(0xDeaD00000000000000000000000000000000BEEf);
address constant WRONG_REGISTRY_PIN = address(0xbEef00000000000000000000000000000000Dead);

/// @dev Shared harness behaviour for both scripts: injectable pins, an externally reachable guard, and a
///      neutralised script surface. `setUp()` reverts because `forge script` calls it before ANY entry point,
///      including a `--sig` target — that is what closes the harness-rooted script paths, since
///      `guardedDeploy()` is externally reachable and would otherwise be broadcast-capable from a test file.
abstract contract PinHarnessBehaviour {
    address internal _priceFeedPinOverride;
    address internal _navRegistryPinOverride;

    function setPinOverrides(address priceFeedPin, address navRegistryPin) external {
        _priceFeedPinOverride = priceFeedPin;
        _navRegistryPinOverride = navRegistryPin;
    }
}

contract DeployImplementationsHarness is DeployImplementations, PinHarnessBehaviour {
    function _priceFeedLibPin() internal view override returns (address) {
        return _priceFeedPinOverride == address(0) ? super._priceFeedLibPin() : _priceFeedPinOverride;
    }

    function _navRegistryLibPin() internal view override returns (address) {
        return _navRegistryPinOverride == address(0) ? super._navRegistryLibPin() : _navRegistryPinOverride;
    }

    function assertPinnedLibrariesUsable() external view {
        _assertPinnedLibrariesUsable(_computeImplPlan());
    }

    function guardedDeploy() external {
        _guardedDeploy(_computeImplPlan());
    }

    function setUp() public pure override {
        revert("harness: not a deploy script");
    }

    function run() public pure override {
        revert("harness: not a deploy script");
    }
}

contract DeployNAVImplementationHarness is DeployNAVImplementation, PinHarnessBehaviour {
    function _priceFeedLibPin() internal view override returns (address) {
        return _priceFeedPinOverride == address(0) ? super._priceFeedLibPin() : _priceFeedPinOverride;
    }

    function _navRegistryLibPin() internal view override returns (address) {
        return _navRegistryPinOverride == address(0) ? super._navRegistryLibPin() : _navRegistryPinOverride;
    }

    function assertPinnedLibrariesUsable() external view {
        _assertPinnedLibrariesUsable(_computeImplPlan());
    }

    function guardedDeploy() external {
        _guardedDeploy(_computeImplPlan());
    }

    function setUp() public pure override {
        revert("harness: not a deploy script");
    }

    function run() public pure override {
        revert("harness: not a deploy script");
    }
}

/// @dev Deploys with the guard neutralised, so "the guard rejects correctly" stays distinguishable from "the
///      deploy path always reverts". A full four-assertion success cannot be staged on a tree whose pins drift —
///      the impl bytecode embeds the real pins, so no injection satisfies linkage and source-match at once.
contract UnguardedDeployImplementationsHarness is DeployImplementationsHarness {
    function _assertPinnedLibrariesUsable(ImplPlan memory) internal view override {}
}

contract UnguardedDeployNAVImplementationHarness is DeployNAVImplementationHarness {
    function _assertPinnedLibrariesUsable(ImplPlan memory) internal view override {}
}

/// @title DeployImplementationsPinsTest
/// @notice The library-pin guards in `01_DeployImplementations` and `01_2_DeployNAVImplementation`.
/// @dev    These assertions existed and were correct; **nothing reached them.** A mutation sweep put
///         `revert("TRIP_01")` as the FIRST statement of each script's `run()` — a strictly stronger probe than
///         deleting the guard, since it fails before anything else can happen — and the entire non-fork suite
///         stayed green while the marker string appeared zero times in 1562 tests' output. No test imported,
///         constructed or invoked either script.
///
///         `test/LibraryPinConsistency.t.sol` asserts the same three underlying properties directly, so the
///         PROPERTIES were covered. What was not covered, and is covered here, is each script's refusal to
///         broadcast — the behaviour that stands between a stale pin and 24 chains of silently wrong-version
///         implementations.
///
///         Two rules this suite is built around, both inherited from PR #194's review rounds:
///           1. Every assertion must be individually trippable, and NOT only in the pin state the tree happens to
///              be in. The source-vs-pin pair is exercised through injected pins so it stays covered after the
///              pin regeneration in PR #185 lands.
///           2. The guard's WIRING needs its own mutation: blanking the guard body and deleting its call are
///              different mutations, and only the second reaches the production path.
contract DeployImplementationsPinsTest is Test {
    DeployImplementationsHarness internal impls;
    DeployNAVImplementationHarness internal navImpl;

    function setUp() public {
        impls = new DeployImplementationsHarness();
        navImpl = new DeployNAVImplementationHarness();
    }

    /// @dev Derived independently of the guard (different helper, different argument order) so it cannot agree
    ///      with a broken guard by construction.
    function _computedPriceFeedPin() internal pure returns (address) {
        return vm.computeCreate2Address(
            keccak256(abi.encodePacked("PriceFeedLib", uint256(1))),
            keccak256(type(PriceFeedLib).creationCode),
            CANONICAL_CREATE2_DEPLOYER
        );
    }

    function _computedNavRegistryPin() internal pure returns (address) {
        return vm.computeCreate2Address(
            keccak256(abi.encodePacked("NavRegistryLib", uint256(1))),
            keccak256(type(NAVRegistryLib).creationCode),
            CANONICAL_CREATE2_DEPLOYER
        );
    }

    function _pinsMatchSource() internal pure returns (bool) {
        return _computedPriceFeedPin() == LibraryPins.PRICE_FEED_LIB
            && _computedNavRegistryPin() == LibraryPins.NAV_REGISTRY_LIB;
    }

    // ---------------------------------------------------------------
    // Family 1 — the pins must still match the library source in this tree.
    // Injected pins, so each assertion is trippable in ANY pin state.
    // ---------------------------------------------------------------

    function test_01_sourceMatch_revertsOnWrongPriceFeedPin() public {
        impls.setPinOverrides(WRONG_PRICE_FEED_PIN, _computedNavRegistryPin());
        vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        impls.assertPinnedLibrariesUsable();
    }

    /// @notice The second assertion in isolation. Without the injected first pin the PriceFeedLib check fires
    ///         first and masks this one — the exact gap reviewers found in PR #194.
    function test_01_sourceMatch_revertsOnWrongNavRegistryPin() public {
        impls.setPinOverrides(_computedPriceFeedPin(), WRONG_REGISTRY_PIN);
        vm.expectRevert("NAVRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        impls.assertPinnedLibrariesUsable();
    }

    function test_01_2_sourceMatch_revertsOnWrongPriceFeedPin() public {
        navImpl.setPinOverrides(WRONG_PRICE_FEED_PIN, _computedNavRegistryPin());
        vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        navImpl.assertPinnedLibrariesUsable();
    }

    function test_01_2_sourceMatch_revertsOnWrongNavRegistryPin() public {
        navImpl.setPinOverrides(_computedPriceFeedPin(), WRONG_REGISTRY_PIN);
        vm.expectRevert("NAVRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        navImpl.assertPinnedLibrariesUsable();
    }

    // ---------------------------------------------------------------
    // Family 2 — the impl bytecode must be linked against both pins.
    // Reachable only once the source-match pair is satisfied, which is why each test injects the COMPUTED pin for
    // the library it is not testing and a plausible-but-wrong one for the library it is.
    // ---------------------------------------------------------------

    /// @dev Injecting the computed PriceFeedLib pin satisfies source-match for it; the impl bytecode embeds
    ///      whatever foundry.toml says, so when the computed pin differs from the foundry.toml pin the linkage
    ///      check is what objects. Skipped when the tree's pins already match source, since then the computed and
    ///      configured pins are the same address and there is no divergence to detect.
    function test_01_linkage_revertsWhenImplNotLinkedAgainstThePin() public {
        vm.skip(_pinsMatchSource());
        impls.setPinOverrides(_computedPriceFeedPin(), _computedNavRegistryPin());
        vm.expectRevert("NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)");
        impls.assertPinnedLibrariesUsable();
    }

    function test_01_2_linkage_revertsWhenImplNotLinkedAgainstThePin() public {
        vm.skip(_pinsMatchSource());
        navImpl.setPinOverrides(_computedPriceFeedPin(), _computedNavRegistryPin());
        vm.expectRevert("NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)");
        navImpl.assertPinnedLibrariesUsable();
    }

    // ---------------------------------------------------------------
    // The wiring: the deploy path must go through the guard.
    // This is the family whose absence the sweep found. Deleting the
    // `_assertPinnedLibrariesUsable` call from `_guardedDeploy` makes these deploys SUCCEED and these tests fail.
    // ---------------------------------------------------------------

    function test_01_guardedDeploy_revertsWhenTheGuardRejects() public {
        impls.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        vm.expectRevert();
        impls.guardedDeploy();
    }

    function test_01_2_guardedDeploy_revertsWhenTheGuardRejects() public {
        navImpl.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        vm.expectRevert();
        navImpl.guardedDeploy();
    }

    /// @notice The other direction, so the wiring is not satisfied by a deploy path that refuses everything.
    /// @dev    A reviewer mutation on PR #194 showed nothing else catches this: `require(false)` inside the
    ///         deploy wrapper left every test green, because every test that reached the deploy expected a revert.
    function test_01_guardedDeploy_succeedsWhenTheGuardIsSatisfied() public {
        UnguardedDeployImplementationsHarness unguarded = new UnguardedDeployImplementationsHarness();
        unguarded.guardedDeploy();
    }

    function test_01_2_guardedDeploy_succeedsWhenTheGuardIsSatisfied() public {
        UnguardedDeployNAVImplementationHarness unguarded = new UnguardedDeployNAVImplementationHarness();
        unguarded.guardedDeploy();
    }

    // ---------------------------------------------------------------
    // The harness is inert as a script.
    // ---------------------------------------------------------------

    /// @dev `forge script` calls `setUp()` before any entry point including a `--sig` target, so a reverting
    ///      `setUp()` closes `--sig guardedDeploy()` too. Scope, stated precisely: this covers the HARNESS-rooted
    ///      paths. `DeployImplementationsPinsTest` is itself a `forge script` entry point and its own `setUp()`
    ///      cannot revert (`forge test` needs it) — a generic property of any test contract that constructs a
    ///      broadcasting helper.
    function test_harnessIsNotRunnableAsAScript() public {
        vm.expectRevert("harness: not a deploy script");
        impls.setUp();

        vm.expectRevert("harness: not a deploy script");
        impls.run();

        vm.expectRevert("harness: not a deploy script");
        navImpl.setUp();

        vm.expectRevert("harness: not a deploy script");
        navImpl.run();
    }
}
