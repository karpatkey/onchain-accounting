// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {
    MerklRewardsAttestedBalanceAdapter,
    IMerklDistributor
} from "src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title MerklRewardsAttestedBalanceAdapterForkTest
/// @notice Fork tests for `MerklRewardsAttestedBalanceAdapter`. Validates the adapter integrates cleanly with the real
///         Merkl Distributor on Ethereum mainnet — `getMerkleRoot()` returns non-zero, the public `claimed`
///         getter works, invalid proofs revert, and uncached reads return 0. The merkle proof-verification math
///         itself is exhaustively tested with synthetic trees in `MerklRewardsAttestedBalanceAdapter.t.sol`. A companion
///         contract in this file (`MerklRewardsAttestedBalanceAdapterRealProofForkTest`) closes the last gap by submitting a
///         REAL captured allocation + proof against the live root, proving our leaf encoding matches Merkl's.
contract MerklRewardsAttestedBalanceAdapterForkTest is BalanceAdapterTestBase {
    /// @notice Merkl Distributor — same address on every supported EVM chain.
    address public constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    /// @notice Pin a recent stable block. Update via `script/test/refresh-integration-snapshot.sh`-style flow if needed.
    uint256 public constant FORK_BLOCK = 21_395_285;

    address public alice = makeAddr("alice");

    MerklRewardsAttestedBalanceAdapter public adapter;

    function _setupFork() internal override {
        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), FORK_BLOCK);
        balances = _deployBalancesForAdapter(MAINNET_DAI); // any registered asset; ARB isn't on Mainnet's NAV
        // Permissionless: no admin/assistant roles.
        adapter = new MerklRewardsAttestedBalanceAdapter(MERKL_DISTRIBUTOR, address(balances));
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
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: MAINNET_DAI,
            cumulativeAmount: 1_000_000 ether,
            proof: new bytes32[](0),
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        vm.expectRevert(MerklRewardsAttestedBalanceAdapter.InvalidProof.selector);
        adapter.submitProofs(alice, allocs);
    }

    function test_adapter_uninitializedRootGuardWithRealDistributor() public view {
        // Real distributor's root is non-zero at this block; this test sanity-checks the contrapositive: when we
        // change nothing, the UninitializedRoot path is not reachable (otherwise our `submitProofs` test above
        // would have hit it before the proof check). Here we just assert non-zero root at the pinned block.
        assertTrue(IMerklDistributor(MERKL_DISTRIBUTOR).getMerkleRoot() != bytes32(0));
    }
}

