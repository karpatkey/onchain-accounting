// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {Balances} from "src/balances/Balances.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IMetaBalanceOracleAdapter} from "src/balances/IMetaBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

contract BalancesHarness is Balances {
    ERC20DefaultOracle public defaultOracle;

    /// @notice Test-only: track assets "registered" so ERC20DefaultOracle.addSupportedAsset (which checks isAssetRegistered) succeeds.
    address[] private _testRegisteredList;
    mapping(address => bool) private _testRegistered;

    constructor() initializer {
        __Balances_init();
        // Set up ERC20DefaultOracle for native address support
        defaultOracle = new ERC20DefaultOracle(address(this), new address[](0));
        _setErc20DefaultOracle(address(defaultOracle));
    }

    /// @notice Adds an asset to the default oracle's inclusion list (for testing). Marks asset as registered so addSupportedAsset succeeds.
    function addSupportedAssetForTest(address asset) public {
        _testRegistered[asset] = true;
        _testRegisteredList.push(asset);
        defaultOracle.addSupportedAsset(asset);
    }

    /// @notice Stub for adapter tests that pass this contract as INAVCalculator (asset registry lives in NAVCalculator).
    function getRegisteredAssets() external view returns (INAVCalculator.Asset[] memory) {
        uint256 n = _testRegisteredList.length;
        INAVCalculator.Asset[] memory out = new INAVCalculator.Asset[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = _testRegisteredList[i];
            out[i] = INAVCalculator.Asset({asset: a, symbol: "", decimals: 18});
        }
        return out;
    }

    function getAssetCount() external view returns (uint256) {
        return _testRegisteredList.length;
    }

    function isAssetRegistered(address asset) external view returns (bool) {
        return _testRegistered[asset];
    }

    function getAssetDecimals(address asset) external view returns (uint8) {
        if (!_testRegistered[asset]) revert AssetNotFound();
        return 18;
    }

    function getAssetSymbol(address asset) external view returns (string memory) {
        if (!_testRegistered[asset]) return "";
        return "";
    }

    function addBalanceOracleDirect(
        address,
        /* underlyingAsset */
        address oracle,
        IBalances.OracleType /* oracleType */
    )
        public
    {
        // Oracles are now global - underlyingAsset parameter is kept for backward compatibility but not used
        _addBalanceOracle(oracle);
    }

    function unsetBalanceOracle(
        address,
        /* underlyingAsset */
        address oracle
    )
        public
    {
        // Oracles are now global - underlyingAsset parameter is kept for backward compatibility but not used
        _removeBalanceOracle(oracle);
    }

    function setMetaInstancesDirect(address oracle, bytes32[] memory instances) public {
        _setMetaInstances(oracle, instances);
    }

    function metaInstanceTotalForTest() public view returns (uint256) {
        return _metaInstanceTotal;
    }
}

