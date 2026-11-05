// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    EtherFiWithdrawalQueueAssistedBalanceAdapter,
    IEtherFiWithdrawRequestNFT
} from "src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueAssistedBalanceAdapter.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {
    NexusMutualStakingPoolsAssistedBalanceAdapter,
    INexusStakingViewer
} from "src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {CoordinateNotOwned} from "src/errors.sol";

interface IEtherFiClaim {
    function claimWithdraw(uint256 tokenId) external;
}

interface IERC721TransferFrom {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IStakeWiseClaim {
    function claimExitedAssets(uint256 positionTicket, uint256 timestamp, uint256 exitQueueIndex) external;
    function getExitQueueIndex(uint256 positionTicket) external view returns (int256);
}

interface INexusPoolWithdraw {
    function withdraw(uint256 tokenId, bool withdrawStake, bool withdrawRewards, uint256[] memory trancheIds)
        external
        returns (uint256 withdrawnStake, uint256 withdrawnRewards);
}

interface IERC20BalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title Keeper-filed positions stop counting once their owner empties them (ADR 0030, no over-report)
/// @notice Each case takes a REAL holder's position that was never fed through an assistant, files it from a keeper
///         with `submitFor`, then has the holder empty it directly at the protocol (claim, withdraw or transfer, no
///         assistant). The coordinate stays cached — nobody calls `removeFor` — so these pin that the NAV read values
///         it live: the emptied part reports nothing in the same block, and what was reported before never exceeds
///         what the protocol paid out plus what is still reported.
contract AssistedKeeperFiledThenEmptiedForkTest is BalanceAdapterTestBase {
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
    }

    function _setupFork() internal override {}

    function _rollTo(uint256 blockNumber, address underlying, string memory symbol) internal {
        vm.rollFork(blockNumber);
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(underlying, 18, symbol);
    }

    function _sum(INAVCalculator.PositionBalance[] memory legs) internal pure returns (uint256 total) {
        for (uint256 i; i < legs.length; ++i) {
            assertFalse(legs[i].isDebt, "credit legs only");
            total += legs[i].amount;
        }
    }

    /// @dev Over-report check: the value reported before emptying must be covered by what the protocol actually paid
    ///      out plus what the adapter still reports afterwards. Under-reporting before (e.g. Nexus rewards accrued
    ///      since the viewer's last update) passes; reporting more than existed does not.
    function _assertNoOverReport(string memory label, uint256 reportedBefore, uint256 reportedAfter, uint256 paidOut)
        internal
    {
        emit log_named_uint(string.concat(label, ": reported before"), reportedBefore);
        emit log_named_uint(string.concat(label, ": paid out"), paidOut);
        emit log_named_uint(string.concat(label, ": reported after"), reportedAfter);
        assertLe(reportedBefore, reportedAfter + paidOut, string.concat(label, ": over-report"));
    }

    // ---- ether.fi ----

    address internal constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address internal constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address internal constant EF_HOLDER = 0xcFFab3dFdCa60d838512c41a772e799b71dF1Af4; // EOA, never used an assistant
    uint256 internal constant EF_TOKEN = 80_154; // pending at 25,387,000, finalized and unclaimed at 25,500,000

    function _etherfi() internal returns (EtherFiWithdrawalQueueAssistedBalanceAdapter a) {
        a = new EtherFiWithdrawalQueueAssistedBalanceAdapter(
            WITHDRAW_REQUEST_NFT, LIQUIDITY_POOL, NATIVE_ETH, address(balances), address(this)
        );
        a.grantRole(a.SUBMITTER_ROLE(), keeper);
    }

    function test_etherfi_claimedDirectly_readsZero() public {
        _rollTo(25_500_000, NATIVE_ETH, "ETH");
        EtherFiWithdrawalQueueAssistedBalanceAdapter a = _etherfi();
        assertTrue(IEtherFiWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).isFinalized(EF_TOKEN), "fixture: claimable");

        vm.prank(keeper);
        a.submitFor(EF_HOLDER, abi.encode(EF_TOKEN));
        uint256 reportedBefore = _sum(a.getAdapterPositions(EF_HOLDER, address(0)));
        assertGt(reportedBefore, 0, "counted once filed");

