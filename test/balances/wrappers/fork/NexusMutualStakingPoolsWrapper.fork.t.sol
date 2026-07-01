// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {NexusMutualStakingPoolsAssistedBalanceAdapter} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {NexusMutualStakingPoolsWrapper} from "src/balances/wrappers/NexusMutualStakingPoolsWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The staking-pool + viewer + Nexus-membership functions this fork test drives.
interface IStakingViewerLike {
    function stakingPool(uint256 poolId) external view returns (address);
}

interface IStakingPoolLike {
    function isPrivatePool() external view returns (bool);
    function withdraw(uint256 tokenId, bool withdrawStake, bool withdrawRewards, uint256[] memory trancheIds)
        external
        returns (uint256 withdrawnStake, uint256 withdrawnRewards);
}

/// @notice Nexus Registry membership surface (the deployed governance Registry that gates NXM membership).
interface INexusRegistry {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function setKycAuthAddress(address kycAuthAddress) external;
    function join(address member, bytes calldata signature) external payable;
    function isMember(address member) external view returns (bool);
}

/// @title NexusMutualStakingPoolsWrapper fork test (real Nexus deposit + withdraw)
/// @notice End-to-end against live Nexus Mutual on mainnet: enrol the wrapper as a real Nexus member (so it can hold
///         NXM), then a member DEPOSITOR stakes real NXM through the wrapper (minting a real StakingNFT tracked by the
///         adapter) and withdraws it back. Exercises wrapper.depositTo → pool.depositTo →
///         TokenController.operatorTransfer → StakingNFT mint → adapter.submit → live valuation, and wrapper.withdraw
///         → pool.withdraw → adapter.remove.
/// @dev Membership is granted via the **real** on-chain flow (no storage pokes): the wrapper must be a whitelisted
///      Nexus member for NXM's `transferFrom` (recipient-gated) to reach it and for `operatorTransfer` to pull from it.
///      `Registry.join(member, sig)` is EIP-712 + KYC-signer gated and charges a 0.002 ETH fee; we repoint the
///      KYC signer to a key we control (governor-pranked `setKycAuthAddress`), sign the `Join(wrapper)` digest, and
///      `join`. The DEPOSITOR is the Nexus Mutual Safe (`0x8e53…cFE3`) — a real member holding NXM.
contract NexusMutualStakingPoolsWrapperForkTest is BalanceAdapterTestBase {
    address public constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address public constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address public constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;

    // Nexus TokenController (NXM operator) — the wrapper approves it the deposit amount.
    address public constant TOKEN_CONTROLLER = 0x5407381b6c251cFd498ccD4A1d877739CB7960B8;
    // Nexus governance Registry (membership) + the governor that administers its KYC signer.
    address public constant REGISTRY = 0xcafea2c575550512582090AA06d0a069E7236b9e;
    address public constant GOVERNOR = 0xcafea6063d4Ec6b045d9676e58897C1f0882Ca32;
    uint256 public constant JOIN_FEE = 0.002 ether;
    bytes32 public constant JOIN_TYPEHASH = keccak256("Join(address member)");

    uint256 public constant FORK_BLOCK = 25_388_000;
    uint256 public constant TRANCHE_DURATION = 91 days;
    uint256 public constant AMOUNT = 100e18; // 100 NXM

    // A real Nexus member holding NXM at FORK_BLOCK (the Nexus Mutual Safe, ~3,827 NXM).
    address depositor = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3;

    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    NexusMutualStakingPoolsWrapper public wrapper;

    bytes32 constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");
    bytes32 constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NXM, 18, "NXM");

        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this), address(0)
        );
        wrapper = new NexusMutualStakingPoolsWrapper(address(adapter), NXM, TOKEN_CONTROLLER, address(this));
        adapter.grantRole(SUBMITTER_ROLE, address(wrapper));
        wrapper.grantRole(DEPOSITOR_ROLE, depositor);

        // Real membership enrollment: the wrapper must be a Nexus member to receive/hold NXM (and for operatorTransfer
        // to pull from it). No storage pokes — the actual Registry.join flow.
        _enrollNexusMember(address(wrapper));

        // The depositor is already a member holding NXM; just approve the wrapper to pull it.
        vm.prank(depositor);
        IERC20(NXM).approve(address(wrapper), type(uint256).max);
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    /// @dev Enrol `member` as a real Nexus member via `Registry.join` (KYC-signer + fee gated). Repoints the KYC signer
    ///      to a key we control (governor tx), signs the EIP-712 `Join(member)` digest, and joins paying the fee.
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

    /// @dev First public staking pool (scan poolIds 1..30 via the viewer; skip private/nonexistent).
    function _firstPublicPool() internal view returns (address) {
        for (uint256 pid = 1; pid <= 30; ++pid) {
            address pool = IStakingViewerLike(STAKING_VIEWER).stakingPool(pid);
            if (pool == address(0)) continue;
            try IStakingPoolLike(pool).isPrivatePool() returns (bool priv) {
                if (!priv) return pool;
            } catch {}
        }
        return address(0);
    }

    /// @dev Deposit AMOUNT into `pool`'s current active tranche as `depositor`; returns (pool, trancheId, tokenId).
    function _deposit() internal returns (address pool, uint256 trancheId, uint256 tokenId) {
        pool = _firstPublicPool();
        require(pool != address(0), "no public pool found");
        trancheId = block.timestamp / TRANCHE_DURATION;
        vm.prank(depositor);
        tokenId = wrapper.depositTo(pool, AMOUNT, trancheId, 0);
    }

    function test_deposit_realPool_mintsTracksAndValues() public {
        uint256 depositorNxmBefore = IERC20(NXM).balanceOf(depositor);
        (,, uint256 tokenId) = _deposit();

        assertGt(tokenId, 0, "a StakingNFT was minted");
        assertEq(IERC20(NXM).balanceOf(depositor), depositorNxmBefore - AMOUNT, "depositor NXM spent");
        assertEq(IERC20(NXM).balanceOf(address(wrapper)), 0, "wrapper is custody-free after deposit");

        uint256[] memory tracked = adapter.tokenIdsOf(depositor);
        assertEq(tracked.length, 1);
        assertEq(tracked[0], tokenId);
        (uint256 bal, bool isDebt) = adapter.getAdapterBalanceForAsset(depositor, NXM);
        assertFalse(isDebt);
        assertApproxEqRel(bal, AMOUNT, 0.01e18, "staked NXM valued ~= deposited amount");
    }

    function test_depositThenWithdraw_realPool_untracksAndReturnsNxm() public {
        (address pool, uint256 trancheId, uint256 tokenId) = _deposit();
        uint256 depositorNxmAfterDeposit = IERC20(NXM).balanceOf(depositor);

        // Warp past the tranche's expiry so the stake becomes withdrawable, then withdraw it through the wrapper.
        vm.warp((trancheId + 1) * TRANCHE_DURATION + 1);
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = trancheId;
        vm.prank(depositor);
        (uint256 withdrawnStake,) = wrapper.withdraw(pool, tokenId, true, false, tranches);

        assertGt(withdrawnStake, 0, "stake withdrawn");
        // Nexus pays the NFT owner (the depositor) directly; the wrapper never custodies it.
        assertGt(IERC20(NXM).balanceOf(depositor), depositorNxmAfterDeposit, "depositor received withdrawn NXM");
        assertEq(IERC20(NXM).balanceOf(address(wrapper)), 0, "wrapper holds no NXM");
        assertEq(adapter.tokenIdsOf(depositor).length, 0, "tokenId untracked after withdraw");
    }
}
