// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {Mock_OwnershipMetaAdapter} from "test/nav/MetaInstanceOwnership.invariant.t.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/price_oracles.sol";

/// @title Meta-instance ownership — unit coverage for every route to a second reporter
/// @notice One test per route, each in BOTH directions: the guard fires on the reported case, and does NOT
///         fire on the nearest legitimate input. Fixing a fail-open by introducing a fail-closed on valid
///         data is the own-goal this pairing exists to catch.
/// @dev Every route here was reachable before this PR and none was covered: the repo's only meta-instance
///      registration tests are fork tests, so the unit suite never called `addMetaInstances`,
///      `removeMetaInstances` or either inclusion toggle.
contract MetaInstanceOwnershipTest is SuperTest {
    Mock_OwnershipMetaAdapter internal metaA;
    Mock_OwnershipMetaAdapter internal metaB;
    ERC20DefaultBalanceAdapter internal def;

    function setUp() public {
        setupAll();
        metaA = new Mock_OwnershipMetaAdapter();
        metaB = new Mock_OwnershipMetaAdapter();
        def = ERC20DefaultBalanceAdapter(nav.erc20DefaultBalanceAdapter());
        vm.startPrank(navCalculatorManager);
        nav.addMetaBalanceAdapter(address(metaA), new bytes32[](0));
        nav.addMetaBalanceAdapter(address(metaB), new bytes32[](0));
        vm.stopPrank();
    }

    function _newToken() internal returns (Mock_ERC20 t) {
        t = new Mock_ERC20("T", 18);
    }

    function _register(Mock_ERC20 t) internal {
        Mock_CustomPriceFeed f = new Mock_CustomPriceFeed("T", address(t), 1e8, 8);
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(t), address(f), IPrices.PriceType.Custom, type(uint256).max);
    }

    function _one(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    function _coord(Mock_ERC20 t) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address(t))));
    }

    // -------------------------------------------------------------------------
    // Route 1: claim, then register the same token as an asset.
    // -------------------------------------------------------------------------

    /// @dev `registerAsset` armed the default adapter UNCONDITIONALLY. Claiming does not require the token to
    ///      be a registered asset, so claim-then-register ended with a meta adapter and the default adapter
    ///      both reporting it — and no health flag, because both legs are well-formed.
    function test_claimThenRegisterAsset_reverts() public {
        Mock_ERC20 t = _newToken();
        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));

        Mock_CustomPriceFeed f = new Mock_CustomPriceFeed("T", address(t), 1e8, 8);
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(IBalances.MetaInstanceClaimedByAnotherAdapter.selector, _coord(t), address(metaA))
        );
        nav.registerAsset(address(t), address(f), IPrices.PriceType.Custom, type(uint256).max);
    }

    /// @dev The other direction: an UNCLAIMED token must still register and still be armed on the default
    ///      adapter. A guard that refused this would silently stop every ordinary asset registration.
    function test_registerAsset_unclaimed_stillArmsDefaultAdapter() public {
        Mock_ERC20 t = _newToken();
        _register(t);
        assertTrue(nav.isAssetRegistered(address(t)), "asset should be registered");
        assertTrue(def.isSupportedByDefault(address(t)), "unclaimed asset must still be armed by default");
    }

    // -------------------------------------------------------------------------
    // Route 2: include an already-governed asset on the default adapter.
    // -------------------------------------------------------------------------

    function test_includeClaimedAsset_reverts() public {
        Mock_ERC20 t = _newToken();
        _register(t);
        vm.prank(navCalculatorManager);
        nav.excludeAssetFromDefaultAdapter(address(t));
        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));

        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(IBalances.MetaInstanceClaimedByAnotherAdapter.selector, _coord(t), address(metaA))
        );
        nav.includeAssetInDefaultAdapter(address(t));
    }

    function test_includeUnclaimedAsset_succeeds() public {
        Mock_ERC20 t = _newToken();
        _register(t);
        vm.prank(navCalculatorManager);
        nav.excludeAssetFromDefaultAdapter(address(t));
        assertFalse(def.isSupportedByDefault(address(t)), "precondition: excluded");

        vm.prank(navCalculatorManager);
        nav.includeAssetInDefaultAdapter(address(t));
        assertTrue(def.isSupportedByDefault(address(t)), "unclaimed asset must be includable");
    }

    // -------------------------------------------------------------------------
    // Route 3: claiming disarms, releasing re-arms — and they must be symmetric.
    // -------------------------------------------------------------------------

    /// @dev Claiming a registered asset must DISARM the default adapter, or the two report it together.
    function test_claimDisarmsDefaultAdapter() public {
        Mock_ERC20 t = _newToken();
        _register(t);
        assertTrue(def.isSupportedByDefault(address(t)), "precondition: armed");

        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        assertFalse(def.isSupportedByDefault(address(t)), "claim must disarm the default adapter");
    }

    /// @dev Releasing must re-arm, so a released registered asset is reported by SOMEBODY rather than nobody.
    function test_releaseRearmsDefaultAdapter() public {
        Mock_ERC20 t = _newToken();
        _register(t);
        vm.startPrank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        nav.removeMetaInstances(address(metaA), _one(_coord(t)));
        vm.stopPrank();
        assertTrue(def.isSupportedByDefault(address(t)), "release must re-arm the default adapter");
    }

    /// @dev THE defect-6 shape. `SwapMetaAdapter` does release-then-re-add: `removeMetaInstances` on the old
    ///      adapter, `addMetaInstances` on the new one. With release re-arming the default adapter but the
    ///      re-add failing to disarm it, the swap ends with TWO reporters — an over-report produced by an
    ///      ordinary, documented reconfiguration.
    function test_releaseThenReAdd_leavesExactlyOneReporter() public {
        Mock_ERC20 t = _newToken();
        _register(t);
        vm.startPrank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        nav.removeMetaInstances(address(metaA), _one(_coord(t)));
        nav.addMetaInstances(address(metaB), _one(_coord(t)));
        vm.stopPrank();

        assertFalse(def.isSupportedByDefault(address(t)), "re-add must disarm the default adapter again");
        assertEq(nav.getMetaInstances(address(metaA)).length, 0, "old adapter must not keep the coordinate");
        assertEq(nav.getMetaInstances(address(metaB)).length, 1, "new adapter must hold it");
    }

    // -------------------------------------------------------------------------
    // Route 4: two adapters claiming one coordinate.
    // -------------------------------------------------------------------------

    function test_crossAdapterClaim_revertsNamingTheHolder() public {
        Mock_ERC20 t = _newToken();
        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));

        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(IBalances.MetaInstanceClaimedByAnotherAdapter.selector, _coord(t), address(metaA))
        );
        nav.addMetaInstances(address(metaB), _one(_coord(t)));
    }

    /// @dev "Already yours" and "already someone else's" stay distinguishable — they are different operator
    ///      problems, and collapsing them to one selector was rejected for that reason.
    function test_sameAdapterDuplicate_revertsDuplicate() public {
        Mock_ERC20 t = _newToken();
        vm.startPrank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        vm.expectRevert(IBalances.DuplicateMetaInstance.selector);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        vm.stopPrank();
    }

    /// @dev A repeat WITHIN one batch is the same over-report — `MetaBalanceAdapter` does not dedupe on read.
    function test_inBatchDuplicate_reverts() public {
        Mock_ERC20 t = _newToken();
        bytes32[] memory two = new bytes32[](2);
        two[0] = _coord(t);
        two[1] = _coord(t);
        vm.prank(navCalculatorManager);
        vm.expectRevert(IBalances.DuplicateMetaInstance.selector);
        nav.addMetaInstances(address(metaA), two);
    }

    /// @dev A coordinate released by one adapter must be freely claimable by another — the guard must not
    ///      turn into a permanent lock, which would make every adapter swap impossible.
    function test_releasedCoordinate_isClaimableByAnother() public {
        Mock_ERC20 t = _newToken();
        vm.startPrank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        nav.removeMetaInstances(address(metaA), _one(_coord(t)));
        nav.addMetaInstances(address(metaB), _one(_coord(t)));
        vm.stopPrank();
        assertEq(nav.getMetaInstances(address(metaB)).length, 1, "released coordinate must be re-claimable");
    }

    // -------------------------------------------------------------------------
    // Route 5: retirement and re-registration (issue #335).
    // -------------------------------------------------------------------------

    /// @dev Retirement hands every coordinate back. Without this the set lies dormant and a later
    ///      re-registration revives it alongside the live adapter.
    function test_retirementReleasesAndRearms() public {
        Mock_ERC20 t = _newToken();
        _register(t);
        address[] memory one = new address[](1);
        one[0] = address(metaA);
        vm.startPrank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        nav.removeBalanceAdapters(one);
        vm.stopPrank();

        assertEq(nav.getMetaInstances(address(metaA)).length, 0, "retirement must clear the set");
        assertTrue(def.isSupportedByDefault(address(t)), "retirement must re-arm the default adapter");
    }

    /// @dev Re-registration WIPES. The guard this replaced scanned the incoming batch, so an EMPTY list
    ///      skipped it entirely — and an empty list is exactly how residue revives.
    function test_reregistrationWithEmptyListLeavesEmptySet() public {
        Mock_ERC20 t = _newToken();
        address[] memory one = new address[](1);
        one[0] = address(metaA);
        vm.startPrank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        nav.removeBalanceAdapters(one);
        nav.addMetaBalanceAdapter(address(metaA), new bytes32[](0));
        vm.stopPrank();
        assertEq(nav.getMetaInstances(address(metaA)).length, 0, "re-registration must not revive coordinates");
    }

    /// @dev And the other direction: re-registration WITH a list still seeds exactly that list.
    function test_reregistrationWithListSeedsIt() public {
        Mock_ERC20 t = _newToken();
        address[] memory one = new address[](1);
        one[0] = address(metaA);
        vm.startPrank(navCalculatorManager);
        nav.removeBalanceAdapters(one);
        nav.addMetaBalanceAdapter(address(metaA), _one(_coord(t)));
        vm.stopPrank();
        bytes32[] memory got = nav.getMetaInstances(address(metaA));
        assertEq(got.length, 1, "re-registration must seed the supplied list");
        assertEq(got[0], _coord(t), "and seed exactly it");
    }
}
