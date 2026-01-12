// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import "forge-std/Test.sol";
import "test/SuperTest.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Test} from "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AaveV3InstanceBalanceOracle} from "src/balances/protocols/AaveV3Instance.sol";
import {INAVCalculator} from "src/nav/INAVCalculator.sol";
import {sDAI_PriceOracle} from "src/prices/protocols/sDAI_Price.sol";
import {CompoundV3Comet} from "src/balances/protocols/CompoundV3Comet.sol";
import {CompoundV3CometWithMultiplier} from "src/balances/protocols/CompoundV3CometWithMultiplier.sol";
import {MorphoMarketBalanceOracle} from "src/balances/protocols/MorphoMarket.sol";
import {DaiDsrBalanceOracle} from "src/balances/protocols/DaiDsr.sol";
import {sDAI_PriceOracle as sXDAI_PriceOracle} from "src/prices/protocols/sXDAI_Price.sol";

import "forge-std/Script.sol";

contract NAVCalculatorForkHarness is TestEnvConfigurator {
    address public safe = address(0x846E7F810E08F1E2AF2c5AfD06847cc95F5CaE1B);

    AaveV3InstanceBalanceOracle public aaveOracle;
    CompoundV3Comet public compoundV3Comet;
    CompoundV3CometWithMultiplier public compoundV3CometWithMultiplier;
    MorphoMarketBalanceOracle public morphoBlueOracle;
    DaiDsrBalanceOracle public daiDsr;
    sXDAI_PriceOracle public savingsXDAIPrice;

    sDAI_PriceOracle public sdaiPriceOracle;

    NAVCalculator public nav;

    uint256 public fork;
    address public admin = makeAddr("admin");
    address public ops = makeAddr("ops");

    uint256 public heartbeat = type(uint256).max;

    function fork_read() internal view returns (INAVCalculator.NAV memory) {
        INAVCalculator.NAV memory reading = nav.read(safe);

        return reading;
    }

    function setup_NAVCalculator() internal {
        vm.selectFork(fork);

        vm.startPrank(admin);
        nav = NAVCalculator(
            Upgrades.deployUUPSProxy(
                "NAVCalculator.sol",
                abi.encodeCall(NAVCalculator.initialize, (admin, safe, address(0))),
                unsafeDeployOpts()
            )
        );

        nav.grantRole(MANAGER, admin);

        setupPriceOracle();

        setupBalanceOracle();

        vm.stopPrank();
    }

    function setupPriceOracle() internal virtual {}

    function setupBalanceOracle() internal virtual {}

    function unsafeDeployOpts() internal pure returns (UUPSDeployOptions memory opts) {
        opts.unsafeSkipAllChecks = true;
    }
}

contract MainnetForkNAVCalculatorTest is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public sdai = IERC20(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    IERC20 public compound = IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);

    address public aaveV3DataProvider = address(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);
    address public aaveV3rewardsDistributor = address(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);

    IERC20 public cUSDCv3 = IERC20(0xc3d688B66703497DAA19211EEdff47f25384cdc3);
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
        fork = vm.createFork(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(20_993_780);
        setup_NAVCalculator();
    }

    function test_mainnetFork_read() public view {
        INAVCalculator.NAV memory reading = super.fork_read();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertEq(reading.usd, 12_742_160_647_301);
    }

    function setupPriceOracle() internal override {
        sdaiPriceOracle = new sDAI_PriceOracle(address(sdai), dsrManager, daiToUsdChainlink, heartbeat);

        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), usdcToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(dai));
        nav.setPriceOracle(address(dai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(sdai));
        nav.setPriceOracle(address(sdai), address(sdaiPriceOracle), IPrices.PriceType.Custom, heartbeat);
        nav.registerAsset(address(compound));
        nav.setPriceOracle(address(compound), compoundToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(eth));
        nav.setPriceOracle(address(eth), ethToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
    }

    function setupBalanceOracle() internal override {
        IBalanceOracleCustom.PositionMetadata memory aaveMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Aave v3", position: "Core Instance", positionType: "Supplied/Borrowed"
        });
        aaveOracle = new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, aaveMetadata);

        IBalanceOracleCustom.PositionMetadata memory compoundMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Compound v3", position: "USDC Comet", positionType: "Supplied/Borrowed"
        });
        compoundV3Comet =
            new CompoundV3Comet(compoundRewardContract, address(cUSDCv3), address(compound), compoundMetadata);

        IBalanceOracleCustom.PositionMetadata memory morphoMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Morpho", position: "Some market", positionType: "Supplied"
        });
        morphoBlueOracle = new MorphoMarketBalanceOracle(morphoBlue, marketIdWsethUsdc, morphoMetadata);

        IBalanceOracleCustom.PositionMetadata memory dsrMetadata =
            IBalanceOracleCustom.PositionMetadata({protocol: "Maker", position: "DSR", positionType: "Supplied"});
        daiDsr = new DaiDsrBalanceOracle(address(dai), dsr, dsrMetadata);

        // usdc
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(usdc), address(aaveOracle), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(usdc), address(compoundV3Comet), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(usdc), address(morphoBlueOracle), IBalances.BalanceType.Custom);

        // dai
        nav.setBalanceOracle(address(dai), address(dai), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(dai), address(aaveOracle), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(dai), address(daiDsr), IBalances.BalanceType.Custom);

        // sDai
        nav.setBalanceOracle(address(sdai), address(sdai), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(sdai), address(aaveOracle), IBalances.BalanceType.Custom);

        // Compound

        nav.setBalanceOracle(address(compound), address(compoundV3Comet), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(compound), address(compound), IBalances.BalanceType.ERC20);
    }
}

