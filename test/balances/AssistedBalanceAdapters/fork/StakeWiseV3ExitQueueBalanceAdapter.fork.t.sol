// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.fork.sol";
import {BalancesHarnessForFork} from "test/TestSetupHelpers.sol";
import {
    StakeWiseV3ExitQueueBalanceAdapter,
    IStakeWiseExitVault
} from "src/balances/AssistedBalanceAdapters/StakeWiseV3ExitQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {InvalidExitPosition} from "src/errors.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {ProtocolIds} from "src/utils/ProtocolIds.sol";

/// @title StakeWiseV3ExitQueueBalanceAdapterForkTest
/// @notice Fork test against StakeWise's real Genesis vault + VaultsRegistry on mainnet.
/// @dev Exit positions aren't enumerable, so the agent (here, the test acting as owner) submits a real
///      (vault, positionTicket, timestamp) tuple; the adapter values it entirely from live on-chain reads. The
///      tuple is a real exit request entered by the ENS DAO Safe (`0x4F20…FE64`, a KPK-managed account) into the
///      Genesis vault — discovered via the `ExitQueueEntered(owner, receiver, positionTicket, shares)` event. The
///      same position is read in two states:
///        - CLAIMABLE_BLOCK: checkpointed, fully exited (leftShares 0), `exitedAssets` claimable.
///        - PENDING_BLOCK: not yet checkpointed (`getExitQueueIndex == -1`); valued via the still-queued shares
///          using the out-of-range-index path (the subtle branch ADR 0014 flagged).
///      Both states are asserted against an independent live recompute (delta 0) AND a pinned value.
contract StakeWiseV3ExitQueueBalanceAdapterForkTest is BalanceAdapterTestBase {
    address public constant VAULTS_REGISTRY = 0x3a0008a588772446f6e656133C2D5029CC4FC20E;
    address public constant GENESIS_VAULT = 0xAC0F906E433d58FA868F936E8A43230473652885;
    /// @dev ERC-7528 native-ETH sentinel — what StakeWise mainnet vaults settle in and how the adapter denominates.
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Real ENS-Safe exit position entered at block 25,375,501 (ts 1,782,159,731), ticket below.
    address public constant HOLDER = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;
    uint256 public constant TICKET = 241_843_370_089_062_440_762_194;
    uint256 public constant ENTRY_TS = 1_782_159_731;

    /// @dev Checkpointed/claimable state — `getExitQueueIndex == 1465`, leftShares 0, exitedAssets pinned below.
    uint256 public constant CLAIMABLE_BLOCK = 25_380_000;
    uint256 public constant EXPECTED_CLAIMABLE = 1_000_033_196_791_603_018_908; // ~1000.03 ETH exited (claimable)

    /// @dev Fully-pending state — `getExitQueueIndex == -1`; valued via convertToAssets(full queued shares).
    uint256 public constant PENDING_BLOCK = 25_376_000;
    uint256 public constant EXPECTED_PENDING = 999_999_999_999_999_999_999; // ~1000 ETH still queued

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

    /// @dev Deploy a fresh balances harness (native ETH registered) + adapter at the current fork block. Re-called
    ///      after rolling so reads happen against the right block without cross-fork persistence ambiguity.
    function _freshAdapter() internal returns (StakeWiseV3ExitQueueBalanceAdapter) {
        balances = new BalancesHarnessForFork();
        balances.registerAssetForTest(NATIVE_ETH, 18, "ETH");
        // admin = assistant = this test, so it plays the agent and submits the real tuple.
        return new StakeWiseV3ExitQueueBalanceAdapter(
            VAULTS_REGISTRY, NATIVE_ETH, "osETH", address(balances), 1 days, address(this), address(this)
        );
    }

    /// @dev Independent live recompute of the position, mirroring the adapter's queue math.
    function _liveOwed(uint256 ticket, uint256 ts) internal view returns (uint256) {
        IStakeWiseExitVault v = IStakeWiseExitVault(GENESIS_VAULT);
        int256 idx = v.getExitQueueIndex(ticket);
        uint256 queryIdx = idx < 0 ? type(uint256).max : uint256(idx);
        (uint256 left,, uint256 exited) = v.calculateExitedAssets(HOLDER, ticket, ts, queryIdx);
        return exited + (left > 0 ? v.convertToAssets(left) : 0);
    }

    function _submit() internal {
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory p =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](1);
        p[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(GENESIS_VAULT, TICKET, ENTRY_TS);
        adapter.submitPositions(HOLDER, p);
    }

    // ---- Claimable state: strict equality vs live read + pinned value ----

    function test_realHolder_claimableValuation() public {
        // Sanity: the position is checkpointed (idx >= 0) at this block.
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
        assertEq(p[0].protocolId, ProtocolIds.STAKEWISE_V3_EXIT);
        assertEq(p[0].positionId, abi.encode(GENESIS_VAULT)); // static per-vault positionId
        assertEq(uint8(p[0].positionKind), uint8(PositionKind.Supplied));
        assertFalse(p[0].isDebt);
        _assertTicketLeg(p[0]);
        assertEq(p[0].positionInstanceId, bytes32(TICKET), "positionInstanceId = ticket");
    }

    /// @dev Sum-based check: per-request legs (claimable + locked) sum to the aggregate `_assetsOwed`, share the
    ///      per-vault positionId, and carry a "Ticket #<id>" leaf label.
    function test_getAdapterPositions_legsSumToAggregate() public {
        _submit();
        INAVCalculator.PositionBalance[] memory p = adapter.getAdapterPositions(HOLDER, address(0));
        bytes memory expectedId = abi.encode(GENESIS_VAULT);
        uint256 total;
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(p[i].positionId, expectedId, "legs share the static per-vault positionId");
            _assertTicketLeg(p[i]);
            total += p[i].amount;
        }
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(total, agg, "sum of per-request legs == aggregate");
    }

    /// @dev Asserts a per-request leg: the static breadcrumb is `["Exit Queue", "osETH"]` (positionId-derived receipt-token
    ///      category, no ephemeral id), and the positionTicket rides in the typed `positionInstanceId`.
    function _assertTicketLeg(INAVCalculator.PositionBalance memory leg) internal view {
        string[] memory labels = adapter.positionLabels(leg.positionId);
        assertEq(labels.length, 2, "static breadcrumb = [category]");
        assertEq(labels[0], "Exit Queue");
        assertEq(labels[1], "osETH");
        assertTrue(leg.positionInstanceId != bytes32(0), "positionInstanceId carries the ticket");
    }

    // ---- Fully-pending state: the out-of-range-index valuation path ----

    function test_realHolder_pendingValuation() public {
        vm.rollFork(PENDING_BLOCK);
        adapter = _freshAdapter();

        // Sanity: not yet checkpointed at this earlier block.
        assertEq(IStakeWiseExitVault(GENESIS_VAULT).getExitQueueIndex(TICKET), -1, "should be fully pending");

        _submit();
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, _liveOwed(TICKET, ENTRY_TS), "pending: adapter must equal an independent live read");
        assertEq(amount, EXPECTED_PENDING, "pending: adapter must equal the pinned value");
        assertGt(amount, 0, "fully-pending position must still be valued");
    }

    // ---- Negative cases against the real contracts ----

    function test_unsubmitted_reportsZero() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(HOLDER, NATIVE_ETH);
        assertEq(amount, 0);
        assertEq(adapter.getAdapterPositions(HOLDER, address(0)).length, 0);
    }

    function test_submit_revertsOnTupleNotOwnedByAccount() public {
        // Submitting the real tuple under a different account → calculateExitedAssets(stranger,…) == 0 → reverts
        // (fail-loud; the zero owed amount is the on-chain ownership proxy).
        address stranger = makeAddr("stranger");
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory p =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](1);
        p[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(GENESIS_VAULT, TICKET, ENTRY_TS);
        vm.expectRevert(abi.encodeWithSelector(InvalidExitPosition.selector, stranger, GENESIS_VAULT, TICKET));
        adapter.submitPositions(stranger, p);
        assertEq(adapter.positionsOf(stranger).length, 0);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(stranger, NATIVE_ETH);
        assertEq(amount, 0);
    }

    function test_submit_revertsOnUnregisteredVault() public {
        // A non-StakeWise address is rejected at write (VaultsRegistry.vaults == false) — fail-loud.
        StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[] memory p =
            new StakeWiseV3ExitQueueBalanceAdapter.ExitPosition[](1);
        p[0] = StakeWiseV3ExitQueueBalanceAdapter.ExitPosition(MAINNET_WETH, TICKET, ENTRY_TS);
        vm.expectRevert(abi.encodeWithSelector(InvalidExitPosition.selector, HOLDER, MAINNET_WETH, TICKET));
        adapter.submitPositions(HOLDER, p);
        assertEq(adapter.positionsOf(HOLDER).length, 0);
    }
}
