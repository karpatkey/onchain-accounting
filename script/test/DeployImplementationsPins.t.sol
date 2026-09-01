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

    /// @notice The PRODUCTION seam bodies, reached past the override. Explicit base qualification, so this reports
    ///         what a real run would use no matter what `setPinOverrides` holds.
    function productionPins() external view returns (address priceFeedLib, address navRegistryLib) {
        return (DeployImplementations._priceFeedLibPin(), DeployImplementations._navRegistryLibPin());
    }

    /// @notice Same guard, with the plan's addresses AND bytecode injectable.
    /// @dev    The pin seam alone cannot reach the linkage pair, in either pin state, which is why this exists.
    ///         Assertions 3-4 are only evaluated once 1-2 pass, and 1-2 force the injected pins to equal the
    ///         CREATE2 addresses computed from current source. On a drifted tree those differ from what the impl
    ///         bytecode embeds, so assertion 3 always fires first and 4 is unreachable; on a regenerated tree they
    ///         are exactly what it embeds, so 3 and 4 both pass and neither can be made to fail. Injecting the
    ///         bytecode breaks that coupling and makes each linkage assertion trippable in ANY pin state — which
    ///         is what this file's own rule 1 demands. Mirrors
    ///         `UpgradeNAVCalculatorHarness.assertImplLinkedAndLibrariesPresent(bytes)`.
    function assertPinnedLibrariesUsableWith(address priceFeedLib, address navRegistryLib, bytes memory implBytecode)
        external
        view
    {
        ImplPlan memory plan = _computeImplPlan();
        plan.priceFeedLib = priceFeedLib;
        plan.navRegistryLib = navRegistryLib;
        plan.navImplBytecode = implBytecode;
        _assertPinnedLibrariesUsable(plan);
    }

    /// @notice The CREATE2 addresses this script would deploy to, so a test can assert the deploy happened.
    /// @dev    `bridgeImpl` is `01`'s FOURTH broadcast; `01_2`'s harness returns only three because it has no
    ///         equivalent. Omitting it left `02_DeployProxies`' dependency on the BridgeEscrow implementation
    ///         unasserted — deleting the whole `if (plan.bridgeImpl.code.length == 0)` block from `01` used to
    ///         leave this file entirely green, and nothing else in the repo reaches script `01`.
    function computedAddresses()
        external
        view
        returns (address priceFeedLib, address navRegistryLib, address navImpl, address bridgeImpl)
    {
        ImplPlan memory plan = _computeImplPlan();
        return (plan.priceFeedLib, plan.navRegistryLib, plan.navImpl, plan.bridgeImpl);
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

    /// @notice See `DeployImplementationsHarness.productionPins`.
    function productionPins() external view returns (address priceFeedLib, address navRegistryLib) {
        return (DeployNAVImplementation._priceFeedLibPin(), DeployNAVImplementation._navRegistryLibPin());
    }

    /// @notice See `DeployImplementationsHarness.assertPinnedLibrariesUsableWith`.
    function assertPinnedLibrariesUsableWith(address priceFeedLib, address navRegistryLib, bytes memory implBytecode)
        external
        view
    {
        ImplPlan memory plan = _computeImplPlan();
        plan.priceFeedLib = priceFeedLib;
        plan.navRegistryLib = navRegistryLib;
        plan.navImplBytecode = implBytecode;
        _assertPinnedLibrariesUsable(plan);
    }

    /// @notice The CREATE2 addresses this script would deploy to, so a test can assert the deploy happened.
    /// @dev    Three, not four: `01_2`'s `ImplPlan` has no `bridgeImpl` member because this script does not deploy
    ///         the BridgeEscrow implementation. See `DeployImplementationsHarness.computedAddresses` for the
    ///         fourth address and why it is asserted there.
    function computedAddresses() external view returns (address priceFeedLib, address navRegistryLib, address navImpl) {
        ImplPlan memory plan = _computeImplPlan();
        return (plan.priceFeedLib, plan.navRegistryLib, plan.navImpl);
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

/// @notice Minimal stand-in for the canonical CREATE2 factory at `0x4e59…`, which holds no code in a bare test EVM.
/// @dev    Without it, `_deployIfNeeded`'s raw `.call` to a code-less address returns `ok == true` and deploys
///         NOTHING, so `require(ok, …)` passes and a positive control could not distinguish "the deploy wrapper
///         works" from "the deploy wrapper silently did nothing". Calldata layout is Arachnid's: 32-byte salt
///         followed by init code.
contract MockCreate2Factory {
    fallback() external payable {
        assembly {
            let len := sub(calldatasize(), 32)
            let ptr := mload(0x40)
            calldatacopy(ptr, 32, len)
            let deployed := create2(0, ptr, len, calldataload(0))
            if iszero(deployed) { revert(0, 0) }
            mstore(0x00, deployed)
            return(0x00, 0x20)
        }
    }
}

/// @notice Records whether `run()` reached `_guardedDeploy`, WITHOUT broadcasting anything.
/// @dev    Closes the last untested call site in the chain. Rule 2 below — "blanking a guard body and deleting its
///         call are different mutations, and only the second reaches production" — was applied at the
///         `_assertPinnedLibrariesUsable` <- `_guardedDeploy` frame and not at the `_guardedDeploy` <- `run()`
///         frame one level up. Nothing executed the production `run()` body, so refactoring it back to an inline
///         `vm.startBroadcast(); _deployIfNeeded(plan); vm.stopBroadcast();` — dropping the guard while KEEPING
///         the broadcast — left the whole file green. That is the PR's own defect class, one frame higher.
///
///         `run()` is the `forge script` entry point, so covering it terminates the chain rather than moving the
///         gap up again.
///
///         Why this harness may safely have a non-reverting `setUp()` when every other one here must revert: the
///         barrier exists because `run()` would otherwise broadcast. Here `_guardedDeploy` is replaced by a
///         recorder that contains no `vm.startBroadcast`, and `_saveAndLog` is a no-op, so driving this contract
///         with `forge script --broadcast` performs no deploy, writes no deployment record and repoints nothing.
///         It is strictly more inert than the reverting harnesses, not less.
///
///         `setUp()` seeds `chainConfig` instead of overriding `validateAddresses()`, so `BaseDeployScript` — used
///         by every deploy script — needs no new `virtual`.
abstract contract RunWiringRecorder {
    bool public guardedDeployCalled;
}

contract DeployImplementationsRunWiringHarness is DeployImplementations, RunWiringRecorder {
    function setUp() public override {
        chainConfig.admin = address(0xA11CE);
        chainConfig.manager = address(0xB0B);
    }

    function _guardedDeploy(ImplPlan memory) internal override {
        guardedDeployCalled = true;
    }

    function _saveAndLog(ImplPlan memory, bool) internal override {}
}

contract DeployNAVImplementationRunWiringHarness is DeployNAVImplementation, RunWiringRecorder {
    function setUp() public override {
        chainConfig.admin = address(0xA11CE);
        chainConfig.manager = address(0xB0B);
    }

    function _guardedDeploy(ImplPlan memory) internal override {
        guardedDeployCalled = true;
    }

    function _saveAndLog(ImplPlan memory) internal override {}
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
    //
    // These inject the BYTECODE as well as the pins. An earlier revision injected only the pins and relied on the
    // tree's own drift to make the linkage check fire; two review gates independently showed that could not work:
    // assertions 3-4 are reached only once 1-2 pass, and 1-2 force the injected pins to equal the CREATE2
    // addresses computed from current source. On a drifted tree those differ from what the bytecode embeds, so
    // assertion 3 always fired first and assertion 4 was UNREACHABLE; on a regenerated tree they are exactly what
    // it embeds, so both would pass and the tests self-skipped into vacuity. Deleting assertion 4 from either
    // script left the whole suite green — the same defect class this PR exists to close.
    //
    // Injecting a matched (pin, plan-address) pair satisfies 1-2 by construction in ANY pin state, so the
    // synthetic bytecode alone decides 3 and 4. The `vm.skip` is gone with it.
    // ---------------------------------------------------------------

    /// @dev Bytecode embeds the registry pin but NOT the price-feed pin, so only assertion 3 can object.
    function test_01_linkage_revertsWhenImplNotLinkedAgainstPriceFeedLib() public {
        impls.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        bytes memory unlinked = abi.encodePacked(hex"60806040", WRONG_REGISTRY_PIN);
        vm.expectRevert("NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)");
        impls.assertPinnedLibrariesUsableWith(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN, unlinked);
    }

    /// @notice The assertion that had no coverage in any pin state, in either script.
    /// @dev Bytecode embeds the price-feed pin but NOT the registry pin, so assertion 3 passes and only 4 objects.
    ///      This is what stops a 24-chain broadcast of an impl that would DELEGATECALL empty code on the registry
    ///      library and revert on `initialize()`.
    function test_01_linkage_revertsWhenImplNotLinkedAgainstNavRegistryLib() public {
        impls.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        bytes memory unlinked = abi.encodePacked(hex"60806040", WRONG_PRICE_FEED_PIN);
        vm.expectRevert("NAVCalculator impl not linked against pinned NAVRegistryLib (foundry.toml `libraries` drift)");
        impls.assertPinnedLibrariesUsableWith(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN, unlinked);
    }

    function test_01_2_linkage_revertsWhenImplNotLinkedAgainstPriceFeedLib() public {
        navImpl.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        bytes memory unlinked = abi.encodePacked(hex"60806040", WRONG_REGISTRY_PIN);
        vm.expectRevert("NAVCalculator impl not linked against pinned PriceFeedLib (foundry.toml `libraries` drift)");
        navImpl.assertPinnedLibrariesUsableWith(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN, unlinked);
    }

    function test_01_2_linkage_revertsWhenImplNotLinkedAgainstNavRegistryLib() public {
        navImpl.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        bytes memory unlinked = abi.encodePacked(hex"60806040", WRONG_PRICE_FEED_PIN);
        vm.expectRevert("NAVCalculator impl not linked against pinned NAVRegistryLib (foundry.toml `libraries` drift)");
        navImpl.assertPinnedLibrariesUsableWith(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN, unlinked);
    }

    /// @notice The positive direction for the linkage pair, so neither test above is satisfied by a guard that
    ///         rejects every bytecode. Bytecode embeds BOTH pins; all four assertions pass.
    function test_linkage_passesWhenBothPinsAreEmbedded() public {
        bytes memory linked = abi.encodePacked(hex"60806040", WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);

        impls.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        impls.assertPinnedLibrariesUsableWith(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN, linked);

        navImpl.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        navImpl.assertPinnedLibrariesUsableWith(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN, linked);
    }

    // ---------------------------------------------------------------
    // The wiring: the deploy path must go through the guard.
    // This is the family whose absence the sweep found. Deleting the
    // `_assertPinnedLibrariesUsable` call from `_guardedDeploy` makes these deploys SUCCEED and these tests fail.
    // ---------------------------------------------------------------

    /// @dev The revert MESSAGE is pinned, not just the fact of a revert. `UpgradeNAVCalculatorPins.t.sol` uses a
    ///      bare `expectRevert` for its equivalent, correctly — it injects no pins, so which of its six assertions
    ///      objects first depends on the tree's pin state. That rationale does not transfer here: both pins are
    ///      injected wrong, so assertion 1 fires deterministically in any pin state and the message is knowable.
    ///
    ///      Worth the extra argument because a bare `expectRevert` here would be satisfied by ANY revert,
    ///      including one from `_deployIfNeeded` rather than from the guard. It kills the guard-deletion mutation
    ///      today only because a raw `.call` to the code-less canonical factory returns `ok == true` in a bare
    ///      test EVM, so the deploy cannot fail on its own — an incidental property, not a designed one. Pinning
    ///      the message removes the dependency. This is the same lesson as `ETHPlus_CustomPriceFeed.t.sol` in
    ///      this PR, where a bare `expectRevert` let one constructor guard stand in for another.
    function test_01_guardedDeploy_revertsWhenTheGuardRejects() public {
        impls.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        impls.guardedDeploy();
    }

    function test_01_2_guardedDeploy_revertsWhenTheGuardRejects() public {
        navImpl.setPinOverrides(WRONG_PRICE_FEED_PIN, WRONG_REGISTRY_PIN);
        vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
        navImpl.guardedDeploy();
    }

    /// @notice The other direction, so the wiring is not satisfied by a deploy path that refuses everything.
    /// @dev    A reviewer mutation on PR #194 showed nothing else catches this: `require(false)` inside the
    ///         deploy wrapper left every test green, because every test that reached the deploy expected a revert.
    ///
    ///         The factory has to be etched first. `_deployIfNeeded` reaches the canonical CREATE2 deployer with a
    ///         raw `.call`, and a call to a CODE-LESS address returns `ok == true` — so on a bare test EVM
    ///         `require(ok, …)` passes while nothing is deployed, and a control that only checked "did not revert"
    ///         would pass identically if the wrapper deployed nothing at all. Asserting the computed addresses
    ///         hold code is what turns this from "did not revert" into "did the thing".
    function test_01_guardedDeploy_succeedsWhenTheGuardIsSatisfied() public {
        vm.etch(CANONICAL_CREATE2_DEPLOYER, address(new MockCreate2Factory()).code);
        UnguardedDeployImplementationsHarness unguarded = new UnguardedDeployImplementationsHarness();
        (address pfl, address nrl, address impl, address bridge) = unguarded.computedAddresses();
        assertEq(pfl.code.length, 0, "fixture: nothing deployed yet");

        unguarded.guardedDeploy();

        assertGt(pfl.code.length, 0, "PriceFeedLib not deployed");
        assertGt(nrl.code.length, 0, "NAVRegistryLib not deployed");
        assertGt(impl.code.length, 0, "NAVCalculator implementation not deployed");
        // `01`'s fourth broadcast. `02_DeployProxies` hard-depends on this implementation existing, and nothing
        // else in the repo reaches script `01`, so without this assertion that deploy has no coverage at all.
        assertGt(bridge.code.length, 0, "BridgeEscrow implementation not deployed");
    }

    function test_01_2_guardedDeploy_succeedsWhenTheGuardIsSatisfied() public {
        vm.etch(CANONICAL_CREATE2_DEPLOYER, address(new MockCreate2Factory()).code);
        UnguardedDeployNAVImplementationHarness unguarded = new UnguardedDeployNAVImplementationHarness();
        (address pfl, address nrl, address impl) = unguarded.computedAddresses();
        assertEq(pfl.code.length, 0, "fixture: nothing deployed yet");

        unguarded.guardedDeploy();

        assertGt(pfl.code.length, 0, "PriceFeedLib not deployed");
        assertGt(nrl.code.length, 0, "NAVRegistryLib not deployed");
        assertGt(impl.code.length, 0, "NAVCalculator implementation not deployed");
    }

    // ---------------------------------------------------------------
    // The frame above: run() must go through the guarded wrapper.
    // ---------------------------------------------------------------

    /// @notice Kills the mutation that inlines the broadcast into `run()`, dropping the guard but keeping the
    ///         deploy — a stale pin broadcast unchecked to 24 chains, with a green suite.
    /// @dev    Pure DELETION of `_guardedDeploy(plan)` from `run()` is fail-safe, because the guard call and the
    ///         only broadcast are co-located inside it: delete the call and nothing deploys. That is why an earlier
    ///         review round refuted this as a finding. But the mutation that matters is not deletion, it is the
    ///         refactor back to `vm.startBroadcast(); _deployIfNeeded(plan); vm.stopBroadcast();` — exactly the
    ///         shape this PR replaced. Nothing executed the production `run()` body, so that refactor was
    ///         invisible. It is not invisible now.
    function test_01_run_goesThroughTheGuardedWrapper() public {
        DeployImplementationsRunWiringHarness h = new DeployImplementationsRunWiringHarness();
        assertFalse(h.guardedDeployCalled(), "fixture");

        h.run();

        assertTrue(h.guardedDeployCalled(), "run() must reach _guardedDeploy, not broadcast on its own");
    }

    function test_01_2_run_goesThroughTheGuardedWrapper() public {
        DeployNAVImplementationRunWiringHarness h = new DeployNAVImplementationRunWiringHarness();
        assertFalse(h.guardedDeployCalled(), "fixture");

        h.run();

        assertTrue(h.guardedDeployCalled(), "run() must reach _guardedDeploy, not broadcast on its own");
    }

    // ---------------------------------------------------------------
    // The production seams themselves.
    // ---------------------------------------------------------------

    /// @notice Each production seam returns ITS OWN library's pin. Kills a swap in any pin state.
    /// @dev    This is the test that actually closes the gap. `test_sourceMatch_tracksRealPinState` below
    ///         exercises the seams but does NOT kill a swap on a drifting tree: assertion 1 compares the computed
    ///         PriceFeedLib address against whatever the seam returns, and on a drifted tree BOTH the correct pin
    ///         and the swapped one differ from it, so the same revert fires either way. I confirmed that by
    ///         mutation — swapping the seams left the whole file green — after believing the tracking test was
    ///         sufficient. Comparing the seams directly is pin-state-independent.
    ///
    ///         It does restate the production bodies, which is normally the shape to avoid. It earns its place by
    ///         pinning a MAPPING rather than a value: which seam returns which constant. That is exactly the
    ///         copy-paste class of error, and this PR already made one of them — the `bridgeImpl` 4-tuple landed
    ///         on `01_2`'s harness, which has no such member.
    function test_pinSeamsReturnTheirOwnLibrarysPin() public view {
        (address pfl, address nrl) = impls.productionPins();
        assertEq(pfl, LibraryPins.PRICE_FEED_LIB, "01: price-feed seam must return the PriceFeedLib pin");
        assertEq(nrl, LibraryPins.NAV_REGISTRY_LIB, "01: registry seam must return the NAVRegistryLib pin");

        (address pfl2, address nrl2) = navImpl.productionPins();
        assertEq(pfl2, LibraryPins.PRICE_FEED_LIB, "01_2: price-feed seam must return the PriceFeedLib pin");
        assertEq(nrl2, LibraryPins.NAV_REGISTRY_LIB, "01_2: registry seam must return the NAVRegistryLib pin");
    }

    /// @notice Against the REAL pins — no overrides — the guard must track the tree's actual state: red during
    ///         PR #185's regeneration, green after.
    /// @dev    Every other test in this file injects overrides or blanks the guard, so the `super.` branch of the
    ///         pin seams was otherwise dead in the suite. Mirrors `UpgradeNAVCalculatorPins.t.sol`'s
    ///         `test_sourceMatch_tracksRealPinState`, which the first revision of this file omitted. Per-library
    ///         message selection because a one-library drift is the ordinary case — pins move only when a file in
    ///         THAT library's compilation closure changes. See the test above for what this one does NOT catch.
    function test_sourceMatch_tracksRealPinState() public {
        bool priceFeedMatches = _computedPriceFeedPin() == LibraryPins.PRICE_FEED_LIB;
        bool navRegistryMatches = _computedNavRegistryPin() == LibraryPins.NAV_REGISTRY_LIB;

        if (priceFeedMatches && navRegistryMatches) {
            // Pins regenerated: the source-match pair passes, and the linkage pair passes because the impl
            // bytecode embeds those same addresses. The whole guard is satisfied.
            impls.assertPinnedLibrariesUsable();
        } else if (!priceFeedMatches) {
            vm.expectRevert("PriceFeedLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
            impls.assertPinnedLibrariesUsable();
        } else {
            vm.expectRevert("NAVRegistryLib CREATE2 addr != foundry.toml pin (lib bytecode drift; regenerate the pin)");
            impls.assertPinnedLibrariesUsable();
        }
    }

    // ---------------------------------------------------------------
    // The harness is inert as a script.
    // ---------------------------------------------------------------

    /// @dev `forge script` calls `setUp()` before any entry point including a `--sig` target, so a reverting
    ///      `setUp()` closes `--sig guardedDeploy()` too. Scope, stated precisely: this covers the HARNESS-rooted
    ///      paths. `DeployImplementationsPinsTest` is itself a `forge script` entry point and its own `setUp()`
    ///      cannot revert (`forge test` needs it) — a generic property of any test contract that constructs a
    ///      broadcasting helper.
    ///
    ///      **Blast radius of that residual path, since it differs in shape from the one
    ///      `UpgradeNAVCalculatorPins.t.sol` documents.** There, the residual deploy is a plain
    ///      `new NAVCalculator()` at a nonce-dependent address. Here it is CREATE2 through the canonical deployer
    ///      at the exact deterministic addresses the 24-chain deployment pins, with the guard neutralised in the
    ///      `Unguarded*` variants. Running
    ///      `forge script <this file>:DeployImplementationsPinsTest --sig "<a deploying test>" --broadcast` would
    ///      therefore broadcast up to four real CREATE2 deploys (PriceFeedLib, NAVRegistryLib, the NAVCalculator
    ///      impl and — for `01` — the BridgeEscrow impl). What it does NOT do: `guardedDeploy()` never calls
    ///      `_saveAndLog`, so `script/config/deployments/<chainId>.json` is untouched, no Safe TX is written and
    ///      no proxy is repointed. On a stale-pin tree the impl's creation code embeds the old pins, so it lands
    ///      on an address a later regeneration would not reuse. The libraries land as orphans at their computed
    ///      addresses. It also requires deliberately invoking a `.t.sol` file as a broadcast script.
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
