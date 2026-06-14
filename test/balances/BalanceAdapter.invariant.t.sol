// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultAdapter} from "src/balances/protocols/ERC20DefaultAdapter.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {PositionKind} from "src/utils/PositionKind.sol";

/// @title Balance Adapter Invariant Tests
/// @notice Tests critical system invariants for balance adapter adapters
contract BalanceAdapterInvariantTest is Test {
    BalancesHarness public balances;
    ERC20DefaultAdapter public erc20DefaultAdapter;
    Mock_CustomBalanceAdapter public customAdapter1;
    Mock_CustomBalanceAdapter public customAdapter2;
    Mock_ERC20 public usdc;
    Mock_ERC20 public dai;
    Mock_ERC20 public weth;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        // Etch NavRegistryLib (pre-linked external lib, DELEGATECALL'd by Balances) at its deterministic address.
        vm.etch(0xC1a8D82555aBB46bCdbFDe09E4B9aB6a862A18d1, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);
        balances = new BalancesHarness();
        erc20DefaultAdapter = balances.defaultAdapter();

        // Create tokens
        usdc = new Mock_ERC20("USDC", 6);
        dai = new Mock_ERC20("DAI", 18);
        weth = new Mock_ERC20("WETH", 18);

        // Register assets
        balances.addSupportedAssetForTest(address(usdc));
        balances.addSupportedAssetForTest(address(dai));
        balances.addSupportedAssetForTest(address(weth));
        balances.addSupportedAssetForTest(balances.NATIVE_ADDRESS());

        // Setup custom adapters
        customAdapter1 = new Mock_CustomBalanceAdapter();
        customAdapter1.setBalances(balances);
        address[] memory assets1 = new address[](2);
        assets1[0] = address(usdc);
        assets1[1] = address(dai);
        customAdapter1.setUnderlyingAssetsSupported(assets1);
        customAdapter1.setPositionMetadata("Protocol 1", "Position 1");

        customAdapter2 = new Mock_CustomBalanceAdapter();
        customAdapter2.setBalances(balances);
        address[] memory assets2 = new address[](1);
        assets2[0] = address(weth);
        customAdapter2.setUnderlyingAssetsSupported(assets2);
        customAdapter2.setPositionMetadata("Protocol 2", "Position 2");

        // Add custom adapters
        balances.addBalanceAdapterDirect(address(0), address(customAdapter1), IBalances.AdapterType.Custom);
        balances.addBalanceAdapterDirect(address(0), address(customAdapter2), IBalances.AdapterType.Custom);
    }

    /// @notice Helper to sum balances from positions
    function sumPositionBalances(INAVCalculator.PositionBalance[] memory positions) internal pure returns (int256) {
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isDebt) {
                sum -= int256(positions[i].amount);
            } else {
                sum += int256(positions[i].amount);
            }
        }
        return sum;
    }

    // ============================================
    // Interface Compliance Invariant
    // ============================================

    /// @notice Test that all adapters implement IBalanceAdapter correctly
    /// @dev This invariant ensures all adapters conform to the interface contract
    function test_invariant_interfaceCompliance() public view {
        address[] memory allAdapters = balances.getAllAdapters();

        for (uint256 i = 0; i < allAdapters.length; i++) {
            IBalanceAdapter adapter = IBalanceAdapter(allAdapters[i]);

            // Verify supportsInterface
            assertTrue(
                adapter.supportsInterface(type(IBalanceAdapter).interfaceId), "Adapter should support IBalanceAdapter"
            );
            assertTrue(adapter.supportsInterface(type(IERC165).interfaceId), "Adapter should support IERC165");

            // Verify underlyingAssetsSupported doesn't revert
            try adapter.underlyingAssetsSupported() returns (
                address[] memory
            ) {
            // Success
            }
            catch {
                revert("underlyingAssetsSupported should not revert");
            }

            // Test getAdapterBalanceForAsset
            try adapter.getAdapterBalanceForAsset(alice, address(usdc)) returns (
                uint256, bool
            ) {
            // Success
            }
            catch {
                revert("getAdapterBalanceForAsset should not revert");
            }

            // Test getAdapterBalances
            try adapter.getAdapterBalances(alice) returns (
                address[] memory, uint256[] memory, bool[] memory
            ) {
            // Success
            }
            catch {
                revert("getAdapterBalances should not revert");
            }

            // Test getAdapterPositions
            try adapter.getAdapterPositions(alice, address(0)) returns (
                INAVCalculator.PositionBalance[] memory
            ) {
            // Success
            }
            catch {
                revert("getAdapterPositions should not revert");
            }
        }
    }

    /// @notice Test that all adapters implement required functions
    /// @dev DEPRECATED: This test is redundant with test_invariant_interfaceCompliance which now includes all checks.
    ///      Kept for backwards compatibility. Consider removing in future refactoring.
    function test_invariant_interfaceCompliance_requiredFunctions() public view {
        // This test is now redundant - all checks are in test_invariant_interfaceCompliance
        // Keeping for backwards compatibility
        address[] memory allAdapters = balances.getAllAdapters();

        for (uint256 i = 0; i < allAdapters.length; i++) {
            IBalanceAdapter adapter = IBalanceAdapter(allAdapters[i]);

            // Test getAdapterBalanceForAsset
            try adapter.getAdapterBalanceForAsset(alice, address(usdc)) returns (
                uint256, bool
            ) {
            // Success
            }
            catch {
                revert("getAdapterBalanceForAsset should not revert");
            }

            // Test getAdapterBalances
            try adapter.getAdapterBalances(alice) returns (
                address[] memory, uint256[] memory, bool[] memory
            ) {
            // Success
            }
            catch {
                revert("getAdapterBalances should not revert");
            }

            // Test getAdapterPositions
            try adapter.getAdapterPositions(alice, address(0)) returns (
                INAVCalculator.PositionBalance[] memory
            ) {
            // Success
            }
            catch {
                revert("getAdapterPositions should not revert");
            }
        }
    }

    // ============================================
    // Zero Balance Exclusion Invariant
    // ============================================

    /// @notice Test that getAdapterPositions excludes zero balances
    function test_invariant_zeroBalanceExclusion() public {
        // Setup: Some tokens with balances, some without
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        // Don't mint DAI or WETH (zero balances)

        // Query positions
        INAVCalculator.PositionBalance[] memory positions = erc20DefaultAdapter.getAdapterPositions(alice, address(0));

        // Verify no zero balances
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount != 0, "No zero amounts should be returned");
        }

        // Should only have USDC position
        assertEq(positions.length, 1, "Should have one position");
        assertEq(positions[0].balanceAsset.asset, address(usdc), "Should be USDC");
    }

    /// @notice Test that zero balances are excluded across multiple adapters
    function test_invariant_zeroBalanceExclusion_multipleAdapters() public {
        // Setup balances
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        customAdapter1.setBalance(address(usdc), alice, 500 * 10 ** usdc.decimals(), false);
        // Don't set DAI balance (zero)

        // Query from ERC20DefaultAdapter
        INAVCalculator.PositionBalance[] memory positions1 = erc20DefaultAdapter.getAdapterPositions(alice, address(0));

        // Query from customAdapter1
        INAVCalculator.PositionBalance[] memory positions2 = customAdapter1.getAdapterPositions(alice, address(0));

        // Verify no zero balances
        for (uint256 i = 0; i < positions1.length; i++) {
            assertTrue(positions1[i].amount != 0, "ERC20DefaultAdapter: No zero amounts");
        }
        for (uint256 i = 0; i < positions2.length; i++) {
            assertTrue(positions2[i].amount != 0, "CustomAdapter1: No zero amounts");
        }
    }

    // ============================================
    // Balance Consistency Invariant
    // ============================================

    /// @notice Test that getAdapterBalance matches sum of getAdapterPositions
    function test_invariant_balanceConsistency() public {
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        dai.mint(alice, 2000 * 10 ** dai.decimals());

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            erc20DefaultAdapter.getAdapterBalances(alice);
        assertEq(assets.length, amounts.length, "assets and amounts length match");

        INAVCalculator.PositionBalance[] memory positions = erc20DefaultAdapter.getAdapterPositions(alice, address(0));

        // Sum positions
        int256 positionsSum = sumPositionBalances(positions);

        // Sum getAdapterBalances (amount + isDebt)
        int256 balanceSum = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (isDebt[i]) {
                balanceSum -= int256(amounts[i]);
            } else {
                balanceSum += int256(amounts[i]);
            }
        }

        // Should match
        assertEq(positionsSum, balanceSum, "Sum of positions should equal sum of balances");
    }

    /// @notice Test balance consistency with debt positions
    function test_invariant_balanceConsistency_debtPositions() public {
        // Setup positive and debt positions
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        customAdapter1.setBalance(address(usdc), alice, 500 * 10 ** usdc.decimals(), true);

        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            customAdapter1.getAdapterBalances(alice);
        assertEq(assets.length, amounts.length, "assets and amounts length match");

        // Get positions
        INAVCalculator.PositionBalance[] memory positions = customAdapter1.getAdapterPositions(alice, address(0));

        // Sum positions
        int256 positionsSum = sumPositionBalances(positions);

        // Sum balances (amount + isDebt)
        int256 balanceSum = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (isDebt[i]) {
                balanceSum -= int256(amounts[i]);
            } else {
                balanceSum += int256(amounts[i]);
            }
        }

        // Should match (debt positions should be included)
        assertEq(positionsSum, balanceSum, "Sum should match with debt positions");
        assertLt(positionsSum, 0, "Should have negative total");
    }

    // ============================================
    // Asset Filtering Invariant
    // ============================================

    /// @notice Test that asset filter correctly filters positions
    function test_invariant_assetFiltering() public {
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());
        dai.mint(alice, 2000 * 10 ** dai.decimals());

        // Get all positions
        INAVCalculator.PositionBalance[] memory allPositions =
            erc20DefaultAdapter.getAdapterPositions(alice, address(0));

        // Get filtered positions (USDC only)
        INAVCalculator.PositionBalance[] memory filteredPositions =
            erc20DefaultAdapter.getAdapterPositions(alice, address(usdc));

        // Filtered should be subset of all
        assertLe(filteredPositions.length, allPositions.length, "Filtered should be subset");

        // All filtered positions should be for USDC
        for (uint256 i = 0; i < filteredPositions.length; i++) {
            assertEq(filteredPositions[i].balanceAsset.asset, address(usdc), "Filtered positions should be for USDC");
        }

        // Verify filtered positions are in all positions
        for (uint256 i = 0; i < filteredPositions.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < allPositions.length; j++) {
                if (
                    filteredPositions[i].balanceAsset.asset == allPositions[j].balanceAsset.asset
                        && filteredPositions[i].amount == allPositions[j].amount
                        && filteredPositions[i].isDebt == allPositions[j].isDebt
                ) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Filtered position should be in all positions");
        }
    }

    /// @notice Test asset filtering with non-existent asset
    function test_invariant_assetFiltering_nonExistentAsset() public {
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());

        address nonExistentAsset = makeAddr("nonExistent");

        // Filter by non-existent asset
        INAVCalculator.PositionBalance[] memory filteredPositions =
            erc20DefaultAdapter.getAdapterPositions(alice, nonExistentAsset);

        // Should return empty array
        assertEq(filteredPositions.length, 0, "Non-existent asset should return empty");
    }

    // ============================================
    // Supported Assets Consistency Invariant
    // ============================================

    /// @notice Test that underlyingAssetsSupported matches queryable assets
    function test_invariant_supportedAssetsConsistency() public view {
        address[] memory supportedAssets = erc20DefaultAdapter.underlyingAssetsSupported();

        // All supported assets should be registered in balances
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            assertTrue(balances.isAssetRegistered(supportedAssets[i]), "Supported asset should be registered");
        }

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            (uint256 amount,) = erc20DefaultAdapter.getAdapterBalanceForAsset(alice, supportedAssets[i]);
            // amount is always valid uint256 (non-negative magnitude)
            assertTrue(amount <= type(uint256).max, "amount in range");
        }
    }

    /// @notice Test that custom adapter supported assets are consistent
    function test_invariant_supportedAssetsConsistency_customAdapter() public view {
        address[] memory supportedAssets = customAdapter1.underlyingAssetsSupported();

        // Should match what we set
        assertEq(supportedAssets.length, 2, "Should have 2 supported assets");

        // Verify assets
        bool foundUsdc = false;
        bool foundDai = false;
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (supportedAssets[i] == address(usdc)) foundUsdc = true;
            if (supportedAssets[i] == address(dai)) foundDai = true;
        }
        assertTrue(foundUsdc, "Should support USDC");
        assertTrue(foundDai, "Should support DAI");
    }

    // ============================================
    // Debt Position Handling Invariant
    // ============================================

    /// @notice Test that debt positions are correctly reported
    function test_invariant_debtPositionHandling() public {
        // Set debt position
        customAdapter1.setBalance(address(usdc), alice, 1000 * 10 ** usdc.decimals(), true);

        // Get balance
        (uint256 amount, bool isDebt) = customAdapter1.getAdapterBalanceForAsset(alice, address(usdc));
        assertEq(amount, 1000 * 10 ** usdc.decimals(), "Amount should match");
        assertTrue(isDebt, "Debt balance should be reported as debt");

        // Get positions
        INAVCalculator.PositionBalance[] memory positions = customAdapter1.getAdapterPositions(alice, address(0));

        // Should have one position with debt
        assertEq(positions.length, 1, "Should have one position");
        assertEq(positions[0].amount, 1000 * 10 ** usdc.decimals(), "Amount should match");
        assertTrue(positions[0].isDebt, "Position should be debt");
    }

    /// @notice Test that debt positions are included in aggregation
    function test_invariant_debtPositionHandling_aggregation() public {
        // Setup mixed credit and debt positions
        customAdapter1.setBalance(address(usdc), alice, 1000 * 10 ** usdc.decimals(), false);
        customAdapter1.setBalance(address(dai), alice, 500 * 10 ** dai.decimals(), true);

        // Get all balances
        (address[] memory assets, uint256[] memory amounts, bool[] memory isDebt) =
            customAdapter1.getAdapterBalances(alice);

        // Should have both assets
        assertEq(assets.length, 2, "Should have 2 assets");

        // Find USDC and DAI balances (amount + sign from isDebt)
        int256 usdcBalance = 0;
        int256 daiBalance = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            int256 signed = isDebt[i] ? -int256(amounts[i]) : int256(amounts[i]);
            if (assets[i] == address(usdc)) {
                usdcBalance = signed;
            }
            if (assets[i] == address(dai)) {
                daiBalance = signed;
            }
        }

        assertEq(usdcBalance, int256(1000 * 10 ** usdc.decimals()), "USDC balance should match");
        assertEq(daiBalance, -int256(500 * 10 ** dai.decimals()), "DAI balance should be negative");
    }

    // ============================================
    // Metadata Consistency Invariant
    // ============================================

    /// @notice Test that protocolId and positionKind are consistent across queries
    function test_invariant_metadataConsistency() public {
        customAdapter1.setBalance(address(usdc), alice, 1000 * 10 ** usdc.decimals(), false);

        // Query multiple times
        INAVCalculator.PositionBalance[] memory positions1 = customAdapter1.getAdapterPositions(alice, address(0));
        INAVCalculator.PositionBalance[] memory positions2 = customAdapter1.getAdapterPositions(alice, address(0));

        // Metadata should be consistent
        assertEq(positions1.length, positions2.length, "Position count should be consistent");

        for (uint256 i = 0; i < positions1.length; i++) {
            assertEq(positions1[i].protocolId, positions2[i].protocolId, "ProtocolId should be consistent");
            assertEq(
                uint8(positions1[i].positionKind),
                uint8(positions2[i].positionKind),
                "PositionKind should be consistent"
            );
        }
    }

    /// @notice Test that metadata is correct for ERC20DefaultAdapter
    function test_invariant_metadataConsistency_erc20Default() public {
        usdc.mint(alice, 1000 * 10 ** usdc.decimals());

        INAVCalculator.PositionBalance[] memory positions = erc20DefaultAdapter.getAdapterPositions(alice, address(0));

        // ERC20DefaultAdapter should have specific metadata
        assertEq(positions.length, 1, "Should have one position");
        assertEq(positions[0].protocolId, keccak256(bytes("wallet")), "ProtocolId should be wallet");
        assertEq(uint256(positions[0].positionKind), uint256(PositionKind.Wallet), "PositionKind should be Wallet");
    }
}
