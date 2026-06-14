// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";
import {ChainlinkPriceFeeds} from "test/ChainlinkPriceFeeds.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "src/balances/protocols/CompoundV3CometsMeta.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/protocols/MorphoMarketsMeta.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {aa} from "test/helpers/AdapterArray.sol";

contract BaseForkNAVCalculator is NAVCalculatorForkHarness {
    /// @notice Safe with Aave V3, Compound V3, Morpho positions on Base (same as base harness default)
    /// @notice USD Prime fund on Base
    address public constant BASE_SAFE = 0xCE74fa7A7dEe1d7640540bd752Bee784BE831b4F;

    // Native and wrapped ETH
    address public native = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public weth = address(0x4200000000000000000000000000000000000006);

    // Token addresses (Base Mainnet)
    address public usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public cbbtc = address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf); // Coinbase Wrapped BTC
    address public compound = address(0x9e1028F5F1D5eDE59748FFceE5532509976840E0);

    // Aave V3 (Base)
    address public aaveV3DataProvider = address(0xd82a47fdebB5bf5329b09441C3DaB4b5df2153Ad);

    // Compound V3 (Base)
    address public cUsdCv3 = address(0xb125E6687d4313864e53df431d5425969c15Eb2F);
    address public compoundRewardContract = address(0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1);

    // Morpho (Base) — cbBTC/USDC market (USD Prime fund position)
    address public morphoBlue = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    // Morpho Base cbBTC/USDC market (loanToken=USDC, collateralToken=cbBTC)
    bytes32 public marketIdCbbtcUsdc = 0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836;

    /// @dev Pinned to a known-good block. See NAVCalculator.Mainnet.fork.t.sol for rationale.
    uint256 public constant FORK_BLOCK = 45_349_500;

    function setUp() public {
        togglePositionsLogging();
        safe = BASE_SAFE;
        fork = createForkWithCadence(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        setupNavCalculator();
    }

    function test_baseFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertTrue(reading.value > 0);
    }

    function test_baseFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertTrue(positions.length > 0, "at least one position");
        assertTrue(navTotal.value > 0);

        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupRegisterAssets() internal override {
        nav.addPriceFeed(native, ChainlinkPriceFeeds.ethUsdBase(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(usdc, ChainlinkPriceFeeds.usdcUsdBase(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(cbbtc, ChainlinkPriceFeeds.cbbtcUsdBase(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(compound, ChainlinkPriceFeeds.compUsdBase(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(weth, ChainlinkPriceFeeds.ethUsdBase(), IPrices.PriceType.Chainlink, heartbeat);
    }

    function setupBalanceAdapter() internal override {
        AaveV3InstancesMetaBalanceAdapter aaveMeta = new AaveV3InstancesMetaBalanceAdapter("Aave V3", address(nav));
        aaveAdapter = aaveMeta;

        compoundV3Comet =
            new CompoundV3CometsMetaBalanceAdapter(compoundRewardContract, compound, "Compound V3", address(nav));

        morphoBlueAdapter = new MorphoMarketsMetaBalanceAdapter(morphoBlue, "Morpho", address(nav));

        nav.addBalanceAdapters(aa(address(aaveAdapter)));
        nav.addBalanceAdapters(aa(address(compoundV3Comet)));
        nav.addBalanceAdapters(aa(address(morphoBlueAdapter)));

        // Configure meta-adapter instance sets
        bytes32[] memory aaveInstances = new bytes32[](1);
        aaveInstances[0] = bytes32(uint256(uint160(aaveV3DataProvider)));
        nav.addMetaInstances(address(aaveMeta), aaveInstances);

        bytes32[] memory comets = new bytes32[](1);
        comets[0] = bytes32(uint256(uint160(cUsdCv3)));
        nav.addMetaInstances(address(compoundV3Comet), comets);

        bytes32[] memory markets = new bytes32[](1);
        markets[0] = marketIdCbbtcUsdc;
        nav.addMetaInstances(address(morphoBlueAdapter), markets);
    }

    function test_logPositions() public view {
        logAccountPositions(safe, address(0));
    }
}
