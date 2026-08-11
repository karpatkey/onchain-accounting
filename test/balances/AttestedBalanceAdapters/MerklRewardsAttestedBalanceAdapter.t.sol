// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    MerklRewardsAttestedBalanceAdapter,
    IMerklDistributor
} from "src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IAttestedBalanceAdapter} from "src/balances/IAttestedBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
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

/// @title MerklRewardsAttestedBalanceAdapterTest
/// @notice Unit tests for MerklRewardsAttestedBalanceAdapter. Builds toy 1-, 2-, and 4-leaf merkle trees in-memory using the
///         same hashing rule as Merkl's Distributor (sorted-pair, `keccak256(abi.encode(a, b))`).
/// @dev    The adapter is PERMISSIONLESS: `submitProofs`/`submitProofsBatch` take no roles and are callable by anyone
///         (integrity comes from live-root proof verification). Submit is UPSERT semantics: each `(token, proof)`
///         entry adds/refreshes just that `(user, token)` and never drops a token it omits — so a third party can't
///         suppress a live entry (removal is only via the stale-gated `clearAllocation`/`clearAccount`). Across-submit
///         monotonicity (`AmountRegression`) is enforced. Batching a user's tokens in one call is a convenience.
contract MerklRewardsAttestedBalanceAdapterTest is BalanceAdapterTestBase {
    MerklRewardsAttestedBalanceAdapter public adapter;
    MockMerklDistributor public distributor;

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

        // Permissionless: no admin/assistant roles.
        adapter = new MerklRewardsAttestedBalanceAdapter(address(distributor), address(balances));
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

    /// @dev Wrap a single (token, amount, proof) into a submit. Submit is UPSERT semantics — this adds/refreshes just
    ///      this one (user, token) and leaves any other cached tokens untouched. Permissionless — any caller works.
    function _submitOne(address user, address token, uint256 amount, bytes32[] memory proof) internal {
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: token,
            cumulativeAmount: amount,
            proof: proof,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        adapter.submitProofs(user, allocs);
    }

    /// @dev Submit several (token, amount, proof) entries for one user in one call. Upsert semantics — each entry
    ///      adds/refreshes its (user, token); batching in one call is a convenience, not a requirement.
    function _submitMany(address user, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs)
        internal
    {
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            allocs[i] = MerklRewardsAttestedBalanceAdapter.Allocation({
                token: tokens[i],
                cumulativeAmount: amounts[i],
                proof: proofs[i],
                campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
            });
        }
        adapter.submitProofs(user, allocs);
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructor_revertsOnZeroDistributor() public {
        vm.expectRevert(InvalidArguments.selector);
        new MerklRewardsAttestedBalanceAdapter(address(0), address(balances));
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new MerklRewardsAttestedBalanceAdapter(address(distributor), address(0));
    }

    function test_constructor_revertsOnNonContractDistributor() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "Distributor"));
        new MerklRewardsAttestedBalanceAdapter(makeAddr("eoa"), address(balances));
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new MerklRewardsAttestedBalanceAdapter(address(distributor), makeAddr("eoa"));
    }

    function test_constructor_setsImmutableState() public view {
        assertEq(adapter.DISTRIBUTOR(), address(distributor));
        assertEq(address(adapter.NAV_CALCULATOR()), address(balances));
    }

    // ============================================
    // ERC165 + interface
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAttestedBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        // No AccessControl anymore — permissionless.
        assertFalse(adapter.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_protocolName() public view {
        assertEq(adapter.protocolName(), "Merkl");
    }

    function test_positionLabels() public view {
        string[] memory labels = adapter.positionLabels("");
        assertEq(labels.length, 1);
        assertEq(labels[0], "Claimable Rewards");
    }

    function test_underlyingAssetsSupported_returnsEmpty() public view {
        assertEq(adapter.underlyingAssetsSupported().length, 0);
    }

    // ============================================
    // submitProofs — permissionless
    // ============================================

    /// @notice Anyone can submit — no role required. An arbitrary caller submits a real (proof-verified) allocation.
    function test_submitProofs_permissionless_arbitraryCaller() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(arb),
            cumulativeAmount: 100 ether,
            proof: new bytes32[](0),
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        // The event attributes the actual caller (stranger), not the beneficiary user (alice) — this is the
        // off-chain monitoring hook for a third-party (potentially griefing) submitter on a permissionless write.
        vm.expectEmit(true, true, true, true, address(adapter));
        emit MerklRewardsAttestedBalanceAdapter.AllocationCached(
            alice, address(arb), stranger, 100 ether, leaf, uint64(block.timestamp), 0
        );
        vm.prank(stranger);
        adapter.submitProofs(alice, allocs);

        (uint256 amt,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 100 ether);
    }

    /// @notice Permissionless does NOT weaken integrity: an arbitrary caller cannot fabricate an amount — a bad proof
    ///         still reverts InvalidProof regardless of who calls.
    function test_submitProofs_permissionless_cannotFabricateAmount() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(arb),
            cumulativeAmount: 999 ether, // fabricated — not the leaf amount
            proof: new bytes32[](0),
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.InvalidProof.selector);
        vm.prank(stranger);
        adapter.submitProofs(alice, allocs);
    }

    // ============================================
    // submitProofs — happy path
    // ============================================

    function test_submitProofs_singleLeafTree() public {
        // Single-leaf tree: root = leaf, proof = [].
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);

        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));

        (uint256 amt, bytes32 root, uint64 ts) = adapter.allocations(alice, address(arb));
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

        (uint256 amt, bytes32 cachedRoot,) = adapter.allocations(alice, address(arb));
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

        vm.expectEmit(true, true, true, true, address(adapter));
        emit MerklRewardsAttestedBalanceAdapter.AllocationCached(
            alice, address(arb), address(this), 100 ether, leaf, uint64(block.timestamp), 0
        );
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));
    }

    /// @notice UPSERT semantics (not replace): a submit that OMITS a token leaves that token's live entry intact — a
    ///         caller can never suppress a live allocation by omitting it (removal is only via the stale-gated
    ///         `clearAllocation`/`clearAccount`). This is the fix for the permissionless-suppression finding.
    function test_submitProofs_upsertKeepsOmittedTokens() public {
        // Seed alice with {ARB, OP} under one root.
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

        // Re-submit ONLY {OP} against the SAME (still-live) root — an upsert of OP; ARB is NOT dropped.
        _submitOne(alice, address(op), 50 ether, p1);

        assertEq(adapter.userTokens(alice).length, 2, "omitted token NOT dropped (upsert, not replace)");
        (uint256 arbAmt,,) = adapter.allocations(alice, address(arb));
        assertEq(arbAmt, 100 ether, "omitted ARB entry left intact");
    }

    /// @notice A third party cannot suppress a victim's live rewards with an empty (or partial) submit — the upsert
    ///         never clears. (The old `_replace` clear-first design let `submitProofs(victim, [])` wipe the set.)
    function test_submitProofs_emptyListCannotSuppressLive() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));
        assertEq(adapter.userTokens(alice).length, 1);

        // Attacker submits an EMPTY list for alice — a no-op, not a wipe.
        vm.prank(makeAddr("attacker"));
        adapter.submitProofs(alice, new MerklRewardsAttestedBalanceAdapter.Allocation[](0));

        assertEq(adapter.userTokens(alice).length, 1, "empty submit must not drop live entries");
        (uint256 amt,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 100 ether, "live ARB entry untouched by third-party empty submit");
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

        (uint256 amt, bytes32 cachedRoot, uint64 ts) = adapter.allocations(alice, address(arb));
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
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.UninitializedRoot.selector);
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));
    }

    function test_submitProofs_revertsOnInvalidProof_wrongAmount() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.InvalidProof.selector);
        _submitOne(alice, address(arb), 999 ether, new bytes32[](0));
    }

    function test_submitProofs_revertsOnInvalidProof_wrongUser() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.InvalidProof.selector);
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

        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.InvalidProof.selector);
        _submitOne(alice, address(arb), 100 ether, proof);
    }

    /// @notice The `AmountRegression` guard rejects a decreasing cumulative — both a DUPLICATE token within one list
    ///         (this test) and across submits (now that upsert no longer clears the prior entry; see below).
    function test_submitProofs_revertsOnWithinListRegression() public {
        // Tree containing both leaf(alice, ARB, 100) and leaf(alice, ARB, 50) so both proofs verify against one root.
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, address(arb), 100 ether);
        leaves[1] = _leaf(alice, address(arb), 50 ether);
        (bytes32 root, bytes32[] memory p0) = _buildTree2(leaves, 0);
        (, bytes32[] memory p1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);

        // Same token twice, decreasing: the second entry trips AmountRegression.
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](2);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(arb),
            cumulativeAmount: 100 ether,
            proof: p0,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        allocs[1] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(arb),
            cumulativeAmount: 50 ether,
            proof: p1,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.AmountRegression.selector);
        adapter.submitProofs(alice, allocs);
    }

    /// @notice Under UPSERT, a new submit with a lower cumulative than the cached one REVERTS `AmountRegression`
    ///         (the prior entry is no longer cleared first). A legitimately lower value only arises after a root
    ///         rotation, which makes the cached entry stale (reads 0) and clearable — so the keeper clears, then
    ///         resubmits. This test proves both halves.
    function test_submitProofs_lowerAmountAcrossSubmitsRevertsThenClearable() public {
        bytes32 leaf1 = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf1);
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));

        // Root rotates to a tree where ARB's cumulative is lower.
        bytes32 leaf2 = _leaf(alice, address(arb), 50 ether);
        distributor.setRoot(leaf2);

        // Direct resubmit is rejected — 50 < cached 100.
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.AmountRegression.selector);
        _submitOne(alice, address(arb), 50 ether, new bytes32[](0));

        // The cached entry is stale (cached root != live root) → reads 0 → clearable; then the lower value lands.
        adapter.clearAllocation(alice, address(arb));
        _submitOne(alice, address(arb), 50 ether, new bytes32[](0));
        (uint256 amt,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 50 ether);
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
        MerklRewardsAttestedBalanceAdapter.Allocation[][] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[][](2);

        // alice: ARB (leaf 0) + OP (leaf 2)
        users[0] = alice;
        allocs[0] = new MerklRewardsAttestedBalanceAdapter.Allocation[](2);
        (, bytes32[] memory aArb) = _buildTree4(leaves, 0);
        (, bytes32[] memory aOp) = _buildTree4(leaves, 2);
        allocs[0][0] = MerklRewardsAttestedBalanceAdapter.Allocation(
            address(arb), 100 ether, aArb, new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        );
        allocs[0][1] = MerklRewardsAttestedBalanceAdapter.Allocation(
            address(op), 50 ether, aOp, new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        );

        // bob: ARB (leaf 1) + OP (leaf 3)
        users[1] = bob;
        allocs[1] = new MerklRewardsAttestedBalanceAdapter.Allocation[](2);
        (, bytes32[] memory bArb) = _buildTree4(leaves, 1);
        (, bytes32[] memory bOp) = _buildTree4(leaves, 3);
        allocs[1][0] = MerklRewardsAttestedBalanceAdapter.Allocation(
            address(arb), 200 ether, bArb, new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        );
        allocs[1][1] = MerklRewardsAttestedBalanceAdapter.Allocation(
            address(op), 75 ether, bOp, new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        );

        adapter.submitProofsBatch(users, allocs);

        assertEq(adapter.userTokens(alice).length, 2);
        assertEq(adapter.userTokens(bob).length, 2);
    }

    function test_submitProofsBatch_revertsOnLengthMismatch() public {
        address[] memory users = new address[](2);
        MerklRewardsAttestedBalanceAdapter.Allocation[][] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[][](1); // mismatch

        vm.expectRevert(InvalidArguments.selector);
        adapter.submitProofsBatch(users, allocs);
    }

    // ============================================
    // clearAllocation — stale-gated GC
    // ============================================

    function _seedAllocation(address user, address token, uint256 amount) internal {
        bytes32 leaf = _leaf(user, token, amount);
        distributor.setRoot(leaf);
        _submitOne(user, token, amount, new bytes32[](0));
    }

    /// @notice A stale (root-rotated) entry contributes 0 to NAV, so it can be cleared: the cache zeroes and the token
    ///         drops off the enumeration list.
    function test_clearAllocation_removesStaleEntry() public {
        _seedAllocation(alice, address(arb), 100 ether);
        // Root rotates → entry is stale → unclaimed reads 0 → clearable.
        distributor.setRoot(keccak256("rotated root"));

        adapter.clearAllocation(alice, address(arb));

        (uint256 amt, bytes32 root, uint64 ts) = adapter.allocations(alice, address(arb));
        assertEq(amt, 0);
        assertEq(root, ZERO);
        assertEq(ts, 0);
        assertEq(adapter.userTokens(alice).length, 0);
    }

    /// @notice A fully-claimed entry contributes 0 to NAV, so it can be cleared.
    function test_clearAllocation_removesFullyClaimedEntry() public {
        _seedAllocation(alice, address(arb), 100 ether);
        // Fully claimed → unclaimed 0 → clearable even with a live root.
        distributor.setClaimed(alice, address(arb), uint208(100 ether), uint48(block.timestamp), bytes32(0));

        adapter.clearAllocation(alice, address(arb));

        assertEq(adapter.userTokens(alice).length, 0);
        (uint256 amt,,) = adapter.allocations(alice, address(arb));
        assertEq(amt, 0);
    }

    /// @notice A LIVE entry (fresh root, unclaimed > 0) cannot be cleared — it can only be *replaced* via submit. This
    ///         is the stale-gate that makes the permissionless clear safe (the fix for the old ASSISTANT_ROLE L-02
    ///         vector: no caller can zero out another account's valid reward).
    function test_clearAllocation_revertsWhenLive() public {
        _seedAllocation(alice, address(arb), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(MerklRewardsAttestedBalanceAdapter.AllocationStillLive.selector, alice, address(arb))
        );
        adapter.clearAllocation(alice, address(arb));
    }

    /// @notice Clearing a (user, token) with nothing cached reverts NothingToClear.
    function test_clearAllocation_revertsNothingToClear() public {
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.NothingToClear.selector);
        adapter.clearAllocation(alice, address(arb));
    }

    function test_clearAllocation_revertsOnZeroArgs() public {
        vm.expectRevert(InvalidArguments.selector);
        adapter.clearAllocation(address(0), address(arb));

        vm.expectRevert(InvalidArguments.selector);
        adapter.clearAllocation(alice, address(0));
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

        // Make OP clearable by fully claiming it (unclaimed → 0), then clear it (the middle one).
        // Expect swap-and-pop: list becomes [arb, morpho].
        distributor.setClaimed(alice, address(op), uint208(50 ether), uint48(block.timestamp), bytes32(0));
        adapter.clearAllocation(alice, address(op));

        address[] memory after_ = adapter.userTokens(alice);
        assertEq(after_.length, 2);
        assertEq(after_[0], address(arb));
        assertEq(after_[1], address(morpho));
    }

    // ============================================
    // clearAccount — stale-gated bulk GC
    // ============================================

    /// @dev Seed alice with {ARB, OP} in one replace submit against a shared 2-leaf tree root.
    function _seedTwoTokens(address user, uint256 arbAmt, uint256 opAmt) internal returns (bytes32 root) {
        bytes32[2] memory leaves;
        leaves[0] = _leaf(user, address(arb), arbAmt);
        leaves[1] = _leaf(user, address(op), opAmt);
        bytes32[] memory p0;
        bytes32[] memory p1;
        (root, p0) = _buildTree2(leaves, 0);
        (, p1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        tokens[0] = address(arb);
        amounts[0] = arbAmt;
        proofs[0] = p0;
        tokens[1] = address(op);
        amounts[1] = opAmt;
        proofs[1] = p1;
        _submitMany(user, tokens, amounts, proofs);
    }

    /// @notice An account with ≥2 tokens, at least one still live (fresh root, unclaimed > 0), cannot be bulk-cleared —
    ///         reverts AllocationStillLive on the first live token. This is the stale-gate that prevents a third party
    ///         from suppressing a live reward set.
    function test_clearAccount_revertsWhenAnyLive() public {
        _seedTwoTokens(alice, 100 ether, 50 ether);
        // Make OP dead (fully claimed) but leave ARB live → the first live token trips the gate.
        distributor.setClaimed(alice, address(op), uint208(50 ether), uint48(block.timestamp), bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(MerklRewardsAttestedBalanceAdapter.AllocationStillLive.selector, alice, address(arb))
        );
        adapter.clearAccount(alice);

        // Nothing removed — the set is intact.
        assertEq(adapter.userTokens(alice).length, 2);
    }

    /// @notice When every token is dead (mix of stale-root and fully-claimed), clearAccount wipes the whole set, emits
    ///         AccountCleared, and afterward userTokens/getAdapterBalances/getAdapterPositions are empty.
    function test_clearAccount_clearsWhenAllDead() public {
        _seedTwoTokens(alice, 100 ether, 50 ether);
        // Kill OP by fully claiming it; kill ARB by rotating the root (both entries now read 0).
        distributor.setClaimed(alice, address(op), uint208(50 ether), uint48(block.timestamp), bytes32(0));
        distributor.setRoot(keccak256("rotated root"));

        vm.expectEmit(true, false, false, false, address(adapter));
        emit MerklRewardsAttestedBalanceAdapter.AccountCleared(alice);
        adapter.clearAccount(alice);

        assertEq(adapter.userTokens(alice).length, 0);

        (uint256 arbAmt,,) = adapter.allocations(alice, address(arb));
        assertEq(arbAmt, 0);
        (uint256 opAmt,,) = adapter.allocations(alice, address(op));
        assertEq(opAmt, 0);

        (address[] memory assets, uint256[] memory amounts,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    /// @notice Bulk-clearing a never-cached account reverts NothingToClear.
    function test_clearAccount_revertsNothingToClear() public {
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.NothingToClear.selector);
        adapter.clearAccount(alice);
    }

    /// @notice address(0) reverts InvalidArguments.
    function test_clearAccount_revertsOnZeroAccount() public {
        vm.expectRevert(InvalidArguments.selector);
        adapter.clearAccount(address(0));
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

    /// @dev Build a 1-token Allocation with the given campaign breakdown and submit it (root set to the token leaf,
    ///      empty proof verifies the single-leaf tree).
    function _submitWithCampaigns(
        address user,
        address token,
        uint256 tokenCumulative,
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares
    ) internal {
        bytes32 leaf = _leaf(user, token, tokenCumulative);
        distributor.setRoot(leaf);
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: token, cumulativeAmount: tokenCumulative, proof: new bytes32[](0), campaigns: shares
        });
        adapter.submitProofs(user, allocs);
    }

    function test_positionInstanceId_carriesCampaignPair() public {
        bytes32 cid = keccak256("merkl-campaign-1");
        bytes32 sub = keccak256("merkl-subcampaign-1");
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares =
            new MerklRewardsAttestedBalanceAdapter.CampaignShare[](1);
        shares[0] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
            campaignId: cid, subCampaignId: sub, cumulativeAmount: 100 ether
        });
        _submitWithCampaigns(alice, address(arb), 100 ether, shares);

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 1);
        // One campaign covering the whole token → the full proof-verified unclaimed, tagged with the pair.
        assertEq(pos[0].amount, 100 ether);
        assertEq(
            pos[0].positionInstanceId,
            keccak256(abi.encode(cid, sub)),
            "positionInstanceId = keccak256(abi.encode(campaignId, subCampaignId))"
        );
    }

    function test_positionInstanceId_zeroWhenNoCampaignSubmitted() public {
        _seedAllocation(alice, address(arb), 100 ether); // empty campaign breakdown
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 1);
        assertEq(pos[0].positionInstanceId, bytes32(0), "no campaign submitted -> bytes32(0)");
    }

    function test_multipleCampaigns_splitProRataByShare() public {
        bytes32 cidA = keccak256("campaign-A");
        bytes32 cidB = keccak256("campaign-B");
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares =
            new MerklRewardsAttestedBalanceAdapter.CampaignShare[](2);
        shares[0] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
            campaignId: cidA, subCampaignId: ZERO, cumulativeAmount: 60 ether
        });
        shares[1] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
            campaignId: cidB, subCampaignId: ZERO, cumulativeAmount: 40 ether
        });
        _submitWithCampaigns(alice, address(arb), 100 ether, shares); // Σ shares == 100 ether == token total

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 2, "one leg per campaign");
        assertEq(pos[0].amount, 60 ether);
        assertEq(pos[0].positionInstanceId, keccak256(abi.encode(cidA, ZERO)));
        assertEq(pos[1].amount, 40 ether);
        assertEq(pos[1].positionInstanceId, keccak256(abi.encode(cidB, ZERO)));
        // Legs sum to the proof-verified per-token unclaimed total.
        assertEq(pos[0].amount + pos[1].amount, 100 ether);
    }

    /// @dev The pro-rata split against a PARTIALLY-CLAIMED token — the only case in which `_appendTokenLegs`'
    ///      `Math.mulDiv` actually divides. Every other campaign test leaves `claimed` at 0, where
    ///      `unclaimed == tokenCumulative` and `mulDiv(unclaimed, share, tokenCumulative)` collapses to `share`
    ///      exactly, so the numerator and the denominator are indistinguishable and an over-reporting mutation is
    ///      numerically invisible. Here 70 of a 100 cumulative is already claimed, so the 60/40 split must be applied
    ///      to the 30 UNCLAIMED — legs of 18 + 12, not 60 + 40. Substituting the cached cumulative for `unclaimed` in
    ///      that numerator emits 60 + 40 = 100 against a real balance of 30: a 3.3x OVER-report, the one direction
    ///      this family forbids. Verified to fail with that mutation applied.
    function test_multipleCampaigns_splitProRataAgainstPartiallyClaimed() public {
        bytes32 cidA = keccak256("campaign-A");
        bytes32 cidB = keccak256("campaign-B");
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares =
            new MerklRewardsAttestedBalanceAdapter.CampaignShare[](2);
        shares[0] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
            campaignId: cidA, subCampaignId: ZERO, cumulativeAmount: 60 ether
        });
        shares[1] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
            campaignId: cidB, subCampaignId: ZERO, cumulativeAmount: 40 ether
        });
        _submitWithCampaigns(alice, address(arb), 100 ether, shares);
        // 70 of the 100 proven cumulative is already claimed on-chain ⇒ 30 unclaimed left to split 60/40.
        distributor.setClaimed(alice, address(arb), uint208(70 ether), uint48(block.timestamp), bytes32(0));

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 2, "one leg per campaign");
        assertEq(pos[0].amount, 18 ether, "60% of the 30 unclaimed, NOT 60% of the 100 cumulative");
        assertEq(pos[0].positionInstanceId, keccak256(abi.encode(cidA, ZERO)));
        assertEq(pos[1].amount, 12 ether, "40% of the 30 unclaimed");
        assertEq(pos[1].positionInstanceId, keccak256(abi.encode(cidB, ZERO)));
        // The legs must sum to the token's unclaimed total, never to its cumulative.
        assertEq(pos[0].amount + pos[1].amount, 30 ether, "legs sum to unclaimed, not cumulative");
        (uint256 whole,) = adapter.getAdapterBalanceForAsset(alice, address(arb));
        assertEq(pos[0].amount + pos[1].amount, whole, "split legs agree with the single-asset getter");
    }

    /// @dev `mulDiv` floors, so an indivisible split under-reports by dust and NEVER over-reports. 100 unclaimed
    ///      across three equal shares of a 300 cumulative gives 33 + 33 + 33 = 99 ≤ 100.
    function test_multipleCampaigns_roundingDownNeverExceedsUnclaimed() public {
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares =
            new MerklRewardsAttestedBalanceAdapter.CampaignShare[](3);
        for (uint256 i; i < 3; ++i) {
            shares[i] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
                campaignId: keccak256(abi.encode("c", i)), subCampaignId: ZERO, cumulativeAmount: 100
            });
        }
        _submitWithCampaigns(alice, address(arb), 300, shares);
        distributor.setClaimed(alice, address(arb), uint208(200), uint48(block.timestamp), bytes32(0));

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        uint256 sum;
        for (uint256 i; i < pos.length; ++i) {
            sum += pos[i].amount;
        }
        assertEq(sum, 99, "33+33+33: one wei of dust dropped by flooring");
        assertLe(sum, 100, "legs must never exceed the token's unclaimed total");
    }

    function test_submit_revertsWhenCampaignSharesDontSumToTotal() public {
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares =
            new MerklRewardsAttestedBalanceAdapter.CampaignShare[](2);
        shares[0] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
            campaignId: keccak256("a"), subCampaignId: ZERO, cumulativeAmount: 60 ether
        });
        shares[1] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
            campaignId: keccak256("b"), subCampaignId: ZERO, cumulativeAmount: 30 ether
        }); // sum 90 != 100
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(arb), cumulativeAmount: 100 ether, proof: new bytes32[](0), campaigns: shares
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                MerklRewardsAttestedBalanceAdapter.CampaignSumMismatch.selector, address(arb), 90 ether, 100 ether
            )
        );
        adapter.submitProofs(alice, allocs);
    }

    /// @dev The campaign cap is the one attacker-controlled read-fan-out amplifier (campaign ids are not proof-bound),
    ///      so it must be enforced fail-loud. `MAX_CAMPAIGNS_PER_TOKEN + 1` shares for one token reverts.
    function test_submit_revertsWhenTooManyCampaigns() public {
        uint256 over = adapter.MAX_CAMPAIGNS_PER_TOKEN() + 1;
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares =
            new MerklRewardsAttestedBalanceAdapter.CampaignShare[](over);
        for (uint256 i; i < over; ++i) {
            shares[i] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
                campaignId: keccak256(abi.encode("c", i)), subCampaignId: ZERO, cumulativeAmount: 1 ether
            });
        }
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(arb), cumulativeAmount: 100 ether, proof: new bytes32[](0), campaigns: shares
        });
        // The count check fires before the sum check, so a mismatched sum is irrelevant here.
        vm.expectRevert(
            abi.encodeWithSelector(MerklRewardsAttestedBalanceAdapter.TooManyCampaigns.selector, address(arb), over)
        );
        adapter.submitProofs(alice, allocs);
    }

    /// @dev Exactly `MAX_CAMPAIGNS_PER_TOKEN` shares is accepted (boundary) and yields one leg per share.
    function test_submit_acceptsExactlyMaxCampaigns() public {
        uint256 max = adapter.MAX_CAMPAIGNS_PER_TOKEN();
        uint256 total = max * 1 ether;
        MerklRewardsAttestedBalanceAdapter.CampaignShare[] memory shares =
            new MerklRewardsAttestedBalanceAdapter.CampaignShare[](max);
        for (uint256 i; i < max; ++i) {
            shares[i] = MerklRewardsAttestedBalanceAdapter.CampaignShare({
                campaignId: keccak256(abi.encode("c", i)), subCampaignId: ZERO, cumulativeAmount: 1 ether
            });
        }
        _submitWithCampaigns(alice, address(arb), total, shares); // Σ shares == total
        assertEq(adapter.getAdapterPositions(alice, address(0)).length, max, "one leg per share at the cap");
    }

    // ============================================
    // MAX_TOKENS_PER_USER — the per-account slot cap
    // ============================================

    /// @dev Fills `alice`'s token cache to exactly `MAX_TOKENS_PER_USER`, one synthetic token per single-leaf root.
    ///      Each submit rotates the mock root to that token's own leaf, so earlier entries go stale — which is the
    ///      point: a stale entry still OCCUPIES its slot (only the stale-gated `clearAllocation` frees one), so the
    ///      cap is reached by accumulation across roots, not only by a large simultaneous footprint.
    ///      Synthetic (non-contract) token addresses are fine here: the adapter never calls the reward token, and the
    ///      cap is enforced purely on `_userTokens` length.
    function _fillTokenCache(address user, uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            address token = address(uint160(0xDEAD0000 + i));
            bytes32 leaf = _leaf(user, token, 1 ether);
            distributor.setRoot(leaf);
            _submitOne(user, token, 1 ether, new bytes32[](0));
        }
    }

    /// @dev A NEW token beyond `MAX_TOKENS_PER_USER` reverts fail-loud. This is the cap ADR 0022's read-gas argument
    ///      rests on, and it was previously untested — a `>=` vs `>` slip here would silently ship an off-by-one.
    function test_submit_revertsWhenTooManyTokens() public {
        uint256 max = adapter.MAX_TOKENS_PER_USER();
        _fillTokenCache(alice, max);
        assertEq(adapter.userTokens(alice).length, max, "cache filled to the cap");

        address oneTooMany = address(uint160(0xBEEF0001));
        bytes32 leaf = _leaf(alice, oneTooMany, 1 ether);
        distributor.setRoot(leaf);
        vm.expectRevert(abi.encodeWithSelector(MerklRewardsAttestedBalanceAdapter.TooManyTokens.selector, alice, max));
        _submitOne(alice, oneTooMany, 1 ether, new bytes32[](0));
    }

    /// @dev Exactly `MAX_TOKENS_PER_USER` is accepted (boundary), and at the cap a REFRESH of an already-cached token
    ///      still lands — the cap gates new slots only. Also pins the blast radius the cap creates: because a submit
    ///      is atomic over its whole list, one new-token entry at the cap reverts the refresh of the others too.
    function test_submit_atCapRefreshesExistingButRejectsNew() public {
        uint256 max = adapter.MAX_TOKENS_PER_USER();
        _fillTokenCache(alice, max);

        // Refresh of an existing token at the cap: no new slot, so it succeeds.
        address existing = address(uint160(0xDEAD0000));
        bytes32 refreshLeaf = _leaf(alice, existing, 5 ether);
        distributor.setRoot(refreshLeaf);
        _submitOne(alice, existing, 5 ether, new bytes32[](0));
        (uint256 amt,,) = adapter.allocations(alice, existing);
        assertEq(amt, 5 ether, "refresh at the cap lands");
        assertEq(adapter.userTokens(alice).length, max, "refresh consumes no slot");

        // A two-entry submit whose SECOND entry is a new token at the cap reverts atomically — the first entry's
        // refresh is rolled back with it. This is the keeper-wedge shape: nothing gets refreshed.
        address newToken = address(uint160(0xBEEF0002));
        bytes32[2] memory leaves;
        leaves[0] = _leaf(alice, existing, 9 ether);
        leaves[1] = _leaf(alice, newToken, 1 ether);
        (bytes32 root, bytes32[] memory p0) = _buildTree2(leaves, 0);
        (, bytes32[] memory p1) = _buildTree2(leaves, 1);
        distributor.setRoot(root);

        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](2);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: existing,
            cumulativeAmount: 9 ether,
            proof: p0,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        allocs[1] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: newToken,
            cumulativeAmount: 1 ether,
            proof: p1,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(MerklRewardsAttestedBalanceAdapter.TooManyTokens.selector, alice, max));
        adapter.submitProofs(alice, allocs);

        (uint256 after_,,) = adapter.allocations(alice, existing);
        assertEq(after_, 5 ether, "the whole submit rolled back: the co-listed refresh did NOT land");
    }

    /// @dev The `_userTokens` no-duplicate invariant, which is the ONLY double-count mechanism in this contract: a
    ///      token present twice in the enumeration list would make `buildPositionsSelf` value it twice and OVER-report
    ///      NAV — the one direction the family forbids. Re-submitting the same `(user, token)` many times, across a
    ///      root rotation, must never grow the list. The presence sentinel is `root != 0`, enforced by the contract's
    ///      own `UninitializedRoot` check, rather than `submittedAt != 0`, which would rest on `block.timestamp != 0`.
    function test_submit_repeatedSubmitsNeverDuplicateUserTokens() public {
        uint256 amount = 100 ether;
        for (uint256 i; i < 5; ++i) {
            amount += 1 ether; // monotonic, so the AmountRegression guard is not what is being tested
            bytes32 leaf = _leaf(alice, address(arb), amount);
            distributor.setRoot(leaf); // rotate the root each time
            _submitOne(alice, address(arb), amount, new bytes32[](0));
            assertEq(adapter.userTokens(alice).length, 1, "re-submit must never push a second slot");
        }

        // And the read values it exactly once — no double count.
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 1, "one untagged leg, counted once");
        assertEq(pos[0].amount, amount, "reported once, not twice");
        (uint256 bal,) = adapter.getAdapterBalanceForAsset(alice, address(arb));
        assertEq(bal, amount);
    }

    /// @dev A `block.timestamp == 0` chain/test environment must not break the presence sentinel. With `submittedAt`
    ///      as the sentinel this pushed a duplicate slot on the second submit (over-report); keyed on `root` it cannot.
    function test_submit_atZeroTimestampStillNeverDuplicates() public {
        vm.warp(0);
        bytes32 leaf = _leaf(alice, address(arb), 100 ether);
        distributor.setRoot(leaf);
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0));
        _submitOne(alice, address(arb), 100 ether, new bytes32[](0)); // same root, same amount — a pure refresh
        assertEq(adapter.userTokens(alice).length, 1, "no duplicate slot even with submittedAt == 0");

        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        assertEq(pos.length, 1, "valued once");
        assertEq(pos[0].amount, 100 ether);
    }

    /// @dev An account with nothing cached returns an empty set WITHOUT paying for the row-building self-call or the
    ///      whole-registry `getRegisteredAssets()` copy inside it. Pinned by gas because the early return is a
    ///      performance guard, and this adapter is queried for EVERY account on every NAV read.
    function test_getAdapterPositions_emptyCacheIsCheap() public view {
        uint256 before = gasleft();
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositions(alice, address(0));
        uint256 used = before - gasleft();
        assertEq(pos.length, 0);
        assertLt(used, 20_000, "empty cache must short-circuit before the registry fetch");
    }
}
