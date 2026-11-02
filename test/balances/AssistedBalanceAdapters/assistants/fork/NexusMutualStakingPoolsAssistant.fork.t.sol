// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistant
} from "src/balances/AssistedBalanceAdapters/assistants/NexusMutualStakingPoolsAssistant.sol";
import {AssistantDelegateCaller} from "test/balances/AssistedBalanceAdapters/assistants/AssistantDelegateCaller.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

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

/// @title NexusMutualStakingPoolsAssistant fork test (real Nexus deposit + withdraw, delegatecall module)
/// @notice End-to-end against live Nexus Mutual on mainnet. The wrapper is a **delegatecall-only** logic module, so the
///         staking **account** is a {AssistantDelegateCaller} that `delegatecall`s it — under the delegatecall
///         `address(this)` is the account, which holds the NXM, is the Nexus member, and owns the StakingNFT (it feeds
///         its own cache — no role). Exercises account→(delegatecall)wrapper.depositTo → pool.depositTo →
///         TokenController.operatorTransfer → StakingNFT mint → adapter.submit → live valuation, and the withdraw path.
/// @dev Membership is granted via the **real** on-chain flow (no storage pokes): governor-pranked
///      `Registry.setKycAuthAddress` + EIP-712 `Registry.join` (KYC-signer + 0.002 ETH fee). The account's NXM is
///      transferred from the Nexus Mutual Safe (`0x8e53…cFE3`, a real member).
contract NexusMutualStakingPoolsAssistantForkTest is BalanceAdapterTestBase {
    address public constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address public constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address public constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;

    address public constant TOKEN_CONTROLLER = 0x5407381b6c251cFd498ccD4A1d877739CB7960B8;
    address public constant REGISTRY = 0xcafea2c575550512582090AA06d0a069E7236b9e;
    address public constant GOVERNOR = 0xcafea6063d4Ec6b045d9676e58897C1f0882Ca32;
    uint256 public constant JOIN_FEE = 0.002 ether;
    bytes32 public constant JOIN_TYPEHASH = keccak256("Join(address member)");

    address public constant NXM_SOURCE = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3; // Nexus Mutual Safe (member)

    uint256 public constant FORK_BLOCK = 25_388_000;
    uint256 public constant TRANCHE_DURATION = 91 days;
    uint256 public constant AMOUNT = 100e18; // 100 NXM

    NexusMutualStakingPoolsAssistedBalanceAdapter public adapter;
    NexusMutualStakingPoolsAssistant public wrapper;
    AssistantDelegateCaller public account; // the delegatecalling staking account

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NXM, 18, "NXM");

        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this)
        );
        wrapper = new NexusMutualStakingPoolsAssistant(address(adapter), NXM, TOKEN_CONTROLLER);

        // The delegatecalling account is the real actor: it feeds its own cache (owner path, no role), is a Nexus
        // member, and holds NXM.
        account = new AssistantDelegateCaller();
        _enrollNexusMember(address(account));

        // Fund the account with real NXM from the Safe (a member); the account is now whitelisted so it can receive.
        vm.prank(NXM_SOURCE);
        IERC20(NXM).transfer(address(account), 500e18);
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

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

    /// @dev First public staking pool (scan poolIds 1..30 via the viewer; skip private/nonexistent).
    function _firstPublicPool() internal view returns (address) {
        address[] memory pools = _publicPools(1);
        return pools[0];
    }

    /// @dev The first `count` distinct public staking pools (scan poolIds 1..40 via the viewer; skip private/nonexistent).
    function _publicPools(uint256 count) internal view returns (address[] memory found) {
        found = new address[](count);
        uint256 n;
        for (uint256 pid = 1; pid <= 40 && n < count; ++pid) {
            address pool = IStakingViewerLike(STAKING_VIEWER).stakingPool(pid);
            if (pool == address(0)) continue;
            try IStakingPoolLike(pool).isPrivatePool() returns (bool priv) {
                if (!priv) found[n++] = pool;
            } catch {}
        }
        require(n == count, "not enough public pools");
    }

    /// @dev Deposit AMOUNT into `pool`'s current active tranche as the account; returns (pool, trancheId, tokenId).
    function _deposit() internal returns (address pool, uint256 trancheId, uint256 tokenId) {
        pool = _firstPublicPool();
        require(pool != address(0), "no public pool found");
        trancheId = block.timestamp / TRANCHE_DURATION;
        tokenId = account.deposit(address(wrapper), pool, AMOUNT, trancheId, 0);
    }

    function test_deposit_realPool_mintsTracksAndValues() public {
        uint256 accountNxmBefore = IERC20(NXM).balanceOf(address(account));
        (,, uint256 tokenId) = _deposit();

        assertGt(tokenId, 0, "a StakingNFT was minted");
        assertEq(IERC20(NXM).balanceOf(address(account)), accountNxmBefore - AMOUNT, "account NXM staked");

        uint256[] memory tracked = adapter.tokenIdsOf(address(account));
        assertEq(tracked.length, 1);
        assertEq(tracked[0], tokenId);
        (uint256 bal, bool isDebt) = adapter.getAdapterBalanceForAsset(address(account), NXM);
        assertFalse(isDebt);
        assertApproxEqRel(bal, AMOUNT, 0.01e18, "staked NXM valued ~= deposited amount");
    }

    function test_deposit_directCallReverts() public {
        // The module is delegatecall-only — a direct call to the deployed wrapper reverts.
        vm.expectRevert();
        wrapper.depositTo(address(1), AMOUNT, 1, 0);
    }

    function test_depositThenWithdraw_realPool_untracksAndReturnsNxm() public {
        (address pool, uint256 trancheId, uint256 tokenId) = _deposit();
        uint256 accountNxmAfterDeposit = IERC20(NXM).balanceOf(address(account));

        // Warp past the tranche's expiry so the stake becomes withdrawable, then FULLY withdraw (stake + rewards)
        // through the wrapper. A full withdraw empties the position, so the wrapper untracks it; a partial / rewards-
        // only withdraw would instead keep the still-live residual tracked (covered by the unit tests).
        vm.warp((trancheId + 1) * TRANCHE_DURATION + 1);
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = trancheId;
        (uint256 withdrawnStake,) = account.withdraw(address(wrapper), pool, tokenId, true, true, tranches);

        assertGt(withdrawnStake, 0, "stake withdrawn");
        // Nexus pays the NFT owner (the account) directly.
        assertGt(IERC20(NXM).balanceOf(address(account)), accountNxmAfterDeposit, "account received withdrawn NXM");
        assertEq(adapter.tokenIdsOf(address(account)).length, 0, "tokenId untracked after full withdraw");
    }

    /// @notice Topping up the same StakingNFT (requestTokenId != 0) returns the same id: one tracked id, ~2x stake.
    function test_topUp_sameTokenId_accumulatesStake() public {
        (address pool, uint256 trancheId, uint256 tokenId) = _deposit();
        uint256 id2 = account.deposit(address(wrapper), pool, AMOUNT, trancheId, tokenId);

        assertEq(id2, tokenId, "top-up returns the same StakingNFT id");
        uint256[] memory tracked = adapter.tokenIdsOf(address(account));
        assertEq(tracked.length, 1, "still one tracked id");
        (uint256 bal,) = adapter.getAdapterBalanceForAsset(address(account), NXM);
        assertApproxEqRel(bal, 2 * AMOUNT, 0.01e18, "staked NXM ~= 2x amount after top-up");
    }

    /// @notice Staking into two distinct pools yields two independently-tracked StakingNFTs, summed in the balance.
    function test_twoPools_distinctTrackedIds() public {
        address[] memory pools = _publicPools(2);
        uint256 trancheId = block.timestamp / TRANCHE_DURATION;

        uint256 id0 = account.deposit(address(wrapper), pools[0], AMOUNT, trancheId, 0);
        uint256 id1 = account.deposit(address(wrapper), pools[1], AMOUNT, trancheId, 0);

        assertTrue(id0 != id1, "distinct StakingNFT ids");
        assertEq(adapter.tokenIdsOf(address(account)).length, 2, "two tracked ids");
        (uint256 bal,) = adapter.getAdapterBalanceForAsset(address(account), NXM);
        assertApproxEqRel(bal, 2 * AMOUNT, 0.01e18, "total ~= sum of both stakes");
    }

    /// @notice After a wrapper deposit, getAdapterPositions emits a Staking leg keyed by the pool address for the
    ///         account, with the tokenId in positionInstanceId.
    function test_deposit_getAdapterPositions_stakingLeg() public {
        (address pool,, uint256 tokenId) = _deposit();

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(address(account), address(0));
        assertGe(p.length, 1, "at least a Staking leg");

        bool foundStaking;
        for (uint256 i; i < p.length; ++i) {
            assertEq(p[i].balanceAsset.asset, NXM);
            assertEq(p[i].positionId, abi.encode(pool), "positionId = staking pool address");
            assertEq(p[i].positionInstanceId, bytes32(tokenId), "tokenId in positionInstanceId");
            if (p[i].positionKind == PositionKind.Staking) {
                foundStaking = true;
                assertApproxEqRel(p[i].amount, AMOUNT, 0.01e18, "Staking leg ~= deposited amount");
            }
        }
        assertTrue(foundStaking, "a Staking leg is present");
    }
}
