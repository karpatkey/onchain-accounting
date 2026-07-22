// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/SuperTest.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IBalanceAdapter} from "src/balances/IBalanceAdapter.sol";
import {IBalances} from "src/balances/IBalances.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ICustomPriceFeed} from "src/prices/ICustomPriceFeed.sol";
import {PositionKind} from "src/utils/PositionKind.sol";
import {aa} from "test/helpers/AdapterArray.sol";

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

/// @title Mock Reverting Price Oracle
/// @notice Price oracle that reverts for testing error handling
contract Mock_RevertingPriceOracle is ICustomPriceFeed {
    function getLatestPrice() external pure override returns (uint256, bool) {
        revert("Price oracle revert");
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function underlyingAssetSupported() external pure override returns (address) {
        return address(0);
    }

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title Mock Malformed Price Oracle
/// @notice Price oracle that returns invalid data
contract Mock_MalformedPriceOracle is ICustomPriceFeed {
    function getLatestPrice() external pure override returns (uint256, bool) {
        // Return zero price (should be marked as stale)
        return (0, true);
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function underlyingAssetSupported() external pure override returns (address) {
        return address(0);
    }

    function latestRoundData() external pure override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ICustomPriceFeed).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title Mock Many-Legs Balance Adapter
/// @notice Emits a configurable number of position legs, all for a single registered asset. Models a
///         meta-adapter that returns many legs per instance (e.g. Uniswap/PancakeSwap V3 emit up to 4
///         legs per LP NFT). Used to regression-test the NAV read-buffer sizing — see audit finding #1
///         in docs/audits/2026-06-nav-core-internal-audit.md.
contract Mock_ManyLegsBalanceAdapter is IBalanceAdapter {
    INAVCalculator.Asset internal _asset;
    uint256 public legCount;

    constructor(address asset_, string memory symbol_, uint8 decimals_) {
        _asset = INAVCalculator.Asset({asset: asset_, symbol: symbol_, decimals: decimals_});
    }

    function setLegCount(uint256 n) external {
        legCount = n;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBalanceAdapter).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getAdapterPositions(address, address)
        external
        view
        override
        returns (INAVCalculator.PositionBalance[] memory pos)
    {
        pos = new INAVCalculator.PositionBalance[](legCount);
        for (uint256 i; i < legCount; ++i) {
            // Field-by-field assignment into the array element (not an 11-field struct literal) keeps this loop under
            // the via_ir stack limit. Writing straight to `pos[i]` (not via a local) makes the in-place mutation
            // unambiguous. isDebt/isLocked default false; positionInstanceId defaults to bytes32(0).
            pos[i].balanceAsset = _asset;
            pos[i].balanceAdapter = address(this);
            pos[i].amount = 1;
            // Populate the full protocol taxonomy (brand/id/subId) so the mock models a realistic Uni/Pancake
            // V3-style leg — the stable identity key uses protocolSubId, not protocolId alone.
            pos[i].protocolBrand = bytes32("uniswap-mock");
            pos[i].protocolId = bytes32("uniswap-v3-mock");
            pos[i].protocolSubId = bytes32("uniswap-v3-mock");
            pos[i].positionId = abi.encode(i);
            pos[i].positionKind = PositionKind.Supplied;
        }
    }

    function getAdapterBalances(address)
        external
        pure
        override
        returns (address[] memory, uint256[] memory, bool[] memory)
    {
        return (new address[](0), new uint256[](0), new bool[](0));
    }

    function getAdapterBalanceForAsset(address, address) external pure override returns (uint256, bool) {
        return (0, false);
    }

    function underlyingAssetsSupported() external view override returns (address[] memory a) {
        a = new address[](1);
        a[0] = _asset.asset;
    }
}

/// @title NAVCalculator Error Handling Tests
/// @notice Tests error scenarios and graceful degradation
contract NAVCalculatorErrorTest is SuperTest {
    Mock_RevertingBalanceAdapter public revertingAdapter;

    function setUp() public {
        setupAll();
        revertingAdapter = new Mock_RevertingBalanceAdapter();
    }

    // ============================================
    // Adapter Revert Handling
    // ============================================

    /// @notice Test that adapter reverts are handled gracefully
    function test_RevertWhen_adapterReverts_handledGracefully() public {
        // Add reverting adapter
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(revertingAdapter)));
        vm.stopPrank();

        // Setup other adapters with valid data
        usdc.mint(safe, 10 ** usdc.decimals());

        // Query should not revert, but skip the reverting adapter
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));

        // Should still get NAV from other adapters
        assertGe(navResult.value, 0, "Should get NAV from non-reverting adapters");

        // Get positions - should not include positions from reverting adapter
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Verify no positions from reverting adapter
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(
                positions[i].balanceAdapter != address(revertingAdapter),
                "Should not have positions from reverting adapter"
            );
        }
    }

    /// @notice Regression for audit finding #1 (High): an adapter that emits more legs than the old
    ///         `2 * (adapters + metaInstances) * assetCount` heuristic — as the Uniswap/PancakeSwap V3
    ///         meta-adapters do (up to ~4 legs per LP NFT) — must NOT overflow the NAV read buffer and
    ///         revert. Before the fix this triggered a Panic(0x32) that bricked getAccountNav /
    ///         getAccountPositions for the account. The buffer is now sized from the actual returned
    ///         lengths, so every leg is reported and the read succeeds.
    function test_manyLegAdapter_doesNotOverflowNavReadBuffer() public {
        Mock_ManyLegsBalanceAdapter many = new Mock_ManyLegsBalanceAdapter(address(usdc), "USDC", usdc.decimals());

        vm.prank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(many)));

        // Old buffer bound = 2 * (adapters + metaInstances) * assetCount; setupAll registers no meta
        // instances, so it is exactly 2 * adapters * assetCount. Emit comfortably past it.
        uint256 oldBound = 2 * nav.getAllAdapters().length * nav.getAssetCount();
        uint256 legs = oldBound + 200;
        many.setLegCount(legs);

        // Would Panic(0x32) under the old fixed-size buffer; must succeed now.
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        assertGe(navResult.value, 0, "NAV read must not revert for a many-leg adapter");

        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        uint256 fromMany;
        for (uint256 i; i < positions.length; ++i) {
            if (positions[i].balanceAdapter == address(many)) ++fromMany;
        }
        assertEq(fromMany, legs, "every leg from the many-leg adapter must be reported (no truncation)");
    }

    /// @notice Test that multiple adapter reverts are handled
    function test_RevertWhen_multipleAdapterReverts_handledGracefully() public {
        // Add multiple reverting adapters
        Mock_RevertingBalanceAdapter adapter2 = new Mock_RevertingBalanceAdapter();
        Mock_RevertingBalanceAdapter adapter3 = new Mock_RevertingBalanceAdapter();

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(revertingAdapter)));
        nav.addBalanceAdapters(aa(address(adapter2)));
        nav.addBalanceAdapters(aa(address(adapter3)));
        vm.stopPrank();

        // Setup valid data
        usdc.mint(safe, 10 ** usdc.decimals());

        // Should still work with other adapters
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        assertGe(navResult.value, 0, "Should work despite multiple reverting adapters");
    }

    /// @notice Test that adapter can recover from revert
    function test_RevertWhen_adapterRecoversFromRevert() public {
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(revertingAdapter)));
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());

        // First query - adapter reverts
        INAVCalculator.NAV memory nav1 = nav.getAccountNav(safe, address(0));

        // Stop adapter from reverting
        revertingAdapter.setShouldRevert(false);

        // Second query - adapter should work now
        INAVCalculator.NAV memory nav2 = nav.getAccountNav(safe, address(0));

        // NAV should be same or greater (adapter might add positions)
        assertGe(nav2.value, nav1.value, "NAV should be same or greater after adapter recovery");
    }

    // ============================================
    // Price Oracle Revert Handling
    // ============================================

    /// @notice Test that a reverting price oracle is skipped and marked stale (not propagated).
    function test_RevertWhen_priceOracleReverts() public {
        Mock_RevertingPriceOracle revertingPriceOracle = new Mock_RevertingPriceOracle();
        Mock_ERC20 token = new Mock_ERC20("REVERT", 18);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token), address(revertingPriceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        token.mint(safe, 10 ** 18);

        // A reverting feed is caught by try/catch and treated as stale; call must not revert.
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        bool tokenIsStale = false;
        for (uint256 i; i < navResult.stalePriceAssets.length; i++) {
            if (navResult.stalePriceAssets[i].asset == address(token)) {
                tokenIsStale = true;
                break;
            }
        }
        assertTrue(tokenIsStale, "reverting feed should mark token stale");
    }

    /// @notice Test that malformed price oracle responses are handled
    function test_RevertWhen_malformedPriceOracle() public {
        // Create malformed price oracle (returns zero price)
        Mock_MalformedPriceOracle malformedAdapter = new Mock_MalformedPriceOracle();

        Mock_ERC20 token = new Mock_ERC20("MALFORMED", 18);

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(token), address(malformedAdapter), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        token.mint(safe, 10 ** 18);

        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        assertTrue(navResult.timestamp >= 0, "nav returned");

        (,, bool stale,) = nav.latestPrice(address(token));
        assertTrue(stale, "Zero price should be marked as stale");
    }

    // ============================================
    // Interface Mismatch Handling
    // ============================================

    /// @notice Test that invalid adapter interface is rejected
    function test_RevertWhen_invalidAdapterInterface() public {
        // Try to add a contract that doesn't implement IBalanceAdapter
        address invalidAdapter = address(usdc); // ERC20 doesn't implement IBalanceAdapter

        vm.startPrank(navCalculatorManager);
        vm.expectRevert(IBalances.InvalidBalanceAdapter.selector);
        nav.addBalanceAdapters(aa(invalidAdapter));
        vm.stopPrank();
    }

    /// @notice Test that zero address adapter is rejected
    function test_RevertWhen_zeroAddressAdapter() public {
        vm.startPrank(navCalculatorManager);
        vm.expectRevert(InvalidArguments.selector);
        nav.addBalanceAdapters(aa(address(0)));
        vm.stopPrank();
    }

    // ============================================
    // Concurrent Failures
    // ============================================

    /// @notice Test handling of concurrent adapter and price failures
    function test_RevertWhen_concurrentFailures() public {
        // Add reverting balance adapter
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(revertingAdapter)));

        // Create token with reverting price oracle
        Mock_RevertingPriceOracle revertingPriceOracle = new Mock_RevertingPriceOracle();
        Mock_ERC20 token = new Mock_ERC20("FAIL", 18);
        nav.registerAsset(address(token), address(revertingPriceOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        // Setup valid data with other assets
        usdc.mint(safe, 10 ** usdc.decimals());

        // Should still work with valid assets
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));

        // Should get NAV from valid assets
        assertGe(navResult.value, 0, "Should work despite concurrent failures");

        // The failing asset is skipped (try/catch); call must not revert; token appears as stale.
        token.mint(safe, 10 ** 18);
        INAVCalculator.NAV memory navResult2 = nav.getAccountNav(safe, address(0));
        bool tokenIsStale = false;
        for (uint256 i; i < navResult2.stalePriceAssets.length; i++) {
            if (navResult2.stalePriceAssets[i].asset == address(token)) {
                tokenIsStale = true;
                break;
            }
        }
        assertTrue(tokenIsStale, "reverting feed should mark token stale");
    }

    // ============================================
    // Error Recovery
    // ============================================

    /// @notice Test that system recovers after adapter removal
    function test_RevertWhen_adapterRemovalRecovery() public {
        // Add reverting adapter
        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(revertingAdapter)));
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());

        // Query with reverting adapter
        INAVCalculator.NAV memory nav1 = nav.getAccountNav(safe, address(0));

        // Remove reverting adapter
        vm.startPrank(navCalculatorManager);
        nav.removeBalanceAdapters(aa(address(revertingAdapter)));
        vm.stopPrank();

        // Query again - should work normally
        INAVCalculator.NAV memory nav2 = nav.getAccountNav(safe, address(0));

        // NAV should be consistent
        assertEq(nav1.value, nav2.value, "NAV should be consistent after adapter removal");
    }

    // ============================================
    // Edge Cases
    // ============================================

    /// @notice Test that all adapters reverting still allows query (returns zero NAV)
    function test_RevertWhen_allAdaptersRevert() public {
        // Add multiple reverting adapters
        Mock_RevertingBalanceAdapter adapter2 = new Mock_RevertingBalanceAdapter();
        Mock_RevertingBalanceAdapter adapter3 = new Mock_RevertingBalanceAdapter();

        vm.startPrank(navCalculatorManager);
        nav.addBalanceAdapters(aa(address(revertingAdapter)));
        nav.addBalanceAdapters(aa(address(adapter2)));
        nav.addBalanceAdapters(aa(address(adapter3)));
        vm.stopPrank();

        // Don't mint any tokens (so ERC20DefaultBalanceAdapter has no positions)

        // Should return zero NAV, not revert
        INAVCalculator.NAV memory navResult = nav.getAccountNav(safe, address(0));
        assertEq(navResult.value, 0, "Should return zero NAV when all adapters revert or have no positions");
    }

    /// @notice Test that invalid quote asset is handled
    function test_RevertWhen_invalidQuoteAsset() public {
        address invalidQuote = makeAddr("invalid");

        // Should revert with PriceFeedNotSet
        vm.expectRevert(abi.encodeWithSelector(PriceFeedNotSet.selector, invalidQuote));
        nav.getAccountNav(safe, invalidQuote);
    }

    /// @notice Test that unregistered asset in calculateValue is handled
    function test_RevertWhen_unregisteredAssetInCalculateValue() public {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = makeAddr("unregistered");
        amounts[0] = 1e18;

        vm.expectRevert(AssetNotFound.selector);
        nav.calculateValue(assets, amounts, address(0));
    }

    /// @notice Test that array length mismatch in calculateValue is handled
    function test_RevertWhen_calculateValue_arrayLengthMismatch() public {
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        amounts[0] = 1e18;

        vm.expectRevert(ArrayLengthMismatch.selector);
        nav.calculateValue(assets, amounts, address(0));
    }
}