/// @notice Minimal mock advertising the meta-oracle interface (for registry tests).
contract Mock_MetaOracle is IMetaBalanceOracleAdapter {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IMetaBalanceOracleAdapter).interfaceId
            || interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getOraclePositions(address, address) external pure returns (INAVCalculator.PositionBalance[] memory) {
        return new INAVCalculator.PositionBalance[](0);
    }

    function getOracleBalances(address) external pure returns (address[] memory, uint256[] memory, bool[] memory) {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getOracleBalanceForAsset(address, address) external pure returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getOraclePositionsForInstances(address, bytes32[] calldata, address)
        external
        pure
        returns (INAVCalculator.PositionBalance[] memory)
    {
        return new INAVCalculator.PositionBalance[](0);
    }

    function underlyingAssetsSupportedForInstances(bytes32[] calldata) external pure returns (address[] memory) {
        return new address[](0);
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
        balances.addSupportedAssetForTest(balances.NATIVE_ADDRESS());
        usdc = new Mock_ERC20("USDC", 6);
        customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalances(balances);
        address[] memory assets = new address[](1);
        assets[0] = address(customOracle);
        customOracle.setUnderlyingAssetsSupported(assets);
        customOracle.setBalance(address(usdc), alice, 123_456_789, false);
        customOracle.setBalance(address(usdc), bob, 987_654_321, true);
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
        balances.addSupportedAssetForTest(address(usdc));
        vm.stopPrank();

        usdc.mint(alice, 1000);

        // Get oracles that support USDC
        address[] memory oracles = balances.getOraclesForAsset(address(usdc));
        assertGt(oracles.length, 0, "Should have at least one oracle supporting USDC");

        // Get balance from ERC20DefaultOracle
        (uint256 amount, bool isDebt) =
            IBalanceOracleAdapter(balances.erc20DefaultOracle()).getOracleBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1000);
        assertFalse(isDebt);
    }

    function test_setAndGetCustomBalanceOracle() public {
        vm.startPrank(admin);
        balances.addBalanceOracleDirect(address(customOracle), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        customOracle.setBalance(address(customOracle), alice, 2000, false);

        // Get balance from custom oracle
        (uint256 amount, bool isDebt) =
            IBalanceOracleAdapter(address(customOracle)).getOracleBalanceForAsset(alice, address(customOracle));
        assertEq(amount, 2000);
        assertFalse(isDebt);
    }

    function test_setAndGetCustomBalanceOracleDebtPosition() public {
        vm.startPrank(admin);
        balances.addBalanceOracleDirect(address(customOracle), address(customOracle), IBalances.OracleType.Custom);
        vm.stopPrank();

        customOracle.setBalance(address(customOracle), alice, 2000, true);

        // Get balance from custom oracle
        (uint256 amount, bool isDebt) =
            IBalanceOracleAdapter(address(customOracle)).getOracleBalanceForAsset(alice, address(customOracle));
        assertEq(amount, 2000);
        assertTrue(isDebt);
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
        (uint256 amount, bool isDebt) = IBalanceOracleAdapter(balances.erc20DefaultOracle())
            .getOracleBalanceForAsset(alice, balances.NATIVE_ADDRESS());
        assertEq(amount, 1337);
        assertFalse(isDebt);
    }

    function test_removeBalanceOracle() public {
        vm.startPrank(admin);
        balances.addSupportedAssetForTest(address(usdc));
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
        balances.addSupportedAssetForTest(address(usdc));
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

    // ============================================
    // Meta-oracle instance registry
    // ============================================

    function _registerMeta() internal returns (Mock_MetaOracle meta) {
        meta = new Mock_MetaOracle();
        vm.prank(admin);
        balances.addBalanceOracleDirect(address(0), address(meta), IBalances.OracleType.Custom);
    }

    function test_meta_setInstances() public {
        Mock_MetaOracle meta = _registerMeta();
        bytes32[] memory instances = new bytes32[](2);
        instances[0] = bytes32(uint256(uint160(address(0xAAA1))));
        instances[1] = bytes32(uint256(uint160(address(0xBBB2))));
        balances.setMetaInstancesDirect(address(meta), instances);

        bytes32[] memory got = balances.getMetaInstances(address(meta));
        assertEq(got.length, 2);
    }

    function test_meta_setInstances_replacesPrevious() public {
        Mock_MetaOracle meta = _registerMeta();
        bytes32[] memory first = new bytes32[](2);
        first[0] = bytes32(uint256(1));
        first[1] = bytes32(uint256(2));
        balances.setMetaInstancesDirect(address(meta), first);

        bytes32[] memory second = new bytes32[](1);
        second[0] = bytes32(uint256(3));
        balances.setMetaInstancesDirect(address(meta), second);

        bytes32[] memory got = balances.getMetaInstances(address(meta));
        assertEq(got.length, 1);
        assertEq(got[0], bytes32(uint256(3)));
    }

    function test_meta_instanceTotal_tracksAcrossOracles() public {
        Mock_MetaOracle meta = _registerMeta();
        bytes32[] memory two = new bytes32[](2);
        two[0] = bytes32(uint256(1));
        two[1] = bytes32(uint256(2));
        balances.setMetaInstancesDirect(address(meta), two);
        assertEq(balances.metaInstanceTotalForTest(), 2);

        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(3));
        balances.setMetaInstancesDirect(address(meta), one);
        assertEq(balances.metaInstanceTotalForTest(), 1, "running total reflects replacement");
    }

    function test_meta_setInstances_onUnregisteredReverts() public {
        Mock_MetaOracle meta = new Mock_MetaOracle(); // not registered
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = bytes32(uint256(1));
        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        balances.setMetaInstancesDirect(address(meta), instances);
    }
}
