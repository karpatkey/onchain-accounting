// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UpgradeNAVCalculator} from "script/upgrade/UpgradeNAVCalculator.s.sol";
import {LibraryPins} from "script/utils/LibraryPins.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {PriceFeedLib} from "src/prices/PriceFeedLib.sol";
import {NAVRegistryLib} from "src/nav/NAVRegistryLib.sol";

/// @dev Exposes the script's internals so each assertion can be tripped individually, and lets a test inject a
///      deliberately wrong pin. Without that injection the two source-vs-pin assertions are only exercisable
///      through ambient tree state — covered today only because the pins are drifting, and uncovered the moment
///      PR #185 regenerates them.
contract UpgradeNAVCalculatorHarness is UpgradeNAVCalculator {
    address internal _priceFeedPinOverride;
    address internal _navRegistryPinOverride;

    function setPinOverrides(address priceFeedPin, address navRegistryPin) external {
        _priceFeedPinOverride = priceFeedPin;
        _navRegistryPinOverride = navRegistryPin;
    }

    function _priceFeedLibPin() internal view override returns (address) {
        return _priceFeedPinOverride == address(0) ? super._priceFeedLibPin() : _priceFeedPinOverride;
    }

    function _navRegistryLibPin() internal view override returns (address) {
        return _navRegistryPinOverride == address(0) ? super._navRegistryLibPin() : _navRegistryPinOverride;
    }

    function assertLibrarySourceMatchesPins() external view {
        _assertLibrarySourceMatchesPins();
    }

    function assertImplLinkedAndLibrariesPresent(bytes memory implBytecode) external view {
        _assertImplLinkedAndLibrariesPresent(implBytecode);
    }

    function assertPinnedLibrariesUsable(bytes memory implBytecode) external view {
        _assertPinnedLibrariesUsable(implBytecode);
    }

    function deployGuardedNavImplementation() external returns (NAVCalculator) {
        return _deployGuardedNavImplementation();
    }

    /// @dev `forge script` calls `setUp()` before ANY entry point, including a `--sig` target, and this test
    ///      never calls it (it constructs the harness directly). Reverting here therefore closes every script
    ///      path at once — which the `run()` override alone did not: `deployGuardedNavImplementation()` is
    ///      externally reachable, and once the pins match it would deploy a real implementation from a test
    ///      file. That deploy saves no address, writes no Safe TX and repoints no proxy, so it was never a
    ///      live-proxy upgrade — but nothing under `script/test/` should be broadcast-capable at all.
    function setUp() public pure override {
        revert("harness: not a deploy script");
    }

    /// @dev Belt-and-braces now that `setUp()` is the primary barrier.
    function run() public pure override {
        revert("harness: not a deploy script");
    }
}

/// @dev Deploys with the guard neutralised. The wiring tests prove the deploy REFUSES when the guard objects;
///      this proves it can still SUCCEED, so "the guard rejects correctly" is distinguishable from "the deploy
///      path always reverts". Reviewers demonstrated the gap: `require(false)` inside
///      `_deployGuardedNavImplementation` left all 15 tests green, because every test that reaches the deploy
///      expects a revert. A full six-assertion success cannot be staged on a tree whose pins drift — the impl
///      bytecode embeds the real pins, so no pin injection satisfies linkage and source-match at once — which is
///      why the deploy mechanics are proved separately here.
contract UnguardedDeployHarness is UpgradeNAVCalculatorHarness {
    function _assertPinnedLibrariesUsable(bytes memory) internal view override {}
}

