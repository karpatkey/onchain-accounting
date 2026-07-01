// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
// Reuse the Nexus mocks defined alongside the assistant-fed adapter test.
import {
    MockStakingNFT,
    MockStakingViewer,
    MockNexusStakingPool
} from "test/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.t.sol";
import {NexusMutualStakingPoolsBalanceAdapter} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IWrapperFedBalanceAdapter} from "src/balances/IWrapperFedBalanceAdapter.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title NexusMutualStakingPoolsBalanceAdapter unit tests (wrapper-fed)
/// @notice Mirrors the assistant-fed adapter's coverage but exercises the wrapper-fed surface: `WRAPPER_ROLE`-gated
///         incremental `submit`/`remove` (single id) instead of the `ASSISTANT_ROLE` full-set `submitTokenIds`. The
///         valuation path is identical (shared {NexusMutualStakingValuationBase}), so the position/label/read-discard
///         assertions match the sibling.
contract NexusMutualStakingPoolsBalanceAdapterTest is BalanceAdapterTestBase {
    NexusMutualStakingPoolsBalanceAdapter public adapter;
    MockStakingNFT public nft;
    MockStakingViewer public viewer;
    Mock_ERC20 public nxm;

    address holder = makeAddr("holder");
    address other = makeAddr("other");

    bytes32 constant WRAPPER_ROLE = keccak256("WRAPPER_ROLE");

    function setUp() public override {
        super.setUp();
        nft = new MockStakingNFT();
        viewer = new MockStakingViewer();
        nxm = _createAndRegisterToken("NXM", 18);
        // admin + wrapper = this test, so it can submit/remove tokenIds directly.
        adapter = new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroNft() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(0), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroViewer() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(0), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(0), address(balances), address(this), address(this)
        );
    }

    function test_constructor_revertsOnZeroNav() public {
        vm.expectRevert(InvalidArguments.selector);
        new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(0), address(this), address(this)
        );
    }

    function test_constructor_revertsWhenNftNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "StakingNFT"));
        new NexusMutualStakingPoolsBalanceAdapter(
            makeAddr("eoa"), address(viewer), address(nxm), address(balances), address(this), address(this)
        );
    }

    function test_roles_grantedToConstructorArgs() public view {
        assertTrue(adapter.hasRole(WRAPPER_ROLE, address(this)));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(adapter.hasRole(WRAPPER_ROLE, other));
    }

    function test_constructor_wrapperOptional() public {
        NexusMutualStakingPoolsBalanceAdapter a2 = new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(balances), address(this), address(0)
        );
        assertFalse(a2.hasRole(WRAPPER_ROLE, address(this)));
        assertTrue(a2.hasRole(a2.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ---- Feed (wrapper) + valuation ----

    /// @dev Seed an owned token for `holder` in pool `pool`, value it, and submit its id (single, incremental).
    function _seedOne(uint256 id, uint256 pool, uint256 a, uint256 e, uint256 r) internal {
        nft.setToken(id, pool, holder);
        viewer.setToken(id, pool, a, e, r);
        adapter.submit(holder, id);
    }

    /// @notice Incremental submits ACCUMULATE (unlike the assistant-fed full-set replace).
    function test_submit_accumulates() public {
        _seedOne(2, 1, 100, 10, 3);
        _seedOne(5, 1, 100, 10, 3);
        assertEq(adapter.tokenIdsOf(holder).length, 2);
        (uint256 amt, bool d) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        // staking = (100+10)*2 = 220; rewards = 3*2 = 6; total = 226
        assertEq(amt, 226);
        assertEq(d, false);
    }

    /// @notice Re-submitting an already-cached id is a no-op (idempotent) — the count and value do not change.
    function test_submit_idempotent() public {
        _seedOne(2, 1, 100, 0, 5);
        adapter.submit(holder, 2); // duplicate
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 105);
    }

    function test_unsubmittedAccount_zero() public {
        _seedOne(3, 1, 100, 0, 5);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(other, address(nxm));
        assertEq(amt, 0);
    }

    function test_balanceForWrongAsset_zero() public {
        _seedOne(1, 1, 100, 0, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(weth));
        assertEq(amt, 0);
    }

    // ---- getAdapterPositions: per-NFT legs + identity ----

    function test_positions_stakingAndRewardsLegs() public {
        _seedOne(4, 7, 100, 20, 7); // pool 7
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 2);
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking));
        assertEq(p[0].amount, 120);
        assertEq(uint8(p[1].positionKind), uint8(PositionKind.Rewards));
        assertEq(p[1].amount, 7);
        bytes memory expectedId = abi.encode(viewer.poolAddr(7));
        for (uint256 i; i < 2; i++) {
            assertEq(p[i].balanceAsset.asset, address(nxm));
            assertEq(p[i].balanceAdapter, address(adapter));
            assertEq(p[i].protocolSubId, ProtocolIds.NEXUS_MUTUAL_STAKING_POOLS);
            assertEq(p[i].protocolId, ProtocolIds.NEXUS_MUTUAL);
            assertEq(p[i].positionId, expectedId);
            assertEq(p[i].isDebt, false);
            string[] memory lbl = adapter.positionLabels(p[i].positionId);
            assertEq(lbl.length, 2);
            assertEq(lbl[0], "Staking Pools");
            assertEq(lbl[1], Strings.toHexString(viewer.poolAddr(7)));
            assertEq(p[i].positionInstanceId, bytes32(uint256(4)));
        }
    }

    function test_positionLabels_poolIdLeaf() public {
        MockNexusStakingPool pool = new MockNexusStakingPool(42);
        string[] memory lbl = adapter.positionLabels(abi.encode(address(pool)));
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "Staking Pools");
        assertEq(lbl[1], "Pool #42");
    }

    function test_positions_twoPools_distinctPositionIds() public {
        nft.setToken(1, 7, holder);
        viewer.setToken(1, 7, 100, 0, 1);
        nft.setToken(2, 9, holder);
        viewer.setToken(2, 9, 200, 0, 2);
        adapter.submit(holder, 1);
        adapter.submit(holder, 2);

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 4);
        assertEq(p[0].positionId, abi.encode(viewer.poolAddr(7)));
        assertEq(p[0].positionInstanceId, bytes32(uint256(1)));
        assertEq(p[0].amount, 100);
        assertEq(p[2].positionId, abi.encode(viewer.poolAddr(9)));
        assertEq(p[2].positionInstanceId, bytes32(uint256(2)));
        assertEq(p[2].amount, 200);
    }

    function test_positions_emptyWhenNothingSubmitted() public view {
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    function test_positions_assetFilterMatch_andMismatch() public {
        _seedOne(1, 1, 100, 0, 0);
        assertEq(adapter.getAdapterPositions(holder, address(nxm)).length, 1);
        assertEq(adapter.getAdapterPositions(holder, address(weth)).length, 0);
    }

    function test_unregisteredUnderlying_positionsEmpty_butBalanceOwed() public {
        BalancesHarness freshNav = new BalancesHarness();
        NexusMutualStakingPoolsBalanceAdapter a2 = new NexusMutualStakingPoolsBalanceAdapter(
            address(nft), address(viewer), address(nxm), address(freshNav), address(this), address(this)
        );
        nft.setToken(1, 1, holder);
        viewer.setToken(1, 1, 100, 0, 5);
        a2.submit(holder, 1);
        assertEq(a2.getAdapterPositions(holder, address(0)).length, 0);
        (uint256 amt,) = a2.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 105);
    }

    function test_getAdapterBalances_shape() public {
        _seedOne(2, 1, 100, 0, 5);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(holder);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(nxm));
        assertEq(amounts[0], 105);
        assertEq(isDebt[0], false);
    }

    // ---- Wrapper-fed cache behaviour ----

    function test_submit_onlyWrapperRole() public {
        nft.setToken(1, 1, holder);
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, WRAPPER_ROLE)
        );
        adapter.submit(holder, 1);
    }

    function test_submit_revertsOnZeroAccount() public {
        nft.setToken(1, 1, holder);
        vm.expectRevert(InvalidArguments.selector);
        adapter.submit(address(0), 1);
    }

    /// @notice Writes are fail-loud: submitting an id not owned by the account reverts NotTokenOwner (rolling back the
    ///         wrapper's deposit tx).
    function test_submit_revertsOnNonOwnedId() public {
        nft.setToken(1, 1, other); // owned by `other`, not holder
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, holder, uint256(1)));
        adapter.submit(holder, 1);
    }

    function test_remove_onlyWrapperRole() public {
        _seedOne(1, 1, 100, 0, 0);
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, WRAPPER_ROLE)
        );
        adapter.remove(holder, 1);
    }

    function test_remove_stopsTracking() public {
        _seedOne(1, 1, 100, 0, 0);
        _seedOne(2, 1, 200, 0, 0);
        adapter.remove(holder, 1);
        assertEq(adapter.tokenIdsOf(holder).length, 1);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 200);
    }

    function test_remove_idempotentOnUncached() public {
        _seedOne(1, 1, 100, 0, 0);
        adapter.remove(holder, 999); // never cached — no-op, no revert
        assertEq(adapter.tokenIdsOf(holder).length, 1);
    }

    /// @notice Reads are fail-open: an id transferred away after submission is silently discarded.
    function test_read_discardsTransferredId() public {
        _seedOne(1, 1, 100, 0, 0);
        _seedOne(2, 1, 200, 0, 0);
        nft.setToken(1, 1, other);
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(holder, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].positionInstanceId, bytes32(uint256(2)));
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 200);
    }

    function test_read_discardsRevertingId() public {
        _seedOne(2, 1, 100, 0, 0);
        _seedOne(4, 1, 100, 0, 0);
        nft.setRevertId(2);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 100);
    }

    // ---- Admin rescue ----

    function test_clearAccount_admin() public {
        _seedOne(1, 1, 100, 0, 0);
        adapter.clearAccount(holder);
        assertEq(adapter.tokenIdsOf(holder).length, 0);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_clearAccount_onlyAdmin() public {
        _seedOne(1, 1, 100, 0, 0);
        bytes32 adminRole = adapter.DEFAULT_ADMIN_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole)
        );
        adapter.clearAccount(holder);
    }

    // ---- Caps + never-revert ----

    function test_perAccountCap_revertsWhenFull() public {
        uint256 cap = adapter.MAX_TOKEN_IDS();
        for (uint256 i = 0; i < cap; i++) {
            uint256 id = i + 1;
            nft.setToken(id, 1, holder);
            viewer.setToken(id, 1, 1, 0, 0);
            adapter.submit(holder, id);
        }
        assertEq(adapter.tokenIdsOf(holder).length, cap);

        // One more (a genuinely new id) is fail-loud.
        uint256 overflowId = cap + 1;
        nft.setToken(overflowId, 1, holder);
        viewer.setToken(overflowId, 1, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(TokenIdCacheFull.selector, holder, cap));
        adapter.submit(holder, overflowId);
        assertEq(adapter.tokenIdsOf(holder).length, cap);
    }

    function test_viewerReverts_balanceZero() public {
        _seedOne(1, 1, 100, 0, 0);
        viewer.setRevert(true);
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(holder, address(nxm));
        assertEq(amt, 0);
    }

    function test_viewerReverts_positionsEmpty() public {
        _seedOne(1, 1, 100, 0, 5);
        viewer.setRevert(true);
        assertEq(adapter.getAdapterPositions(holder, address(0)).length, 0);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IWrapperFedBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory a = adapter.underlyingAssetsSupported();
        assertEq(a.length, 1);
        assertEq(a[0], address(nxm));
    }
}
