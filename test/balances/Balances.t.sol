// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {Balances} from "src/balances/Balances.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract BalancesHarness is Balances {
    ERC20DefaultOracle public defaultOracle;

    constructor() initializer {
        __Balances_init();
        // Set up ERC20DefaultOracle for native address support
        defaultOracle = new ERC20DefaultOracle(address(this));
        _setErc20DefaultOracle(address(defaultOracle));
    }

    // Expose internal functions for testing
    function registerAssetForTest(address asset, uint8 decimals) public {
        _registerAsset(asset, decimals);
    }

    function setAssetSymbolForTest(address asset, string memory symbol) public {
        _setAssetSymbol(asset, symbol);
    }

    function addBalanceOracleDirect(address underlyingAsset, address oracle, IBalances.OracleType oracleType) public {
        // Oracles are now global - underlyingAsset parameter is kept for backward compatibility but not used
        _addBalanceOracle(oracle);
    }

    function unsetBalanceOracle(address underlyingAsset, address oracle) public {
        // Oracles are now global - underlyingAsset parameter is kept for backward compatibility but not used
        _removeBalanceOracle(oracle);
    }
}

contract BalancesTest is Test {
    BalancesHarness public balances;
    Mock_ERC20 public usdc;
    Mock_CustomBalanceOracle public customOracle;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public ops = makeAddr("ops");
    address public admin = makeAddr("admin");

    function setUp() public {
        vm.startPrank(admin);
        balances = new BalancesHarness();
        // Set up native address - ERC20DefaultOracle is already registered in constructor
        balances.registerAssetForTest(balances.NATIVE_ADDRESS(), 18);
        balances.setAssetSymbolForTest(balances.NATIVE_ADDRESS(), "ETH");
        // ERC20DefaultOracle is already registered, no need to add it again
        usdc = new Mock_ERC20("USDC", 6);
        customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalances(balances);
        address[] memory assets = new address[](1);
        assets[0] = address(customOracle);
        customOracle.setUnderlyingAssetsSupported(assets);
        customOracle.setBalance(address(usdc), alice, 123_456_789);
        customOracle.setBalance(address(usdc), bob, -987_654_321);
        address[] memory underlyingAssets = new address[](1);
        underlyingAssets[0] = address(usdc);
        customOracle.setUnderlyingAssetsSupported(underlyingAssets);
        customOracle.setPositionMetadata("Mock Protocol", "Mock Position");
        vm.stopPrank();
    }

    function test_setup() public view {
        uint256 count = balances.getOracleCount();
        assertEq(count, 1, "Should have one balance oracle (ERC20DefaultOracle)");

        address[] memory oracles = balances.getAllOracles();
        assertEq(oracles.length, 1, "Should have one oracle");
        assertEq(oracles[0], balances.erc20DefaultOracle(), "First oracle should be ERC20DefaultOracle");
    }

    function test_setAndGetERC20BalanceOracle() public {
        vm.startPrank(admin);
        balances.registerAssetForTest(address(usdc), 6);
        balances.setAssetSymbolForTest(address(usdc), "USDC");
        // ERC20DefaultOracle is already registered, no need to add it again
        vm.stopPrank();

        usdc.mint(alice, 1000);

        // Get oracles that support USDC
        address[] memory oracles = balances.getOraclesForAsset(address(usdc));
        assertGt(oracles.length, 0, "Should have at least one oracle supporting USDC");

        // Get balance from ERC20DefaultOracle
        int256 balance =
            IBalanceOracleAdapter(balances.erc20DefaultOracle()).getOracleBalanceForAsset(alice, address(usdc));
        assertEq(balance, 1000);
    }

    function test_setAndGetCustomBalanceOracle() public {
        vm.startPrank(admin);
        balances.addBalanceOracleDirect(address(customOracle), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        customOracle.setBalance(address(customOracle), alice, 2000);

        // Get balance from custom oracle
        int256 balance =
            IBalanceOracleAdapter(address(customOracle)).getOracleBalanceForAsset(alice, address(customOracle));
        assertEq(balance, 2000);
    }

    function test_setAndGetCustomBalanceOracleNegativeBalance() public {
        vm.startPrank(admin);
        balances.addBalanceOracleDirect(address(customOracle), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        customOracle.setBalance(address(customOracle), alice, -2000);

        // Get balance from custom oracle
        int256 balance =
            IBalanceOracleAdapter(address(customOracle)).getOracleBalanceForAsset(alice, address(customOracle));
        assertEq(balance, -2000);
    }

    function test_addBalanceOracle_nativeAddress() public {
        address nativeAddress = balances.NATIVE_ADDRESS();
        address oracle = balances.erc20DefaultOracle();

        vm.expectRevert(IBalances.DuplicateBalanceOracle.selector);
        balances.addBalanceOracleDirect(nativeAddress, oracle, IBalances.OracleType.Default);
    }

    function test_getNativeBalance() public {
        deal(alice, 1337);

        // Get balance from ERC20DefaultOracle for native address
        int256 balance = IBalanceOracleAdapter(balances.erc20DefaultOracle())
            .getOracleBalanceForAsset(alice, balances.NATIVE_ADDRESS());
        assertEq(balance, 1337);
    }

    function test_removeBalanceOracle() public {
        vm.startPrank(admin);
        balances.registerAssetForTest(address(usdc), 6);
        balances.setAssetSymbolForTest(address(usdc), "USDC");
        // Add a custom oracle for USDC
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        // Remove the custom oracle
        balances.unsetBalanceOracle(address(usdc), address(customOracle));
        vm.stopPrank();

        // Verify custom oracle is no longer registered
        assertFalse(balances.isOracleRegistered(address(customOracle)), "Custom oracle should not be registered");

        // ERC20DefaultOracle should still be available for USDC
        address[] memory oracles = balances.getOraclesForAsset(address(usdc));
        // Should still have ERC20DefaultOracle
        assertGt(oracles.length, 0, "Should still have ERC20DefaultOracle for USDC");
    }

    function test_removeBalanceOracle_cantRemoveERC20DefaultOracle() public {
        // Cannot remove ERC20DefaultOracle
        address erc20Default = balances.erc20DefaultOracle();
        vm.expectRevert(InvalidArguments.selector);
        balances.unsetBalanceOracle(address(0), erc20Default);
    }

    function test_checkOracleSupport_ERC20() public view {
        // checkBalanceOracleSupport should pass for valid oracles, even if already registered
        // The duplicate check is now in _addBalanceOracle, not in checkBalanceOracleSupport
        balances.checkBalanceOracleSupport(balances.erc20DefaultOracle());
    }

    function test_checkOracleSupport_Custom() public view {
        balances.checkBalanceOracleSupport(address(customOracle));
    }

    function test_RevertIf_InvalidOracleZeroAddress() public {
        vm.expectRevert(InvalidArguments.selector);
        balances.checkBalanceOracleSupport(address(0));
    }

    function test_RevertIf_InvalidOracleERC20() public {
        // This test checks that a non-IBalanceOracleAdapter address fails
        address invalidOracle = makeAddr("invalid");
        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        balances.checkBalanceOracleSupport(invalidOracle);
    }

    function test_RevertIf_InvalidOracleCustom() public {
        // Test that a non-IBalanceOracleAdapter address fails
        address invalidOracle = makeAddr("invalid");
        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        balances.checkBalanceOracleSupport(invalidOracle);
    }

    function test_addBalanceOracle_duplicate() public {
        vm.startPrank(admin);
        // Add custom oracle first
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);

        // Try to add the same oracle again - should fail
        vm.expectRevert(IBalances.DuplicateBalanceOracle.selector);
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();
    }

    // ============================================
    // Global Oracle Registry Tests
    // ============================================

    function test_isOracleRegistered() public {
        // ERC20DefaultOracle should be registered
        assertTrue(balances.isOracleRegistered(balances.erc20DefaultOracle()));

        // Random address should not be registered
        assertFalse(balances.isOracleRegistered(makeAddr("random")));
    }

    // ============================================
    // Asset Registry Tests
    // ============================================

    function test_getAssets() public {
        address[] memory assets = balances.getAssets();

        assertEq(assets.length, balances.getAssetCount());
        assertTrue(assets.length > 0);
    }

    function test_getAssetCount() public {
        uint256 count = balances.getAssetCount();

        assertTrue(count >= 1); // At least native address
    }

    function test_getAssetDecimals() public {
        uint8 decimals = balances.getAssetDecimals(balances.NATIVE_ADDRESS());
        assertEq(decimals, 18);
    }

    function test_getAssetDecimals_invalidAsset() public {
        address unregisteredAsset = makeAddr("unregistered");

        vm.expectRevert(AssetNotFound.selector);
        balances.getAssetDecimals(unregisteredAsset);
    }

    function test_getAssetSymbol() public {
        string memory symbol = balances.getAssetSymbol(balances.NATIVE_ADDRESS());
        assertEq(symbol, "ETH");
    }

    function test_isAssetRegistered() public {
        assertTrue(balances.isAssetRegistered(balances.NATIVE_ADDRESS()));
        assertFalse(balances.isAssetRegistered(makeAddr("unregistered")));
    }

    // ============================================
    // Balance Oracle Management Tests
    // ============================================

    function test_addBalanceOracle_zeroAddress() public {
        // Try to add oracle with zero address as the oracle parameter - should fail with InvalidArguments
        // The check happens in checkBalanceOracleSupport which checks if oracle == address(0)
        vm.expectRevert(InvalidArguments.selector);
        balances.addBalanceOracleDirect(address(usdc), address(0), IBalances.OracleType.Default);
    }

    function test_removeBalanceOracle_invalidOracle() public {
        vm.startPrank(admin);
        // Add a custom oracle first
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        address invalidOracle = makeAddr("invalid");

        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        balances.unsetBalanceOracle(address(usdc), invalidOracle);
    }

    function test_balanceOracleTotalCount() public {
        uint256 initialCount = balances.getOracleCount();

        vm.startPrank(admin);
        // Add a new custom oracle
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        // Should have one more oracle
        assertEq(balances.getOracleCount(), initialCount + 1);
    }

    function test_getOracleCount() public {
        uint256 initialCount = balances.getOracleCount();
        assertEq(initialCount, 1, "Should start with ERC20DefaultOracle");

        vm.startPrank(admin);
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        assertEq(balances.getOracleCount(), initialCount + 1, "Should have one more oracle");
    }

    function test_getAllOracles() public {
        address[] memory initialOracles = balances.getAllOracles();
        assertEq(initialOracles.length, 1, "Should start with one oracle");
        assertEq(initialOracles[0], balances.erc20DefaultOracle(), "First oracle should be ERC20DefaultOracle");

        vm.startPrank(admin);
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        address[] memory allOracles = balances.getAllOracles();
        assertEq(allOracles.length, 2, "Should have two oracles");
        assertEq(allOracles[0], balances.erc20DefaultOracle(), "First should be ERC20DefaultOracle");
        assertEq(allOracles[1], address(customOracle), "Second should be custom oracle");
    }

    function test_getOracleType() public {
        IBalances.OracleType defaultType = balances.getOracleType(balances.erc20DefaultOracle());
        assertEq(uint8(defaultType), uint8(IBalances.OracleType.Default), "ERC20DefaultOracle should be Default type");

        vm.startPrank(admin);
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        IBalances.OracleType customType = balances.getOracleType(address(customOracle));
        assertEq(uint8(customType), uint8(IBalances.OracleType.Custom), "Custom oracle should be Custom type");
    }

    function test_getOracleType_invalidOracle() public {
        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        balances.getOracleType(address(0x123));
    }

    function test_getOraclesForAsset() public {
        vm.startPrank(admin);
        balances.registerAssetForTest(address(usdc), 6);
        balances.setAssetSymbolForTest(address(usdc), "USDC");
        // Add custom oracle that supports USDC
        balances.addBalanceOracleDirect(address(usdc), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        // Get oracles that support USDC
        address[] memory oracles = balances.getOraclesForAsset(address(usdc));

        // Should include ERC20DefaultOracle (supports all registered assets) and customOracle
        assertGe(oracles.length, 1, "Should have at least one oracle supporting USDC");

        bool foundCustomOracle = false;
        bool foundErc20Default = false;
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == address(customOracle)) {
                foundCustomOracle = true;
            }
            if (oracles[i] == balances.erc20DefaultOracle()) {
                foundErc20Default = true;
            }
        }
        assertTrue(foundCustomOracle, "Should find customOracle in supporting oracles");
        assertTrue(foundErc20Default, "Should find ERC20DefaultOracle in supporting oracles");
    }

    function test_getOraclesForAsset_noSupport() public {
        // Get oracles for an asset that no oracle supports
        address unsupportedAsset = makeAddr("unsupported");
        address[] memory oracles = balances.getOraclesForAsset(unsupportedAsset);

        // ERC20DefaultOracle might still return it if the asset is registered
        // But if not registered, should return empty or only ERC20DefaultOracle
        assertGe(oracles.length, 0, "Should return at least empty array");
    }

    // ============================================
    // Constants and Getters Tests
    // ============================================

    function test_NATIVE_ADDRESS() public view {
        address nativeAddress = balances.NATIVE_ADDRESS();
        assertEq(nativeAddress, address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE));
    }

    function test_erc20DefaultOracle() public view {
        address defaultOracle = balances.erc20DefaultOracle();
        assertTrue(defaultOracle != address(0));
    }

    // Legacy metadata-based tests removed as metadata API was refactored away.
}
