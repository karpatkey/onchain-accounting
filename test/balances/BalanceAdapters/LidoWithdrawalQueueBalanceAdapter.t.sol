// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    LidoWithdrawalQueueBalanceAdapter,
    ILidoWithdrawalQueue
} from "src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of Lido's WithdrawalQueueERC721.
/// @dev Mirrors the view methods the adapter reads: `balanceOf`, `getWithdrawalRequests`,
///      `getWithdrawalStatus`, `getLastCheckpointIndex`, `findCheckpointHints`, and
///      `getClaimableEther`. `STETH()` is deliberately omitted so the adapter's `_cappedOwed` call
///      fail-opens, valuing not-yet-finalized requests at their request-time `amountOfStETH`.
contract MockLidoWithdrawalQueue {
    mapping(address => uint256[]) private _ids;
    mapping(uint256 => ILidoWithdrawalQueue.WithdrawalRequestStatus) private _status;
    mapping(uint256 => uint256) private _claimable; // exact claimable ETH for finalized requests

    /// @notice Push a not-yet-finalized request (adapter values it via amountOfStETH).
    function pushRequest(address owner, uint256 id, uint256 amountOfStETH, bool isClaimed) external {
        _ids[owner].push(id);
        _status[id] = ILidoWithdrawalQueue.WithdrawalRequestStatus({
            amountOfStETH: amountOfStETH,
            amountOfShares: amountOfStETH, // shares ~ stETH for the mock; the adapter reads it only via STETH(), which this mock omits
            owner: owner,
            timestamp: 0,
            isFinalized: false,
            isClaimed: isClaimed
        });
    }

    /// @notice Push a finalized, un-claimed request whose exact claimable ETH may differ from amountOfStETH.
    function pushFinalizedRequest(address owner, uint256 id, uint256 amountOfStETH, uint256 claimableEth) external {
        _ids[owner].push(id);
        _status[id] = ILidoWithdrawalQueue.WithdrawalRequestStatus({
            amountOfStETH: amountOfStETH,
            amountOfShares: amountOfStETH,
            owner: owner,
            timestamp: 0,
            isFinalized: true,
            isClaimed: false
        });
        _claimable[id] = claimableEth;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _ids[owner].length;
    }

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory) {
        return _ids[owner];
    }

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses)
    {
        statuses = new ILidoWithdrawalQueue.WithdrawalRequestStatus[](requestIds.length);
        for (uint256 i = 0; i < requestIds.length; i++) {
            statuses[i] = _status[requestIds[i]];
        }
    }

    function getLastCheckpointIndex() external pure returns (uint256) {
        return 1; // non-zero so the adapter takes the claimable-ETH path
    }

    function findCheckpointHints(uint256[] calldata requestIds, uint256, uint256)
        external
        view
        returns (uint256[] memory hints)
    {
        hints = new uint256[](requestIds.length);
        uint256 prev = 0;
        for (uint256 i = 0; i < requestIds.length; i++) {
            // mirror Lido: reverts unless the id array is ascending-sorted
            require(requestIds[i] >= prev, "RequestIdsNotSorted");
            prev = requestIds[i];
            // a hint exists only for finalized requests, else 0
            if (_status[requestIds[i]].isFinalized) hints[i] = 1;
        }
    }

    function getClaimableEther(uint256[] calldata requestIds, uint256[] calldata)
        external
        view
        returns (uint256[] memory claimableEthValues)
    {
        claimableEthValues = new uint256[](requestIds.length);
        for (uint256 i = 0; i < requestIds.length; i++) {
            ILidoWithdrawalQueue.WithdrawalRequestStatus storage s = _status[requestIds[i]];
            // mirror Lido: claimable only for finalized & un-claimed requests
            if (s.isFinalized && !s.isClaimed) claimableEthValues[i] = _claimable[requestIds[i]];
        }
    }
}

