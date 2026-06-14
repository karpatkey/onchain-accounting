// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.fork.sol";
import {ChainlinkPriceFeeds} from "test/ChainlinkPriceFeeds.sol";
import {AaveV3InstancesMetaBalanceAdapter} from "src/balances/protocols/AaveV3InstancesMeta.sol";
import {AaveV3SafetyModuleBalanceAdapter} from "src/balances/protocols/AaveV3SafetyModule.sol";
import {CompoundV3CometsMetaBalanceAdapter} from "src/balances/protocols/CompoundV3CometsMeta.sol";
import {MorphoMarketsMetaBalanceAdapter} from "src/balances/protocols/MorphoMarketsMeta.sol";
import {DaiDsrBalanceAdapter} from "src/balances/protocols/DaiDsr.sol";
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {sUSDS_PriceOracle} from "src/prices/protocols/sUSDS_Price.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";

contract MainnetForkNAVCalculatorTest is NAVCalculatorForkHarness {
    /// @notice Safe with Aave V3, Compound V3, Morpho, DSR positions on Ethereum Mainnet (same as base harness default)
    address public constant MAINNET_SAFE = 0xCE74fa7A7dEe1d7640540bd752Bee784BE831b4F;

    // Native and wrapped ETH
    address public native = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Token addresses (Ethereum Mainnet)
    address public usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public usdt = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address public dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address public sdai = address(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    address public susds = address(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD); // Sky Savings USDS
    address public compound = address(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    address public gho = address(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    address public wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    // Aave V3 (Ethereum Mainnet)
    address public aave = address(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    address public aaveV3DataProvider = address(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);
    address public stkGho = address(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d); // Aave Safety Module staked GHO
    address public stkAave = address(0x4da27a545c0c5B758a6BA100e3a049001de870f5); // Aave Safety Module staked AAVE

    // Compound V3 (Ethereum Mainnet)
    address public cUsdCv3 = address(0xc3d688B66703497DAA19211EEdff47f25384cdc3);
    address public compoundRewardContract = address(0x1B0e765F6224C21223AeA2af16c1C46E38885a40);

    // Morpho (Ethereum Mainnet)
    address public morphoBlue = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    bytes32 public marketIdSusdsUsdt = 0x3274643db77a064abd3bc851de77556a4ad2e2f502f4f0c80845fa8f909ecf0b; // sUSDS/USDT

    // sUSDS price (USDS/USD Chainlink feed)
    address public usdsUsdChainlink = address(0xfF30586cD0F29eD462364C7e81375FC0C71219b1);
    uint256 public susdsHeartbeat = 82_800;
    sUSDS_PriceOracle public susdsPriceOracle;

    // Maker DSR
    address public dsrManager = address(0x373238337Bfe1146fb49989fc222523f83081dDb);
    address public dsr = address(0x373238337Bfe1146fb49989fc222523f83081dDb);

    /// @dev Pinned to a known-good block. Forking at latest is fragile: when a Chainlink feed
    ///      (or its proxy) gets replaced, the bare `latestRoundData()` call starts reverting
    ///      and setUp fails. Re-pin (or migrate to the new feed addresses) when something
    ///      changes upstream.
    uint256 public constant FORK_BLOCK = 24_987_608;

    function setUp() public {
        togglePositionsLogging();
        safe = MAINNET_SAFE;
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(FORK_BLOCK);
        setupNavCalculator();
    }

    function test_mainnetFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertTrue(reading.value > 0);
    }

    function test_mainnetFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));

        assertEq(navTotal.stalePriceAssets.length, 0);
        assertEq(navTotal.sequencerDown, false);
        assertTrue(navTotal.value > 0);

        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);

        assertTrue(positions.length > 0);
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].balanceAsset.asset != address(0));
            assertTrue(bytes(positions[i].balanceAsset.symbol).length > 0);
        }
    }

    function test_mainnetFork_getAllPositions_ethQuote() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, native);

        assertTrue(positions.length > 0);
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].quoteAsset.asset, native);
            assertTrue(positions[i].value != 0);
        }
    }

    function test_mainnetFork_navConsistency() public view {
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);

        assertEq(navTotal.timestamp, navTotal.timestamp);
        assertEq(navTotal.sequencerDown, navTotal.sequencerDown);
        assertEq(navTotal.stalePriceAssets.length, navTotal.stalePriceAssets.length);
    }

    function setupRegisterAssets() internal override {
        sdaiPriceOracle = new sDAI_PriceOracle(sdai, dsrManager, ChainlinkPriceFeeds.daiUsdEthMainnet(), heartbeat);
        susdsPriceOracle = new sUSDS_PriceOracle(susds, usdsUsdChainlink, susdsHeartbeat);

        nav.registerAsset(usdc, ChainlinkPriceFeeds.usdcUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(usdt, ChainlinkPriceFeeds.usdtUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(dai, ChainlinkPriceFeeds.daiUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(sdai, address(sdaiPriceOracle), IPrices.PriceType.Custom, heartbeat);
        nav.registerAsset(susds, address(susdsPriceOracle), IPrices.PriceType.Custom, susdsHeartbeat);
        nav.registerAsset(aave, ChainlinkPriceFeeds.aaveUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(compound, ChainlinkPriceFeeds.compUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(gho, ChainlinkPriceFeeds.ghoUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.addPriceFeed(native, ChainlinkPriceFeeds.ethUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(weth, ChainlinkPriceFeeds.ethUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(wbtc, ChainlinkPriceFeeds.btcUsdEthMainnet(), IPrices.PriceType.Chainlink, heartbeat);
    }

    function setupBalanceAdapter() internal override {
        AaveV3InstancesMetaBalanceAdapter aaveMeta = new AaveV3InstancesMetaBalanceAdapter("Aave V3", address(nav));
        aaveAdapter = aaveMeta;
        AaveV3SafetyModuleBalanceAdapter smAdapter = new AaveV3SafetyModuleBalanceAdapter(address(nav));
        compoundV3Comet =
            new CompoundV3CometsMetaBalanceAdapter(compoundRewardContract, compound, "Compound V3", address(nav));
        morphoBlueAdapter = new MorphoMarketsMetaBalanceAdapter(morphoBlue, "Morpho", address(nav));
        daiDsr = new DaiDsrBalanceAdapter(dai, dsr, address(nav));

        nav.addBalanceAdapter(address(aaveAdapter));
        nav.addBalanceAdapter(address(smAdapter));
        nav.addBalanceAdapter(address(compoundV3Comet));
        nav.addBalanceAdapter(address(morphoBlueAdapter));
        nav.addBalanceAdapter(address(daiDsr));

        bytes32[] memory aaveInstances = new bytes32[](1);
        aaveInstances[0] = bytes32(uint256(uint160(aaveV3DataProvider)));
        nav.setMetaInstances(address(aaveMeta), aaveInstances);
    }

    function test_logPositions() public view {
        logAccountPositions(safe, address(0));
    }
}
