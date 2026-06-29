// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of Stader's UserWithdrawalManager.
/// @dev Mirrors the two storage getters the adapter relies on: `requestIdsByUserAddress(addr, idx)`
///      and `userWithdrawRequests(id)`. Out-of-bounds indexing reverts to mimic Solidity's auto-getter.
contract MockUserWithdrawalManager {
    struct Info {
        address owner;
        uint256 ethXAmount;
        uint256 ethExpected;
        uint256 ethFinalized;
        uint256 requestBlock;
    }

    mapping(address => uint256[]) private _userIds;
    mapping(uint256 => Info) public userWithdrawRequests;

    /// @dev Set by tests to inject a non-OOB panic from `requestIdsByUserAddress`.
    bool public injectArithmeticPanic;

    /// @dev Set by tests to inject a non-empty plain revert (i.e. not the legacy-OOB sentinel).
    bool public injectStringRevert;

    function pushRequest(address user, uint256 requestId, Info memory info) external {
        _userIds[user].push(requestId);
        userWithdrawRequests[requestId] = info;
    }

    function clearOwner(uint256 requestId) external {
        userWithdrawRequests[requestId].owner = address(0);
    }

    function setInjectArithmeticPanic(bool v) external {
        injectArithmeticPanic = v;
    }

    function setInjectStringRevert(bool v) external {
        injectStringRevert = v;
    }

    function requestIdsByUserAddress(address user, uint256 index) external view returns (uint256) {
        if (injectArithmeticPanic) {
            // Panic(0x12) — division by zero. Anything other than 0x32 (OOB) should propagate.
            uint256 zero;
            return uint256(1) / zero;
        }
        if (injectStringRevert) {
            // Plain revert with non-empty data — must propagate (not be treated as OOB sentinel).
            revert("boom");
        }
        return _userIds[user][index]; // intentionally reverts on out-of-bounds (Panic 0x32)
    }
}

