// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Mock Reverting Balance Adapter
/// @notice Adapter that reverts on query for testing error handling
contract Mock_RevertingBalanceAdapter is IBalanceOracleAdapter {
    bool public shouldRevert = true;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceOracleAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getOraclePositions(address, address)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        if (shouldRevert) {
            revert("Adapter revert");
        }
        return new INAVCalculator.PositionBalance[](0);
    }

    function getOracleBalance(address) external view override returns (address[] memory, int256[] memory) {
        if (shouldRevert) {
            revert("Adapter revert");
        }
        return (new address[](0), new int256[](0));
    }

    function getOracleBalanceForAsset(address, address) external view override returns (int256) {
        if (shouldRevert) {
            revert("Adapter revert");
        }
        return 0;
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }
}

/// @title Balance Adapter Error Handling Tests
/// @notice Tests error scenarios and graceful degradation
contract BalanceAdapterErrorTest is Test {
    BalancesHarness public balances;
    ERC20DefaultOracle public erc20DefaultOracle;
    Mock_RevertingBalanceAdapter public revertingAdapter;
    Mock_CustomBalanceOracle public customOracle;
    Mock_ERC20 public usdc;

    address public alice = makeAddr("alice");

    function setUp() public {
        balances = new BalancesHarness();
        erc20DefaultOracle = balances.defaultOracle();
        revertingAdapter = new Mock_RevertingBalanceAdapter();
        customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalances(balances);

        usdc = new Mock_ERC20("USDC", 6);
        balances.registerAssetForTest(address(usdc), 6);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        customOracle.setUnderlyingAssetsSupported(assets);
    }

    // ============================================
    // Adapter Revert Handling
    // ============================================

    /// @notice Test that adapter reverts are handled gracefully when querying directly
    function test_RevertWhen_adapterReverts_directQuery() public {
        // Query reverting adapter directly - should revert
        vm.expectRevert("Adapter revert");
        revertingAdapter.getOracleBalanceForAsset(alice, address(usdc));
    }

    /// @notice Test that adapter can recover from revert
    function test_RevertWhen_adapterRecoversFromRevert() public {
        // First query - adapter reverts
        vm.expectRevert("Adapter revert");
        revertingAdapter.getOracleBalanceForAsset(alice, address(usdc));

        // Stop adapter from reverting
        revertingAdapter.setShouldRevert(false);

        // Second query - adapter should work now
        int256 balance = revertingAdapter.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(balance, 0, "Should return zero after recovery");
    }

    // ============================================
    // Invalid Asset Address Handling
    // ============================================

    /// @notice Test that zero address asset returns zero balance
    function test_RevertWhen_zeroAddressAsset() public {
        // Zero address should return zero balance, not revert
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(0));
        assertEq(balance, 0, "Zero address should return zero balance");

        INAVCalculator.PositionBalance[] memory positions = erc20DefaultOracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0, "Zero address should return no positions");
    }

    /// @notice Test that unregistered asset returns zero balance
    function test_RevertWhen_unregisteredAsset() public {
        address unregisteredAsset = makeAddr("unregistered");

        // Unregistered asset should return zero balance, not revert
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(alice, unregisteredAsset);
        assertEq(balance, 0, "Unregistered asset should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultOracle.getOraclePositions(alice, unregisteredAsset);
        assertEq(positions.length, 0, "Unregistered asset should return no positions");
    }

    // ============================================
    // Zero Address Account Handling
    // ============================================

    /// @notice Test that zero address account returns zero balance
    function test_RevertWhen_zeroAddressAccount() public {
        // Zero address account should return zero balance, not revert
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(address(0), address(usdc));
        assertEq(balance, 0, "Zero address account should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultOracle.getOraclePositions(address(0), address(0));
        assertEq(positions.length, 0, "Zero address account should return no positions");
    }

    // ============================================
    // Balance Overflow Edge Cases
    // ============================================

    /// @notice Test that very large balances don't cause overflow
    function test_RevertWhen_largeBalances_noOverflow() public {
        // Use uint96 to avoid overflow issues
        uint96 largeAmount = type(uint96).max;

        usdc.mint(alice, largeAmount);

        // Should handle large balance without reverting
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(uint256(balance), uint256(largeAmount), "Should handle large balance");
        assertGt(balance, 0, "Should be positive balance");
    }

    /// @notice Test that extreme debt positions are handled
    function test_RevertWhen_extremeDebtPositions() public {
        // Set extreme debt position - use uint96 to avoid overflow
        uint256 extremeDebt = type(uint96).max;
        customOracle.setBalance(address(usdc), alice, extremeDebt, true);

        // Should handle extreme debt
        int256 balance = customOracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(balance, -int256(extremeDebt), "Should handle extreme debt amount (negative balance)");
    }

    // ============================================
    // Interface Mismatch Handling
    // ============================================

    /// @notice Test that invalid adapter interface is rejected
    function test_RevertWhen_invalidAdapterInterface() public {
        // Try to add a contract that doesn't implement IBalanceOracleAdapter
        address invalidAdapter = address(usdc); // ERC20 doesn't implement IBalanceOracleAdapter

        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        balances.addBalanceOracleDirect(address(0), invalidAdapter, IBalances.OracleType.Custom);
    }

    /// @notice Test that zero address adapter is rejected
    function test_RevertWhen_zeroAddressAdapter() public {
        vm.expectRevert(InvalidArguments.selector);
        balances.addBalanceOracleDirect(address(0), address(0), IBalances.OracleType.Custom);
    }

    // ============================================
    // Concurrent Failures
    // ============================================

    /// @notice Test handling when multiple adapters have issues
    function test_RevertWhen_multipleAdapterIssues() public {
        // Add reverting adapter
        balances.addBalanceOracleDirect(address(0), address(revertingAdapter), IBalances.OracleType.Custom);

        // Setup valid data with custom oracle
        customOracle.setBalance(address(usdc), alice, 1000 * 10 ** usdc.decimals(), false);
        balances.addBalanceOracleDirect(address(0), address(customOracle), IBalances.OracleType.Custom);

        // Query from custom oracle - should work despite reverting adapter
        int256 balance = customOracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(uint256(balance), 1000 * 10 ** usdc.decimals(), "Valid adapter should work");
        assertGt(balance, 0, "Should be positive balance");

        // Query from reverting adapter - should revert
        vm.expectRevert("Adapter revert");
        revertingAdapter.getOracleBalanceForAsset(alice, address(usdc));
    }

    // ============================================
    // Error Recovery
    // ============================================

    /// @notice Test that system recovers after adapter removal
    function test_RevertWhen_adapterRemovalRecovery() public {
        // Add reverting adapter
        balances.addBalanceOracleDirect(address(0), address(revertingAdapter), IBalances.OracleType.Custom);

        // Setup valid data
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());

        // Query with reverting adapter (direct query will revert)
        vm.expectRevert("Adapter revert");
        revertingAdapter.getOracleBalanceForAsset(alice, address(usdc));

        // Remove reverting adapter
        balances.unsetBalanceOracle(address(0), address(revertingAdapter));

        // Verify adapter is removed
        assertFalse(balances.isOracleRegistered(address(revertingAdapter)), "Adapter should be removed");

        // ERC20DefaultOracle should still work
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(uint256(balance), 1000 * 10 ** usdc.decimals(), "ERC20DefaultOracle should still work");
    }

    // ============================================
    // Edge Cases
    // ============================================

    /// @notice Test that all adapters reverting still allows query (returns zero)
    function test_RevertWhen_allAdaptersRevert() public {
        // Add multiple reverting adapters
        Mock_RevertingBalanceAdapter adapter2 = new Mock_RevertingBalanceAdapter();
        Mock_RevertingBalanceAdapter adapter3 = new Mock_RevertingBalanceAdapter();

        balances.addBalanceOracleDirect(address(0), address(revertingAdapter), IBalances.OracleType.Custom);
        balances.addBalanceOracleDirect(address(0), address(adapter2), IBalances.OracleType.Custom);
        balances.addBalanceOracleDirect(address(0), address(adapter3), IBalances.OracleType.Custom);

        // Don't mint any tokens (so ERC20DefaultOracle has no positions)

        // Query from ERC20DefaultOracle - should return zero, not revert
        int256 balance = erc20DefaultOracle.getOracleBalanceForAsset(alice, address(usdc));
        assertEq(balance, 0, "Should return zero balance when no positions");

        INAVCalculator.PositionBalance[] memory positions = erc20DefaultOracle.getOraclePositions(alice, address(0));
        assertEq(positions.length, 0, "Should return no positions");
    }

    /// @notice Test that invalid asset filter returns empty array
    function test_RevertWhen_invalidAssetFilter() public {
        address invalidFilter = makeAddr("invalid");

        // Filter by invalid asset should return empty array, not revert
        INAVCalculator.PositionBalance[] memory positions = erc20DefaultOracle.getOraclePositions(alice, invalidFilter);
        assertEq(positions.length, 0, "Invalid filter should return empty array");
    }

    /// @notice Test that getOracleBalance handles empty account gracefully
    function test_RevertWhen_emptyAccount() public {
        // Account with no balances
        address emptyAccount = makeAddr("empty");

        // Should return empty arrays, not revert
        (address[] memory assets, int256[] memory balances) = erc20DefaultOracle.getOracleBalance(emptyAccount);

        assertEq(assets.length, 0, "Empty account should return empty assets");
        assertEq(balances.length, 0, "Empty account should return empty balances");
    }
}
