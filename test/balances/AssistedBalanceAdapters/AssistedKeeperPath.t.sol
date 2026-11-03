// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {
    MockWithdrawRequestNFT,
    MockLiquidityPool
} from "test/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueue.t.sol";
import {
    MockStakeWiseVault,
    MockVaultsRegistry
} from "test/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.t.sol";
import {
    MockStakingNFT,
    MockStakingViewer
} from "test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {IAssistedBalanceAdapter} from "src/balances/IAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Keeper path (ADR 0030) — ether.fi member
/// @notice `submitFor` / `submitForBatch` (role-gated), `removeFor` (permissionless, proof-of-death) and the
///         cache-free `previewPositions`, exercised on the ether.fi member. Row numbers refer to ADR 0030's table.
contract EtherFiKeeperPathTest is BalanceAdapterTestBase {
    EtherFiWithdrawalQueueAssistedBalanceAdapter internal adapter;
    MockWithdrawRequestNFT internal nft;
    MockLiquidityPool internal lp;

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal keeper = makeAddr("keeper");
    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        nft = new MockWithdrawRequestNFT();
        lp = new MockLiquidityPool();
        balances.addSupportedAssetForTest(NATIVE);
        adapter = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(balances), address(this)
        );
        adapter.grantRole(adapter.SUBMITTER_ROLE(), keeper);
    }

    function _pending(uint256 id, address owner_) internal {
        nft.setRequest(id, owner_, 1 ether, 1 ether, true, 0, false, 0);
    }

    function _coord(uint256 id) internal pure returns (bytes memory) {
        return abi.encode(id);
    }

    // ---- Roles (S5, S8) ----

    function test_admin_isConstructorArg_andNoSubmitterAtDeploy() public {
        EtherFiWithdrawalQueueAssistedBalanceAdapter fresh = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(balances), other
        );
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), other));
        assertFalse(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(fresh.hasRole(fresh.SUBMITTER_ROLE(), other));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(InvalidArguments.selector);
        new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(balances), address(0)
        );
    }

    function test_submitFor_requiresRole() public {
        _pending(1, holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, other, adapter.SUBMITTER_ROLE()
            )
        );
        vm.prank(other);
        adapter.submitFor(holder, _coord(1));
    }

    function test_submitForBatch_emptyStillRequiresRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, other, adapter.SUBMITTER_ROLE()
            )
        );
        vm.prank(other);
        adapter.submitForBatch(new address[](0), new bytes[](0));
    }

    function test_submitFor_revokedKeeperCannotSubmit() public {
        adapter.revokeRole(adapter.SUBMITTER_ROLE(), keeper);
        _pending(1, holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, adapter.SUBMITTER_ROLE()
            )
        );
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(1));
    }

    // ---- submitFor (S1, S2, S4) ----

    function test_submitFor_filesUnderOwner_andValues() public {
        _pending(7, holder);
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7));
        uint256[] memory ids = adapter.tokenIdsOf(holder);
        assertEq(ids.length, 1);
        assertEq(ids[0], 7);
        INAVCalculator.PositionBalance[] memory legs = adapter.getAdapterPositions(holder, address(0));
        assertEq(legs.length, 1);
        assertEq(legs[0].amount, 1 ether);
        assertEq(adapter.tokenIdsOf(keeper).length, 0, "nothing filed under the keeper");
    }

    function test_submitFor_wrongOwnerReverts() public {
        _pending(7, holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, other, 7));
        vm.prank(keeper);
        adapter.submitFor(other, _coord(7));
    }

    function test_submitFor_zeroAccountReverts() public {
        vm.expectRevert(InvalidArguments.selector);
        vm.prank(keeper);
        adapter.submitFor(address(0), _coord(7));
    }

    function test_submitFor_nonCanonicalEncodingReverts() public {
        _pending(7, holder);
        bytes memory trailing = abi.encodePacked(_coord(7), bytes1(0x00));
        vm.expectRevert(abi.encodeWithSelector(IAssistedBalanceAdapter.NonCanonicalCoordinate.selector, 33, 32));
        vm.prank(keeper);
        adapter.submitFor(holder, trailing);

        vm.expectRevert(abi.encodeWithSelector(IAssistedBalanceAdapter.NonCanonicalCoordinate.selector, 31, 32));
        vm.prank(keeper);
        adapter.submitFor(holder, abi.encodePacked(uint248(7)));
    }

    event CoordSubmittedFor(address indexed account, uint256 indexed id, address indexed submitter);

    function test_submitFor_emitsKeeperAttribution_onlyWhenNew() public {
        _pending(7, holder);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit CoordSubmittedFor(holder, 7, keeper);
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7));

        vm.recordLogs();
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7)); // idempotent: no new entry, no event
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_submitFor_resubmitAfterTransferReverts() public {
        _pending(7, holder);
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7));
        _pending(7, other);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, 7));
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7));
    }

    function test_submitFor_idempotent_andSameKeyAsOwnerPath() public {
        _pending(7, holder);
        vm.prank(holder);
        adapter.submit(7);
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7));
        assertEq(adapter.tokenIdsOf(holder).length, 1, "owner and keeper paths share one cache key");
    }

    function test_sameIdCachedForTwoAccounts_onlyCurrentOwnerCounts() public {
        _pending(7, holder);
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7));
        _pending(7, other); // transferred
        vm.prank(keeper);
        adapter.submitFor(other, _coord(7));
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
        assertEq(adapter.getAdapterPositions(other, address(0)).length, 1);
    }

    function test_submitForBatch_filesEach_andIsAllOrNothing() public {
        _pending(1, holder);
        _pending(2, other);
        address[] memory accounts = new address[](2);
        bytes[] memory coords = new bytes[](2);
        accounts[0] = holder;
        coords[0] = _coord(1);
        accounts[1] = holder; // wrong owner for id 2
        coords[1] = _coord(2);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, 2));
        vm.prank(keeper);
        adapter.submitForBatch(accounts, coords);
        assertEq(adapter.tokenIdsOf(holder).length, 0, "first entry rolled back");

        accounts[1] = other;
        vm.prank(keeper);
        adapter.submitForBatch(accounts, coords);
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        assertEq(adapter.tokenIdsOf(other).length, 1);
    }

    function test_submitForBatch_lengthMismatchReverts() public {
        vm.expectRevert(InvalidArguments.selector);
        vm.prank(keeper);
        adapter.submitForBatch(new address[](1), new bytes[](2));
    }

    /// @notice S13: the keeper stops OWNER_RESERVE slots short of the cap, so the owner's own submit (its Assistant
    ///         path) always has room; the owner path still runs to the full cap.
    function test_submitFor_stopsShortOfCap_ownerKeepsReserve() public {
        uint256 cap = adapter.MAX_TOKEN_IDS();
        uint256 keeperLimit = cap - adapter.OWNER_RESERVE();
        for (uint256 i = 1; i <= keeperLimit; ++i) {
            _pending(i, holder);
            vm.prank(keeper);
            adapter.submitFor(holder, _coord(i));
        }
        _pending(keeperLimit + 1, holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, holder, keeperLimit));
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(keeperLimit + 1));

        for (uint256 i = keeperLimit + 1; i <= cap; ++i) {
            _pending(i, holder);
            vm.prank(holder);
            adapter.submit(i);
        }
        _pending(cap + 1, holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, holder, cap));
        vm.prank(holder);
        adapter.submit(cap + 1);
    }

    /// @notice S13 recovery: after a keeper saturated its share with live positions and the owner used its reserve, the
    ///         owner frees one slot with `evict` (live entry, no liveness gate) without losing its other entries.
    function test_evict_ownerFreesSlotAfterKeeperSaturation() public {
        uint256 cap = adapter.MAX_TOKEN_IDS();
        uint256 keeperLimit = cap - adapter.OWNER_RESERVE();
        for (uint256 i = 1; i <= cap; ++i) {
            _pending(i, holder);
            if (i <= keeperLimit) {
                vm.prank(keeper);
                adapter.submitFor(holder, _coord(i));
            } else {
                vm.prank(holder);
                adapter.submit(i);
            }
        }
        _pending(cap + 1, holder);
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, holder, cap));
        vm.prank(holder);
        adapter.submit(cap + 1);

        vm.prank(holder);
        adapter.evict(_coord(1)); // a keeper-filed, still-live entry
        vm.prank(holder);
        adapter.submit(cap + 1);
        assertEq(adapter.tokenIdsOf(holder).length, cap);
    }

    function test_evict_nonCanonicalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssistedBalanceAdapter.NonCanonicalCoordinate.selector, 33, 32));
        vm.prank(holder);
        adapter.evict(abi.encodePacked(_coord(7), bytes1(0)));
    }

    function test_evict_onlyTouchesCallersOwnSet() public {
        _pending(7, holder);
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(7));
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, other, 7));
        vm.prank(other);
        adapter.evict(_coord(7));
        assertEq(adapter.tokenIdsOf(holder).length, 1);
    }

    /// @notice Re-seeding is safe at the keeper limit: an already-cached coordinate is an idempotent no-op even when the
    ///         account sits at cap − OWNER_RESERVE (the dedup return comes before the limit check).
    function test_submitFor_resubmitAtKeeperLimitIsNoop() public {
        uint256 keeperLimit = adapter.MAX_TOKEN_IDS() - adapter.OWNER_RESERVE();
        for (uint256 i = 1; i <= keeperLimit; ++i) {
            _pending(i, holder);
            vm.prank(keeper);
            adapter.submitFor(holder, _coord(i));
        }
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(1)); // no revert
        assertEq(adapter.tokenIdsOf(holder).length, keeperLimit);
    }

    // ---- removeFor (S6) ----

    function _cached(uint256 id) internal {
        _pending(id, holder);
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(id));
    }

    function test_removeFor_livePositionReverts() public {
        _cached(7);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, 7));
        vm.prank(other);
        adapter.removeFor(holder, _coord(7));
    }

    function test_removeFor_claimedPositionIsRemovableByAnyone() public {
        _cached(7);
        nft.setRequest(7, address(0), 0, 0, false, 0, false, 0); // claim: NFT burned, request deleted
        vm.prank(other);
        adapter.removeFor(holder, _coord(7));
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    function test_removeFor_transferredAwayIsRemovable() public {
        _cached(7);
        _pending(7, other);
        vm.prank(other);
        adapter.removeFor(holder, _coord(7));
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    function test_removeFor_revertingReadIsNotDeath() public {
        _cached(7);
        nft.burn(7); // ownerOf now reverts …
        nft.setRevertGetRequest(true); // … and getRequest cannot prove the request is gone
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, 7));
        adapter.removeFor(holder, _coord(7));
    }

    function test_removeFor_invalidatedIsNotDeath_butOwnerMayDrop() public {
        _cached(7);
        nft.setRequest(7, holder, 1 ether, 1 ether, false, 0, false, 0); // invalidated, still owned
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, 7));
        adapter.removeFor(holder, _coord(7));
        vm.prank(holder);
        adapter.remove(7); // S12: the owner can drop it
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    function test_removeFor_ownedButEmptiedRequestIsNotDeath() public {
        _cached(7);
        nft.setRequest(7, holder, 0, 0, true, 0, false, 0); // still owned; an empty request alone proves nothing
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, 7));
        adapter.removeFor(holder, _coord(7));
    }

    function test_removeFor_uncachedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, holder, 7));
        adapter.removeFor(holder, _coord(7));
    }

    function test_removeFor_nonCanonicalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssistedBalanceAdapter.NonCanonicalCoordinate.selector, 64, 32));
        adapter.removeFor(holder, abi.encode(uint256(7), uint256(0)));
    }

    // ---- previewPositions (S9) ----

    function _payload(uint256 a, uint256 b) internal pure returns (bytes memory) {
        bytes[] memory coords = new bytes[](2);
        coords[0] = abi.encode(a);
        coords[1] = abi.encode(b);
        return abi.encode(coords);
    }

    function test_preview_matchesCachedRead_andWritesNothing() public {
        _pending(1, holder);
        nft.setRequest(2, holder, 3 ether, 3 ether, true, 0, true, 2 ether);
        INAVCalculator.PositionBalance[] memory preview = adapter.previewPositions(holder, _payload(1, 2));
        assertEq(adapter.tokenIdsOf(holder).length, 0, "preview wrote nothing");

        vm.startPrank(keeper);
        adapter.submitFor(holder, _coord(1));
        adapter.submitFor(holder, _coord(2));
        vm.stopPrank();
        INAVCalculator.PositionBalance[] memory cached = adapter.getAdapterPositions(holder, address(0));
        assertEq(preview.length, cached.length);
        for (uint256 i; i < cached.length; ++i) {
            assertEq(preview[i].amount, cached[i].amount);
            assertEq(preview[i].isLocked, cached[i].isLocked);
            assertEq(preview[i].positionInstanceId, cached[i].positionInstanceId);
        }
    }

    function test_preview_duplicateReverts() public {
        _pending(1, holder);
        vm.expectRevert(abi.encodeWithSelector(IAssistedBalanceAdapter.DuplicateCoordinate.selector, holder, 1));
        adapter.previewPositions(holder, _payload(1, 1));
    }

    function test_preview_notOwnedReverts() public {
        _pending(1, holder);
        _pending(2, other);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, 2));
        adapter.previewPositions(holder, _payload(1, 2));
    }

    function test_preview_tooManyReverts() public {
        uint256 n = adapter.MAX_TOKEN_IDS() + 1;
        bytes[] memory coords = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            coords[i] = abi.encode(i + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(IAssistedBalanceAdapter.TooManyCoordinates.selector, holder, n, n - 1));
        adapter.previewPositions(holder, abi.encode(coords));
    }

    function test_preview_emptyInputs() public view {
        assertEq(adapter.previewPositions(holder, "").length, 0);
        assertEq(adapter.previewPositions(address(0), _payload(1, 2)).length, 0);
        assertEq(adapter.previewPositions(holder, abi.encode(new bytes[](0))).length, 0);
    }

    function test_preview_unregisteredUnderlyingReturnsEmpty() public {
        BalancesHarness fresh = new BalancesHarness();
        EtherFiWithdrawalQueueAssistedBalanceAdapter a2 = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            address(nft), address(lp), NATIVE, address(fresh), address(this)
        );
        _pending(1, holder);
        _pending(2, holder);
        assertEq(a2.previewPositions(holder, _payload(1, 2)).length, 0);
    }

    function test_previewSelf_isNotExternallyCallable() public {
        vm.expectRevert(NotAuthorized.selector);
        adapter.previewPositionsSelf(holder, new bytes[](0));
    }

    // ---- ERC-165 ----

    function test_supportsInterface_includesAccessControl() public view {
        assertTrue(adapter.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAssistedBalanceAdapter).interfaceId));
    }
}