        uint256 eth0 = EF_HOLDER.balance;
        vm.prank(EF_HOLDER);
        IEtherFiClaim(WITHDRAW_REQUEST_NFT).claimWithdraw(EF_TOKEN); // burns the NFT, pays ETH
        uint256 paidOut = EF_HOLDER.balance - eth0;

        assertEq(a.coordsOf(EF_HOLDER).length, 1, "the stale coordinate is still cached");
        assertEq(a.getAdapterPositions(EF_HOLDER, address(0)).length, 0, "claimed request reports nothing");
        (uint256 owed,) = a.getAdapterBalanceForAsset(EF_HOLDER, NATIVE_ETH);
        assertEq(owed, 0, "balance getter agrees");
        _assertNoOverReport("ether.fi claim", reportedBefore, 0, paidOut);

        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, EF_HOLDER, EF_TOKEN));
        vm.prank(keeper);
        a.submitFor(EF_HOLDER, abi.encode(EF_TOKEN));
        vm.prank(stranger);
        a.removeFor(EF_HOLDER, abi.encode(EF_TOKEN));
        assertEq(a.coordsOf(EF_HOLDER).length, 0);
    }

    /// @notice The keeper files the request for its old AND its new owner: only the current owner counts it.
    function test_etherfi_transferredAway_countedOnce() public {
        _rollTo(25_387_000, NATIVE_ETH, "ETH");
        EtherFiWithdrawalQueueAssistedBalanceAdapter a = _etherfi();
        vm.prank(keeper);
        a.submitFor(EF_HOLDER, abi.encode(EF_TOKEN));
        uint256 reportedBefore = _sum(a.getAdapterPositions(EF_HOLDER, address(0)));
        assertGt(reportedBefore, 0);

        vm.prank(EF_HOLDER);
        IERC721TransferFrom(WITHDRAW_REQUEST_NFT).transferFrom(EF_HOLDER, stranger, EF_TOKEN);
        vm.prank(keeper);
        a.submitFor(stranger, abi.encode(EF_TOKEN));

        assertEq(_sum(a.getAdapterPositions(EF_HOLDER, address(0))), 0, "old owner reads 0");
        assertEq(_sum(a.getAdapterPositions(stranger, address(0))), reportedBefore, "new owner reads it once");
    }

    // ---- StakeWise V3 ----

    address internal constant VAULTS_REGISTRY = 0x3a0008a588772446f6e656133C2D5029CC4FC20E;
    address internal constant GENESIS_VAULT = 0xAC0F906E433d58FA868F936E8A43230473652885;

    function _stakewise() internal returns (StakeWiseV3ExitQueueAssistedBalanceAdapter a) {
        a = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(balances), 1 days, address(this)
        );
        a.grantRole(a.SUBMITTER_ROLE(), keeper);
    }

    function _claimDirectly(address holder, uint256 ticket, uint256 ts) internal returns (uint256 paidOut) {
        int256 i = IStakeWiseClaim(GENESIS_VAULT).getExitQueueIndex(ticket);
        uint256 exitQueueIndex = i < 0 ? type(uint256).max : uint256(i);
        uint256 eth0 = holder.balance;
        vm.prank(holder);
        IStakeWiseClaim(GENESIS_VAULT).claimExitedAssets(ticket, ts, exitQueueIndex);
        paidOut = holder.balance - eth0;
    }

    /// @notice The holder fully claimed this ticket at block 25,382,071; replayed one block earlier.
    function test_stakewise_fullyClaimedDirectly_readsZero() public {
        address holder = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;
        uint256 ticket = 241_843_370_089_062_440_762_194;
        uint256 ts = 1_782_159_731;
        _rollTo(25_382_070, NATIVE_ETH, "ETH");
        StakeWiseV3ExitQueueAssistedBalanceAdapter a = _stakewise();

        bytes memory coord = abi.encode(GENESIS_VAULT, ticket, ts);
        vm.prank(keeper);
        a.submitFor(holder, coord);
        uint256 reportedBefore = _sum(a.getAdapterPositions(holder, address(0)));
        assertGt(reportedBefore, 0);

        uint256 paidOut = _claimDirectly(holder, ticket, ts);

        assertEq(a.coordsOf(holder).length, 1, "the stale coordinate is still cached");
        assertEq(a.getAdapterPositions(holder, address(0)).length, 0, "claimed request reports nothing");
        (uint256 owed,) = a.getAdapterBalanceForAsset(holder, NATIVE_ETH);
        assertEq(owed, 0, "balance getter agrees");
        _assertNoOverReport("StakeWise full claim", reportedBefore, 0, paidOut);

        vm.prank(stranger);
        a.removeFor(holder, coord);
    }

    /// @notice A partial claim made directly (not through the assistant) deletes the filed ticket and re-queues the
    ///         rest under a new one (the real `ExitedAssetsClaimed` at block 25,836,981). The old ticket stops
    ///         counting at once; the remainder counts only after it is filed — never both.
    function test_stakewise_partiallyClaimedDirectly_neverDoubleCounts() public {
        address holder = 0x34284C27A2304132aF751b0dEc5bBa2CF98eD039;
        uint256 ticket = 253_084_580_248_056_438_094_483;
        uint256 ts = 1_787_631_515;
        uint256 remainderTicket = 253_084_938_748_546_616_225_773;
        _rollTo(25_836_980, NATIVE_ETH, "ETH");
        StakeWiseV3ExitQueueAssistedBalanceAdapter a = _stakewise();

        vm.prank(keeper);
        a.submitFor(holder, abi.encode(GENESIS_VAULT, ticket, ts));
        uint256 reportedBefore = _sum(a.getAdapterPositions(holder, address(0)));
        assertGt(reportedBefore, 0);

        uint256 paidOut = _claimDirectly(holder, ticket, ts);
        assertEq(_sum(a.getAdapterPositions(holder, address(0))), 0, "claimed ticket reports nothing");

        vm.prank(keeper);
        a.submitFor(holder, abi.encode(GENESIS_VAULT, remainderTicket, ts));
        uint256 reportedAfter = _sum(a.getAdapterPositions(holder, address(0)));
        assertGt(reportedAfter, 0, "remainder counted once filed");
        _assertNoOverReport("StakeWise partial claim", reportedBefore, reportedAfter, paidOut);
    }

    // ---- Nexus Mutual ----

    address internal constant STAKING_NFT = 0xcafea508a477D94c502c253A58239fb8F948e97f;
    address internal constant STAKING_VIEWER = 0xcafea5c7d25a192ba70ECA0E2dB62F835c1cF81F;
    address internal constant NXM = 0xd7c49CEE7E9188cCa6AD8FF264C1DA2e69D4Cf3B;
    address internal constant NX_HOLDER = 0x8e53D04644E9ab0412a8c6bd228C84da7664cFE3; // Nexus Mutual Safe
    uint256 internal constant NX_TOKEN = 180;
    uint256 internal constant NX_BLOCK = 25_388_000;
    uint256 internal constant TRANCHE_DURATION = 91 days;

    function _nexus() internal returns (NexusMutualStakingPoolsAssistedBalanceAdapter a) {
        a = new NexusMutualStakingPoolsAssistedBalanceAdapter(
            STAKING_NFT, STAKING_VIEWER, NXM, address(balances), address(this)
        );
        a.grantRole(a.SUBMITTER_ROLE(), keeper);
        vm.prank(keeper);
        a.submitFor(NX_HOLDER, abi.encode(NX_TOKEN));
    }

    /// @return t The live token, `pool` its staking pool and `tranches` the tranche ids it has deposits in.
    function _nexusToken()
        internal
        view
        returns (INexusStakingViewer.Token memory t, address pool, uint256[] memory tranches, uint256 lastTranche)
    {
        uint256[] memory one = new uint256[](1);
        one[0] = NX_TOKEN;
        t = INexusStakingViewer(STAKING_VIEWER).getTokens(one)[0];
        pool = INexusStakingViewer(STAKING_VIEWER).stakingPool(t.poolId);
        tranches = new uint256[](t.deposits.length);
        for (uint256 i; i < t.deposits.length; ++i) {
            tranches[i] = t.deposits[i].trancheId;
            if (tranches[i] > lastTranche) lastTranche = tranches[i];
        }
    }

    /// @notice Rewards withdrawn directly: the Rewards leg disappears and the untouched stake is all that remains.
    function test_nexus_rewardsWithdrawnDirectly_rewardsLegGone() public {
        _rollTo(NX_BLOCK, NXM, "NXM");
        NexusMutualStakingPoolsAssistedBalanceAdapter a = _nexus();
        uint256 reportedBefore = _sum(a.getAdapterPositions(NX_HOLDER, address(0)));
        (INexusStakingViewer.Token memory t, address pool, uint256[] memory tranches,) = _nexusToken();

        uint256 nxm0 = IERC20BalanceOf(NXM).balanceOf(NX_HOLDER);
        vm.prank(NX_HOLDER);
        INexusPoolWithdraw(pool).withdraw(NX_TOKEN, false, true, tranches);
        uint256 paidOut = IERC20BalanceOf(NXM).balanceOf(NX_HOLDER) - nxm0;

        INAVCalculator.PositionBalance[] memory legs = a.getAdapterPositions(NX_HOLDER, address(0));
        assertEq(legs.length, 1, "only the Staking leg is left");
        assertEq(legs[0].amount, t.activeStake + t.expiredStake, "and it is the untouched stake");
        _assertNoOverReport("Nexus rewards withdrawal", reportedBefore, legs[0].amount, paidOut);
    }

    /// @notice Full exit after every tranche has expired. Nexus never burns the StakingNFT, so the id stays owned and
    ///         cached; it must still report nothing.
    function test_nexus_fullyWithdrawnDirectly_readsZero() public {
        _rollTo(NX_BLOCK, NXM, "NXM");
        NexusMutualStakingPoolsAssistedBalanceAdapter a = _nexus();
        uint256 reportedBefore = _sum(a.getAdapterPositions(NX_HOLDER, address(0)));
        (, address pool, uint256[] memory tranches, uint256 lastTranche) = _nexusToken();

        vm.warp((lastTranche + 1) * TRANCHE_DURATION + 1);
        uint256 nxm0 = IERC20BalanceOf(NXM).balanceOf(NX_HOLDER);
        vm.prank(NX_HOLDER);
        INexusPoolWithdraw(pool).withdraw(NX_TOKEN, true, true, tranches);
        uint256 paidOut = IERC20BalanceOf(NXM).balanceOf(NX_HOLDER) - nxm0;

        assertEq(a.coordsOf(NX_HOLDER).length, 1, "the emptied NFT is still cached");
        assertEq(a.getAdapterPositions(NX_HOLDER, address(0)).length, 0, "emptied NFT reports nothing");
        _assertNoOverReport("Nexus full withdrawal", reportedBefore, 0, paidOut);

        vm.prank(stranger);
        a.removeFor(NX_HOLDER, abi.encode(NX_TOKEN));
    }

    /// @notice The keeper files the NFT for its old AND its new owner: only the current owner counts it.
    function test_nexus_transferredAway_countedOnce() public {
        _rollTo(NX_BLOCK, NXM, "NXM");
        NexusMutualStakingPoolsAssistedBalanceAdapter a = _nexus();
        uint256 reportedBefore = _sum(a.getAdapterPositions(NX_HOLDER, address(0)));
        assertGt(reportedBefore, 0);

        vm.prank(NX_HOLDER);
        IERC721TransferFrom(STAKING_NFT).transferFrom(NX_HOLDER, stranger, NX_TOKEN);
        vm.prank(keeper);
        a.submitFor(stranger, abi.encode(NX_TOKEN));

        assertEq(_sum(a.getAdapterPositions(NX_HOLDER, address(0))), 0, "old owner reads 0");
        assertEq(_sum(a.getAdapterPositions(stranger, address(0))), reportedBefore, "new owner reads it once");
    }
}
