// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/tokens.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/price_oracles.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "test/mocks/balance_oracles.sol";

/// @title NAVCalculator Handler for Stateful Invariant Testing
/// @notice Handler contract that manages stateful operations for invariant testing
contract NAVCalculatorHandler is Test {
    NAVCalculator public nav;
    Mock_ERC20[] public tokens;
    Mock_CustomPriceFeed[] public priceOracles;
    Mock_CustomBalanceOracle[] public balanceOracles;

    // Actors for testing
    address[] public actors;
    address internal currentActor;

    // Ghost variables for tracking state
    uint256 public ghost_totalNav;
    uint256 public ghost_positionCount;
    uint256 public ghost_oracleCount;
    uint256 public ghost_assetCount;

    // Track registered assets and oracles
    mapping(address => bool) public registeredAssets;
    mapping(address => bool) public registeredOracles;

    modifier useActor(uint256 actorSeed) {
        // Bound seed first to prevent issues with very large values
        actorSeed = bound(actorSeed, 0, type(uint64).max);
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(NAVCalculator _nav, address admin, address manager) {
        nav = _nav;

        // Initialize actors
        for (uint256 i = 0; i < 10; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }

        // Store initial state
        ghost_oracleCount = nav.getOracleCount();
        ghost_assetCount = nav.getAssetCount();
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
        // Bound priceDecimals to prevent denominator overflow (10**denominator must fit in uint256)
        // Max safe denominator is ~77 (10**77 fits in uint256)
        // For denominator = assetDecimals + priceDecimals - 8, we need assetDecimals + priceDecimals <= 85
        // Since assetDecimals is bound to 0-18, priceDecimals should be bound to 0-67
        // BUT: We must ensure assetDecimals + priceDecimals >= 8 (NAV_DECIMALS constraint)
        uint8 priceDecimals;
        if (decimals < 8) {
            // If assetDecimals < 8, ensure priceDecimals makes up the difference
            priceDecimals = uint8(bound(priceSeed % 100, 8 - decimals, 67));
        } else {
            // If assetDecimals >= 8, priceDecimals can be 0-67
            priceDecimals = uint8(bound(priceSeed % 100, 0, 67));
        }
        Mock_CustomPriceFeed priceOracle = new Mock_CustomPriceFeed("TOKEN", address(token), price, priceDecimals);
        priceOracles.push(priceOracle);

        // Register asset
        nav.registerAsset(address(token), address(priceOracle), IPrices.PriceType.Custom, type(uint256).max);
        registeredAssets[address(token)] = true;
        ghost_assetCount = nav.getAssetCount();
    }

    /// @notice Add a balance oracle
    function addOracle(uint256 oracleSeed) external useActor(oracleSeed) {
        // Only manager can add oracles
        if (!nav.hasRole(MANAGER, currentActor)) {
            return;
        }

        // Bound seed first to prevent overflow
        oracleSeed = bound(oracleSeed, 0, type(uint64).max);

        // Create new oracle
        Mock_CustomBalanceOracle oracle = new Mock_CustomBalanceOracle();
        oracle.setBalances(IBalances(address(nav)));
        balanceOracles.push(oracle);

        // Set supported assets (use existing registered assets)
        address[] memory assets = nav.getAssets();
        if (assets.length > 0) {
            uint256 assetCount = bound(oracleSeed, 1, assets.length);
            address[] memory supportedAssets = new address[](assetCount);
            for (uint256 i = 0; i < assetCount; i++) {
                // Use addition instead of multiplication to avoid overflow
                uint256 assetIndex = bound(oracleSeed + i * 1000, 0, assets.length - 1);
                supportedAssets[i] = assets[assetIndex];
            }
            oracle.setUnderlyingAssetsSupported(supportedAssets);
        }

        // Add oracle
        nav.addBalanceOracle(address(oracle));
        registeredOracles[address(oracle)] = true;
        ghost_oracleCount = nav.getOracleCount();
    }

    /// @notice Remove a balance oracle
    function removeOracle(uint256 oracleSeed) external useActor(oracleSeed) {
        // Only manager can remove oracles
        if (!nav.hasRole(MANAGER, currentActor)) {
            return;
        }

        // Bound seed first
        oracleSeed = bound(oracleSeed, 0, type(uint64).max);

        if (balanceOracles.length == 0) return;

        uint256 oracleIndex = bound(oracleSeed, 0, balanceOracles.length - 1);
        address oracle = address(balanceOracles[oracleIndex]);

        // Cannot remove ERC20DefaultOracle
        if (oracle == nav.erc20DefaultOracle()) {
            return;
        }

        nav.removeBalanceOracle(oracle);
        registeredOracles[oracle] = false;
        ghost_oracleCount = nav.getOracleCount();
    }

    /// @notice Mint tokens to an actor
    function mintTokens(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) external useActor(actorSeed) {
        address[] memory assets = nav.getAssets();
        if (assets.length == 0) return;

        // Bound seeds first to prevent overflow issues (use smaller bounds)
        assetSeed = bound(assetSeed, 0, type(uint64).max);
        amountSeed = bound(amountSeed, 0, type(uint64).max);

        uint256 assetIndex = bound(assetSeed, 0, assets.length - 1);
        address asset = assets[assetIndex];

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
            (uint256 price,,) = nav.latestPrice(asset);

            // Bound amount to avoid overflow in amount * usdRate calculation
            // Need to ensure amount * price doesn't overflow uint256
            // Conservative bound: use smaller max to account for price multiplication
            uint256 maxAmount;
            if (decimals <= 18) {
                maxAmount = 1_000_000 * 10 ** decimals;
            } else {
                // For very high decimals, use a more conservative bound
                maxAmount = 1_000_000 * 10 ** 18; // Cap at 18 decimals worth
            }
            // Also check against price-based limit
            uint256 maxByPrice = type(uint256).max / price;
            if (maxByPrice < maxAmount) {
                maxAmount = maxByPrice;
            }
            uint256 amount = bound(amountSeed, 1, maxAmount);

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
        address[] memory assets = nav.getAssets();
        address quoteAsset = address(0); // Default to USD
        if (assets.length > 0) {
            uint256 index = bound(quoteAssetSeed, 0, assets.length);
            if (index < assets.length) {
                quoteAsset = assets[index];
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

        address[] memory assets = nav.getAssets();
        address quoteAsset = address(0);
        if (assets.length > 0) {
            uint256 index = bound(quoteAssetSeed, 0, assets.length);
            if (index < assets.length) {
                quoteAsset = assets[index];
            }
        }

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(account, quoteAsset);
        return positions.length;
    }
}

import "test/SuperTest.sol";

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
                address asset = positions[j].underlyingAsset.asset;
                assertTrue(nav.isAssetRegistered(asset), "All position assets should be registered");
            }
        }
    }

    /// @notice Invariant: Oracle balances aggregate correctly
    function invariant_oracleAggregation() external view {
        // Test with a few actors
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.actors(i);

            // Get all positions
            INAVCalculator.Position[] memory allPositions = nav.getAccountPositions(account, address(0));

            // Group by asset and verify no duplicate oracles
            for (uint256 j = 0; j < allPositions.length; j++) {
                address asset = allPositions[j].underlyingAsset.asset;
                address oracle = allPositions[j].balanceOracle;

                // Check for duplicate oracles reporting same asset
                for (uint256 k = j + 1; k < allPositions.length; k++) {
                    if (allPositions[k].underlyingAsset.asset == asset) {
                        assertTrue(
                            allPositions[k].balanceOracle != oracle,
                            "No duplicate oracles should report same asset for same account"
                        );
                    }
                }
            }
        }
    }

    /// @notice Invariant: Prices consistent within block
    function invariant_priceConsistency() external view {
        address[] memory assets = nav.getAssets();
        if (assets.length == 0) return;

        // Test a few assets
        uint256 testCount = assets.length > 3 ? 3 : assets.length;
        for (uint256 i = 0; i < testCount; i++) {
            address asset = assets[i];

            (uint256 price1, uint8 decimals1, bool stale1) = nav.latestPrice(asset);
            (uint256 price2, uint8 decimals2, bool stale2) = nav.latestPrice(asset);

            assertEq(price1, price2, "Price should be consistent within block");
            assertEq(decimals1, decimals2, "Decimals should be consistent");
            assertEq(stale1, stale2, "Staleness should be consistent");
        }
    }

    /// @notice Invariant: ERC20DefaultOracle always registered
    function invariant_erc20DefaultOracleAlwaysRegistered() external view {
        address[] memory allOracles = nav.getAllOracles();

        bool found = false;
        for (uint256 i = 0; i < allOracles.length; i++) {
            if (allOracles[i] == nav.erc20DefaultOracle()) {
                found = true;
                break;
            }
        }

        assertTrue(found, "ERC20DefaultOracle should always be registered");
    }

    /// @notice Invariant: Oracle count matches registry
    function invariant_oracleCountConsistency() external view {
        uint256 oracleCount = nav.getOracleCount();
        address[] memory allOracles = nav.getAllOracles();

        assertEq(oracleCount, allOracles.length, "Oracle count should match registry length");
    }

    /// @notice Invariant: Asset count matches registry
    function invariant_assetCountConsistency() external view {
        uint256 assetCount = nav.getAssetCount();
        address[] memory allAssets = nav.getAssets();

        assertEq(assetCount, allAssets.length, "Asset count should match registry length");
    }
}
