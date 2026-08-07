// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";
import {InvalidArguments, NotAuthorized} from "src/errors.sol";
import {IPrices} from "src/prices/IPrices.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @notice Minimal `NAVCalculator` stand-in. The registry needs THREE things from the NAV — `hasRole` (its only
///         authority source), `getAssetPricing` (the peg derivation's input) and the register/unregister entry points
///         it forwards to — so the mock provides those and
///         records the forwarded calls, which is what lets a test prove the forward actually happened.
contract MockNav {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    address[] public registered;
    address[] public unregistered;
    bool public revertOnRegister;
    bool public revertOnUnregister;

    error MockNavRegisterReverted();
    error MockNavUnregisterReverted();
    error MockNavNotAuthorized();
    error MockNavAssetNotRegistered();
    error MockNavAlreadyRegistered();

    function grant(bytes32 role, address who) external {
        _roles[role][who] = true;
    }

    function revoke(bytes32 role, address who) external {
        _roles[role][who] = false;
    }

    function hasRole(bytes32 role, address who) external view returns (bool) {
        return _roles[role][who];
    }

    /// @dev The derivation's input. `AssetKindRegistry` reads `pegToleranceBps` through `IPrices` to compute `PegKind`,
    ///      so a test that never varies this never exercises the derivation at all.
    mapping(address => IPrices.AssetPricing) private _pricing;
    mapping(address => bool) private _isRegistered;

    function setPegTolerance(address asset, uint32 bps) external {
        _pricing[asset].pegToleranceBps = bps;
    }

    function getAssetPricing(address asset) external view returns (IPrices.AssetPricing memory) {
        return _pricing[asset];
    }

    function setRevertOnRegister(bool v) external {
        revertOnRegister = v;
    }

    function setRevertOnUnregister(bool v) external {
        revertOnUnregister = v;
    }

    /// @dev ⚠️ **These MUST gate on MANAGER, exactly as the real `NAVCalculator` does.** An earlier version of this mock
    ///      authorised every caller, and that single omission hid a fatal bug through 28 green tests and a 5/5 mutation
    ///      matrix: the facade forwards to `NAV.registerAsset`, the real NAV gates on ITS `msg.sender` — the REGISTRY,
    ///      not the operator — and nothing granted the registry that role, so every facade call reverted on-chain while
    ///      the suite reported success. A mock that is more permissive than production makes the tests structurally
    ///      unable to see an authority defect. If you relax this, you reintroduce that blindness.
    function registerAsset(address asset, address, IPrices.PriceType, uint256) external {
        if (!_roles[MANAGER][msg.sender]) revert MockNavNotAuthorized();
        // Faithful to `NAVCalculator.registerAsset`, which reverts `InvalidArguments()` for an asset it already
        // holds. `_setAssetLabels`'s justification for carrying no write-once guard rests on exactly that
        // behaviour — "{registerAsset} can only succeed for an asset the NAV does not already hold, so
        // `_labels[asset]` is empty whenever this runs through the facade" — and a mock without it cannot
        // falsify that claim. Latent rather than live when added: no test re-registered without an intervening
        // unregister, so nothing was vacuous. Added so nothing becomes vacuous later.
        if (_isRegistered[asset]) revert MockNavAlreadyRegistered();
        if (revertOnRegister) revert MockNavRegisterReverted();
        registered.push(asset);
        _isRegistered[asset] = true;
    }

    function unregisterAsset(address asset) external {
        if (!_roles[MANAGER][msg.sender]) revert MockNavNotAuthorized();
        // Faithful to `NAVCalculator.unregisterAsset`, which calls `_requireAssetExists` FIRST. Without this the
        // mock let the facade unregister an asset the NAV never held — and that is the exact premise the
        // {setAssetLabels} not-registered guard is justified by, so a mock that is more permissive than production
        // makes the justification untestable.
        if (!_isRegistered[asset]) revert MockNavAssetNotRegistered();
        if (revertOnUnregister) revert MockNavUnregisterReverted();
        unregistered.push(asset);
        _isRegistered[asset] = false;
    }

    /// @notice Mirrors `NAVCalculator.isAssetRegistered`, which {AssetKindRegistry-setAssetLabels} gates on.
    /// @dev Tracked as REAL state rather than hardcoded, and flipped by the two mutators above, so a test cannot
    ///      accidentally set labels on an asset this mock never registered — the guard has to be exercised against a
    ///      registration that actually happened, the same way production would.
    function isAssetRegistered(address asset) external view returns (bool) {
        return _isRegistered[asset];
    }

    function registeredCount() external view returns (uint256) {
        return registered.length;
    }

    function unregisteredCount() external view returns (uint256) {
        return unregistered.length;
    }
}