/// @title LidoWithdrawalQueueBalanceAdapter unit tests
contract LidoWithdrawalQueueBalanceAdapterTest is BalanceAdapterTestBase {
    string internal constant POSITION_DETAIL_BASE =
        "{\"protocol\":\"Lido\",\"product\":\"Staking\",\"name\":\"stETH Withdrawal Queue\"";
    string internal constant POSITION_DETAIL_FULL =
        "{\"protocol\":\"Lido\",\"product\":\"Staking\",\"name\":\"stETH Withdrawal Queue\",\"type\":\"Staking\"}";

    LidoWithdrawalQueueBalanceAdapter public adapter;
    MockLidoWithdrawalQueue public queue;

    // `weth` (registered in the base) stands in for the native-ETH payout as the underlying.
    function setUp() public override {
        super.setUp();
        queue = new MockLidoWithdrawalQueue();
        adapter = new LidoWithdrawalQueueBalanceAdapter(address(queue), address(weth), address(balances));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroQueue() public {
        vm.expectRevert(InvalidArguments.selector);
        new LidoWithdrawalQueueBalanceAdapter(address(0), address(weth), address(balances));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new LidoWithdrawalQueueBalanceAdapter(address(queue), address(0), address(balances));
    }

    function test_constructor_revertsWhenQueueNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "WithdrawalQueue"));
        new LidoWithdrawalQueueBalanceAdapter(eoa, address(weth), address(balances));
    }

    function test_constructor_revertsWhenNAVNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new LidoWithdrawalQueueBalanceAdapter(address(queue), address(weth), eoa);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xdeadbeef));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
    }

    // ---- getAdapterBalanceForAsset ----

    function test_getAdapterBalanceForAsset_zeroAsset() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_zeroAccount() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(weth));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_singleOpenRequest() public {
        queue.pushRequest(alice, 1, 2.5e18, false);
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 2.5e18);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_multipleRequestsSummed() public {
        queue.pushRequest(alice, 1, 2.5e18, false);
        queue.pushRequest(alice, 2, 1.1e18, false);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 3.6e18);
    }

    function test_getAdapterBalanceForAsset_finalizedUsesClaimableEth() public {
        // Finalized below amountOfStETH (e.g. after a negative rebase): the adapter must use the
        // exact claimable ETH for the finalized request, and amountOfStETH for the pending one.
        queue.pushFinalizedRequest(alice, 1, 3e18, 2.9e18); // finalized: claimable 2.9 < 3.0 stETH
        queue.pushRequest(alice, 2, 1e18, false); // pending: valued at amountOfStETH
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 2.9e18 + 1e18, "finalized uses claimable ETH; pending uses amountOfStETH");
    }

    function test_getAdapterBalanceForAsset_finalizedRequestsUnsortedOrder() public {
        // getWithdrawalRequests can return ids in non-ascending order (Lido's EnumerableSet does
        // swap-and-pop on claim). Lido's findCheckpointHints reverts on an unsorted batch, so the
        // adapter must resolve each finalized request's claimable ETH per-request. ids = [30, 20].
        queue.pushFinalizedRequest(alice, 30, 3e18, 2.95e18);
        queue.pushFinalizedRequest(alice, 20, 2e18, 2e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 2.95e18 + 2e18, "per-request hint lookup avoids the sorted-batch revert");
    }

    function test_getAdapterBalanceForAsset_skipsClaimed() public {
        queue.pushRequest(alice, 1, 2e18, true); // claimed
        queue.pushRequest(alice, 2, 3e18, false);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 3e18, "Claimed request must be excluded");
    }

    function test_getAdapterBalanceForAsset_sumsUpToCap() public {
        uint256 cap = adapter.MAX_REQUESTS_PROBED();
        for (uint256 i = 0; i < cap; i++) {
            queue.pushRequest(alice, i + 1, 1e18, false);
        }
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, cap * 1e18, "Exactly MAX_REQUESTS_PROBED open requests: all summed");
    }

    function test_getAdapterBalanceForAsset_skipsWhenAboveCap() public {
        // Lido's queue is not ERC721Enumerable, so an account with more open requests than the cap
        // is skipped (return 0) rather than materialising an unbounded, attacker-inflatable id list.
        uint256 cap = adapter.MAX_REQUESTS_PROBED();
        for (uint256 i = 0; i < cap + 1; i++) {
            queue.pushRequest(alice, i + 1, 1e18, false);
        }
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 0, "Above cap: skipped to bound gas");
    }

    // ---- getAdapterBalances ----

    function test_getAdapterBalances_zeroAccount() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
    }

    function test_getAdapterBalances_emptyForNoRequests() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
    }

    function test_getAdapterBalances_singlePosition() public {
        queue.pushRequest(alice, 1, 4e18, false);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
        assertEq(amounts[0], 4e18);
        assertFalse(isDebt[0]);
    }

    // ---- getAdapterPositions ----

    function test_getAdapterPositions_zeroBalanceProducesEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    function test_getAdapterPositions_filtersByAsset() public {
        queue.pushRequest(alice, 1, 5e18, false);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(usdc));
        assertEq(positions.length, 0, "Filter mismatch should produce empty");

        positions = adapter.getAdapterPositions(alice, address(weth));
        // A single not-finalized request → one locked leg.
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(weth));
        assertEq(positions[0].balanceAdapter, address(adapter));
        assertEq(positions[0].amount, 5e18);
        assertFalse(positions[0].isDebt);
        assertTrue(positions[0].isLocked, "not-finalized request -> locked leg");
        assertEq(positions[0].positionId, abi.encode(address(queue)), "static positionId = withdrawal queue");
        // Static breadcrumb is positionId-derived (no ephemeral id); the request id rides in positionInstanceId.
        string[] memory lbl = adapter.positionLabels(positions[0].positionId);
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "Withdrawal Queue");
        assertEq(lbl[1], "stETH");
        assertEq(positions[0].positionInstanceId, bytes32(uint256(1)));
    }

    function test_getAdapterPositions_perRequestLegsAndLabels() public {
        // Two requests of the SAME state (both pending/locked) must now emit TWO separate legs — one per request —
        // each carrying its own request id in positionInstanceId, all sharing the static positionId.
        queue.pushRequest(alice, 7, 2e18, false);
        queue.pushRequest(alice, 42, 3e18, false);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 2, "one leg per request, even at the same isLocked state");

        bytes memory expectedId = abi.encode(address(queue));
        bool saw7;
        bool saw42;
        uint256 sum;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].positionId, expectedId, "all legs share the static positionId");
            assertTrue(positions[i].isLocked, "both pending -> locked");
            sum += positions[i].amount;
            if (positions[i].positionInstanceId == bytes32(uint256(7))) {
                saw7 = true;
                assertEq(positions[i].amount, 2e18);
            }
            if (positions[i].positionInstanceId == bytes32(uint256(42))) {
                saw42 = true;
                assertEq(positions[i].amount, 3e18);
            }
        }
        assertTrue(saw7 && saw42, "each request id surfaced as its own positionInstanceId");

        // NAV-total invariance: per-request legs still sum to the aggregate balance method.
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(sum, agg, "sum of per-request legs == aggregate balance");
    }

    function test_getAdapterPositions_claimableOnlyLeg() public {
        // A single finalized request → one claimable leg (isLocked = false).
        queue.pushFinalizedRequest(alice, 1, 3e18, 2.9e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 1);
        assertEq(positions[0].amount, 2.9e18, "claimable leg uses exact getClaimableEther");
        assertFalse(positions[0].isLocked, "finalized request -> claimable leg");
        assertEq(positions[0].positionId, abi.encode(address(queue)));
    }

    function test_getAdapterPositions_mixedClaimableAndLocked() public {
        // One finalized (claimable) + one pending (locked) request → two legs sharing the static positionId,
        // told apart by isLocked. NAV total must equal the old single-aggregate (_ethOwed).
        queue.pushFinalizedRequest(alice, 1, 3e18, 2.9e18); // claimable 2.9
        queue.pushRequest(alice, 2, 1.5e18, false); // locked 1.5

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 2, "claimable + locked legs");

        bytes memory expectedId = abi.encode(address(queue));
        uint256 claimable;
        uint256 locked;
        bool sawClaimable;
        bool sawLocked;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(weth));
            assertEq(positions[i].balanceAdapter, address(adapter));
            assertFalse(positions[i].isDebt);
            assertEq(positions[i].positionId, expectedId, "both legs share the static positionId");
            if (positions[i].isLocked) {
                locked += positions[i].amount;
                sawLocked = true;
            } else {
                claimable += positions[i].amount;
                sawClaimable = true;
            }
        }
        assertTrue(sawClaimable && sawLocked, "exactly one claimable + one locked leg present");
        assertEq(claimable, 2.9e18, "claimable leg amount");
        assertEq(locked, 1.5e18, "locked leg amount");

        // NAV-total invariance: legs sum to the aggregate balance method's total.
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(claimable + locked, agg, "sum of legs == old aggregate");
    }

    function test_getAdapterPositions_emptyWhenAssetUnregistered() public {
        address unregistered = makeAddr("unregisteredAsset");
        LidoWithdrawalQueueBalanceAdapter freshAdapter =
            new LidoWithdrawalQueueBalanceAdapter(address(queue), unregistered, address(balances));
        queue.pushRequest(alice, 1, 5e18, false);

        INAVCalculator.PositionBalance[] memory positions = freshAdapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "Unregistered underlying should not produce positions");
    }
}
