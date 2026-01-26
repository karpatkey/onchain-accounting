// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {BalancesHarness} from "test/balances/Balances.t.sol";
import {Mock_CustomBalanceOracle} from "test/mocks/balance_oracles.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {ERC20DefaultOracle} from "src/balances/protocols/ERC20DefaultOracle.sol";

/// @title Balance Adapter Handler for Stateful Invariant Testing
/// @notice Handler contract that manages stateful operations for invariant testing
contract BalanceAdapterHandler is Test {
    BalancesHarness public balances;
    ERC20DefaultOracle public erc20DefaultOracle;
    Mock_CustomBalanceOracle[] public customOracles;
    Mock_ERC20[] public tokens;
    
    // Actors for testing
    address[] public actors;
    address internal currentActor;
    
    // Ghost variables for tracking state
    uint256 public ghost_totalBalances;
    uint256 public ghost_positionCount;
    uint256 public ghost_adapterCount;
    
    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }
    
    constructor() {
        balances = new BalancesHarness();
        erc20DefaultOracle = balances.defaultOracle();
        
        // Initialize actors
        for (uint256 i = 0; i < 10; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
        
        // Store initial state
        ghost_adapterCount = balances.getOracleCount();
    }
    
    /// @notice Add a custom oracle
    function addAdapter(uint256 oracleSeed) external {
        // Create new oracle
        Mock_CustomBalanceOracle oracle = new Mock_CustomBalanceOracle();
        oracle.setBalances(balances);
        customOracles.push(oracle);
        
        // Create token for this oracle
        uint8 decimals = uint8(bound(oracleSeed, 6, 18));
        Mock_ERC20 token = new Mock_ERC20(string(abi.encodePacked("TOKEN", vm.toString(customOracles.length))), decimals);
        tokens.push(token);
        
        // Register asset
        balances.registerAssetForTest(address(token), decimals);
        
        // Set supported assets
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        oracle.setUnderlyingAssetsSupported(assets);
        oracle.setPositionMetadata(
            string(abi.encodePacked("Protocol ", vm.toString(customOracles.length))),
            string(abi.encodePacked("Position ", vm.toString(customOracles.length)))
        );
        
        // Add oracle
        balances.addBalanceOracleDirect(address(0), address(oracle), IBalances.OracleType.Custom);
        ghost_adapterCount = balances.getOracleCount();
    }
    
    /// @notice Remove a custom oracle
    function removeAdapter(uint256 oracleSeed) external {
        if (customOracles.length == 0) return;
        
        uint256 oracleIndex = bound(oracleSeed, 0, customOracles.length - 1);
        address oracle = address(customOracles[oracleIndex]);
        
        // Cannot remove ERC20DefaultOracle
        if (oracle == address(erc20DefaultOracle)) {
            return;
        }
        
        balances.unsetBalanceOracle(address(0), oracle);
        ghost_adapterCount = balances.getOracleCount();
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
    
    /// @notice Set balance in custom oracle
    function setCustomBalance(uint256 actorSeed, uint256 oracleSeed, uint256 tokenSeed, uint256 amountSeed, bool isDebtSeed) external useActor(actorSeed) {
        if (customOracles.length == 0) return;
        if (tokens.length == 0) return;
        
        uint256 oracleIndex = bound(oracleSeed, 0, customOracles.length - 1);
        uint256 tokenIndex = bound(tokenSeed, 0, tokens.length - 1);
        
        Mock_CustomBalanceOracle oracle = customOracles[oracleIndex];
        Mock_ERC20 token = tokens[tokenIndex];
        
        // Bound amount to reasonable range
        uint256 amount = bound(amountSeed, 1, type(uint96).max);
        bool isDebt = isDebtSeed;
        
        oracle.setBalance(address(token), currentActor, amount, isDebt);
    }
    
    /// @notice Query balance for an actor
    function queryBalance(uint256 actorSeed, uint256 adapterSeed, uint256 assetSeed) external view returns (int256 balance) {
        address account = actors[bound(actorSeed, 0, actors.length - 1)];
        
        address[] memory allOracles = balances.getAllOracles();
        if (allOracles.length == 0) return 0;
        
        uint256 adapterIndex = bound(adapterSeed, 0, allOracles.length - 1);
        IBalanceOracleAdapter adapter = IBalanceOracleAdapter(allOracles[adapterIndex]);
        
        // Get supported assets
        address[] memory supportedAssets = adapter.underlyingAssetsSupported();
        if (supportedAssets.length == 0) return 0;
        
        uint256 assetIndex = bound(assetSeed, 0, supportedAssets.length - 1);
        address asset = supportedAssets[assetIndex];
        
        balance = adapter.getOracleBalanceForAsset(account, asset);
    }
    
    /// @notice Get positions for an actor
    function getPositions(uint256 actorSeed, uint256 adapterSeed, uint256 filterSeed) external view returns (uint256) {
        address account = actors[bound(actorSeed, 0, actors.length - 1)];
        
        address[] memory allOracles = balances.getAllOracles();
        if (allOracles.length == 0) return 0;
        
        uint256 adapterIndex = bound(adapterSeed, 0, allOracles.length - 1);
        IBalanceOracleAdapter adapter = IBalanceOracleAdapter(allOracles[adapterIndex]);
        
        // Get supported assets for filter
        address[] memory supportedAssets = adapter.underlyingAssetsSupported();
        address filter = address(0);
        if (supportedAssets.length > 0 && filterSeed % 2 == 0) {
            uint256 filterIndex = bound(filterSeed, 0, supportedAssets.length - 1);
            filter = supportedAssets[filterIndex];
        }
        
        INAVCalculator.PositionBalance[] memory positions = adapter.getOraclePositions(account, filter);
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
        address[] memory allOracles = handler.balances().getAllOracles();
        if (allOracles.length == 0) return;
        
        uint256 actorCount = handler.getActorCount();
        if (actorCount == 0) return;
        
        uint256 maxActors = actorCount < 3 ? actorCount : 3;
        for (uint256 i = 0; i < maxActors; i++) {
            address account = handler.getActor(i);
            if (account == address(0)) continue;
            
            for (uint256 j = 0; j < allOracles.length && j < 3; j++) {
                IBalanceOracleAdapter adapter = IBalanceOracleAdapter(allOracles[j]);
                
                // Get balance via getOracleBalance - use try-catch to handle potential reverts
                try adapter.getOracleBalance(account) returns (address[] memory assets, int256[] memory balances) {
                    // Get positions
                    INAVCalculator.PositionBalance[] memory positions = adapter.getOraclePositions(account, address(0));
                    
                    // Sum positions
                    int256 positionsSum = 0;
                    for (uint256 k = 0; k < positions.length; k++) {
                        if (positions[k].isDebt) {
                            positionsSum -= int256(positions[k].amount);
                        } else {
                            positionsSum += int256(positions[k].amount);
                        }
                    }
                    
                    // Sum balances (already signed)
                    int256 balanceSum = 0;
                    for (uint256 k = 0; k < balances.length; k++) {
                        balanceSum += balances[k];
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
        address[] memory allOracles = handler.balances().getAllOracles();
        if (allOracles.length == 0) return;
        
        uint256 actorCount = handler.getActorCount();
        if (actorCount == 0) return;
        
        uint256 maxActors = actorCount < 3 ? actorCount : 3;
        for (uint256 i = 0; i < maxActors; i++) {
            address account = handler.getActor(i);
            if (account == address(0)) continue;
            
            for (uint256 j = 0; j < allOracles.length && j < 3; j++) {
                IBalanceOracleAdapter adapter = IBalanceOracleAdapter(allOracles[j]);
                try adapter.getOraclePositions(account, address(0)) returns (INAVCalculator.PositionBalance[] memory positions) {
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
        address[] memory allOracles = handler.balances().getAllOracles();
        if (allOracles.length == 0) return;
        
        uint256 actorCount = handler.getActorCount();
        if (actorCount == 0) return;
        
        uint256 maxActors = actorCount < 3 ? actorCount : 3;
        for (uint256 i = 0; i < maxActors; i++) {
            address account = handler.getActor(i);
            if (account == address(0)) continue;
            
            for (uint256 j = 0; j < allOracles.length && j < 3; j++) {
                IBalanceOracleAdapter adapter = IBalanceOracleAdapter(allOracles[j]);
                
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
                try adapter.getOraclePositions(account, address(0)) returns (INAVCalculator.PositionBalance[] memory positions) {
                    allPositions = positions;
                } catch {
                    continue;
                }
                
                // Filter by each supported asset
                uint256 maxAssets = supportedAssets.length < 3 ? supportedAssets.length : 3;
                for (uint256 k = 0; k < maxAssets; k++) {
                    address filter = supportedAssets[k];
                    INAVCalculator.PositionBalance[] memory filteredPositions;
                    try adapter.getOraclePositions(account, filter) returns (INAVCalculator.PositionBalance[] memory positions) {
                        filteredPositions = positions;
                    } catch {
                        continue;
                    }
                    
                    // All filtered positions should match filter
                    for (uint256 l = 0; l < filteredPositions.length; l++) {
                        assertEq(
                            filteredPositions[l].underlyingAsset.asset,
                            filter,
                            "Filtered positions should match filter"
                        );
                    }
                    
                    // Filtered should be subset of all
                    assertLe(filteredPositions.length, allPositions.length, "Filtered should be subset");
                }
            }
        }
    }
    
    /// @notice Invariant: Interface compliance
    function invariant_interfaceCompliance() external view {
        address[] memory allOracles = handler.balances().getAllOracles();
        if (allOracles.length == 0) return;
        
        for (uint256 i = 0; i < allOracles.length; i++) {
            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(allOracles[i]);
            
            // Verify supportsInterface - all registered adapters must support the interface
            bool supported;
            try adapter.supportsInterface(type(IBalanceOracleAdapter).interfaceId) returns (bool result) {
                supported = result;
            } catch {
                revert("Registered adapter must support IBalanceOracleAdapter interface");
            }
            assertTrue(supported, "Adapter should support IBalanceOracleAdapter");
            
            // Verify required functions don't revert - all registered adapters must be properly initialized
            try adapter.underlyingAssetsSupported() returns (address[] memory) {
                // Success - adapter is properly initialized
            } catch {
                revert("Registered adapter must be properly initialized and support underlyingAssetsSupported()");
            }
        }
    }
    
    /// @notice Invariant: Supported assets consistency
    function invariant_supportedAssetsConsistency() external view {
        address[] memory allOracles = handler.balances().getAllOracles();
        if (allOracles.length == 0) return;
        
        for (uint256 i = 0; i < allOracles.length; i++) {
            IBalanceOracleAdapter adapter = IBalanceOracleAdapter(allOracles[i]);
            
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
                try adapter.getOracleBalanceForAsset(testAccount, asset) returns (int256) {
                    // Success
                } catch {
                    revert("Registered adapter must be able to query balance for all supported assets");
                }
            }
        }
    }
    
    /// @notice Invariant: ERC20DefaultOracle always registered
    function invariant_erc20DefaultOracleAlwaysRegistered() external view {
        address[] memory allOracles = handler.balances().getAllOracles();
        
        bool found = false;
        for (uint256 i = 0; i < allOracles.length; i++) {
            if (allOracles[i] == address(handler.erc20DefaultOracle())) {
                found = true;
                break;
            }
        }
        
        assertTrue(found, "ERC20DefaultOracle should always be registered");
    }
    
    /// @notice Invariant: Adapter count consistency
    function invariant_adapterCountConsistency() external view {
        uint256 adapterCount = handler.balances().getOracleCount();
        address[] memory allOracles = handler.balances().getAllOracles();
        
        assertEq(adapterCount, allOracles.length, "Adapter count should match registry length");
    }
}