/// @title AssetKindRegistryTest
/// @notice Unit tests for the two-axis asset-kind registry: the atomic register+classify facade, all six combinations,
///         the fail-closed read, the delegated authority gate, and the batch surface's all-or-nothing contract.
contract AssetKindRegistryTest is Test {
    AssetKindRegistry internal registry;

    MockNav internal nav;

    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");

    // Real mainnet addresses, used as documentation-in-code: these are the assets the classification is ABOUT.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address internal constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c; // Aave V3 aUSDC

    function setUp() public {
        nav = new MockNav();
        nav.grant(MANAGER, manager);
        registry = new AssetKindRegistry(address(nav));
        // Mirrors `08_DeployAssetKindRegistry`: the registry must hold MANAGER on the NAV or its forwards revert.
        nav.grant(MANAGER, address(registry));
    }

    /// @dev Stores the accrual axis. The peg axis is NOT settable — use {_pegged} to move the NAV tolerance the
    ///      derivation reads.
    function _set(address asset, AccrualKind a) internal {
        vm.prank(manager);
        registry.setAssetKind(asset, a);
    }

    /// @dev The empty label list every kind-focused test passes. An empty argument means "leave the labels alone", so
    ///      these tests stay about the axis they are testing.
    function _noLabels() internal pure returns (string[] memory) {
        return new string[](0);
    }

    /// @dev A one-element label list.
    function _labels(string memory a) internal pure returns (string[] memory l) {
        l = new string[](1);
        l[0] = a;
    }

    /// @dev A two-element label list in SIGNIFICANT order: index 0 is the protocol, index 1 narrows to the product —
    ///      `("Aave v3", "Savings")`, `("Lido", "LST")`.
    function _labels(string memory a, string memory b) internal pure returns (string[] memory l) {
        l = new string[](2);
        l[0] = a;
        l[1] = b;
    }

    /// @dev Asserts a label list matches, element for element and in order.
    function _assertLabels(address asset, string[] memory expected) internal view {
        string[] memory actual = registry.getAssetLabels(asset);
        assertEq(actual.length, expected.length, "label count");
        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i], expected[i], "label element");
        }
    }

    /// @dev Makes `asset` derive as `Pegged` by giving it a non-zero NAV peg tolerance (the real switch).
    function _pegged(address asset) internal {
        nav.setPegTolerance(asset, 100);
    }

    // ============================================================
    // The atomic facade — register+classify as ONE call
    // ============================================================

    /// @dev **The test that was missing, and whose absence shipped a non-functional facade.** The registry must hold
    ///      `MANAGER` on the NAV, because the forwarded `NAV.registerAsset` gates on the REGISTRY as `msg.sender`, not
    ///      on the operator. Revoke that grant and the facade must fail — if this test ever passes without the grant,
    ///      either the mock has stopped gating or the NAV no longer checks, and both mean the suite has gone blind to
    ///      an authority defect again.
    ///
    ///      Note the operator is still a NAV MANAGER throughout: this isolates the REGISTRY's privilege specifically,
    ///      which is the hop that was missing.
    function test_facadeRevertsIfRegistryLacksNavManager() public {
        nav.revoke(MANAGER, address(registry));
        _pegged(USDC);

        vm.prank(manager);
        vm.expectRevert(MockNav.MockNavNotAuthorized.selector);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _noLabels());

        vm.prank(manager);
        vm.expectRevert(MockNav.MockNavNotAuthorized.selector);
        registry.unregisterAsset(USDC);

        assertEq(nav.registeredCount(), 0, "nothing may reach the NAV without the registry's own role");

        // **The deploy hazard's JOINT state, which no test could previously express.** The suite pinned "facade dead"
        // and "classification works" separately and never together — so the exact outcome of `grantRole` failing while
        // `setAssetKinds` succeeds (a fully classified registry whose facade is dead, script exiting 0) was not
        // representable in any test. These two assertions make it representable: with the registry's NAV role revoked,
        // classification STILL SUCCEEDS, because `setAssetKinds` gates on the OPERATOR's role, not the registry's.
        //
        // That asymmetry is the hazard in one line. If this ever starts reverting, the two paths have been coupled and
        // the deploy failure mode has changed shape — re-read `08`'s three-transaction note before "fixing" this test.
        vm.prank(manager);
        registry.setAssetKinds(_one(USDC), _one(AccrualKind.None));
        assertTrue(registry.isClassified(USDC), "classification succeeds while the facade is dead - the hazard state");
    }

    function _one(address a) private pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _one(AccrualKind k) private pure returns (AccrualKind[] memory out) {
        out = new AccrualKind[](1);
        out[0] = k;
    }

    /// @dev The whole point of the contract: one call registers on the NAV AND classifies, so a registered asset is
    ///      always classified. Asserts BOTH halves landed, and that the NAV received the forward (not just that the
    ///      kind was stored) — otherwise a facade that silently skipped the forward would pass.
    function test_registerAsset_classifiesAndForwardsInOneCall() public {
        _pegged(USDC); // the NAV tolerance is what makes it derive as Pegged
        vm.prank(manager);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _noLabels());

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
        assertEq(nav.registeredCount(), 1, "the NAV must actually have been called");
        assertEq(nav.registered(0), USDC);
    }

    /// @dev Symmetry, as required: removal works the same way. Clears the kind AND forwards the unregister.
    function test_unregisterAsset_clearsAndForwardsInOneCall() public {
        vm.prank(manager);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _noLabels());

        vm.prank(manager);
        registry.unregisterAsset(USDC);

        assertFalse(registry.isClassified(USDC), "kind must be gone");
        assertEq(nav.unregisteredCount(), 1, "the NAV must actually have been called");
        assertEq(nav.unregistered(0), USDC);
    }

    /// @dev **Atomicity, proven from the failing side rather than asserted.** If the NAV half reverts, the kind must not
    ///      survive — there is no `try`/`catch` on this path, so the whole transaction reverts. A facade that stored the
    ///      kind in a separate transaction, or swallowed the NAV failure, would leave USDC classified here.
    function test_registerAsset_isAtomic_navRevertLeavesNoKind() public {
        nav.setRevertOnRegister(true);

        vm.prank(manager);
        vm.expectRevert(MockNav.MockNavRegisterReverted.selector);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _noLabels());

        assertFalse(registry.isClassified(USDC), "a reverted NAV call must leave NO classification behind");
        assertEq(nav.registeredCount(), 0);
    }

    /// @dev The mirror: a failing unregister must not leave the asset stripped of its kind.
    function test_unregisterAsset_isAtomic_navRevertKeepsTheKind() public {
        _pegged(USDC);
        vm.prank(manager);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _noLabels());
        nav.setRevertOnUnregister(true);

        vm.prank(manager);
        vm.expectRevert(MockNav.MockNavUnregisterReverted.selector);
        registry.unregisterAsset(USDC);

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
    }

    /// @dev **The case that forced `unregisterAsset` to be idempotent on the kind.** Direct `NAV.registerAsset` remains
    ///      possible for any MANAGER by design (whether to revoke that is a deploy-time role decision, not a code one),
    ///      so an asset can exist on the NAV with NO classification. Unregistering it through the facade must still
    ///      work. Using the reverting {clearAssetKind} internally would make the facade unusable for exactly these
    ///      assets — which would be a self-inflicted outage on the path the facade is supposed to own.
    function test_unregisterAsset_worksForAnAssetThatWasNeverClassified() public {
        // Model the premise the docstring states: the asset is on the NAV, registered DIRECTLY, with no kind here.
        // This line is not decoration — before `MockNav.unregisterAsset` mirrored `_requireAssetExists`, the test
        // passed without it while modelling nothing, because the mock let the facade unregister an asset the NAV
        // had never held.
        vm.prank(manager);
        nav.registerAsset(WETH, address(0xFEED), IPrices.PriceType.Chainlink, 3600);
        assertFalse(registry.isClassified(WETH));

        vm.prank(manager);
        registry.unregisterAsset(WETH); // must not revert

        assertEq(nav.unregisteredCount(), 1, "forward still happens with nothing to clear");
        assertEq(nav.unregistered(0), WETH);
    }

    /// @dev Both facade entry points are gated by the NAV's MANAGER, not by anything local.
    function test_facadeIsNavManagerGated() public {
        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _noLabels());

        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        registry.unregisterAsset(USDC);

        assertEq(nav.registeredCount(), 0, "an unauthorized call must not reach the NAV");
        assertEq(nav.unregisteredCount(), 0);
    }

    // ============================================================
    // The six combinations
    // ============================================================

    /// @dev Every cell the registry can hold round-trips, storage-wise: the mapping is agnostic and accepts all six
    ///      pairs. This is the test that justifies two axes rather than one enum — if a single enum could express
    ///      these, the combinations would not be independent.
    ///
    ///      **`Pegged + Appreciating` is exercised here for STORAGE only, and its member is deliberately a made-up
    ///      address rather than a real asset.** No real asset belongs in that cell: a growing redemption rate on a
    ///      static balance moves the USD price off $1, which is what "not pegged" means. See {AccrualKind}. Storing it
    ///      must still work — the registry is a dumb map and must not silently reinterpret what a MANAGER wrote — but
    ///      pointing a real symbol at it would pin a classification the pricing layer contradicts.
    function test_allSixCombinationsRoundTrip() public {
        address memberlessCellProbe = makeAddr("pegged-appreciating-has-no-real-member");

        _pegged(USDC);
        _set(USDC, AccrualKind.None);
        _pegged(AUSDC);
        _set(AUSDC, AccrualKind.Rebasing);
        _pegged(memberlessCellProbe);
        _set(memberlessCellProbe, AccrualKind.Appreciating);
        _set(WETH, AccrualKind.None);
        _set(STETH, AccrualKind.Rebasing);
        _set(WSTETH, AccrualKind.Appreciating);

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
        _assertKind(AUSDC, PegKind.Pegged, AccrualKind.Rebasing);
        _assertKind(memberlessCellProbe, PegKind.Pegged, AccrualKind.Appreciating);
        _assertKind(WETH, PegKind.Floating, AccrualKind.None);
        _assertKind(STETH, PegKind.Floating, AccrualKind.Rebasing);
        _assertKind(WSTETH, PegKind.Floating, AccrualKind.Appreciating);
    }

    /// @dev **sDAI is `Floating`, not `Pegged`** — the ruling that resolves the one contested cell. A yield-bearing
    ///      wrapper has no peg: its USD price is not $1 and rises with accrued yield, exactly as wstETH's does with
    ///      ETH. An earlier revision of this file asserted `Pegged + Appreciating` for sDAI, which contradicted the
    ///      repo's own pricing layer: `pegToleranceBps` (the absolute-$1 guard) is set on the true stablecoins and on
    ///      **no** yield-bearing wrapper. That absence is the discriminator — note that only `sUSDe` also carries
    ///      wstETH's `divergenceToleranceBps` + monitors, and sDAI is configured on Gnosis rather than mainnet.
    ///
    ///      **⚠️ This is a DOCUMENTATION test, not a machine check of the ruling, and must not be cited as one.** Every
    ///      value it asserts is written by the test two lines earlier, so it pins the intent rather than the data. (The
    ///      config now lives on `main` — chain 100 carries `sDAI.accrualKind = "Appreciating"` — but this test writes
    ///      its own values and never reads it, which is why it remains documentation rather than a check.) So no mutation of the production code fails this test
    ///      that `test_allSixCombinationsRoundTrip` would not already catch. It is kept for the same reason
    ///      {test_wstETHIsFloatingNotPegged} is: it records the intended classification next to the reasoning, where a
    ///      future author will look.
    ///
    ///      **There is no machine check of the ruling any more, and that is by design rather than an oversight.** An
    ///      earlier revision cited `08`'s `Pegged` ⇔ `pegToleranceBps > 0` assertion here; that guard was deleted when
    ///      the peg axis became derived, because with one authority there is no second value to disagree with. What
    ///      replaced the check is stronger than a check: the contradiction is no longer expressible in config.
    function test_sDAIIsFloatingNotPegged_becauseYieldBearingMeansNoPeg() public {
        _set(SDAI, AccrualKind.Appreciating);
        _assertKind(SDAI, PegKind.Floating, AccrualKind.Appreciating);

        // Same cell as wstETH — recording the shared mechanism, not proving it (see the warning above: both values
        // are written here, so this comparison cannot fail independently of the round-trip test).
        _set(WSTETH, AccrualKind.Appreciating);
        (PegKind sdaiPeg, AccrualKind sdaiAccrual) = registry.getAssetKind(SDAI);
        (PegKind wstethPeg, AccrualKind wstethAccrual) = registry.getAssetKind(WSTETH);
        assertEq(uint8(sdaiPeg), uint8(wstethPeg), "an appreciating wrapper is Floating regardless of denomination");
        assertEq(uint8(sdaiAccrual), uint8(wstethAccrual));
    }

    /// @dev `Pegged + Rebasing` has NO registered member today — no aToken is currently registered — so it would
    ///      otherwise be an untested branch reached first by a live registration. Pinned deliberately: the first
    ///      aToken registration is a plausible near-term event, and it must not be the moment this cell is first
    ///      exercised.
    function test_peggedRebasing_theCellWithNoMemberToday() public {
        _pegged(AUSDC);
        _set(AUSDC, AccrualKind.Rebasing);
        (PegKind p, AccrualKind a) = registry.getAssetKind(AUSDC);
        assertEq(uint8(p), uint8(PegKind.Pegged), "an aToken is pegged to USD");
        assertEq(uint8(a), uint8(AccrualKind.Rebasing), "and its BALANCE grows, so Rebasing not Appreciating");
    }

    /// @dev wstETH is `Floating`, and this is the axis's definitional edge. `Pegged` means pegged to the NAV's QUOTE
    ///      asset (USD), not "rigidly related to something": wstETH tracks stETH tightly but its USD price moves with
    ///      ETH. Getting this backwards would invert the operational property the axis exists to predict — a
    ///      zero-heartbeat-margin staleness condition tends to reach heartbeat-driven feeds, which pegged assets more
    ///      often are. A correlation with the feed's publish behaviour, not a law about the peg — see {PegKind}.
    function test_wstETHIsFloatingNotPegged() public {
        _set(WSTETH, AccrualKind.Appreciating);
        (PegKind p,) = registry.getAssetKind(WSTETH);
        assertEq(uint8(p), uint8(PegKind.Floating), "wstETH is Floating: Pegged means pegged to the QUOTE asset");
    }

    /// @dev stETH and wstETH are the same underlying exposure and differ ONLY on the accrual axis. If a future change
    ///      ever collapses the two axes, this is the assertion that breaks.
    function test_stETHAndWstETHDifferOnlyOnAccrual() public {
        _set(STETH, AccrualKind.Rebasing);
        _set(WSTETH, AccrualKind.Appreciating);
        (PegKind pSteth, AccrualKind aSteth) = registry.getAssetKind(STETH);
        (PegKind pWsteth, AccrualKind aWsteth) = registry.getAssetKind(WSTETH);
        assertEq(uint8(pSteth), uint8(pWsteth), "same peg axis");
        assertTrue(uint8(aSteth) != uint8(aWsteth), "different accrual axis: balance grows vs rate grows");
    }

    // ============================================================
    // Fail-closed reads
    // ============================================================

    /// @dev The central safety property. An unclassified asset must REVERT, not return the zero value: `Pegged` +
    ///      `None` is a plausible-looking answer that is wrong for most assets, so a silent default would be
    ///      indistinguishable from real data.
    function test_unclassifiedAssetRevertsRatherThanDefaulting() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotClassified.selector, WETH));
        registry.getAssetKind(WETH);
    }

    /// @dev And the zero value is genuinely reachable as a REAL classification, which is exactly why the sentinel is
    ///      needed: `Pegged` + `None` (USDC) is indistinguishable from unset without it.
    function test_theZeroValueIsARealClassification_soTheSentinelIsLoadBearing() public {
        assertFalse(registry.isClassified(USDC), "precondition: unset");
        _pegged(USDC);
        _set(USDC, AccrualKind.None); // both enums are 0
        assertTrue(registry.isClassified(USDC), "an all-zero classification still reads as classified");
        (PegKind p, AccrualKind a) = registry.getAssetKind(USDC);
        assertEq(uint8(p), 0);
        assertEq(uint8(a), 0);
    }

    function test_isClassified_isTheNonRevertingProbe() public {
        assertFalse(registry.isClassified(WETH));
        _set(WETH, AccrualKind.None);
        assertTrue(registry.isClassified(WETH));
    }

    // ============================================================
    // Batch surface
    // ============================================================

    function test_getAssetKinds_batchRoundTrips() public {
        _pegged(USDC);
        _set(USDC, AccrualKind.None);
        _set(WSTETH, AccrualKind.Appreciating);

        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = WSTETH;
        (PegKind[] memory pegs, AccrualKind[] memory accruals) = registry.getAssetKinds(assets);

        assertEq(pegs.length, 2);
        assertEq(accruals.length, 2);
        // EVERY index on BOTH axes. Asserting only `pegs[0]` and `accruals[1]` left the batch copy loop effectively
        // untested: element 0's expected `pegKind` is `Pegged`, the ZERO value, so an implementation that ignored
        // storage and wrote a constant `PegKind.Pegged` into every slot satisfied the whole suite. That was verified
        // by running a mutant — `pegKinds[i] = PegKind.Pegged;` — against the 20-test version of this file that then
        // existed: 20/20 passed. That count describes a state this file is no longer in (it has grown, and the peg axis
        // is no longer stored at all), and is kept only as the reason these assertions are index-complete.
        assertEq(uint8(pegs[0]), uint8(PegKind.Pegged));
        assertEq(uint8(pegs[1]), uint8(PegKind.Floating));
        assertEq(uint8(accruals[0]), uint8(AccrualKind.None));
        assertEq(uint8(accruals[1]), uint8(AccrualKind.Appreciating));

        // Structural belt-and-braces: the batch must stay index-aligned with the single-asset read, which IS
        // well covered (all six matrix cells). This makes the batch path unable to diverge from it silently.
        for (uint256 i; i < assets.length; ++i) {
            (PegKind p, AccrualKind a) = registry.getAssetKind(assets[i]);
            assertEq(uint8(pegs[i]), uint8(p));
            assertEq(uint8(accruals[i]), uint8(a));
        }
    }

    /// @dev A batch is all-or-nothing, naming the FIRST gap. Zero-filling the gaps would hand the caller precisely
    ///      the silent default the single-asset read refuses — the batch surface must not be the soft way in.
    function test_getAssetKinds_batchFailsClosedOnAnyGap() public {
        _pegged(USDC);
        _set(USDC, AccrualKind.None);
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = WETH; // unclassified
        assets[2] = WSTETH; // also unclassified, but WETH is hit first

        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotClassified.selector, WETH));
        registry.getAssetKinds(assets);
    }

    function test_getAssetKinds_emptyBatchIsEmptyNotAnError() public view {
        (PegKind[] memory pegs, AccrualKind[] memory accruals) = registry.getAssetKinds(new address[](0));
        assertEq(pegs.length, 0);
        assertEq(accruals.length, 0);
    }

    function test_setAssetKinds_batchSets() public {
        _pegged(USDC); // derives Pegged; STETH deliberately left with no tolerance so it derives Floating
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = STETH;
        AccrualKind[] memory accruals = new AccrualKind[](2);
        accruals[0] = AccrualKind.None;
        accruals[1] = AccrualKind.Rebasing;

        vm.prank(manager);
        registry.setAssetKinds(assets, accruals);

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
        _assertKind(STETH, PegKind.Floating, AccrualKind.Rebasing);
    }

    /// @dev BOTH arms of `length != pegKinds.length || length != accrualKinds.length`. Testing only the `pegKinds`
    ///      arm left the `accrualKinds` arm dead: deleting it still passed the suite, while an over-long
    ///      `accrualKinds` would then be silently truncated to `assets.length` instead of rejected.
    /// @dev BOTH arms of the single length check, now that there is only one kind array. The long case matters as much
    ///      as the short one: without the check an over-long `accrualKinds` would be silently truncated to
    ///      `assets.length` rather than rejected.
    function test_setAssetKinds_revertsOnLengthMismatch() public {
        address[] memory assets = new address[](2);

        // accrualKinds too SHORT
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.KindArrayLengthMismatch.selector, 2, 1));
        registry.setAssetKinds(assets, new AccrualKind[](1));

        // accrualKinds too LONG
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.KindArrayLengthMismatch.selector, 2, 3));
        registry.setAssetKinds(assets, new AccrualKind[](3));
    }

    // ============================================================
    // Roles and arguments
    // ============================================================

    function test_setAssetKind_isManagerGated() public {
        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        registry.setAssetKind(USDC, AccrualKind.None);
    }

    /// @dev **Authority is DELEGATED to the NAV, and this is the test that proves it.** The registry holds no roles of
    ///      its own, so the only thing that makes a caller authorized is `NAV.hasRole(MANAGER, caller)`. Granting
    ///      MANAGER on the NAV *after* deployment must immediately authorize that caller here, with no action on the
    ///      registry — which is only possible if the gate reads through to the NAV on every call rather than caching.
    ///
    ///      This replaces an earlier pair of tests about `DEFAULT_ADMIN_ROLE` vs `MANAGER` on the registry itself. That
    ///      whole question is GONE: with no local roles there is no admin to self-grant, nothing to hand over to a Safe,
    ///      and no renouncement that can freeze the map.
    function test_authorityIsDelegatedToTheNav_notHeldLocally() public {
        address late = makeAddr("late-manager");

        vm.prank(late);
        vm.expectRevert(NotAuthorized.selector);
        registry.setAssetKind(USDC, AccrualKind.None);

        nav.grant(MANAGER, late); // nothing touches the registry

        _pegged(USDC);
        vm.prank(late);
        registry.setAssetKind(USDC, AccrualKind.None);
        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
    }

    /// @dev Pins that the NAV is the registry's only authority source. **This does NOT detect roles being re-added** —
    ///      an earlier docstring claimed it would stop compiling if `hasRole`/`grantRole` reappeared, which is untrue:
    ///      adding them would not affect this assertion at all. Treat it as documentation of the design, not a tripwire.
    function test_registryHasNoLocalRoleSurface() public view {
        assertEq(address(registry.NAV()), address(nav), "the NAV is the only authority source");
    }

    function test_batchSetAndClear_areManagerGated() public {
        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        registry.setAssetKinds(new address[](0), new AccrualKind[](0));

        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        registry.clearAssetKind(USDC);
    }

    /// @dev `address(0)` is the USD-quote sentinel, never a registered asset, so classifying it could only ever
    ///      record something nothing reads back.
    function test_zeroAddressRejected() public {
        vm.prank(manager);
        vm.expectRevert(InvalidArguments.selector);
        registry.setAssetKind(address(0), AccrualKind.None);
    }

    /// @dev A registry pointed at `address(0)` would derive its authority from nothing, so every write would revert and
    ///      the contract would be inert-but-deployed. Rejected in the constructor.
    function test_constructorRejectsZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new AssetKindRegistry(address(0));
    }

    // ============================================================
    // Lifecycle
    // ============================================================

    /// @dev Re-classification is allowed: a protocol can change how an asset accrues (a rebasing token gets a wrapped
    ///      variant, a peg is abandoned), and the registry must be able to follow without a redeploy.
    function test_reclassificationOverwritesAndEmits() public {
        _set(STETH, AccrualKind.None); // deliberately wrong to start
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AssetKindSet(STETH, AccrualKind.Rebasing);
        _set(STETH, AccrualKind.Rebasing);
        _assertKind(STETH, PegKind.Floating, AccrualKind.Rebasing);
    }

    /// @dev Clearing returns the asset to failing closed — the point of having a clear at all is that an unregistered
    ///      asset must not keep answering.
    function test_clearAssetKind_returnsToFailingClosed() public {
        _pegged(USDC);
        _set(USDC, AccrualKind.None);
        assertTrue(registry.isClassified(USDC));

        vm.expectEmit(true, false, false, false, address(registry));
        emit IAssetKindRegistry.AssetKindCleared(USDC);
        vm.prank(manager);
        registry.clearAssetKind(USDC);

        assertFalse(registry.isClassified(USDC));
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotClassified.selector, USDC));
        registry.getAssetKind(USDC);
    }

    function test_clearAssetKind_revertsIfNotClassified() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotClassified.selector, USDC));
        registry.clearAssetKind(USDC);
    }

    function _assertKind(address asset, PegKind expectedPeg, AccrualKind expectedAccrual) internal view {
        (PegKind p, AccrualKind a) = registry.getAssetKind(asset);
        assertEq(uint8(p), uint8(expectedPeg), "pegKind");
        assertEq(uint8(a), uint8(expectedAccrual), "accrualKind");
    }

    // ============================================================
    // Display labels — written at REGISTRATION, replaced by setAssetLabels
    //
    // The rule used to be "registration is the only chance", and these branches were written against it. They still
    // earn their place: each covers a failure mode prose cannot distinguish — a classifier that quietly accepts
    // labels, a re-registration that cannot replace them, an unregister that leaves them behind — and each is the
    // difference between a repair that works and one that silently does nothing. The setter's own arms are in the
    // `setAssetLabels` section below.
    //
    // Note what is NOT here any more, deliberately: the fill-a-blank tests, the identical-content no-op, and the
    // write-once guard's reverts. They covered behaviour that no longer exists. `setAssetKind`/`setAssetKinds` do not
    // take labels, so nothing can rewrite them and there is no guard left to exercise.
    // ============================================================

    /// @dev Registers `asset` through the facade with `labels`, the only path that can write them.
    function _register(address asset, AccrualKind a, string[] memory labels) internal {
        vm.prank(manager);
        registry.registerAsset(asset, address(0xFEED), IPrices.PriceType.Chainlink, 3600, a, labels);
    }

    /// @dev The happy path, asserted per INDEX rather than by membership. Order is significant — index 0 is the
    ///      protocol, later indices narrow to the product — so a list with the right elements in the wrong order is a
    ///      different description, not the same one.
    function test_labels_areStoredInSignificantOrderAtRegistration() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        _assertLabels(WSTETH, _labels("Lido", "LST"));
        _assertKind(WSTETH, PegKind.Floating, AccrualKind.Appreciating);
        assertEq(nav.registeredCount(), 1, "the NAV forward happened");
    }

    /// @dev **Registration is the ONLY writer, and this is the test that fails if anyone adds a second one.**
    ///      `setAssetKind` cannot carry labels — the compiler enforces the signature — so what is asserted here is the
    ///      consequence: re-classifying an unlabelled asset leaves it unlabelled, with no way to change that.
    function test_labels_setAssetKindCannotIntroduceThem() public {
        _set(AUSDC, AccrualKind.Rebasing); // classified, never registered through the facade
        assertEq(registry.getAssetLabels(AUSDC).length, 0, "classification does not label");

        _set(AUSDC, AccrualKind.Appreciating); // re-classify
        assertEq(registry.getAssetLabels(AUSDC).length, 0, "re-classification does not label either");
    }

    /// @dev An asset registered with no labels stays unlabelled *through registration alone* — {registerAsset} is
    ///      the only writer on this path, and an empty list is a silent no-op. {setAssetLabels} is what fills it in
    ///      afterwards; `test_setAssetLabels_fillsInLabelsOnAnAssetRegisteredWithout` is the other half of this pair.
    function test_labels_anAssetRegisteredWithoutThemStaysUnlabelled() public {
        _register(USDC, AccrualKind.None, _noLabels());
        assertEq(registry.getAssetLabels(USDC).length, 0);

        _set(USDC, AccrualKind.Rebasing);
        assertEq(registry.getAssetLabels(USDC).length, 0, "no path adds them afterwards");
    }

    /// @dev **The repair path, demonstrated end to end rather than asserted.** A wrong label is fixed by unregistering
    ///      and re-registering. That only works because {unregisterAsset} DROPS the labels — if they survived, the
    ///      re-registration would meet labels already set and, since `registerAsset` is the only writer, could never
    ///      replace them. The repair would be a silent no-op and the typo permanent.
    ///
    ///      This is also what makes a write-once guard unnecessary: `_labels` is empty whenever a facade registration
    ///      succeeds.
    function test_labels_repairIsUnregisterThenReRegister() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LTS")); // typo, as shipped
        _assertLabels(WSTETH, _labels("Lido", "LTS"));

        vm.prank(manager);
        registry.unregisterAsset(WSTETH);
        assertEq(registry.getAssetLabels(WSTETH).length, 0, "unregister drops the labels");

        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST")); // corrected
        _assertLabels(WSTETH, _labels("Lido", "LST"));
    }

    /// @dev **The orphaned-labels path, RUN rather than reasoned about — this is the test that justifies DELETING the
    ///      write-once check.** An argument for removing a guard has to be exercised for exactly the same reason a
    ///      guard does; otherwise the deletion rests on reasoning alone, which is the failure mode #241/#253 exist to
    ///      record.
    ///
    ///      `unregisterAsset` on the facade drops the labels, but the NAV can also be unregistered DIRECTLY by any
    ///      MANAGER — the facade is the intended path, not an enforced one. That route never touches this contract, so
    ///      the labels are left behind, orphaned. A later re-registration through the facade then meets a non-empty
    ///      `_labels[asset]`.
    ///
    ///      With a write-once check that call would revert (or, if written to skip instead, silently keep labels
    ///      describing the PREVIOUS registration). Neither is right: registration is what defines an asset's labels,
    ///      so the new registration's labels must win. Overwriting is the correct behaviour, and it is only correct
    ///      because the guard is gone.
    function test_labels_reRegistrationOverwritesLabelsOrphanedByADirectNavUnregister() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        _assertLabels(WSTETH, _labels("Lido", "LST"));

        // Bypass the facade entirely: unregister straight on the NAV, as a MANAGER may.
        vm.prank(manager);
        nav.unregisterAsset(WSTETH);

        // The registry never saw it, so the labels are still here — orphaned, describing an asset the NAV no longer
        // holds. This assertion is the precondition the whole argument depends on; without it the rest is vacuous.
        _assertLabels(WSTETH, _labels("Lido", "LST"));
        assertEq(nav.unregisteredCount(), 1, "precondition: the NAV-side unregister happened");

        // Re-register through the facade with DIFFERENT labels. No revert, and the new labels win.
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "Staking"));
        _assertLabels(WSTETH, _labels("Lido", "Staking"));
    }

    /// @dev The off-chain half of the on-chain change. An indexer that never sees a clear keeps serving labels for an
    ///      asset the NAV no longer knows about.
    function test_labels_unregisterEmitsAssetLabelsCleared() public {
        _register(USDC, AccrualKind.None, _labels("Circle", "Stablecoin"));

        vm.expectEmit(true, false, false, false);
        emit IAssetKindRegistry.AssetLabelsCleared(USDC);
        vm.prank(manager);
        registry.unregisterAsset(USDC);
    }

    /// @dev Guarded, so an asset that never had labels does not emit a misleading clear. Asserted by recording logs
    ///      rather than by `expectEmit`, which can only assert presence.
    function test_labels_unregisterDoesNotEmitWhenThereWereNone() public {
        _register(USDC, AccrualKind.None, _noLabels());

        vm.recordLogs();
        vm.prank(manager);
        registry.unregisterAsset(USDC);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IAssetKindRegistry.AssetLabelsCleared.selector, "no clear for an unlabelled asset"
            );
        }
    }

    /// @dev **`clearAssetKind` does NOT drop labels, and the asymmetry with {unregisterAsset} is the point.** Labels
    ///      are tied to REGISTRATION, not classification: this ends the classification while the asset stays
    ///      registered on the NAV, so its labels still describe a live asset. The two look interchangeable from
    ///      outside and are not.
    function test_labels_surviveClearAssetKindBecauseTheAssetIsStillRegistered() public {
        _register(USDC, AccrualKind.None, _labels("Circle", "Stablecoin"));

        vm.prank(manager);
        registry.clearAssetKind(USDC);

        assertFalse(registry.isClassified(USDC), "classification gone");
        _assertLabels(USDC, _labels("Circle", "Stablecoin"));
        assertEq(nav.unregisteredCount(), 0, "and the asset was never unregistered");
    }

    // ---- bounds, enforced in the SETTER (not only in preflight — #248 is the precedent) ----

    /// @dev ⚠️ `max` is read BEFORE `vm.prank`, and that ordering is load-bearing rather than stylistic. A prank
    ///      applies to the next EXTERNAL call, so reading `registry.MAX_ASSET_LABELS()` inside the `expectRevert`
    ///      argument consumes it — the call under test then runs unpranked and reverts `NotAuthorized()`, never
    ///      reaching the cap at all. Written that way first; it failed loudly only because the expected error was
    ///      specific. A bare `vm.expectRevert()` would have passed on the wrong revert and pinned nothing.
    function test_labels_revertOnTooMany() public {
        uint256 max = registry.MAX_ASSET_LABELS();
        string[] memory tooMany = new string[](max + 1);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = "x";
        }
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.TooManyAssetLabels.selector, USDC, max + 1, max));
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, tooMany);
    }

    /// @dev The boundary from the accepting side. A cap tested only from above passes even if it is off by one.
    function test_labels_acceptExactlyTheMaximumCount() public {
        uint256 max = registry.MAX_ASSET_LABELS();
        string[] memory atMax = new string[](max);
        for (uint256 i; i < max; ++i) {
            atMax[i] = "x";
        }
        _register(USDC, AccrualKind.None, atMax);
        assertEq(registry.getAssetLabels(USDC).length, max);
    }

    function test_labels_revertOnOverlongLabel() public {
        uint256 max = registry.MAX_ASSET_LABEL_BYTES();
        string[] memory tooLong = _labels(_repeat("a", max + 1));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetLabelTooLong.selector, USDC, 0, max + 1, max));
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, tooLong);
    }

    /// @dev The accepting side of the same boundary.
    function test_labels_acceptExactlyTheMaximumLength() public {
        uint256 max = registry.MAX_ASSET_LABEL_BYTES();
        string memory atMax = _repeat("a", max);
        _register(USDC, AccrualKind.None, _labels(atMax));
        _assertLabels(USDC, _labels(atMax));
    }

    /// @dev Length is in BYTES, not characters. A short multi-byte string can exceed a 32-byte bound, and the error
    ///      must report the byte count — otherwise an operator reading "33 > 32" about an 11-character label has no
    ///      idea what to shorten.
    function test_labels_lengthIsMeasuredInBytesNotCharacters() public {
        string memory euros = _repeat(unicode"€", 11); // 3 bytes each = 33 bytes, 11 characters
        assertEq(bytes(euros).length, 33, "precondition: 33 bytes");

        uint256 max = registry.MAX_ASSET_LABEL_BYTES();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetLabelTooLong.selector, USDC, 0, 33, max));
        registry.registerAsset(
            USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _labels(euros)
        );
    }

    /// @dev An empty LIST is legitimate; an empty ELEMENT is not. It renders as nothing while still occupying an
    ///      ordered slot, so it silently shifts the meaning of every label after it.
    function test_labels_revertOnEmptyElement() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAssetLabel.selector, USDC, 1));
        registry.registerAsset(
            USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _labels("Aave v3", "")
        );
    }

    /// @dev **A bad label aborts the whole registration**, not just the labelling. There is no `try`/`catch` on this
    ///      path, so the asset is not registered on the NAV, not classified, and has no labels — one failure, one
    ///      all-or-nothing outcome. That matters more here than elsewhere: a half-applied registration would leave an
    ///      asset registered and permanently unlabellable.
    function test_labels_aBadLabelAbortsTheWholeRegistration() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAssetLabel.selector, WSTETH, 0));
        registry.registerAsset(
            WSTETH, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.Appreciating, _labels("")
        );

        assertFalse(registry.isClassified(WSTETH), "not classified");
        assertEq(registry.getAssetLabels(WSTETH).length, 0, "no labels");
        assertEq(nav.registeredCount(), 0, "the NAV forward did not happen");

        // And the asset can still be registered properly afterwards — the failed attempt consumed nothing.
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        _assertLabels(WSTETH, _labels("Lido", "LST"));
    }

    // ---- the read surface ----

    /// @dev Never reverts, unlike {getAssetKind}. An unclassified, unknown, never-seen asset returns an empty list,
    ///      because "no labels" is the honest answer where "no classification" has no honest default.
    function test_getAssetLabels_returnsEmptyForAnUnknownAssetWithoutReverting() public view {
        assertEq(registry.getAssetLabels(address(0xDEAD)).length, 0);
    }

    function test_getAssetInfo_returnsAllThreeFields() public {
        _pegged(USDC);
        _register(USDC, AccrualKind.None, _labels("Circle", "Stablecoin"));

        (PegKind peg, AccrualKind accrual, string[] memory labels) = registry.getAssetInfo(USDC);
        assertEq(uint8(peg), uint8(PegKind.Pegged));
        assertEq(uint8(accrual), uint8(AccrualKind.None));
        assertEq(labels.length, 2);
        assertEq(labels[0], "Circle");
        assertEq(labels[1], "Stablecoin");
    }

    /// @dev The classification half still fails closed even though the label half has a legitimate empty answer. The
    ///      two axes differ here on purpose and this pins that they do.
    function test_getAssetInfo_revertsForAnUnclassifiedAsset() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotClassified.selector, WETH));
        registry.getAssetInfo(WETH);
    }

    /// @dev Labels for one asset must not be visible from another. Cheap to assert, and the failure it guards against
    ///      — a mapping keyed on something other than the asset — would be invisible in every single-asset test.
    function test_labels_areIndependentPerAsset() public {
        _register(USDC, AccrualKind.None, _labels("Circle", "Stablecoin"));
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));

        _assertLabels(USDC, _labels("Circle", "Stablecoin"));
        _assertLabels(WSTETH, _labels("Lido", "LST"));
    }

    /// @dev Writing labels is MANAGER-gated like every other mutator — the registry has no roles of its own and reads
    ///      authority off the NAV.
    function test_labels_writeIsManagerGated() public {
        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        registry.registerAsset(
            USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None, _labels("Circle")
        );
    }

    /// @dev Builds `n` copies of `unit`. Used for the byte-length boundaries so the numbers are derived from the
    ///      contract's own public constants rather than hard-coded alongside them.
    function _repeat(string memory unit, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; ++i) {
            out = string(abi.encodePacked(out, unit));
        }
    }

    // ============================================================
    // setAssetLabels — the repair path
    // ============================================================
    // Labels used to be write-once: a wrong one was fixed by unregistering and re-registering the asset. That repair
    // is far more destructive than it looks — `NAVCalculator.unregisterAsset` also drops every price feed, every
    // monitor feed and all of `_assetPricing` (divergence AND peg tolerance, the latter being what `PegKind` is
    // derived from), across up to five transactions on an EOA MANAGER with the asset absent from NAV throughout.
    // These arms cover the setter that replaces it, and BOTH of its refusals.

    /// @notice The point of the whole change: a wrong label is corrected in one call, wholesale, with the asset
    ///         never leaving the NAV.
    function test_setAssetLabels_replacesLabelsWithoutUnregistering() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LTS")); // typo'd label
        _assertLabels(WSTETH, _labels("Lido", "LTS"));

        vm.prank(manager);
        registry.setAssetLabels(WSTETH, _labels("Lido", "LST"));

        _assertLabels(WSTETH, _labels("Lido", "LST"));
        // The repair cost nothing else: no unregistration, and the classification is untouched.
        assertEq(nav.unregisteredCount(), 0, "the asset never left the NAV");
        _assertKind(WSTETH, PegKind.Floating, AccrualKind.Appreciating);
    }

    /// @notice Replacement is WHOLESALE, not a merge — a shorter list shortens the stored one.
    function test_setAssetLabels_replacementIsWholesaleNotAMerge() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        vm.prank(manager);
        registry.setAssetLabels(WSTETH, _labels("Lido"));
        _assertLabels(WSTETH, _labels("Lido"));
    }

    /// @notice Emits the same event registration emits, so an indexer needs no new handler.
    /// @notice Asserts the WHOLE event, not just its selector. Checking `topics[0]` alone passes for a wrong asset
    ///         or a stale payload, which is most of what could go wrong — and the event is the only signal an
    ///         off-chain indexer has that a label changed.
    function test_setAssetLabels_emitsAssetLabelsSet() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LTS"));
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AssetLabelsSet(WSTETH, _labels("Lido", "LST"));
        vm.prank(manager);
        registry.setAssetLabels(WSTETH, _labels("Lido", "LST"));
    }

    /// @notice An asset registered with NO labels can be given some later. This is the empty -> non-empty
    ///         transition, which registration itself can never exercise (an empty list is a silent no-op there).
    function test_setAssetLabels_fillsInLabelsOnAnAssetRegisteredWithout() public {
        _register(AUSDC, AccrualKind.Appreciating, _noLabels());
        assertEq(registry.getAssetLabels(AUSDC).length, 0, "starts unlabelled");
        vm.prank(manager);
        registry.setAssetLabels(AUSDC, _labels("Aave V3", "aUSDC"));
        _assertLabels(AUSDC, _labels("Aave V3", "aUSDC"));
    }

    /// @notice Shrinking from MAX-length, MAX-byte labels to one short label. Long strings (>= 32 bytes) use the
    ///         long-form storage layout with a separate data slot, so this is the case where a stale tail could
    ///         survive a wholesale replacement; the read-back proves it does not.
    function test_setAssetLabels_shrinkFromLongFormLeavesNoStaleTail() public {
        uint256 maxLabels = registry.MAX_ASSET_LABELS();
        uint256 maxBytes = registry.MAX_ASSET_LABEL_BYTES();
        string memory long = string(new bytes(maxBytes));
        string[] memory full = new string[](maxLabels);
        for (uint256 i; i < maxLabels; ++i) {
            full[i] = long;
        }
        _register(WSTETH, AccrualKind.Appreciating, full);
        assertEq(registry.getAssetLabels(WSTETH).length, maxLabels, "precondition: full long-form set");

        vm.prank(manager);
        registry.setAssetLabels(WSTETH, _labels("x"));

        string[] memory after_ = registry.getAssetLabels(WSTETH);
        assertEq(after_.length, 1, "shrunk to one");
        assertEq(after_[0], "x", "and it is the new value, not a truncated old one");

        // GROW BACK, and this is the half that actually proves it. `getAssetLabels` returns only `length`
        // elements, so residue past the new length is structurally invisible to the two assertions above — a
        // mutant that truncates the length while leaving the dropped elements' payload slots populated passes
        // them green. Re-growing to the full width re-reads those exact slots, so a stale tail surfaces as a
        // wrong string rather than staying hidden.
        string[] memory regrown = new string[](maxLabels);
        for (uint256 i; i < maxLabels; ++i) {
            regrown[i] = "n";
        }
        vm.prank(manager);
        registry.setAssetLabels(WSTETH, regrown);

        string[] memory back = registry.getAssetLabels(WSTETH);
        assertEq(back.length, maxLabels, "regrown to full width");
        for (uint256 i; i < maxLabels; ++i) {
            assertEq(back[i], "n", "every re-grown slot holds the new value, not long-form residue");
        }
    }

    /// @notice REFUSAL 1 — an asset the NAV does not hold. Labels are registration-scoped, and `unregisterAsset`
    ///         reverts for an asset the NAV does not hold, so labels written here could never be cleared by any path
    ///         on this contract. Explicit, not incidental.
    function test_RevertIf_setAssetLabels_assetNotRegisteredOnNav() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotRegisteredForLabels.selector, WSTETH));
        registry.setAssetLabels(WSTETH, _labels("Lido", "LST"));
        assertEq(registry.getAssetLabels(WSTETH).length, 0, "no orphan labels were written");
    }

    /// @notice And it stays refused after the asset is unregistered — the guard tracks the NAV's live state, it does
    ///         not merely check that a registration once happened.
    function test_RevertIf_setAssetLabels_afterUnregistration() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        vm.prank(manager);
        registry.unregisterAsset(WSTETH);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotRegisteredForLabels.selector, WSTETH));
        registry.setAssetLabels(WSTETH, _labels("Lido", "LST"));
    }

    /// @notice REFUSAL 2 — an empty array. `_setAssetLabels` treats empty as a silent no-op, which is right for
    ///         registration and wrong for a setter: a caller asking to clear would get silence and believe it worked.
    function test_RevertIf_setAssetLabels_emptyArray() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAssetLabelSet.selector, WSTETH));
        registry.setAssetLabels(WSTETH, _noLabels());
        _assertLabels(WSTETH, _labels("Lido", "LST"));
    }

    /// @notice The authority gate is the contract's only one — the same `NAV.hasRole(MANAGER, …)` every other write
    ///         uses. No new role, no local role.
    function test_RevertIf_setAssetLabels_notManager() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        registry.setAssetLabels(WSTETH, _labels("Lido", "LST"));
    }

    /// @notice The content bounds are inherited from `_setAssetLabels` unchanged: a set that could not be REGISTERED
    ///         cannot be SET either. Covers all three, so the setter cannot become a way around them.
    function test_RevertIf_setAssetLabels_violatesInheritedContentBounds() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        // Read the bounds BEFORE any prank: `vm.prank` applies to the next EXTERNAL call, and these getters are
        // external calls — reading them inline would consume the prank and the setter would arrive unpranked.
        uint256 maxLabels = registry.MAX_ASSET_LABELS();
        uint256 maxBytes = registry.MAX_ASSET_LABEL_BYTES();

        string[] memory tooMany = new string[](maxLabels + 1);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = "x";
        }
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetKindRegistry.TooManyAssetLabels.selector, WSTETH, maxLabels + 1, maxLabels)
        );
        registry.setAssetLabels(WSTETH, tooMany);

        string[] memory withEmpty = _labels("Lido", "");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.EmptyAssetLabel.selector, WSTETH, uint256(1)));
        registry.setAssetLabels(WSTETH, withEmpty);

        string[] memory tooLong = _labels(string(new bytes(maxBytes + 1)));
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetKindRegistry.AssetLabelTooLong.selector, WSTETH, uint256(0), maxBytes + 1, maxBytes
            )
        );
        registry.setAssetLabels(WSTETH, tooLong);

        _assertLabels(WSTETH, _labels("Lido", "LST")); // nothing partial was written by any of the three
    }

    /// @notice The setter does not disturb the other axis, and re-classification still does not disturb labels.
    function test_setAssetLabels_andClassificationRemainIndependent() public {
        _register(WSTETH, AccrualKind.Appreciating, _labels("Lido", "LST"));
        vm.prank(manager);
        registry.setAssetLabels(WSTETH, _labels("Lido", "Staked ETH"));
        _assertKind(WSTETH, PegKind.Floating, AccrualKind.Appreciating);

        vm.prank(manager);
        registry.setAssetKind(WSTETH, AccrualKind.Rebasing);
        _assertLabels(WSTETH, _labels("Lido", "Staked ETH"));
    }
}
