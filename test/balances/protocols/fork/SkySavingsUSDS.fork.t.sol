// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {SkySavingsUsdsBalanceAdapter} from "src/balances/protocols/SkySavingsUsds.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @title SkySavingsUsdsBalanceAdapterForkTest
/// @notice Fork tests for SkySavingsUsdsBalanceAdapter using real mainnet contracts
/// @dev Tests adapter behavior with real Sky SavingsUSDS contracts and positions
contract SkySavingsUsdsBalanceAdapterForkTest is BalanceAdapterTestBase {
    // Sky contract addresses (mainnet)
    IERC4626 public constant SAVINGS_USDS = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    IERC20 public constant USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);

    // Fork block
    uint256 public constant FORK_BLOCK = 21_378_910;

    // Adapter instance
    SkySavingsUsdsBalanceAdapter public adapter;

    // Real user address with SavingsUSDS position
    address public constant TEST_USER = 0x7F311a4D48377030bD810395f4CCfC03bdbe9Ef3;

    function setUp() public override {
        super.setUp();
        _setupFork();
        _setupAdapter();
    }

    function _setupFork() internal override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
    }

    function _setupAdapter() internal {
        balances = _deployBalancesForAdapter(address(USDS));
        adapter = new SkySavingsUsdsBalanceAdapter(address(SAVINGS_USDS), address(balances));
    }

    // ============================================
    // Real Position Tests
    // ============================================

    function test_getAdapterBalanceForAsset_mainnet_testUser() public {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(TEST_USER, address(USDS));

        vm.startPrank(TEST_USER);
        uint256 previousBalance = USDS.balanceOf(TEST_USER);
        SAVINGS_USDS.redeem(SAVINGS_USDS.balanceOf(TEST_USER), TEST_USER, TEST_USER);
        uint256 newBalance = USDS.balanceOf(TEST_USER);
        vm.stopPrank();

        uint256 expected = newBalance - previousBalance;

        assertEq(amount, expected, "Adapter balance should match redemption amount");
        assertGt(amount, 0, "User should have positive USDS position");
        assertFalse(isDebt);
    }

    // ============================================
    // View / No-Fork Logic Tests (run on fork for adapter instance)
    // ============================================

    function test_balanceOfZeroAddress() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(USDS));
        assertEq(amount, 0);
    }

    function test_returnsZeroOnInvalidToken() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(TEST_USER, address(0xdead));
        assertEq(amount, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    // ============================================
    // Supported Assets Tests
    // ============================================

    function test_underlyingAssetsSupported() public view {
        address[] memory assets = adapter.underlyingAssetsSupported();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(USDS));
    }

    // ============================================
    // Immutable Addresses Tests
    // ============================================

    function test_immutableAddresses() public view {
        assertEq(address(adapter.SAVINGS_USDS()), address(SAVINGS_USDS));
        assertEq(adapter.USDS(), address(USDS));
    }

    // ============================================
    // Position Aggregation Tests
    // ============================================

    function test_getAdapterBalance_aggregatesPositions() public view {
        (address[] memory assets, uint256[] memory amounts,) = adapter.getAdapterBalances(TEST_USER);

        // Should have USDS position
        assertGe(assets.length, 1, "Should have at least one position");
        assertEq(assets.length, amounts.length, "Arrays should match length");
    }

    function test_getAdapterPositions_returnsCorrectPositions() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(TEST_USER, address(0));

        assertGe(positions.length, 1, "Should have at least one position");

        // Verify positions have correct structure
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount > 0, "Position amount should be positive");
        }
    }
}
