// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {MerklRewardsBalanceAdapter, IMerklDistributor} from "src/balances/protocols/MerklRewardsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Mock Merkl Distributor: lets the test set the active root and the per-(user, token) claimed amount.
/// @dev    Returns are auto-flat-tuple-style to match Solidity's auto-generated public mapping getter.
contract MockMerklDistributor is IMerklDistributor {
    bytes32 private _root;
    mapping(address => mapping(address => Claim)) private _claimed;

    struct Claim {
        uint208 amount;
        uint48 timestamp;
        bytes32 merkleRoot;
    }

    function setRoot(bytes32 r) external {
        _root = r;
    }

    function setClaimed(address user, address token, uint208 amount, uint48 timestamp, bytes32 merkleRoot) external {
        _claimed[user][token] = Claim(amount, timestamp, merkleRoot);
    }

    function getMerkleRoot() external view override returns (bytes32) {
        return _root;
    }

    function claimed(address user, address token)
        external
        view
        override
        returns (uint208 amount, uint48 timestamp, bytes32 merkleRoot)
    {
        Claim memory c = _claimed[user][token];
        return (c.amount, c.timestamp, c.merkleRoot);
    }
}

/// @title MerklRewardsBalanceAdapterTest
/// @notice Unit tests for MerklRewardsBalanceAdapter. Builds toy 1-, 2-, and 4-leaf merkle trees in-memory using the
///         same hashing rule as Merkl's Distributor (sorted-pair, `keccak256(abi.encode(a, b))`).
contract MerklRewardsBalanceAdapterTest is BalanceAdapterTestBase {
    MerklRewardsBalanceAdapter public adapter;
    MockMerklDistributor public distributor;

    address public owner = makeAddr("owner");
    address public stranger = makeAddr("stranger");

    Mock_ERC20 public arb;
    Mock_ERC20 public op;
    Mock_ERC20 public morpho;

    bytes32 internal constant ZERO = bytes32(0);

    function setUp() public override {
        super.setUp();
        distributor = new MockMerklDistributor();
        arb = _createAndRegisterToken("ARB", 18);
        op = _createAndRegisterToken("OP", 18);
        morpho = _createAndRegisterToken("MORPHO", 18);

        adapter = new MerklRewardsBalanceAdapter(address(distributor), address(balances), owner);
    }

    // ============================================
    // Helpers — toy merkle tree (matches Merkl's Distributor _verifyProof)
    // ============================================

    function _leaf(address user, address token, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, token, amount));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Builds a 4-leaf tree and returns the root and a proof for `leafIdx` (0-indexed).
    function _buildTree4(bytes32[4] memory leaves, uint256 leafIdx)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        bytes32 h01 = _hashPair(leaves[0], leaves[1]);
        bytes32 h23 = _hashPair(leaves[2], leaves[3]);
        root = _hashPair(h01, h23);

        proof = new bytes32[](2);
        if (leafIdx == 0) {
            proof[0] = leaves[1];
            proof[1] = h23;
        } else if (leafIdx == 1) {
            proof[0] = leaves[0];
            proof[1] = h23;
        } else if (leafIdx == 2) {
            proof[0] = leaves[3];
            proof[1] = h01;
        } else {
            proof[0] = leaves[2];
            proof[1] = h01;
        }
    }

    function _buildTree2(bytes32[2] memory leaves, uint256 leafIdx)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        root = _hashPair(leaves[0], leaves[1]);
        proof = new bytes32[](1);
        proof[0] = leaves[leafIdx == 0 ? 1 : 0];
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructor_revertsOnZeroDistributor() public {
        vm.expectRevert(InvalidArguments.selector);
        new MerklRewardsBalanceAdapter(address(0), address(balances), owner);
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new MerklRewardsBalanceAdapter(address(distributor), address(0), owner);
    }

    function test_constructor_revertsOnNonContractDistributor() public {
        vm.expectRevert("Distributor must be a contract");
        new MerklRewardsBalanceAdapter(makeAddr("eoa"), address(balances), owner);
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new MerklRewardsBalanceAdapter(address(distributor), makeAddr("eoa"), owner);
    }

    function test_constructor_setsImmutableState() public view {
        assertEq(adapter.DISTRIBUTOR(), address(distributor));
        assertEq(address(adapter.NAV_CALCULATOR()), address(balances));
        assertEq(adapter.owner(), owner);
    }

    // ============================================
    // ERC165 + interface
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_underlyingAssetsSupported_returnsEmpty() public view {
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    // ============================================
    // submitProof — happy path
    // ============================================

    function test_submitProof_singleLeafTree() public {
        // Single-leaf tree: root = leaf, proof = [].
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, emptyProof);

        (uint256 amt, bytes32 root, uint64 ts) = adapter.allocations(alice, address(arb));
        assertEq(amt, 100 ether);
        assertEq(root, leaf);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_submitProof_twoLeafTree() public {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);

        (bytes32 root, bytes32[] memory proof) = _buildTree2(leaves, 0);
        distributor.setRoot(root);

        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, proof);

        (uint256 amt, bytes32 cachedRoot,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 100 ether);
        assertEq(cachedRoot, root);

        // _userTokens populated
        address[] memory tokens = adapter.userTokens(alice);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(arb));
    }

    function test_submitProof_fourLeafTree_allLeavesVerifiable() public {
        bytes32[4] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);
        leaves[2] = _leaf(alice, address(op), 50 ether);
        leaves[3] = _leaf(makeAddr("carol"), address(op), 75 ether);

        bytes32 root;
        bytes32[] memory proof;

        // Compute root once
        (root, proof) = _buildTree4(leaves, 0);
        distributor.setRoot(root);

        // alice/ARB
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, proof);

        // bob/ARB
        (, proof) = _buildTree4(leaves, 1);
        vm.prank(owner);
        adapter.submitProof(bob, address(arb), 200 ether, proof);

        // alice/OP
        (, proof) = _buildTree4(leaves, 2);
        vm.prank(owner);
        adapter.submitProof(alice, address(op), 50 ether, proof);

        // alice now has two tokens cached
        address[] memory aliceTokens = adapter.userTokens(alice);
        assertEq(aliceTokens.length, 2);
        assertEq(aliceTokens[0], address(arb));
        assertEq(aliceTokens[1], address(op));

        address[] memory bobTokens = adapter.userTokens(bob);
        assertEq(bobTokens.length, 1);
        assertEq(bobTokens[0], address(arb));
    }

    function test_submitProof_emitsEvent() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit MerklRewardsBalanceAdapter.AllocationCached(alice, address(arb), 100 ether, leaf, uint64(block.timestamp));
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, emptyProof);
    }

    function test_submitProof_overwritesPriorEntry_doesNotDuplicateUserTokenList() public {
        // First submission
        bytes32 leaf1 = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf1);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, emptyProof);

        // Time passes; root rotates
        vm.warp(block.timestamp + 1 days);
        bytes32 leaf2 = _leaf(alice, address(arb), 150 ether);
        distributor.setRoot(leaf2);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 150 ether, emptyProof);

        // _userTokens should have ARB exactly once
        address[] memory tokens = adapter.userTokens(alice);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(arb));

        (uint256 amt, bytes32 cachedRoot, uint64 ts) = adapter.allocations(alice, address(arb));
        assertEq(amt, 150 ether);
        assertEq(cachedRoot, leaf2);
        assertEq(ts, uint64(block.timestamp));
    }

    // ============================================
    // submitProof — rejection paths
    // ============================================

    function test_submitProof_revertsOnZeroUser() public {
        bytes32 leaf = _leaf(address(0), address(arb), 100 ether);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(InvalidArguments.selector);
        vm.prank(owner);
        adapter.submitProof(address(0), address(arb), 100 ether, emptyProof);
    }

    function test_submitProof_revertsOnZeroToken() public {
        bytes32 leaf = _leaf(alice, address(0), 100 ether);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(InvalidArguments.selector);
        vm.prank(owner);
        adapter.submitProof(alice, address(0), 100 ether, emptyProof);
    }

    function test_submitProof_revertsOnUninitializedRoot() public {
        // root == 0
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.expectRevert(MerklRewardsBalanceAdapter.UninitializedRoot.selector);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, emptyProof);
    }

    function test_submitProof_revertsOnInvalidProof_wrongAmount() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(MerklRewardsBalanceAdapter.InvalidProof.selector);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 999 ether, emptyProof);
    }

    function test_submitProof_revertsOnInvalidProof_wrongUser() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(MerklRewardsBalanceAdapter.InvalidProof.selector);
        vm.prank(owner);
        adapter.submitProof(bob, address(arb), 100 ether, emptyProof);
    }

    function test_submitProof_revertsOnInvalidProof_corruptedSibling() public {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);

        (bytes32 root, bytes32[] memory proof) = _buildTree2(leaves, 0);
        distributor.setRoot(root);

        // Corrupt the sibling
        proof[0] = bytes32(uint256(proof[0]) ^ uint256(1));

        vm.expectRevert(MerklRewardsBalanceAdapter.InvalidProof.selector);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, proof);
    }

    function test_submitProof_revertsOnAmountRegression() public {
        // First submission at 100
        bytes32 leaf1 = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf1);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, emptyProof);

        // Try to submit a smaller amount — even with a valid proof against a different root.
        bytes32 leaf2 = _leaf(alice, address(arb), 50 ether);
        distributor.setRoot(leaf2);

        vm.expectRevert(MerklRewardsBalanceAdapter.AmountRegression.selector);
        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 50 ether, emptyProof);
    }

    function test_submitProof_revertsOnNonOwner() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(); // OwnableUnauthorizedAccount
        vm.prank(stranger);
        adapter.submitProof(alice, address(arb), 100 ether, emptyProof);
    }

    // ============================================
    // submitProofBatch
    // ============================================

    function test_submitProofBatch_happyPath() public {
        bytes32[4] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);
        leaves[2] = _leaf(alice, address(op), 50 ether);
        leaves[3] = _leaf(bob, address(op), 75 ether);

        (bytes32 root,) = _buildTree4(leaves, 0);
        distributor.setRoot(root);

        address[] memory users = new address[](4);
        address[] memory tokens = new address[](4);
        uint256[] memory amounts = new uint256[](4);
        bytes32[][] memory proofs = new bytes32[][](4);

        users[0] = alice;
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        (, proofs[0]) = _buildTree4(leaves, 0);

        users[1] = bob;
        tokens[1] = address(arb);
        amounts[1] = 200 ether;
        (, proofs[1]) = _buildTree4(leaves, 1);

        users[2] = alice;
        tokens[2] = address(op);
        amounts[2] = 50 ether;
        (, proofs[2]) = _buildTree4(leaves, 2);

        users[3] = bob;
        tokens[3] = address(op);
        amounts[3] = 75 ether;
        (, proofs[3]) = _buildTree4(leaves, 3);

        vm.prank(owner);
        adapter.submitProofBatch(users, tokens, amounts, proofs);

        assertEq(adapter.userTokens(alice).length, 2);
        assertEq(adapter.userTokens(bob).length, 2);
    }

    function test_submitProofBatch_revertsOnLengthMismatch() public {
        address[] memory users = new address[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](1); // mismatch
        bytes32[][] memory proofs = new bytes32[][](2);

        vm.expectRevert(ArrayLengthMismatch.selector);
        vm.prank(owner);
        adapter.submitProofBatch(users, tokens, amounts, proofs);
    }

    // ============================================
    // clearAllocation
    // ============================================

    function _seedAllocation(address user, address token, uint256 amount) internal {
        bytes32 leaf = _leaf(user, token, amount);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(owner);
        adapter.submitProof(user, token, amount, emptyProof);
    }

    function test_clearAllocation_zerosCacheAndRemovesFromList() public {
        _seedAllocation(alice, address(arb), 100 ether);

        vm.prank(owner);
        adapter.clearAllocation(alice, address(arb));

        (uint256 amt, bytes32 root, uint64 ts) = adapter.allocations(alice, address(arb));
        assertEq(amt, 0);
        assertEq(root, ZERO);
        assertEq(ts, 0);
        assertEq(adapter.userTokens(alice).length, 0);
    }

    function test_clearAllocation_swapAndPopFromMiddle() public {
        // Seed three tokens for alice, one root at a time.
        _seedAllocation(alice, address(arb), 100 ether);
        _seedAllocation(alice, address(op), 50 ether);
        _seedAllocation(alice, address(morpho), 25 ether);

        // Sanity: list is [arb, op, morpho]
        address[] memory before = adapter.userTokens(alice);
        assertEq(before.length, 3);

        // Clear OP (the middle one). Expect swap-and-pop: list becomes [arb, morpho].
        vm.prank(owner);
        adapter.clearAllocation(alice, address(op));

        address[] memory after_ = adapter.userTokens(alice);
        assertEq(after_.length, 2);
        assertEq(after_[0], address(arb));
        assertEq(after_[1], address(morpho));
    }

    function test_clearAllocation_isIdempotent() public {
        // Clear something that was never cached — should not revert.
        vm.prank(owner);
        adapter.clearAllocation(alice, address(arb));
    }

    function test_clearAllocation_revertsOnNonOwner() public {
        _seedAllocation(alice, address(arb), 100 ether);
        vm.expectRevert();
        vm.prank(stranger);
        adapter.clearAllocation(alice, address(arb));
    }

    // ============================================
    // Reads — getAdapterBalanceForAsset
    // ============================================

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amt, bool isDebt) = adapter.getAdapterBalanceForAsset(address(0), address(arb));
        assertEq(amt, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAsset() public view {
        (uint256 amt, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amt, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_returnsZeroForUncachedPair() public view {
        (uint256 amt,) = adapter.getAdapterBalanceForAsset(alice, address(arb));
        assertEq(amt, 0);
    }

    function test_getAdapterBalanceForAsset_returnsCumMinusClaimed() public {
        _seedAllocation(alice, address(arb), 100 ether);
        distributor.setClaimed(alice, address(arb), uint208(30 ether), uint48(block.timestamp), bytes32(0));

        (uint256 amt, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(arb));
        assertEq(amt, 70 ether);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_returnsZeroWhenFullyClaimed() public {
        _seedAllocation(alice, address(arb), 100 ether);
        distributor.setClaimed(alice, address(arb), uint208(100 ether), uint48(block.timestamp), bytes32(0));

        (uint256 amt,) = adapter.getAdapterBalanceForAsset(alice, address(arb));
        assertEq(amt, 0);
    }

    function test_getAdapterBalanceForAsset_returnsZeroWhenStaleRoot() public {
        _seedAllocation(alice, address(arb), 100 ether);
        // Root rotates; cache becomes stale.
        distributor.setRoot(keccak256("a different root"));

        (uint256 amt,) = adapter.getAdapterBalanceForAsset(alice, address(arb));
        assertEq(amt, 0);
    }

    // ============================================
    // Reads — getAdapterBalances
    // ============================================

    function test_getAdapterBalances_emptyForZeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterBalances_skipsZeroAndStale() public {
        _seedAllocation(alice, address(arb), 100 ether);
        _seedAllocation(alice, address(op), 50 ether);

        // Mark OP as fully claimed → returns 0 → skipped.
        distributor.setClaimed(alice, address(op), uint208(50 ether), uint48(block.timestamp), bytes32(0));
        // Refresh root to the most recent leaf so ARB is still fresh.
        distributor.setRoot(_leaf(alice, address(op), 50 ether));

        (address[] memory assets, uint256[] memory amounts,) = adapter.getAdapterBalances(alice);
        // ARB is now stale (root != leaf(alice, ARB, 100)). Both should be skipped.
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getAdapterBalances_returnsAllFreshNonZero() public {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(op), 50 ether);
        (bytes32 root, bytes32[] memory proof0) = _buildTree2(leaves, 0);
        (, bytes32[] memory proof1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);

        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, proof0);
        vm.prank(owner);
        adapter.submitProof(alice, address(op), 50 ether, proof1);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 2);
        assertEq(amounts[0], 100 ether);
        assertEq(amounts[1], 50 ether);
        assertFalse(isDebt[0]);
        assertFalse(isDebt[1]);
    }

    // ============================================
    // Reads — getAdapterPositions
    // ============================================

    function test_getAdapterPositions_emptyForZeroAccount() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(address(0), address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_filtersUnregisteredAsset() public {
        // Cache an allocation for an unregistered token (skip _createAndRegisterToken).
        Mock_ERC20 unregistered = new Mock_ERC20("UNREG", 18);
        bytes32 leaf = _leaf(alice, address(unregistered), 100 ether);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(owner);
        adapter.submitProof(alice, address(unregistered), 100 ether, emptyProof);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0); // dropped — not in NAV asset registry
    }

    function test_getAdapterPositions_assetFilterRespected() public {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(op), 50 ether);
        (bytes32 root, bytes32[] memory proof0) = _buildTree2(leaves, 0);
        (, bytes32[] memory proof1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);

        vm.prank(owner);
        adapter.submitProof(alice, address(arb), 100 ether, proof0);
        vm.prank(owner);
        adapter.submitProof(alice, address(op), 50 ether, proof1);

        INAVCalculator.PositionBalance[] memory all = adapter.getAdapterPositions(alice, address(0));
        assertEq(all.length, 2);

        INAVCalculator.PositionBalance[] memory arbOnly = adapter.getAdapterPositions(alice, address(arb));
        assertEq(arbOnly.length, 1);
        assertEq(arbOnly[0].balanceAsset.asset, address(arb));
        assertEq(arbOnly[0].amount, 100 ether);
        assertFalse(arbOnly[0].isDebt);
        assertEq(arbOnly[0].balanceAdapter, address(adapter));
    }

    function test_getAdapterPositions_skipsClaimedAndStale() public {
        _seedAllocation(alice, address(arb), 100 ether);
        // Mark fully claimed → unclaimed = 0 → skipped.
        distributor.setClaimed(alice, address(arb), uint208(100 ether), uint48(block.timestamp), bytes32(0));

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    // ============================================
    // Ownership
    // ============================================

    function test_transferOwnership_works() public {
        vm.prank(owner);
        adapter.transferOwnership(stranger);
        assertEq(adapter.owner(), stranger);

        // New owner can submit
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(stranger);
        adapter.submitProof(alice, address(arb), 100 ether, emptyProof);
    }
}
