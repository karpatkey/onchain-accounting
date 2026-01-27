// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {NAVCalculatorForkHarness} from "test/nav/fork/NAVCalculatorForkTestBase.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {DaiDsrBalanceOracle} from "src/balances/protocols/DaiDsr.sol";
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {IPrices} from "src/prices/IPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MainnetForkNAVCalculatorTest is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public sdai = IERC20(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    IERC20 public compound = IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);

    address public aaveV3DataProvider = address(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);
    address public aaveV3rewardsDistributor = address(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);

    IERC20 public cUsdCv3 = IERC20(0xc3d688B66703497DAA19211EEdff47f25384cdc3);
    address public compoundRewardContract = address(0x1B0e765F6224C21223AeA2af16c1C46E38885a40);

    address public morphoBlue = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    bytes32 public marketIdWsethUsdc = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

    address public dsrManager = address(0x373238337Bfe1146fb49989fc222523f83081dDb);
    address public dsr = address(0x373238337Bfe1146fb49989fc222523f83081dDb);

    address public daiToUsdChainlink = address(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);
    address public usdcToUsdChainlink = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    address public compoundToUsdChainlink = address(0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5);
    address public ethToUsdChainlink = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    function setUp() public {
        _checkSkipForkTests();
        fork = createForkWithCadence(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        setupNavCalculator();
    }

    function test_mainnetFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertTrue(reading.value > 0);
    }

    function test_fork_getAllPositions_usd() public view {
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
            assertTrue(positions[i].underlyingAsset.asset != address(0));
            assertTrue(bytes(positions[i].underlyingAsset.symbol).length > 0);
            assertTrue(bytes(positions[i].protocol).length > 0);
        }
    }

    function test_fork_getAllPositions_ethQuote() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, eth);

        assertTrue(positions.length > 0);
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].quoteAsset.asset, eth);
            assertTrue(positions[i].value != 0);
        }
    }

    function test_fork_navConsistency() public view {
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
        sdaiPriceOracle = new sDAI_PriceOracle(address(sdai), dsrManager, daiToUsdChainlink, heartbeat);

        nav.registerAsset(address(usdc), usdcToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(dai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(sdai), address(sdaiPriceOracle), IPrices.PriceType.Custom, heartbeat);
        nav.registerAsset(address(compound), compoundToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(eth), ethToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
    }

    function setupBalanceOracle() internal override {
        aaveOracle =
            new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, "Aave v3", address(nav));

        compoundV3Comet = new CompoundV3Comet(
            compoundRewardContract, address(cUsdCv3), address(compound), "Compound v3", "USDC Comet", address(nav)
        );

        morphoBlueOracle =
            new MorphoMarketBalanceOracle(morphoBlue, marketIdWsethUsdc, "Morpho", "Some market", address(nav));

        daiDsr = new DaiDsrBalanceOracle(address(dai), dsr, "Maker", "DSR", address(nav));

        nav.addBalanceOracle(address(aaveOracle));
        nav.addBalanceOracle(address(compoundV3Comet));
        nav.addBalanceOracle(address(morphoBlueOracle));
        nav.addBalanceOracle(address(daiDsr));
    }
}
