// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";
import {InvalidArguments, NotAuthorized} from "src/errors.sol";
import {IPrices} from "src/prices/IPrices.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @notice Minimal `NAVCalculator` stand-in. The registry needs exactly two things from the NAV — `hasRole` (its ONLY
///         authority source) and the register/unregister entry points it forwards to — so the mock provides those and
///         records the forwarded calls, which is what lets a test prove the forward actually happened.
contract MockNav {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    address[] public registered;
    address[] public unregistered;
    bool public revertOnRegister;
    bool public revertOnUnregister;

    error MockNavRegisterReverted();
    error MockNavUnregisterReverted();

    function grant(bytes32 role, address who) external {
        _roles[role][who] = true;
    }

    function hasRole(bytes32 role, address who) external view returns (bool) {
        return _roles[role][who];
    }

    /// @dev The derivation's input. `AssetKindRegistry` reads `pegToleranceBps` through `IPrices` to compute `PegKind`,
    ///      so a test that never varies this never exercises the derivation at all.
    mapping(address => IPrices.AssetPricing) private _pricing;

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

    function registerAsset(address asset, address, IPrices.PriceType, uint256) external {
        if (revertOnRegister) revert MockNavRegisterReverted();
        registered.push(asset);
    }

    function unregisterAsset(address asset) external {
        if (revertOnUnregister) revert MockNavUnregisterReverted();
        unregistered.push(asset);
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
    }

    /// @dev Stores the accrual axis. The peg axis is NOT settable — use {_pegged} to move the NAV tolerance the
    ///      derivation reads.
    function _set(address asset, AccrualKind a) internal {
        vm.prank(manager);
        registry.setAssetKind(asset, a);
    }

    /// @dev Makes `asset` derive as `Pegged` by giving it a non-zero NAV peg tolerance (the real switch).
    function _pegged(address asset) internal {
        nav.setPegTolerance(asset, 100);
    }

    // ============================================================
    // The atomic facade — register+classify as ONE call
    // ============================================================

    /// @dev The whole point of the contract: one call registers on the NAV AND classifies, so a registered asset is
    ///      always classified. Asserts BOTH halves landed, and that the NAV received the forward (not just that the
    ///      kind was stored) — otherwise a facade that silently skipped the forward would pass.
    function test_registerAsset_classifiesAndForwardsInOneCall() public {
        _pegged(USDC); // the NAV tolerance is what makes it derive as Pegged
        vm.prank(manager);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None);

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
        assertEq(nav.registeredCount(), 1, "the NAV must actually have been called");
        assertEq(nav.registered(0), USDC);
    }

    /// @dev Symmetry, as required: removal works the same way. Clears the kind AND forwards the unregister.
    function test_unregisterAsset_clearsAndForwardsInOneCall() public {
        vm.prank(manager);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None);

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
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None);

        assertFalse(registry.isClassified(USDC), "a reverted NAV call must leave NO classification behind");
        assertEq(nav.registeredCount(), 0);
    }

    /// @dev The mirror: a failing unregister must not leave the asset stripped of its kind.
    function test_unregisterAsset_isAtomic_navRevertKeepsTheKind() public {
        _pegged(USDC);
        vm.prank(manager);
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None);
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
        registry.registerAsset(USDC, address(0xFEED), IPrices.PriceType.Chainlink, 3600, AccrualKind.None);

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
        address unreachableCellProbe = makeAddr("pegged-appreciating-has-no-real-member");

        _pegged(USDC);
        _set(USDC, AccrualKind.None);
        _pegged(AUSDC);
        _set(AUSDC, AccrualKind.Rebasing);
        _pegged(unreachableCellProbe);
        _set(unreachableCellProbe, AccrualKind.Appreciating);
        _set(WETH, AccrualKind.None);
        _set(STETH, AccrualKind.Rebasing);
        _set(WSTETH, AccrualKind.Appreciating);

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
        _assertKind(AUSDC, PegKind.Pegged, AccrualKind.Rebasing);
        _assertKind(unreachableCellProbe, PegKind.Pegged, AccrualKind.Appreciating);
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
    ///      value it asserts is written by the test two lines earlier, and nothing in THIS repo classifies sDAI — the
    ///      classification data lives in the sibling config PR. So no mutation of the production code fails this test
    ///      that `test_allSixCombinationsRoundTrip` would not already catch. It is kept for the same reason
    ///      {test_wstETHIsFloatingNotPegged} is: it records the intended classification next to the reasoning, where a
    ///      future author will look.
    ///
    ///      The ONLY machine check of the ruling is `08_DeployAssetKindRegistry`'s `Pegged` ⇔ `pegToleranceBps > 0`
    ///      assertion, which runs against the real config at deploy time and aborts on disagreement.
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
    ///      zero-heartbeat-margin staleness condition reaches pegged feeds and not floating ones, because a floating
    ///      asset's divergence threshold fires long before its heartbeat lapses.
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
        // by running a mutant — `pegKinds[i] = PegKind.Pegged;` — against this file: 20/20 passed.
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

    /// @dev The registry exposes no role surface at all. If this ever stops compiling because `hasRole`/`grantRole`
    ///      exist again, the delegated-authority design has been reverted and the docstrings describing it are wrong.
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
}
