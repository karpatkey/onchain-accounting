// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {AssistedNftCacheAdapter} from "src/balances/AssistedBalanceAdapters/AssistedNftCacheAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @dev Minimal concrete {AssistedNftCacheAdapter} for exercising the shared per-account tokenId cache directly —
///      the delta-reconcile submit, the cap enforcement, and the ownership-gated writes that every NFT-cache adapter
///      (EtherFi, Uniswap V3, PancakeSwap V3, Nexus) inherits. A small cap (3) keeps the cap-path tests cheap.
contract MockNftCacheAdapter is AssistedNftCacheAdapter {
    mapping(uint256 => address) private _owners;

    constructor(address admin, address assistant) AssistedNftCacheAdapter(admin, assistant) {}

    /// @dev Test hook: set (or clear, with `address(0)`) the owner the cache's write-time check sees for `tokenId`.
    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function _ownerOf(uint256 tokenId) internal view override returns (address, bool) {
        address o = _owners[tokenId];
        return o == address(0) ? (address(0), false) : (o, true);
    }

    function _maxTokenIds() internal pure override returns (uint256) {
        return 3;
    }

    // Unused IBalanceAdapter read surface — this mock exercises only the shared cache CRUD on the base, so these are
    // stubbed to empty to make the contract concrete (the concrete protocol adapters provide the real valuation).
    function getAdapterPositions(address, address)
        external
        pure
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    function getAdapterBalances(address)
        external
        pure
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }
}

contract AssistedNftCacheAdapterTest is Test {
    MockNftCacheAdapter private adapter;
    address private constant ADMIN = address(0xA11CE);
    address private constant ASSISTANT = address(0xA5151);
    address private constant USER = address(0xCAFE);

    function setUp() public {
        adapter = new MockNftCacheAdapter(ADMIN, ASSISTANT);
    }

    //
    // Helpers
    //

    function _ids(uint256 a) private pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids(uint256 a, uint256 b) private pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    function _ids(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory r) {
        r = new uint256[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _ids(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (uint256[] memory r) {
        r = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
    }

    function _own(uint256[] memory ids) private {
        for (uint256 i; i < ids.length; ++i) {
            adapter.setOwner(ids[i], USER);
        }
    }

    function _submit(uint256[] memory ids) private {
        vm.prank(ASSISTANT);
        adapter.submitTokenIds(USER, ids);
    }

    /// @dev Asserts the cache for USER equals `want` as a set (order-independent; `want` must be duplicate-free).
    function _assertCacheEquals(uint256[] memory want) private view {
        uint256[] memory got = adapter.tokenIdsOf(USER);
        assertEq(got.length, want.length, "cache size");
        for (uint256 i; i < want.length; ++i) {
            bool found;
            for (uint256 j; j < got.length; ++j) {
                if (got[j] == want[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "expected id missing from cache");
        }
    }

    //
    // Delta reconcile
    //

    function test_submit_overlap_appliesDelta() public {
        _own(_ids(1, 2, 3));
        adapter.setOwner(4, USER);
        _submit(_ids(1, 2, 3));
        _assertCacheEquals(_ids(1, 2, 3));
        // Resubmit an overlapping full set: drop 3, keep 1 & 2 (untouched), add 4.
        _submit(_ids(1, 2, 4));
        _assertCacheEquals(_ids(1, 2, 4));
    }

    function test_submit_shrinkingSet_removesDropped() public {
        _own(_ids(1, 2, 3));
        _submit(_ids(1, 2, 3));
        _submit(_ids(1));
        _assertCacheEquals(_ids(1));
    }

    function test_submit_dedupsDuplicatesInList() public {
        _own(_ids(1, 2));
        _submit(_ids(1, 1, 2)); // the duplicate 1 collapses
        _assertCacheEquals(_ids(1, 2));
    }

    function test_submit_unchangedResubmit_skipsReownershipCheck() public {
        _own(_ids(1, 2, 3));
        _submit(_ids(1, 2, 3));
        // Transfer 2 away AFTER it was cached. An unchanged full-set resubmit must NOT revert — the delta skips
        // re-checking already-cached ids — and the set is left intact (reads, not this write, discard non-owned ids).
        adapter.setOwner(2, address(0xDEAD));
        _submit(_ids(1, 2, 3));
        _assertCacheEquals(_ids(1, 2, 3));
    }

    //
    // Cap enforcement
    //

    /// @dev Regression test for the cap-ordering bug: at the cap (3), a full-set resubmit that rotates one id OUT and
    ///      another IN (net size unchanged) must succeed. Removals run before additions, so the outgoing id's slot is
    ///      freed before the incoming id is added. (Pre-fix this reverted `TokenIdCacheFull` on the transient union.)
    function test_submit_fullCapSwap_doesNotRevert() public {
        _own(_ids(1, 2, 3));
        adapter.setOwner(4, USER);
        _submit(_ids(1, 2, 3)); // exactly at cap
        _submit(_ids(1, 2, 4)); // rotate 3 -> 4
        _assertCacheEquals(_ids(1, 2, 4));
    }

    function test_submit_overCap_reverts() public {
        _own(_ids(1, 2, 3));
        adapter.setOwner(4, USER);
        vm.prank(ASSISTANT);
        vm.expectRevert(abi.encodeWithSelector(TokenIdCacheFull.selector, USER, 3));
        adapter.submitTokenIds(USER, _ids(1, 2, 3, 4));
    }

    //
    // Ownership + access control
    //

    function test_submit_nonOwnedId_reverts() public {
        _own(_ids(1, 2)); // 3 is not owned by USER
        vm.prank(ASSISTANT);
        vm.expectRevert(abi.encodeWithSelector(NotTokenOwner.selector, USER, 3));
        adapter.submitTokenIds(USER, _ids(1, 2, 3));
    }

    function test_submit_onlyAssistant() public {
        _own(_ids(1));
        vm.expectRevert(); // AccessControl: caller lacks ASSISTANT_ROLE
        adapter.submitTokenIds(USER, _ids(1));
    }

    //
    // GC
    //

    function test_clearTokenId_then_clearAccount() public {
        _own(_ids(1, 2, 3));
        _submit(_ids(1, 2, 3));
        vm.prank(ASSISTANT);
        adapter.clearTokenId(USER, 2);
        _assertCacheEquals(_ids(1, 3));
        vm.prank(ASSISTANT);
        adapter.clearAccount(USER);
        assertEq(adapter.tokenIdsOf(USER).length, 0, "cleared");
    }
}
