// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {NotAContract} from "src/errors.sol";
import {BalanceAdapterTestBase} from "test/balances/BalanceAdapterTestBase.sol";
import {
    StaderWithdrawalQueueBalanceAdapter
} from "src/balances/BalanceAdapters/StaderWithdrawalQueueBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IPositionDescribable} from "src/balances/IPositionDescribable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Minimal mock of Stader's UserWithdrawalManager for the self-fed adapter.
/// @dev The cache-based adapter only reads the `userWithdrawRequests(id)` public mapping getter (ownership + amounts);
///      it no longer enumerates `requestIdsByUserAddress`. The getter returns a zeroed tuple for an unknown/claimed id.
contract MockUserWithdrawalManager {
    struct Info {
        address owner;
        uint256 ethXAmount;
        uint256 ethExpected;
        uint256 ethFinalized;
        uint256 requestBlock;
    }

    mapping(uint256 => Info) public userWithdrawRequests;

    function setRequest(uint256 requestId, Info memory info) external {
        userWithdrawRequests[requestId] = info;
    }

    /// @dev Simulate a claim: the manager deletes the request, so its owner reads back as address(0).
    function clearOwner(uint256 requestId) external {
        delete userWithdrawRequests[requestId];
    }
}

/// @title StaderWithdrawalQueueBalanceAdapter unit tests (self-fed, id-cached)
contract StaderWithdrawalQueueBalanceAdapterTest is BalanceAdapterTestBase {
    StaderWithdrawalQueueBalanceAdapter public adapter;
    MockUserWithdrawalManager public manager;

    function setUp() public override {
        super.setUp();
        manager = new MockUserWithdrawalManager();
        adapter = new StaderWithdrawalQueueBalanceAdapter(address(manager), address(weth), address(balances));
    }

    // ---- helpers ----

    /// @dev Cache `id` for `owner` the way the adapter requires: the request must be owned by `owner`, and the submit
    ///      must come from `owner` (the cache is keyed on msg.sender).
    function _seed(address owner, uint256 id, uint256 ethExpected, uint256 ethFinalized) internal {
        manager.setRequest(
            id,
            MockUserWithdrawalManager.Info({
                owner: owner, ethXAmount: 1e18, ethExpected: ethExpected, ethFinalized: ethFinalized, requestBlock: 0
            })
        );
        vm.prank(owner);
        adapter.submit(id);
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
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "UserWithdrawalManager"));
        new StaderWithdrawalQueueBalanceAdapter(eoa, address(weth), address(balances));
    }

    function test_constructor_revertsWhenNAVNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, "NAVCalculator"));
        new StaderWithdrawalQueueBalanceAdapter(address(manager), address(weth), eoa);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IPositionDescribable).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xdeadbeef));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
    }

    // ---- submit (permissionless, keyed on msg.sender) ----

    function test_submit_addsAndIsIdempotent() public {
        _seed(alice, 1, 1e18, 0);
        uint256[] memory ids = adapter.requestIdsOf(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);

        // Re-submitting the same id is a no-op (no revert, no duplicate).
        vm.prank(alice);
        adapter.submit(1);
        assertEq(adapter.requestIdsOf(alice).length, 1);
    }

    function test_submit_cachesForCallerOnly() public {
        // A request owned by alice can only be cached by alice — bob submitting it caches nothing for alice (it lands
        // in bob's own cache attempt, which fails the ownership check).
        manager.setRequest(
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, bob, uint256(1)));
        adapter.submit(1);
        assertEq(adapter.requestIdsOf(alice).length, 0, "bob cannot feed alice's cache");
    }

    function test_submit_revertsWhenNotOwner() public {
        manager.setRequest(
            1,
            MockUserWithdrawalManager.Info({
                owner: bob, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotOwned.selector, alice, uint256(1)));
        adapter.submit(1);
    }

    function test_submit_revertsWhenCacheFull() public {
        uint256 cap = adapter.MAX_REQUESTS();
        for (uint256 i = 1; i <= cap; i++) {
            _seed(alice, i, 1e18, 0);
        }
        uint256 overflowId = cap + 1;
        manager.setRequest(
            overflowId,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );
        // Capture `cap` above so no external call sits between the prank and submit (it would consume the prank).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoordinateCacheFull.selector, alice, cap));
        adapter.submit(overflowId);
    }

    // ---- remove (permissionless, keyed on msg.sender: must be cached AND claimed) ----

    function test_remove_revertsWhenNotCached() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoordinateNotCached.selector, alice, uint256(9)));
        adapter.remove(9);
    }

    function test_remove_revertsWhenStillOwned() public {
        _seed(alice, 1, 1e18, 0); // cached and still live (not claimed)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoordinateStillLive.selector, alice, uint256(1)));
        adapter.remove(1);
    }

    function test_remove_dropsCachedClaimedId() public {
        _seed(alice, 1, 1e18, 0);
        manager.clearOwner(1); // simulate claim -> owner becomes address(0)
        vm.prank(alice);
        adapter.remove(1);
        assertEq(adapter.requestIdsOf(alice).length, 0);
    }

    // ---- Valuation via getAdapterBalanceForAsset ----

    function test_getAdapterBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_zeroAccount() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(weth));
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_singleOpenRequestUsesEthExpected() public {
        _seed(alice, 1, 1.05e18, 0);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.05e18);
    }

    function test_getAdapterBalanceForAsset_finalizedRequestPrefersEthFinalized() public {
        _seed(alice, 1, 1.05e18, 1.04e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.04e18, "Should use ethFinalized once set");
    }

    function test_getAdapterBalanceForAsset_multipleRequestsSummed() public {
        _seed(alice, 1, 1.05e18, 0);
        _seed(alice, 2, 2.1e18, 2.09e18);
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.05e18 + 2.09e18);
    }

    function test_getAdapterBalanceForAsset_skipsClaimedEntries() public {
        _seed(alice, 1, 1e18, 1e18);
        _seed(alice, 2, 2e18, 2e18);
        manager.clearOwner(1); // claimed after submission; still cached but now unowned -> valued 0
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(amount, 2e18, "Claimed request must be excluded from valuation");
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
        _seed(alice, 1, 1e18, 0);
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
        assertEq(amounts[0], 1e18);
        assertFalse(isDebt[0]);
    }

    // ---- getAdapterPositions ----

    function test_getAdapterPositions_emptyWhenAssetUnregistered() public {
        address unregisteredAsset = makeAddr("unregisteredAsset");
        StaderWithdrawalQueueBalanceAdapter freshAdapter =
            new StaderWithdrawalQueueBalanceAdapter(address(manager), unregisteredAsset, address(balances));
        manager.setRequest(
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );
        vm.prank(alice);
        freshAdapter.submit(1);

        INAVCalculator.PositionBalance[] memory positions = freshAdapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "Unregistered underlying should not produce positions");
    }

    function test_getAdapterPositions_filtersByAsset() public {
        _seed(alice, 1, 1e18, 0);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(usdc));
        assertEq(positions.length, 0, "Filter mismatch should produce empty");

        positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(weth));
        assertEq(positions[0].balanceAdapter, address(adapter));
        assertEq(positions[0].amount, 1e18);
        assertFalse(positions[0].isDebt);
        assertTrue(positions[0].isLocked, "not-finalized request -> locked leg");
        assertEq(positions[0].positionId, abi.encode(address(manager)), "static positionId = withdrawal manager");
        string[] memory lbl = adapter.positionLabels(positions[0].positionId);
        assertEq(lbl.length, 2);
        assertEq(lbl[0], "Withdrawal Queue");
        assertEq(lbl[1], "ETHx");
        assertEq(positions[0].positionInstanceId, bytes32(uint256(1)));
    }

    function test_getAdapterPositions_perRequestLegsAndLabels() public {
        _seed(alice, 7, 2e18, 0);
        _seed(alice, 42, 3e18, 0);

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

        (uint256 agg,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(sum, agg, "sum of per-request legs == aggregate balance");
    }

    function test_getAdapterPositions_claimableOnlyLeg() public {
        _seed(alice, 1, 2e18, 1.95e18);
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 1);
        assertEq(positions[0].amount, 1.95e18, "claimable leg uses ethFinalized");
        assertFalse(positions[0].isLocked, "finalized request -> claimable leg");
        assertEq(positions[0].positionInstanceId, bytes32(uint256(1)));
    }

    function test_getAdapterPositions_mixedClaimableAndLocked() public {
        _seed(alice, 1, 2e18, 1.95e18);
        _seed(alice, 2, 1.1e18, 0);

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(weth));
        assertEq(positions.length, 2, "claimable + locked legs");

        uint256 claimable;
        uint256 locked;
        bool sawClaimable;
        bool sawLocked;
        for (uint256 i = 0; i < positions.length; i++) {
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

        (uint256 agg,) = adapter.getAdapterBalanceForAsset(alice, address(weth));
        assertEq(claimable + locked, agg, "sum of legs == aggregate");
    }

    function test_getAdapterPositions_zeroBalanceProducesEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