/// @title UpgradeNAVCalculatorPinsTest
/// @notice The upgrade script repoints a LIVE proxy at whatever `new NAVCalculator()` produced, so it must refuse
///         to broadcast an implementation that is not usable on the target chain. Three failure families: a pin
///         that no longer matches the library source in this tree, bytecode linked against something other than
///         the pins, and pinned addresses holding no code on this chain.
/// @dev    Two rules this suite is built around, both learned from review rounds on this PR:
///         1. Every assertion must be individually trippable — and NOT only in the pin state the tree happens to
///            be in. The source-vs-pin pair is tested through injected pins so it stays covered after PR #185.
///         2. The guard's WIRING needs its own mutation: blanking the guard body and deleting its call are
///            different mutations, and only the second one reaches the production path.
contract UpgradeNAVCalculatorPinsTest is Test {
    UpgradeNAVCalculatorHarness internal harness;

    address internal constant CANONICAL_CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @dev Any non-empty runtime code; the guard only checks `code.length > 0`.
    bytes internal constant STUB_CODE = hex"600160005260206000f3";

    /// @dev Stand-ins for "a pin that does not match the library source". Arbitrary, and deliberately not the
    ///      real pins so these tests mean the same thing before and after a pin regeneration.
    address internal constant WRONG_PRICE_FEED_PIN = address(0xDeaD00000000000000000000000000000000BEEf);
    address internal constant WRONG_REGISTRY_PIN = address(0xbEef00000000000000000000000000000000Dead);

    function setUp() public {
        harness = new UpgradeNAVCalculatorHarness();
    }

    function _deployPinnedLibraries() internal {
        vm.etch(LibraryPins.PRICE_FEED_LIB, STUB_CODE);
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, STUB_CODE);
    }

    function _clearPinnedLibraries() internal {
        vm.etch(LibraryPins.PRICE_FEED_LIB, "");
        vm.etch(LibraryPins.NAV_REGISTRY_LIB, "");
    }

    /// @dev The address the guard recomputes for each library from current source. Derived independently of the
    ///      guard (different helper, different argument order) so it cannot agree with a broken guard by
    ///      construction.
    function _computedPriceFeedPin() internal view returns (address) {
        return vm.computeCreate2Address(
            keccak256(abi.encodePacked("PriceFeedLib", uint256(1))),
            keccak256(type(PriceFeedLib).creationCode),
            CANONICAL_CREATE2_DEPLOYER
        );
    }

    function _computedNavRegistryPin() internal view returns (address) {
        return vm.computeCreate2Address(
            keccak256(abi.encodePacked("NavRegistryLib", uint256(1))),
            keccak256(type(NAVRegistryLib).creationCode),
            CANONICAL_CREATE2_DEPLOYER
        );
    }

    function _priceFeedPinMatches() internal view returns (bool) {
        return _computedPriceFeedPin() == LibraryPins.PRICE_FEED_LIB;
    }

    function _navRegistryPinMatches() internal view returns (bool) {
        return _computedNavRegistryPin() == LibraryPins.NAV_REGISTRY_LIB;
    }

    // ---------------------------------------------------------------
    // Family 1: the pins must still match the library source in this tree.
    // Injected pins, so each assertion is trippable in ANY pin state.
    // ---------------------------------------------------------------

    function test_sourceMatch_revertsOnWrongPriceFeedPin() public {
        harness.setPinOverrides(WRONG_PRICE_FEED_PIN, _computedNavRegistryPin());
        vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        harness.assertLibrarySourceMatchesPins();
    }

    /// @notice The assertion reviewers proved had NO coverage: the PriceFeedLib check fires first and masked it,
    ///         so deleting this `require` left all ten tests green. Pinning PriceFeedLib to its correct computed
    ///         value forces execution past the first check, whatever state the real pins are in.
    function test_sourceMatch_revertsOnWrongNavRegistryPin() public {
        harness.setPinOverrides(_computedPriceFeedPin(), WRONG_REGISTRY_PIN);
        vm.expectRevert("NAVRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        harness.assertLibrarySourceMatchesPins();
    }

    /// @notice The positive direction, so the pair is not satisfied by rejecting everything.
    function test_sourceMatch_passesWhenBothPinsMatchSource() public {
        harness.setPinOverrides(_computedPriceFeedPin(), _computedNavRegistryPin());
        harness.assertLibrarySourceMatchesPins();
    }

    /// @notice Against the REAL pins, the guard must track the tree's actual state — red during PR #185's
    ///         regeneration, green after. Per-library message selection: `_pinsMatch...` is checked per library
    ///         because a one-library drift is the ordinary case (pins move only when a file in THAT library's
    ///         compilation closure changes), and the guard reports whichever library drifted.
    function test_sourceMatch_tracksRealPinState() public {
        if (_priceFeedPinMatches() && _navRegistryPinMatches()) {
            harness.assertLibrarySourceMatchesPins();
        } else if (!_priceFeedPinMatches()) {
            vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
            harness.assertLibrarySourceMatchesPins();
        } else {
            vm.expectRevert("NAVRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
            harness.assertLibrarySourceMatchesPins();
        }
    }

    /// @notice Locks the asymmetry that motivated adding family 1 at all: on a stale pin the OTHER two families
    ///         still pass, so they can never substitute for the source check. Synthetic rather than ambient, so
    ///         it asserts the same thing before and after a pin regeneration.
    function test_weakerFamiliesPassOnASyntheticallyStalePin() public {
        harness.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        vm.etch(WRONG_PRICE_FEED_PIN, STUB_CODE);
        vm.etch(WRONG_REGISTRY_PIN, STUB_CODE);
        bytes memory linkedToStalePins = abi.encodePacked(hex"60806040", WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);

        // Families 2 and 3 are satisfied by a pin that does not match the library source at all...
        harness.assertImplLinkedAndLibrariesPresent(linkedToStalePins);

        // ...while family 1 is the one that rejects it.
        vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        harness.assertLibrarySourceMatchesPins();
    }

    /// @notice The composite guard must actually invoke the source-match family. Constructed so ONLY family 1
    ///         can object: the injected pins are etched (family 3 passes) and the synthetic bytecode embeds them
    ///         (family 2 passes), while those pins do not match the library source (family 1 fails).
    /// @dev    Unhooking `_assertLibrarySourceMatchesPins()` from `_assertPinnedLibrariesUsable` makes this call
    ///         succeed and this test fail — in ANY pin state. The deploy-path wiring test cannot cover that once
    ///         PR #185 lands, because a matching tree makes its true branch assert success instead.
    function test_composite_invokesTheSourceMatchFamily() public {
        harness.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        vm.etch(WRONG_PRICE_FEED_PIN, STUB_CODE);
        vm.etch(WRONG_REGISTRY_PIN, STUB_CODE);
        bytes memory linkedToStalePins = abi.encodePacked(hex"60806040", WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        harness.assertPinnedLibrariesUsable(linkedToStalePins);
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
    ///         DELEGATECALL into nothing only reverts on first use — so deleting the guard call from
    ///         `_deployGuardedNavImplementation` makes this deploy SUCCEED and this test fail.
    /// @dev    Which of the six assertions objects first depends on the tree's pin state, so this asserts only
    ///         that the guard is REACHED and refuses. It cannot prove the call precedes the broadcast: relocating
    ///         it below `new` reverts the same external call. `forge script` simulates the whole run and
    ///         broadcasts nothing when it reverts, so ordering is defence in depth, not the load-bearing property.
    function test_guardedDeploy_revertsWhenTheGuardRejects() public {
        _clearPinnedLibraries();
        vm.expectRevert();
        harness.deployGuardedNavImplementation();
    }

    /// @notice The other direction, so the wiring is not satisfied by refusing everything.
    function test_guardedDeploy_succeedsOnlyWhenEverythingHolds() public {
        _deployPinnedLibraries();
        if (_priceFeedPinMatches() && _navRegistryPinMatches()) {
            NAVCalculator impl = harness.deployGuardedNavImplementation();
            assertGt(address(impl).code.length, 0, "implementation not deployed");
        } else {
            vm.expectRevert();
            harness.deployGuardedNavImplementation();
        }
    }

    /// @notice The HARNESS is not runnable as a script: `setUp()` reverts, and `forge script` calls it before
    ///         any entry point including a `--sig` target such as `deployGuardedNavImplementation()`. `run()` is
    ///         neutralised too, as defence in depth.
    /// @dev    Scope, stated precisely because an earlier revision of this docstring overclaimed: this closes the
    ///         HARNESS-rooted script paths, not every path in the file. `UpgradeNAVCalculatorPinsTest` is itself
    ///         a `forge script` entry point — its own `setUp()` cannot revert, since `forge test` needs it — so
    ///         `forge script <this file>:UpgradeNAVCalculatorPinsTest --sig "<a test that deploys>" --broadcast
    ///         --rpc-url <chain>` can still deploy an implementation once the pins match. That is a generic
    ///         property of any test contract that constructs a broadcasting helper, not something this file can
    ///         fix; the blast radius is one orphan implementation — no address recorded, no Safe TX, no proxy
    ///         repointed — and it takes a deliberate invocation of a test file as a script.
    function test_harnessIsNotRunnableAsADeployScript() public {
        vm.expectRevert("harness: not a deploy script");
        harness.setUp();
        vm.expectRevert("harness: not a deploy script");
        harness.run();
    }

    /// @notice The deploy wrapper can still succeed when the guard permits it — the direction no other test
    ///         covers while the pins drift, and the one that makes "rejects always" a detectable regression.
    function test_deployWrapper_succeedsWhenTheGuardPermits() public {
        UnguardedDeployHarness unguarded = new UnguardedDeployHarness();
        NAVCalculator impl = unguarded.deployGuardedNavImplementation();
        assertGt(address(impl).code.length, 0, "deploy wrapper produced no implementation");
    }

    /// @notice Guards the guard: the real implementation bytecode must embed both pins, so the positive tests
    ///         above cannot pass for an unrelated reason.
    function test_realImplBytecodeEmbedsBothPins() public view {
        bytes memory code = type(NAVCalculator).creationCode;
        assertTrue(LibraryPins.contains(code, LibraryPins.PRICE_FEED_LIB), "impl missing PriceFeedLib pin");
        assertTrue(LibraryPins.contains(code, LibraryPins.NAV_REGISTRY_LIB), "impl missing NAVRegistryLib pin");
    }
}
