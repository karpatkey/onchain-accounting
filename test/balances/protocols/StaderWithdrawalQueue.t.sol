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

/// @title StaderWithdrawalQueueBalanceOracle unit tests
contract StaderWithdrawalQueueBalanceOracleTest is BalanceAdapterTestBase {
    StaderWithdrawalQueueBalanceOracle public oracle;
    MockUserWithdrawalManager public manager;

    function setUp() public override {
        super.setUp();
        manager = new MockUserWithdrawalManager();
        oracle = new StaderWithdrawalQueueBalanceOracle(
            address(manager), address(weth), "Stader", "{\"protocol\":\"Stader\",\"product\":\"Withdrawal Queue\",\"name\":\"ETHx\"", "0x0000000000000000000000000000000000000001", address(balances)
        );
    }

    // ---- Constructor ----

    function test_constructor_revertsOnZeroManager() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceOracle(
            address(0), address(weth), "Stader", "{\"protocol\":\"Stader\",\"product\":\"Withdrawal Queue\",\"name\":\"ETHx\"", "0x0000000000000000000000000000000000000001", address(balances)
        );
    }

    function test_constructor_revertsOnZeroUnderlying() public {
        vm.expectRevert(InvalidArguments.selector);
        new StaderWithdrawalQueueBalanceOracle(
            address(manager), address(0), "Stader", "{\"protocol\":\"Stader\",\"product\":\"Withdrawal Queue\",\"name\":\"ETHx\"", "0x0000000000000000000000000000000000000001", address(balances)
        );
    }

    function test_constructor_revertsWhenManagerNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("UserWithdrawalManager must be a contract"));
        new StaderWithdrawalQueueBalanceOracle(eoa, address(weth), "Stader", "{\"protocol\":\"Stader\",\"product\":\"Withdrawal Queue\",\"name\":\"ETHx\"", "0x0000000000000000000000000000000000000001", address(balances));
    }

    function test_constructor_revertsWhenNAVNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(bytes("NAVCalculator must be a contract"));
        new StaderWithdrawalQueueBalanceOracle(address(manager), address(weth), "Stader", "{\"protocol\":\"Stader\",\"product\":\"Withdrawal Queue\",\"name\":\"ETHx\"", "0x0000000000000000000000000000000000000001", eoa);
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
        // Build a fresh adapter pointing at an asset that was never registered with the harness.
        // The constructor only requires non-zero, not contract-shaped, for `underlyingToken_`, so a
        // bare EOA-style address is enough to demonstrate the asset-registry filtering behaviour.
        address unregisteredAsset = makeAddr("unregisteredAsset");
        StaderWithdrawalQueueBalanceOracle freshOracle = new StaderWithdrawalQueueBalanceOracle(
            address(manager), unregisteredAsset, "Stader", "{\"protocol\":\"Stader\",\"product\":\"Withdrawal Queue\",\"name\":\"ETHx\"", "0x0000000000000000000000000000000000000001", address(balances)
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
        assertEq(positions[0].positionDetail, "{\"protocol\":\"Stader\",\"product\":\"Withdrawal Queue\",\"name\":\"ETHx\"}");
    }

    function test_getOraclePositions_zeroBalanceProducesEmpty() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0);
    }

    // ---- Panic propagation ----

    function test_getOracleBalanceForAsset_propagatesNonOOBPanic() public {
        // OOB panic ends enumeration silently. Any other panic must surface as UnexpectedPanic
        // so NAVCalculator's outer try/catch sees the failure rather than the adapter silently
        // returning 0 and undercounting NAV.
        manager.setInjectArithmeticPanic(true);
        vm.expectRevert(
            abi.encodeWithSelector(StaderWithdrawalQueueBalanceOracle.UnexpectedPanic.selector, uint256(0x12))
        );
        oracle.getOracleBalanceForAsset(alice, address(weth));
    }

    function test_getOracleBalanceForAsset_propagatesNonEmptyRevert() public {
        // Empty bytes revert is the legacy-Solidity OOB sentinel and must end enumeration; any
        // revert with data must propagate.
        manager.setInjectStringRevert(true);
        vm.expectRevert(bytes("boom"));
        oracle.getOracleBalanceForAsset(alice, address(weth));
    }
}
