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
        pure
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
    /// @dev    `bridgeImpl` is `01`'s FOURTH broadcast and is returned separately rather than folded into the
    ///         3-tuple, because `01_2` has no equivalent. Omitting it left `02_DeployProxies`' dependency on the
    ///         BridgeEscrow implementation unasserted: deleting the whole `if (plan.bridgeImpl.code.length == 0)`
    ///         block from `01` used to leave this file entirely green.
    /// @notice `01_2` deploys three contracts; `01`'s harness returns a fourth. See its docstring.
    function computedAddresses() external pure returns (address priceFeedLib, address navRegistryLib, address navImpl) {
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
