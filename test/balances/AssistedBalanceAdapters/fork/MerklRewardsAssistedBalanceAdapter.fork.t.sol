// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    MerklRewardsAssistedBalanceAdapter,
    IMerklDistributor
} from "src/balances/AssistedBalanceAdapters/MerklRewardsAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title MerklRewardsAssistedBalanceAdapterForkTest
/// @notice Fork tests for `MerklRewardsAssistedBalanceAdapter`. Validates the adapter integrates cleanly with the real
///         Merkl Distributor on Ethereum mainnet — `getMerkleRoot()` returns non-zero, the public `claimed`
///         getter works, invalid proofs revert, and uncached reads return 0. The merkle proof-verification math
///         itself is exhaustively tested with synthetic trees in `MerklRewardsAssistedBalanceAdapter.t.sol`; capturing a real proof at
///         a pinned block is brittle (Merkl rotates roots ~every 8h) and is left as a future enhancement.
contract MerklRewardsAssistedBalanceAdapterForkTest is BalanceAdapterTestBase {
    /// @notice Merkl Distributor — same address on every supported EVM chain.
    address public constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    /// @notice Pin a recent stable block. Update via `script/test/refresh-integration-snapshot.sh`-style flow if needed.
    uint256 public constant FORK_BLOCK = 21_395_285;

    address public owner = makeAddr("merkl-owner");
    address public alice = makeAddr("alice");

    MerklRewardsAssistedBalanceAdapter public adapter;

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        balances = _deployBalancesForAdapter(MAINNET_DAI); // any registered asset; ARB isn't on Mainnet's NAV
        // admin = assistant = `owner`.
        adapter = new MerklRewardsAssistedBalanceAdapter(MERKL_DISTRIBUTOR, address(balances), owner, owner);
    }

    // ============================================
    // Real Distributor sanity
    // ============================================

    function test_distributor_isContractAtExpectedAddress() public view {
        assertGt(MERKL_DISTRIBUTOR.code.length, 0, "Distributor should be a deployed contract");
    }

    function test_distributor_getMerkleRoot_returnsNonZero() public view {
        bytes32 root = IMerklDistributor(MERKL_DISTRIBUTOR).getMerkleRoot();
        assertTrue(root != bytes32(0), "Merkl root should be initialized at the pinned block");
    }

    function test_distributor_claimedGetter_works() public view {
        // Reads against an arbitrary (user, token) pair. The user is unlikely to have claimed anything; we just
        // assert the public getter doesn't revert and returns sensible-shaped values.
        (uint208 amount, uint48 timestamp, bytes32 merkleRoot) =
            IMerklDistributor(MERKL_DISTRIBUTOR).claimed(alice, MAINNET_DAI);
        assertEq(amount, 0);
        assertEq(timestamp, 0);
        assertEq(merkleRoot, bytes32(0));
    }

    // ============================================
    // Adapter integration
    // ============================================

    function test_adapter_immutableStateMatchesConstructor() public view {
        assertEq(adapter.DISTRIBUTOR(), MERKL_DISTRIBUTOR);
        assertEq(address(adapter.NAV_CALCULATOR()), address(balances));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(adapter.hasRole(adapter.ASSISTANT_ROLE(), owner));
    }

    function test_adapter_uncachedReadReturnsZero() public view {
        (uint256 amt, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, MAINNET_DAI);
        assertEq(amt, 0);
        assertFalse(isDebt);
    }

    function test_adapter_emptyPositionsForFreshAccount() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_adapter_invalidProofRevertsAgainstRealRoot() public {
        // Build a leaf that is virtually guaranteed not to be in the active tree, then submit it with an
        // empty proof. The adapter should run real proof verification against the real on-chain root and revert.
        MerklRewardsAssistedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAssistedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAssistedBalanceAdapter.Allocation({
            token: MAINNET_DAI,
            cumulativeAmount: 1_000_000 ether,
            proof: new bytes32[](0),
            campaigns: new MerklRewardsAssistedBalanceAdapter.CampaignShare[](0)
        });
        vm.expectRevert(MerklRewardsAssistedBalanceAdapter.InvalidProof.selector);
        vm.prank(owner);
        adapter.submitProofs(alice, allocs);
    }

    function test_adapter_uninitializedRootGuardWithRealDistributor() public view {
        // Real distributor's root is non-zero at this block; this test sanity-checks the contrapositive: when we
        // change nothing, the UninitializedRoot path is not reachable (otherwise our `submitProofs` test above
        // would have hit it before the proof check). Here we just assert non-zero root at the pinned block.
        assertTrue(IMerklDistributor(MERKL_DISTRIBUTOR).getMerkleRoot() != bytes32(0));
    }
}