contract OptimismForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    IERC20 public compound = IERC20(0x7e7d4467112689329f7E06571eD0E8CbAd4910eE);

    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);
    address public aaveV3rewardsDistributor = address(0x929EC64c34a17401F460460D4B9390518E5B473e);

    IERC20 public cUSDCv3 = IERC20(0x2e44e174f7D53F0212823acC11C01A11d58c5bCB);
    address public compoundRewardContract = address(0x443EA0340cb75a160F31A440722dec7b5bc3C2E9);

    address public usdcToUsdChainlink = address(0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3);
    address public compoundToUsdChainlink = address(0xe1011160d78a80E2eEBD60C228EEf7af4Dfcd4d7);

    function setUp() public {
        fork = vm.createFork(getAlchemyUrl("opt-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(126_963_147);
        setup_NAVCalculator();
    }

    function test_optimismFork_read() public view {
        INAVCalculator.NAV memory reading = super.fork_read();
        assertEq(reading.usd, 7_596_542_008_105);

        int256 aave_usdc_balance = aaveOracle.balanceOf(address(usdc), safe);
        assertEq(aave_usdc_balance, 75_976_056_729);
        assertEq(compoundV3CometWithMultiplier.balanceOf(address(compound), safe), 0);
        assertEq(compoundV3CometWithMultiplier.balanceOf(address(usdc), safe), 0);
    }

    function setupPriceOracle() internal override {
        // usdc
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(address(usdc), usdcToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);

        // Compound
        nav.registerAsset(address(compound));
        nav.setPriceOracle(address(compound), compoundToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);
    }

    function setupBalanceOracle() internal override {
        IBalanceOracleCustom.PositionMetadata memory aavePositionMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Aave v3", position: "Core Instance", positionType: "Supplied/Borrowed"
        });
        aaveOracle = new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, aavePositionMetadata);

        IBalanceOracleCustom.PositionMetadata memory compoundPositionMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Compound v3", position: "USDC Comet", positionType: "Supplied/Borrowed"
        });
        compoundV3CometWithMultiplier = new CompoundV3CometWithMultiplier(
            compoundRewardContract, address(cUSDCv3), address(compound), compoundPositionMetadata
        );

        // usdc
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(usdc), address(aaveOracle), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(usdc), address(compoundV3CometWithMultiplier), IBalances.BalanceType.Custom);

        // Compound

        nav.setBalanceOracle(address(compound), address(compoundV3CometWithMultiplier), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(compound), address(compound), IBalances.BalanceType.ERC20);
    }
}

contract BaseForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IERC20 public cUSDCv3 = IERC20(0xb125E6687d4313864e53df431d5425969c15Eb2F);
    IERC20 public compound = IERC20(0x9e1028F5F1D5eDE59748FFceE5532509976840E0);

    address public aaveV3DataProvider = address(0xd82a47fdebB5bf5329b09441C3DaB4b5df2153Ad);
    address public aaveV3rewardsDistributor = address(0xf9cc4F0D883F1a1eb2c253bdb46c254Ca51E1F44);

    address public compoundRewardContract = address(0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1);
    address public morphoBlue = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    bytes32 public marketIdWsethUsdc = 0xdba352d93a64b17c71104cbddc6aef85cd432322a1446b5b65163cbbc615cd0c;

    function setUp() public {
        fork = vm.createFork(getAlchemyUrl("base-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(21_360_710);
        setup_NAVCalculator();
    }

    function test_baseFork_read() public view {
        INAVCalculator.NAV memory reading = super.fork_read();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertEq(morphoBlueOracle.balanceOf(address(usdc), safe), 25_277_122_725);
        assertEq(aaveOracle.balanceOf(address(usdc), safe), 25_162_172_577);
        assertEq(compoundV3Comet.balanceOf(address(compound), safe), 860_559_000_000_000_000);

        assertEq(reading.usd, 5_047_061_452_128);
    }

    function setupPriceOracle() internal override {
        // usdc
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(
            address(usdc), address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B), IPrices.PriceType.Chainlink, heartbeat
        );

        // Compound

        nav.registerAsset(address(compound));
        nav.setPriceOracle(
            address(compound),
            address(0x9DDa783DE64A9d1A60c49ca761EbE528C35BA428),
            IPrices.PriceType.Chainlink,
            heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        IBalanceOracleCustom.PositionMetadata memory aavePositionMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Aave v3", position: "Core Instance", positionType: "Supplied/Borrowed"
        });
        aaveOracle = new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, aavePositionMetadata);

        IBalanceOracleCustom.PositionMetadata memory compoundPositionMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Compound v3", position: "USDC Comet", positionType: "Supplied/Borrowed"
        });
        compoundV3Comet =
            new CompoundV3Comet(compoundRewardContract, address(cUSDCv3), address(compound), compoundPositionMetadata);

        IBalanceOracleCustom.PositionMetadata memory morphoPositionMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Morpho", position: "Some Market", positionType: "Supplied"
        });
        morphoBlueOracle = new MorphoMarketBalanceOracle(morphoBlue, marketIdWsethUsdc, morphoPositionMetadata);

        // usdc
        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(usdc), address(aaveOracle), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(usdc), address(compoundV3Comet), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(usdc), address(morphoBlueOracle), IBalances.BalanceType.Custom);

        // Compound
        nav.setBalanceOracle(address(compound), address(compoundV3Comet), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(compound), address(compound), IBalances.BalanceType.ERC20);
    }
}

