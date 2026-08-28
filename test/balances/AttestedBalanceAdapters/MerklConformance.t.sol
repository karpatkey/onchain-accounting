// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {AttestedAdapterConformance} from "test/balances/AttestedBalanceAdapters/AttestedAdapterConformance.sol";
import {AttestedValueCache} from "src/balances/AttestedBalanceAdapters/AttestedValueCache.sol";
import {
    MerklRewardsAttestedBalanceAdapter,
    IMerklDistributor
} from "src/balances/AttestedBalanceAdapters/MerklRewardsAttestedBalanceAdapter.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice Minimal Merkl Distributor stand-in for the conformance fixtures.
contract ConformanceDistributor is IMerklDistributor {
    bytes32 public root;

    function setRoot(bytes32 r) external {
        root = r;
    }

    function getMerkleRoot() external view override returns (bytes32) {
        return root;
    }

    function claimed(address, address) external pure override returns (uint208, uint48, bytes32) {
        return (0, 0, bytes32(0));
    }
}

/// @notice Runs the attested family's conformance kit against the FIRST member.
/// @dev The kit is only worth what its fixtures are worth, so these are deliberately honest:
///      - `_validPayload` builds a real single-leaf Merkl tree and sets the Distributor root to it, so the
///        member's real `_verifyMerklProof` must accept it.
///      - `_tamperedPayload` keeps a VALID root and corrupts only the amount, so the payload fails for the right
///        reason — the leaf no longer hashes to the root — rather than being malformed in some unrelated way.
///        This is the fixture a reviewer should read first.
///      - `_rotateValidity` rotates the root, which is exactly how Merkl entries go stale in production.
///      - `_submitViaTypedEntrypoint` routes through `submitProofs`, so the typed convenience is checked against
///        the same role gate as the generic entrypoint.
contract MerklConformanceTest is AttestedAdapterConformance {
    ConformanceDistributor internal distributor;
    Mock_ERC20 internal rewardToken;
    Mock_ERC20 internal secondToken;

    function _deployMember(address admin_) internal override returns (AttestedValueCache) {
        distributor = new ConformanceDistributor();
        rewardToken = new Mock_ERC20("REWARD", 18);
        balances.addSupportedAssetForTest(address(rewardToken));
        secondToken = new Mock_ERC20("REWARD2", 18);
        balances.addSupportedAssetForTest(address(secondToken));
        return new MerklRewardsAttestedBalanceAdapter(address(distributor), address(balances), admin_);
    }

    /// @dev Merkl's sorted-pair, `abi.encode` hashing — must match `_verifyMerklProof` exactly.
    function _tree2(bytes32 a, bytes32 b, uint256 idx) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        proof = new bytes32[](1);
        proof[0] = idx == 0 ? b : a;
    }

    function _leaf(address user, address token, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, token, amount));
    }

    function _allocs(address token, uint256 amount)
        internal
        pure
        returns (MerklRewardsAttestedBalanceAdapter.Allocation[] memory a)
    {
        a = new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        a[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: token,
            cumulativeAmount: amount,
            proof: new bytes32[](0),
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
    }

    function _validPayload(address account)
        internal
        override
        returns (bytes memory data, address[] memory assets, uint256[] memory values)
    {
        // TWO-leaf tree carrying both reward tokens, so the root that proves this payload also proves
        // `_secondValidPayload` — otherwise submitting the second would rotate the root and make the first STALE,
        // and the non-suppression test could not tell suppression apart from ordinary staleness.
        bytes32 leafA = _leaf(account, address(rewardToken), 100 ether);
        bytes32 leafB = _leaf(account, address(secondToken), 55 ether);
        (bytes32 root, bytes32[] memory proofA) = _tree2(leafA, leafB, 0);
        distributor.setRoot(root);

        assets = new address[](1);
        values = new uint256[](1);
        assets[0] = address(rewardToken);
        values[0] = 100 ether;

        MerklRewardsAttestedBalanceAdapter.Allocation[] memory a =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        a[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(rewardToken),
            cumulativeAmount: 100 ether,
            proof: proofA,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        data = abi.encode(a);
    }

    function _secondValidPayload(address account)
        internal
        override
        returns (bytes memory data, address[] memory assets, uint256[] memory values)
    {
        // A DIFFERENT reward token, in a two-leaf tree alongside the first, so both are provable under one root —
        // which is what lets the non-suppression test submit the second while omitting the first.
        bytes32 leafA = _leaf(account, address(rewardToken), 100 ether);
        bytes32 leafB = _leaf(account, address(secondToken), 55 ether);
        (bytes32 root, bytes32[] memory proofB) = _tree2(leafA, leafB, 1);
        distributor.setRoot(root);

        assets = new address[](1);
        values = new uint256[](1);
        assets[0] = address(secondToken);
        values[0] = 55 ether;

        MerklRewardsAttestedBalanceAdapter.Allocation[] memory a =
            new MerklRewardsAttestedBalanceAdapter.Allocation[](1);
        a[0] = MerklRewardsAttestedBalanceAdapter.Allocation({
            token: address(secondToken),
            cumulativeAmount: 55 ether,
            proof: proofB,
            campaigns: new MerklRewardsAttestedBalanceAdapter.CampaignShare[](0)
        });
        data = abi.encode(a);
    }

    function _tamperedPayload(address account) internal override returns (bytes memory data) {
        // Root is valid for 100 ether; the payload claims 999. The leaf no longer hashes to the root, so this
        // fails on VERIFICATION rather than on shape — which is the only way this fixture is worth anything.
        distributor.setRoot(_leaf(account, address(rewardToken), 100 ether));
        data = abi.encode(_allocs(address(rewardToken), 999 ether));
    }

    /// @dev Pinned: the tampered fixture must fail because the merkle proof rejects it, not for any other reason.
    function _tamperedRevertSelector() internal pure override returns (bytes4) {
        return MerklRewardsAttestedBalanceAdapter.InvalidProof.selector;
    }

    function _rotateValidity() internal override {
        distributor.setRoot(keccak256("conformance-rotated-root"));
    }

    function _submitViaTypedEntrypoint(address account, bytes memory data) internal override {
        MerklRewardsAttestedBalanceAdapter.Allocation[] memory allocs =
            abi.decode(data, (MerklRewardsAttestedBalanceAdapter.Allocation[]));
        MerklRewardsAttestedBalanceAdapter(address(member)).submitProofs(account, allocs);
    }
}
