// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {SparkLendBalanceAdapter} from "src/balances/protocols/SparkLend.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

contract MockAavePoolAddressesProvider {
    address public pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function getPool() external view returns (address) {
        return pool;
    }

    function getLendingPool() external view returns (address) {
        return pool;
    }
}

contract MockAddressesProviderSource {
    MockAavePoolAddressesProvider public ap;

    constructor(address pool_) {
        ap = new MockAavePoolAddressesProvider(pool_);
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(ap);
    }
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

/// @title SparkLendBalanceAdapterTest
/// @notice Unit and implementation tests for SparkLendBalanceAdapter
/// @dev Tests adapter logic and error handling without requiring fork
/// @dev SparkLend inherits from AaveV3Instance, so most logic is tested there
contract SparkLendBalanceAdapterTest is BalanceAdapterTestBase {
    SparkLendBalanceAdapter public adapter;
    MockAaveProtocolDataProvider public mockDataProvider;

    function setUp() public override {
        super.setUp();
        mockDataProvider = new MockAaveProtocolDataProvider();
        adapter = new SparkLendBalanceAdapter(address(mockDataProvider), address(balances));
    }

    // ============================================
    // Error Handling Tests
    // ============================================

    function test_getAdapterBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");

        // getAdapterBalanceForAsset should return 0 for unsupported tokens
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(alice, invalidToken);
        assertEq(amount, 0);
    }

    function test_getAdapterBalanceForAsset_returns_zero_for_zero_address() public view {
        (uint256 amount,) = adapter.getAdapterBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0);
    }

    // ============================================
    // Interface Compliance Tests
    // ============================================

    function test_getAdapterBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, uint256[] memory amounts,) = adapter.getAdapterBalances(address(0));

        assertEq(assets.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_getAdapterPositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(address(0), address(0));

        assertEq(positions.length, 0);
    }
}
