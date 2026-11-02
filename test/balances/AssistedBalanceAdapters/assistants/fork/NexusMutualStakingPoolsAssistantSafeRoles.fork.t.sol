// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssistantSafeRolesForkBase} from "test/utils/AssistantSafeRolesForkBase.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/NexusMutualStakingPoolsAssistant.sol";

/// @title NexusMutualStakingPoolsAssistant — Safe + Zodiac Roles integration (happy path)
/// @notice End-to-end proof of the delegatecall path: the manager Safe, a member of a Roles role permitting a
///         DELEGATECALL to the assistant, calls `execTransactionWithRole`; the Roles modifier makes the **avatar Safe**
///         delegatecall `NexusMutualStakingPoolsAssistant.depositTo`, which stakes the avatar's NXM into a Nexus pool
///         (minting the StakingNFT to the avatar) and records it on the adapter. The avatar is enrolled as a real Nexus
///         member and funded with NXM (setup).
/// @dev Membership uses the real on-chain flow (governor-pranked `Registry.setKycAuthAddress` + EIP-712 `Registry.join`,
///      no storage pokes); NXM is transferred from the Nexus Mutual Safe (a real member).
contract NexusMutualStakingPoolsAssistantSafeRolesForkTest is AssistantSafeRolesForkBase {
    address public constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address public constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address public constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;
    address public constant TOKEN_CONTROLLER = 0x5407381b6c251cFd498ccD4A1d877739CB7960B8;
    address public constant REGISTRY = 0xcafea2c575550512582090AA06d0a069E7236b9e;
    address public constant GOVERNOR = 0xcafea6063d4Ec6b045d9676e58897C1f0882Ca32;
    address public constant NXM_SOURCE = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3; // Nexus Mutual Safe (member)

    uint256 public constant JOIN_FEE = 0.002 ether;
    bytes32 public constant JOIN_TYPEHASH = keccak256("Join(address member)");
    uint256 public constant FORK_BLOCK = 25_388_000;
    uint256 public constant TRANCHE_DURATION = 91 days;
    uint256 public constant AMOUNT = 100e18; // 100 NXM staked via the queue

    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    NexusMutualStakingPoolsAssistant public assistant;

    function setUp() public override {
        super.setUp(); // invokes _setupFork()
        balances = _deployBalancesForAdapter(NXM);

        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this)
        );
        assistant = new NexusMutualStakingPoolsAssistant(address(adapter), NXM, TOKEN_CONTROLLER);

        _initManagerSafe();
        _permitDelegatecall(address(assistant));

        // Enrol the avatar Safe as a real Nexus member (required to hold NXM + stake), then fund it with NXM.
        _enrollNexusMember(AVATAR_SAFE);
        vm.prank(NXM_SOURCE);
        IERC20(NXM).transfer(AVATAR_SAFE, 500e18);
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @notice Manager Safe → Roles `execTransactionWithRole` (DelegateCall) → avatar Safe delegatecalls the assistant's
    ///         `depositTo`, staking NXM into a Nexus pool and tracking the minted StakingNFT on the adapter.
    function test_managerSafe_viaRoles_delegatecalls_depositTo() public {
        address pool = _firstPublicPool();
        uint256 trancheId = block.timestamp / TRANCHE_DURATION;

        // Precondition: avatar holds NXM; adapter tracks nothing for it yet.
        assertGe(IERC20(NXM).balanceOf(AVATAR_SAFE), AMOUNT, "avatar funded with NXM");
        assertEq(adapter.tokenIdsOf(AVATAR_SAFE).length, 0, "nothing tracked yet");

        // The manager Safe drives the avatar Safe to delegatecall the assistant through the Roles modifier.
        bytes memory data = abi.encodeCall(NexusMutualStakingPoolsAssistant.depositTo, (pool, AMOUNT, trancheId, 0));
        _managerDelegatecall(address(assistant), data);

        // The delegatecall executed as the avatar: a StakingNFT is minted to and tracked for the avatar Safe.
        uint256[] memory tracked = adapter.tokenIdsOf(AVATAR_SAFE);
        assertEq(tracked.length, 1, "one StakingNFT tracked for the avatar Safe");

        (uint256 bal, bool isDebt) = adapter.getAdapterBalanceForAsset(AVATAR_SAFE, NXM);
        assertFalse(isDebt);
        assertApproxEqRel(bal, AMOUNT, 0.01e18, "staked NXM valued ~= deposited amount");
    }

    // ---- Nexus membership + pool-discovery helpers (real on-chain flow; ported from the assistant fork test) ----

    /// @dev Enrol `member` as a real Nexus member via `Registry.join` (KYC-signer + fee gated). No storage pokes.
    function _enrollNexusMember(address member) internal {
        (address kyc, uint256 kycPk) = makeAddrAndKey("nexusKycSigner");
        vm.prank(GOVERNOR);
        INexusRegistry(REGISTRY).setKycAuthAddress(kyc);

        bytes32 structHash = keccak256(abi.encode(JOIN_TYPEHASH, member));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", INexusRegistry(REGISTRY).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kycPk, digest);

        vm.deal(address(this), JOIN_FEE);
        INexusRegistry(REGISTRY).join{value: JOIN_FEE}(member, abi.encodePacked(r, s, v));
        require(INexusRegistry(REGISTRY).isMember(member), "enrollment failed");
    }

    /// @dev First public staking pool (scan poolIds 1..40 via the viewer; skip private/nonexistent).
    function _firstPublicPool() internal view returns (address) {
        for (uint256 pid = 1; pid <= 40; ++pid) {
            address pool = IStakingViewerLike(STAKING_VIEWER).stakingPool(pid);
            if (pool == address(0)) continue;
            try IStakingPoolLike(pool).isPrivatePool() returns (bool priv) {
                if (!priv) return pool;
            } catch {}
        }
        revert("no public pool found");
    }
}

interface IStakingViewerLike {
    function stakingPool(uint256 poolId) external view returns (address);
}

interface IStakingPoolLike {
    function isPrivatePool() external view returns (bool);
}

/// @notice Nexus Registry membership surface (the deployed governance Registry that gates NXM membership).
interface INexusRegistry {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function setKycAuthAddress(address kycAuthAddress) external;
    function join(address member, bytes calldata signature) external payable;
    function isMember(address member) external view returns (bool);
}
