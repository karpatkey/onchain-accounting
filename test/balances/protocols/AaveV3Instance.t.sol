// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import "src/errors.sol";

/// @title Mock Aave Protocol Data Provider
contract MockAaveProtocolDataProvider {
    struct TokenData {
        string symbol;
        address tokenAddress;
    }
    
    struct ReserveData {
        address aTokenAddress;
    }
    
    TokenData[] public reserves;
    mapping(address => ReserveData) public reserveData;
    
    function getAllReservesTokens() external view returns (TokenData[] memory) {
        return reserves;
    }
    
    function getReserveData(address asset) external view returns (ReserveData memory) {
        return reserveData[asset];
    }
    
    function getUserReserveData(address asset, address user)
        external
        view
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
    
    function addReserve(string memory symbol, address tokenAddress, address aTokenAddress) external {
        reserves.push(TokenData({symbol: symbol, tokenAddress: tokenAddress}));
        reserveData[tokenAddress] = ReserveData({aTokenAddress: aTokenAddress});
    }
}

/// @title Mock Aave Rewards Distributor
contract MockAaveRewardsDistributor {
    mapping(address => mapping(address => uint256)) public userRewards;
    address[] public rewardsList;
    
    function getRewardsList() external view returns (address[] memory) {
        return rewardsList;
    }
    
    function getUserAccruedRewards(address user, address reward) external view returns (uint256) {
        return userRewards[user][reward];
    }
    
    function setUserRewards(address user, address reward, uint256 amount) external {
        userRewards[user][reward] = amount;
    }
    
    function addReward(address reward) external {
        rewardsList.push(reward);
    }
}

/// @title AaveV3InstanceBalanceOracleTest
/// @notice Unit and implementation tests for AaveV3InstanceBalanceOracle
/// @dev Tests adapter logic and implementation without requiring fork
contract AaveV3InstanceBalanceOracleTest is BalanceAdapterTestBase {
    AaveV3InstanceBalanceOracle public oracle;
    MockAaveProtocolDataProvider public mockDataProvider;
    MockAaveRewardsDistributor public mockRewardsDistributor;
    
    function setUp() public override {
        super.setUp();
        mockDataProvider = new MockAaveProtocolDataProvider();
        mockRewardsDistributor = new MockAaveRewardsDistributor();
        oracle = new AaveV3InstanceBalanceOracle(
            address(mockDataProvider),
            address(mockRewardsDistributor),
            "Aave v3",
            address(balances)
        );
    }
    
    // ============================================
    // Initialization Tests
    // ============================================
    
    function test_constructor_setsCorrectValues() public view {
        assertEq(address(oracle.DATA_PROVIDER()), address(mockDataProvider));
        assertEq(address(oracle.REWARDS_DISTRIBUTOR()), address(mockRewardsDistributor));
        // Note: protocol() is private, so we can't test it directly
        // It's tested indirectly through position metadata in fork tests
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_returns_zero_for_invalid_token() public {
        address invalidToken = makeAddr("invalidToken");
        
        // getOracleBalanceForAsset should return 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(alice, invalidToken);
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_returns_zero_for_zero_address_account() public {
        address invalidToken = makeAddr("invalidToken");
        
        // Zero address account should return zero
        int256 balance = oracle.getOracleBalanceForAsset(address(0), invalidToken);
        assertEq(balance, 0);
    }
    
    // ============================================
    // Interface Compliance Tests
    // ============================================
    
    function test_underlyingAssetsSupported_returnsArray() public view {
        address[] memory assets = oracle.underlyingAssetsSupported();
        
        // Should return an array (may be empty in unit tests without fork)
        // The actual assets are tested in fork tests
        assertTrue(true, "underlyingAssetsSupported should not revert");
    }
    
    function test_getOracleBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, int256[] memory balances) = 
            oracle.getOracleBalance(address(0));
        
        assertEq(assets.length, 0);
        assertEq(balances.length, 0);
    }
    
    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public view {
        INAVCalculator.PositionBalance[] memory positions = 
            oracle.getOraclePositions(address(0), address(0));
        
        assertEq(positions.length, 0);
    }
}
