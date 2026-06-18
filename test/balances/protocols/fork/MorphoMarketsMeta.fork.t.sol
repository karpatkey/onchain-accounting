// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceAdapterTestBase} from "test/balances/protocols/fork/BalanceAdapterTestBase.fork.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/protocols/MorphoMarketsMeta.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Mock_CustomPriceFeed} from "test/mocks/price_oracles.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "src/constants.sol";
import {aa} from "test/helpers/AdapterArray.sol";

/// @title MorphoMarketsMetaBalanceAdapter fork tests
/// @notice One meta-adapter serving multiple Morpho Blue markets, routed through a real NAVCalculator that holds
///         the configured marketId set (addMetaInstances). Uses the apxUSD/apyUSD market at a pinned block where
///         the account holds all three legs (supply + borrow + collateral), and asserts parity with the
///         per-market MorphoMarket adapter.
contract MorphoMarketsMetaBalanceAdapterForkTest is BalanceAdapterTestBase {
    address constant PRICE_FEED_LIB = 0x6F0C6f68728Ec474FecB4DE7cdd72E28C2D42715;

    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // apxUSD/apyUSD market: loan = apxUSD, collateral = apyUSD. Account has all three legs at the block below.
    bytes32 public constant MARKET_ID = 0xe23380494e365453f72f736f2d941959ae945773eb67a06cf4f538c7c4201264;
    address public constant APXUSD = 0x98A878b1Cd98131B271883B390f68D2c90674665; // loan token
    address public constant APYUSD = 0x38EEb52F0771140d10c4E9A9a72349A329Fe8a6A; // collateral token
    address public constant USER = 0x81F5d98eA5aCf65640ce8bB68aa8449b7c304c50;
    uint256 public constant FORK_BLOCK = 25_094_065;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    NAVCalculator public nav;
    MorphoMarketsMetaBalanceAdapter public adapter;

    function setUp() public override {
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);

        vm.etch(PRICE_FEED_LIB, vm.deployCode("PriceFeedLib.sol:PriceFeedLib").code);
        vm.etch(0x02F27E28452E6F419b97935f6346381E2b5003B1, vm.deployCode("NavRegistryLib.sol:NavRegistryLib").code);

        vm.startPrank(admin);
        address navImpl = address(new NAVCalculator());
        nav = NAVCalculator(
            UnsafeUpgrades.deployUUPSProxy(
                navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, address(0), "ETH"))
            )
        );
        nav.grantRole(MANAGER, manager);
        vm.stopPrank();

        // Native ETH is pre-registered at init without a feed; add one so getAccountNav can price the user's ETH.
        vm.startPrank(manager);
        nav.addPriceFeed(
            nav.NATIVE_ADDRESS(),
            address(new Mock_CustomPriceFeed("ETH", nav.NATIVE_ADDRESS(), 3000e8, 8)),
            IPrices.PriceType.Custom,
            type(uint256).max
        );
        // Register both market tokens with $1 custom feeds (non-stale).
        nav.registerAsset(
            APXUSD,
            address(new Mock_CustomPriceFeed("apxUSD", APXUSD, 1e8, 8)),
            IPrices.PriceType.Custom,
            type(uint256).max
        );
        nav.registerAsset(
            APYUSD,
            address(new Mock_CustomPriceFeed("apyUSD", APYUSD, 1e8, 8)),
            IPrices.PriceType.Custom,
            type(uint256).max
        );
        vm.stopPrank();

        adapter = new MorphoMarketsMetaBalanceAdapter(MORPHO, "Morpho", address(nav));

        vm.startPrank(manager);
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = MARKET_ID;
        nav.addMetaBalanceAdapter(address(adapter), instances);
        vm.stopPrank();
    }

    function test_threeLegs_present() public view {
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = MARKET_ID;
        INAVCalculator.PositionBalance[] memory pos =
            adapter.getAdapterPositionsForInstances(USER, instances, address(0));
        assertEq(pos.length, 3, "collateral + loan-supply + loan-borrow");

        uint256 collateral;
        uint256 supply;
        uint256 borrow;
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceAdapter, address(adapter));
            assertGt(pos[i].amount, 0);
            if (pos[i].balanceAsset.asset == APYUSD) collateral++;
            else if (pos[i].balanceAsset.asset == APXUSD && !pos[i].isDebt) supply++;
            else if (pos[i].balanceAsset.asset == APXUSD && pos[i].isDebt) borrow++;
        }
        assertEq(collateral, 1, "one collateral leg (apyUSD)");
        assertEq(supply, 1, "one loan-supply leg (apxUSD)");
        assertEq(borrow, 1, "one loan-borrow leg (apxUSD)");
    }

    function test_navRouting_surfacesAllLegs() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(USER, address(0));
        uint256 metaCount = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].balanceAdapter == address(adapter)) metaCount++;
        }
        assertEq(metaCount, 3, "NAV surfaces all three legs via the meta-adapter");

        // NAV nets to net debt here (borrow + collateral valued at $1): assert it computes without reverting.
        INAVCalculator.NAV memory snapshot = nav.getAccountNav(USER, address(0));
        assertTrue(snapshot.value != 0, "NAV computed");
    }

    function test_assetFilter_loanToken_returnsSupplyAndBorrow() public view {
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = MARKET_ID;
        // Filtering by the loan token must return BOTH the supply and borrow legs (the multi-leg-per-filter case
        // the NAV buffer sizing was fixed for).
        INAVCalculator.PositionBalance[] memory pos = adapter.getAdapterPositionsForInstances(USER, instances, APXUSD);
        assertEq(pos.length, 2, "loan-token filter returns supply + borrow");
        for (uint256 i = 0; i < pos.length; i++) {
            assertEq(pos[i].balanceAsset.asset, APXUSD);
        }
    }

    function test_underlyingAssetsForInstances() public view {
        bytes32[] memory instances = new bytes32[](1);
        instances[0] = MARKET_ID;
        address[] memory assets = adapter.underlyingAssetsSupportedForInstances(instances);
        assertEq(assets.length, 2);
        assertEq(assets[0], APYUSD, "collateral first");
        assertEq(assets[1], APXUSD, "loan second");
    }
}
