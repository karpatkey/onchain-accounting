// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveUmbrellaBalanceAdapter} from "src/balances/protocols/AaveUmbrella.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title AaveUmbrellaBalanceAdapterTest
/// @notice Unit tests for the dynamic-discovery AaveUmbrellaBalanceAdapter.
/// @dev The adapter discovers the full Umbrella stake-token set at runtime via
///      `RewardsController.getAllAssets()`. Behaviour against real Mainnet contracts is covered by
///      the fork-test companion in `test/balances/protocols/fork/AaveUmbrella.fork.t.sol`. These
///      unit tests cover the surface that doesn't depend on a live controller: constructor guards,
///      ERC165, and the zero-account / zero-asset early-exit shortcuts (which return empty results
///      before touching the controller, so they work even when the controller is a stub).
contract AaveUmbrellaBalanceAdapterTest is BalanceAdapterTestBase {
    /// @dev Stand-in for the RewardsController. Marked as a contract via deployed bytecode so the
    ///      adapter constructor's `code.length > 0` check passes; its functions are not invoked by
    ///      the early-exit paths exercised here.
    address internal stubRewardsController;

    AaveUmbrellaBalanceAdapter public adapter;

    function setUp() public override {
        super.setUp();
        stubRewardsController = address(new RewardsControllerStub());
        adapter = new AaveUmbrellaBalanceAdapter(stubRewardsController, address(balances));
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_pinsImmutables() public view {
        assertEq(address(adapter.REWARDS_CONTROLLER()), stubRewardsController);
        assertEq(address(adapter.NAV_CALCULATOR()), address(balances));
        assertEq(adapter.protocolName(), "Aave Umbrella");
    }

    function test_constructor_revertsOnZeroRewardsController() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveUmbrellaBalanceAdapter(address(0), address(balances));
    }

    function test_constructor_revertsOnZeroNavCalculator() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveUmbrellaBalanceAdapter(stubRewardsController, address(0));
    }

    function test_constructor_revertsOnNonContractRewardsController() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveUmbrellaBalanceAdapter(makeAddr("eoa-controller"), address(balances));
    }

    function test_constructor_revertsOnNonContractNavCalculator() public {
        vm.expectRevert(); // require message; selector check unnecessary
        new AaveUmbrellaBalanceAdapter(stubRewardsController, makeAddr("eoa-nav"));
    }

    // ─── Zero-account / zero-asset shortcuts (no controller calls expected) ───

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAccount() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalanceForAsset_returnsZeroForZeroAsset() public view {
        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0);
        assertFalse(isDebt);
    }

    function test_getAdapterBalances_returnsEmptyArraysForZeroAccount() public view {
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) = adapter.getAdapterBalances(address(0));
        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
        assertEq(isDebt.length, 0);
    }

    function test_getAdapterPositions_returnsEmptyArrayForZeroAccount() public view {
        // Zero-account shortcut returns [] before touching NAV_CALCULATOR or the controller.
        assertEq(adapter.getAdapterPositions(address(0), address(0)).length, 0);
    }

    // ─── ERC165 ───────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IBalanceAdapter).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(bytes4(0xdeadbeef)));
    }
}

/// @dev Minimal contract stub so `RewardsController.code.length > 0` passes in the constructor.
///      Function selectors are irrelevant for the unit tests above (early-exit paths don't call them).
contract RewardsControllerStub {}
