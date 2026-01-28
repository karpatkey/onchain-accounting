// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {GmxBalanceOracle} from "src/balances/protocols/GMX.sol";
import {IMarket, IDataStore, IGMXReader} from "src/balances/protocols/GMX.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Mock GMX DataStore (constructor only needs it to be a contract; containsBytes32 unused at construction)
contract MockGMXDataStore is IDataStore {
    function containsBytes32(bytes32, bytes32) external pure returns (bool) {
        return false;
    }
}

/// @notice Mock GMX Market that returns a fixed dataStore address
contract MockGMXMarket is IMarket {
    address public override dataStore;

    constructor(address dataStore_) {
        dataStore = dataStore_;
    }
}

    /// @notice Mock GMX Reader that returns fixed MarketProps for getMarket (getPositionInfo not used in unit tests)
    contract MockGMXReader {
        IGMXReader.MarketProps private _props;

        constructor(address marketToken, address indexToken, address longToken, address shortToken) {
            _props = IGMXReader.MarketProps(marketToken, indexToken, longToken, shortToken);
        }

        function getMarket(IDataStore, address) external view returns (IGMXReader.MarketProps memory) {
            return _props;
        }
    }

    /// @title GmxBalanceOracleTest
    /// @notice Unit and implementation tests for GmxBalanceOracle
    /// @dev Tests adapter logic and error handling without requiring fork
    contract GmxBalanceOracleTest is BalanceAdapterTestBase {
        GmxBalanceOracle public oracle;
        MockGMXDataStore public mockDataStore;
        MockGMXMarket public mockMarket;
        MockGMXReader public mockReader;
        MockContract public mockReferralStorage;
        MockContract public mockPriceFeed;

        function setUp() public override {
            super.setUp();
            mockDataStore = new MockGMXDataStore();
            mockMarket = new MockGMXMarket(address(mockDataStore));
            mockReader = new MockGMXReader(
                address(usdc), // marketToken
                address(weth), // indexToken
                address(weth), // longToken
                address(usdc) // shortToken
            );
            mockReferralStorage = new MockContract();
            mockPriceFeed = new MockContract();

            GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
            feeds[0] = GmxBalanceOracle.TokenFeed(address(usdc), address(mockPriceFeed));
            feeds[1] = GmxBalanceOracle.TokenFeed(address(weth), address(mockPriceFeed));

            oracle = new GmxBalanceOracle(
                address(mockMarket),
                address(mockReader),
                address(mockReferralStorage),
                address(usdc),
                address(weth),
                false,
                feeds,
                "GMX",
                "Test Market",
                address(balances)
            );
        }

        // ============================================
        // Error Handling Tests
        // ============================================

        function test_getOracleBalanceForAsset_returns_zero_for_zero_address() public view {
            int256 balance = oracle.getOracleBalanceForAsset(address(0), address(usdc));
            assertEq(balance, 0);
        }

        // ============================================
        // Interface Compliance Tests
        // ============================================

        function test_getOracleBalance_returnsEmptyArraysForZeroAddress() public view {
            (address[] memory assets, int256[] memory balances) = oracle.getOracleBalance(address(0));

            assertEq(assets.length, 0);
            assertEq(balances.length, 0);
        }

        function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
            INAVCalculator.PositionBalance[] memory positions = oracle.getOraclePositions(address(0), address(0));

            assertEq(positions.length, 0);
        }
    }
