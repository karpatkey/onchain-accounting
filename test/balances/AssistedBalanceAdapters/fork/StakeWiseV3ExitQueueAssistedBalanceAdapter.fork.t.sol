// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    StakeWiseV3ExitQueueAssistedBalanceAdapter,
    IStakeWiseExitVault
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueAssistedBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {NotExitPositionOwner} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title StakeWiseV3ExitQueueAssistedBalanceAdapterForkTest
/// @notice Fork test against StakeWise's real Genesis vault + VaultsRegistry on mainnet, for the wrapper-fed adapter.
/// @dev Same real ENS-DAO-Safe exit position and pinned states as the prior agent-fed adapter's fork test. The write
///      path is **permissionless self-submit**: the account submits its OWN ticket (the adapter derives the account
///      from `msg.sender`), so the test calls as the real holder. The adapter then values it entirely from live
///      on-chain reads in two states (checkpointed/claimable and fully-pending), asserted against an independent live
///      recompute AND a pinned value.
contract StakeWiseV3ExitQueueAssistedBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant VAULTS_REGISTRY = 0x3a0008a588772446f6e656133C2D5029CC4FC20E;
    address public constant GENESIS_VAULT = 0xAC0F906E433d58FA868F936E8A43230473652885;
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public constant HOLDER = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;
    uint256 public constant TICKET = 241_843_370_089_062_440_762_194;
    uint256 public constant ENTRY_TS = 1_782_159_731;

    uint256 public constant CLAIMABLE_BLOCK = 25_380_000;
    uint256 public constant EXPECTED_CLAIMABLE = 1_000_033_196_791_603_018_908;

    uint256 public constant PENDING_BLOCK = 25_376_000;
    uint256 public constant EXPECTED_PENDING = 999_999_999_999_999_999_999;

    // Two more independent real holders with checkpointed, unclaimed exit positions at MULTI_BLOCK (~59 / ~17.87 ETH).
    uint256 public constant MULTI_BLOCK = 25_440_928;
    address public constant HOLDER_A = 0x044755C6866a83C150c140F61CFD6dD80559CD98;
    uint256 public constant TICKET_A = 0x3369f8c7db81fb8b13d7;
    uint256 public constant ENTRY_TS_A = 1_782_636_371;
    address public constant HOLDER_B = 0x7fc304492ee5CD07bAF900BfD86aFe66A731d82f;
    uint256 public constant TICKET_B = 0x3368929130022f47ef13;
    uint256 public constant ENTRY_TS_B = 1_782_530_135;

    StakeWiseV3ExitQueueAssistedBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        _setupFork();
        adapter = _freshAdapter();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(CLAIMABLE_BLOCK);
    }

    /// @dev Fresh balances harness (native ETH registered) + adapter at the current fork block, with the real holder
    ///      permissionless + self-scoped, so the test submits the real ticket by calling as HOLDER.
    function _freshAdapter() internal returns (StakeWiseV3ExitQueueAssistedBalanceAdapter a) {
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        a = new StakeWiseV3ExitQueueAssistedBalanceAdapter(
            VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(balances), 1 days
        );
    }

    function _liveOwed(uint256 ticket, uint256 ts) internal view returns (uint256) {
        return _liveOwedFor(HOLDER, ticket, ts);
    }

    /// @dev Independent live recompute of the owed assets for `account`'s exit position (mirrors the adapter's math).
    function _liveOwedFor(address account, uint256 ticket, uint256 ts) internal view returns (uint256) {
        IStakeWiseExitVault v = IStakeWiseExitVault(GENESIS_VAULT);
        int256 idx = v.getExitQueueIndex(ticket);
        uint256 queryIdx = idx < 0 ? type(uint256).max : uint256(idx);
        (uint256 left,, uint256 exited) = v.calculateExitedAssets(account, ticket, ts, queryIdx);
        return exited + (left > 0 ? v.convertToAssets(left) : 0);
    }

    function _submit() internal {
        // Before: the adapter reports nothing for HOLDER (proves the submit is what makes the position appear).
        (uint256 owedBefore,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(owedBefore, 0, "zero owed before submit");
        assertEq(adapter.getAdapterPositions(HOLDER, address(0)).length, 0, "no legs before submit");
        assertEq(adapter.positionsOf(HOLDER).length, 0, "not tracked before submit");
        vm.prank(HOLDER);
        adapter.submit(GENESIS_VAULT, TICKET, ENTRY_TS);
    }

    function test_realHolder_claimableValuation() public {
        assertGe(IStakeWiseExitVault(GENESIS_VAULT).getExitQueueIndex(TICKET), 0, "should be checkpointed");
        _submit();
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, _liveOwed(TICKET, ENTRY_TS), "adapter must equal an independent live read (delta 0)");
        assertEq(amount, EXPECTED_CLAIMABLE, "adapter must equal the pinned value");
        assertFalse(isDebt);
    }

    function test_getAdapterPositions_identity() public {
        _submit();
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        assertEq(p.length, 1);
        assertEq(p[0].amount, EXPECTED_CLAIMABLE);
        assertEq(p[0].balanceAsset.asset, NATIVE_ETH);
        assertEq(p[0].balanceAdapter, address(adapter));
        assertEq(p[0].protocolSubId, ProtocolIds.STAKEWISE_V3_EXIT);
        assertEq(p[0].protocolId, ProtocolIds.STAKEWISE_V3);
        assertEq(p[0].positionId, abi.encode(GENESIS_VAULT));
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(p[0].isDebt);
        assertEq(p[0].positionInstanceId, bytes32(TICKET));
    }

    function test_realHolder_pendingValuation() public {
        vm.rollFork(PENDING_BLOCK);
        adapter = _freshAdapter();
        assertEq(IStakeWiseExitVault(GENESIS_VAULT).getExitQueueIndex(TICKET), -1, "should be fully pending");
        _submit();
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, _liveOwed(TICKET, ENTRY_TS), "pending: adapter must equal an independent live read");
        assertEq(amount, EXPECTED_PENDING, "pending: adapter must equal the pinned value");
        assertGt(amount, 0);
    }

    function test_unsubmitted_reportsZero() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(HOLDER, address(0)).length, 0);
    }

    function test_submit_revertsOnTupleNotOwnedByAccount() public {
        // A stranger submitting a real ticket it does not own → owed 0 for the caller → NotExitPositionOwner.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotExitPositionOwner.selector, stranger, GENESIS_VAULT, TICKET));
        adapter.submit(GENESIS_VAULT, TICKET, ENTRY_TS);
        assertEq(adapter.positionsOf(stranger).length, 0);
    }

    /// @notice Happy path: two independent real holders each self-submit their own checkpointed position; the adapter
    ///         values each against an independent live recompute and keeps the sets isolated (no cross-contamination).
    function test_realHolders_multipleAccounts_valuedLive() public {
        vm.rollFork(MULTI_BLOCK);
        adapter = _freshAdapter();

        // Before: the adapter reports nothing for either holder.
        (uint256 aBefore,) = adapter.getAdapterBalanceForAsset(HOLDER_A, NATIVE_ETH);
        (uint256 bBefore,) = adapter.getAdapterBalanceForAsset(HOLDER_B, NATIVE_ETH);
        assertEq(aBefore, 0, "A zero before submit");
        assertEq(bBefore, 0, "B zero before submit");

        vm.prank(HOLDER_A);
        adapter.submit(GENESIS_VAULT, TICKET_A, ENTRY_TS_A);
        vm.prank(HOLDER_B);
        adapter.submit(GENESIS_VAULT, TICKET_B, ENTRY_TS_B);

        uint256 owedA = _liveOwedFor(HOLDER_A, TICKET_A, ENTRY_TS_A);
        uint256 owedB = _liveOwedFor(HOLDER_B, TICKET_B, ENTRY_TS_B);
        assertGt(owedA, 0);
        assertGt(owedB, 0);

        (uint256 a,) = adapter.getAdapterBalanceForAsset(HOLDER_A, NATIVE_ETH);
        (uint256 b,) = adapter.getAdapterBalanceForAsset(HOLDER_B, NATIVE_ETH);
        assertEq(a, owedA, "holder A valued to an independent live read");
        assertEq(b, owedB, "holder B valued to an independent live read");

        // Each account sees only its own position, as a single Supplied leg carrying its own ticket.
        INAVCalculator.PositionBalance[] memory pA = adapter.getAdapterPositions(HOLDER_A, address(0));
        assertEq(pA.length, 1);
        assertEq(pA[0].positionInstanceId, bytes32(TICKET_A));
        assertEq(pA[0].amount, owedA);
        INAVCalculator.PositionBalance[] memory pB = adapter.getAdapterPositions(HOLDER_B, address(0));
        assertEq(pB.length, 1);
        assertEq(pB[0].positionInstanceId, bytes32(TICKET_B));
        assertEq(pB[0].amount, owedB);
        assertEq(adapter.positionsOf(HOLDER_A).length, 1);
        assertEq(adapter.positionsOf(HOLDER_B).length, 1);
    }
}
