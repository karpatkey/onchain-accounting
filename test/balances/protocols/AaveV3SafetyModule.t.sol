// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV3SafetyModuleBalanceOracle} from "src/balances/protocols/aave/AaveV3SafetyModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @notice Mock stake token that returns reward/staked token addresses (required by AaveV3SafetyModule constructor)
contract MockStakeToken {
    address public immutable REWARD_TOKEN;
    address public immutable STAKED_TOKEN;

    constructor(address rewardToken_, address stakedToken_) {
        REWARD_TOKEN = rewardToken_;
        STAKED_TOKEN = stakedToken_;
    }
}

/// @title AaveV3SafetyModuleBalanceOracleTest
/// @notice Unit and implementation tests for AaveV3SafetyModuleBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
contract AaveV3SafetyModuleBalanceOracleTest is BalanceAdapterTestBase {
    AaveV3SafetyModuleBalanceOracle public oracle;
    MockBalances public mockBalances;
    MockStakeToken public mockStakeToken;

    function setUp() public override {
        super.setUp();
        mockBalances = new MockBalances();
        mockStakeToken = new MockStakeToken(address(usdc), address(dai));
        oracle =
            new AaveV3SafetyModuleBalanceOracle(address(mockStakeToken), "Aave v3", "Safety Module", address(balances));
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        new AaveV3SafetyModuleBalanceOracle(address(0), "Aave v3", "Safety Module", address(mockBalances));
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, invalidToken);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        (uint256 amount1,) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount1, 0);

        (uint256 amount2,) = oracle.getOracleBalanceForAsset(address(0), address(dai));
        assertEq(amount2, 0);
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_supportsInterface() public view {
        assertTrue(oracle.supportsInterface(type(IBalanceOracleAdapter).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
    }

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
