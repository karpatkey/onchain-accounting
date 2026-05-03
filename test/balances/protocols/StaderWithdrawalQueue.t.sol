// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {StaderWithdrawalQueueBalanceOracle} from "src/balances/protocols/StaderWithdrawalQueue.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
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

    function pushRequest(address user, uint256 requestId, Info memory info) external {
        _userIds[user].push(requestId);
        userWithdrawRequests[requestId] = info;
    }

    function clearOwner(uint256 requestId) external {
        userWithdrawRequests[requestId].owner = address(0);
    }

    function requestIdsByUserAddress(address user, uint256 index) external view returns (uint256) {
        return _userIds[user][index]; // intentionally reverts on out-of-bounds
    }
}

/// @title StaderWithdrawalQueueBalanceOracle unit tests
contract StaderWithdrawalQueueBalanceOracleTest is BalanceAdapterTestBase {
    StaderWithdrawalQueueBalanceOracle public oracle;
    MockUserWithdrawalManager public manager;

    function setUp() public override {
        super.setUp();
        manager = new MockUserWithdrawalManager();
        oracle = new StaderWithdrawalQueueBalanceOracle(
            address(manager), address(weth), "Stader", "ETH Withdrawal Queue", address(balances)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroManager() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceOracle(
            address(0), address(weth), "Stader", "ETH Withdrawal Queue", address(balances)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceOracle(
            address(manager), address(0), "Stader", "ETH Withdrawal Queue", address(balances)
        );
    }

    function test_constructor_revertsWhenManagerNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("UserWithdrawalManager must be a contract"));
        new StaderWithdrawalQueueBalanceOracle(eoa, address(weth), "Stader", "ETH Withdrawal Queue", address(balances));
    }

    function test_constructor_revertsWhenNAVNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("NAVCalculator must be a contract"));
        new StaderWithdrawalQueueBalanceOracle(address(manager), address(weth), "Stader", "ETH Withdrawal Queue", eoa);
    }

    // ---- Interface ----

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(0xdeadbeef));
    }

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
    }

    // ---- getOracleBalanceForAsset ----

    function test_getOracleBalanceForAsset_zeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_unsupportedAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_zeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(address(0), address(weth));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_singleOpenRequestUsesEthExpected() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1.05e18, ethFinalized: 0, requestBlock: 0
            })
        );

        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.05e18);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_finalizedRequestPrefersEthFinalized() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1.05e18, ethFinalized: 1.04e18, requestBlock: 0
            })
        );

        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.04e18, "Should use ethFinalized once set");
    }

    function test_getOracleBalanceForAsset_multipleRequestsSummed() public {
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

        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 1.05e18 + 2.09e18);
    }

    function test_getOracleBalanceForAsset_skipsClaimedEntries() public {
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

        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, address(weth));
        assertEq(amount, 2e18, "Claimed request must be excluded");
    }

    // ---- getOracleBalances ----

    function test_getOracleBalances_zeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOracleBalances_emptyForAccountWithNoRequests() public view {
        (address[] memory assets,,) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 0);
    }

    function test_getOracleBalances_emitsSinglePosition() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(alice);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
        assertEq(amounts[0], 1e18);
        assertFalse(isDebt[0]);
    }

    // ---- getOraclePositions ----

    function test_getOraclePositions_emptyWhenAssetUnregistered() public {
        // remove weth registration by deploying a fresh harness without weth
        StaderWithdrawalQueueBalanceOracle freshOracle;
        // create a new harness scope: a token never added to balances
        address unregisteredAsset = makeAddr("unregisteredAsset");
        vm.etch(unregisteredAsset, hex"60006000"); // make it look like a contract for require check
        freshOracle = new StaderWithdrawalQueueBalanceOracle(
            address(manager), unregisteredAsset, "Stader", "ETH Withdrawal Queue", address(balances)
        );

        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );

        INAVCalculator.PositionBalance[] memory positions = freshOracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0, "Unregistered underlying should not produce positions");
    }

    function test_getOraclePositions_filtersByAsset() public {
        manager.pushRequest(
            alice,
            1,
            MockUserWithdrawalManager.Info({
                owner: alice, ethXAmount: 1e18, ethExpected: 1e18, ethFinalized: 0, requestBlock: 0
            })
        );

        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(usdc));
        assertEq(positions.length, 0, "Filter mismatch should produce empty");

        positions = oracle.getOraclePositions(alice, address(weth));
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, address(weth));
        assertEq(positions[0].balanceOracle, address(oracle));
        assertEq(positions[0].amount, 1e18);
        assertFalse(positions[0].isDebt);
        assertEq(positions[0].protocol, "Stader");
        assertEq(positions[0].positionDetail, "ETH Withdrawal Queue");
    }

    function test_getOraclePositions_zeroBalanceProducesEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }
}
