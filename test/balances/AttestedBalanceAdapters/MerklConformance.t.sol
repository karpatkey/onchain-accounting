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

    function _deployMember(address admin_) internal override returns (AttestedValueCache) {
        distributor = new ConformanceDistributor();
        rewardToken = new Mock_ERC20("REWARD", 18);
        balances.addSupportedAssetForTest(address(rewardToken));
        return new MerklRewardsAttestedBalanceAdapter(address(distributor), address(balances), admin_);
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
        // Single-leaf tree: the leaf IS the root, so the empty proof verifies.
        distributor.setRoot(_leaf(account, address(rewardToken), 100 ether));
        assets = new address[](1);
        values = new uint256[](1);
        assets[0] = address(rewardToken);
        values[0] = 100 ether;
        data = abi.encode(_allocs(address(rewardToken), 100 ether));
    }

    function _tamperedPayload(address account) internal override returns (bytes memory data) {
        // Root is valid for 100 ether; the payload claims 999. The leaf no longer hashes to the root, so this
        // fails on VERIFICATION rather than on shape — which is the only way this fixture is worth anything.
        distributor.setRoot(_leaf(account, address(rewardToken), 100 ether));
        data = abi.encode(_allocs(address(rewardToken), 999 ether));
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
