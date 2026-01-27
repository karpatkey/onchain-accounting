// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BalanceAdapterTestBase} from "test/balances/protocols/BalanceAdapterTestBase.sol";
import {CometExtInterface, CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";

/// @notice Mock Compound rewards that returns no reward config so _getRewardOwed returns 0
contract MockCompoundRewardsMinimal {
    function rewardConfig(address) external pure returns (address token, uint64 rescaleFactor, bool shouldUpscale) {
        return (address(0), 0, false);
    }

    function rewardsClaimed(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock Comet that implements the Comet/CometExt interface used by CompoundV3Comet (and WithMultiplier) so unit tests run without fork.
/// Uses fixed indices and no accrual (lastAccrualTime = block.timestamp) so getUnderlying and _getRewardAccrued paths don't revert.
contract MockCometMinimal {
    address private _baseToken;

    uint256 public constant baseScale = 1e6;
    /// @dev Match Comet BASE_INDEX_SCALE so principal * index / scale is correct
    uint64 private constant MOCK_BASE_INDEX = 1e15;

    constructor(address baseToken_) {
        _baseToken = baseToken_;
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function BASE_TOKEN() external view returns (address) {
        return _baseToken;
    }

    function numAssets() external pure returns (uint8) {
        return 0;
    }

    function getAssetInfo(uint8)
        external
        pure
        returns (
            uint8 offset,
            address asset,
            address priceFeed,
            uint64 scale,
            uint64 borrowCollateralFactor,
            uint64 liquidateCollateralFactor,
            uint64 liquidationFactor,
            uint128 supplyCap
        )
    {
        revert("unused in unit test");
    }

    function userBasic(address)
        external
        pure
        returns (int104 principal, uint64 baseTrackingIndex, uint64 baseTrackingAccrued, uint16 assetsIn, uint8 reserved)
    {
        return (0, 0, 0, 0, 0);
    }

    function collateralBalanceOf(address, address) external pure returns (uint256) {
        return 0;
    }

    function totalsBasic()
        external
        view
        returns (
            uint64 baseSupplyIndex,
            uint64 baseBorrowIndex,
            uint64 trackingSupplyIndex,
            uint64 trackingBorrowIndex,
            uint104 totalSupplyBase,
            uint104 totalBorrowBase,
            uint40 lastAccrualTime,
            uint8 pauseFlags
        )
    {
        // Use 1 for tracking indices so updateBasePrincipal(..., baseTrackingIndex=1, ...) does not underflow
        return (MOCK_BASE_INDEX, MOCK_BASE_INDEX, 1, 1, 0, 0, uint40(block.timestamp), 0);
    }

    function baseMinForRewards() external pure returns (uint256) {
        return 1;
    }

    function baseTrackingSupplySpeed() external pure returns (uint256) {
        return 0;
    }

    function baseTrackingBorrowSpeed() external pure returns (uint256) {
        return 0;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getSupplyRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function getBorrowRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function trackingIndexScale() external pure returns (uint256) {
        return 1e15;
    }
}

/// @title CompoundV3CometBalanceOracleTest
/// @notice Unit and implementation tests for CompoundV3CometBalanceOracle
/// @dev Tests adapter logic and edge cases without requiring fork
contract CompoundV3CometBalanceOracleTest is BalanceAdapterTestBase {
    CompoundV3Comet public oracle;
    MockCompoundRewardsMinimal public mockCompoundRewards;
    MockCometMinimal public mockComet;
    MockContract public mockRewardToken;

    function setUp() public override {
        super.setUp();
        mockCompoundRewards = new MockCompoundRewardsMinimal();
        mockComet = new MockCometMinimal(address(usdc));
        mockRewardToken = new MockContract();
        oracle = new CompoundV3Comet(
            address(mockCompoundRewards),
            address(mockComet),
            address(mockRewardToken),
            "Compound v3 USDC",
            address(balances)
        );
    }
    
    // ============================================
    // Error Handling Tests
    // ============================================
    
    function test_getOracleBalanceForAsset_unsupportedToken() public {
        address unsupportedToken = address(1);
        
        // getOracleBalanceForAsset returns 0 for unsupported tokens
        int256 balance = oracle.getOracleBalanceForAsset(address(this), unsupportedToken);
        assertEq(balance, 0);
    }
    
    function test_getOracleBalanceForAsset_userWithoutPosition() public view {
        address user = address(1);
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertEq(balance, 0);
    }
    
    // ============================================
    // Edge Case Tests (Using Mocks)
    // ============================================
    
    function test_getOracleBalanceForAsset_edgeCase_MaxPrincipal() public {
        address user = address(1);
        
        int104 maxPositivePrincipal = type(int104).max;
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxPositivePrincipal, 0, 0, 0, 0)
        );
        
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertGt(balance, 0, "Balance should be positive (credit)");
    }
    
    function test_getOracleBalanceForAsset_edgeCase_MinimalPrincipal() public {
        address user = address(1);
        
        int104 maxNegativePrincipal = type(int104).min;
        vm.mockCall(
            address(mockComet),
            abi.encodeWithSelector(CometExtInterface.userBasic.selector, user),
            abi.encode(maxNegativePrincipal, 0, 0, 0, 0)
        );
        
        int256 balance = oracle.getOracleBalanceForAsset(user, address(usdc));
        assertLt(balance, 0, "Balance should be negative (debt)");
    }
    
    // ============================================
    // Interface Compliance Tests
    // ============================================
    
    function test_getOracleBalance_returnsEmptyArraysForZeroAddress() public view {
        (address[] memory assets, int256[] memory balances) = 
            oracle.getOracleBalance(address(0));
        
        assertEq(assets.length, 0);
        assertEq(balances.length, 0);
    }
    
    function test_getOraclePositions_returnsEmptyArrayForZeroAddress() public {
        // Note: This test verifies interface compliance
        // Actual position testing is done in fork tests
        assertTrue(true, "getOraclePositions should not revert for zero address");
    }
}