/// @title MerklRewardsAttestedBalanceAdapterRealProofForkTest
/// @notice End-to-end proof against the REAL live Merkl Distributor root: submits a genuine captured allocation +
///         merkle proof (from `test/integration/merkl-proofs.json`, mainnet chain 1) and asserts the adapter accepts
///         it and reports `cumulative − claimed`. This is the assertion that catches a leaf-encoding mismatch between
///         our `keccak256(abi.encode(user, token, cumulativeAmount))` + sorted-pair hashing and what Merkl's
///         API/Distributor actually produce — a mismatch would silently make every production submit revert and NAV
///         under-count Merkl to 0.
/// @dev Forks at the fixture's own `rootBlock` so `getMerkleRoot()` matches the tree the proof was captured against
///      (Merkl rotates roots ~8h). The fixture is regenerated by `script/test/refresh-integration-snapshot.sh`; this
///      test reads it at runtime so it stays in sync.
contract MerklRewardsAttestedBalanceAdapterRealProofForkTest is BalanceAdapterTestBase {
    /// @notice Merkl Distributor — same address on every supported EVM chain.
    address public constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    MerklRewardsAttestedBalanceAdapter public adapter;

    // Parsed from the mainnet (chain 1) fixture, entry index 0.
    address internal fixtureUser;
    address internal fixtureToken;
    uint256 internal fixtureCumulative;
    bytes32[] internal fixtureProof;
    bytes32 internal fixtureRoot;

    /// @dev True when the regenerated mainnet fixture carries no entries to replay, in which case every test in this
    ///      contract skips rather than failing. See the guard in {_setupFork}.
    bool internal fixtureMissing;

    function _setupFork() internal override {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/integration/merkl-proofs.json"));
        uint256 rootBlock = vm.parseJsonUint(json, ".1.rootBlock");
        fixtureRoot = vm.parseJsonBytes32(json, ".1.expectedRoot");

        // An empty entry list is an ORDINARY outcome, not a defect: `refresh-integration-snapshot.sh` regenerates this
        // fixture from live Merkl API data, so a chain's list is empty whenever the tracked accounts hold no unclaimed
        // rewards at the new fork block — already the case for chains 10, 100 and 8453. Hard-indexing entry 0 would
        // abort every test in this contract with an out-of-bounds JSON parse *in setUp*, which reads as a code
        // regression and needs a hand edit to clear. Degrade to a skip instead, so a routine snapshot refresh cannot
        // turn this suite red — while still failing loudly for a real encoding break when there IS something to replay.
        address[] memory users = vm.parseJsonAddressArray(json, ".1.users");
        if (users.length == 0) {
            fixtureMissing = true;
            fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), rootBlock);
            return;
        }

        fixtureUser = users[0];
        fixtureToken = vm.parseJsonAddress(json, ".1.tokens[0]");
        // amounts[] are decimal strings (cumulative wei); parse string → uint.
        fixtureCumulative = vm.parseUint(vm.parseJsonString(json, ".1.amounts[0]"));
        fixtureProof = vm.parseJsonBytes32Array(json, ".1.proofs[0]");

        fork = createSelectForkWithCadence(getAlchemyUrl("eth-mainnet"), rootBlock);
        // Register the reward token so getAdapterPositions can resolve its asset metadata and emit a leg.
        balances = _deployBalancesForAdapter(fixtureToken);
        // Permissionless: no admin/assistant roles.
        adapter = new MerklRewardsAttestedBalanceAdapter(MERKL_DISTRIBUTOR, address(balances));
    }

    function _alloc() internal view returns (MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs) {
        allocs = new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        allocs[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: fixtureToken,
            cumulativeAmount: fixtureCumulative,
            proof: fixtureProof,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
    }

    /// @notice The fork block is aligned with the fixture: the live root equals the root the proof was captured for.
    function test_realProof_forkRootMatchesFixture() public {
        if (fixtureMissing) vm.skip(true);
        assertEq(IMerklDistributor(MERKL_DISTRIBUTOR).getMerkleRoot(), fixtureRoot, "fork block root != fixture root");
    }

    /// @notice A REAL Merkl proof verifies against the REAL live root — proving our leaf encoding matches Merkl's.
    function test_realProof_verifiesAndCaches() public {
        if (fixtureMissing) vm.skip(true);
        adapter.submitProofs(fixtureUser, _alloc());
        (uint256 cachedCumulative, bytes32 cachedRoot,) = adapter.allocations(fixtureUser, fixtureToken);
        assertEq(cachedCumulative, fixtureCumulative, "cached cumulative == proven amount");
        assertEq(cachedRoot, fixtureRoot, "cached root == live root");
    }

    /// @notice After caching, the adapter reports unclaimed = cumulative − Distributor.claimed and emits one
    ///         `Rewards` leg for the token with the canonical identity fields.
    function test_realProof_reportsUnclaimedAndLeg() public {
        if (fixtureMissing) vm.skip(true);
        adapter.submitProofs(fixtureUser, _alloc());

        (uint208 claimed,,) = IMerklDistributor(MERKL_DISTRIBUTOR).claimed(fixtureUser, fixtureToken);
        uint256 expectedUnclaimed = fixtureCumulative > uint256(claimed) ? fixtureCumulative - uint256(claimed) : 0;

        (uint256 amt, bool isDebt) = adapter.getAdapterBalanceForAsset(fixtureUser, fixtureToken);
        assertEq(amt, expectedUnclaimed, "unclaimed = cumulative - claimed");
        assertFalse(isDebt);
        assertGt(amt, 0, "fixture entry 0 has no unclaimed rewards left; re-run refresh-integration-snapshot.sh");

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(fixtureUser, address(0));
        assertEq(positions.length, 1, "one untagged Merkl reward leg");
        assertEq(positions[0].balanceAdapter, address(adapter), "balanceAdapter == address(this)");
        assertEq(positions[0].balanceAsset.asset, fixtureToken, "leg asset == reward token");
        assertEq(positions[0].amount, expectedUnclaimed, "leg amount == unclaimed");
        assertFalse(positions[0].isDebt);
        assertTrue(positions[0].positionKind == PositionKind.Rewards, "positionKind == Rewards");
        // Full canonical identity, not just protocolId — `positionId` in particular is the stable reconciliation
        // key downstream consumers JOIN on, so re-keying it must fail a test rather than pass silently.
        assertEq(positions[0].positionId, abi.encode(MERKL_DISTRIBUTOR), "positionId == abi.encode(DISTRIBUTOR)");
        assertEq(positions[0].protocolBrand, ProtocolIds.MERKL, "protocolBrand == MERKL");
        assertEq(positions[0].protocolId, ProtocolIds.MERKL, "protocolId == MERKL");
        assertEq(positions[0].protocolSubId, ProtocolIds.MERKL, "protocolSubId == MERKL");
        assertFalse(positions[0].isLocked, "unclaimed Merkl rewards are never locked");
        assertEq(positions[0].positionInstanceId, bytes32(0), "untagged (no campaign breakdown)");
        assertEq(adapter.protocolName(), "Merkl", "protocolName == Merkl");
    }

    /// @notice CACHE-FREE preview against the REAL live root: WITHOUT ever calling `submitProofs`, `previewPositions`
    ///         verifies the captured proof, values it as `cumulative − live claimed`, and emits the canonical leg —
    ///         while caching nothing. Proves the trustless, account-agnostic path end-to-end against the real
    ///         Distributor, and that it does not disturb the NAV (cache) path.
    function test_realProof_previewMatchesLiveWithoutCaching() public {
        if (fixtureMissing) vm.skip(true);

        (uint208 claimed,,) = IMerklDistributor(MERKL_DISTRIBUTOR).claimed(fixtureUser, fixtureToken);
        uint256 expectedUnclaimed = fixtureCumulative > uint256(claimed) ? fixtureCumulative - uint256(claimed) : 0;

        INAVCalculator.PositionBalance[] memory positions = adapter.previewPositions(fixtureUser, _alloc());
        assertEq(positions.length, 1, "one untagged Merkl reward leg from the supplied proof");
        assertEq(positions[0].balanceAsset.asset, fixtureToken, "leg asset == reward token");
        assertEq(positions[0].amount, expectedUnclaimed, "preview leg == cumulative - live claimed");
        assertGt(
            positions[0].amount, 0, "fixture entry 0 has no unclaimed left; re-run refresh-integration-snapshot.sh"
        );
        assertEq(positions[0].positionId, abi.encode(MERKL_DISTRIBUTOR), "positionId == abi.encode(DISTRIBUTOR)");
        assertTrue(positions[0].positionKind == PositionKind.Rewards, "positionKind == Rewards");

        // Cache-free: the preview wrote nothing and the NAV path is untouched (never submitted).
        (uint256 cachedCumulative, bytes32 cachedRoot,) = adapter.allocations(fixtureUser, fixtureToken);
        assertEq(cachedCumulative, 0, "preview cached no cumulative");
        assertEq(cachedRoot, bytes32(0), "preview cached no entry");
        assertEq(adapter.getAdapterPositions(fixtureUser, address(0)).length, 0, "NAV path still empty");

        // The lightweight variant agrees.
        (address[] memory toks, uint256[] memory amts) = adapter.previewBalances(fixtureUser, _alloc());
        assertEq(toks.length, 1);
        assertEq(toks[0], fixtureToken);
        assertEq(amts[0], expectedUnclaimed, "previewBalances agrees with previewPositions");
    }
}
