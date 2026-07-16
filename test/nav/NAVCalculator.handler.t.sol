// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/price_oracles.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/balance_adapters.sol";

/// @title NAVCalculator Handler for Stateful Invariant Testing
/// @notice Handler contract that manages stateful operations for invariant testing
contract NAVCalculatorHandler is Test {
    NAVCalculator public nav;
    Mock_ERC20[] public tokens;
    Mock_CustomPriceFeed[] public priceOracles;
    Mock_CustomBalanceAdapter[] public balanceAdapters;

    // Actors for testing
    address[] public actors;
    address internal currentActor;

    // Ghost variables for tracking state
    uint256 public ghostTotalNav;
    uint256 public ghostPositionCount;
    uint256 public ghostAdapterCount;
    uint256 public ghostAssetCount;

    // Track registered assets and adapters
    mapping(address => bool) public registeredAssets;
    mapping(address => bool) public registeredAdapters;

    modifier useActor(uint256 actorSeed) {
        // Bound seed first to prevent issues with very large values
        actorSeed = bound(actorSeed, 0, type(uint64).max);
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        NAVCalculator _nav,
        address,
        /* admin */
        address /* manager */
    ) {
        nav = _nav;

        // Initialize actors
        for (uint256 i = 0; i < 10; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }

        // Store initial state
        ghostAdapterCount = nav.getAdapterCount();
        ghostAssetCount = nav.getAssetCount();
    }

    /// @notice Register a new asset with price feed
    function registerAsset(uint256 tokenSeed, uint256 priceSeed) external useActor(tokenSeed) {
        // Only manager can register assets
        if (!nav.hasRole(MANAGER, currentActor)) {
            return;
        }

        // Bound seeds first to prevent overflow issues (use smaller bounds for better fuzzing)
        tokenSeed = bound(tokenSeed, 0, type(uint64).max);
        priceSeed = bound(priceSeed, 0, type(uint64).max);

        // Create new token
        uint8 decimals = uint8(bound(tokenSeed, 0, 18));
        Mock_ERC20 token = new Mock_ERC20("TOKEN", decimals);
        tokens.push(token);

        // Create price oracle
        // Bound price to prevent overflow in amount * price calculations
        // Use conservative bounds: max price * max amount should not overflow uint256
        uint256 price = bound(priceSeed, 1e6, 1e12); // Reasonable price range
        // Bound priceDecimals so denom1 = assetDecimals + priceDecimals - NAV_DECIMALS <= MAX_DECIMAL_EXPONENT_INT256 (76)
        // i.e. priceDecimals <= 76 + 8 - assetDecimals = 84 - assetDecimals
        // Also require assetDecimals + priceDecimals >= 8 (NAV_DECIMALS constraint)
        uint8 maxPriceDecimals = decimals <= 84 ? uint8(84 - decimals) : 0;
        uint8 priceDecimals;
        if (decimals < 8) {
            priceDecimals = uint8(bound(priceSeed % 100, 8 - decimals, maxPriceDecimals));
        } else {
            priceDecimals = uint8(bound(priceSeed % 100, 0, maxPriceDecimals));
        }
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TOKEN", address(token), price, priceDecimals);
        priceOracles.push(priceOracle);

        // Register asset
        nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        registeredAssets[address(token)] = true;
        ghostAssetCount = nav.getAssetCount();
    }

    /// @notice Add a balance adapter
    function addAdapter(uint256 adapterSeed) external useActor(adapterSeed) {
        // Only manager can add adapters
        if (!nav.hasRole(MANAGER, currentActor)) {
            return;
        }

        // Bound seed first to prevent overflow
        adapterSeed = bound(adapterSeed, 0, type(uint64).max);

        // Create new adapter
        Mock_CustomBalanceAdapter adapter = new Mock_CustomBalanceAdapter();
        adapter.setBalances(IBalances(address(nav)));
        balanceAdapters.push(adapter);

        // Set supported assets (use existing registered assets)
        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        if (registered.length > 0) {
            uint256 assetCount = bound(adapterSeed, 1, registered.length);
            address[] memory supportedAssets = new address[](assetCount);
            for (uint256 i = 0; i < assetCount; i++) {
                // Use addition instead of multiplication to avoid overflow
                uint256 assetIndex = bound(adapterSeed + i * 1000, 0, registered.length - 1);
                supportedAssets[i] = registered[assetIndex].asset;
            }
            adapter.setUnderlyingAssetsSupported(supportedAssets);
        }

        // Add adapter
        nav.addBalanceAdapters(aa(address(adapter)));
        registeredAdapters[address(adapter)] = true;
        ghostAdapterCount = nav.getAdapterCount();
    }

    /// @notice Remove a balance adapter
    function removeAdapter(uint256 adapterSeed) external useActor(adapterSeed) {
        // Only manager can remove adapters
        if (!nav.hasRole(MANAGER, currentActor)) {
            return;
        }

        // Bound seed first
        adapterSeed = bound(adapterSeed, 0, type(uint64).max);

        if (balanceAdapters.length == 0) return;

        uint256 adapterIndex = bound(adapterSeed, 0, balanceAdapters.length - 1);
        address adapter = address(balanceAdapters[adapterIndex]);

        // Cannot remove ERC20DefaultBalanceAdapter
        if (adapter == nav.erc20DefaultBalanceAdapter()) {
            return;
        }

        nav.removeBalanceAdapters(aa(adapter));
        registeredAdapters[adapter] = false;
        ghostAdapterCount = nav.getAdapterCount();
    }

    /// @notice Mint tokens to an actor
    function mintTokens(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) external useActor(actorSeed) {
        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        if (registered.length == 0) return;

        // Bound seeds first to prevent overflow issues (use smaller bounds)
        assetSeed = bound(assetSeed, 0, type(uint64).max);
        amountSeed = bound(amountSeed, 0, type(uint64).max);

        uint256 assetIndex = bound(assetSeed, 0, registered.length - 1);
        address asset = registered[assetIndex].asset;

        // Find token contract
        Mock_ERC20 token;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (address(tokens[i]) == asset) {
                token = tokens[i];
                break;
            }
        }

        // Also check base tokens (usdc, dai, weth from SuperTest)
        // For simplicity, we'll use a try-catch approach
        try Mock_ERC20(asset).decimals() returns (uint8 decimals) {
            // Get price to calculate safe amount bound
            (int256 price,,,,) = nav.latestPrice(asset);

            // Bound amount to avoid overflow in amount * usdRate calculation
            // Need to ensure amount * price doesn't overflow uint256
            // Conservative bound: use smaller max to account for price multiplication
            int256 maxAmount;
            if (decimals <= 18) {
                maxAmount = SafeCast.toInt256(uint256(1_000_000) * 10 ** decimals);
            } else {
                // For very high decimals, use a more conservative bound
                maxAmount = SafeCast.toInt256(uint256(1_000_000) * 10 ** 18); // Cap at 18 decimals worth
            }
            // Also check against price-based limit (price is int256; use magnitude when positive)
            if (price > 0) {
                int256 maxByPrice = type(int256).max / price;
                if (maxByPrice < maxAmount) {
                    maxAmount = maxByPrice;
                }
            }
            uint256 amount = bound(amountSeed, 1, SafeCast.toUint256(maxAmount));

            // Try to mint (will fail if not a mock token, that's okay)
            try token.mint(currentActor, amount) {} catch {}
        } catch {}
    }

    /// @notice Query NAV for an actor
    function queryNav(uint256 actorSeed, uint256 quoteAssetSeed) external view returns (int256) {
        // Bound seeds first
        actorSeed = bound(actorSeed, 0, type(uint64).max);
        quoteAssetSeed = bound(quoteAssetSeed, 0, type(uint64).max);

        address account = actors[bound(actorSeed, 0, actors.length - 1)];

        // Get valid quote asset
        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        address quoteAsset = address(0); // Default to USD
        if (registered.length > 0) {
            uint256 index = bound(quoteAssetSeed, 0, registered.length);
            if (index < registered.length) {
                quoteAsset = registered[index].asset;
            }
        }

        INAVCalculator.NAV memory navResult = nav.getAccountNav(account, quoteAsset);
        return navResult.value;
    }

    /// @notice Get positions for an actor
    function getPositions(uint256 actorSeed, uint256 quoteAssetSeed) external view returns (uint256) {
        // Bound seeds first
        actorSeed = bound(actorSeed, 0, type(uint64).max);
        quoteAssetSeed = bound(quoteAssetSeed, 0, type(uint64).max);

        address account = actors[bound(actorSeed, 0, actors.length - 1)];

        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        address quoteAsset = address(0);
        if (registered.length > 0) {
            uint256 index = bound(quoteAssetSeed, 0, registered.length);
            if (index < registered.length) {
                quoteAsset = registered[index].asset;
            }
        }

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, quoteAsset);
        return positions.length;
    }
}

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {aa} from "test/helpers/AdapterArray.sol";

