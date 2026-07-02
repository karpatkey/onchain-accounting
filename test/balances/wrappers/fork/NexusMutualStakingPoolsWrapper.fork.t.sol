// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {NexusMutualStakingPoolsAssistedBalanceAdapter, INexusStakingViewer} from
    "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {NexusMutualStakingPoolsWrapper} from "src/balances/wrappers/NexusMutualStakingPoolsWrapper.sol";
import {WrapperDelegateCaller} from "test/balances/wrappers/WrapperDelegateCaller.sol";
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

/// @title NexusMutualStakingPoolsWrapper fork test (real Nexus deposit + withdraw, delegatecall module)
/// @notice End-to-end against live Nexus Mutual on mainnet. The wrapper is a **delegatecall-only** logic module, so the
///         staking **account** is a {WrapperDelegateCaller} that `delegatecall`s it — under the delegatecall
///         `address(this)` is the account, which holds the NXM, is the Nexus member, owns the StakingNFT, and holds
///         `SUBMITTER_ROLE`. Exercises account→(delegatecall)wrapper.depositTo → pool.depositTo →
///         TokenController.operatorTransfer → StakingNFT mint → adapter.submit → live valuation, and the withdraw path.
/// @dev Membership is granted via the **real** on-chain flow (no storage pokes): governor-pranked
///      `Registry.setKycAuthAddress` + EIP-712 `Registry.join` (KYC-signer + 0.002 ETH fee). The account's NXM is
///      transferred from the Nexus Mutual Safe (`0x8e53…cFE3`, a real member).
contract NexusMutualStakingPoolsWrapperForkTest is BalanceAdapterTestBase {
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
    NexusMutualStakingPoolsWrapper public wrapper;
    WrapperDelegateCaller public account; // the delegatecalling staking account

    bytes32 constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");

    function setUp() public override {
        super.setUp();
        _setupFork();

        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NXM, 18, "NXM");

        adapter = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this), address(0)
        );
        wrapper = new NexusMutualStakingPoolsWrapper(address(adapter), NXM, TOKEN_CONTROLLER);

        // The delegatecalling account is the real actor: it holds SUBMITTER_ROLE, is a Nexus member, and holds NXM.
        account = new WrapperDelegateCaller();
        adapter.grantRole(SUBMITTER_ROLE, address(account));
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

    /// @dev The account's NXM balance.
    function _nxm(address a) internal view returns (uint256) {
        return IERC20(NXM).balanceOf(a);
    }

    /// @dev Assert the adapter's reported NXM balance for `account` equals Nexus's own `getAggregatedTokens` over the
    ///      account's currently-cached ids (delta 0) — the faithful correctness property. The ~65k-wei stake↔shares
    ///      rounding lives entirely inside Nexus's math, which the adapter mirrors exactly.
    function _assertAdapterMatchesNexus(address acct) internal view {
        uint256[] memory ids = adapter.tokenIdsOf(acct);
        uint256 nexusTotal;
        if (ids.length != 0) {
            INexusStakingViewer.AggregatedTokens memory agg =
                INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(ids);
            nexusTotal = agg.totalActiveStake + agg.totalExpiredStake + agg.totalRewards;
        }
        (uint256 bal,) = adapter.getAdapterBalanceForAsset(acct, NXM);
        assertEq(bal, nexusTotal, "adapter balance == Nexus getAggregatedTokens (delta 0)");
    }

    /// @dev Deposit AMOUNT into `pool`'s current active tranche as the account; returns (pool, trancheId, tokenId).
    function _deposit() internal returns (address pool, uint256 trancheId, uint256 tokenId) {
        pool = _firstPublicPool();
        require(pool != address(0), "no public pool found");
        trancheId = block.timestamp / TRANCHE_DURATION;
        tokenId = account.deposit(address(wrapper), pool, AMOUNT, trancheId, 0);
    }

    function test_deposit_realPool_mintsTracksAndValues() public {
        // Before: adapter reports nothing.
        _assertAdapterMatchesNexus(address(account));
        assertEq(adapter.tokenIdsOf(address(account)).length, 0, "untracked before deposit");
        uint256 nxmBefore = _nxm(address(account));

        (,, uint256 tokenId) = _deposit();

        // After: the account spent exactly the deposited amount, and the adapter reports exactly Nexus's staked value.
        assertGt(tokenId, 0, "a StakingNFT was minted");
        assertEq(nxmBefore - _nxm(address(account)), AMOUNT, "account NXM spent == deposited amount");
        uint256[] memory tracked = adapter.tokenIdsOf(address(account));
        assertEq(tracked.length, 1);
        assertEq(tracked[0], tokenId);
        _assertAdapterMatchesNexus(address(account));
    }

    function test_deposit_directCallReverts() public {
        // The module is delegatecall-only — a direct call to the deployed wrapper reverts.
        vm.expectRevert();
        wrapper.depositTo(address(1), AMOUNT, 1, 0);
    }

    function test_depositThenWithdraw_realPool_untracksAndReturnsNxm() public {
        // Before deposit: adapter reports 0.
        _assertAdapterMatchesNexus(address(account));
        uint256 nxmBefore = _nxm(address(account));

        (address pool, uint256 trancheId, uint256 tokenId) = _deposit();

        // After deposit: account spent exactly the deposited amount; adapter mirrors Nexus's staked value exactly.
        assertEq(nxmBefore - _nxm(address(account)), AMOUNT, "account NXM spent == deposited amount");
        assertEq(adapter.tokenIdsOf(address(account)).length, 1, "one tracked id after deposit");
        _assertAdapterMatchesNexus(address(account));

        // Warp past the tranche's expiry so the stake becomes withdrawable. (Note: between expiry and the withdraw's
        // internal processExpirations, Nexus's viewer reverts "expirations not processed", so we don't read it here —
        // the withdraw call below runs the expirations.)
        vm.warp((trancheId + 1) * TRANCHE_DURATION + 1);
        uint256 nxmBeforeWithdraw = _nxm(address(account));

        // FULLY withdraw (stake + rewards) so the position is claimed (zero value) and remove is allowed to untrack it.
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = trancheId;
        (uint256 withdrawnStake, uint256 withdrawnRewards) =
            account.withdraw(address(wrapper), pool, tokenId, true, true, tranches);
        uint256 claimed = withdrawnStake + withdrawnRewards;

        assertGt(claimed, 0, "something was claimed");
        // Nexus pays the NFT owner (the account) directly — the account received exactly the claimed amount.
        assertEq(_nxm(address(account)) - nxmBeforeWithdraw, claimed, "account received == claimed amount");
        // After full withdraw: the id is untracked and the adapter reports 0 (== Nexus for the now-empty cache).
        assertEq(adapter.tokenIdsOf(address(account)).length, 0, "tokenId untracked after withdraw");
        _assertAdapterMatchesNexus(address(account));
    }

    /// @notice Topping up the same StakingNFT (requestTokenId != 0) returns the same id: one tracked id, ~2x stake.
    function test_topUp_sameTokenId_accumulatesStake() public {
        // Before: adapter reports 0.
        _assertAdapterMatchesNexus(address(account));
        uint256 nxmBefore = _nxm(address(account));

        (address pool, uint256 trancheId, uint256 tokenId) = _deposit();

        // After first deposit: account spent exactly AMOUNT; adapter mirrors Nexus.
        assertEq(nxmBefore - _nxm(address(account)), AMOUNT, "account NXM spent == deposited amount (1st)");
        assertEq(adapter.tokenIdsOf(address(account)).length, 1, "one tracked id after first deposit");
        _assertAdapterMatchesNexus(address(account));

        uint256 nxmBeforeTopUp = _nxm(address(account));
        uint256 id2 = account.deposit(address(wrapper), pool, AMOUNT, trancheId, tokenId);

        // After top-up: same id, account spent exactly AMOUNT again, adapter still mirrors Nexus exactly.
        assertEq(id2, tokenId, "top-up returns the same StakingNFT id");
        assertEq(nxmBeforeTopUp - _nxm(address(account)), AMOUNT, "account NXM spent == deposited amount (top-up)");
        assertEq(adapter.tokenIdsOf(address(account)).length, 1, "still one tracked id");
        _assertAdapterMatchesNexus(address(account));
    }

    /// @notice Staking into two distinct pools yields two independently-tracked StakingNFTs, summed in the balance.
    function test_twoPools_distinctTrackedIds() public {
        address[] memory pools = _publicPools(2);
        uint256 trancheId = block.timestamp / TRANCHE_DURATION;

        // Before: adapter reports 0.
        _assertAdapterMatchesNexus(address(account));

        uint256 nxm0 = _nxm(address(account));
        uint256 id0 = account.deposit(address(wrapper), pools[0], AMOUNT, trancheId, 0);
        // After first pool: account spent exactly AMOUNT, one tracked id, adapter mirrors Nexus.
        assertEq(nxm0 - _nxm(address(account)), AMOUNT, "account NXM spent == deposited amount (pool 0)");
        assertEq(adapter.tokenIdsOf(address(account)).length, 1, "one tracked id after first pool");
        _assertAdapterMatchesNexus(address(account));

        uint256 nxm1 = _nxm(address(account));
        uint256 id1 = account.deposit(address(wrapper), pools[1], AMOUNT, trancheId, 0);
        // After second pool: two distinct tracked ids, account spent exactly AMOUNT again, adapter mirrors Nexus.
        assertTrue(id0 != id1, "distinct StakingNFT ids");
        assertEq(nxm1 - _nxm(address(account)), AMOUNT, "account NXM spent == deposited amount (pool 1)");
        assertEq(adapter.tokenIdsOf(address(account)).length, 2, "two tracked ids");
        _assertAdapterMatchesNexus(address(account));
    }

    /// @notice After a wrapper deposit, getAdapterPositions emits a Staking leg keyed by the pool address for the
    ///         account, with the tokenId in positionInstanceId.
    function test_deposit_getAdapterPositions_stakingLeg() public {
        // Before: no positions for the account.
        assertEq(adapter.getAdapterPositions(address(account), address(0)).length, 0, "no positions before deposit");

        (address pool,, uint256 tokenId) = _deposit();

        // After: exactly one Staking leg, valued at exactly Nexus's recorded stake for the new token.
        uint256[] memory one = new uint256[](1);
        one[0] = tokenId;
        INexusStakingViewer.AggregatedTokens memory agg = INexusStakingViewer(STAKING_VIEWER).getAggregatedTokens(one);
        uint256 nexusStake = agg.totalActiveStake + agg.totalExpiredStake + agg.totalRewards;

        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(address(account), address(0));
        assertEq(p.length, 1, "exactly one (Staking) leg for a fresh deposit");
        assertEq(p[0].balanceAsset.asset, NXM);
        assertEq(p[0].positionId, abi.encode(pool), "positionId = staking pool address");
        assertEq(p[0].positionInstanceId, bytes32(tokenId), "tokenId in positionInstanceId");
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Staking), "Staking leg");
        assertEq(p[0].amount, nexusStake, "Staking leg == Nexus's recorded stake for the token");
    }
}
