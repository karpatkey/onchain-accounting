// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceOracleAdapter} from "src/balances/IBalanceOracleAdapter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract NAVCalculatorHarness is NAVCalculator {
    constructor(address admin, address chainlinkUptimeFeed, string memory nativeTokenSymbol) {
        NAVCalculator.initialize(admin, chainlinkUptimeFeed, nativeTokenSymbol);
    }
}

contract NAVCalculatorTest is SuperTest {
    Mock_PriceOracleChainlink public chainlinkOracle;

    Mock_CustomBalanceOracle public depositedWethOracle;

    function setUp() public {
        setupAll();
        chainlinkOracle = new Mock_PriceOracleChainlink("Chainlink Oracle", 1, 8);
    }

    // Helper functions for tests
    function sumPositionValues(INAVCalculator.Position[] memory positions) internal pure returns (int256) {
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        return sum;
    }

    /// @notice Helper function to configure mockBalanceOracle with specific assets
    /// @param assets Array of asset addresses to configure
    /// @param balances Optional array of balances for each asset (same length as assets, or empty for defaults)
    /// @param protocol Optional protocol name (defaults to "Mock Protocol")
    /// @param position Optional position name (defaults to "Mock Position")
    function setupMockBalanceOracle(
        address[] memory assets,
        int256[] memory balances,
        string memory protocol,
        string memory position
    ) internal {
        // Set balances reference if nav is available
        mockBalanceOracle.setBalances(IBalances(address(nav)));

        // Set underlying assets supported
        mockBalanceOracle.setUnderlyingAssetsSupported(assets);

        // Set balances for each asset (use provided balances or defaults)
        for (uint256 i = 0; i < assets.length; i++) {
            int256 balance = balances.length > i ? balances[i] : int256(0);
            if (balance >= 0) {
                mockBalanceOracle.setBalance(assets[i], safe, SafeCast.toUint256(balance), false);
            } else {
                mockBalanceOracle.setBalance(assets[i], safe, SafeCast.toUint256(-balance), true);
            }
        }

        // Set position metadata
        mockBalanceOracle.setPositionMetadata(
            bytes(protocol).length > 0 ? protocol : "Mock Protocol",
            bytes(position).length > 0 ? position : "Mock Position"
        );
    }

    /// @notice Convenience overload for single asset
    function setupMockBalanceOracle(address asset, int256 balance) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        int256[] memory balances = new int256[](1);
        balances[0] = balance;
        // Note: setupMockBalanceOracle still uses int256[] for backward compatibility
        setupMockBalanceOracle(assets, balances, "", "");
    }

    function findPositionByAsset(INAVCalculator.Position[] memory positions, address asset)
        internal
        pure
        returns (INAVCalculator.Position memory, bool)
    {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].underlyingAsset.asset == asset) {
                // Check if this matches the balance oracle index by checking metadata
                // We'll need to match by protocol/positionDetail or use a different approach
                // For now, return first match - tests should be more specific
                return (positions[i], true);
            }
        }
        INAVCalculator.Position memory empty;
        return (empty, false);
    }

    function assertPositionMetadata(
        INAVCalculator.Position memory pos,
        address expectedAsset,
        string memory expectedProtocol,
        string memory expectedPositionDetail
    ) internal pure {
        assertEq(pos.underlyingAsset.asset, expectedAsset, "Asset mismatch");
        assertEq(pos.protocol, expectedProtocol, "Protocol mismatch");
        assertEq(pos.positionDetail, expectedPositionDetail, "PositionDetail mismatch");
    }

    function test_setUp() public {
        // Native address is already registered in setupAll(), so we just verify the setup
        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        assertEq(registered.length, 4);
        // Assets can be in any order, so we check by searching
        bool foundUsdc = false;
        bool foundDai = false;
        bool foundWeth = false;
        bool foundNative = false;
        for (uint256 i = 0; i < registered.length; i++) {
            if (registered[i].asset == address(usdc)) foundUsdc = true;
            if (registered[i].asset == address(dai)) foundDai = true;
            if (registered[i].asset == address(weth)) foundWeth = true;
            if (registered[i].asset == nav.NATIVE_ADDRESS()) foundNative = true;
        }
        assertTrue(foundUsdc, "USDC should be registered");
        assertTrue(foundDai, "DAI should be registered");
        assertTrue(foundWeth, "WETH should be registered");
        assertTrue(foundNative, "Native address should be registered");

        (address address_, uint8 decimals, uint256 chainlinkHeartbeat_, IPrices.PriceType priceType_) =
            nav.priceOracles(address(usdc));
        assertEq(address_, address(usdcOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, type(uint256).max);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Custom));

        (address_, decimals, chainlinkHeartbeat_, priceType_) = nav.priceOracles(address(dai));
        assertEq(address_, address(daiOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, 86_400);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Chainlink));

        (address_, decimals, chainlinkHeartbeat_, priceType_) = nav.priceOracles(address(weth));
        assertEq(address_, address(wethOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, type(uint256).max);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Custom));

        (address_, decimals, chainlinkHeartbeat_, priceType_) = nav.priceOracles(nav.NATIVE_ADDRESS());
        assertEq(address_, address(ethOracle));
        assertEq(decimals, 8);
        assertEq(chainlinkHeartbeat_, type(uint256).max);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Chainlink));

        // Configure mockBalanceOracle with all three assets
        address[] memory mockAssets = new address[](3);
        mockAssets[0] = address(usdc);
        mockAssets[1] = address(dai);
        mockAssets[2] = address(weth);
        int256[] memory mockBalances = new int256[](3);
        mockBalances[0] = int256(123 * 10 ** usdc.decimals());
        mockBalances[1] = int256(456 * 10 ** dai.decimals());
        mockBalances[2] = int256(789 * 10 ** weth.decimals());
        setupMockBalanceOracle(mockAssets, mockBalances, "Mock Protocol", "Mock Position");

        vm.startPrank(navCalculatorManager);
        // Oracles are now global - add the oracle once
        nav.addBalanceOracle(address(mockBalanceOracle));
        vm.stopPrank();

        // getAllOracles returns all global oracles
        address[] memory allOracles = nav.getAllOracles();
        // Should include ERC20DefaultOracle (from initialization) and mockBalanceOracle
        assertGe(allOracles.length, 2, "Should have at least ERC20DefaultOracle and mockBalanceOracle");
        bool foundMockOracle = false;
        bool foundErc20Default = false;
        for (uint256 i = 0; i < allOracles.length; i++) {
            if (allOracles[i] == address(mockBalanceOracle)) {
                foundMockOracle = true;
            }
            if (allOracles[i] == nav.erc20DefaultOracle()) {
                foundErc20Default = true;
            }
        }
        assertTrue(foundMockOracle, "Should find mockBalanceOracle in global oracles");
        assertTrue(foundErc20Default, "Should find ERC20DefaultOracle in global oracles");

        assertEq(nav.chainlinkL2SequencerGracePeriod(), 3600);
    }

    function test_addBalanceOracle() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        // ERC20DefaultOracle is already registered globally, no need to add it again
        vm.stopPrank();
    }

    function test_addBalanceOracle_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        address erc20Oracle = nav.erc20DefaultOracle();
        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.addBalanceOracle(erc20Oracle);
        vm.stopPrank();
    }

    function test_registerAsset() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_registerAsset_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_addBalanceOracle_withoutAsset() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        // With global oracles, you can add an oracle without an asset being registered
        // ERC20DefaultOracle is already registered, so try adding a custom oracle
        address customOracle = address(mockBalanceOracle);
        vm.prank(navCalculatorManager);
        nav.addBalanceOracle(customOracle);

        // Verify it was added
        assertTrue(nav.isOracleRegistered(customOracle), "Custom oracle should be registered");
    }

    function test_removeBalanceOracle_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        // Add a custom oracle to test removal
        nav.addBalanceOracle(address(mockBalanceOracle));
        assertTrue(nav.isOracleRegistered(address(mockBalanceOracle)), "Oracle should be registered");

        // Remove the oracle
        nav.removeBalanceOracle(address(mockBalanceOracle));
        assertFalse(nav.isOracleRegistered(address(mockBalanceOracle)), "Oracle should be removed");
        vm.stopPrank();
    }

    function test_removeBalanceOracle_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        // Add a custom oracle to test removal
        nav.addBalanceOracle(address(mockBalanceOracle));
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.removeBalanceOracle(address(mockBalanceOracle));
        vm.stopPrank();
    }

    function test_unsetPriceFeed_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);

        nav.unsetPriceFeed(address(usdc));
        vm.stopPrank();
    }

    function test_unsetPriceFeed_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.unsetPriceFeed(address(usdc));
        vm.stopPrank();
    }

    // ============================================
    // Asset Registration Tests
    // ============================================

    function test_registerAsset_duplicate() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);

        vm.expectRevert(InvalidArguments.selector);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_registerAsset_zeroAddress() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.registerAsset(address(0), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_registerAsset_zeroOracle() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.registerAsset(address(usdc), address(0), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Asset Unregistration Tests
    // ============================================

    function test_unregisterAsset() public {
        vm.startPrank(navCalculatorManager);
        // USDC is already registered in setup, so we can directly test unregistering it
        // Verify asset is registered
        assertTrue(nav.isAssetRegistered(address(usdc)));

        // Unregister asset
        nav.unregisterAsset(address(usdc));

        // Verify asset is unregistered
        assertFalse(nav.isAssetRegistered(address(usdc)));
        vm.stopPrank();
    }

    function test_unregisterAsset_notAuthorized() public {
        // USDC is already registered in setup, so we can directly test authorization
        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.unregisterAsset(address(usdc));
        vm.stopPrank();
    }

    function test_unregisterAsset_withBalanceOracles() public {
        // Configure mockBalanceOracle for USDC
        setupMockBalanceOracle(address(usdc), int256(123 * 10 ** usdc.decimals()));

        vm.startPrank(navCalculatorManager);
        // USDC is already registered in setup. Add the custom oracle globally
        nav.addBalanceOracle(address(mockBalanceOracle));

        // Verify balance oracles exist (ERC20DefaultOracle from setup + custom oracle)
        assertGe(nav.getOracleCount(), 2, "Should have at least ERC20DefaultOracle and custom oracle");

        // Unregister asset - oracles are global and should not be removed
        nav.unregisterAsset(address(usdc));

        // Verify balance oracles are still present (oracles are global, not removed when asset is unregistered)
        assertGe(nav.getOracleCount(), 2, "Oracles should still exist after asset unregistration");
        vm.stopPrank();
    }

    function test_unregisterAsset_withPriceFeed() public {
        vm.startPrank(navCalculatorManager);
        // USDC is already registered in setup with price feed, so we can directly test unregistering

        // Verify price feed exists
        (address oracle,,,) = nav.priceOracles(address(usdc));
        assertEq(oracle, address(usdcOracle));

        // Unregister asset
        nav.unregisterAsset(address(usdc));

        // Verify price feed is removed
        (oracle,,,) = nav.priceOracles(address(usdc));
        assertEq(oracle, address(0));
        vm.stopPrank();
    }

    // ============================================
    // Default oracle inclusion list (exclude / include)
    // ============================================

    function test_registerAsset_addsAssetToDefaultOracleInclusionList() public {
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        Mock_CustomPriceFeed newTokenOracle = new Mock_CustomPriceFeed("NEW", address(newToken), 1e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(newToken), address(newTokenOracle), IPrices.PriceType.Custom, type(uint256).max);

        address defaultOracle = nav.erc20DefaultOracle();
        address[] memory supported = IBalanceOracleAdapter(defaultOracle).underlyingAssetsSupported();
        bool found = false;
        for (uint256 i = 0; i < supported.length; i++) {
            if (supported[i] == address(newToken)) found = true;
        }
        assertTrue(found, "Default oracle should support newly registered asset");

        address[] memory oracles = nav.getOraclesForAsset(address(newToken));
        bool defaultFound = false;
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == defaultOracle) defaultFound = true;
        }
        assertTrue(defaultFound, "getOraclesForAsset should include default oracle for new asset");
    }

    function test_excludeAssetFromDefaultOracle_removesFromInclusionList() public {
        address defaultOracle = nav.erc20DefaultOracle();
        address[] memory oraclesBefore = nav.getOraclesForAsset(address(usdc));
        bool hadDefaultBefore = false;
        for (uint256 i = 0; i < oraclesBefore.length; i++) {
            if (oraclesBefore[i] == defaultOracle) hadDefaultBefore = true;
        }
        assertTrue(hadDefaultBefore, "Default oracle should support USDC before exclude");

        vm.prank(navCalculatorManager);
        nav.excludeAssetFromDefaultOracle(address(usdc));

        address[] memory supported = IBalanceOracleAdapter(defaultOracle).underlyingAssetsSupported();
        for (uint256 i = 0; i < supported.length; i++) {
            assertTrue(supported[i] != address(usdc), "USDC should not be in default oracle after exclude");
        }
        address[] memory oraclesAfter = nav.getOraclesForAsset(address(usdc));
        for (uint256 i = 0; i < oraclesAfter.length; i++) {
            assertTrue(oraclesAfter[i] != defaultOracle, "Default oracle should not support USDC after exclude");
        }
    }

    function test_includeAssetInDefaultOracle_addsBack() public {
        vm.prank(navCalculatorManager);
        nav.excludeAssetFromDefaultOracle(address(usdc));

        vm.prank(navCalculatorManager);
        nav.includeAssetInDefaultOracle(address(usdc));

        address defaultOracle = nav.erc20DefaultOracle();
        address[] memory supported = IBalanceOracleAdapter(defaultOracle).underlyingAssetsSupported();
        bool found = false;
        for (uint256 i = 0; i < supported.length; i++) {
            if (supported[i] == address(usdc)) found = true;
        }
        assertTrue(found, "USDC should be in default oracle after include");
        address[] memory oracles = nav.getOraclesForAsset(address(usdc));
        bool defaultFound = false;
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == defaultOracle) defaultFound = true;
        }
        assertTrue(defaultFound, "getOraclesForAsset should include default oracle after include");
    }

    function test_excludeAssetFromDefaultOracle_notAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.excludeAssetFromDefaultOracle(address(usdc));
    }

    function test_includeAssetInDefaultOracle_notAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.includeAssetInDefaultOracle(address(usdc));
    }

    function test_includeAssetInDefaultOracle_revertsForUnregisteredAsset() public {
        address unregisteredAsset = makeAddr("unregistered");
        vm.prank(navCalculatorManager);
        vm.expectRevert(AssetNotFound.selector);
        nav.includeAssetInDefaultOracle(unregisteredAsset);
    }

    function test_unregisterAsset_removesFromDefaultOracleInclusionList() public {
        address defaultOracle = nav.erc20DefaultOracle();
        address[] memory supportedBefore = IBalanceOracleAdapter(defaultOracle).underlyingAssetsSupported();
        uint256 countBefore = 0;
        for (uint256 i = 0; i < supportedBefore.length; i++) {
            if (supportedBefore[i] == address(usdc)) countBefore++;
        }
        assertEq(countBefore, 1, "USDC should be in default oracle before unregister");

        vm.prank(navCalculatorManager);
        nav.unregisterAsset(address(usdc));

        address[] memory supportedAfter = IBalanceOracleAdapter(defaultOracle).underlyingAssetsSupported();
        for (uint256 i = 0; i < supportedAfter.length; i++) {
            assertTrue(supportedAfter[i] != address(usdc), "USDC should not be in default oracle after unregister");
        }
    }

    // ============================================
    // Asset-Specific Query Tests
    // ============================================

    function test_getAccountPositionsForAsset() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());

        // Get positions for USDC only
        INAVCalculator.Position[] memory usdcPositions =
            nav.getAccountPositionsForAsset(safe, address(usdc), address(0));

        // All positions should be for USDC
        assertTrue(usdcPositions.length > 0);
        for (uint256 i = 0; i < usdcPositions.length; i++) {
            assertEq(usdcPositions[i].underlyingAsset.asset, address(usdc));
        }
    }

    function test_getAccountPositionsForAsset_invalidAsset() public {
        address unregisteredAsset = makeAddr("unregistered");

        vm.expectRevert(AssetNotFound.selector);
        nav.getAccountPositionsForAsset(safe, unregisteredAsset, address(0));
    }

    function test_getAccountPositionsForAsset_invalidQuoteAsset() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        address invalidQuote = makeAddr("invalid");
        // Implementation checks price feed first, not asset registration
        vm.expectRevert(abi.encodeWithSelector(PriceFeedNotSet.selector, invalidQuote));
        nav.getAccountPositionsForAsset(safe, address(usdc), invalidQuote);
    }

    function test_getAccountPositionsForAsset_emptyAccount() public view {
        // Account with no positions for the asset
        INAVCalculator.Position[] memory positions = nav.getAccountPositionsForAsset(safe, address(usdc), address(0));
        assertEq(positions.length, 0);
    }

    // ============================================
    // Price Data Tests
    // ============================================

    function test_getPriceData() public view {
        INAVCalculator.PriceFeedData memory priceFeed = nav.getPriceData(address(usdc));

        assertTrue(priceFeed.priceFeed != address(0));
        assertTrue(priceFeed.price > 0);
        assertTrue(priceFeed.decimals > 0);
        assertEq(uint8(priceFeed.priceType), uint8(IPrices.PriceType.Custom));
    }

    function test_getPriceData_chainlinkOracle() public view {
        INAVCalculator.PriceFeedData memory priceFeed = nav.getPriceData(address(dai));

        assertTrue(priceFeed.priceFeed != address(0));
        assertEq(uint8(priceFeed.priceType), uint8(IPrices.PriceType.Chainlink));
        assertTrue(priceFeed.updatedAt > 0); // Chainlink should have updatedAt
    }

    function test_getPriceData_customOracle() public view {
        INAVCalculator.PriceFeedData memory priceFeed = nav.getPriceData(address(usdc));

        assertEq(uint8(priceFeed.priceType), uint8(IPrices.PriceType.Custom));
        // Per IPriceFeedCustom.latestRoundData() convention, updatedAt surfaces the worst-case
        // freshness of the underlying oracle(s); Mock_CustomPriceFeed pins it to block.timestamp.
        assertEq(priceFeed.updatedAt, block.timestamp);
    }

    function test_getPriceData_customOracle_noTrackableOracle() public {
        // Per IPriceFeedCustom convention, latestRoundData() returning updatedAt = 0 is the
        // documented sentinel for feeds with no trackable oracle dependency (live on-chain rate).
        // getPriceData() must pass the sentinel through to callers — see ADR 0010.
        //
        // The live-rate feed is NOT stale (getLatestPrice returns stale=false) — only its
        // latestRoundData() reports updatedAt=0. Mixing the staleness and the no-oracle-dep
        // signals in one mock would obscure which one is under test, so this uses the dedicated
        // Mock_CustomPriceFeedLiveRate that flips ONLY the updatedAt sentinel.
        Mock_CustomPriceFeedLiveRate liveRateOracle =
            new Mock_CustomPriceFeedLiveRate("LiveRate", address(usdc), 1e8, 8);
        vm.prank(navCalculatorManager);
        nav.setPriceFeed(address(usdc), address(liveRateOracle), IPrices.PriceType.Custom, type(uint256).max);

        INAVCalculator.PriceFeedData memory priceFeed = nav.getPriceData(address(usdc));
        assertEq(uint8(priceFeed.priceType), uint8(IPrices.PriceType.Custom));
        assertEq(priceFeed.updatedAt, 0);
        assertFalse(priceFeed.stale, "live-rate feed (no oracle dep) must not be marked stale");
    }

    function test_getPriceData_stalePrice() public {
        // Create a stale price oracle with short heartbeat
        Mock_PriceOracleChainlink staleOracle = new Mock_PriceOracleChainlink("Stale", 1, 8);
        vm.startPrank(navCalculatorManager);
        nav.setPriceFeed(address(usdc), address(staleOracle), IPrices.PriceType.Chainlink, 1); // 1 second heartbeat
        vm.stopPrank();

        // Make price stale by warping time
        vm.warp(block.timestamp + 2);

        INAVCalculator.PriceFeedData memory priceFeed = nav.getPriceData(address(usdc));
        assertTrue(priceFeed.stale);
    }

    function test_getPriceData_sequencerDown() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeedDown));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        INAVCalculator.PriceFeedData memory priceFeed = nav.getPriceData(address(usdc));
        assertTrue(priceFeed.sequencerDown);
    }

    function test_getPriceData_invalidAsset() public {
        address unregisteredAsset = makeAddr("unregistered");

        vm.expectRevert(AssetNotFound.selector);
        nav.getPriceData(unregisteredAsset);
    }

    // ============================================
    // Asset Enumeration Tests
    // ============================================

    function test_getRegisteredAssets_firstAsset() public view {
        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        assertTrue(registered.length > 0);

        INAVCalculator.Asset memory asset = registered[0];
        assertTrue(asset.asset != address(0));
        assertTrue(asset.asset == address(nav.NATIVE_ADDRESS()));
        assertTrue(bytes(asset.symbol).length > 0);
        assertTrue(asset.decimals > 0);
    }

    function test_getRegisteredAssets_lengthMatchesAssetCount() public view {
        INAVCalculator.Asset[] memory registered = nav.getRegisteredAssets();
        assertEq(registered.length, nav.getAssetCount());
        assertTrue(registered.length > 0);
    }

    function test_assetCount() public view {
        uint256 count = nav.assetCount();

        // Should have at least the assets from setup (usdc, dai, weth, native)
        assertTrue(count >= 4);
    }

    // ============================================
    // Utility Function Tests
    // ============================================

    function test_version() public view {
        uint64 version = nav.version();
        assertTrue(version > 0);
    }

    function test_usdDecimals() public view {
        uint8 decimals = nav.usdDecimals();
        assertEq(decimals, 8); // NAV_DECIMALS
    }

    // ============================================
    // Global Oracle Registry Tests
    // ============================================

    function test_getAllOracles() public view {
        address[] memory oracles = nav.getAllOracles();

        assertTrue(oracles.length > 0);
        assertEq(oracles.length, nav.getOracleCount());
    }

    function test_getOracleCount() public view {
        uint256 count = nav.getOracleCount();

        assertTrue(count > 0);
        // Should have at least ERC20DefaultOracle
        assertTrue(count >= 1);
    }

    function test_isOracleRegistered() public {
        // ERC20DefaultOracle should be registered
        assertTrue(nav.isOracleRegistered(nav.erc20DefaultOracle()));

        // Random address should not be registered
        assertFalse(nav.isOracleRegistered(makeAddr("random")));
    }

    function test_getOracleType() public view {
        IBalances.OracleType oracleType = nav.getOracleType(nav.erc20DefaultOracle());
        assertEq(uint8(oracleType), uint8(IBalances.OracleType.Default));
    }

    function test_getOracleType_invalidOracle() public {
        address invalidOracle = makeAddr("invalid");

        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        nav.getOracleType(invalidOracle);
    }

    // ============================================
    // Asset Registry Tests (from Balances)
    // ============================================

    function test_getRegisteredAssets() public view {
        INAVCalculator.Asset[] memory assets = nav.getRegisteredAssets();

        assertEq(assets.length, nav.getAssetCount());
        assertTrue(assets.length > 0);
    }

    function test_getAssetCount() public view {
        uint256 count = nav.getAssetCount();

        assertTrue(count >= 4); // At least usdc, dai, weth, native
    }

    function test_getAssetDecimals() public view {
        // Get asset info from registered assets
        INAVCalculator.Asset[] memory assets = nav.getRegisteredAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].asset == address(usdc)) {
                assertEq(assets[i].decimals, usdc.decimals());
                return;
            }
        }
        revert("Asset not found");
    }

    function test_getAssetDecimals_invalidAsset() public {
        address unregisteredAsset = makeAddr("unregistered");

        // Check asset is not registered
        assertFalse(nav.isAssetRegistered(unregisteredAsset));
    }

    function test_getAssetSymbol() public view {
        // Get asset info from registered assets
        INAVCalculator.Asset[] memory assets = nav.getRegisteredAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].asset == address(usdc)) {
                assertEq(assets[i].symbol, "USDC");
                return;
            }
        }
        revert("Asset not found");
    }

    function test_isAssetRegistered() public {
        assertTrue(nav.isAssetRegistered(address(usdc)));
        assertTrue(nav.isAssetRegistered(address(dai)));
        assertFalse(nav.isAssetRegistered(makeAddr("unregistered")));
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_setChainlinkL2SequencerGracePeriod_zeroPeriod() public {
        vm.startPrank(navCalculatorManager);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeed));

        vm.expectRevert(InvalidArguments.selector);
        nav.setChainlinkL2SequencerGracePeriod(0);
        vm.stopPrank();
    }

    function test_setChainlinkL2SequencerGracePeriod_noUptimeFeed() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(0)); // No uptime feed
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        vm.expectRevert(INAVCalculator.UptimeFeedNotSet.selector);
        nav.setChainlinkL2SequencerGracePeriod(2 hours);
        vm.stopPrank();
    }

    function test_setPriceFeed_assetNotRegistered() public {
        address unregisteredAsset = makeAddr("unregistered");

        vm.startPrank(navCalculatorManager);
        vm.expectRevert(AssetNotFound.selector);
        nav.setPriceFeed(unregisteredAsset, address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_setPriceFeed_zeroOracle() public {
        vm.startPrank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.setPriceFeed(address(usdc), address(0), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_addBalanceOracle_duplicate() public {
        vm.startPrank(navCalculatorManager);
        // ERC20DefaultOracle is already registered, try to add it again - should revert with DuplicateBalanceOracle
        address erc20Oracle = nav.erc20DefaultOracle();
        vm.expectRevert(IBalances.DuplicateBalanceOracle.selector);
        nav.addBalanceOracle(erc20Oracle);
        vm.stopPrank();
    }

    function test_removeBalanceOracle_invalidOracle() public {
        vm.startPrank(navCalculatorManager);
        address invalidOracle = makeAddr("invalid");

        vm.expectRevert(IBalances.InvalidBalanceOracle.selector);
        nav.removeBalanceOracle(invalidOracle);
        vm.stopPrank();
    }

    function test_removeBalanceOracle_nativeAddress() public {
        vm.startPrank(navCalculatorManager);
        address oracle = nav.erc20DefaultOracle();
        // Cannot remove ERC20DefaultOracle, it's protected
        vm.expectRevert(InvalidArguments.selector);
        nav.removeBalanceOracle(oracle);
        vm.stopPrank();
    }

    // Test 1: getAccountNav_emptyAccount
    function test_getAccountNav_emptyAccount() public {
        vm.roll(1);

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertEq(r.timestamp, block.timestamp);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
        assertEq(r.value, 0);

        vm.roll(2);
        r = nav.getAccountNav(safe, address(0));
        assertEq(r.timestamp, block.timestamp);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
        assertEq(r.value, 0);
    }

    // Test 2: getAccountNav_singleAsset
    function test_getAccountNav_singleAsset() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertEq(r.value, 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
        assertEq(r.timestamp, block.timestamp);
    }

    // Test 5: getAccountPositions_singlePosition
    function test_getAccountPositions_singlePosition() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        assertEq(positions.length, 1);
        INAVCalculator.Position memory p = positions[0];

        // Check core data
        assertEq(p.underlyingAsset.asset, address(usdc));
        assertEq(p.underlyingAsset.symbol, "USDC");
        assertEq(p.underlyingAsset.decimals, usdc.decimals());
        assertEq(p.amount, 10 ** usdc.decimals());
        assertFalse(p.isDebt, "Should be credit position");
        assertPositionMetadata(p, address(usdc), "wallet", "{\"protocol\":\"wallet\",\"product\":\"Holding\"}");

        // Check pricing data
        assertEq(p.quoteAsset.asset, address(0));
        assertEq(p.quoteAsset.symbol, "USD");
        assertEq(p.quoteAsset.decimals, 8);
        assertEq(p.value, 1e8);
        assertEq(p.price, 1e8);
        assertEq(p.priceDecimals, 8);
        assertEq(p.stale, false);
    }

    function test_getAccountNav_eth() public {
        vm.startPrank(navCalculatorManager);
        // Native address is already registered in setupNav(), only set price feed if not already set
        if (!nav.isAssetRegistered(address(nav.NATIVE_ADDRESS()))) {
            nav.registerAsset(
                address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else {
            // Only set price feed if not already set
            (address existingOracle,,,) = nav.priceOracles(address(nav.NATIVE_ADDRESS()));
            if (existingOracle == address(0)) {
                nav.setPriceFeed(
                    address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
                );
            }
        }
        vm.stopPrank();

        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertEq(r.value, 3_564_627_000_000);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
    }

    // Test 19: getAccountPositions_nativeToken
    function test_getAccountPositions_nativeToken() public {
        vm.startPrank(navCalculatorManager);
        // Native address is already registered in setupNav(), only set price feed if not already set
        if (!nav.isAssetRegistered(address(nav.NATIVE_ADDRESS()))) {
            nav.registerAsset(
                address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else {
            // Only set price feed if not already set
            (address existingOracle,,,) = nav.priceOracles(address(nav.NATIVE_ADDRESS()));
            if (existingOracle == address(0)) {
                nav.setPriceFeed(
                    address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
                );
            }
        }
        vm.stopPrank();
        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(positions.length, 1);

        INAVCalculator.Position memory p = positions[0];
        assertEq(p.underlyingAsset.asset, nav.NATIVE_ADDRESS());
        assertEq(p.underlyingAsset.symbol, "ETH");
        assertEq(p.underlyingAsset.decimals, 18);
        assertEq(p.amount, 11 ether);
        assertFalse(p.isDebt, "Should be credit position");
        assertPositionMetadata(p, nav.NATIVE_ADDRESS(), "wallet", "{\"protocol\":\"wallet\",\"product\":\"Holding\"}");
        assertEq(p.value, 3_564_627_000_000);
    }

    // Test 13: metadataConsistencyInvariant - custom oracle
    function test_getAccountPositions_customOracleMetadata() public {
        // Configure mockBalanceOracle for USDC
        setupMockBalanceOracle(address(usdc), int256(123 * 10 ** usdc.decimals()));

        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(mockBalanceOracle));
        vm.stopPrank();

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Find the position from custom oracle (should be index 1, but we'll search)
        bool found = false;
        for (uint256 i = 0; i < positions.length; i++) {
            if (keccak256(bytes(positions[i].protocol)) == keccak256(bytes("Mock Protocol"))) {
                INAVCalculator.Position memory p = positions[i];
                assertPositionMetadata(p, address(usdc), "Mock Protocol", "Mock Position");
                assertEq(p.underlyingAsset.symbol, "USDC");
                assertEq(p.underlyingAsset.decimals, usdc.decimals());
                assertEq(p.amount, 123 * 10 ** usdc.decimals());
                assertFalse(p.isDebt, "Should be credit position");
                assertEq(p.value, 123e8);
                assertEq(p.price, 1e8);
                assertEq(p.priceDecimals, 8);
                assertEq(p.stale, false);
                found = true;
                break;
            }
        }
        assertTrue(found, "Custom oracle position not found");
    }

    // Test 3: getAccountNav_multipleAssets
    function test_getAccountNav_multipleAssets() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());
        weth.mint(safe, 10 ** weth.decimals());

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        // USDC: 1e8, DAI: 1e8, WETH: ~3240e8
        assertApproxEqRel(r.value, 3242e8, 0.01 ether);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
    }

    // Test 6: getAccountPositions_multiplePositions
    function test_getAccountPositions_multiplePositions() public {
        dai.mint(safe, 10 ** dai.decimals());

        // Configure mockBalanceOracle for DAI
        setupMockBalanceOracle(address(dai), int256(456 * 10 ** dai.decimals()));

        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(mockBalanceOracle));
        vm.stopPrank();

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));

        // Should have 2 positions: ERC20 DAI and Custom oracle DAI
        assertEq(positions.length, 2);

        // Verify both positions are for DAI
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, address(dai));
            assertTrue(positions[i].amount != 0);
        }

        // Verify NAV matches sum
        int256 sum = sumPositionValues(positions);
        assertEq(navTotal.value, sum);
    }

    // Test 18: getAccountPositions_sequencerDown
    function test_getAccountPositions_sequencerDown() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeedDown));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        // ERC20DefaultOracle is already registered globally, no need to add it again
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertEq(r.value, 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, true);

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(r.sequencerDown, true);
        assertEq(positions.length, 1);
        // Note: sequencerDown is on the NAV struct, not per-position
        assertEq(positions[0].stale, false);
    }

    // Test 16: getAccountPositions_multipleBalancesSameAsset
    function test_getAccountPositions_multipleBalancesSameAsset() public {
        Mock_CustomBalanceOracle stakingBalanceOracle = new Mock_CustomBalanceOracle();
        stakingBalanceOracle.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        stakingBalanceOracle.setUnderlyingAssetsSupported(assets);
        stakingBalanceOracle.setPositionMetadata("Staking", "Staked USDC");
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(stakingBalanceOracle));
        vm.stopPrank();

        // mint 1 USDC to both the safe and the custom oracle
        stakingBalanceOracle.setBalance(address(usdc), safe, 10 ** usdc.decimals(), false);
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertEq(r.value, 2 * 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(positions.length, 2);

        // Both positions should be for USDC
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].underlyingAsset.asset, address(usdc));
        }

        // Sum should match NAV
        int256 sum = sumPositionValues(positions);
        assertEq(r.value, sum);
    }

    // Test 15: getAccountPositions_negativeBalances
    function test_getAccountPositions_negativeBalances() public {
        Mock_CustomBalanceOracle stakingBalanceOracle = new Mock_CustomBalanceOracle();
        stakingBalanceOracle.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        stakingBalanceOracle.setUnderlyingAssetsSupported(assets);
        stakingBalanceOracle.setPositionMetadata("Debt", "Borrowed USDC");
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(stakingBalanceOracle));

        //Set the custom oracle to -1 USDC  and  mint 1 USDC to the safe
        stakingBalanceOracle.setBalance(address(usdc), safe, 10 ** usdc.decimals(), true);
        vm.stopPrank();
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertEq(r.value, 0 * 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(positions.length, 2);

        // One position should be negative
        bool foundNegative = false;
        bool foundPositive = false;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isDebt) {
                assertTrue(positions[i].value <= 0);
                foundNegative = true;
            } else {
                foundPositive = true;
            }
        }
        assertTrue(foundNegative, "Negative position not found");
        assertTrue(foundPositive, "Positive position not found");

        // Sum should match NAV
        int256 sum = sumPositionValues(positions);
        assertEq(r.value, sum);
    }

    // Test 4: getAccountPositions_emptyAccount
    function test_getAccountPositions_emptyAccount() public {
        vm.startPrank(navCalculatorManager);
        nav.unregisterAsset(address(usdc));
        nav.unregisterAsset(address(dai));
        nav.unregisterAsset(address(weth));
        // Native address is still registered, so unregister it too
        nav.unregisterAsset(nav.NATIVE_ADDRESS());
        vm.stopPrank();

        assertEq(nav.assetCount(), 0);

        INAVCalculator.NAV memory n = nav.getAccountNav(safe, address(0));
        assertEq(n.value, 0);
        assertEq(n.stalePriceAssets.length, 0);
        assertEq(n.sequencerDown, false);
        assertEq(n.timestamp, block.timestamp);

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertEq(positions.length, 0);
        assertEq(navTotal.value, 0);
        assertEq(navTotal.timestamp, block.timestamp);
    }

    function test_setChainlinkUptimeFeed() public {
        assertEq(address(nav.chainlinkL2SequencerUptimeFeed()), address(sequencerUptimeFeed));

        vm.prank(navCalculatorManager);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeedDown));

        assertEq(address(nav.chainlinkL2SequencerUptimeFeed()), address(sequencerUptimeFeedDown));
    }

    function test_setChainlinkUptimeFeed_notAuthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeedDown));
    }

    function test_setSequencerGracePeriod() public {
        assertEq(nav.chainlinkL2SequencerGracePeriod(), 1 hours);

        vm.startPrank(navCalculatorManager);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeed));
        nav.setChainlinkL2SequencerGracePeriod(2 hours);

        assertEq(nav.chainlinkL2SequencerGracePeriod(), 2 hours);
    }

    function test_setSequencerGracePeriod_notAuthorized() public {
        vm.startPrank(alice);
        vm.expectRevert();
        nav.setChainlinkL2SequencerGracePeriod(2 hours);
    }

    function test_setChainlinkUptimeFeed_toAddressZero() public {
        // This test verifies that setting the sequencer feed to address(0) is allowed
        // This is the correct configuration for chains without sequencers (mainnet, Gnosis)
        assertEq(address(nav.chainlinkL2SequencerUptimeFeed()), address(sequencerUptimeFeed));

        // Set to address(0) - should work for L1 chains
        vm.prank(navCalculatorManager);
        nav.setChainlinkL2SequencerUptimeFeed(address(0));

        assertEq(address(nav.chainlinkL2SequencerUptimeFeed()), address(0));

        // Verify checkL2SequencerUptime returns false (not stale) when feed is address(0)
        bool stale = nav.checkL2SequencerUptime();
        assertFalse(stale);

        // Verify latestPrice still works correctly without sequencer check
        usdc.mint(safe, 10 ** usdc.decimals());
        (int256 price, uint8 decimals, bool priceStale) = nav.latestPrice(address(usdc));
        assertEq(price, 1e8);
        assertEq(decimals, 8);
        assertFalse(priceStale);

        // Verify getAccountNav works correctly
        INAVCalculator.NAV memory navReading = nav.getAccountNav(safe, address(0));
        assertEq(navReading.value, 1e8);
        assertFalse(navReading.sequencerDown);

        // Verify that trying to set grace period now reverts (because feed is address(0))
        vm.startPrank(navCalculatorManager);
        vm.expectRevert(INAVCalculator.UptimeFeedNotSet.selector);
        nav.setChainlinkL2SequencerGracePeriod(2 hours);
        vm.stopPrank();
    }

    // ============================================
    // B. Currency Conversion Tests
    // ============================================

    // Test 7: getAccountPositions_usdDefault
    function test_getAccountPositions_usdDefault() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        assertEq(positions.length, 1);
        INAVCalculator.Position memory p = positions[0];

        assertEq(p.quoteAsset.asset, address(0));
        assertEq(p.quoteAsset.symbol, "USD");
        assertEq(p.quoteAsset.decimals, 8);
        assertEq(p.price, 1e8);
        assertEq(p.priceDecimals, 8);
    }

    // Test 8: getAccountPositions_ethQuoteAsset
    function test_getAccountPositions_ethQuoteAsset() public {
        vm.startPrank(navCalculatorManager);
        // Native address is already registered in setupNav(), only set price feed if not already set
        if (!nav.isAssetRegistered(address(nav.NATIVE_ADDRESS()))) {
            nav.registerAsset(
                address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else {
            // Only set price feed if not already set
            (address existingOracle,,,) = nav.priceOracles(address(nav.NATIVE_ADDRESS()));
            if (existingOracle == address(0)) {
                nav.setPriceFeed(
                    address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
                );
            }
        }
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, nav.NATIVE_ADDRESS());

        assertEq(positions.length, 1);
        INAVCalculator.Position memory p = positions[0];

        assertEq(p.quoteAsset.asset, nav.NATIVE_ADDRESS());
        assertEq(p.quoteAsset.symbol, "ETH");
        assertEq(p.quoteAsset.decimals, 18);
        // Value should be converted to ETH (1 USDC / ETH price)
        assertTrue(p.value > 0);
        assertTrue(p.price > 0);
    }

    // Test 9: getAccountPositions_customQuoteAsset
    function test_getAccountPositions_customQuoteAsset() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(dai));

        assertEq(positions.length, 1);
        INAVCalculator.Position memory p = positions[0];

        assertEq(p.quoteAsset.asset, address(dai));
        assertEq(p.quoteAsset.symbol, "DAI");
        assertEq(p.quoteAsset.decimals, dai.decimals());
        // Value should be converted to DAI
        assertTrue(p.value > 0);
    }

    // Test 10: getAccountPositions_currencyConversionReversibility
    function test_getAccountPositions_currencyConversionReversibility() public {
        vm.startPrank(navCalculatorManager);
        // Native address is already registered in setupNav(), only set price feed if not already set
        if (!nav.isAssetRegistered(address(nav.NATIVE_ADDRESS()))) {
            nav.registerAsset(
                address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else {
            // Only set price feed if not already set
            (address existingOracle,,,) = nav.priceOracles(address(nav.NATIVE_ADDRESS()));
            if (existingOracle == address(0)) {
                nav.setPriceFeed(
                    address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
                );
            }
        }
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());

        // Get positions in USD
        INAVCalculator.Position[] memory usdPositions = nav.getAccountPositions(safe, address(0));
        int256 usdValue = usdPositions[0].value;

        // Get positions in ETH
        INAVCalculator.Position[] memory ethPositions = nav.getAccountPositions(safe, nav.NATIVE_ADDRESS());
        int256 ethValue = ethPositions[0].value;

        // Convert ETH value back to USD using the rate
        // ethValue is in ETH with 18 decimals, we need to convert back
        // Get ETH price
        (int256 ethPrice, uint8 ethPriceDecimals,) = nav.latestPrice(nav.NATIVE_ADDRESS());
        // Convert: ethValue * ethPrice / 10^(18 + ethPriceDecimals - 8)
        int256 convertedBack = (ethValue * int256(ethPrice)) / int256(10 ** (18 + ethPriceDecimals - 8));

        // Allow 0.01% tolerance for rounding
        assertApproxEqRel(usdValue, convertedBack, 0.0001 ether);
    }

    // ============================================
    // C. Invariant Verification Tests
    // ============================================

    // Test 11: navConsistencyInvariant
    function test_navConsistencyInvariant() public {
        // Test with empty account
        INAVCalculator.NAV memory nav1 = nav.getAccountNav(safe, address(0));
        INAVCalculator.Position[] memory positions1 = nav.getAccountPositions(safe, address(0));
        assertEq(nav1.value, sumPositionValues(positions1));

        // Test with single asset
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.NAV memory nav2 = nav.getAccountNav(safe, address(0));
        INAVCalculator.Position[] memory positions2 = nav.getAccountPositions(safe, address(0));
        assertEq(nav2.value, sumPositionValues(positions2));

        // Test with multiple assets
        dai.mint(safe, 10 ** dai.decimals());
        weth.mint(safe, 10 ** weth.decimals());
        INAVCalculator.NAV memory nav3 = nav.getAccountNav(safe, address(0));
        INAVCalculator.Position[] memory positions3 = nav.getAccountPositions(safe, address(0));
        assertEq(nav3.value, sumPositionValues(positions3));

        // Test with negative balances
        Mock_CustomBalanceOracle debtOracle = new Mock_CustomBalanceOracle();
        debtOracle.setBalances(IBalances(address(nav)));
        address[] memory debtAssets = new address[](1);
        debtAssets[0] = address(usdc);
        debtOracle.setUnderlyingAssetsSupported(debtAssets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(debtOracle));
        debtOracle.setBalance(address(usdc), safe, 10 ** usdc.decimals(), true);
        vm.stopPrank();

        INAVCalculator.NAV memory nav4 = nav.getAccountNav(safe, address(0));
        INAVCalculator.Position[] memory positions4 = nav.getAccountPositions(safe, address(0));
        assertEq(nav4.value, sumPositionValues(positions4));
    }

    // Test 12: positionCompletenessInvariant
    function test_positionCompletenessInvariant() public {
        // Setup: some zero balances, some non-zero
        usdc.mint(safe, 10 ** usdc.decimals());
        // dai has zero balance
        // weth has zero balance

        Mock_CustomBalanceOracle customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        customOracle.setUnderlyingAssetsSupported(assets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(customOracle));
        customOracle.setBalance(address(usdc), safe, 0, false); // Zero balance
        vm.stopPrank();

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Should only have 1 position (ERC20 USDC), not the zero custom oracle position
        assertEq(positions.length, 1);
        assertEq(positions[0].underlyingAsset.asset, address(usdc));
        assertTrue(positions[0].amount != 0);

        // Verify no zero positions
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount != 0, "Zero position found");
        }
    }

    // Test 13: metadataConsistencyInvariant (partially covered above, adding comprehensive test)
    function test_metadataConsistencyInvariant() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        // Test ERC20 oracle metadata
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.Position memory erc20Pos = positions[0];
        assertPositionMetadata(erc20Pos, address(usdc), "wallet", "{\"protocol\":\"wallet\",\"product\":\"Holding\"}");

        // Configure mockBalanceOracle for USDC
        setupMockBalanceOracle(address(usdc), int256(123 * 10 ** usdc.decimals()));

        // Test custom oracle metadata
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(mockBalanceOracle));
        vm.stopPrank();

        INAVCalculator.Position[] memory positions2 = nav.getAccountPositions(safe, address(0));
        bool foundCustom = false;
        for (uint256 i = 0; i < positions2.length; i++) {
            if (keccak256(bytes(positions2[i].protocol)) == keccak256(bytes("Mock Protocol"))) {
                assertPositionMetadata(positions2[i], address(usdc), "Mock Protocol", "Mock Position");
                foundCustom = true;
            }
        }
        assertTrue(foundCustom, "Custom oracle position not found");
    }

    // ============================================
    // D. Edge Cases
    // ============================================

    // Test 14: getAccountPositions_zeroBalancesExcluded
    function test_getAccountPositions_zeroBalancesExcluded() public {
        // No minting - all balances are zero
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(positions.length, 0);

        // Add a custom oracle with zero balance
        Mock_CustomBalanceOracle zeroOracle = new Mock_CustomBalanceOracle();
        zeroOracle.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        zeroOracle.setUnderlyingAssetsSupported(assets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(zeroOracle));
        zeroOracle.setBalance(address(usdc), safe, 0, false);
        vm.stopPrank();

        INAVCalculator.Position[] memory positions2 = nav.getAccountPositions(safe, address(0));
        assertEq(positions2.length, 0);
    }

    // Test 17: getAccountPositions_stalePrices
    function test_getAccountPositions_stalePrices() public {
        // Create a stale price oracle with short heartbeat
        Mock_PriceOracleChainlink staleOracle = new Mock_PriceOracleChainlink("Stale", 1, 8);
        vm.startPrank(navCalculatorManager);
        // USDC is already registered, just update the price oracle with short heartbeat
        nav.setPriceFeed(address(usdc), address(staleOracle), IPrices.PriceType.Chainlink, 1); // 1 second heartbeat
        vm.stopPrank();

        // Make price stale by warping time
        vm.warp(block.timestamp + 2);

        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertTrue(r.stalePriceAssets.length > 0);
        assertEq(r.stalePriceAssets[0].asset, address(usdc));

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertEq(navTotal.stalePriceAssets.length, 1);
        assertEq(navTotal.stalePriceAssets[0].asset, address(usdc));

        // All positions for stale asset should be marked stale
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].underlyingAsset.asset == address(usdc)) {
                assertTrue(positions[i].stale, "Position not marked stale");
            }
        }
    }

    // Test 20: getAccountPositions_assetWithoutPriceFeed
    function test_getAccountPositions_assetWithoutPriceFeed() public {
        // Create a new token that's not in setUp
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        Mock_CustomPriceFeed newTokenOracle = new Mock_CustomPriceFeed("NEW", address(newToken), 1e8, 8);

        vm.startPrank(navCalculatorManager);
        // Asset must be registered with a price feed - this is now required
        nav.registerAsset(address(newToken), address(newTokenOracle), IPrices.PriceType.Custom, type(uint256).max);
        // ERC20DefaultOracle is already registered globally, no need to add it again
        vm.stopPrank();

        newToken.mint(safe, 10 ** newToken.decimals());

        // Should work now that asset is registered with price feed
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        // Asset should be included since it has a price feed
        bool found = false;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].underlyingAsset.asset == address(newToken)) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Asset with price feed should be included");
    }

    function test_getAccountPositions_unregisteredAsset() public {
        // Create a new token that's not registered at all
        Mock_ERC20 unregisteredToken = new Mock_ERC20("UNREG", 18);

        // Mint tokens to simulate a balance
        unregisteredToken.mint(safe, 10 ** unregisteredToken.decimals());

        // Should not revert, but skip unregistered asset (it's filtered out before price fetching)
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        // Unregistered asset should not be included
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(
                positions[i].underlyingAsset.asset != address(unregisteredToken), "Unregistered asset should be skipped"
            );
        }
    }

    // ============================================
    // E. Error Cases
    // ============================================

    // Test 21: getAccountPositions_invalidQuoteAsset
    function test_getAccountPositions_invalidQuoteAsset() public {
        // Use a non-registered address
        address invalidCurrency = makeAddr("invalid");

        // Implementation checks price feed first, not asset registration
        vm.expectRevert(abi.encodeWithSelector(PriceFeedNotSet.selector, invalidCurrency));
        nav.getAccountPositions(safe, invalidCurrency);

        // Create a new token, register it with price oracle
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        Mock_CustomPriceFeed newTokenOracle = new Mock_CustomPriceFeed("NEW", address(newToken), 1e8, 8);
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(newToken), address(newTokenOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
        nav.getAccountPositions(safe, address(newToken));
    }

    // ============================================
    // F. Data Structure Tests
    // ============================================

    // Test 23: getAccountPositions_structureCompleteness
    function test_getAccountPositions_structureCompleteness() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        assertEq(positions.length, 1);
        INAVCalculator.Position memory p = positions[0];

        // Check Position completeness
        assertTrue(p.underlyingAsset.asset != address(0));
        assertTrue(bytes(p.underlyingAsset.symbol).length > 0);
        assertTrue(p.underlyingAsset.decimals > 0);
        assertTrue(bytes(p.protocol).length > 0);
        assertTrue(bytes(p.positionDetail).length > 0);

        // Check pricing completeness
        assertTrue(bytes(p.quoteAsset.symbol).length > 0);
        assertTrue(p.quoteAsset.decimals > 0);
        assertTrue(p.price > 0);
        assertTrue(p.priceDecimals > 0);
    }

    // Test 24: getAccountPositions_rateCalculation
    function test_getAccountPositions_rateCalculation() public {
        uint256 usdcBalance = 10 ** usdc.decimals();
        usdc.mint(safe, usdcBalance);

        // Test USD rate
        INAVCalculator.Position[] memory usdPositions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.Position memory usdPos = usdPositions[0];
        assertEq(usdPos.underlyingAsset.asset, address(usdc));
        (int256 priceInUsd, uint8 usdPriceDecimals,) = nav.latestPrice(address(usdc));
        assertEq(usdPos.price, priceInUsd);
        assertEq(usdPos.priceDecimals, usdPriceDecimals);

        // Test ETH rate
        vm.startPrank(navCalculatorManager);
        // Native address is already registered in setupNav(), only set price feed if not already set
        if (!nav.isAssetRegistered(address(nav.NATIVE_ADDRESS()))) {
            nav.registerAsset(
                address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else {
            // Only set price feed if not already set
            (address existingOracle,,,) = nav.priceOracles(address(nav.NATIVE_ADDRESS()));
            if (existingOracle == address(0)) {
                nav.setPriceFeed(
                    address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
                );
            }
        }
        vm.stopPrank();

        INAVCalculator.Position[] memory ethPositions = nav.getAccountPositions(safe, nav.NATIVE_ADDRESS());
        INAVCalculator.Position memory ethPos = ethPositions[0];
        (int256 priceInEth, uint8 ethPriceDecimals,) = nav.latestPrice(nav.NATIVE_ADDRESS());
        assertGe(priceInEth, 0, "price non-negative");
        assertLe(ethPriceDecimals, 255, "decimals valid");

        // Verify underlying asset is still USDC (what we hold)
        assertEq(ethPos.underlyingAsset.asset, address(usdc));
        assertEq(usdPos.underlyingAsset.asset, address(usdc));

        // Verify quote asset is ETH (the quote currency)
        assertEq(ethPos.quoteAsset.asset, nav.NATIVE_ADDRESS());
        assertEq(usdPos.quoteAsset.asset, address(0)); // USD quote

        // Price should be the USD price of the underlying asset (USDC), not the quote currency price
        // The price field always represents the USD price of the underlying asset
        assertEq(ethPos.price, priceInUsd);
        assertEq(ethPos.priceDecimals, usdPriceDecimals);

        // Value should be converted from USD to ETH using the contract's conversion logic
        assertTrue(ethPos.value > 0, "ETH quote value should be positive");
    }

    // ============================================
    // G. Integration with Existing Features
    // ============================================

    // Test 25: getAccountNav_healthCheckConsistency
    function test_getAccountNav_healthCheckConsistency() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        (bool sequencerDown, address[] memory stalePriceAssets) = nav.healthCheck();
        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));

        assertEq(r.sequencerDown, sequencerDown);
        assertEq(r.stalePriceAssets.length, stalePriceAssets.length);
        for (uint256 i = 0; i < r.stalePriceAssets.length; i++) {
            assertEq(r.stalePriceAssets[i].asset, stalePriceAssets[i]);
        }
    }

    // Test 26: getAccountPositions_hasPositionsConsistency
    function test_getAccountPositions_hasPositionsConsistency() public {
        // Empty account
        assertFalse(nav.hasPositions(safe));
        INAVCalculator.Position[] memory empty = nav.getAccountPositions(safe, address(0));
        assertEq(empty.length, 0);

        // Account with positions
        usdc.mint(safe, 10 ** usdc.decimals());
        assertTrue(nav.hasPositions(safe));
        INAVCalculator.Position[] memory withPositions = nav.getAccountPositions(safe, address(0));
        assertTrue(withPositions.length > 0);
    }

    // ============================================
    // H. calculateValue Tests (positive balances only)
    // ============================================

    function test_calculateValue_singleAsset_usd() public view {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = address(usdc);
        amounts[0] = 10 ** usdc.decimals();

        int256 value = nav.calculateValue(assets, amounts, address(0));
        assertEq(value, 1e8); // 1 USDC = 1 USD (8 decimals)
    }

    function test_calculateValue_multipleAssets_usd() public view {
        address[] memory assets = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        assets[0] = address(usdc);
        amounts[0] = 10 ** usdc.decimals();
        assets[1] = address(dai);
        amounts[1] = 10 ** dai.decimals();
        assets[2] = address(weth);
        amounts[2] = 10 ** weth.decimals();

        int256 value = nav.calculateValue(assets, amounts, address(0));
        assertApproxEqRel(value, 3242e8, 0.01 ether);
    }

    function test_calculateValue_quoteAsset() public view {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = address(usdc);
        amounts[0] = 10 ** usdc.decimals();

        int256 valueInDai = nav.calculateValue(assets, amounts, address(dai));
        assertApproxEqRel(valueInDai, int256(10 ** dai.decimals()), 0.01 ether);
    }

    function test_calculateValue_zeroAmountsSkipped() public view {
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        assets[0] = address(usdc);
        amounts[0] = 0;
        assets[1] = address(dai);
        amounts[1] = 10 ** dai.decimals();

        int256 value = nav.calculateValue(assets, amounts, address(0));
        assertEq(value, 1e8);
    }

    function test_calculateValue_arrayLengthMismatch() public {
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        amounts[0] = 10 ** usdc.decimals();

        vm.expectRevert(ArrayLengthMismatch.selector);
        nav.calculateValue(assets, amounts, address(0));
    }

    function test_calculateValue_assetNotFound() public {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = makeAddr("invalid");
        amounts[0] = 1e18;

        vm.expectRevert(AssetNotFound.selector);
        nav.calculateValue(assets, amounts, address(0));
    }

    function test_calculateValue_invalidQuoteAsset() public {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = address(usdc);
        amounts[0] = 10 ** usdc.decimals();

        vm.expectRevert(AssetNotFound.selector);
        nav.calculateValue(assets, amounts, makeAddr("invalid"));
    }

    // ============================================
    // I. getAssetsWithPositions Tests
    // ============================================

    // Test getAssetsWithPositions_emptyAccount
    function test_getAssetsWithPositions_emptyAccount() public view {
        address[] memory assets = nav.getAssetsWithPositions(safe);
        assertEq(assets.length, 0);
    }

    // Test getAssetsWithPositions_singleAsset
    function test_getAssetsWithPositions_singleAsset() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        address[] memory assets = nav.getAssetsWithPositions(safe);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(usdc));
    }

    // Test getAssetsWithPositions_multipleAssets
    function test_getAssetsWithPositions_multipleAssets() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());
        weth.mint(safe, 10 ** weth.decimals());

        address[] memory assets = nav.getAssetsWithPositions(safe);
        assertEq(assets.length, 3);

        // Check all expected assets are present
        bool foundUsdc = false;
        bool foundDai = false;
        bool foundWeth = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(usdc)) foundUsdc = true;
            if (assets[i] == address(dai)) foundDai = true;
            if (assets[i] == address(weth)) foundWeth = true;
        }
        assertTrue(foundUsdc);
        assertTrue(foundDai);
        assertTrue(foundWeth);
    }

    // Test getAssetsWithPositions_skipsEmptyAssets
    function test_getAssetsWithPositions_skipsEmptyAssets() public {
        // Mint only USDC, not DAI
        usdc.mint(safe, 10 ** usdc.decimals());

        address[] memory assets = nav.getAssetsWithPositions(safe);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(usdc));

        // DAI should not be in the list
        for (uint256 i = 0; i < assets.length; i++) {
            assertTrue(assets[i] != address(dai));
        }
    }

    // Test getAssetsWithPositions_consistencyWithHasPositions
    function test_getAssetsWithPositions_consistencyWithHasPositions() public {
        // Empty account
        assertFalse(nav.hasPositions(safe));
        address[] memory emptyAssets = nav.getAssetsWithPositions(safe);
        assertEq(emptyAssets.length, 0);

        // Account with positions
        usdc.mint(safe, 10 ** usdc.decimals());
        assertTrue(nav.hasPositions(safe));
        address[] memory assets = nav.getAssetsWithPositions(safe);
        assertTrue(assets.length > 0);
    }

    // Test getAssetsWithPositions_consistencyWithGetAllPositions
    function test_getAssetsWithPositions_consistencyWithGetAllPositions() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());

        address[] memory assets = nav.getAssetsWithPositions(safe);
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // All assets with positions should have corresponding positions in getAllPositions
        for (uint256 i = 0; i < assets.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < positions.length; j++) {
                if (positions[j].underlyingAsset.asset == assets[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Asset from getAssetsWithPositions not found in getAllPositions");
        }

        // All positions in getAllPositions should be from assets in getAssetsWithPositions
        for (uint256 i = 0; i < positions.length; i++) {
            address positionAsset = positions[i].underlyingAsset.asset;
            bool found = false;
            for (uint256 j = 0; j < assets.length; j++) {
                if (assets[j] == positionAsset) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Position from getAllPositions not found in getAssetsWithPositions");
        }
    }

    // Test getAssetsWithPositions_multipleBalanceOracles
    function test_getAssetsWithPositions_multipleBalanceOracles() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        // Add a custom balance oracle for USDC
        Mock_CustomBalanceOracle customOracle = new Mock_CustomBalanceOracle();
        customOracle.setBalances(IBalances(address(nav)));
        address[] memory oracleAssets = new address[](1);
        oracleAssets[0] = address(usdc);
        customOracle.setUnderlyingAssetsSupported(oracleAssets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(customOracle));
        customOracle.setBalance(address(usdc), safe, 5 * 10 ** (usdc.decimals() - 1), false);
        vm.stopPrank();

        address[] memory assetsWithPos = nav.getAssetsWithPositions(safe);
        // Should still return USDC (has positions from both oracles)
        assertEq(assetsWithPos.length, 1);
        assertEq(assetsWithPos[0], address(usdc));
    }

    // Test getAssetsWithPositions_allZeroBalances
    function test_getAssetsWithPositions_allZeroBalances() public {
        // Add a custom oracle with zero balance
        Mock_CustomBalanceOracle zeroOracle = new Mock_CustomBalanceOracle();
        zeroOracle.setBalances(IBalances(address(nav)));
        address[] memory oracleAssets = new address[](1);
        oracleAssets[0] = address(usdc);
        zeroOracle.setUnderlyingAssetsSupported(oracleAssets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceOracle(address(zeroOracle));
        zeroOracle.setBalance(address(usdc), safe, 0, false);
        vm.stopPrank();

        address[] memory assetsWithPos = nav.getAssetsWithPositions(safe);
        // Should not include USDC since all balances are zero
        for (uint256 i = 0; i < assetsWithPos.length; i++) {
            assertTrue(assetsWithPos[i] != address(usdc));
        }
    }

    // ============================================
    // J. Gas Optimization Benchmarks
    // ============================================

    // Test gas optimization: getAccountPositions with many empty assets
    function test_getAccountPositions_gasOptimization_manyEmptyAssets() public {
        // Create many assets but only mint to 2
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());

        // Register additional assets without minting (they will be empty)
        Mock_ERC20 token3 = new Mock_ERC20("T3", 18);
        Mock_ERC20 token4 = new Mock_ERC20("T4", 18);
        Mock_ERC20 token5 = new Mock_ERC20("T5", 18);

        // Create price oracles for the new tokens
        Mock_PriceOracleChainlink token3Oracle = new Mock_PriceOracleChainlink("T3", 1, 8);
        Mock_PriceOracleChainlink token4Oracle = new Mock_PriceOracleChainlink("T4", 1, 8);
        Mock_PriceOracleChainlink token5Oracle = new Mock_PriceOracleChainlink("T5", 1, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token3), address(token3Oracle), IPrices.PriceType.Chainlink, type(uint256).max);
        // ERC20DefaultOracle is already registered globally, no need to add it again

        nav.registerAsset(address(token4), address(token4Oracle), IPrices.PriceType.Chainlink, type(uint256).max);
        // ERC20DefaultOracle is already registered globally, no need to add it again

        nav.registerAsset(address(token5), address(token5Oracle), IPrices.PriceType.Chainlink, type(uint256).max);
        // ERC20DefaultOracle is already registered globally, no need to add it again
        vm.stopPrank();

        // Measure gas for getAllPositions (should skip empty assets)
        uint256 gasBefore = gasleft();
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        uint256 gasUsed = gasBefore - gasleft();

        // Verify correctness
        assertEq(positions.length, 2); // Only USDC and DAI
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertTrue(navTotal.value > 0);

        // Verify getAssetsWithPositions returns only assets with positions
        address[] memory assetsWithPos = nav.getAssetsWithPositions(safe);
        assertEq(assetsWithPos.length, 2);

        // Gas should be reasonable (optimization should help)
        // This is a sanity check - actual savings depend on number of empty assets
        assertTrue(gasUsed < 500000, "Gas usage seems too high");
    }

    // Test gas optimization: verify getAccountPositions still works correctly
    function test_getAccountPositions_optimization_correctness() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());

        // Get assets with positions
        address[] memory assetsWithPos = nav.getAssetsWithPositions(safe);
        assertEq(assetsWithPos.length, 2);

        // Get all positions
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Verify NAV matches
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertTrue(navTotal.value > 0);

        // Verify positions match assets
        assertEq(positions.length, 2);

        // Verify each asset from getAssetsWithPositions has a position
        for (uint256 i = 0; i < assetsWithPos.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < positions.length; j++) {
                if (positions[j].underlyingAsset.asset == assetsWithPos[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found);
        }
    }

    // Test gas optimization: empty account should be very cheap
    function test_getAccountPositions_gasOptimization_emptyAccount() public view {
        uint256 gasBefore = gasleft();
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        uint256 gasUsed = gasBefore - gasleft();

        // Should return empty results quickly
        assertEq(positions.length, 0);
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertEq(navTotal.value, 0);

        // Should be very cheap (just helper call + early return)
        assertTrue(gasUsed < 100000, "Empty account should be very cheap");
    }
}
