// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {AssetKindRegistry} from "src/nav/AssetKindRegistry.sol";
import {IAssetKindRegistry} from "src/nav/IAssetKindRegistry.sol";
import {PegKind, AccrualKind} from "src/utils/AssetKind.sol";

/// @title NAVCalculatorAssetKindTest
/// @notice Covers the NAV's asset-kind read surface: the MANAGER-gated setter, and `getAssetKind` forwarding to the
///         registry so a consumer needs ONE entry point rather than two addresses.
/// @dev **Every failure branch this feature adds is reached by a test here, deliberately.** The rule comes from #241
///      and #253 the expensive way: three guards were written into `08_DeployAssetKindRegistry` on reasoning alone,
///      never executing their failure paths, and all three turned out to be defective — one checked local state and
///      called it an on-chain check, one prescribed a recovery for a cause it could not distinguish, one was
///      near-tautological. A guard whose failure branch has never run is indistinguishable from a guard that cannot
///      run. So: the zero-address revert is reached, the unset-registry read is reached, and the registry's own
///      `AssetNotClassified` is asserted to PROPAGATE rather than being swallowed.
contract NAVCalculatorAssetKindTest is SuperTest {
    AssetKindRegistry internal registry;

    function setUp() public {
        setupAll();
        // The registry derives ALL of its authority from the NAV, so it is constructed against this NAV and then
        // granted MANAGER on it — the same wiring `08_DeployAssetKindRegistry` performs.
        registry = new AssetKindRegistry(address(nav));
        vm.prank(navCalculatorAdmin);
        nav.grantRole(MANAGER, address(registry));
    }

    // ============================================================
    // setAssetKindRegistry
    // ============================================================

    function test_setAssetKindRegistry_storesAndIsReadable() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));
        assertEq(address(nav.assetKindRegistry()), address(registry));
    }

    function test_setAssetKindRegistry_isManagerGated() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotAuthorized.selector);
        nav.setAssetKindRegistry(address(registry));
    }

    /// @dev **The zero-address branch, REACHED rather than reasoned about.** Clearing the registry by accident would
    ///      present as a registry outage — every `getAssetKind` reverting — rather than as the config change it is, so
    ///      it is rejected at the setter where the cause is still visible.
    function test_setAssetKindRegistry_rejectsZeroAddress() public {
        vm.prank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.setAssetKindRegistry(address(0));
    }

    /// @dev Re-settable on purpose: the registry is a plain contract, so replacing it is a redeploy plus this call.
    function test_setAssetKindRegistry_isResettable() public {
        AssetKindRegistry second = new AssetKindRegistry(address(nav));
        vm.startPrank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));
        nav.setAssetKindRegistry(address(second));
        vm.stopPrank();
        assertEq(address(nav.assetKindRegistry()), address(second));
    }

    // ============================================================
    // getAssetKind — the single entry point
    // ============================================================

    function test_getAssetKind_forwardsToTheRegistry() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        vm.prank(navCalculatorManager);
        registry.setAssetKind(address(weth), AccrualKind.Appreciating);

        (PegKind peg, AccrualKind accrual) = nav.getAssetKind(address(weth));
        // WETH carries no `pegToleranceBps` here, so the derived axis is Floating — this also proves the NAV is
        // returning the registry's DERIVED value and not a stored default of its own.
        assertEq(uint8(peg), uint8(PegKind.Floating));
        assertEq(uint8(accrual), uint8(AccrualKind.Appreciating));
    }

    /// @dev **The window between deploying the new implementation and calling the setter, stated as an assertion
    ///      rather than left to inference.** `assetKindRegistry` is zero until set, so this call reaches
    ///      `address(0)`. A caller in that window gets a REVERT.
    ///
    ///      That is the outcome to want. The alternative — returning `(Pegged, None)` because both enums are the zero
    ///      value — would be a confident wrong answer: `Pegged + None` is USDC's real classification, so it is
    ///      indistinguishable from a configured reply, and every consumer would believe an unconfigured NAV had told
    ///      them something. This test exists to fail if anyone ever "helpfully" makes the getter tolerant.
    function test_getAssetKind_revertsWhenRegistryUnset() public {
        assertEq(address(nav.assetKindRegistry()), address(0), "precondition: registry unset");
        vm.expectRevert();
        nav.getAssetKind(address(weth));
    }

    /// @dev The registry's fail-closed read must survive the extra hop. `AssetNotClassified` PROPAGATES with its asset
    ///      argument intact — the NAV does not catch it and does not substitute a default. A consumer can therefore
    ///      distinguish "not classified" from every other failure, which is the whole point of the registry reverting
    ///      instead of zero-filling.
    function test_getAssetKind_propagatesAssetNotClassified() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        vm.expectRevert(abi.encodeWithSelector(IAssetKindRegistry.AssetNotClassified.selector, address(weth)));
        nav.getAssetKind(address(weth));
    }

    /// @dev The registry is reachable directly as well as through the NAV, and both must agree. The NAV is a
    ///      convenience entry point, not a second source of truth.
    function test_getAssetKind_agreesWithReadingTheRegistryDirectly() public {
        vm.prank(navCalculatorManager);
        nav.setAssetKindRegistry(address(registry));

        vm.prank(navCalculatorManager);
        registry.setAssetKind(address(usdc), AccrualKind.None);

        (PegKind navPeg, AccrualKind navAccrual) = nav.getAssetKind(address(usdc));
        (PegKind regPeg, AccrualKind regAccrual) = registry.getAssetKind(address(usdc));
        assertEq(uint8(navPeg), uint8(regPeg));
        assertEq(uint8(navAccrual), uint8(regAccrual));
    }
}
