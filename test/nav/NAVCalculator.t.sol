// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "test/SuperTest.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPrices} from "src/prices/IPrices.sol";

contract NAVCalculatorHarness is NAVCalculator {
    constructor(address admin, address safe, address chainlinkUptimeFeed) {
        NAVCalculator.initialize(admin, safe, chainlinkUptimeFeed);
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
    function sumPositionValues(INAVCalculator.VerbosePosition[] memory positions) internal pure returns (int256) {
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].pricing.value;
        }
        return sum;
    }

    function findPositionByAsset(
        INAVCalculator.VerbosePosition[] memory positions,
        address asset
    ) internal pure returns (INAVCalculator.VerbosePosition memory, bool) {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].core.asset == asset) {
                // Check if this matches the balance oracle index by checking metadata
                // We'll need to match by protocol/position/positionType or use a different approach
                // For now, return first match - tests should be more specific
                return (positions[i], true);
            }
        }
        INAVCalculator.VerbosePosition memory empty;
        return (empty, false);
    }

    function assertPositionMetadata(
        INAVCalculator.VerbosePosition memory pos,
        address expectedAsset,
        string memory expectedProtocol,
        string memory expectedPosition,
        string memory expectedPositionType
    ) internal pure {
        assertEq(pos.core.asset, expectedAsset, "Asset mismatch");
        assertEq(pos.core.protocol, expectedProtocol, "Protocol mismatch");
        assertEq(pos.core.position, expectedPosition, "Position mismatch");
        assertEq(pos.core.positionType, expectedPositionType, "PositionType mismatch");
    }

    function test_setUp() public {
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(nav.NATIVE_ADDRESS()));
        nav.setPriceOracle(address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, 86_400);
        vm.stopPrank();

        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        address[] memory assets = nav.assets();
        assertEq(assets.length, 4);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(dai));
        assertEq(assets[2], address(weth));
        assertEq(assets[3], nav.NATIVE_ADDRESS());

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
        assertEq(chainlinkHeartbeat_, 86_400);
        assertEq(uint8(priceType_), uint8(IPrices.PriceType.Chainlink));

        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(dai), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(weth), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        address[] memory balanceOracles = nav.balanceOracles(address(usdc));
        assertEq(balanceOracles.length, 2);
        assertEq(balanceOracles[0], address(usdc));
        assertEq(balanceOracles[1], address(mockBalanceOracle));

        balanceOracles = nav.balanceOracles(address(dai));
        assertEq(balanceOracles.length, 2);
        assertEq(balanceOracles[0], address(dai));
        assertEq(balanceOracles[1], address(mockBalanceOracle));

        balanceOracles = nav.balanceOracles(address(weth));
        assertEq(balanceOracles.length, 2);
        assertEq(balanceOracles[0], address(weth));
        assertEq(balanceOracles[1], address(mockBalanceOracle));

        balanceOracles = nav.balanceOracles(nav.NATIVE_ADDRESS());
        assertEq(balanceOracles.length, 1);
        assertEq(balanceOracles[0], nav.NATIVE_ADDRESS());

        assertEq(nav.chainlinkL2SequencerGracePeriod(), 3600);
        assertEq(nav.assetRecoverer(), safe);
    }

    function test_setBalanceOracle() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();
    }

    function test_setBalanceOracle_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();
    }

    function test_setPriceOracle() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_setPriceOracle_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();
    }

    function test_setBalanceOracle_withoutAsset() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.prank(navCalculatorManager);
        vm.expectRevert(INAVCalculator.AssetNotFound.selector);
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
    }

    function test_unsetBalanceOracle_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        nav.unsetBalanceOracle(address(usdc), address(usdc));
        vm.stopPrank();
    }

    function test_unsetBalanceOracle_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.unsetBalanceOracle(address(usdc), address(usdc));
        vm.stopPrank();
    }

    function test_unsetPriceOracle_ops() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);

        nav.unsetPriceOracle(address(usdc));
        vm.stopPrank();
    }

    function test_unsetPriceOracle_notAuthorized() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeed));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        nav.unsetPriceOracle(address(usdc));
        vm.stopPrank();
    }

    // Test 1: getTotalNAV_emptyAccount
    function test_getTotalNAV_emptyAccount() public {
        vm.roll(1);

        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        assertEq(r.block, 1);
        assertEq(r.timestamp, block.timestamp);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
        assertEq(r.usd, 0);

        vm.roll(2);
        r = nav.getTotalNAV(safe);
        assertEq(r.block, 2);
        assertEq(r.timestamp, block.timestamp);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
        assertEq(r.usd, 0);
    }

    // Test 2: getTotalNAV_singleAsset
    function test_getTotalNAV_singleAsset() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        assertEq(r.usd, 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
        assertEq(r.block, block.number);
        assertEq(r.timestamp, block.timestamp);
    }

    // Test 5: getAllPositions_singlePosition
    function test_getAllPositions_singlePosition() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        
        assertEq(accountPositions.positions.length, 1);
        INAVCalculator.VerbosePosition memory p = accountPositions.positions[0];
        
        // Check core data
        assertEq(p.core.asset, address(usdc));
        assertEq(p.core.assetSymbol, "USDC");
        assertEq(p.core.assetDecimals, usdc.decimals());
        assertEq(p.core.balance, int256(10 ** usdc.decimals()));
        assertPositionMetadata(p, address(usdc), "Portfolio balance", "USDC", "ERC20");
        
        // Check pricing data
        assertEq(p.pricing.quoteCurrency, address(0));
        assertEq(p.pricing.quoteCurrencySymbol, "USD");
        assertEq(p.pricing.quoteCurrencyDecimals, 8);
        assertEq(p.pricing.value, 1e8);
        assertEq(p.pricing.rate, 1e8);
        assertEq(p.pricing.rateDecimals, 8);
        assertEq(p.pricing.stale, false);
        assertEq(p.pricing.sequencerDown, false);
    }

    function test_getTotalNAV_eth() public {
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(nav.NATIVE_ADDRESS()));
        nav.setPriceOracle(
            address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
        );
        vm.stopPrank();

        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        assertEq(r.usd, 3_564_627_000_000);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
    }

    // Test 19: getAllPositions_nativeToken
    function test_getAllPositions_nativeToken() public {
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(nav.NATIVE_ADDRESS()));
        nav.setPriceOracle(
            address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
        );
        vm.stopPrank();
        vm.deal(safe, 11 ether);
        assertEq(address(safe).balance, 11 ether);

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions.positions.length, 1);
        
        INAVCalculator.VerbosePosition memory p = accountPositions.positions[0];
        assertEq(p.core.asset, nav.NATIVE_ADDRESS());
        assertEq(p.core.assetSymbol, "ETH");
        assertEq(p.core.assetDecimals, 18);
        assertEq(p.core.balance, int256(11 ether));
        assertPositionMetadata(p, nav.NATIVE_ADDRESS(), "Portfolio balance", "ETH", "Native");
        assertEq(p.pricing.value, 3_564_627_000_000);
    }



    // Test 13: metadataConsistencyInvariant - custom oracle
    function test_getAllPositions_customOracleMetadata() public {
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        
        // Find the position from custom oracle (should be index 1, but we'll search)
        bool found = false;
        for (uint256 i = 0; i < accountPositions.positions.length; i++) {
            if (
                keccak256(bytes(accountPositions.positions[i].core.protocol)) ==
                keccak256(bytes("Mock Protocol"))
            ) {
                INAVCalculator.VerbosePosition memory p = accountPositions.positions[i];
                assertPositionMetadata(p, address(usdc), "Mock Protocol", "Mock Position", "Mock Type");
                assertEq(p.core.assetSymbol, "USDC");
                assertEq(p.core.assetDecimals, usdc.decimals());
                assertEq(p.core.balance, int256(123 * 10 ** usdc.decimals()));
                assertEq(p.pricing.value, 123e8);
                assertEq(p.pricing.rate, 1e8);
                assertEq(p.pricing.rateDecimals, 8);
                assertEq(p.pricing.stale, false);
                found = true;
                break;
            }
        }
        assertTrue(found, "Custom oracle position not found");
    }

    // Test 3: getTotalNAV_multipleAssets
    function test_getTotalNAV_multipleAssets() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());
        weth.mint(safe, 10 ** weth.decimals());
        
        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        // USDC: 1e8, DAI: 1e8, WETH: ~3240e8
        assertApproxEqRel(r.usd, 3242e8, 0.01 ether);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);
    }

    // Test 6: getAllPositions_multiplePositions
    function test_getAllPositions_multiplePositions() public {
        dai.mint(safe, 10 ** dai.decimals());
        
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(dai), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        
        // Should have 2 positions: ERC20 DAI and Custom oracle DAI
        assertEq(accountPositions.positions.length, 2);
        
        // Verify both positions are for DAI
        for (uint256 i = 0; i < accountPositions.positions.length; i++) {
            assertEq(accountPositions.positions[i].core.asset, address(dai));
            assertTrue(accountPositions.positions[i].core.balance != 0);
        }
        
        // Verify NAV matches sum
        int256 sum = sumPositionValues(accountPositions.positions);
        assertEq(accountPositions.nav.usd, sum);
    }



    // Test 18: getAllPositions_sequencerDown
    function test_getAllPositions_sequencerDown() public {
        vm.startPrank(admin);
        nav = this.setupNAVCalculatorWithParams(admin, safe, address(sequencerUptimeFeedDown));
        nav.grantRole(MANAGER, navCalculatorManager);
        vm.stopPrank();

        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), address(usdcOracle), IPrices.PriceType.Custom, type(uint256).max);
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        assertEq(r.usd, 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, true);

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions.nav.sequencerDown, true);
        assertEq(accountPositions.positions.length, 1);
        assertEq(accountPositions.positions[0].pricing.sequencerDown, true);
        assertEq(accountPositions.positions[0].pricing.stale, false);
    }


    // Test 16: getAllPositions_multipleBalancesSameAsset
    function test_getAllPositions_multipleBalancesSameAsset() public {
        Mock_CustomBalanceOracle stakingBalanceOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(stakingBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        // mint 1 USDC to both the safe and the custom oracle
        stakingBalanceOracle.setBalance(address(usdc), safe, int256(10 ** usdc.decimals()));
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        assertEq(r.usd, 2 * 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions.positions.length, 2);
        
        // Both positions should be for USDC
        for (uint256 i = 0; i < accountPositions.positions.length; i++) {
            assertEq(accountPositions.positions[i].core.asset, address(usdc));
        }
        
        // Sum should match NAV
        int256 sum = sumPositionValues(accountPositions.positions);
        assertEq(accountPositions.nav.usd, sum);
    }

    // Test 15: getAllPositions_negativeBalances
    function test_getAllPositions_negativeBalances() public {
        Mock_CustomBalanceOracle stakingBalanceOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(stakingBalanceOracle), IBalances.BalanceType.Custom);

        //Set the custom oracle to -1 USDC  and  mint 1 USDC to the safe
        stakingBalanceOracle.setBalance(address(usdc), safe, -1 * int256(10 ** usdc.decimals()));
        vm.stopPrank();
        usdc.mint(safe, 10 ** usdc.decimals());

        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        assertEq(r.usd, 0 * 1e8);
        assertEq(r.stalePriceAssets.length, 0);
        assertEq(r.sequencerDown, false);

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions.positions.length, 2);
        
        // One position should be negative
        bool foundNegative = false;
        bool foundPositive = false;
        for (uint256 i = 0; i < accountPositions.positions.length; i++) {
            if (accountPositions.positions[i].core.balance < 0) {
                assertTrue(accountPositions.positions[i].pricing.value <= 0);
                foundNegative = true;
            } else {
                foundPositive = true;
            }
        }
        assertTrue(foundNegative, "Negative position not found");
        assertTrue(foundPositive, "Positive position not found");
        
        // Sum should match NAV
        int256 sum = sumPositionValues(accountPositions.positions);
        assertEq(accountPositions.nav.usd, sum);
    }



    // Test 4: getAllPositions_emptyAccount
    function test_getAllPositions_emptyAccount() public {
        vm.startPrank(navCalculatorManager);
        nav.unregisterAsset(address(usdc));
        nav.unregisterAsset(address(dai));
        nav.unregisterAsset(address(weth));
        vm.stopPrank();

        assertEq(nav.assetCount(), 0);

        INAVCalculator.NAV memory n = nav.getTotalNAV(safe);
        assertEq(n.usd, 0);
        assertEq(n.stalePriceAssets.length, 0);
        assertEq(n.sequencerDown, false);
        assertEq(n.block, block.number);
        assertEq(n.timestamp, block.timestamp);

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions.positions.length, 0);
        assertEq(accountPositions.nav.usd, 0);
        assertEq(accountPositions.nav.block, block.number);
        assertEq(accountPositions.nav.timestamp, block.timestamp);
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

    // ============================================
    // B. Currency Conversion Tests
    // ============================================

    // Test 7: getAllPositions_usdDefault
    function test_getAllPositions_usdDefault() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        
        assertEq(accountPositions.positions.length, 1);
        INAVCalculator.VerbosePosition memory p = accountPositions.positions[0];
        
        assertEq(p.pricing.quoteCurrency, address(0));
        assertEq(p.pricing.quoteCurrencySymbol, "USD");
        assertEq(p.pricing.quoteCurrencyDecimals, 8);
        assertEq(p.pricing.rate, 1e8);
        assertEq(p.pricing.rateDecimals, 8);
    }

    // Test 8: getAllPositions_ethQuoteCurrency
    function test_getAllPositions_ethQuoteCurrency() public {
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(nav.NATIVE_ADDRESS()));
        nav.setPriceOracle(
            address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
        );
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, nav.NATIVE_ADDRESS());
        
        assertEq(accountPositions.positions.length, 1);
        INAVCalculator.VerbosePosition memory p = accountPositions.positions[0];
        
        assertEq(p.pricing.quoteCurrency, nav.NATIVE_ADDRESS());
        assertEq(p.pricing.quoteCurrencySymbol, "ETH");
        assertEq(p.pricing.quoteCurrencyDecimals, 18);
        // Value should be converted to ETH (1 USDC / ETH price)
        assertTrue(p.pricing.value > 0);
        assertTrue(p.pricing.rate > 0);
    }

    // Test 9: getAllPositions_customQuoteCurrency
    function test_getAllPositions_customQuoteCurrency() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(dai));
        
        assertEq(accountPositions.positions.length, 1);
        INAVCalculator.VerbosePosition memory p = accountPositions.positions[0];
        
        assertEq(p.pricing.quoteCurrency, address(dai));
        assertEq(p.pricing.quoteCurrencySymbol, "DAI");
        assertEq(p.pricing.quoteCurrencyDecimals, dai.decimals());
        // Value should be converted to DAI
        assertTrue(p.pricing.value > 0);
    }

    // Test 10: getAllPositions_currencyConversionReversibility
    function test_getAllPositions_currencyConversionReversibility() public {
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(nav.NATIVE_ADDRESS()));
        nav.setPriceOracle(
            address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
        );
        vm.stopPrank();

        usdc.mint(safe, 10 ** usdc.decimals());
        
        // Get positions in USD
        INAVCalculator.AccountPositions memory usdPositions = nav.getAllPositions(safe, address(0));
        int256 usdValue = usdPositions.positions[0].pricing.value;
        
        // Get positions in ETH
        INAVCalculator.AccountPositions memory ethPositions = nav.getAllPositions(safe, nav.NATIVE_ADDRESS());
        int256 ethValue = ethPositions.positions[0].pricing.value;
        
        // Convert ETH value back to USD using the rate
        // ethValue is in ETH with 18 decimals, we need to convert back
        // Get ETH price
        (uint256 ethPrice, uint8 ethPriceDecimals,) = nav.latestPrice(nav.NATIVE_ADDRESS());
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
        INAVCalculator.NAV memory nav1 = nav.getTotalNAV(safe);
        INAVCalculator.AccountPositions memory positions1 = nav.getAllPositions(safe, address(0));
        assertEq(nav1.usd, sumPositionValues(positions1.positions));

        // Test with single asset
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.NAV memory nav2 = nav.getTotalNAV(safe);
        INAVCalculator.AccountPositions memory positions2 = nav.getAllPositions(safe, address(0));
        assertEq(nav2.usd, sumPositionValues(positions2.positions));

        // Test with multiple assets
        dai.mint(safe, 10 ** dai.decimals());
        weth.mint(safe, 10 ** weth.decimals());
        INAVCalculator.NAV memory nav3 = nav.getTotalNAV(safe);
        INAVCalculator.AccountPositions memory positions3 = nav.getAllPositions(safe, address(0));
        assertEq(nav3.usd, sumPositionValues(positions3.positions));

        // Test with negative balances
        Mock_CustomBalanceOracle debtOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(debtOracle), IBalances.BalanceType.Custom);
        debtOracle.setBalance(address(usdc), safe, -1 * int256(10 ** usdc.decimals()));
        vm.stopPrank();
        
        INAVCalculator.NAV memory nav4 = nav.getTotalNAV(safe);
        INAVCalculator.AccountPositions memory positions4 = nav.getAllPositions(safe, address(0));
        assertEq(nav4.usd, sumPositionValues(positions4.positions));
    }

    // Test 12: positionCompletenessInvariant
    function test_positionCompletenessInvariant() public {
        // Setup: some zero balances, some non-zero
        usdc.mint(safe, 10 ** usdc.decimals());
        // dai has zero balance
        // weth has zero balance
        
        Mock_CustomBalanceOracle customOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(customOracle), IBalances.BalanceType.Custom);
        customOracle.setBalance(address(usdc), safe, 0); // Zero balance
        vm.stopPrank();

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        
        // Should only have 1 position (ERC20 USDC), not the zero custom oracle position
        assertEq(accountPositions.positions.length, 1);
        assertEq(accountPositions.positions[0].core.asset, address(usdc));
        assertTrue(accountPositions.positions[0].core.balance != 0);
        
        // Verify no zero positions
        for (uint256 i = 0; i < accountPositions.positions.length; i++) {
            assertTrue(accountPositions.positions[i].core.balance != 0, "Zero position found");
        }
    }

    // Test 13: metadataConsistencyInvariant (partially covered above, adding comprehensive test)
    function test_metadataConsistencyInvariant() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        
        // Test ERC20 oracle metadata
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        INAVCalculator.VerbosePosition memory erc20Pos = accountPositions.positions[0];
        assertPositionMetadata(erc20Pos, address(usdc), "Portfolio balance", "USDC", "ERC20");

        // Test custom oracle metadata
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(mockBalanceOracle), IBalances.BalanceType.Custom);
        vm.stopPrank();

        INAVCalculator.AccountPositions memory accountPositions2 = nav.getAllPositions(safe, address(0));
        bool foundCustom = false;
        for (uint256 i = 0; i < accountPositions2.positions.length; i++) {
            if (keccak256(bytes(accountPositions2.positions[i].core.protocol)) == keccak256(bytes("Mock Protocol"))) {
                assertPositionMetadata(
                    accountPositions2.positions[i],
                    address(usdc),
                    "Mock Protocol",
                    "Mock Position",
                    "Mock Type"
                );
                foundCustom = true;
            }
        }
        assertTrue(foundCustom, "Custom oracle position not found");
    }

    // ============================================
    // D. Edge Cases
    // ============================================

    // Test 14: getAllPositions_zeroBalancesExcluded
    function test_getAllPositions_zeroBalancesExcluded() public {
        // No minting - all balances are zero
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions.positions.length, 0);

        // Add a custom oracle with zero balance
        Mock_CustomBalanceOracle zeroOracle = new Mock_CustomBalanceOracle();
        vm.startPrank(navCalculatorManager);
        nav.setBalanceOracle(address(usdc), address(zeroOracle), IBalances.BalanceType.Custom);
        zeroOracle.setBalance(address(usdc), safe, 0);
        vm.stopPrank();

        INAVCalculator.AccountPositions memory accountPositions2 = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions2.positions.length, 0);
    }

    // Test 17: getAllPositions_stalePrices
    function test_getAllPositions_stalePrices() public {
        // Create a stale price oracle with short heartbeat
        Mock_PriceOracleChainlink staleOracle = new Mock_PriceOracleChainlink("Stale", 1, 8);
        vm.startPrank(navCalculatorManager);
        // USDC is already registered, just update the price oracle with short heartbeat
        nav.setPriceOracle(address(usdc), address(staleOracle), IPrices.PriceType.Chainlink, 1); // 1 second heartbeat
        vm.stopPrank();

        // Make price stale by warping time
        vm.warp(block.timestamp + 2);
        
        usdc.mint(safe, 10 ** usdc.decimals());
        
        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        assertTrue(r.stalePriceAssets.length > 0);
        assertEq(r.stalePriceAssets[0], address(usdc));

        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        assertEq(accountPositions.nav.stalePriceAssets.length, 1);
        assertEq(accountPositions.nav.stalePriceAssets[0], address(usdc));
        
        // All positions for stale asset should be marked stale
        for (uint256 i = 0; i < accountPositions.positions.length; i++) {
            if (accountPositions.positions[i].core.asset == address(usdc)) {
                assertTrue(accountPositions.positions[i].pricing.stale, "Position not marked stale");
            }
        }
    }

    // Test 20: getAllPositions_assetWithoutPriceOracle
    function test_getAllPositions_assetWithoutPriceOracle() public {
        // Create a new token that's not in setUp
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(newToken));
        // Don't set price oracle - this is the key test case
        nav.setBalanceOracle(address(newToken), address(newToken), IBalances.BalanceType.ERC20);
        vm.stopPrank();

        newToken.mint(safe, 10 ** newToken.decimals());
        
        // Should not revert, but skip asset without price oracle
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        // Asset should not be included since it has no price oracle
        for (uint256 i = 0; i < accountPositions.positions.length; i++) {
            assertTrue(accountPositions.positions[i].core.asset != address(newToken));
        }
    }

    // ============================================
    // E. Error Cases
    // ============================================

    // Test 21: getAllPositions_invalidQuoteCurrency
    function test_getAllPositions_invalidQuoteCurrency() public {
        // Use a non-registered address
        address invalidCurrency = makeAddr("invalid");
        
        vm.expectRevert(INAVCalculator.AssetNotFound.selector);
        nav.getAllPositions(safe, invalidCurrency);

        // Create a new token, register it but don't set price oracle
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(newToken));
        // Don't set price oracle
        vm.stopPrank();

        vm.expectRevert(IPrices.PriceOracleNotSet.selector);
        nav.getAllPositions(safe, address(newToken));
    }

    // ============================================
    // F. Data Structure Tests
    // ============================================

    // Test 23: getAllPositions_structureCompleteness
    function test_getAllPositions_structureCompleteness() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        
        assertEq(accountPositions.positions.length, 1);
        INAVCalculator.VerbosePosition memory p = accountPositions.positions[0];
        
        // Check PositionCore completeness
        assertTrue(p.core.asset != address(0));
        assertTrue(bytes(p.core.assetSymbol).length > 0);
        assertTrue(p.core.assetDecimals > 0);
        assertTrue(bytes(p.core.protocol).length > 0);
        assertTrue(bytes(p.core.position).length > 0);
        assertTrue(bytes(p.core.positionType).length > 0);
        
        // Check PositionPricing completeness
        assertTrue(bytes(p.pricing.quoteCurrencySymbol).length > 0);
        assertTrue(p.pricing.quoteCurrencyDecimals > 0);
        assertTrue(p.pricing.rate > 0);
        assertTrue(p.pricing.rateDecimals > 0);
    }

    // Test 24: getAllPositions_rateCalculation
    function test_getAllPositions_rateCalculation() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        
        // Test USD rate
        INAVCalculator.AccountPositions memory usdPositions = nav.getAllPositions(safe, address(0));
        INAVCalculator.VerbosePosition memory usdPos = usdPositions.positions[0];
        (uint256 usdRate, uint8 usdRateDecimals,) = nav.latestPrice(address(usdc));
        assertEq(usdPos.pricing.rate, usdRate);
        assertEq(usdPos.pricing.rateDecimals, usdRateDecimals);

        // Test ETH rate
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(nav.NATIVE_ADDRESS()));
        nav.setPriceOracle(
            address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
        );
        vm.stopPrank();

        INAVCalculator.AccountPositions memory ethPositions = nav.getAllPositions(safe, nav.NATIVE_ADDRESS());
        INAVCalculator.VerbosePosition memory ethPos = ethPositions.positions[0];
        (uint256 ethPrice, uint8 ethPriceDecimals,) = nav.latestPrice(nav.NATIVE_ADDRESS());
        
        // Rate should be: (usdRate * 10^(ethPriceDecimals + ethDecimals)) / (ethPrice * 10^usdRateDecimals)
        uint256 expectedRate = (usdRate * (10 ** (ethPriceDecimals + 18))) / (ethPrice * (10 ** usdRateDecimals));
        assertApproxEqRel(ethPos.pricing.rate, expectedRate, 0.01 ether);
        assertEq(ethPos.pricing.rateDecimals, 18);
    }

    // ============================================
    // G. Integration with Existing Features
    // ============================================

    // Test 25: getTotalNAV_healthCheckConsistency
    function test_getTotalNAV_healthCheckConsistency() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        
        (bool sequencerDown, address[] memory stalePriceAssets) = nav.healthCheck();
        INAVCalculator.NAV memory r = nav.getTotalNAV(safe);
        
        assertEq(r.sequencerDown, sequencerDown);
        assertEq(r.stalePriceAssets.length, stalePriceAssets.length);
        for (uint256 i = 0; i < r.stalePriceAssets.length; i++) {
            assertEq(r.stalePriceAssets[i], stalePriceAssets[i]);
        }
    }

    // Test 26: getAllPositions_hasPositionsConsistency
    function test_getAllPositions_hasPositionsConsistency() public {
        // Empty account
        assertFalse(nav.hasPositions(safe));
        INAVCalculator.AccountPositions memory empty = nav.getAllPositions(safe, address(0));
        assertEq(empty.positions.length, 0);

        // Account with positions
        usdc.mint(safe, 10 ** usdc.decimals());
        assertTrue(nav.hasPositions(safe));
        INAVCalculator.AccountPositions memory withPositions = nav.getAllPositions(safe, address(0));
        assertTrue(withPositions.positions.length > 0);
    }

    // ============================================
    // H. calculateValue Tests
    // ============================================

    // Test calculateValue_singleAsset_usd
    function test_calculateValue_singleAsset_usd() public {
        address[] memory assets = new address[](1);
        int256[] memory balances = new int256[](1);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());

        int256 value = nav.calculateValue(assets, balances, address(0));
        assertEq(value, 1e8); // 1 USDC = 1 USD (with 8 decimals)
    }

    // Test calculateValue_multipleAssets_usd
    function test_calculateValue_multipleAssets_usd() public {
        address[] memory assets = new address[](3);
        int256[] memory balances = new int256[](3);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());
        assets[1] = address(dai);
        balances[1] = int256(10 ** dai.decimals());
        assets[2] = address(weth);
        balances[2] = int256(10 ** weth.decimals());

        int256 value = nav.calculateValue(assets, balances, address(0));
        // USDC: 1e8, DAI: 1e8, WETH: ~3240e8
        assertApproxEqRel(value, 3242e8, 0.01 ether);
    }

    // Test calculateValue_ethQuoteCurrency
    function test_calculateValue_ethQuoteCurrency() public {
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(nav.NATIVE_ADDRESS()));
        nav.setPriceOracle(
            address(nav.NATIVE_ADDRESS()), address(ethOracle), IPrices.PriceType.Chainlink, type(uint256).max
        );
        vm.stopPrank();

        address[] memory assets = new address[](1);
        int256[] memory balances = new int256[](1);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());

        int256 value = nav.calculateValue(assets, balances, nav.NATIVE_ADDRESS());
        // 1 USDC in ETH should be positive
        assertTrue(value > 0);
    }

    // Test calculateValue_customQuoteCurrency
    function test_calculateValue_customQuoteCurrency() public {
        address[] memory assets = new address[](1);
        int256[] memory balances = new int256[](1);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());

        int256 value = nav.calculateValue(assets, balances, address(dai));
        // 1 USDC in DAI should be approximately 1 DAI (both are $1)
        assertApproxEqRel(value, int256(10 ** dai.decimals()), 0.01 ether);
    }

    // Test calculateValue_zeroBalances
    function test_calculateValue_zeroBalances() public {
        address[] memory assets = new address[](2);
        int256[] memory balances = new int256[](2);
        assets[0] = address(usdc);
        balances[0] = 0;
        assets[1] = address(dai);
        balances[1] = 0;

        int256 value = nav.calculateValue(assets, balances, address(0));
        assertEq(value, 0);
    }

    // Test calculateValue_negativeBalances
    function test_calculateValue_negativeBalances() public {
        address[] memory assets = new address[](2);
        int256[] memory balances = new int256[](2);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());
        assets[1] = address(usdc);
        balances[1] = -1 * int256(10 ** usdc.decimals());

        int256 value = nav.calculateValue(assets, balances, address(0));
        assertEq(value, 0);
    }

    // Test calculateValue_mixedPositiveNegative
    function test_calculateValue_mixedPositiveNegative() public {
        address[] memory assets = new address[](2);
        int256[] memory balances = new int256[](2);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());
        assets[1] = address(dai);
        balances[1] = -1 * int256(5 * 10 ** (dai.decimals() - 1)); // -0.5 DAI

        int256 value = nav.calculateValue(assets, balances, address(0));
        // 1 USDC - 0.5 DAI = 0.5 USD (in 8 decimals = 0.5e8)
        assertEq(value, 5e7);
    }

    // Test calculateValue_arrayLengthMismatch
    function test_calculateValue_arrayLengthMismatch() public {
        address[] memory assets = new address[](2);
        int256[] memory balances = new int256[](1);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        balances[0] = int256(10 ** usdc.decimals());

        vm.expectRevert(abi.encodeWithSelector(InvalidArgumentsWithContext.selector, "assets.length != balances.length"));
        nav.calculateValue(assets, balances, address(0));
    }

    // Test calculateValue_assetNotFound
    function test_calculateValue_assetNotFound() public {
        address invalidAsset = makeAddr("invalid");
        address[] memory assets = new address[](1);
        int256[] memory balances = new int256[](1);
        assets[0] = invalidAsset;
        balances[0] = int256(10 ** 18);

        vm.expectRevert(INAVCalculator.AssetNotFound.selector);
        nav.calculateValue(assets, balances, address(0));
    }

    // Test calculateValue_priceOracleNotSet
    function test_calculateValue_priceOracleNotSet() public {
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(newToken));
        // Don't set price oracle
        vm.stopPrank();

        address[] memory assets = new address[](1);
        int256[] memory balances = new int256[](1);
        assets[0] = address(newToken);
        balances[0] = int256(10 ** 18);

        vm.expectRevert(IPrices.PriceOracleNotSet.selector);
        nav.calculateValue(assets, balances, address(0));
    }

    // Test calculateValue_invalidQuoteCurrency
    function test_calculateValue_invalidQuoteCurrency() public {
        address[] memory assets = new address[](1);
        int256[] memory balances = new int256[](1);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());

        address invalidQuote = makeAddr("invalid");
        vm.expectRevert(INAVCalculator.AssetNotFound.selector);
        nav.calculateValue(assets, balances, invalidQuote);
    }

    // Test calculateValue_quoteCurrencyNoPriceOracle
    function test_calculateValue_quoteCurrencyNoPriceOracle() public {
        Mock_ERC20 newToken = new Mock_ERC20("NEW", 18);
        vm.startPrank(navCalculatorManager);
        nav.registerAsset(address(newToken));
        // Don't set price oracle for quote currency
        vm.stopPrank();

        address[] memory assets = new address[](1);
        int256[] memory balances = new int256[](1);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());

        vm.expectRevert(IPrices.PriceOracleNotSet.selector);
        nav.calculateValue(assets, balances, address(newToken));
    }

    // Test calculateValue_consistencyWithGetAllPositions
    function test_calculateValue_consistencyWithGetAllPositions() public {
        usdc.mint(safe, 10 ** usdc.decimals());
        dai.mint(safe, 10 ** dai.decimals());

        // Get value from getAllPositions
        INAVCalculator.AccountPositions memory accountPositions = nav.getAllPositions(safe, address(0));
        int256 positionsValue = sumPositionValues(accountPositions.positions);

        // Calculate value manually
        address[] memory assets = new address[](2);
        int256[] memory balances = new int256[](2);
        assets[0] = address(usdc);
        balances[0] = int256(10 ** usdc.decimals());
        assets[1] = address(dai);
        balances[1] = int256(10 ** dai.decimals());

        int256 calculatedValue = nav.calculateValue(assets, balances, address(0));

        // Should match (allowing for any rounding differences)
        assertEq(calculatedValue, positionsValue);
    }
}
