// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_CustomBalanceAdapter} from "test/mocks/balance_adapters.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultBalanceAdapter} from "src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Balance Adapter Handler for Stateful Invariant Testing
/// @notice Handler contract that manages stateful operations for invariant testing
contract BalanceAdapterHandler is Test {
    BalancesHarness public balances;
    ERC20DefaultBalanceAdapter public erc20DefaultBalanceAdapter;
    Mock_CustomBalanceAdapter[] public customAdapters;
    Mock_ERC20[] public tokens;

    // Actors for testing
    address[] public actors;
    address internal currentActor;

    // Ghost variables for tracking state
    uint256 public ghostTotalBalances;
    uint256 public ghostPositionCount;
    uint256 public ghostAdapterCount;

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor() {
        balances = new BalancesHarness();
        erc20DefaultBalanceAdapter = balances.defaultAdapter();

        // Initialize actors
        for (uint256 i = 0; i < 10; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }

        // Store initial state
        ghostAdapterCount = balances.getAdapterCount();
    }

    /// @notice Add a custom adapter
    function addAdapter(uint256 adapterSeed) external {
        // Create new adapter
        Mock_CustomBalanceAdapter adapter = new Mock_CustomBalanceAdapter();
        adapter.setBalances(balances);
        customAdapters.push(adapter);

        // Create token for this adapter
        uint8 decimals = uint8(bound(adapterSeed, 6, 18));
        Mock_ERC20 token =
            new Mock_ERC20(string(abi.encodePacked("TOKEN", vm.toString(customAdapters.length))), decimals);
        tokens.push(token);

        // Register asset
        balances.addSupportedAssetForTest(address(token));

        // Set supported assets
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        adapter.setUnderlyingAssetsSupported(assets);
        adapter.setPositionMetadata(
            string(abi.encodePacked("Protocol ", vm.toString(customAdapters.length))),
            string(abi.encodePacked("Position ", vm.toString(customAdapters.length)))
        );

        // Add adapter
        balances.addBalanceAdapterDirect(address(0), address(adapter), IBalances.AdapterType.Custom);
        ghostAdapterCount = balances.getAdapterCount();
    }

    /// @notice Remove a custom adapter
    function removeAdapter(uint256 adapterSeed) external {
        if (customAdapters.length == 0) return;

        uint256 adapterIndex = bound(adapterSeed, 0, customAdapters.length - 1);
        address adapter = address(customAdapters[adapterIndex]);

        // Cannot remove ERC20DefaultBalanceAdapter
        if (adapter == address(erc20DefaultBalanceAdapter)) {
            return;
        }

        balances.unsetBalanceAdapter(address(0), adapter);
        ghostAdapterCount = balances.getAdapterCount();
    }

    /// @notice Mint tokens to an actor
    function mintTokens(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) external useActor(actorSeed) {
        if (tokens.length == 0) return;

        uint256 tokenIndex = bound(tokenSeed, 0, tokens.length - 1);
        Mock_ERC20 token = tokens[tokenIndex];

        // Bound amount to avoid overflow
        uint256 maxAmount = 1_000_000 * 10 ** token.decimals();
        uint256 amount = bound(amountSeed, 1, maxAmount);

        token.mint(currentActor, amount);
    }

    /// @notice Set balance in custom adapter
    function setCustomBalance(
        uint256 actorSeed,
        uint256 adapterSeed,
        uint256 tokenSeed,
        uint256 amountSeed,
        bool isDebtSeed
    ) external useActor(actorSeed) {
        if (customAdapters.length == 0) return;
        if (tokens.length == 0) return;

        uint256 adapterIndex = bound(adapterSeed, 0, customAdapters.length - 1);
        uint256 tokenIndex = bound(tokenSeed, 0, tokens.length - 1);

        Mock_CustomBalanceAdapter adapter = customAdapters[adapterIndex];
        Mock_ERC20 token = tokens[tokenIndex];

        // Bound amount to reasonable range
        uint256 amount = bound(amountSeed, 1, type(uint96).max);
        bool isDebt = isDebtSeed;

        adapter.setBalance(address(token), currentActor, amount, isDebt);
    }

    /// @notice Query balance for an actor
    function queryBalance(uint256 actorSeed, uint256 adapterSeed, uint256 assetSeed)
        external
        view
        returns (int256 balance)
    {
        address account = actors[bound(actorSeed, 0, actors.length - 1)];

        address[] memory allAdapters = balances.getAllAdapters();
        if (allAdapters.length == 0) return 0;

        uint256 adapterIndex = bound(adapterSeed, 0, allAdapters.length - 1);
        IBalanceAdapter adapter = IBalanceAdapter(allAdapters[adapterIndex]);

        // Get supported assets
        address[] memory supportedAssets = adapter.underlyingAssetsSupported();
        if (supportedAssets.length == 0) return 0;

        uint256 assetIndex = bound(assetSeed, 0, supportedAssets.length - 1);
        address asset = supportedAssets[assetIndex];

        (uint256 amount, bool isDebt) = adapter.getAdapterBalanceForAsset(account, asset);
        balance = isDebt ? -SafeCast.toInt256(amount) : SafeCast.toInt256(amount);
    }

    /// @notice Get positions for an actor
    function getPositions(uint256 actorSeed, uint256 adapterSeed, uint256 filterSeed) external view returns (uint256) {
        address account = actors[bound(actorSeed, 0, actors.length - 1)];

        address[] memory allAdapters = balances.getAllAdapters();
        if (allAdapters.length == 0) return 0;

        uint256 adapterIndex = bound(adapterSeed, 0, allAdapters.length - 1);
        IBalanceAdapter adapter = IBalanceAdapter(allAdapters[adapterIndex]);

        // Get supported assets for filter
        address[] memory supportedAssets = adapter.underlyingAssetsSupported();
        address filter = address(0);
        if (supportedAssets.length > 0 && filterSeed % 2 == 0) {
            uint256 filterIndex = bound(filterSeed, 0, supportedAssets.length - 1);
            filter = supportedAssets[filterIndex];
        }

        INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(account, filter);
        return positions.length;
    }

    /// @notice Get actor at index, with bounds checking
    function getActor(uint256 index) external view returns (address) {
        if (actors.length == 0) return address(0);
        if (index >= actors.length) return actors[0];
        return actors[index];
    }

    /// @notice Get number of actors
    function getActorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @title Balance Adapter Handler-Based Invariant Tests
/// @notice Stateful invariant tests using handler contract
contract BalanceAdapterHandlerTest is Test {
    BalanceAdapterHandler public handler;

    function setUp() public {
        handler = new BalanceAdapterHandler();
        targetContract(address(handler));
    }

    // ============================================
    // Invariant Functions
    // ============================================

    /// @notice Invariant: Balance consistency across queries
    function invariant_balanceConsistency() external view {
        // Test with a few actors and adapters
        address[] memory allAdapters = handler.balances().getAllAdapters();
        if (allAdapters.length == 0) return;

        uint256 actorCount = handler.getActorCount();
        if (actorCount == 0) return;

        uint256 maxActors = actorCount < 3 ? actorCount : 3;
        for (uint256 i = 0; i < maxActors; i++) {
            address account = handler.getActor(i);
            if (account == address(0)) continue;

            for (uint256 j = 0; j < allAdapters.length && j < 3; j++) {
                IBalanceAdapter adapter = IBalanceAdapter(allAdapters[j]);

                // Get balance via getAdapterBalances - use try-catch to handle potential reverts
                try adapter.getAdapterBalances(account) returns (
                    address[] memory, /* assets */ uint256[] memory amounts, bool[] memory isDebt
                ) {
                    // Get positions
                    INAVCalculator.PositionBalance[] memory positions = adapter.getAdapterPositions(account, address(0));

                    // Sum positions
                    int256 positionsSum = 0;
                    for (uint256 k = 0; k < positions.length; k++) {
                        if (positions[k].isDebt) {
                            positionsSum -= int256(positions[k].amount);
                        } else {
                            positionsSum += int256(positions[k].amount);
                        }
                    }

                    // Sum balances (amount + isDebt)
                    int256 balanceSum = 0;
                    for (uint256 k = 0; k < amounts.length; k++) {
                        if (isDebt[k]) {
                            balanceSum -= int256(amounts[k]);
                        } else {
                            balanceSum += int256(amounts[k]);
                        }
                    }

                    // Should match (allow small rounding differences)
                    assertApproxEqAbs(positionsSum, balanceSum, 1, "Sum of positions should equal sum of balances");
                } catch {
                    // If adapter reverts, skip this combination
                    continue;
                }
            }
        }
    }

    /// @notice Invariant: No zero positions in results
    function invariant_noZeroPositions() external view {
        address[] memory allAdapters = handler.balances().getAllAdapters();
        if (allAdapters.length == 0) return;

        uint256 actorCount = handler.getActorCount();
        if (actorCount == 0) return;

        uint256 maxActors = actorCount < 3 ? actorCount : 3;
        for (uint256 i = 0; i < maxActors; i++) {
            address account = handler.getActor(i);
            if (account == address(0)) continue;

            for (uint256 j = 0; j < allAdapters.length && j < 3; j++) {
                IBalanceAdapter adapter = IBalanceAdapter(allAdapters[j]);
                try adapter.getAdapterPositions(account, address(0)) returns (
                    INAVCalculator.PositionBalance[] memory positions
                ) {
                    for (uint256 k = 0; k < positions.length; k++) {
                        assertTrue(positions[k].amount != 0, "No zero positions should be returned");
                    }
                } catch {
                    // If adapter reverts, skip this combination
                    continue;
                }
            }
        }
    }

    /// @notice Invariant: Asset filtering works correctly
    function invariant_assetFiltering() external view {
        address[] memory allAdapters = handler.balances().getAllAdapters();
        if (allAdapters.length == 0) return;

        uint256 actorCount = handler.getActorCount();
        if (actorCount == 0) return;

        uint256 maxActors = actorCount < 3 ? actorCount : 3;
        for (uint256 i = 0; i < maxActors; i++) {
            address account = handler.getActor(i);
            if (account == address(0)) continue;

            for (uint256 j = 0; j < allAdapters.length && j < 3; j++) {
                IBalanceAdapter adapter = IBalanceAdapter(allAdapters[j]);

                // Get supported assets - all registered adapters must support this function
                address[] memory supportedAssets;
                try adapter.underlyingAssetsSupported() returns (address[] memory assets) {
                    supportedAssets = assets;
                } catch {
                    revert("Registered adapter must support underlyingAssetsSupported()");
                }

                if (supportedAssets.length == 0) continue;

                // Get all positions
                INAVCalculator.PositionBalance[] memory allPositions;
                try adapter.getAdapterPositions(account, address(0)) returns (
                    INAVCalculator.PositionBalance[] memory positions
                ) {
                    allPositions = positions;
                } catch {
                    continue;
                }

                // Filter by each supported asset. The per-filter check lives in a helper so its locals do not
                // share this function's stack frame — the fully-inlined four-loop body otherwise exceeds the
                // via-IR stack limit.
                uint256 maxAssets = supportedAssets.length < 3 ? supportedAssets.length : 3;
                for (uint256 k = 0; k < maxAssets; k++) {
                    _assertFilterIsSubset(adapter, account, supportedAssets[k], allPositions.length);
                }
            }
        }
    }

    /// @notice Asserts that filtering an adapter's positions by a single asset yields only matching positions and
    ///         a subset of the unfiltered set. Extracted from `invariant_assetFiltering` for via-IR stack relief.
    function _assertFilterIsSubset(IBalanceAdapter adapter, address account, address filter, uint256 unfilteredCount)
        private
        view
    {
        INAVCalculator.PositionBalance[] memory filteredPositions;
        try adapter.getAdapterPositions(account, filter) returns (INAVCalculator.PositionBalance[] memory positions) {
            filteredPositions = positions;
        } catch {
            return;
        }

        // All filtered positions should match filter
        for (uint256 l = 0; l < filteredPositions.length; l++) {
            assertEq(filteredPositions[l].balanceAsset.asset, filter, "Filtered positions should match filter");
        }

        // Filtered should be subset of all
        assertLe(filteredPositions.length, unfilteredCount, "Filtered should be subset");
    }

    /// @notice Invariant: Interface compliance
    function invariant_interfaceCompliance() external view {
        address[] memory allAdapters = handler.balances().getAllAdapters();
        if (allAdapters.length == 0) return;

        for (uint256 i = 0; i < allAdapters.length; i++) {
            IBalanceAdapter adapter = IBalanceAdapter(allAdapters[i]);

            // Verify supportsInterface - all registered adapters must support the interface
            bool supported;
            try adapter.supportsInterface(type(IBalanceAdapter).interfaceId) returns (bool result) {
                supported = result;
            } catch {
                revert("Registered adapter must support IBalanceAdapter interface");
            }
            assertTrue(supported, "Adapter should support IBalanceAdapter");

            // Verify required functions don't revert - all registered adapters must be properly initialized
            try adapter.underlyingAssetsSupported() returns (
                address[] memory
            ) {
            // Success - adapter is properly initialized
            }
            catch {
                revert("Registered adapter must be properly initialized and support underlyingAssetsSupported()");
            }
        }
    }

    /// @notice Invariant: Supported assets consistency
    function invariant_supportedAssetsConsistency() external view {
        address[] memory allAdapters = handler.balances().getAllAdapters();
        if (allAdapters.length == 0) return;

        for (uint256 i = 0; i < allAdapters.length; i++) {
            IBalanceAdapter adapter = IBalanceAdapter(allAdapters[i]);

            // Query multiple times - should be consistent
            // All registered adapters must support underlyingAssetsSupported()
            address[] memory assets1;
            try adapter.underlyingAssetsSupported() returns (address[] memory assets) {
                assets1 = assets;
            } catch {
                revert("Registered adapter must support underlyingAssetsSupported()");
            }

            address[] memory assets2;
            try adapter.underlyingAssetsSupported() returns (address[] memory assets) {
                assets2 = assets;
            } catch {
                revert("Registered adapter must support underlyingAssetsSupported() consistently");
            }

            assertEq(assets1.length, assets2.length, "Supported assets should be consistent");

            // All supported assets should be queryable
            uint256 actorCount = handler.getActorCount();
            if (actorCount == 0) continue;

            address testAccount = handler.getActor(0);
            if (testAccount == address(0)) continue;

            for (uint256 j = 0; j < assets1.length; j++) {
                address asset = assets1[j];

                // Should be able to query balance (may be zero, that's fine)
                // All supported assets must be queryable
                try adapter.getAdapterBalanceForAsset(testAccount, asset) returns (
                    uint256, bool
                ) {
                // Success
                }
                catch {
                    revert("Registered adapter must be able to query balance for all supported assets");
                }
            }
        }
    }

    /// @notice Invariant: ERC20DefaultBalanceAdapter always registered
    function invariant_erc20DefaultBalanceAdapterAlwaysRegistered() external view {
        address[] memory allAdapters = handler.balances().getAllAdapters();

        bool found = false;
        for (uint256 i = 0; i < allAdapters.length; i++) {
            if (allAdapters[i] == address(handler.erc20DefaultBalanceAdapter())) {
                found = true;
                break;
            }
        }

        assertTrue(found, "ERC20DefaultBalanceAdapter should always be registered");
    }

    /// @notice Invariant: Adapter count consistency
    function invariant_adapterCountConsistency() external view {
        uint256 adapterCount = handler.balances().getAdapterCount();
        address[] memory allAdapters = handler.balances().getAllAdapters();

        assertEq(adapterCount, allAdapters.length, "Adapter count should match registry length");
    }
}
