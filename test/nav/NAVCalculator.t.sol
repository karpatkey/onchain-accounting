// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {aa} from "test/helpers/AdapterArray.sol";

contract NAVCalculatorHarness is NAVCalculator {
    constructor(address admin, address chainlinkUptimeFeed, string memory nativeTokenSymbol) {
        this.initialize(admin, chainlinkUptimeFeed, nativeTokenSymbol);
    }
}

/// @notice Balance adapter whose read methods always revert.
/// @dev Used to prove `hasPositions` is fail-open: a single misbehaving adapter must not DoS the scan.
///      Reverts on both `getAdapterPositions` (the path `hasPositions` reads) and `getAdapterBalances`.
contract RevertingBalanceAdapter is IBalanceAdapter {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function underlyingAssetsSupported() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function getAdapterBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (0, false);
    }

    function getAdapterBalances(address)
        external
        pure
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        revert("boom");
    }

    function getAdapterPositions(address, address)
        external
        pure
        override
        returns (INAVCalculator.PositionBalance[] memory)
    {
        revert("boom");
    }
}

contract NAVCalculatorTest is SuperTest {
    Mock_PriceOracleChainlink public chainlinkOracle;

    Mock_CustomBalanceAdapter public depositedWethAdapter;

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

    /// @notice Helper function to configure mockBalanceAdapter with specific assets
    /// @param assets Array of asset addresses to configure
    /// @param balances Optional array of balances for each asset (same length as assets, or empty for defaults)
    /// @param protocol Optional protocol name (defaults to "Mock Protocol")
    /// @param position Optional position name (defaults to "Mock Position")
    function setupMockBalanceAdapter(
        address[] memory assets,
        int256[] memory balances,
        string memory protocol,
        string memory position
    ) internal {
        // Set balances reference if nav is available
        mockBalanceAdapter.setBalances(IBalances(address(nav)));

        // Set underlying assets supported
        mockBalanceAdapter.setUnderlyingAssetsSupported(assets);

        // Set balances for each asset (use provided balances or defaults)
        for (uint256 i = 0; i < assets.length; i++) {
            int256 balance = balances.length > i ? balances[i] : int256(0);
            if (balance >= 0) {
                mockBalanceAdapter.setBalance(assets[i], safe, SafeCast.toUint256(balance), false);
            } else {
                mockBalanceAdapter.setBalance(assets[i], safe, SafeCast.toUint256(-balance), true);
            }
        }

        // Set position metadata
        mockBalanceAdapter.setPositionMetadata(
            bytes(protocol).length > 0 ? protocol : "Mock Protocol",
            bytes(position).length > 0 ? position : "Mock Position"
        );
    }

    /// @notice Convenience overload for single asset
    function setupMockBalanceAdapter(address asset, int256 balance) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        int256[] memory balances = new int256[](1);
        balances[0] = balance;
        // Note: setupMockBalanceAdapter still uses int256[] for backward compatibility
        setupMockBalanceAdapter(assets, balances, "", "");
    }

    function findPositionByAsset(INAVCalculator.Position[] memory positions, address asset)
        internal
        pure
        returns (INAVCalculator.Position memory, bool)
    {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAsset.asset == asset) {
                // Check if this matches the balance adapter index by checking metadata
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
        string memory, /* expectedProtocol — replaced by protocolId in new struct */
        string memory /* expectedPositionDetail — replaced by positionKind in new struct */
    ) internal pure {
        assertEq(pos.balanceAsset.asset, expectedAsset, "Asset mismatch");
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

        IPrices.PriceFeedConfig memory cfg_ = nav.getPriceFeedAt(address(usdc), 0);
        assertEq(cfg_.priceFeed, address(usdcAdapter));
        assertEq(cfg_.decimals, 8);
        assertEq(cfg_.chainlinkHeartbeat, type(uint256).max);
        assertEq(uint8(cfg_.priceType), uint8(IPrices.PriceType.Custom));

        cfg_ = nav.getPriceFeedAt(address(dai), 0);
        assertEq(cfg_.priceFeed, address(daiAdapter));
        assertEq(cfg_.decimals, 8);
        assertEq(cfg_.chainlinkHeartbeat, 86_400);
        assertEq(uint8(cfg_.priceType), uint8(IPrices.PriceType.Chainlink));

        cfg_ = nav.getPriceFeedAt(address(weth), 0);
        assertEq(cfg_.priceFeed, address(wethAdapter));
        assertEq(cfg_.decimals, 8);
        assertEq(cfg_.chainlinkHeartbeat, type(uint256).max);
        assertEq(uint8(cfg_.priceType), uint8(IPrices.PriceType.Custom));

        cfg_ = nav.getPriceFeedAt(nav.NATIVE_ADDRESS(), 0);
        assertEq(cfg_.priceFeed, address(ethAdapter));
        assertEq(cfg_.decimals, 8);
        assertEq(cfg_.chainlinkHeartbeat, type(uint256).max);
        assertEq(uint8(cfg_.priceType), uint8(IPrices.PriceType.Chainlink));

        // Configure mockBalanceAdapter with all three assets
        address[] memory mockAssets = new address[](3);
        mockAssets[0] = address(usdc);
        mockAssets[1] = address(dai);
        mockAssets[2] = address(weth);
        int256[] memory mockBalances = new int256[](3);
        mockBalances[0] = int256(123 * 10 ** usdc.decimals());
        mockBalances[1] = int256(456 * 10 ** dai.decimals());
        mockBalances[2] = int256(789 * 10 ** weth.decimals());
        setupMockBalanceAdapter(mockAssets, mockBalances, "Mock Protocol", "Mock Position");

        vm.startPrank(navCalculatorManager);
        // Adapters are now global - add the adapter once
        nav.addBalanceAdapters(aa(address(mockBalanceAdapter)));
        vm.stopPrank();

        // getAllAdapters returns all global adapters
        address[] memory allAdapters = nav.getAllAdapters();
        // Should include ERC20DefaultAdapter (from initialization) and mockBalanceAdapter
        assertGe(allAdapters.length, 2, "Should have at least ERC20DefaultAdapter and mockBalanceAdapter");
        bool foundMockAdapter = false;
        bool foundErc20Default = false;
        for (uint256 i = 0; i < allAdapters.length; i++) {
            if (allAdapters[i] == address(mockBalanceAdapter)) {
                foundMockAdapter = true;
            }
            if (allAdapters[i] == nav.erc20DefaultAdapter()) {
                foundErc20Default = true;
            }
        }
        assertTrue(foundMockAdapter, "Should find mockBalanceAdapter in global adapters");
        assertTrue(foundErc20Default, "Should find ERC20DefaultAdapter in global adapters");

        assertEq(nav.chainlinkL2SequencerGracePeriod(), 3600);
    }

    function test_addBalanceAdapter() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        // ERC20DefaultAdapter is already registered globally, no need to add it again
        vm.stopPrank();
    }

    function test_addBalanceAdapter_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        address erc20Adapter = nav.erc20DefaultAdapter();
        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.addBalanceAdapters(aa(erc20Adapter));
        vm.stopPrank();
    }

    function test_registerAsset() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_registerAsset_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_addBalanceAdapter_withoutAsset() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        // With global adapters, you can add an adapter without an asset being registered
        // ERC20DefaultAdapter is already registered, so try adding a custom adapter
        address customAdapter = address(mockBalanceAdapter);
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(customAdapter));

        // Verify it was added
        assertTrue(nav.isAdapterRegistered(customAdapter), "Custom adapter should be registered");
    }

    function test_removeBalanceAdapter_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        // Add a custom adapter to test removal
        nav.addBalanceAdapters(aa(address(mockBalanceAdapter)));
        assertTrue(nav.isAdapterRegistered(address(mockBalanceAdapter)), "Adapter should be registered");

        // Remove the adapter
        nav.removeBalanceAdapters(aa(address(mockBalanceAdapter)));
        assertFalse(nav.isAdapterRegistered(address(mockBalanceAdapter)), "Adapter should be removed");
        vm.stopPrank();
    }

    function test_removeBalanceAdapter_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        // Add a custom adapter to test removal
        nav.addBalanceAdapters(aa(address(mockBalanceAdapter)));
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.removeBalanceAdapters(aa(address(mockBalanceAdapter)));
        vm.stopPrank();
    }

    function test_unsetPriceFeed_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);

        Mock_PriceOracleChainlink secondAdapter = new Mock_PriceOracleChainlink("Second", 1, 8);
        nav.addPriceFeed(address(usdc), address(secondAdapter), IPrices.PriceType.Chainlink, type(uint256).max);
        nav.removePriceFeedAt(address(usdc), 0);
        vm.stopPrank();
    }

    function test_unsetPriceFeed_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        Mock_PriceOracleChainlink secondAdapter = new Mock_PriceOracleChainlink("Second", 1, 8);
        nav.addPriceFeed(address(usdc), address(secondAdapter), IPrices.PriceType.Chainlink, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.removePriceFeedAt(address(usdc), 0);
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
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);

        vm.expectRevert(InvalidArguments.selector);
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_registerAsset_zeroAddress() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.registerAsset(address(0), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_registerAsset_zeroAdapter() public {
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

    function test_unregisterAsset_withBalanceAdapters() public {
        // Configure mockBalanceAdapter for USDC
        setupMockBalanceAdapter(address(usdc), int256(123 * 10 ** usdc.decimals()));

        vm.startPrank(navCalculatorManager);
        // USDC is already registered in setup. Add the custom adapter globally
        nav.addBalanceAdapters(aa(address(mockBalanceAdapter)));

        // Verify balance adapters exist (ERC20DefaultAdapter from setup + custom adapter)
        assertGe(nav.getAdapterCount(), 2, "Should have at least ERC20DefaultAdapter and custom adapter");

        // Unregister asset - adapters are global and should not be removed
        nav.unregisterAsset(address(usdc));

        // Verify balance adapters are still present (adapters are global, not removed when asset is unregistered)
        assertGe(nav.getAdapterCount(), 2, "Adapters should still exist after asset unregistration");
        vm.stopPrank();
    }

    function test_unregisterAsset_withPriceFeed() public {
        vm.startPrank(navCalculatorManager);
        // USDC is already registered in setup with price feed, so we can directly test unregistering

        // Verify price feed exists
        assertGt(nav.getPriceFeedCount(address(usdc)), 0); // has a feed

        // Unregister asset
        nav.unregisterAsset(address(usdc));

        // Verify price feed is removed
        assertEq(nav.getPriceFeedCount(address(usdc)), 0); // feeds cleared
        vm.stopPrank();
    }

    // ============================================
    // Default adapter inclusion list (exclude / include)
    // ============================================

    function test_registerAsset_addsAssetToDefaultAdapterInclusionList() public {
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        Mock_CustomPriceFeed newTokenAdapter = new Mock_CustomPriceFeed("NEW", address(newToken), 1e8, 8);

        vm.prank(navCalculatorManager);
        nav.registerAsset(address(newToken), address(newTokenAdapter), IPrices.PriceType.Custom, type(uint256).max);

        address defaultAdapter = nav.erc20DefaultAdapter();
        address[] memory supported = IBalanceAdapter(defaultAdapter).underlyingAssetsSupported();
        bool found = false;
        for (uint256 i = 0; i < supported.length; i++) {
            if (supported[i] == address(newToken)) found = true;
        }
        assertTrue(found, "Default adapter should support newly registered asset");

        address[] memory adapters = nav.getAdaptersForAsset(address(newToken));
        bool defaultFound = false;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == defaultAdapter) defaultFound = true;
        }
        assertTrue(defaultFound, "getAdaptersForAsset should include default adapter for new asset");
    }

    function test_excludeAssetFromDefaultAdapter_removesFromInclusionList() public {
        address defaultAdapter = nav.erc20DefaultAdapter();
        address[] memory adaptersBefore = nav.getAdaptersForAsset(address(usdc));
        bool hadDefaultBefore = false;
        for (uint256 i = 0; i < adaptersBefore.length; i++) {
            if (adaptersBefore[i] == defaultAdapter) hadDefaultBefore = true;
        }
        assertTrue(hadDefaultBefore, "Default adapter should support USDC before exclude");

        vm.prank(navCalculatorManager);
        nav.excludeAssetFromDefaultAdapter(address(usdc));

        address[] memory supported = IBalanceAdapter(defaultAdapter).underlyingAssetsSupported();
        for (uint256 i = 0; i < supported.length; i++) {
            assertTrue(supported[i] != address(usdc), "USDC should not be in default adapter after exclude");
        }
        address[] memory adaptersAfter = nav.getAdaptersForAsset(address(usdc));
        for (uint256 i = 0; i < adaptersAfter.length; i++) {
            assertTrue(adaptersAfter[i] != defaultAdapter, "Default adapter should not support USDC after exclude");
        }
    }

    function test_includeAssetInDefaultAdapter_addsBack() public {
        vm.prank(navCalculatorManager);
        nav.excludeAssetFromDefaultAdapter(address(usdc));

        vm.prank(navCalculatorManager);
        nav.includeAssetInDefaultAdapter(address(usdc));

        address defaultAdapter = nav.erc20DefaultAdapter();
        address[] memory supported = IBalanceAdapter(defaultAdapter).underlyingAssetsSupported();
        bool found = false;
        for (uint256 i = 0; i < supported.length; i++) {
            if (supported[i] == address(usdc)) found = true;
        }
        assertTrue(found, "USDC should be in default adapter after include");
        address[] memory adapters = nav.getAdaptersForAsset(address(usdc));
        bool defaultFound = false;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == defaultAdapter) defaultFound = true;
        }
        assertTrue(defaultFound, "getAdaptersForAsset should include default adapter after include");
    }

    function test_excludeAssetFromDefaultAdapter_notAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.excludeAssetFromDefaultAdapter(address(usdc));
    }

    function test_includeAssetInDefaultAdapter_notAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.includeAssetInDefaultAdapter(address(usdc));
    }

    function test_includeAssetInDefaultAdapter_revertsForUnregisteredAsset() public {
        address unregisteredAsset = makeAddr("unregistered");
        vm.prank(navCalculatorManager);
        vm.expectRevert(AssetNotFound.selector);
        nav.includeAssetInDefaultAdapter(unregisteredAsset);
    }

    function test_unregisterAsset_removesFromDefaultAdapterInclusionList() public {
        address defaultAdapter = nav.erc20DefaultAdapter();
        address[] memory supportedBefore = IBalanceAdapter(defaultAdapter).underlyingAssetsSupported();
        uint256 countBefore = 0;
        for (uint256 i = 0; i < supportedBefore.length; i++) {
            if (supportedBefore[i] == address(usdc)) countBefore++;
        }
        assertEq(countBefore, 1, "USDC should be in default adapter before unregister");

        vm.prank(navCalculatorManager);
        nav.unregisterAsset(address(usdc));

        address[] memory supportedAfter = IBalanceAdapter(defaultAdapter).underlyingAssetsSupported();
        for (uint256 i = 0; i < supportedAfter.length; i++) {
            assertTrue(supportedAfter[i] != address(usdc), "USDC should not be in default adapter after unregister");
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
            assertEq(usdcPositions[i].balanceAsset.asset, address(usdc));
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
        assertEq(priceFeed.updatedAt, 0); // Custom adapter should have 0 updatedAt
    }

    function test_getPriceData_stalePrice() public {
        // Create a stale price oracle with short heartbeat
        Mock_PriceOracleChainlink staleAdapter = new Mock_PriceOracleChainlink("Stale", 1, 8);
        vm.startPrank(navCalculatorManager);
        nav.addPriceFeed(address(usdc), address(staleAdapter), IPrices.PriceType.Chainlink, 1); // 1 second heartbeat
        nav.removePriceFeed(address(usdc), address(usdcAdapter));
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
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
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
    // Global Adapter Registry Tests
    // ============================================

    function test_getAllAdapters() public view {
        address[] memory adapters = nav.getAllAdapters();

        assertTrue(adapters.length > 0);
        assertEq(adapters.length, nav.getAdapterCount());
    }

    function test_getAdapterCount() public view {
        uint256 count = nav.getAdapterCount();

        assertTrue(count > 0);
        // Should have at least ERC20DefaultAdapter
        assertTrue(count >= 1);
    }

    function test_isAdapterRegistered() public {
        // ERC20DefaultAdapter should be registered
        assertTrue(nav.isAdapterRegistered(nav.erc20DefaultAdapter()));

        // Random address should not be registered
        assertFalse(nav.isAdapterRegistered(makeAddr("random")));
    }

    function test_getAdapterType() public view {
        IBalances.AdapterType adapterType = nav.getAdapterType(nav.erc20DefaultAdapter());
        assertEq(uint8(adapterType), uint8(IBalances.AdapterType.Default));
    }

    function test_getAdapterType_invalidAdapter() public {
        address invalidAdapter = makeAddr("invalid");

        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        nav.getAdapterType(invalidAdapter);
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
        vm.prank(admin);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeed));

        vm.prank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.setChainlinkL2SequencerGracePeriod(0);
    }

    function test_setChainlinkL2SequencerGracePeriod_belowMinimum() public {
        vm.prank(admin);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeed));

        vm.prank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.setChainlinkL2SequencerGracePeriod(1 hours - 1);
    }

    function test_setChainlinkL2SequencerGracePeriod_exactMinimum() public {
        vm.prank(admin);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeed));

        vm.prank(navCalculatorManager);
        nav.setChainlinkL2SequencerGracePeriod(1 hours);

        assertEq(nav.chainlinkL2SequencerGracePeriod(), 1 hours);
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

    function test_addPriceFeed_assetNotRegistered() public {
        address unregisteredAsset = makeAddr("unregistered");

        vm.startPrank(navCalculatorManager);
        vm.expectRevert(AssetNotFound.selector);
        nav.addPriceFeed(unregisteredAsset, address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_addPriceFeed_zeroOracle() public {
        vm.startPrank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.addPriceFeed(address(usdc), address(0), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_addBalanceAdapter_duplicate() public {
        vm.startPrank(navCalculatorManager);
        // ERC20DefaultAdapter is already registered, try to add it again - should revert with DuplicateBalanceAdapter
        address erc20Adapter = nav.erc20DefaultAdapter();
        vm.expectRevert(IBalances.DuplicateBalanceAdapter.selector);
        nav.addBalanceAdapters(aa(erc20Adapter));
        vm.stopPrank();
    }

    function test_removeBalanceAdapter_invalidAdapter() public {
        vm.startPrank(navCalculatorManager);
        address invalidAdapter = makeAddr("invalid");

        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        nav.removeBalanceAdapters(aa(invalidAdapter));
        vm.stopPrank();
    }

    function test_removeBalanceAdapter_nativeAddress() public {
        vm.startPrank(navCalculatorManager);
        address adapter = nav.erc20DefaultAdapter();
        // Cannot remove ERC20DefaultAdapter, it's protected
        vm.expectRevert(InvalidArguments.selector);
        nav.removeBalanceAdapters(aa(adapter));
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
        assertEq(p.balanceAsset.asset, address(usdc));
        assertEq(p.balanceAsset.symbol, "USDC");
        assertEq(p.balanceAsset.decimals, usdc.decimals());
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
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else if (nav.getPriceFeedCount(address(nav.NATIVE_ADDRESS())) == 0) {
            nav.addPriceFeed(
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
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
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else if (nav.getPriceFeedCount(address(nav.NATIVE_ADDRESS())) == 0) {
            nav.addPriceFeed(
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
        }
        vm.stopPrank();
        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(positions.length, 1);

        INAVCalculator.Position memory p = positions[0];
        assertEq(p.balanceAsset.asset, nav.NATIVE_ADDRESS());
        assertEq(p.balanceAsset.symbol, "ETH");
        assertEq(p.balanceAsset.decimals, 18);
        assertEq(p.amount, 11 ether);
        assertFalse(p.isDebt, "Should be credit position");
        assertPositionMetadata(p, nav.NATIVE_ADDRESS(), "wallet", "{\"protocol\":\"wallet\",\"product\":\"Holding\"}");
        assertEq(p.value, 3_564_627_000_000);
    }

    // Test 13: metadataConsistencyInvariant - custom adapter
    function test_getAccountPositions_customAdapterMetadata() public {
        // Configure mockBalanceAdapter for USDC
        setupMockBalanceAdapter(address(usdc), int256(123 * 10 ** usdc.decimals()));

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(mockBalanceAdapter)));
        vm.stopPrank();

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Find the position from custom adapter (should be index 1, but we'll search)
        bool found = false;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAdapter == address(mockBalanceAdapter)) {
                INAVCalculator.Position memory p = positions[i];
                assertEq(p.balanceAsset.symbol, "USDC");
                assertEq(p.balanceAsset.decimals, usdc.decimals());
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
        assertTrue(found, "Custom adapter position not found");
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

        // Configure mockBalanceAdapter for DAI
        setupMockBalanceAdapter(address(dai), int256(456 * 10 ** dai.decimals()));

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(mockBalanceAdapter)));
        vm.stopPrank();

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));

        // Should have 2 positions: ERC20 DAI and Custom adapter DAI
        assertEq(positions.length, 2);

        // Verify both positions are for DAI
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(dai));
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
        nav.registerAsset(address(usdc), address(usdcAdapter), IPrices.PriceType.Custom, type(uint256).max);
        // ERC20DefaultAdapter is already registered globally, no need to add it again
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
        Mock_CustomBalanceAdapter stakingBalanceAdapter = new Mock_CustomBalanceAdapter();
        stakingBalanceAdapter.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        stakingBalanceAdapter.setUnderlyingAssetsSupported(assets);
        stakingBalanceAdapter.setPositionMetadata("Staking", "Staked USDC");
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(stakingBalanceAdapter)));
        vm.stopPrank();

        // mint 1 USDC to both the safe and the custom adapter
        stakingBalanceAdapter.setBalance(address(usdc), safe, 10 ** usdc.decimals(), false);
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getAccountNav(safe, address(0));
        assertEq(r.value, 2 * 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(positions.length, 2);

        // Both positions should be for USDC
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].balanceAsset.asset, address(usdc));
        }

        // Sum should match NAV
        int256 sum = sumPositionValues(positions);
        assertEq(r.value, sum);
    }

    // Test 15: getAccountPositions_negativeBalances
    function test_getAccountPositions_negativeBalances() public {
        Mock_CustomBalanceAdapter stakingBalanceAdapter = new Mock_CustomBalanceAdapter();
        stakingBalanceAdapter.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        stakingBalanceAdapter.setUnderlyingAssetsSupported(assets);
        stakingBalanceAdapter.setPositionMetadata("Debt", "Borrowed USDC");
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(stakingBalanceAdapter)));

        //Set the custom adapter to -1 USDC  and  mint 1 USDC to the safe
        stakingBalanceAdapter.setBalance(address(usdc), safe, 10 ** usdc.decimals(), true);
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

        vm.prank(admin);
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

        vm.prank(admin);
        nav.setChainlinkL2SequencerUptimeFeed(address(sequencerUptimeFeed));
        vm.prank(navCalculatorManager);
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
        vm.prank(admin);
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
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else if (nav.getPriceFeedCount(address(nav.NATIVE_ADDRESS())) == 0) {
            nav.addPriceFeed(
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
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
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else if (nav.getPriceFeedCount(address(nav.NATIVE_ADDRESS())) == 0) {
            nav.addPriceFeed(
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
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
        Mock_CustomBalanceAdapter debtAdapter = new Mock_CustomBalanceAdapter();
        debtAdapter.setBalances(IBalances(address(nav)));
        address[] memory debtAssets = new address[](1);
        debtAssets[0] = address(usdc);
        debtAdapter.setUnderlyingAssetsSupported(debtAssets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(debtAdapter)));
        debtAdapter.setBalance(address(usdc), safe, 10 ** usdc.decimals(), true);
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

        Mock_CustomBalanceAdapter customAdapter = new Mock_CustomBalanceAdapter();
        customAdapter.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        customAdapter.setUnderlyingAssetsSupported(assets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(customAdapter)));
        customAdapter.setBalance(address(usdc), safe, 0, false); // Zero balance
        vm.stopPrank();

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Should only have 1 position (ERC20 USDC), not the zero custom adapter position
        assertEq(positions.length, 1);
        assertEq(positions[0].balanceAsset.asset, address(usdc));
        assertTrue(positions[0].amount != 0);

        // Verify no zero positions
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].amount != 0, "Zero position found");
        }
    }

    // Test 13: metadataConsistencyInvariant (partially covered above, adding comprehensive test)
    function test_metadataConsistencyInvariant() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        // Test ERC20 adapter metadata
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.Position memory erc20Pos = positions[0];
        assertPositionMetadata(erc20Pos, address(usdc), "wallet", "{\"protocol\":\"wallet\",\"product\":\"Holding\"}");

        // Configure mockBalanceAdapter for USDC
        setupMockBalanceAdapter(address(usdc), int256(123 * 10 ** usdc.decimals()));

        // Test custom adapter metadata
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(mockBalanceAdapter)));
        vm.stopPrank();

        INAVCalculator.Position[] memory positions2 = nav.getAccountPositions(safe, address(0));
        bool foundCustom = false;
        for (uint256 i = 0; i < positions2.length; i++) {
            if (positions2[i].balanceAdapter == address(mockBalanceAdapter)) {
                assertPositionMetadata(positions2[i], address(usdc), "Mock Protocol", "Mock Position");
                foundCustom = true;
            }
        }
        assertTrue(foundCustom, "Custom adapter position not found");
    }

    // ============================================
    // D. Edge Cases
    // ============================================

    // Test 14: getAccountPositions_zeroBalancesExcluded
    function test_getAccountPositions_zeroBalancesExcluded() public {
        // No minting - all balances are zero
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        assertEq(positions.length, 0);

        // Add a custom adapter with zero balance
        Mock_CustomBalanceAdapter zeroAdapter = new Mock_CustomBalanceAdapter();
        zeroAdapter.setBalances(IBalances(address(nav)));
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        zeroAdapter.setUnderlyingAssetsSupported(assets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(zeroAdapter)));
        zeroAdapter.setBalance(address(usdc), safe, 0, false);
        vm.stopPrank();

        INAVCalculator.Position[] memory positions2 = nav.getAccountPositions(safe, address(0));
        assertEq(positions2.length, 0);
    }

    // Test 17: getAccountPositions_stalePrices
    function test_getAccountPositions_stalePrices() public {
        // Create a stale price oracle with short heartbeat
        Mock_PriceOracleChainlink staleAdapter = new Mock_PriceOracleChainlink("Stale", 1, 8);
        vm.startPrank(navCalculatorManager);
        // USDC is already registered, just update the price oracle with short heartbeat
        nav.addPriceFeed(address(usdc), address(staleAdapter), IPrices.PriceType.Chainlink, 1); // 1 second heartbeat
        nav.removePriceFeed(address(usdc), address(usdcAdapter));
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
            if (positions[i].balanceAsset.asset == address(usdc)) {
                assertTrue(positions[i].stale, "Position not marked stale");
            }
        }
    }

    // Test 20: getAccountPositions_assetWithoutPriceFeed
    function test_getAccountPositions_assetWithoutPriceFeed() public {
        // Create a new token that's not in setUp
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        Mock_CustomPriceFeed newTokenAdapter = new Mock_CustomPriceFeed("NEW", address(newToken), 1e8, 8);

        vm.startPrank(navCalculatorManager);
        // Asset must be registered with a price feed - this is now required
        nav.registerAsset(address(newToken), address(newTokenAdapter), IPrices.PriceType.Custom, type(uint256).max);
        // ERC20DefaultAdapter is already registered globally, no need to add it again
        vm.stopPrank();

        newToken.mint(safe, 10 ** newToken.decimals());

        // Should work now that asset is registered with price feed
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        // Asset should be included since it has a price feed
        bool found = false;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAsset.asset == address(newToken)) {
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
                positions[i].balanceAsset.asset != address(unregisteredToken), "Unregistered asset should be skipped"
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
        Mock_CustomPriceFeed newTokenAdapter = new Mock_CustomPriceFeed("NEW", address(newToken), 1e8, 8);
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(newToken), address(newTokenAdapter), IPrices.PriceType.Custom, type(uint256).max);
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
        assertTrue(p.balanceAsset.asset != address(0));
        assertTrue(bytes(p.balanceAsset.symbol).length > 0);
        assertTrue(p.balanceAsset.decimals > 0);
        assertTrue(p.protocolId != bytes32(0));

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
        assertEq(usdPos.balanceAsset.asset, address(usdc));
        (int256 priceInUsd, uint8 usdPriceDecimals,) = nav.latestPrice(address(usdc));
        assertEq(usdPos.price, priceInUsd);
        assertEq(usdPos.priceDecimals, usdPriceDecimals);

        // Test ETH rate
        vm.startPrank(navCalculatorManager);
        // Native address is already registered in setupNav(), only set price feed if not already set
        if (!nav.isAssetRegistered(address(nav.NATIVE_ADDRESS()))) {
            nav.registerAsset(
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
        } else if (nav.getPriceFeedCount(address(nav.NATIVE_ADDRESS())) == 0) {
            nav.addPriceFeed(
                address(nav.NATIVE_ADDRESS()), address(ethAdapter), IPrices.PriceType.Chainlink, type(uint256).max
            );
        }
        vm.stopPrank();

        INAVCalculator.Position[] memory ethPositions = nav.getAccountPositions(safe, nav.NATIVE_ADDRESS());
        INAVCalculator.Position memory ethPos = ethPositions[0];
        (int256 priceInEth, uint8 ethPriceDecimals,) = nav.latestPrice(nav.NATIVE_ADDRESS());
        assertGe(priceInEth, 0, "price non-negative");
        assertLe(ethPriceDecimals, 255, "decimals valid");

        // Verify underlying asset is still USDC (what we hold)
        assertEq(ethPos.balanceAsset.asset, address(usdc));
        assertEq(usdPos.balanceAsset.asset, address(usdc));

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

    // Test 26b: hasPositions is fail-open — a reverting adapter must not DoS the scan.
    function test_hasPositions_resilientToRevertingAdapter() public {
        RevertingBalanceAdapter reverter = new RevertingBalanceAdapter();
        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(reverter)));

        // Empty account: the reverting adapter is skipped, hasPositions returns false (no revert).
        assertFalse(nav.hasPositions(safe));

        // Real wallet position via the default adapter is still detected despite the reverting adapter.
        usdc.mint(safe, 10 ** usdc.decimals());
        assertTrue(nav.hasPositions(safe));
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
                if (positions[j].balanceAsset.asset == assets[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Asset from getAssetsWithPositions not found in getAllPositions");
        }

        // All positions in getAllPositions should be from assets in getAssetsWithPositions
        for (uint256 i = 0; i < positions.length; i++) {
            address positionAsset = positions[i].balanceAsset.asset;
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

    // Test getAssetsWithPositions_multipleBalanceAdapters
    function test_getAssetsWithPositions_multipleBalanceAdapters() public {
        usdc.mint(safe, 10 ** usdc.decimals());

        // Add a custom balance adapter for USDC
        Mock_CustomBalanceAdapter customAdapter = new Mock_CustomBalanceAdapter();
        customAdapter.setBalances(IBalances(address(nav)));
        address[] memory adapterAssets = new address[](1);
        adapterAssets[0] = address(usdc);
        customAdapter.setUnderlyingAssetsSupported(adapterAssets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(customAdapter)));
        customAdapter.setBalance(address(usdc), safe, 5 * 10 ** (usdc.decimals() - 1), false);
        vm.stopPrank();

        address[] memory assetsWithPos = nav.getAssetsWithPositions(safe);
        // Should still return USDC (has positions from both adapters)
        assertEq(assetsWithPos.length, 1);
        assertEq(assetsWithPos[0], address(usdc));
    }

    // Test getAssetsWithPositions_allZeroBalances
    function test_getAssetsWithPositions_allZeroBalances() public {
        // Add a custom adapter with zero balance
        Mock_CustomBalanceAdapter zeroAdapter = new Mock_CustomBalanceAdapter();
        zeroAdapter.setBalances(IBalances(address(nav)));
        address[] memory adapterAssets = new address[](1);
        adapterAssets[0] = address(usdc);
        zeroAdapter.setUnderlyingAssetsSupported(adapterAssets);
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(zeroAdapter)));
        zeroAdapter.setBalance(address(usdc), safe, 0, false);
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
        Mock_PriceOracleChainlink token3Adapter = new Mock_PriceOracleChainlink("T3", 1, 8);
        Mock_PriceOracleChainlink token4Adapter = new Mock_PriceOracleChainlink("T4", 1, 8);
        Mock_PriceOracleChainlink token5Adapter = new Mock_PriceOracleChainlink("T5", 1, 8);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token3), address(token3Adapter), IPrices.PriceType.Chainlink, type(uint256).max);
        // ERC20DefaultAdapter is already registered globally, no need to add it again

        nav.registerAsset(address(token4), address(token4Adapter), IPrices.PriceType.Chainlink, type(uint256).max);
        // ERC20DefaultAdapter is already registered globally, no need to add it again

        nav.registerAsset(address(token5), address(token5Adapter), IPrices.PriceType.Chainlink, type(uint256).max);
        // ERC20DefaultAdapter is already registered globally, no need to add it again
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
                if (positions[j].balanceAsset.asset == assetsWithPos[i]) {
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
