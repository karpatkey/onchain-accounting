// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    StakeWiseV3ExitQueueBalanceAdapter
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBalanceAdapter.sol";
import {IStakeWiseExitVault} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBase.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title StakeWiseV3ExitQueueBalanceAdapterForkTest
/// @notice Fork test against StakeWise's real Genesis vault + VaultsRegistry on mainnet, for the wrapper-fed adapter.
/// @dev Same real ENS-DAO-Safe exit position and pinned states as the assisted adapter's fork test (the valuation is
///      shared via `StakeWiseV3ExitQueueBase`). The difference here is the write path: the adapter is fed by a
///      **role-gated self-submit** — the account grants itself `DEPOSITOR_ROLE` (here the test, playing admin, grants
///      the real holder) and submits its OWN ticket (`account == msg.sender`). The adapter then values it entirely
///      from live on-chain reads in two states (checkpointed/claimable and fully-pending), asserted against an
///      independent live recompute AND a pinned value.
contract StakeWiseV3ExitQueueBalanceAdapterForkTest is BalanceAdapterTestBase {
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

    StakeWiseV3ExitQueueBalanceAdapter public adapter;

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
    ///      approved as a depositor so it can self-submit its real ticket.
    function _freshAdapter() internal returns (StakeWiseV3ExitQueueBalanceAdapter a) {
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        a = new StakeWiseV3ExitQueueBalanceAdapter(
            VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(balances), 1 days, address(this)
        );
        a.grantRole(a.DEPOSITOR_ROLE(), HOLDER);
    }

    function _liveOwed(uint256 ticket, uint256 ts) internal view returns (uint256) {
        IStakeWiseExitVault v = IStakeWiseExitVault(GENESIS_VAULT);
        int256 idx = v.getExitQueueIndex(ticket);
        uint256 queryIdx = idx < 0 ? type(uint256).max : uint256(idx);
        (uint256 left,, uint256 exited) = v.calculateExitedAssets(HOLDER, ticket, ts, queryIdx);
        return exited + (left > 0 ? v.convertToAssets(left) : 0);
    }

    function _submit() internal {
        vm.prank(HOLDER);
        adapter.submit(HOLDER, GENESIS_VAULT, TICKET, ENTRY_TS);
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
        // A stranger with the role submitting its OWN (address) but a ticket it does not own → owed 0 → fail-loud.
        address stranger = makeAddr("stranger");
        adapter.grantRole(adapter.DEPOSITOR_ROLE(), stranger);
        vm.prank(stranger);
        vm.expectRevert();
        adapter.submit(stranger, GENESIS_VAULT, TICKET, ENTRY_TS);
        assertEq(adapter.positionsOf(stranger).length, 0);
    }
}
