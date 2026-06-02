// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {SparkLendBalanceOracle} from "src/balances/protocols/SparkLend.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

contract MockAavePoolAddressesProvider {
    address public pool;
    constructor(address pool_) { pool = pool_; }
    function getPool() external view returns (address) { return pool; }
    function getLendingPool() external view returns (address) { return pool; }
}

contract MockAddressesProviderSource {
    MockAavePoolAddressesProvider public ap;
    constructor(address pool_) { ap = new MockAavePoolAddressesProvider(pool_); }
    function ADDRESSES_PROVIDER() external view returns (address) { return address(ap); }
}

contract MockAaveProtocolDataProvider {
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

    MockAddressesProviderSource public _src;
    TokenData[] public reserves;

    constructor() {
        _src = new MockAddressesProviderSource(address(0x1234));
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(_src.ADDRESSES_PROVIDER());
    }

    function getAllReservesTokens() external view returns (TokenData[] memory) {
        return reserves;
    }

    function getUserReserveData(
        address,
        /* asset */
        address /* user */
    )
        external
        pure
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        )
    {
        // Return zeros for all values (can be customized in tests if needed)
        return (0, 0, 0, 0, 0, 0, 0, 0, false);
    }

    function addReserve(string memory symbol, address tokenAddress) external {
        reserves.push(TokenData({symbol: symbol, tokenAddress: tokenAddress}));
    }
}

/// @title SparkLendBalanceOracleTest
/// @notice Unit and implementation tests for SparkLendBalanceOracle
/// @dev Tests adapter logic and error handling without requiring fork
/// @dev SparkLend inherits from AaveV3Instance, so most logic is tested there
contract SparkLendBalanceOracleTest is BalanceAdapterTestBase {
    SparkLendBalanceOracle public oracle;
    MockAaveProtocolDataProvider public mockDataProvider;

    function setUp() public override {
        super.setUp();
        mockDataProvider = new MockAaveProtocolDataProvider();
        oracle = new SparkLendBalanceOracle(address(mockDataProvider), address(balances));
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        // getOracleBalanceForAsset should return 0 for unsupported tokens
        (uint256 amount,) = oracle.getOracleBalanceForAsset(alice, invalidToken);
        assertEq(amount, 0);
    }

    function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
        (uint256 amount,) = oracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
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