/// @title Keeper path (ADR 0030) — StakeWise V3 member
contract StakeWiseKeeperPathTest is BalanceAdapterTestBase {
    StakeWiseV3ExitQueueAssistedBalanceAdapter internal adapter;
    MockStakeWiseVault internal vault;
    MockVaultsRegistry internal registry;

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal keeper = makeAddr("keeper");
    address internal holder = makeAddr("holder");

    uint256 internal constant TICKET = 12_345;
    uint256 internal constant TS = 1_700_000_000;
    uint256 internal constant DELAY = 1 days;

    function setUp() public override {
        super.setUp();
        vault = new MockStakeWiseVault();
        registry = new MockVaultsRegistry();
        registry.setVault(address(vault), true);
        balances.addSupportedAssetForTest(NATIVE);
        adapter = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            address(registry), NATIVE, "osETH", address(balances), DELAY, address(this)
        );
        adapter.grantRole(adapter.SUBMITTER_ROLE(), keeper);
        vm.warp(TS + DELAY + 1);
        vault.setIndex(TICKET, 1);
        vault.setRequest(holder, TICKET, TS, 0, 1 ether);
    }

    function _coord(address v, uint256 ticket, uint256 ts) internal pure returns (bytes memory) {
        return abi.encode(v, ticket, ts);
    }

    function test_submitFor_filesUnderReceiver() public {
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(address(vault), TICKET, TS));
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 1);
    }

    function test_submitFor_wrongTimestampReverts() public {
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, holder, TICKET));
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(address(vault), TICKET, TS + 1));
    }

    function test_submitFor_dirtyAddressBitsRevert() public {
        bytes memory dirty = abi.encode(uint256(uint160(address(vault))) | (uint256(1) << 200), TICKET, TS);
        vm.expectRevert(bytes("")); // abi.decode's cleanliness check — not a CoordinateNotOwned / role error
        vm.prank(keeper);
        adapter.submitFor(holder, dirty);
    }

    function test_submitFor_wrongLengthReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssistedBalanceAdapter.NonCanonicalCoordinate.selector, 64, 96));
        vm.prank(keeper);
        adapter.submitFor(holder, abi.encode(address(vault), TICKET));
    }

    function test_removeFor_requestGoneIsDeath() public {
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(address(vault), TICKET, TS));
        vault.clearRequest(holder, TICKET, TS);
        adapter.removeFor(holder, _coord(address(vault), TICKET, TS));
        assertEq(adapter.positionsOf(holder).length, 0);
    }

    function test_removeFor_revertingReadIsNotDeath() public {
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(address(vault), TICKET, TS));
        vault.clearRequest(holder, TICKET, TS);
        vault.setRevertCalc(true);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, TICKET));
        adapter.removeFor(holder, _coord(address(vault), TICKET, TS));
    }

    function test_removeFor_indexReadRevertIsNotDeath() public {
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(address(vault), TICKET, TS));
        vault.clearRequest(holder, TICKET, TS);
        vault.setRevertIndex(true);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, TICKET));
        adapter.removeFor(holder, _coord(address(vault), TICKET, TS));
    }

    function test_removeFor_liveReverts() public {
        vm.prank(keeper);
        adapter.submitFor(holder, _coord(address(vault), TICKET, TS));
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, TICKET));
        adapter.removeFor(holder, _coord(address(vault), TICKET, TS));
    }

    function test_preview_unregisteredVaultReverts() public {
        MockStakeWiseVault rogue = new MockStakeWiseVault();
        rogue.setIndex(TICKET, 1);
        rogue.setRequest(holder, TICKET, TS, 0, 1_000_000 ether);
        bytes[] memory coords = new bytes[](1);
        coords[0] = _coord(address(rogue), TICKET, TS);
        vm.expectRevert(abi.encodeWithSelector(InvalidCoordinate.selector, holder, TICKET));
        adapter.previewPositions(holder, abi.encode(coords));
    }

    function test_preview_valuesRegisteredPosition() public view {
        bytes[] memory coords = new bytes[](1);
        coords[0] = _coord(address(vault), TICKET, TS);
        INAVCalculator.PositionBalance[] memory legs = adapter.previewPositions(holder, abi.encode(coords));
        assertEq(legs.length, 1);
        assertEq(legs[0].amount, 1 ether);
    }
}

