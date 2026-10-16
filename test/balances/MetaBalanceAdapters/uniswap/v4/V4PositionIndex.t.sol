// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";

import {V4PositionIndex} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4PositionIndex.sol";
import {PoolKey} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";
import {NotAContract} from "src/errors.sol";
import {MockV4PositionManager} from "test/balances/MetaBalanceAdapters/uniswap/v4/UniswapV4Mocks.sol";

/// @title V4PositionIndex unit tests
/// @notice The index files an id under whatever `ownerOf` says, never under the caller — that is the property that
///         lets it be permissionless, and it is what these tests pin down. Staleness is exercised as the normal
///         state it is: a transfer and a burn, which is what every vfat rebalance produces.
contract V4PositionIndexTest is Test {
    MockV4PositionManager internal posm;
    V4PositionIndex internal index;

    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");
    address internal stranger = makeAddr("stranger");

    PoolKey internal key;

    function setUp() public {
        posm = new MockV4PositionManager();
        index = new V4PositionIndex(address(posm));
        key = PoolKey(address(1), address(2), 3000, 60, address(0));
        for (uint256 id = 1; id <= 4; ++id) {
            posm.mint(holder, id, key, -60, 60, 1e12);
        }
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function test_constructorRejectsANonContract() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "PositionManager"));
        new V4PositionIndex(address(0));
        assertEq(address(index.POSITION_MANAGER()), address(posm));
    }

    /// @notice The premise of the whole design: the PositionManager cannot be enumerated.
    function test_positionManagerIsNotEnumerable() public {
        (bool ok,) =
            address(posm).staticcall(abi.encodeWithSignature("tokenOfOwnerByIndex(address,uint256)", holder, 0));
        assertFalse(ok, "no enumeration extension: this is why the index exists");
    }

    function test_indexFilesUnderTheCurrentOwner() public {
        index.index(_ids(1, 2));
        uint256[] memory filed = index.indexedTokenIds(holder);
        assertEq(filed.length, 2);
        assertEq(filed[0], 1);
        assertEq(filed[1], 2);
        assertTrue(index.isIndexed(holder, 1));
        assertFalse(index.isIndexed(other, 1));
        assertEq(index.liveCount(holder), 2);
    }

    /// @notice Callable by anyone — the ownership read, not the caller, is what makes an entry correct.
    function test_indexIsPermissionlessAndIdempotent() public {
        vm.prank(stranger);
        index.index(_ids(1));
        assertTrue(index.isIndexed(holder, 1), "filed under the owner, not the caller");
        assertFalse(index.isIndexed(stranger, 1));

        vm.prank(stranger);
        index.index(_ids(1));
        assertEq(index.indexedTokenIds(holder).length, 1, "re-indexing is a no-op, never a duplicate");
    }

    function test_indexEmitsIndexed() public {
        vm.expectEmit(true, true, false, false, address(index));
        emit V4PositionIndex.Indexed(holder, 1);
        index.index(_ids(1));
    }

    function test_indexRevertsOnANonexistentTokenId() public {
        vm.expectRevert(abi.encodeWithSelector(V4PositionIndex.NonexistentPosition.selector, uint256(999)));
        index.index(_ids(999));
    }

    /// @notice Pruning live data must be impossible, or an open prune could blind the adapter.
    function test_pruneRevertsForAStillOwnedEntry() public {
        index.index(_ids(1));
        vm.expectRevert(abi.encodeWithSelector(V4PositionIndex.EntryStillValid.selector, holder, uint256(1)));
        index.prune(holder, _ids(1));
    }

    function test_pruneRevertsWhenNotIndexed() public {
        vm.expectRevert(abi.encodeWithSelector(V4PositionIndex.NotIndexed.selector, holder, uint256(1)));
        index.prune(holder, _ids(1));
    }

    /// @notice The rebalance shape: ownership moves, the entry goes stale, `prune` reclaims it.
    function test_transferredEntryGoesStaleAndIsPrunable() public {
        index.index(_ids(1, 2));
        posm.transfer(holder, other, 1);

        assertTrue(index.isIndexed(holder, 1), "still filed: index and prune are decoupled on purpose");
        assertEq(index.liveCount(holder), 1, "but no longer live");
        uint256[] memory live = index.liveTokenIds(holder);
        assertEq(live.length, 1);
        assertEq(live[0], 2);

        index.prune(holder, _ids(1));
        assertFalse(index.isIndexed(holder, 1));
        assertEq(index.indexedTokenIds(holder).length, 1);
        assertEq(index.indexedTokenIds(holder)[0], 2, "swap-and-pop keeps the survivor reachable");
        assertTrue(index.isIndexed(holder, 2));
    }

    /// @notice A burned position (every rebalance leaves one) is prunable, not a revert.
    function test_burnedEntryIsPrunable() public {
        index.index(_ids(1, 2));
        posm.burn(1);
        assertEq(index.liveCount(holder), 1);
        index.prune(holder, _ids(1));
        assertFalse(index.isIndexed(holder, 1));
    }

    /// @notice Swap-and-pop has to keep every other entry addressable, including the one it moved.
    function test_pruneKeepsTheRemainingEntriesConsistent() public {
        uint256[] memory four = new uint256[](4);
        four[0] = 1;
        four[1] = 2;
        four[2] = 3;
        four[3] = 4;
        index.index(four);

        posm.burn(2);
        index.prune(holder, _ids(2));

        uint256[] memory filed = index.indexedTokenIds(holder);
        assertEq(filed.length, 3);
        // Position 2 (1-based slot 2) was overwritten by the last element, 4.
        assertEq(filed[0], 1);
        assertEq(filed[1], 4);
        assertEq(filed[2], 3);
        assertTrue(index.isIndexed(holder, 4), "the moved entry is still addressable at its new slot");

        // And pruning the moved entry still works, which is what a wrong `_slotOf` update would break.
        posm.burn(4);
        index.prune(holder, _ids(4));
        assertEq(index.indexedTokenIds(holder).length, 2);
        assertTrue(index.isIndexed(holder, 1));
        assertTrue(index.isIndexed(holder, 3));
    }

    /// @notice A transfer re-files the id under the NEW owner while the OLD entry stays behind, by design.
    function test_reindexAfterTransferFilesUnderTheNewOwner() public {
        index.index(_ids(1));
        posm.transfer(holder, other, 1);
        index.index(_ids(1));

        assertTrue(index.isIndexed(other, 1), "filed under the new owner");
        assertTrue(index.isIndexed(holder, 1), "the old entry is prune's job, not index's");
        assertEq(index.liveCount(other), 1);
        assertEq(index.liveCount(holder), 0);
    }

    function test_emptyHolderReadsAreEmpty() public view {
        assertEq(index.indexedTokenIds(other).length, 0);
        assertEq(index.liveTokenIds(other).length, 0);
        assertEq(index.liveCount(other), 0);
        assertFalse(index.isIndexed(other, 1));
    }
}