contract ArbitrumForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IERC20 public cUSDCv3 = IERC20(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);
    IERC20 public compound = IERC20(0x354A6dA3fcde098F8389cad84b0182725c6C91dE);

    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);
    address public aaveV3rewardsDistributor = address(0x929EC64c34a17401F460460D4B9390518E5B473e);

    address public compoundRewardContract = address(0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae);

    function setUp() public {
        fork = vm.createFork(getAlchemyUrl("arb-mainnet"));

        vm.selectFork(fork);
        vm.rollFork(266_194_155);
        setup_NAVCalculator();
    }

    function test_arbitrumFork_read() public view {
        INAVCalculator.NAV memory reading = super.fork_read();
        assertEq(reading.usd, 5_069_577_118_472);
        assertEq(aaveOracle.balanceOf(address(usdc), safe), 50_703_125_166);
        (uint256 price,,) = nav.latestPrice(address(usdc));
        assertEq(price, 99_985_496);
    }

    function setupPriceOracle() internal override {
        // usdc
        nav.registerAsset(address(usdc));
        nav.setPriceOracle(
            address(usdc), address(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3), IPrices.PriceType.Chainlink, heartbeat
        );

        // Compound

        nav.registerAsset(address(compound));
        nav.setPriceOracle(
            address(compound),
            address(0xe7C53FFd03Eb6ceF7d208bC4C13446c76d1E5884),
            IPrices.PriceType.Chainlink,
            heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        IBalanceOracleCustom.PositionMetadata memory aavePositionMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Aave v3", position: "Core Instance", positionType: "Supplied/Borrowed"
        });
        aaveOracle = new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, aavePositionMetadata);

        IBalanceOracleCustom.PositionMetadata memory compoundPositionMetadata = IBalanceOracleCustom.PositionMetadata({
            protocol: "Compound v3", position: "USDC Comet", positionType: "Supplied/Borrowed"
        });
        compoundV3Comet =
            new CompoundV3Comet(compoundRewardContract, address(cUSDCv3), address(compound), compoundPositionMetadata);

        nav.setBalanceOracle(address(usdc), address(usdc), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(usdc), address(aaveOracle), IBalances.BalanceType.Custom);
        nav.setBalanceOracle(address(usdc), address(compoundV3Comet), IBalances.BalanceType.Custom);

        nav.setBalanceOracle(address(compound), address(compound), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(compound), address(compoundV3Comet), IBalances.BalanceType.Custom);
    }
}

contract GnosisForkNAVCalculatorTest is NAVCalculatorForkHarness {
    address public savingsXDaiContract = address(0xaf204776c7245bF4147c2612BF6e5972Ee483701);
    address public xdai = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address public wxdai = address(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d);

    address public daiToUsdChainlink = address(0x678df3415fc31947dA4324eC63212874be5a82f8);

    function setUp() public {
        fork = vm.createFork(getAlchemyUrl("gnosis-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(36_738_104);
        setup_NAVCalculator();
    }

    function test_gnosisFork_read() public view {
        INAVCalculator.NAV memory reading = super.fork_read();

        assertEq(reading.stalePriceAssets.length, 0);
        assertEq(reading.sequencerDown, false);
        assertEq(reading.usd, 15_378_167_317_682);
    }

    function setupPriceOracle() internal override {
        savingsXDAIPrice = new sXDAI_PriceOracle(savingsXDaiContract, daiToUsdChainlink, heartbeat);

        nav.registerAsset(address(xdai));
        nav.setPriceOracle(address(xdai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(wxdai));
        nav.setPriceOracle(address(wxdai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(savingsXDaiContract));
        nav.setPriceOracle(address(savingsXDaiContract), address(savingsXDAIPrice), IPrices.PriceType.Custom, heartbeat);
    }

    function setupBalanceOracle() internal override {
        // wxdai
        nav.setBalanceOracle(address(wxdai), address(wxdai), IBalances.BalanceType.ERC20);
        nav.setBalanceOracle(address(savingsXDaiContract), address(savingsXDaiContract), IBalances.BalanceType.ERC20);
    }
}
