// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    MerklRewardsBalanceAdapter,
    IMerklDistributor
} from "src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
/// @dev    Submit is REPLACE semantics: `submitProofs(user, Allocation[])` sets the user's COMPLETE cached token set
///         (clearing the prior set), so a user's multiple tokens must be submitted in ONE call (see `_submitMany`).
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

        // admin = assistant = `owner`, so `owner` can submit/clear allocations.
        adapter = new MerklRewardsBalanceAdapter(address(distributor), address(balances), owner, owner);
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

    /// @dev Wrap a single (token, amount, proof) into the per-user replace submit (pranked as `owner`). Submit is
    ///      replace semantics, so this sets the user's cached set to exactly this one token.
    function _submitOne(address user, address token, uint256 amount, bytes32[] memory proof) internal {
        MerklRewardsBalanceAdapter.Allocation[] memory allocs = new MerklRewardsBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsBalanceAdapter.Allocation({token: token, cumulativeAmount: amount, proof: proof, campaignId: bytes32(0), subCampaignId: bytes32(0)});
        vm.prank(owner);
        adapter.submitProofs(user, allocs);
    }

    /// @dev Submit several (token, amount, proof) entries for one user in a single replace submit (pranked as `owner`).
    ///      Needed because a per-user submit replaces the whole set — multiple tokens for one user must go in one call.
    function _submitMany(address user, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs)
        internal
    {
        MerklRewardsBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsBalanceAdapter.Allocation[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            allocs[i] =
                MerklRewardsBalanceAdapter.Allocation({token: tokens[i], cumulativeAmount: amounts[i], proof: proofs[i], campaignId: bytes32(0), subCampaignId: bytes32(0)});
        }
        vm.prank(owner);
        adapter.submitProofs(user, allocs);
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructor_revertsOnZeroDistributor() public {
        vm.expectRevert(InvalidArguments.selector);
        new MerklRewardsBalanceAdapter(address(0), address(balances), owner, owner);
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new MerklRewardsBalanceAdapter(address(distributor), address(0), owner, owner);
    }

    function test_constructor_revertsOnNonContractDistributor() public {
        vm.expectRevert("Distributor must be a contract");
        new MerklRewardsBalanceAdapter(makeAddr("eoa"), address(balances), owner, owner);
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert("NAVCalculator must be a contract");
        new MerklRewardsBalanceAdapter(address(distributor), makeAddr("eoa"), owner, owner);
    }

    function test_constructor_setsImmutableState() public view {
        assertEq(adapter.DISTRIBUTOR(), address(distributor));
        assertEq(address(adapter.NAV_CALCULATOR()), address(balances));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(adapter.hasRole(adapter.ASSISTANT_ROLE(), owner));
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
    // submitProofs — happy path
    // ============================================

    function test_submitProofs_singleLeafTree() public {
        // Single-leaf tree: root = leaf, proof = [].
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));

        (uint256 amt, bytes32 root, uint64 ts,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 100 ether);
        assertEq(root, leaf);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_submitProofs_twoLeafTree() public {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);

        (bytes32 root, bytes32[] memory proof) = _buildTree2(leaves, 0);
        distributor.setRoot(root);

        _submitOne(alice, address(arb), 100 ether, proof);

        (uint256 amt, bytes32 cachedRoot,,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 100 ether);
        assertEq(cachedRoot, root);

        // _userTokens populated
        address[] memory tokens = adapter.userTokens(alice);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(arb));
    }

    function test_submitProofs_fourLeafTree_allLeavesVerifiable() public {
        bytes32[4] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);
        leaves[2] = _leaf(alice, address(op), 50 ether);
        leaves[3] = _leaf(makeAddr("carol"), address(op), 75 ether);

        (bytes32 root,) = _buildTree4(leaves, 0);
        distributor.setRoot(root);

        // alice holds TWO tokens (ARB + OP): submitted together in one replace call.
        address[] memory aTokens = new address[](2);
        uint256[] memory aAmounts = new uint256[](2);
        bytes32[][] memory aProofs = new bytes32[][](2);
        aTokens[0] = address(arb);
        aAmounts[0] = 100 ether;
        (, aProofs[0]) = _buildTree4(leaves, 0);
        aTokens[1] = address(op);
        aAmounts[1] = 50 ether;
        (, aProofs[1]) = _buildTree4(leaves, 2);
        _submitMany(alice, aTokens, aAmounts, aProofs);

        // bob holds one token (ARB).
        (, bytes32[] memory bobProof) = _buildTree4(leaves, 1);
        _submitOne(bob, address(arb), 200 ether, bobProof);

        address[] memory aliceTokens = adapter.userTokens(alice);
        assertEq(aliceTokens.length, 2);
        assertEq(aliceTokens[0], address(arb));
        assertEq(aliceTokens[1], address(op));

        address[] memory bobTokens = adapter.userTokens(bob);
        assertEq(bobTokens.length, 1);
        assertEq(bobTokens[0], address(arb));
    }

    function test_submitProofs_emitsEvent() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        vm.expectEmit(true, true, false, true, address(adapter));
        emit MerklRewardsBalanceAdapter.AllocationCached(alice, address(arb), 100 ether, leaf, uint64(block.timestamp), bytes32(0), bytes32(0));
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));
    }

    function test_submitProofs_replacesPriorSet() public {
        // Seed alice with {ARB, OP}.
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(op), 50 ether);
        (bytes32 root, bytes32[] memory p0) = _buildTree2(leaves, 0);
        (, bytes32[] memory p1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        proofs[0] = p0;
        tokens[1] = address(op);
        amounts[1] = 50 ether;
        proofs[1] = p1;
        _submitMany(alice, tokens, amounts, proofs);
        assertEq(adapter.userTokens(alice).length, 2);

        // Re-submitting ONLY {OP} replaces the set — ARB is dropped.
        bytes32 opLeaf = _leaf(alice, address(op), 50 ether);
        distributor.setRoot(opLeaf);
        _submitOne(alice, address(op), 50 ether, new bytes32[](0));

        address[] memory after_ = adapter.userTokens(alice);
        assertEq(after_.length, 1, "prior set replaced, not merged");
        assertEq(after_[0], address(op));
        (uint256 arbAmt,,,,) = adapter.allocations(alice, address(arb));
        assertEq(arbAmt, 0, "dropped ARB entry zeroed");
    }

    function test_submitProofs_overwritesPriorEntry_doesNotDuplicateUserTokenList() public {
        // First submission
        bytes32 leaf1 = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf1);
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));

        // Time passes; root rotates; resubmit the same single token at a higher amount.
        vm.warp(block.timestamp + 1 days);
        bytes32 leaf2 = _leaf(alice, address(arb), 150 ether);
        distributor.setRoot(leaf2);
        _submitOne(alice, address(arb), 150 ether, new bytes32[](0));

        // _userTokens should have ARB exactly once
        address[] memory tokens = adapter.userTokens(alice);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(arb));

        (uint256 amt, bytes32 cachedRoot, uint64 ts,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 150 ether);
        assertEq(cachedRoot, leaf2);
        assertEq(ts, uint64(block.timestamp));
    }

    // ============================================
    // submitProofs — rejection paths
    // ============================================

    function test_submitProofs_revertsOnZeroUser() public {
        bytes32 leaf = _leaf(address(0), address(arb), 100 ether);
        distributor.setRoot(leaf);
        vm.expectRevert(InvalidArguments.selector);
        _submitOne(address(0), address(arb), 100 ether, new bytes32[](0));
    }

    function test_submitProofs_revertsOnZeroToken() public {
        bytes32 leaf = _leaf(alice, address(0), 100 ether);
        distributor.setRoot(leaf);
        vm.expectRevert(InvalidArguments.selector);
        _submitOne(alice, address(0), 100 ether, new bytes32[](0));
    }

    function test_submitProofs_revertsOnUninitializedRoot() public {
        // root == 0
        vm.expectRevert(MerklRewardsBalanceAdapter.UninitializedRoot.selector);
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));
    }

    function test_submitProofs_revertsOnInvalidProof_wrongAmount() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        vm.expectRevert(MerklRewardsBalanceAdapter.InvalidProof.selector);
        _submitOne(alice, address(arb), 999 ether, new bytes32[](0));
    }

    function test_submitProofs_revertsOnInvalidProof_wrongUser() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        vm.expectRevert(MerklRewardsBalanceAdapter.InvalidProof.selector);
        _submitOne(bob, address(arb), 100 ether, new bytes32[](0));
    }

    function test_submitProofs_revertsOnInvalidProof_corruptedSibling() public {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);

        (bytes32 root, bytes32[] memory proof) = _buildTree2(leaves, 0);
        distributor.setRoot(root);

        // Corrupt the sibling
        proof[0] = bytes32(uint256(proof[0]) ^ uint256(1));

        vm.expectRevert(MerklRewardsBalanceAdapter.InvalidProof.selector);
        _submitOne(alice, address(arb), 100 ether, proof);
    }

    /// @notice Across-submit monotonicity is NOT enforced under replace (the cleared cache makes the guard moot) — the
    ///         live-root proof is the guarantee. The `AmountRegression` guard still catches a decreasing DUPLICATE
    ///         token within a single submitted list.
    function test_submitProofs_revertsOnWithinListRegression() public {
        // Tree containing both leaf(alice, ARB, 100) and leaf(alice, ARB, 50) so both proofs verify against one root.
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(arb), 50 ether);
        (bytes32 root, bytes32[] memory p0) = _buildTree2(leaves, 0);
        (, bytes32[] memory p1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);

        // Same token twice, decreasing: the second entry trips AmountRegression.
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        proofs[0] = p0;
        tokens[1] = address(arb);
        amounts[1] = 50 ether;
        proofs[1] = p1;

        MerklRewardsBalanceAdapter.Allocation[] memory allocs = new MerklRewardsBalanceAdapter.Allocation[](2);
        allocs[0] = MerklRewardsBalanceAdapter.Allocation({token: tokens[0], cumulativeAmount: amounts[0], proof: p0, campaignId: bytes32(0), subCampaignId: bytes32(0)});
        allocs[1] = MerklRewardsBalanceAdapter.Allocation({token: tokens[1], cumulativeAmount: amounts[1], proof: p1, campaignId: bytes32(0), subCampaignId: bytes32(0)});
        vm.expectRevert(MerklRewardsBalanceAdapter.AmountRegression.selector);
        vm.prank(owner);
        adapter.submitProofs(alice, allocs);
    }

    /// @notice Under replace, a NEW submit with a lower amount than a prior submit is accepted (the prior cache is
    ///         cleared first) — across-submit monotonicity is intentionally not enforced.
    function test_submitProofs_lowerAmountInNewSubmitAccepted() public {
        bytes32 leaf1 = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf1);
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));

        bytes32 leaf2 = _leaf(alice, address(arb), 50 ether);
        distributor.setRoot(leaf2);
        _submitOne(alice, address(arb), 50 ether, new bytes32[](0)); // lower — accepted under replace

        (uint256 amt,,,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 50 ether);
    }

    function test_submitProofs_revertsOnNonAssistant() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        MerklRewardsBalanceAdapter.Allocation[] memory allocs = new MerklRewardsBalanceAdapter.Allocation[](1);
        allocs[0] =
            MerklRewardsBalanceAdapter.Allocation({token: address(arb), cumulativeAmount: 100 ether, proof: new bytes32[](0), campaignId: bytes32(0), subCampaignId: bytes32(0)});
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, keccak256("ASSISTANT_ROLE")
            )
        );
        vm.prank(stranger);
        adapter.submitProofs(alice, allocs);
    }

    // ============================================
    // submitProofsBatch
    // ============================================

    function test_submitProofsBatch_happyPath() public {
        bytes32[4] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(bob, address(arb), 200 ether);
        leaves[2] = _leaf(alice, address(op), 50 ether);
        leaves[3] = _leaf(bob, address(op), 75 ether);

        (bytes32 root,) = _buildTree4(leaves, 0);
        distributor.setRoot(root);

        address[] memory users = new address[](2);
        MerklRewardsBalanceAdapter.Allocation[][] memory allocs = new MerklRewardsBalanceAdapter.Allocation[][](2);

        // alice: ARB (leaf 0) + OP (leaf 2)
        users[0] = alice;
        allocs[0] = new MerklRewardsBalanceAdapter.Allocation[](2);
        (, bytes32[] memory aArb) = _buildTree4(leaves, 0);
        (, bytes32[] memory aOp) = _buildTree4(leaves, 2);
        allocs[0][0] = MerklRewardsBalanceAdapter.Allocation(address(arb), 100 ether, aArb, bytes32(0), bytes32(0));
        allocs[0][1] = MerklRewardsBalanceAdapter.Allocation(address(op), 50 ether, aOp, bytes32(0), bytes32(0));

        // bob: ARB (leaf 1) + OP (leaf 3)
        users[1] = bob;
        allocs[1] = new MerklRewardsBalanceAdapter.Allocation[](2);
        (, bytes32[] memory bArb) = _buildTree4(leaves, 1);
        (, bytes32[] memory bOp) = _buildTree4(leaves, 3);
        allocs[1][0] = MerklRewardsBalanceAdapter.Allocation(address(arb), 200 ether, bArb, bytes32(0), bytes32(0));
        allocs[1][1] = MerklRewardsBalanceAdapter.Allocation(address(op), 75 ether, bOp, bytes32(0), bytes32(0));

        vm.prank(owner);
        adapter.submitProofsBatch(users, allocs);

        assertEq(adapter.userTokens(alice).length, 2);
        assertEq(adapter.userTokens(bob).length, 2);
    }

    function test_submitProofsBatch_revertsOnLengthMismatch() public {
        address[] memory users = new address[](2);
        MerklRewardsBalanceAdapter.Allocation[][] memory allocs = new MerklRewardsBalanceAdapter.Allocation[][](1); // mismatch

        vm.expectRevert(ArrayLengthMismatch.selector);
        vm.prank(owner);
        adapter.submitProofsBatch(users, allocs);
    }

    // ============================================
    // clearAllocation
    // ============================================

    function _seedAllocation(address user, address token, uint256 amount) internal {
        bytes32 leaf = _leaf(user, token, amount);
        distributor.setRoot(leaf);
        _submitOne(user, token, amount, new bytes32[](0));
    }

    function test_clearAllocation_zerosCacheAndRemovesFromList() public {
        _seedAllocation(alice, address(arb), 100 ether);

        vm.prank(owner);
        adapter.clearAllocation(alice, address(arb));

        (uint256 amt, bytes32 root, uint64 ts,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 0);
        assertEq(root, ZERO);
        assertEq(ts, 0);
        assertEq(adapter.userTokens(alice).length, 0);
    }

    function test_clearAllocation_swapAndPopFromMiddle() public {
        // Seed three tokens for alice in ONE replace submit (a 4-leaf tree; the 4th leaf is an unused filler).
        bytes32[4] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(op), 50 ether);
        leaves[2] = _leaf(alice, address(morpho), 25 ether);
        leaves[3] = _leaf(makeAddr("filler"), address(arb), 1 ether);
        (bytes32 root,) = _buildTree4(leaves, 0);
        distributor.setRoot(root);

        address[] memory tokens = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        bytes32[][] memory proofs = new bytes32[][](3);
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        (, proofs[0]) = _buildTree4(leaves, 0);
        tokens[1] = address(op);
        amounts[1] = 50 ether;
        (, proofs[1]) = _buildTree4(leaves, 1);
        tokens[2] = address(morpho);
        amounts[2] = 25 ether;
        (, proofs[2]) = _buildTree4(leaves, 2);
        _submitMany(alice, tokens, amounts, proofs);

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

    function test_clearAllocation_revertsOnNonAssistant() public {
        _seedAllocation(alice, address(arb), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, keccak256("ASSISTANT_ROLE")
            )
        );
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

    function test_getAdapterBalances_skipsClaimedZero() public {
        // Seed alice with {ARB, OP} in one replace submit (shared tree root).
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(op), 50 ether);
        (bytes32 root, bytes32[] memory p0) = _buildTree2(leaves, 0);
        (, bytes32[] memory p1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        proofs[0] = p0;
        tokens[1] = address(op);
        amounts[1] = 50 ether;
        proofs[1] = p1;
        _submitMany(alice, tokens, amounts, proofs);

        // Mark OP fully claimed → its unclaimed is 0 → skipped from the array; ARB (fresh root) remains.
        distributor.setClaimed(alice, address(op), uint208(50 ether), uint48(block.timestamp), bytes32(0));

        (address[] memory assets, uint256[] memory outAmounts,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1, "claimed-zero OP skipped, ARB kept");
        assertEq(assets[0], address(arb));
        assertEq(outAmounts[0], 100 ether);
    }

    function test_getAdapterBalances_skipsAllWhenStale() public {
        // Seed {ARB, OP}, then rotate the root so the whole cache goes stale → both skipped.
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(op), 50 ether);
        (bytes32 root, bytes32[] memory p0) = _buildTree2(leaves, 0);
        (, bytes32[] memory p1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        proofs[0] = p0;
        tokens[1] = address(op);
        amounts[1] = 50 ether;
        proofs[1] = p1;
        _submitMany(alice, tokens, amounts, proofs);

        distributor.setRoot(keccak256("rotated root")); // both entries now stale

        (address[] memory assets, uint256[] memory outAmounts,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
        assertEq(outAmounts.length, 0);
    }

    function test_getAdapterBalances_returnsAllFreshNonZero() public {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(op), 50 ether);
        (bytes32 root, bytes32[] memory proof0) = _buildTree2(leaves, 0);
        (, bytes32[] memory proof1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        proofs[0] = proof0;
        tokens[1] = address(op);
        amounts[1] = 50 ether;
        proofs[1] = proof1;
        _submitMany(alice, tokens, amounts, proofs);

        (address[] memory assets, uint256[] memory outAmounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 2);
        assertEq(outAmounts[0], 100 ether);
        assertEq(outAmounts[1], 50 ether);
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
        _submitOne(alice, address(unregistered), 100 ether, new bytes32[](0));

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

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        tokens[0] = address(arb);
        amounts[0] = 100 ether;
        proofs[0] = proof0;
        tokens[1] = address(op);
        amounts[1] = 50 ether;
        proofs[1] = proof1;
        _submitMany(alice, tokens, amounts, proofs);

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

    function test_positionInstanceId_carriesCampaignPair() public {
        bytes32 cid = keccak256("merkl-campaign-1");
        bytes32 sub = keccak256("merkl-subcampaign-1");
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        MerklRewardsBalanceAdapter.Allocation[] memory allocs = new MerklRewardsBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsBalanceAdapter.Allocation({
            token: address(arb),
            cumulativeAmount: 100 ether,
            proof: new bytes32[](0),
            campaignId: cid,
            subCampaignId: sub
        });
        vm.prank(owner);
        adapter.submitProofs(alice, allocs);

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 1);
        // The reward amount is still the proof-verified per-token total (campaign pair never affects value).
        assertEq(pos[0].amount, 100 ether);
        assertEq(
            pos[0].positionInstanceId,
            keccak256(abi.encode(cid, sub)),
            "positionInstanceId = keccak256(abi.encode(campaignId, subCampaignId))"
        );
    }

    function test_positionInstanceId_zeroWhenNoCampaignSubmitted() public {
        _seedAllocation(alice, address(arb), 100 ether); // campaignId/subCampaignId default to bytes32(0)
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].positionInstanceId, bytes32(0), "no campaign submitted -> bytes32(0)");
    }

    // ============================================
    // Access control — role administration
    // ============================================

    function test_adminCanGrantAssistantRole_grantee_canSubmit() public {
        // Admin (`owner`) grants ASSISTANT_ROLE to a fresh actor.
        bytes32 role = adapter.ASSISTANT_ROLE();
        vm.prank(owner);
        adapter.grantRole(role, stranger);
        assertTrue(adapter.hasRole(role, stranger));

        // The new assistant can submit.
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        MerklRewardsBalanceAdapter.Allocation[] memory allocs = new MerklRewardsBalanceAdapter.Allocation[](1);
        allocs[0] =
            MerklRewardsBalanceAdapter.Allocation({token: address(arb), cumulativeAmount: 100 ether, proof: new bytes32[](0), campaignId: bytes32(0), subCampaignId: bytes32(0)});
        vm.prank(stranger);
        adapter.submitProofs(alice, allocs);
    }
}
