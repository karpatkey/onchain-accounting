// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {BalancerV3PoolBalanceOracle} from "src/balances/protocols/BalancerV3.sol";
import {InvalidArguments} from "src/errors.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Mock gauge that returns the given pool from lp_token() (required by BalancerV3 constructor)
contract MockBalancerGauge {
    address private _lpToken;

    constructor(address pool_) {
        _lpToken = pool_;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function lp_token() external view returns (address) {
        return _lpToken;
    }
}

/// @title BalancerV3PoolBalanceOracleTest
/// @notice Unit and implementation tests for BalancerV3PoolBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract BalancerV3PoolBalanceOracleTest is BalanceAdapterTestBase {
    BalancerV3PoolBalanceOracle public oracle;
    MockBalances public mockBalances;
    MockContract public mockPool;
    MockBalancerGauge public mockGauge;
    MockContract public mockMinter;

    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        mockPool = new MockContract();
        mockGauge = new MockBalancerGauge(address(mockPool));
        mockMinter = new MockContract();
        oracle = new BalancerV3PoolBalanceOracle(
            address(mockPool), address(mockGauge), address(mockMinter), "Balancer v3", address(balances)
        );
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor() public view {
        assertEq(address(oracle.POOL()), address(mockPool));
        assertEq(address(oracle.GAUGE()), address(mockGauge));
    }

    function test_constructor_reverts_zeroPool() public {
        vm.expectRevert(InvalidArguments.selector);
        new BalancerV3PoolBalanceOracle(
            address(0), address(mockGauge), address(mockMinter), "Balancer v3", address(mockBalances)
        );
    }

    function test_constructor_reverts_zeroGauge() public {
        vm.expectRevert(InvalidArguments.selector);
        new BalancerV3PoolBalanceOracle(
            address(mockPool), address(0), address(mockMinter), "Balancer v3", address(mockBalances)
        );
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getOracleBalanceForAsset_returns_zero_for_nonPoolToken() public view {
        address randomToken = address(0x1234);

        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, randomToken);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_returns_zero_when_noBpt() public view {
        address deadAddress = address(0xdead);

        (uint256 amount1,) = oracle.getOracleBalanceForAsset(deadAddress, address(usdc));
        assertEq(amount1, 0);

        (uint256 amount2,) = oracle.getOracleBalanceForAsset(deadAddress, address(dai));
        assertEq(amount2, 0);
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_getOracleBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, uint256[] memory amounts,) = oracle.getOracleBalances(address(0));

        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));

        assertEq(positions.length, 0);
    }
}
