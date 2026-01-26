// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPriceFeedCustom} from "src/prices/IPriceFeedCustom.sol";

/// @title Mock Reverting Balance Oracle
/// @notice Oracle that reverts on query for testing error handling
contract Mock_RevertingBalanceOracle is IBalanceOracleAdapter {
    bool public shouldRevert = true;
    
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
    
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
    
    function getOraclePositions(address, address) external view override returns (INAVCalculator.PositionBalance[] memory) {
        if (shouldRevert) {
            revert("Oracle revert");
        }
        return new INAVCalculator.PositionBalance[](0);
    }
    
    function getOracleBalance(address) external view override returns (address[] memory, int256[] memory) {
        if (shouldRevert) {
            revert("Oracle revert");
        }
        return (new address[](0), new int256[](0));
    }
    
    function getOracleBalanceForAsset(address, address) external view override returns (int256) {
        if (shouldRevert) {
            revert("Oracle revert");
        }
        return 0;
    }
    
    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }
}

/// @title Mock Reverting Price Oracle
/// @notice Price oracle that reverts for testing error handling
contract Mock_RevertingPriceOracle is IPriceFeedCustom {
    function getLatestPrice() external pure override returns (uint256, bool) {
        revert("Price oracle revert");
    }
    
    function decimals() external pure override returns (uint8) {
        return 8;
    }
    
    function underlyingAssetSupported() external pure override returns (address) {
        return address(0);
    }
    
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title Mock Malformed Price Oracle
/// @notice Price oracle that returns invalid data
contract Mock_MalformedPriceOracle is IPriceFeedCustom {
    function getLatestPrice() external pure override returns (uint256, bool) {
        // Return zero price (should be marked as stale)
        return (0, true);
    }
    
    function decimals() external pure override returns (uint8) {
        return 8;
    }
    
    function underlyingAssetSupported() external pure override returns (address) {
        return address(0);
    }
    
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPriceFeedCustom).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title NAVCalculator Error Handling Tests
/// @notice Tests error scenarios and graceful degradation
contract NAVCalculatorErrorTest is SuperTest {
    Mock_RevertingBalanceOracle public revertingOracle;
    
    function setUp() public {
        setupAll();
        revertingOracle = new Mock_RevertingBalanceOracle();
    }
    
    // ============================================
    // Oracle Revert Handling
    // ============================================
    
    /// @notice Test that oracle reverts are handled gracefully
    function test_RevertWhen_oracleReverts_handledGracefully() public {
        // Add reverting oracle
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(revertingOracle));
        vm.stopPrank();
        
        // Setup other oracles with valid data
        usdc.mint(safe, 10 ** usdc.decimals());
        
        // Query should not revert, but skip the reverting oracle
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        
        // Should still get NAV from other oracles
        assertGe(navResult.value, 0, "Should get NAV from non-reverting oracles");
        
        // Get positions - should not include positions from reverting oracle
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        
        // Verify no positions from reverting oracle
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(
                positions[i].balanceOracle != address(revertingOracle),
                "Should not have positions from reverting oracle"
            );
        }
    }
    
    /// @notice Test that multiple oracle reverts are handled
    function test_RevertWhen_multipleOracleReverts_handledGracefully() public {
        // Add multiple reverting oracles
        Mock_RevertingBalanceOracle oracle2 = new Mock_RevertingBalanceOracle();
        Mock_RevertingBalanceOracle oracle3 = new Mock_RevertingBalanceOracle();
        
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(revertingOracle));
        nav.addBalanceOracle(address(oracle2));
        nav.addBalanceOracle(address(oracle3));
        vm.stopPrank();
        
        // Setup valid data
        usdc.mint(safe, 10 ** usdc.decimals());
        
        // Should still work with other oracles
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        assertGe(navResult.value, 0, "Should work despite multiple reverting oracles");
    }
    
    /// @notice Test that oracle can recover from revert
    function test_RevertWhen_oracleRecoversFromRevert() public {
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(revertingOracle));
        vm.stopPrank();
        
        usdc.mint(safe, 10 ** usdc.decimals());
        
        // First query - oracle reverts
        INAVCalculator.NAV memory nav1 = nav.getAccountNav(safe, address(0));
        
        // Stop oracle from reverting
        revertingOracle.setShouldRevert(false);
        
        // Second query - oracle should work now
        INAVCalculator.NAV memory nav2 = nav.getAccountNav(safe, address(0));
        
        // NAV should be same or greater (oracle might add positions)
        assertGe(nav2.value, nav1.value, "NAV should be same or greater after oracle recovery");
    }
    
    // ============================================
    // Price Oracle Revert Handling
    // ============================================
    
    /// @notice Test that price oracle reverts are handled properly
    function test_RevertWhen_priceOracleReverts() public {
        // Create reverting price oracle
        Mock_RevertingPriceOracle revertingPriceOracle = new Mock_RevertingPriceOracle();
        
        // Create new token
        Mock_ERC20 token = new Mock_ERC20("REVERT", 18);
        
        vm.startPrank(navCalculatorManager);
        // Register with reverting price oracle
        nav.registerAsset(address(token), address(revertingPriceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        
        token.mint(safe, 10 ** 18);
        
        // Getting NAV should revert with proper error
        vm.expectRevert();
        nav.getAccountNav(safe, address(0));
    }
    
    /// @notice Test that malformed price oracle responses are handled
    function test_RevertWhen_malformedPriceOracle() public {
        // Create malformed price oracle (returns zero price)
        Mock_MalformedPriceOracle malformedOracle = new Mock_MalformedPriceOracle();
        
        Mock_ERC20 token = new Mock_ERC20("MALFORMED", 18);
        
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token), address(malformedOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        
        token.mint(safe, 10 ** 18);
        
        // Should handle zero price (marked as stale)
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        
        // Price should be marked as stale
        (,, bool stale) = nav.latestPrice(address(token));
        assertTrue(stale, "Zero price should be marked as stale");
        
        // NAV might be zero or the position might be excluded
        // The important thing is it doesn't revert
    }
    
    // ============================================
    // Interface Mismatch Handling
    // ============================================
    
    /// @notice Test that invalid oracle interface is rejected
    function test_RevertWhen_invalidOracleInterface() public {
        // Try to add a contract that doesn't implement IBalanceOracleAdapter
        address invalidOracle = address(usdc); // ERC20 doesn't implement IBalanceOracleAdapter
        
        vm.startPrank(navCalculatorManager);
        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        nav.addBalanceOracle(invalidOracle);
        vm.stopPrank();
    }
    
    /// @notice Test that zero address oracle is rejected
    function test_RevertWhen_zeroAddressOracle() public {
        vm.startPrank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.addBalanceOracle(address(0));
        vm.stopPrank();
    }
    
    // ============================================
    // Concurrent Failures
    // ============================================
    
    /// @notice Test handling of concurrent oracle and price failures
    function test_RevertWhen_concurrentFailures() public {
        // Add reverting balance oracle
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(revertingOracle));
        
        // Create token with reverting price oracle
        Mock_RevertingPriceOracle revertingPriceOracle = new Mock_RevertingPriceOracle();
        Mock_ERC20 token = new Mock_ERC20("FAIL", 18);
        nav.registerAsset(address(token), address(revertingPriceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        
        // Setup valid data with other assets
        usdc.mint(safe, 10 ** usdc.decimals());
        
        // Should still work with valid assets
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        
        // Should get NAV from valid assets
        assertGe(navResult.value, 0, "Should work despite concurrent failures");
        
        // But querying the failing asset should revert
        token.mint(safe, 10 ** 18);
        vm.expectRevert();
        nav.getAccountNav(safe, address(0));
    }
    
    // ============================================
    // Error Recovery
    // ============================================
    
    /// @notice Test that system recovers after oracle removal
    function test_RevertWhen_oracleRemovalRecovery() public {
        // Add reverting oracle
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(revertingOracle));
        vm.stopPrank();
        
        usdc.mint(safe, 10 ** usdc.decimals());
        
        // Query with reverting oracle
        INAVCalculator.NAV memory nav1 = nav.getAccountNav(safe, address(0));
        
        // Remove reverting oracle
        vm.startPrank(navCalculatorManager);
        nav.removeBalanceOracle(address(revertingOracle));
        vm.stopPrank();
        
        // Query again - should work normally
        INAVCalculator.NAV memory nav2 = nav.getAccountNav(safe, address(0));
        
        // NAV should be consistent
        assertEq(nav1.value, nav2.value, "NAV should be consistent after oracle removal");
    }
    
    // ============================================
    // Edge Cases
    // ============================================
    
    /// @notice Test that all oracles reverting still allows query (returns zero NAV)
    function test_RevertWhen_allOraclesRevert() public {
        // Add multiple reverting oracles
        Mock_RevertingBalanceOracle oracle2 = new Mock_RevertingBalanceOracle();
        Mock_RevertingBalanceOracle oracle3 = new Mock_RevertingBalanceOracle();
        
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(revertingOracle));
        nav.addBalanceOracle(address(oracle2));
        nav.addBalanceOracle(address(oracle3));
        vm.stopPrank();
        
        // Don't mint any tokens (so ERC20DefaultOracle has no positions)
        
        // Should return zero NAV, not revert
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        assertEq(navResult.value, 0, "Should return zero NAV when all oracles revert or have no positions");
    }
    
    /// @notice Test that invalid quote currency is handled
    function test_RevertWhen_invalidQuoteCurrency() public {
        address invalidQuote = makeAddr("invalid");
        
        // Should revert with PriceFeedNotSet
        vm.expectRevert(abi.encodeWithSelector(PriceFeedNotSet.selector, invalidQuote));
        nav.getAccountNav(safe, invalidQuote);
    }
    
    /// @notice Test that unregistered asset in calculateValue is handled
    function test_RevertWhen_unregisteredAssetInCalculateValue() public {
        address unregisteredAsset = makeAddr("unregistered");
        
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bool[] memory isDebt = new bool[](1);
        assets[0] = unregisteredAsset;
        amounts[0] = 1e18;
        isDebt[0] = false;
        
        vm.expectRevert(AssetNotFound.selector);
        nav.calculateValue(assets, amounts, isDebt, address(0));
    }
    
    /// @notice Test that array length mismatch in calculateValue is handled
    function test_RevertWhen_arrayLengthMismatch() public {
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        bool[] memory isDebt = new bool[](1);
        
        assets[0] = address(usdc);
        assets[1] = address(dai);
        amounts[0] = 1e18;
        isDebt[0] = false;
        
        vm.expectRevert(abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "arrays.length mismatch"));
        nav.calculateValue(assets, amounts, isDebt, address(0));
    }
}
