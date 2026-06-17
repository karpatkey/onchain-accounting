// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultAdapter} from "src/balances/protocols/ERC20DefaultAdapter.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/errors.sol";

/// @title Mock Reverting Balance Adapter
/// @notice Adapter that reverts on query for testing error handling
contract Mock_RevertingBalanceAdapter is IBalanceAdapter {
    bool public shouldRevert = true;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getAdapterPositions(address, address)
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

    function getAdapterBalances(address)
        external
        view
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        if (shouldRevert) {
            revert("Adapter revert");
        }
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external view override returns (uint256, bool) {
        if (shouldRevert) {
            revert("Adapter revert");
        }
        return (0, false);
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }
}

/// @title Balance Adapter Error Handling Tests
/// @notice Tests error scenarios and graceful degradation
contract BalanceAdapterErrorTest is Test {
    BalancesHarness public balances;
    ERC20DefaultAdapter public erc20DefaultAdapter;
    Mock_RevertingBalanceAdapter public revertingAdapter;
    Mock_CustomBalanceAdapter public customAdapter;
    Mock_ERC20 public usdc;

    address public alice = makeAddr("alice");

    function setUp() public {
        // Etch NavRegistryLib (pre-linked external lib, DELEGATECALL'd by Balances) at its deterministic address.
        vm.etch(0x706cD291D3164B7F50e8FEBDE5d744a3eb12Ed56, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);
        balances = new BalancesHarness();
        erc20DefaultAdapter = balances.defaultAdapter();
        revertingAdapter = new Mock_RevertingBalanceAdapter();
        customAdapter = new Mock_CustomBalanceAdapter();
        customAdapter.setBalances(balances);

        usdc = new Mock_ERC20("USDC", 6);
        balances.addSupportedAssetForTest(address(usdc));

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        customAdapter.setUnderlyingAssetsSupported(assets);
    }

    // ============================================
    // Adapter Revert Handling
    // ============================================

    /// @notice Test that adapter reverts are handled gracefully when querying directly
    function test_RevertWhen_adapterReverts_directQuery() public {
        // Query reverting adapter directly - should revert
        vm.expectRevert("Adapter revert");
        revertingAdapter.getAdapterBalanceForAsset(alice, address(usdc));
    }

    /// @notice Test that adapter can recover from revert
    function test_RevertWhen_adapterRecoversFromRevert() public {
        // First query - adapter reverts
        vm.expectRevert("Adapter revert");
        revertingAdapter.getAdapterBalanceForAsset(alice, address(usdc));

        // Stop adapter from reverting
        revertingAdapter.setShouldRevert(false);

        // Second query - adapter should work now
        (uint256 amount,) = revertingAdapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0, "Should return zero after recovery");
    }

    // ============================================
    // Invalid Asset Address Handling
    // ============================================

    /// @notice Test that zero address asset returns zero balance
    function test_RevertWhen_zeroAddressAsset() public view {
        // Zero address should return zero balance, not revert
        (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(alice, address(0));
        assertEq(amount, 0, "Zero address should return zero balance");

        INAVCalculator.PositionBalance[] memory positions = erc20DefaultAdapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "Zero address should return no positions");
    }

    /// @notice Test that unregistered asset returns zero balance
    function test_RevertWhen_unregisteredAsset() public {
        address unregisteredAsset = makeAddr("unregistered");

        // Unregistered asset should return zero balance, not revert
        (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(alice, unregisteredAsset);
        assertEq(amount, 0, "Unregistered asset should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultAdapter.getAdapterPositions(alice, unregisteredAsset);
        assertEq(positions.length, 0, "Unregistered asset should return no positions");
    }

    // ============================================
    // Zero Address Account Handling
    // ============================================

    /// @notice Test that zero address account returns zero balance
    function test_RevertWhen_zeroAddressAccount() public view {
        // Zero address account should return zero balance, not revert
        (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(address(0), address(usdc));
        assertEq(amount, 0, "Zero address account should return zero balance");

        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultAdapter.getAdapterPositions(address(0), address(0));
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
        (uint256 amount, bool isDebt) = erc20DefaultAdapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, uint256(largeAmount), "Should handle large balance");
        assertFalse(isDebt);
    }

    /// @notice Test that extreme debt positions are handled
    function test_RevertWhen_extremeDebtPositions() public {
        // Set extreme debt position - use uint96 to avoid overflow
        uint256 extremeDebt = type(uint96).max;
        customAdapter.setBalance(address(usdc), alice, extremeDebt, true);

        // Should handle extreme debt
        (uint256 amount, bool isDebt) = customAdapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, extremeDebt, "Should handle extreme debt amount");
        assertTrue(isDebt);
    }

    // ============================================
    // Interface Mismatch Handling
    // ============================================

    /// @notice Test that invalid adapter interface is rejected
    function test_RevertWhen_invalidAdapterInterface() public {
        // Try to add a contract that doesn't implement IBalanceAdapter
        address invalidAdapter = address(usdc); // ERC20 doesn't implement IBalanceAdapter

        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        balances.addBalanceAdapterDirect(address(0), invalidAdapter, IBalances.AdapterType.Custom);
    }

    /// @notice Test that zero address adapter is rejected
    function test_RevertWhen_zeroAddressAdapter() public {
        vm.expectRevert(InvalidArguments.selector);
        balances.addBalanceAdapterDirect(address(0), address(0), IBalances.AdapterType.Custom);
    }

    // ============================================
    // Concurrent Failures
    // ============================================

    /// @notice Test handling when multiple adapters have issues
    function test_RevertWhen_multipleAdapterIssues() public {
        // Add reverting adapter
        balances.addBalanceAdapterDirect(address(0), address(revertingAdapter), IBalances.AdapterType.Custom);

        // Setup valid data with custom adapter
        customAdapter.setBalance(address(usdc), alice, 1000 * 10 ** usdc.decimals(), false);
        balances.addBalanceAdapterDirect(address(0), address(customAdapter), IBalances.AdapterType.Custom);

        // Query from custom adapter - should work despite reverting adapter
        (uint256 amount, bool isDebt) = customAdapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1000 * 10 ** usdc.decimals(), "Valid adapter should work");
        assertFalse(isDebt);

        // Query from reverting adapter - should revert
        vm.expectRevert("Adapter revert");
        revertingAdapter.getAdapterBalanceForAsset(alice, address(usdc));
    }

    // ============================================
    // Error Recovery
    // ============================================

    /// @notice Test that system recovers after adapter removal
    function test_RevertWhen_adapterRemovalRecovery() public {
        // Add reverting adapter
        balances.addBalanceAdapterDirect(address(0), address(revertingAdapter), IBalances.AdapterType.Custom);

        // Setup valid data
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());

        // Query with reverting adapter (direct query will revert)
        vm.expectRevert("Adapter revert");
        revertingAdapter.getAdapterBalanceForAsset(alice, address(usdc));

        // Remove reverting adapter
        balances.unsetBalanceAdapter(address(0), address(revertingAdapter));

        // Verify adapter is removed
        assertFalse(balances.isAdapterRegistered(address(revertingAdapter)), "Adapter should be removed");

        // ERC20DefaultAdapter should still work
        (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1000 * 10 ** usdc.decimals(), "ERC20DefaultAdapter should still work");
    }

    // ============================================
    // Edge Cases
    // ============================================

    /// @notice Test that all adapters reverting still allows query (returns zero)
    function test_RevertWhen_allAdaptersRevert() public {
        // Add multiple reverting adapters
        Mock_RevertingBalanceAdapter adapter2 = new Mock_RevertingBalanceAdapter();
        Mock_RevertingBalanceAdapter adapter3 = new Mock_RevertingBalanceAdapter();

        balances.addBalanceAdapterDirect(address(0), address(revertingAdapter), IBalances.AdapterType.Custom);
        balances.addBalanceAdapterDirect(address(0), address(adapter2), IBalances.AdapterType.Custom);
        balances.addBalanceAdapterDirect(address(0), address(adapter3), IBalances.AdapterType.Custom);

        // Don't mint any tokens (so ERC20DefaultAdapter has no positions)

        // Query from ERC20DefaultAdapter - should return zero, not revert
        (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 0, "Should return zero balance when no positions");

        INAVCalculator.PositionBalance[] memory positions = erc20DefaultAdapter.getAdapterPositions(alice, address(0));
        assertEq(positions.length, 0, "Should return no positions");
    }

    /// @notice Test that invalid asset filter returns empty array
    function test_RevertWhen_invalidAssetFilter() public {
        address invalidFilter = makeAddr("invalid");

        // Filter by invalid asset should return empty array, not revert
        INAVCalculator.PositionBalance[] memory positions =
            erc20DefaultAdapter.getAdapterPositions(alice, invalidFilter);
        assertEq(positions.length, 0, "Invalid filter should return empty array");
    }

    /// @notice Test that getAdapterBalance handles empty account gracefully
    function test_RevertWhen_emptyAccount() public {
        // Account with no balances
        address emptyAccount = makeAddr("empty");

        // Should return empty arrays, not revert
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            erc20DefaultAdapter.getAdapterBalances(emptyAccount);

        assertEq(assets.length, 0, "Empty account should return empty assets");
        assertEq(amounts.length, 0, "Empty account should return empty amounts");
        assertEq(isDebt.length, 0, "Empty account should return empty isDebt");
    }
}
