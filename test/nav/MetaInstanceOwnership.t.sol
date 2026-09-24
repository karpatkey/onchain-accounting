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

    /// @dev `registerAsset` used to arm the default adapter UNCONDITIONALLY, so claim-then-register ended
    ///      with two reporters. The gate now SKIPS the inclusion instead of reverting the registration, and
    ///      that distinction was itself a review finding: reverting made a claimed token permanently
    ///      un-re-registerable, because `unregisterAsset` does not release the claim — so the documented
    ///      unregister-then-register repair for a wrong feed died on its second half, and `RegisterAssets`
    ///      planned it for any unregistered asset with no claimant check, reverting a whole chain's Safe
    ///      MultiSend at execution after the batch file had been written.
    ///
    ///      So the asserted behaviour is: registration SUCCEEDS, and the default adapter is NOT armed — which
    ///      is the correct end state anyway, since the claiming meta adapter reports the token. An explicit
    ///      `includeAssetInDefaultAdapter` still reverts; that is the operator asking for a second reporter,
    ///      and it is covered by {test_includeClaimedAsset_reverts}.
    ///
    ///      This test previously asserted the revert, and failed when the behaviour changed — which is the
    ///      test doing its job rather than a regression.
    function test_claimThenRegisterAsset_registersWithoutArmingDefault() public {
        Mock_ERC20 t = _newToken();
        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));

        Mock_CustomPriceFeed f = new Mock_CustomPriceFeed("T", address(t), 1e8, 8);
        vm.prank(navCalculatorManager);
        nav.registerAsset(address(t), address(f), IPrices.PriceType.Custom, type(uint256).max);

        assertTrue(nav.isAssetRegistered(address(t)), "a claimed token must still be registerable");
        assertFalse(
            def.isSupportedByDefault(address(t)), "registering a claimed token must NOT arm the default adapter"
        );
        assertEq(nav.getMetaInstances(address(metaA)).length, 1, "the claim must be untouched");
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
    // Route 4b: the UN-BACKFILLED proxy — the claim map is empty while the set is full.
    // -------------------------------------------------------------------------

    /// @dev `_claimant` is new storage, so on a proxy upgraded past it the map is EMPTY while `_metaInstances`
    ///      is already full. Deciding a duplicate on the map ALONE therefore let an adapter re-add a coordinate
    ///      it already holds: a second copy is pushed, `MetaBalanceAdapter` iterates the raw array without
    ///      de-duplicating, and the leg is emitted twice — an immediate double-count, in the exact window the
    ///      backfill script is otherwise the only guard against.
    ///
    ///      Simulated by zeroing the claim slot for a coordinate the adapter genuinely holds, which is bit-for-bit
    ///      the live post-upgrade state. Fails without the own-set scan in `_claim`.
    function test_unbackfilledProxy_cannotReAddACoordinateItAlreadyHolds() public {
        Mock_ERC20 t = _newToken();
        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        assertEq(nav.getMetaInstances(address(metaA)).length, 1, "precondition: held once");

        // Erase the claim, leaving the instance set intact: the un-backfilled shape.
        bytes32 slot = keccak256(abi.encode(_coord(t), uint256(109)));
        vm.store(address(nav), slot, bytes32(0));
        assertEq(vm.load(address(nav), slot), bytes32(0), "precondition: claim erased");

        vm.prank(navCalculatorManager);
        vm.expectRevert(IBalances.DuplicateMetaInstance.selector);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));

        assertEq(nav.getMetaInstances(address(metaA)).length, 1, "the set must not have gained a second copy");
    }

    /// @dev Release must not delete a claim another adapter owns. Before the ownership gate, `_release` ran
    ///      unconditionally, so releasing one adapter's set could delete the claim of a DIFFERENT adapter that
    ///      still held the coordinate and was still reporting it — and re-arm the default adapter for it.
    ///      Two reporters, no health flag: the +$11,375.92 shape, reintroduced through the release side.
    ///
    ///      The residue array is written with `vm.store` because it CANNOT be produced through the external
    ///      API any more — every post-upgrade removal path wipes the array. That is the point: the dangerous
    ///      state is PRE-#335 residue, which this implementation inherits and cannot create. `ClearDormantMeta
    ///      Instances` documents one such array live on mainnet today, and `addMetaBalanceAdapter(residue, [])`
    ///      — its own step 2, and the natural operator repair — is the single MANAGER call that reaches it.
    ///
    ///      A first version of this test re-registered `metaA` with an empty set and asserted the same things.
    ///      It passed with the fix REVERTED, because `removeBalanceAdapters` had already emptied metaA's array,
    ///      so the wipe iterated nothing and never reached the theft path at all.
    function test_release_cannotStealAClaimAnotherAdapterOwns() public {
        Mock_ERC20 t = _newToken();
        _register(t);

        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaB), _one(_coord(t)));
        assertFalse(def.isSupportedByDefault(address(t)), "precondition: metaB's claim disarmed the default");

        // Deregister metaA first: real residue sits on a DEREGISTERED adapter, which is also what makes
        // re-registration the call that reaches it.
        address[] memory one = new address[](1);
        one[0] = address(metaA);
        vm.prank(navCalculatorManager);
        nav.removeBalanceAdapters(one);

        // Fabricate pre-#335 residue: metaA's `_metaInstances` array lists a coordinate metaB owns.
        // `_metaInstances` is a mapping at slot 60; the array's length lives at the mapping slot and its
        // elements at keccak256(that slot).
        bytes32 base = keccak256(abi.encode(address(metaA), uint256(60)));
        vm.store(address(nav), base, bytes32(uint256(1)));
        vm.store(address(nav), keccak256(abi.encode(base)), _coord(t));
        assertEq(nav.getMetaInstances(address(metaA)).length, 1, "precondition: residue fabricated");

        // The single MANAGER call that wipes that residue — and must not touch metaB's claim.
        vm.prank(navCalculatorManager);
        nav.addMetaBalanceAdapter(address(metaA), new bytes32[](0));

        assertFalse(def.isSupportedByDefault(address(t)), "a residue wipe must not re-arm the default adapter");
        assertEq(nav.getMetaInstances(address(metaB)).length, 1, "metaB must still hold its coordinate");

        // And the claim must still be metaB's: the wipe must not have left it takeable.
        vm.prank(navCalculatorManager);
        vm.expectRevert(
            abi.encodeWithSelector(IBalances.MetaInstanceClaimedByAnotherAdapter.selector, _coord(t), address(metaB))
        );
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
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

    // -------------------------------------------------------------------------
    // Route 8: release a coordinate that NARROWS onto a token another adapter governs.
    // -------------------------------------------------------------------------

    /// @dev `_reincludeIfAsset` narrows a coordinate to an address by dropping its top 12 bytes, and that
    ///      narrowing is NOT injective: a coordinate that is not address-shaped — a Morpho marketId, a
    ///      Balancer V2 poolId — can land on a real token another meta adapter governs under the
    ///      address-shaped coordinate `bytes32(T)`.
    ///
    ///      Before the claim gate, releasing such a coordinate re-armed the default adapter for `T` while the
    ///      other adapter was still reporting it: two reporters, no health flag — the exact shape this PR
    ///      exists to close, arriving through the RELEASE side rather than the claim side. Its inclusion twin
    ///      `includeAssetIfUnclaimed` had always consulted `claimant`; `_reincludeIfAsset` had not, and that
    ///      asymmetry was the gap.
    ///
    ///      Unreachable on today's configs — zero low-160 collisions across every configured coordinate — but
    ///      it becomes live the moment the claimant map is populated, and from then on it governs every
    ///      `removeMetaInstances` and `removeBalanceAdapters`. "Expected never" is not "cannot".
    function test_releaseNarrowingOntoGovernedToken_doesNotArmDefault() public {
        Mock_ERC20 t = _newToken();
        _register(t);

        // metaB governs the token itself, which disarms the default adapter.
        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaB), _one(_coord(t)));
        assertFalse(def.isSupportedByDefault(address(t)), "claiming the token must disarm the default adapter");

        // metaA governs a DIFFERENT coordinate that narrows onto the same token: same low 160 bits, a set
        // high bit so it is a distinct map key. This is the marketId/poolId shape.
        bytes32 narrowing = bytes32(uint256(uint160(address(t))) | (uint256(1) << 255));
        assertTrue(narrowing != _coord(t), "the probe must be a DISTINCT coordinate, or it tests nothing");
        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(narrowing));

        // Releasing metaA's coordinate must NOT hand the token back to the default adapter: metaB still
        // reports it.
        vm.prank(navCalculatorManager);
        nav.removeMetaInstances(address(metaA), _one(narrowing));

        assertFalse(
            def.isSupportedByDefault(address(t)),
            "releasing a coordinate that narrows onto a GOVERNED token must not arm the default adapter"
        );
        assertEq(nav.getMetaInstances(address(metaB)).length, 1, "metaB must still govern the token it never released");
    }

    /// @dev The other direction, and the one that matters for not over-correcting: an ORDINARY release must
    ///      still re-arm the default adapter. `_release` deletes the claim before calling
    ///      `_reincludeIfAsset`, so for an address-shaped coordinate the new gate reads zero and the re-arm
    ///      proceeds exactly as before. Without this test the claim gate could be tightened into a
    ///      fail-closed that silently strands every released token with no reporter — which is the failure
    ///      `_reincludeIfAsset` was added to prevent in the first place.
    function test_releaseOwnAddressShapedCoordinate_stillArmsDefault() public {
        Mock_ERC20 t = _newToken();
        _register(t);

        vm.prank(navCalculatorManager);
        nav.addMetaInstances(address(metaA), _one(_coord(t)));
        assertFalse(def.isSupportedByDefault(address(t)), "claiming must disarm the default adapter");

        vm.prank(navCalculatorManager);
        nav.removeMetaInstances(address(metaA), _one(_coord(t)));

        assertTrue(
            def.isSupportedByDefault(address(t)),
            "an ordinary release must hand the token back to the default adapter, not strand it"
        );
    }
}
