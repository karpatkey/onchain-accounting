// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";
import {InvalidArguments} from "src/errors.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";

/// @title AssetKindRegistryTest
/// @notice Unit tests for the two-axis asset-kind registry: all six combinations, the fail-closed read, role
///         separation, and the batch surface's all-or-nothing contract.
contract AssetKindRegistryTest is Test {
    AssetKindRegistry internal registry;

    address internal admin = makeAddr("admin");
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
        registry = new AssetKindRegistry(admin, manager);
    }

    function _set(address asset, PegKind p, AccrualKind a) internal {
        vm.prank(manager);
        registry.setAssetKind(asset, p, a);
    }

    // ============================================================
    // The six combinations
    // ============================================================

    /// @dev Every cell of the 2x3 matrix round-trips. This is the test that justifies two axes rather than one enum:
    ///      if a single enum could express these, the combinations would not be independent.
    function test_allSixCombinationsRoundTrip() public {
        _set(USDC, PegKind.Pegged, AccrualKind.None);
        _set(AUSDC, PegKind.Pegged, AccrualKind.Rebasing);
        _set(SDAI, PegKind.Pegged, AccrualKind.Appreciating);
        _set(WETH, PegKind.Floating, AccrualKind.None);
        _set(STETH, PegKind.Floating, AccrualKind.Rebasing);
        _set(WSTETH, PegKind.Floating, AccrualKind.Appreciating);

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
        _assertKind(AUSDC, PegKind.Pegged, AccrualKind.Rebasing);
        _assertKind(SDAI, PegKind.Pegged, AccrualKind.Appreciating);
        _assertKind(WETH, PegKind.Floating, AccrualKind.None);
        _assertKind(STETH, PegKind.Floating, AccrualKind.Rebasing);
        _assertKind(WSTETH, PegKind.Floating, AccrualKind.Appreciating);
    }

    /// @dev `Pegged + Rebasing` has NO registered member today — no aToken is currently registered — so it would
    ///      otherwise be an untested branch reached first by a live registration. Pinned deliberately: the first
    ///      aToken registration is a plausible near-term event, and it must not be the moment this cell is first
    ///      exercised.
    function test_peggedRebasing_theCellWithNoMemberToday() public {
        _set(AUSDC, PegKind.Pegged, AccrualKind.Rebasing);
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
        _set(WSTETH, PegKind.Floating, AccrualKind.Appreciating);
        (PegKind p,) = registry.getAssetKind(WSTETH);
        assertEq(uint8(p), uint8(PegKind.Floating), "wstETH is Floating: Pegged means pegged to the QUOTE asset");
    }

    /// @dev stETH and wstETH are the same underlying exposure and differ ONLY on the accrual axis. If a future change
    ///      ever collapses the two axes, this is the assertion that breaks.
    function test_stETHAndWstETHDifferOnlyOnAccrual() public {
        _set(STETH, PegKind.Floating, AccrualKind.Rebasing);
        _set(WSTETH, PegKind.Floating, AccrualKind.Appreciating);
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
        _set(USDC, PegKind.Pegged, AccrualKind.None); // both enums are 0
        assertTrue(registry.isClassified(USDC), "an all-zero classification still reads as classified");
        (PegKind p, AccrualKind a) = registry.getAssetKind(USDC);
        assertEq(uint8(p), 0);
        assertEq(uint8(a), 0);
    }

    function test_isClassified_isTheNonRevertingProbe() public {
        assertFalse(registry.isClassified(WETH));
        _set(WETH, PegKind.Floating, AccrualKind.None);
        assertTrue(registry.isClassified(WETH));
    }

    // ============================================================
    // Batch surface
    // ============================================================

    function test_getAssetKinds_batchRoundTrips() public {
        _set(USDC, PegKind.Pegged, AccrualKind.None);
        _set(WSTETH, PegKind.Floating, AccrualKind.Appreciating);

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
        _set(USDC, PegKind.Pegged, AccrualKind.None);
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
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = STETH;
        PegKind[] memory pegs = new PegKind[](2);
        pegs[0] = PegKind.Pegged;
        pegs[1] = PegKind.Floating;
        AccrualKind[] memory accruals = new AccrualKind[](2);
        accruals[0] = AccrualKind.None;
        accruals[1] = AccrualKind.Rebasing;

        vm.prank(manager);
        registry.setAssetKinds(assets, pegs, accruals);

        _assertKind(USDC, PegKind.Pegged, AccrualKind.None);
        _assertKind(STETH, PegKind.Floating, AccrualKind.Rebasing);
    }

    /// @dev BOTH arms of `length != pegKinds.length || length != accrualKinds.length`. Testing only the `pegKinds`
    ///      arm left the `accrualKinds` arm dead: deleting it still passed the suite, while an over-long
    ///      `accrualKinds` would then be silently truncated to `assets.length` instead of rejected.
    function test_setAssetKinds_revertsOnLengthMismatch() public {
        address[] memory assets = new address[](2);

        // pegKinds too short
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.KindArrayLengthMismatch.selector, 2, 1, 2));
        registry.setAssetKinds(assets, new PegKind[](1), new AccrualKind[](2));

        // accrualKinds too short
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.KindArrayLengthMismatch.selector, 2, 2, 1));
        registry.setAssetKinds(assets, new PegKind[](2), new AccrualKind[](1));

        // accrualKinds too LONG — the truncation case, not just the short one
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.KindArrayLengthMismatch.selector, 2, 2, 3));
        registry.setAssetKinds(assets, new PegKind[](2), new AccrualKind[](3));
    }

    // ============================================================
    // Roles and arguments
    // ============================================================

    function test_setAssetKind_isManagerGated() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER)
        );
        registry.setAssetKind(USDC, PegKind.Pegged, AccrualKind.None);
    }

    /// @dev The admin holding ONLY `DEFAULT_ADMIN_ROLE` is not authorized on `setAssetKind` — the role check itself.
    ///      That is all this proves, and the name says so.
    ///
    ///      **It is NOT proof of separation of duties, and must never be cited as such.** See
    ///      {test_adminCanSelfGrantManager_soSeparationIsProceduralNotEnforced} directly below for why: the admin can
    ///      grant itself `MANAGER` and then classify. This test only shows it cannot do so *without* taking that step.
    function test_adminRoleAloneIsNotAuthorizedToClassify() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, MANAGER)
        );
        registry.setAssetKind(USDC, PegKind.Pegged, AccrualKind.None);
    }

    /// @dev Pins the ACTUAL privilege boundary, so no reader mistakes the test above for an enforced separation.
    ///      `AssetKindRegistry` uses stock OZ `AccessControl` with no `_setRoleAdmin` override, so `MANAGER`'s role
    ///      admin is `DEFAULT_ADMIN_ROLE`: the admin self-grants and classifies in two calls, one block, no timelock
    ///      and no second party. The separation is therefore PROCEDURAL, not ENFORCED.
    ///
    ///      This is not hypothetical on the live deployment. `script/config/chains/1.json` sets `admin` and `manager`
    ///      to the SAME deployer EOA, and `08_DeployAssetKindRegistry` passes `(chain.admin, msg.sender)` — so both
    ///      roles land on one key and even the procedural separation does not exist until the roles are split.
    ///
    ///      If this test ever FAILS, role administration has been tightened (an override, a timelock, a renounce),
    ///      which is a deliberate change — update the docstrings that describe the boundary rather than this test.
    function test_adminCanSelfGrantManager_soSeparationIsProceduralNotEnforced() public {
        assertFalse(registry.hasRole(MANAGER, admin));

        vm.prank(admin);
        registry.grantRole(MANAGER, admin);
        assertTrue(registry.hasRole(MANAGER, admin));

        vm.prank(admin);
        registry.setAssetKind(USDC, PegKind.Floating, AccrualKind.Appreciating);

        // Classified by the admin alone, with no involvement from the configured manager.
        _assertKind(USDC, PegKind.Floating, AccrualKind.Appreciating);
    }

    function test_batchSetAndClear_areManagerGated() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER)
        );
        registry.setAssetKinds(new address[](0), new PegKind[](0), new AccrualKind[](0));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, MANAGER)
        );
        registry.clearAssetKind(USDC);
    }

    /// @dev `address(0)` is the USD-quote sentinel, never a registered asset, so classifying it could only ever
    ///      record something nothing reads back.
    function test_zeroAddressRejected() public {
        vm.prank(manager);
        vm.expectRevert(InvalidArguments.selector);
        registry.setAssetKind(address(0), PegKind.Pegged, AccrualKind.None);
    }

    function test_constructorRejectsZeroRoleHolders() public {
        vm.expectRevert(InvalidArguments.selector);
        new AssetKindRegistry(address(0), manager);
        vm.expectRevert(InvalidArguments.selector);
        new AssetKindRegistry(admin, address(0));
    }

    // ============================================================
    // Lifecycle
    // ============================================================

    /// @dev Re-classification is allowed: a protocol can change how an asset accrues (a rebasing token gets a wrapped
    ///      variant, a peg is abandoned), and the registry must be able to follow without a redeploy.
    function test_reclassificationOverwritesAndEmits() public {
        _set(STETH, PegKind.Floating, AccrualKind.None); // deliberately wrong to start
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetKindRegistry.AssetKindSet(STETH, PegKind.Floating, AccrualKind.Rebasing);
        _set(STETH, PegKind.Floating, AccrualKind.Rebasing);
        _assertKind(STETH, PegKind.Floating, AccrualKind.Rebasing);
    }

    /// @dev Clearing returns the asset to failing closed — the point of having a clear at all is that an unregistered
    ///      asset must not keep answering.
    function test_clearAssetKind_returnsToFailingClosed() public {
        _set(USDC, PegKind.Pegged, AccrualKind.None);
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
