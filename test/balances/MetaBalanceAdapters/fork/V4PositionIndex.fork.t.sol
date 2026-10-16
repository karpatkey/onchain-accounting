// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {V4PositionIndex} from "src/balances/MetaBalanceAdapters/uniswap/v4/V4PositionIndex.sol";
import {IV4PositionManager} from "src/balances/MetaBalanceAdapters/uniswap/v4/IUniswapV4.sol";

interface IERC721Minimal {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title V4PositionIndexForkTest
/// @notice Fork tests for the V4 discovery index against the live Uniswap V4 PositionManager on Robinhood Chain
///         (chain id 4663) and the real positions of a production vault's vfat Sickle.
///
/// @dev **What is true at {FORK_BLOCK} = 90,186,157** (all measured, 16 Oct 2026):
///        - `tokenOfOwnerByIndex` is absent from `0x58daec31…4fa7` — the premise the whole contract exists for.
///        - `balanceOf(SICKLE) == 8`, and those eight ids are {liveIds}.
///        - 2475032 is BURNED (`ownerOf` reverts `NOT_MINTED`); it is the ether position whose unmapped
///          `address(0)` currency cost the NAV about 1,660 USDG in Sep 2026, long since rebalanced away. It is
///          still filed on the deployed index, which is exactly the staleness this contract treats as normal.
///        - `nextTokenId() == 3855591`, so that id has never been minted.
///        - The already-deployed index `0x025e980A…D301` holds 20 filed ids for the Sickle, 8 of them live.
contract V4PositionIndexForkTest is TestEnvConfigurator {
    uint256 public constant FORK_BLOCK = 90_186_157;

    address public constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address public constant LIVE_INDEX = 0x025e980Ad119Db4656DFdeF6C5B170eA51A5D301;
    address public constant SICKLE = 0x6f94B45B68d9d446706436eB9D55E3a600a723Ba;

    uint256 public constant BURNED_TOKEN = 2475032;
    uint256 public constant NEVER_MINTED = 3855591;

    V4PositionIndex internal index;
    IV4PositionManager internal posm = IV4PositionManager(POSITION_MANAGER);
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        uint256 fork_ = createForkWithCadence(getAlchemyUrl("robinhood-mainnet"));
        vm.selectFork(fork_);
        vm.rollFork(FORK_BLOCK);
        index = new V4PositionIndex(POSITION_MANAGER);
    }

    /// @notice The eight V4 positions the Sickle holds at {FORK_BLOCK}.
    function liveIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](8);
        ids[0] = 3214040;
        ids[1] = 3270258;
        ids[2] = 3270259;
        ids[3] = 3270386;
        ids[4] = 3270387;
        ids[5] = 3270388;
        ids[6] = 3271001;
        ids[7] = 3272091;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    /// @notice The premise: V4's PositionManager is Solmate ERC721, with no enumeration to walk.
    function test_positionManagerIsNotEnumerable() public {
        (bool ok,) = POSITION_MANAGER.staticcall(
            abi.encodeWithSignature("tokenOfOwnerByIndex(address,uint256)", SICKLE, uint256(0))
        );
        assertFalse(ok, "no enumeration extension on chain");
        assertEq(posm.balanceOf(SICKLE), 8, "balanceOf works, which is why coverage can have a denominator");
    }

    function test_indexFilesTheSicklesRealPositions() public {
        uint256[] memory ids = liveIds();
        for (uint256 i; i < ids.length; ++i) {
            assertEq(posm.ownerOf(ids[i]), SICKLE, "fixture is live at this block");
        }
        index.index(ids);

        assertEq(index.indexedTokenIds(SICKLE).length, 8);
        assertEq(index.liveCount(SICKLE), 8);
        assertEq(index.liveCount(SICKLE), posm.balanceOf(SICKLE), "full coverage of what the chain says it holds");
        assertEq(index.liveTokenIds(SICKLE).length, 8);
    }

    /// @notice Callable by anyone, because the ownership read is what makes an entry correct.
    function test_indexIsPermissionlessAndIdempotent() public {
        vm.prank(stranger);
        index.index(_ids(3214040));
        assertTrue(index.isIndexed(SICKLE, 3214040), "filed under the real owner, not the caller");
        assertFalse(index.isIndexed(stranger, 3214040));

        vm.prank(stranger);
        index.index(_ids(3214040));
        assertEq(index.indexedTokenIds(SICKLE).length, 1, "never duplicated");
    }

    /// @notice A burned id is the residue of every vfat rebalance; `index` must say so rather than file nothing.
    function test_indexRevertsOnABurnedOrUnmintedId() public {
        vm.expectRevert(abi.encodeWithSelector(V4PositionIndex.NonexistentPosition.selector, BURNED_TOKEN));
        index.index(_ids(BURNED_TOKEN));

        vm.expectRevert(abi.encodeWithSelector(V4PositionIndex.NonexistentPosition.selector, NEVER_MINTED));
        index.index(_ids(NEVER_MINTED));
    }

    function test_pruneRefusesALiveEntry() public {
        index.index(_ids(3214040));
        vm.expectRevert(abi.encodeWithSelector(V4PositionIndex.EntryStillValid.selector, SICKLE, uint256(3214040)));
        index.prune(SICKLE, _ids(3214040));
    }

    function test_pruneRevertsWhenNotIndexed() public {
        vm.expectRevert(abi.encodeWithSelector(V4PositionIndex.NotIndexed.selector, SICKLE, uint256(3214040)));
        index.prune(SICKLE, _ids(3214040));
    }

    /// @notice The rebalance shape, driven through the real ERC721 rather than a mock: ownership moves, the entry
    ///         goes stale, `prune` reclaims it, and the other entries survive.
    function test_aRealTransferMakesAnEntryStaleAndPrunable() public {
        index.index(liveIds());
        assertEq(index.liveCount(SICKLE), 8);

        vm.prank(SICKLE);
        IERC721Minimal(POSITION_MANAGER).transferFrom(SICKLE, stranger, 3214040);
        assertEq(posm.ownerOf(3214040), stranger);

        assertTrue(index.isIndexed(SICKLE, 3214040), "still filed: index and prune are decoupled on purpose");
        assertEq(index.liveCount(SICKLE), 7, "but no longer live");

        index.prune(SICKLE, _ids(3214040));
        assertFalse(index.isIndexed(SICKLE, 3214040));
        assertEq(index.indexedTokenIds(SICKLE).length, 7);
        assertEq(index.liveCount(SICKLE), 7, "the survivors are untouched");

        // And it re-files under its NEW owner, leaving nothing of the old attribution behind.
        index.index(_ids(3214040));
        assertTrue(index.isIndexed(stranger, 3214040));
        assertEq(index.liveCount(stranger), 1);
    }

    /// @notice The index that is actually deployed on 4663, read as found: staleness is the normal state.
    function test_theDeployedIndexCarriesStaleEntriesNextToFullCoverage() public view {
        V4PositionIndex live = V4PositionIndex(LIVE_INDEX);
        assertEq(live.indexedTokenIds(SICKLE).length, 20, "twenty ids ever filed for this Sickle");
        assertEq(live.liveCount(SICKLE), 8, "twelve of them are dead");
        assertEq(live.liveCount(SICKLE), posm.balanceOf(SICKLE), "and coverage is nonetheless complete");
        assertTrue(live.isIndexed(SICKLE, BURNED_TOKEN), "including the burned ether position from Sep 2026");
    }
}
