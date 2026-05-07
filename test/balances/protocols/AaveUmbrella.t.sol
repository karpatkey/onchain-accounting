// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveUmbrellaBalanceOracle} from "src/balances/protocols/AaveUmbrella.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AaveUmbrellaBalanceOracleTest
/// @notice Unit tests for the dynamic-discovery AaveUmbrellaBalanceOracle.
/// @dev The adapter discovers the full Umbrella stake-token set at runtime via
///      `RewardsController.getAllAssets()`. Behaviour against real Mainnet contracts is covered by
///      the fork-test companion in `test/balances/protocols/fork/AaveUmbrella.fork.t.sol`. These
///      unit tests cover the surface that doesn't depend on a live controller: constructor guards,
///      ERC165, and the zero-account / zero-asset early-exit shortcuts (which return empty results
///      before touching the controller, so they work even when the controller is a stub).
contract AaveUmbrellaBalanceOracleTest is BalanceAdapterTestBase {
    /// @dev Stand-in for the RewardsController. Marked as a contract via deployed bytecode so the
    ///      adapter constructor's `code.length > 0` check passes; its functions are not invoked by
    ///      the early-exit paths exercised here.
    address internal stubRewardsController;

    AaveUmbrellaBalanceOracle public oracle;

    function setUp() public override {
        super.setUp();
        stubRewardsController = address(new RewardsControllerStub());
        oracle = new AaveUmbrellaBalanceOracle(stubRewardsController, address(balances), "Aave Umbrella", "{\"protocol\":\"Aave V3\",\"product\":\"Umbrella\"", "0x0000000000000000000000000000000000000001");
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_pinsImmutables() public view {
        assertEq(address(oracle.REWARDS_CONTROLLER()), stubRewardsController);
        assertEq(address(oracle.NAV_CALCULATOR()), address(balances));
        assertEq(oracle.PROTOCOL(), "Aave Umbrella");
    }

    function test_constructor_revertsOnZeroRewardsController() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveUmbrellaBalanceOracle(address(0), address(balances), "x", "{\"p\":\"t\"", "0x0000000000000000000000000000000000000001");
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveUmbrellaBalanceOracle(stubRewardsController, address(0), "x", "{\"p\":\"t\"", "0x0000000000000000000000000000000000000001");
    }

    function test_constructor_revertsOnNonContractRewardsController() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveUmbrellaBalanceOracle(makeAddr("eoa-controller"), address(balances), "x", "{\"p\":\"t\"", "0x0000000000000000000000000000000000000001");
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveUmbrellaBalanceOracle(stubRewardsController, makeAddr("eoa-nav"), "x", "{\"p\":\"t\"", "0x0000000000000000000000000000000000000001");
    }

    // ─── Zero-account / zero-asset shortcuts (no controller calls expected) ───

    function test_getOracleBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalanceForAsset_returnsZeroForZeroAsset() public view {
        (uint256 amount, bool isDebt) = oracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getOracleBalances_returnsEmptyArraysForZeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = oracle.getOracleBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getOraclePositions_returnsEmptyArrayForZeroAccount() public view {
        // Zero-account shortcut returns [] before touching NAV_CALCULATOR or the controller.
        assertEq(oracle.getOraclePositions(address(0), address(0)).length, 0);
    }

    // ─── ERC165 ───────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(bytes4(0xdeadbeef)));
    }
}

/// @dev Minimal contract stub so `RewardsController.code.length > 0` passes in the constructor.
///      Function selectors are irrelevant for the unit tests above (early-exit paths don't call them).
contract RewardsControllerStub {}