/// @title Keeper path (ADR 0030) — Nexus Mutual member
contract NexusKeeperPathTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsAssistedBalanceAdapter internal adapter;
    MockStakingNFT internal nft;
    MockStakingViewer internal viewer;
    Mock_ERC20 internal nxm;

    address internal keeper = makeAddr("keeper");
    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this)
        );
        adapter.grantRole(adapter.SUBMITTER_ROLE(), keeper);
    }

    function _seed(uint256 id, address owner_, uint256 active) internal {
        nft.setToken(id, 1, owner_);
        viewer.setToken(id, 1, active, 0, 0);
    }

    function test_submitFor_filesUnderOwner() public {
        _seed(5, holder, 10 ether);
        vm.prank(keeper);
        adapter.submitFor(holder, abi.encode(uint256(5)));
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        assertGt(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_removeFor_emptiedIsDeath() public {
        _seed(5, holder, 10 ether);
        vm.prank(keeper);
        adapter.submitFor(holder, abi.encode(uint256(5)));
        viewer.setToken(5, 1, 0, 0, 0);
        adapter.removeFor(holder, abi.encode(uint256(5)));
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    function test_removeFor_transferredIsDeath() public {
        _seed(5, holder, 10 ether);
        vm.prank(keeper);
        adapter.submitFor(holder, abi.encode(uint256(5)));
        nft.setToken(5, 1, other);
        adapter.removeFor(holder, abi.encode(uint256(5)));
        assertEq(adapter.tokenIdsOf(holder).length, 0);
    }

    function test_removeFor_tokenInfoRevertIsNotDeath() public {
        _seed(5, holder, 10 ether);
        vm.prank(keeper);
        adapter.submitFor(holder, abi.encode(uint256(5)));
        nft.setRevertId(5);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, 5));
        adapter.removeFor(holder, abi.encode(uint256(5)));
    }

    function test_removeFor_viewerRevertIsNotDeath() public {
        _seed(5, holder, 10 ether);
        vm.prank(keeper);
        adapter.submitFor(holder, abi.encode(uint256(5)));
        viewer.setRevert(true);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, holder, 5));
        adapter.removeFor(holder, abi.encode(uint256(5)));
    }

    function test_preview_matchesCachedRead() public {
        _seed(5, holder, 10 ether);
        viewer.setToken(5, 1, 10 ether, 0, 2 ether);
        bytes[] memory coords = new bytes[](1);
        coords[0] = abi.encode(uint256(5));
        INAVCalculator.PositionBalance[] memory preview = adapter.previewPositions(holder, abi.encode(coords));
        vm.prank(keeper);
        adapter.submitFor(holder, coords[0]);
        INAVCalculator.PositionBalance[] memory cached = adapter.getAdapterPositions(holder, address(0));
        assertEq(preview.length, 2);
        assertEq(preview.length, cached.length);
        for (uint256 i; i < cached.length; ++i) {
            assertEq(preview[i].amount, cached[i].amount);
            assertEq(uint8(preview[i].positionKind), uint8(cached[i].positionKind));
        }
    }

    /// @dev Keeper fills to its limit, the owner fills the reserve: a full cache, by both paths.
    function _fillToCap() internal returns (uint256 cap) {
        cap = adapter.MAX_TOKEN_IDS();
        uint256 keeperLimit = cap - adapter.OWNER_RESERVE();
        for (uint256 i = 1; i <= cap; ++i) {
            _seed(i, holder, 1 ether);
            if (i <= keeperLimit) {
                vm.prank(keeper);
                adapter.submitFor(holder, abi.encode(i));
            } else {
                vm.prank(holder);
                adapter.submit(i);
            }
        }
    }

    function test_cacheFull_atCap() public {
        uint256 cap = _fillToCap();
        _seed(cap + 1, holder, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, holder, cap));
        vm.prank(holder);
        adapter.submit(cap + 1);
    }

    function test_readAtCap_staysWithinGas() public {
        uint256 cap = _fillToCap();
        uint256 g = gasleft();
        INAVCalculator.PositionBalance[] memory legs = adapter.getAdapterPositions(holder, address(0));
        uint256 used = g - gasleft();
        assertEq(legs.length, cap);
        assertLt(used, 30_000_000, "full-cap read fits a block");
    }
}