/// @title StaderWithdrawalQueueBalanceAdapter unit tests
contract StaderWithdrawalQueueBalanceAdapterTest is BalanceAdapterTestBase {
    StaderWithdrawalQueueBalanceAdapter public adapter;
    MockUserWithdrawalManager public manager;

    function setUp() public override {
        super.setUp();
        manager = new MockUserWithdrawalManager();
        adapter = new StaderWithdrawalQueueBalanceAdapter(address(manager), address(weth), address(balances));
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroManager() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceAdapter(address(0), address(weth), address(balances));
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceAdapter(address(manager), address(0), address(balances));
    }

    function test_constructor_revertsWhenManagerNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("UserWithdrawalManager must be a contract"));
        new StaderWithdrawalQueueBalanceAdapter(eoa, address(weth), address(balances));
    }

    function test_constructor_revertsWhenNAVNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("NAVCalculator must be a contract"));
        new StaderWithdrawalQueueBalanceAdapter(address(manager), address(weth), eoa);
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
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_zeroAccount() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(address(0), address(weth));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_singleOpenRequestUsesEthExpected() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1.05e18, ethFinalized: 0, requestBlock: 0
            })
        );

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.05e18);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_finalizedRequestPrefersEthFinalized() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1.05e18, ethFinalized: 1.04e18, requestBlock: 0
            })
        );

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.04e18, "Should use ethFinalized once set");
    }

    function test_getAdapterBalanceForAsset_multipleRequestsSummed() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1.05e18, ethFinalized: 0, requestBlock: 0
            })
        );
        manager.pushRequest(
            alice,
            2,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 2e18, ethExpected: 2.1e18, ethFinalized: 2.09e18, requestBlock: 0
            })
        );

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.05e18 + 2.09e18);
    }

    function test_getAdapterBalanceForAsset_skipsClaimedEntries() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 1e18, requestBlock: 0
            })
        );
        manager.pushRequest(
            alice,
            2,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 2e18, ethExpected: 2e18, ethFinalized: 2e18, requestBlock: 0
            })
        );
        manager.clearOwner(1); // simulate claim

        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 2e18, "Claimed request must be excluded");
    }

    // ---- getAdapterBalances ----

    function test_getAdapterBalances_zeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterBalances_emptyForAccountWithNoRequests() public view {
        (address[] memory assets,,) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 0);
    }

    function test_getAdapterBalances_emitsSinglePosition() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
        assertEq(amounts[0], 1e18);
        assertFalse(isDebt[0]);
    }

    // ---- getAdapterPositions ----

    function test_getAdapterPositions_emptyWhenAssetUnregistered() public {
        // Build a fresh adapter pointing at an asset that was never registered with the harness.
        // The constructor only requires non-zero, not contract-shaped, for `underlyingToken_`, so a
        // bare EOA-style address is enough to demonstrate the asset-registry filtering behaviour.
        address unregisteredAsset = makeAddr("unregisteredAsset");
        StaderWithdrawalQueueBalanceAdapter freshAdapter =
            new StaderWithdrawalQueueBalanceAdapter(address(manager), unregisteredAsset, address(balances));

        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );

        INAVCalculator.PositionBalance[] memory positions = freshAdapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "Unregistered underlying should not produce positions");
    }

    function test_getAdapterPositions_filtersByAsset() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(usdc));
        assertEq(positions.length, 0, "Filter mismatch should produce empty");

        positions = adapter.getAdapterPositions(alice, address(weth));
        // A single not-finalized request (ethFinalized == 0) → one locked leg only.
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(weth));
        assertEq(positions[0].balanceAdapter, address(adapter));
        assertEq(positions[0].amount, 1e18);
        assertFalse(positions[0].isDebt);
        assertTrue(positions[0].isLocked, "not-finalized request -> locked leg");
        assertEq(positions[0].positionId, abi.encode(address(manager)), "static positionId = withdrawal manager");
        // Static breadcrumb is positionId-derived; the request id rides in positionInstanceId.
        string[] memory lbl = adapter.positionLabels(positions[0].positionId);
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "Withdrawal Queue");
        assertEq(lbl[1], "ETHx");
        assertEq(positions[0].positionInstanceId, bytes32(uint256(1)));
    }

    function test_getAdapterPositions_perRequestLegsAndLabels() public {
        // Two requests of the SAME state (both pending/locked) must now emit TWO separate legs — one per request —
        // each carrying its own request id in positionInstanceId, all sharing the static positionId.
        manager.pushRequest(
            alice,
            7,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 2e18, ethFinalized: 0, requestBlock: 0
            })
        );
        manager.pushRequest(
            alice,
            42,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 3e18, ethFinalized: 0, requestBlock: 0
            })
        );

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 2, "one leg per request, even at the same isLocked state");

        bytes memory expectedId = abi.encode(address(manager));
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
        // A single finalized request (ethFinalized > 0) → one claimable leg (isLocked = false).
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 2e18, ethFinalized: 1.95e18, requestBlock: 0
            })
        );
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 1);
        assertEq(positions[0].amount, 1.95e18, "claimable leg uses ethFinalized");
        assertFalse(positions[0].isLocked, "finalized request -> claimable leg");
        assertEq(positions[0].positionId, abi.encode(address(manager)));
        string[] memory lbl = adapter.positionLabels(positions[0].positionId);
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "Withdrawal Queue");
        assertEq(lbl[1], "ETHx");
        assertEq(positions[0].positionInstanceId, bytes32(uint256(1)));
    }

    function test_getAdapterPositions_mixedClaimableAndLocked() public {
        // One finalized (claimable) + one pending (locked) request → two legs sharing the static positionId.
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 2e18, ethFinalized: 1.95e18, requestBlock: 0
            })
        );
        manager.pushRequest(
            alice,
            2,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1.1e18, ethFinalized: 0, requestBlock: 0
            })
        );

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 2, "claimable + locked legs");

        bytes memory expectedId = abi.encode(address(manager));
        uint256 claimable;
        uint256 locked;
        bool sawClaimable;
        bool sawLocked;
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(weth));
            assertEq(positions[i].balanceAdapter, address(adapter));
            assertFalse(positions[i].isDebt);
            assertEq(positions[i].positionId, expectedId, "both legs share the static positionId");
            string[] memory lbl = adapter.positionLabels(positions[i].positionId);
            assertEq(lbl.length, 2);
            assertEq(lbl[0], "Withdrawal Queue");
            assertEq(lbl[1], "ETHx");
            if (positions[i].isLocked) {
                locked += positions[i].amount;
                sawLocked = true;
                assertEq(positions[i].positionInstanceId, bytes32(uint256(2)), "locked leg carries its own request id");
            } else {
                claimable += positions[i].amount;
                sawClaimable = true;
                assertEq(
                    positions[i].positionInstanceId, bytes32(uint256(1)), "claimable leg carries its own request id"
                );
            }
        }
        assertTrue(sawClaimable && sawLocked, "exactly one claimable + one locked leg present");
        assertEq(claimable, 1.95e18, "claimable leg = ethFinalized");
        assertEq(locked, 1.1e18, "locked leg = ethExpected");

        // NAV-total invariance.
        (uint256 agg,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(claimable + locked, agg, "sum of legs == old aggregate");
    }

    function test_getAdapterPositions_zeroBalanceProducesEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    // ---- Panic propagation ----

    function test_getAdapterBalanceForAsset_propagatesNonOOBPanic() public {
        // OOB panic ends enumeration silently. Any other panic must surface as UnexpectedPanic
        // so NAVCalculator's outer try/catch sees the failure rather than the adapter silently
        // returning 0 and undercounting NAV.
        manager.setInjectArithmeticPanic(true);
        vm.expectRevert(
            abi.encodeWithSelector(StaderWithdrawalQueueBalanceAdapter.UnexpectedPanic.selector, uint256(0x12))
        );
        adapter.getAdapterBalanceForAsset(alice, address(weth));
    }

    function test_getAdapterBalanceForAsset_propagatesNonEmptyRevert() public {
        // Empty bytes revert is the legacy-Solidity OOB sentinel and must end enumeration; any
        // revert with data must propagate.
        manager.setInjectStringRevert(true);
        vm.expectRevert(bytes("boom"));
        adapter.getAdapterBalanceForAsset(alice, address(weth));
    }
}