/// @title NAVCalculator Handler-Based Invariant Tests
/// @notice Stateful invariant tests using handler contract
contract NAVCalculatorHandlerTest is SuperTest {
    NAVCalculatorHandler public handler;

    function setUp() public {
        setupAll();

        // Create handler
        handler = new NAVCalculatorHandler(nav, admin, navCalculatorManager);

        // Grant handler actors the manager role for testing
        for (uint256 i = 0; i < 10; i++) {
            address actor = handler.actors(i);
            vm.prank(admin);
            nav.grantRole(MANAGER, actor);
        }

        // Set handler as target for invariant testing
        targetContract(address(handler));
    }

    // ============================================
    // Invariant Functions
    // ============================================

    /// @notice Invariant: NAV always equals sum of positions
    function invariant_navConsistency() external view {
        // Test with a few actors
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.actors(i);

            INAVCalculator.NAV memory navResult = nav.getAccountNav(account, address(0));
            INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, address(0));

            int256 positionsSum = 0;
            for (uint256 j = 0; j < positions.length; j++) {
                positionsSum += positions[j].value;
            }

            // Allow small rounding differences
            assertApproxEqAbs(navResult.value, positionsSum, 1, "NAV should equal sum of positions");
        }
    }

    /// @notice Invariant: No zero positions in results
    function invariant_noZeroPositions() external view {
        // Test with a few actors
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.actors(i);
            INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, address(0));

            for (uint256 j = 0; j < positions.length; j++) {
                assertTrue(positions[j].amount != 0, "No zero positions should be returned");
            }
        }
    }

    /// @notice Invariant: All position assets are registered
    function invariant_allAssetsRegistered() external view {
        // Test with a few actors
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.actors(i);
            INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, address(0));

            for (uint256 j = 0; j < positions.length; j++) {
                address asset = positions[j].balanceAsset.asset;
                assertTrue(nav.isAssetRegistered(asset), "All position assets should be registered");
            }
        }
    }

    /// @notice Invariant: Adapter balances aggregate correctly
    function invariant_adapterAggregation() external view {
        // Test with a few actors
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.actors(i);

            // Get all positions
            INAVCalculator.Position[] memory allPositions = nav.getAccountPositions(account, address(0));

            // Group by asset and verify no duplicate adapters
            for (uint256 j = 0; j < allPositions.length; j++) {
                address asset = allPositions[j].balanceAsset.asset;
                address adapter = allPositions[j].balanceAdapter;

                // Check for duplicate adapters reporting same asset
                for (uint256 k = j + 1; k < allPositions.length; k++) {
                    if (allPositions[k].balanceAsset.asset == asset) {
                        assertTrue(
                            allPositions[k].balanceAdapter != adapter,
                            "No duplicate adapters should report same asset for same account"
                        );
                    }
                }
            }
        }
    }

    /// @notice Invariant: Prices consistent within block
    function invariant_priceConsistency() external view {
        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        if (registered.length == 0) return;

        // Test a few assets
        uint256 testCount = registered.length > 3 ? 3 : registered.length;
        for (uint256 i = 0; i < testCount; i++) {
            address asset = registered[i].asset;

            (int256 price1, uint8 decimals1, bool stale1,,) = nav.latestPrice(asset);
            (int256 price2, uint8 decimals2, bool stale2,,) = nav.latestPrice(asset);

            assertEq(price1, price2, "Price should be consistent within block");
            assertEq(decimals1, decimals2, "Decimals should be consistent");
            assertEq(stale1, stale2, "Staleness should be consistent");
        }
    }

    /// @notice Invariant: ERC20DefaultBalanceAdapter always registered
    function invariant_erc20DefaultBalanceAdapterAlwaysRegistered() external view {
        address[] memory allAdapters = nav.getAllAdapters();

        bool found = false;
        for (uint256 i = 0; i < allAdapters.length; i++) {
            if (allAdapters[i] == nav.erc20DefaultBalanceAdapter()) {
                found = true;
                break;
            }
        }

        assertTrue(found, "ERC20DefaultBalanceAdapter should always be registered");
    }

    /// @notice Invariant: Adapter count matches registry
    function invariant_adapterCountConsistency() external view {
        uint256 adapterCount = nav.getAdapterCount();
        address[] memory allAdapters = nav.getAllAdapters();

        assertEq(adapterCount, allAdapters.length, "Adapter count should match registry length");
    }

    /// @notice Invariant: Asset count matches registry
    function invariant_assetCountConsistency() external view {
        uint256 assetCount = nav.getAssetCount();
        INAVCalculator.Asset[] memory allAssets = nav.getRegisteredAssets();

        assertEq(assetCount, allAssets.length, "Asset count should match registry length");
    }
}
